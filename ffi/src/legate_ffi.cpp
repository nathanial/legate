#include "legate_ffi.h"

#include <grpcpp/grpcpp.h>
#include <grpcpp/generic/generic_stub.h>
#include <grpcpp/generic/async_generic_service.h>
#include <grpc/byte_buffer_reader.h>

#include <memory>
#include <mutex>
#include <condition_variable>
#include <string>
#include <vector>
#include <unordered_map>
#include <thread>
#include <atomic>
#include <chrono>

// ============================================================================
// External Class Registration
// ============================================================================

static lean_external_class* g_channel_class = nullptr;
static lean_external_class* g_client_stream_class = nullptr;
static lean_external_class* g_server_stream_class = nullptr;
static lean_external_class* g_bidi_stream_class = nullptr;
static lean_external_class* g_server_builder_class = nullptr;
static lean_external_class* g_server_class = nullptr;

static std::mutex g_init_mutex;
static std::atomic<bool> g_initialized{false};

// ============================================================================
// Wrapper Types
// ============================================================================

// Channel wrapper with GenericStub for making calls
struct ChannelWrapper {
    std::shared_ptr<grpc::Channel> channel;
    std::unique_ptr<grpc::GenericStub> stub;

    explicit ChannelWrapper(std::shared_ptr<grpc::Channel> ch)
        : channel(std::move(ch))
        , stub(std::make_unique<grpc::GenericStub>(channel)) {}
};

// Base class for stream wrappers
struct StreamWrapperBase {
    std::unique_ptr<grpc::ClientContext> context;
    grpc::Status status;
    std::multimap<grpc::string_ref, grpc::string_ref> trailing_metadata;

    StreamWrapperBase() : context(std::make_unique<grpc::ClientContext>()) {}
    virtual ~StreamWrapperBase() = default;
};

// Client streaming call wrapper - using ReaderWriter for all streaming
struct ClientStreamWrapper : StreamWrapperBase {
    std::unique_ptr<grpc::GenericClientAsyncReaderWriter> stream;
    grpc::ByteBuffer response;
    grpc::CompletionQueue cq;
    bool writes_done = false;
};

// Server streaming call wrapper - using ReaderWriter for all streaming
struct ServerStreamWrapper : StreamWrapperBase {
    std::unique_ptr<grpc::GenericClientAsyncReaderWriter> stream;
    grpc::CompletionQueue cq;
    bool finished = false;
};

// Bidirectional streaming call wrapper
struct BidiStreamWrapper : StreamWrapperBase {
    std::unique_ptr<grpc::GenericClientAsyncReaderWriter> stream;
    grpc::CompletionQueue cq;
    bool writes_done = false;
    bool read_finished = false;
};

// Server-side types
enum class HandlerType : uint8_t {
    UNARY = 0,
    CLIENT_STREAMING = 1,
    SERVER_STREAMING = 2,
    BIDI_STREAMING = 3
};

struct RegisteredHandler {
    std::string method;
    HandlerType type;
    lean_object* handler;  // Lean closure (inc-refed)

    RegisteredHandler() : type(HandlerType::UNARY), handler(nullptr) {}
    RegisteredHandler(const RegisteredHandler&) = delete;
    RegisteredHandler& operator=(const RegisteredHandler&) = delete;
    RegisteredHandler(RegisteredHandler&& other) noexcept
        : method(std::move(other.method)), type(other.type), handler(other.handler) {
        other.handler = nullptr;
    }
    RegisteredHandler& operator=(RegisteredHandler&& other) noexcept {
        if (this != &other) {
            if (handler) lean_dec(handler);
            method = std::move(other.method);
            type = other.type;
            handler = other.handler;
            other.handler = nullptr;
        }
        return *this;
    }
    ~RegisteredHandler() {
        if (handler) {
            lean_dec(handler);
            handler = nullptr;
        }
    }
};

struct ServerBuilderWrapper {
    std::unique_ptr<grpc::ServerBuilder> builder;
    std::vector<RegisteredHandler> handlers;
    grpc::AsyncGenericService service;
    int selected_port = 0;

    ServerBuilderWrapper() : builder(std::make_unique<grpc::ServerBuilder>()) {
        builder->RegisterAsyncGenericService(&service);
    }
};

// Forward declaration for call context
struct ServerCallContext;

struct ServerWrapper {
    std::unique_ptr<grpc::Server> server;
    std::unique_ptr<grpc::ServerCompletionQueue> cq;
    std::vector<RegisteredHandler> handlers;
    grpc::AsyncGenericService* service = nullptr;  // Borrowed from builder
    std::thread polling_thread;
    std::atomic<bool> running{false};

    RegisteredHandler* findHandler(const std::string& method) {
        for (auto& h : handlers) {
            if (h.method == method) {
                return &h;
            }
        }
        return nullptr;
    }

    ~ServerWrapper() {
        if (running.load()) {
            running.store(false);
            if (server) server->Shutdown();
            if (cq) cq->Shutdown();
            if (polling_thread.joinable()) {
                polling_thread.join();
            }
        }
        // Handlers are cleaned up by their destructors
    }
};

// Server call context for tracking async operations
struct ServerCallContext {
    grpc::GenericServerContext ctx;
    grpc::GenericServerAsyncReaderWriter stream;
    ServerWrapper* server;
    RegisteredHandler* handler;
    grpc::ByteBuffer request;
    grpc::ByteBuffer response;

    enum class State {
        ACCEPTING,
        READING,
        PROCESSING,
        WRITING,
        FINISHING,
        DONE
    } state;

    ServerCallContext(ServerWrapper* s)
        : stream(&ctx), server(s), handler(nullptr), state(State::ACCEPTING) {}
};

// ============================================================================
// Finalizers for Lean GC
// ============================================================================

static void channel_finalizer(void* ptr) {
    delete static_cast<ChannelWrapper*>(ptr);
}

static void client_stream_finalizer(void* ptr) {
    delete static_cast<ClientStreamWrapper*>(ptr);
}

static void server_stream_finalizer(void* ptr) {
    delete static_cast<ServerStreamWrapper*>(ptr);
}

static void bidi_stream_finalizer(void* ptr) {
    delete static_cast<BidiStreamWrapper*>(ptr);
}

static void server_builder_finalizer(void* ptr) {
    auto* wrapper = static_cast<ServerBuilderWrapper*>(ptr);
    // Handlers are cleaned up by their destructors (RAII)
    delete wrapper;
}

static void server_finalizer(void* ptr) {
    delete static_cast<ServerWrapper*>(ptr);
}

static void noop_foreach(void*, b_lean_obj_arg) {}

// ============================================================================
// Initialization
// ============================================================================

static void init_external_classes() {
    if (g_channel_class == nullptr) {
        g_channel_class = lean_register_external_class(channel_finalizer, noop_foreach);
        g_client_stream_class = lean_register_external_class(client_stream_finalizer, noop_foreach);
        g_server_stream_class = lean_register_external_class(server_stream_finalizer, noop_foreach);
        g_bidi_stream_class = lean_register_external_class(bidi_stream_finalizer, noop_foreach);
        g_server_builder_class = lean_register_external_class(server_builder_finalizer, noop_foreach);
        g_server_class = lean_register_external_class(server_finalizer, noop_foreach);
    }
}

extern "C" LEAN_EXPORT lean_obj_res legate_init(lean_obj_arg /* world */) {
    std::lock_guard<std::mutex> lock(g_init_mutex);
    if (!g_initialized.load()) {
        init_external_classes();
        g_initialized.store(true);
    }
    return lean_io_result_mk_ok(lean_box(0));
}

extern "C" LEAN_EXPORT lean_obj_res legate_shutdown(lean_obj_arg /* world */) {
    // gRPC doesn't require explicit shutdown in most cases
    return lean_io_result_mk_ok(lean_box(0));
}

// ============================================================================
// Helper Functions
// ============================================================================

// Convert Lean String to std::string
static std::string lean_string_to_std(b_lean_obj_arg s) {
    return std::string(lean_string_cstr(s), lean_string_size(s) - 1);
}

// Convert Lean ByteArray to gRPC ByteBuffer
static grpc::ByteBuffer lean_bytearray_to_bytebuffer(b_lean_obj_arg arr) {
    size_t size = lean_sarray_size(arr);
    uint8_t* data = lean_sarray_cptr(arr);
    grpc::Slice slice(data, size);
    return grpc::ByteBuffer(&slice, 1);
}

// Convert gRPC ByteBuffer to Lean ByteArray
static lean_object* bytebuffer_to_lean_bytearray(const grpc::ByteBuffer& buf) {
    std::vector<grpc::Slice> slices;
    buf.Dump(&slices);

    size_t total_size = 0;
    for (const auto& slice : slices) {
        total_size += slice.size();
    }

    lean_object* arr = lean_alloc_sarray(1, total_size, total_size);
    uint8_t* ptr = lean_sarray_cptr(arr);

    for (const auto& slice : slices) {
        memcpy(ptr, slice.begin(), slice.size());
        ptr += slice.size();
    }

    return arr;
}

// Create a Lean IO result (ok)
static lean_object* mk_io_result_ok(lean_object* val) {
    return lean_io_result_mk_ok(val);
}

// Create a Lean IO error
static lean_object* mk_io_error(const std::string& msg) {
    return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg.c_str())));
}

// Create a Lean pair (α × β)
static lean_object* mk_pair(lean_object* fst, lean_object* snd) {
    lean_object* pair = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(pair, 0, fst);
    lean_ctor_set(pair, 1, snd);
    return pair;
}

// Create Except.ok
static lean_object* mk_except_ok(lean_object* val) {
    lean_object* result = lean_alloc_ctor(1, 1, 0);  // Except.ok constructor
    lean_ctor_set(result, 0, val);
    return result;
}

// Create Except.error with GrpcError
// GrpcError : StatusCode × String × Option ByteArray
static lean_object* mk_except_error(const grpc::Status& status) {
    // StatusCode is a simple enum (UInt8-like after boxing)
    lean_object* code = lean_box(static_cast<unsigned>(status.error_code()));

    // Error message
    lean_object* msg = lean_mk_string(status.error_message().c_str());

    // Details (Option ByteArray) - for now, always none
    lean_object* details = lean_box(0);  // Option.none

    // Create GrpcError structure
    lean_object* grpc_error = lean_alloc_ctor(0, 3, 0);
    lean_ctor_set(grpc_error, 0, code);
    lean_ctor_set(grpc_error, 1, msg);
    lean_ctor_set(grpc_error, 2, details);

    // Wrap in Except.error
    lean_object* result = lean_alloc_ctor(0, 1, 0);  // Except.error constructor
    lean_ctor_set(result, 0, grpc_error);
    return result;
}

// Create Lean Option.some
static lean_object* mk_option_some(lean_object* val) {
    lean_object* opt = lean_alloc_ctor(1, 1, 0);  // Option.some
    lean_ctor_set(opt, 0, val);
    return opt;
}

// Create Lean Option.none
static lean_object* mk_option_none() {
    return lean_box(0);  // Option.none
}

// Convert Lean metadata array to gRPC metadata
static void apply_metadata(grpc::ClientContext* ctx, b_lean_obj_arg metadata) {
    size_t len = lean_array_size(metadata);
    for (size_t i = 0; i < len; i++) {
        lean_object* pair = lean_array_get_core(metadata, i);
        lean_object* key = lean_ctor_get(pair, 0);
        lean_object* val = lean_ctor_get(pair, 1);
        ctx->AddMetadata(lean_string_to_std(key), lean_string_to_std(val));
    }
}

// Convert gRPC trailing metadata to Lean array
static lean_object* trailing_metadata_to_lean(
    const std::multimap<grpc::string_ref, grpc::string_ref>& metadata
) {
    lean_object* arr = lean_mk_empty_array();
    for (const auto& [key, val] : metadata) {
        lean_object* k = lean_mk_string_from_bytes(key.data(), key.size());
        lean_object* v = lean_mk_string_from_bytes(val.data(), val.size());
        lean_object* pair = mk_pair(k, v);
        arr = lean_array_push(arr, pair);
    }
    return arr;
}

// Apply timeout to context
static void apply_timeout(grpc::ClientContext* ctx, uint64_t timeout_ms) {
    if (timeout_ms > 0) {
        ctx->set_deadline(std::chrono::system_clock::now() +
                         std::chrono::milliseconds(timeout_ms));
    }
}

// Create Lean Status structure
static lean_object* mk_status(const grpc::Status& status) {
    lean_object* code = lean_box(static_cast<unsigned>(status.error_code()));
    lean_object* msg = lean_mk_string(status.error_message().c_str());
    lean_object* s = lean_alloc_ctor(0, 2, 0);
    lean_ctor_set(s, 0, code);
    lean_ctor_set(s, 1, msg);
    return s;
}

// ============================================================================
// Channel Operations
// ============================================================================

extern "C" LEAN_EXPORT lean_obj_res legate_channel_create_insecure(
    b_lean_obj_arg target,
    lean_obj_arg /* world */
) {
    if (!g_initialized.load()) {
        legate_init(lean_box(0));
    }

    std::string target_str = lean_string_to_std(target);
    auto channel = grpc::CreateChannel(target_str, grpc::InsecureChannelCredentials());

    auto* wrapper = new ChannelWrapper(channel);
    lean_object* obj = lean_alloc_external(g_channel_class, wrapper);
    return mk_io_result_ok(obj);
}

extern "C" LEAN_EXPORT lean_obj_res legate_channel_create_secure(
    b_lean_obj_arg target,
    b_lean_obj_arg root_certs,
    b_lean_obj_arg private_key,
    b_lean_obj_arg cert_chain,
    lean_obj_arg /* world */
) {
    if (!g_initialized.load()) {
        legate_init(lean_box(0));
    }

    std::string target_str = lean_string_to_std(target);
    std::string root_certs_str = lean_string_to_std(root_certs);
    std::string private_key_str = lean_string_to_std(private_key);
    std::string cert_chain_str = lean_string_to_std(cert_chain);

    grpc::SslCredentialsOptions opts;
    if (!root_certs_str.empty()) {
        opts.pem_root_certs = root_certs_str;
    }
    if (!private_key_str.empty()) {
        opts.pem_private_key = private_key_str;
    }
    if (!cert_chain_str.empty()) {
        opts.pem_cert_chain = cert_chain_str;
    }

    auto creds = grpc::SslCredentials(opts);
    auto channel = grpc::CreateChannel(target_str, creds);

    auto* wrapper = new ChannelWrapper(channel);
    lean_object* obj = lean_alloc_external(g_channel_class, wrapper);
    return mk_io_result_ok(obj);
}

extern "C" LEAN_EXPORT lean_obj_res legate_channel_get_state(
    b_lean_obj_arg channel,
    uint8_t try_connect,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ChannelWrapper*>(lean_get_external_data(channel));
    grpc_connectivity_state state = wrapper->channel->GetState(try_connect != 0);
    return mk_io_result_ok(lean_box(static_cast<unsigned>(state)));
}

// ============================================================================
// Unary Call
// ============================================================================

extern "C" LEAN_EXPORT lean_obj_res legate_unary_call(
    b_lean_obj_arg channel,
    b_lean_obj_arg method,
    b_lean_obj_arg request,
    uint64_t timeout_ms,
    b_lean_obj_arg metadata,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ChannelWrapper*>(lean_get_external_data(channel));
    std::string method_str = lean_string_to_std(method);

    grpc::ClientContext context;
    apply_timeout(&context, timeout_ms);
    apply_metadata(&context, metadata);

    grpc::ByteBuffer request_buf = lean_bytearray_to_bytebuffer(request);
    grpc::ByteBuffer response_buf;

    // Use async unary call with completion queue for synchronous behavior
    grpc::CompletionQueue cq;
    grpc::Status status;
    auto reader = wrapper->stub->PrepareUnaryCall(&context, method_str, request_buf, &cq);
    reader->StartCall();
    reader->Finish(&response_buf, &status, reinterpret_cast<void*>(1));

    void* tag;
    bool ok;
    cq.Next(&tag, &ok);

    if (status.ok()) {
        lean_object* response = bytebuffer_to_lean_bytearray(response_buf);
        lean_object* trailers = trailing_metadata_to_lean(context.GetServerTrailingMetadata());
        lean_object* pair = mk_pair(response, trailers);
        return mk_io_result_ok(mk_except_ok(pair));
    } else {
        return mk_io_result_ok(mk_except_error(status));
    }
}

// ============================================================================
// Client Streaming Call
// ============================================================================

extern "C" LEAN_EXPORT lean_obj_res legate_client_streaming_call_start(
    b_lean_obj_arg channel,
    b_lean_obj_arg method,
    uint64_t timeout_ms,
    b_lean_obj_arg metadata,
    lean_obj_arg /* world */
) {
    auto* ch_wrapper = static_cast<ChannelWrapper*>(lean_get_external_data(channel));
    std::string method_str = lean_string_to_std(method);

    auto* wrapper = new ClientStreamWrapper();
    apply_timeout(wrapper->context.get(), timeout_ms);
    apply_metadata(wrapper->context.get(), metadata);

    // Use PrepareCall which returns a bidirectional stream
    wrapper->stream = ch_wrapper->stub->PrepareCall(
        wrapper->context.get(), method_str, &wrapper->cq);

    wrapper->stream->StartCall(reinterpret_cast<void*>(1));

    // Wait for start
    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);
    if (!ok) {
        delete wrapper;
        grpc::Status failed(grpc::StatusCode::INTERNAL, "Failed to start client streaming call");
        return mk_io_result_ok(mk_except_error(failed));
    }

    lean_object* obj = lean_alloc_external(g_client_stream_class, wrapper);
    return mk_io_result_ok(mk_except_ok(obj));
}

extern "C" LEAN_EXPORT lean_obj_res legate_client_stream_write(
    b_lean_obj_arg stream,
    b_lean_obj_arg data,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ClientStreamWrapper*>(lean_get_external_data(stream));

    if (wrapper->writes_done) {
        grpc::Status err(grpc::StatusCode::FAILED_PRECONDITION, "Stream writes already done");
        return mk_io_result_ok(mk_except_error(err));
    }

    grpc::ByteBuffer buf = lean_bytearray_to_bytebuffer(data);
    wrapper->stream->Write(buf, reinterpret_cast<void*>(2));

    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);
    if (!ok) {
        grpc::Status err(grpc::StatusCode::INTERNAL, "Write failed");
        return mk_io_result_ok(mk_except_error(err));
    }

    return mk_io_result_ok(mk_except_ok(lean_box(0)));
}

extern "C" LEAN_EXPORT lean_obj_res legate_client_stream_writes_done(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ClientStreamWrapper*>(lean_get_external_data(stream));

    if (wrapper->writes_done) {
        return mk_io_result_ok(mk_except_ok(lean_box(0)));
    }

    wrapper->stream->WritesDone(reinterpret_cast<void*>(3));
    wrapper->writes_done = true;

    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);
    // WritesDone might return !ok but that's often fine

    return mk_io_result_ok(mk_except_ok(lean_box(0)));
}

extern "C" LEAN_EXPORT lean_obj_res legate_client_stream_finish(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ClientStreamWrapper*>(lean_get_external_data(stream));

    if (!wrapper->writes_done) {
        legate_client_stream_writes_done(stream, lean_box(0));
    }

    void* tag;
    bool ok;

    // Read the response from the server
    wrapper->stream->Read(&wrapper->response, reinterpret_cast<void*>(4));
    wrapper->cq.Next(&tag, &ok);

    // Finish the call
    wrapper->stream->Finish(&wrapper->status, reinterpret_cast<void*>(5));
    wrapper->cq.Next(&tag, &ok);

    if (wrapper->status.ok()) {
        lean_object* response = bytebuffer_to_lean_bytearray(wrapper->response);
        lean_object* trailers = trailing_metadata_to_lean(
            wrapper->context->GetServerTrailingMetadata());
        lean_object* status = mk_status(wrapper->status);
        // Lean tuple (A × B × C) is (A × (B × C)), so nest the pairs
        lean_object* inner = mk_pair(trailers, status);
        lean_object* result = mk_pair(response, inner);
        return mk_io_result_ok(mk_except_ok(result));
    } else {
        return mk_io_result_ok(mk_except_error(wrapper->status));
    }
}

// ============================================================================
// Server Streaming Call
// ============================================================================

extern "C" LEAN_EXPORT lean_obj_res legate_server_streaming_call_start(
    b_lean_obj_arg channel,
    b_lean_obj_arg method,
    b_lean_obj_arg request,
    uint64_t timeout_ms,
    b_lean_obj_arg metadata,
    lean_obj_arg /* world */
) {
    auto* ch_wrapper = static_cast<ChannelWrapper*>(lean_get_external_data(channel));
    std::string method_str = lean_string_to_std(method);

    auto* wrapper = new ServerStreamWrapper();
    apply_timeout(wrapper->context.get(), timeout_ms);
    apply_metadata(wrapper->context.get(), metadata);

    grpc::ByteBuffer request_buf = lean_bytearray_to_bytebuffer(request);

    wrapper->stream = ch_wrapper->stub->PrepareCall(
        wrapper->context.get(), method_str, &wrapper->cq);

    wrapper->stream->StartCall(reinterpret_cast<void*>(1));

    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);
    if (!ok) {
        delete wrapper;
        grpc::Status failed(grpc::StatusCode::INTERNAL, "Failed to start server streaming call");
        return mk_io_result_ok(mk_except_error(failed));
    }

    // Send the request
    wrapper->stream->Write(request_buf, reinterpret_cast<void*>(2));
    wrapper->cq.Next(&tag, &ok);
    if (!ok) {
        delete wrapper;
        grpc::Status failed(grpc::StatusCode::INTERNAL, "Failed to write request");
        return mk_io_result_ok(mk_except_error(failed));
    }

    // Signal writes done (server streaming means we only send one message)
    wrapper->stream->WritesDone(reinterpret_cast<void*>(3));
    wrapper->cq.Next(&tag, &ok);

    lean_object* obj = lean_alloc_external(g_server_stream_class, wrapper);
    return mk_io_result_ok(mk_except_ok(obj));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_stream_read(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerStreamWrapper*>(lean_get_external_data(stream));

    if (wrapper->finished) {
        return mk_io_result_ok(mk_except_ok(mk_option_none()));
    }

    grpc::ByteBuffer response;
    wrapper->stream->Read(&response, reinterpret_cast<void*>(4));

    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);

    if (!ok) {
        // Stream ended
        wrapper->finished = true;
        return mk_io_result_ok(mk_except_ok(mk_option_none()));
    }

    lean_object* data = bytebuffer_to_lean_bytearray(response);
    return mk_io_result_ok(mk_except_ok(mk_option_some(data)));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_stream_get_trailers(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerStreamWrapper*>(lean_get_external_data(stream));
    lean_object* trailers = trailing_metadata_to_lean(
        wrapper->context->GetServerTrailingMetadata());
    return mk_io_result_ok(trailers);
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_stream_get_status(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerStreamWrapper*>(lean_get_external_data(stream));

    if (!wrapper->finished) {
        // Need to finish first
        wrapper->stream->Finish(&wrapper->status, reinterpret_cast<void*>(5));
        void* tag;
        bool ok;
        wrapper->cq.Next(&tag, &ok);
        wrapper->finished = true;
    }

    return mk_io_result_ok(mk_status(wrapper->status));
}

// ============================================================================
// Bidirectional Streaming Call
// ============================================================================

extern "C" LEAN_EXPORT lean_obj_res legate_bidi_streaming_call_start(
    b_lean_obj_arg channel,
    b_lean_obj_arg method,
    uint64_t timeout_ms,
    b_lean_obj_arg metadata,
    lean_obj_arg /* world */
) {
    auto* ch_wrapper = static_cast<ChannelWrapper*>(lean_get_external_data(channel));
    std::string method_str = lean_string_to_std(method);

    auto* wrapper = new BidiStreamWrapper();
    apply_timeout(wrapper->context.get(), timeout_ms);
    apply_metadata(wrapper->context.get(), metadata);

    wrapper->stream = ch_wrapper->stub->PrepareCall(
        wrapper->context.get(), method_str, &wrapper->cq);

    wrapper->stream->StartCall(reinterpret_cast<void*>(1));

    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);
    if (!ok) {
        delete wrapper;
        grpc::Status failed(grpc::StatusCode::INTERNAL, "Failed to start bidi streaming call");
        return mk_io_result_ok(mk_except_error(failed));
    }

    lean_object* obj = lean_alloc_external(g_bidi_stream_class, wrapper);
    return mk_io_result_ok(mk_except_ok(obj));
}

extern "C" LEAN_EXPORT lean_obj_res legate_bidi_stream_write(
    b_lean_obj_arg stream,
    b_lean_obj_arg data,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<BidiStreamWrapper*>(lean_get_external_data(stream));

    if (wrapper->writes_done) {
        grpc::Status err(grpc::StatusCode::FAILED_PRECONDITION, "Stream writes already done");
        return mk_io_result_ok(mk_except_error(err));
    }

    grpc::ByteBuffer buf = lean_bytearray_to_bytebuffer(data);
    wrapper->stream->Write(buf, reinterpret_cast<void*>(2));

    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);
    if (!ok) {
        grpc::Status err(grpc::StatusCode::INTERNAL, "Write failed");
        return mk_io_result_ok(mk_except_error(err));
    }

    return mk_io_result_ok(mk_except_ok(lean_box(0)));
}

extern "C" LEAN_EXPORT lean_obj_res legate_bidi_stream_writes_done(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<BidiStreamWrapper*>(lean_get_external_data(stream));

    if (wrapper->writes_done) {
        return mk_io_result_ok(mk_except_ok(lean_box(0)));
    }

    wrapper->stream->WritesDone(reinterpret_cast<void*>(3));
    wrapper->writes_done = true;

    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);

    return mk_io_result_ok(mk_except_ok(lean_box(0)));
}

extern "C" LEAN_EXPORT lean_obj_res legate_bidi_stream_read(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<BidiStreamWrapper*>(lean_get_external_data(stream));

    if (wrapper->read_finished) {
        return mk_io_result_ok(mk_except_ok(mk_option_none()));
    }

    grpc::ByteBuffer response;
    wrapper->stream->Read(&response, reinterpret_cast<void*>(4));

    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);

    if (!ok) {
        wrapper->read_finished = true;
        return mk_io_result_ok(mk_except_ok(mk_option_none()));
    }

    lean_object* data = bytebuffer_to_lean_bytearray(response);
    return mk_io_result_ok(mk_except_ok(mk_option_some(data)));
}

extern "C" LEAN_EXPORT lean_obj_res legate_bidi_stream_get_status(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<BidiStreamWrapper*>(lean_get_external_data(stream));

    if (!wrapper->writes_done) {
        legate_bidi_stream_writes_done(stream, lean_box(0));
    }

    wrapper->stream->Finish(&wrapper->status, reinterpret_cast<void*>(5));
    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);

    return mk_io_result_ok(mk_status(wrapper->status));
}

// ============================================================================
// Server Operations
// ============================================================================

// Helper to convert grpc metadata to Lean array
static lean_object* server_metadata_to_lean(
    const std::multimap<grpc::string_ref, grpc::string_ref>& metadata
) {
    lean_object* arr = lean_mk_empty_array();
    for (const auto& [key, val] : metadata) {
        lean_object* k = lean_mk_string_from_bytes(key.data(), key.size());
        lean_object* v = lean_mk_string_from_bytes(val.data(), val.size());
        lean_object* pair = mk_pair(k, v);
        arr = lean_array_push(arr, pair);
    }
    return arr;
}

// Helper to extract result from Except GrpcError α
// Returns true if ok, false if error
// On success, sets *result to the ok value
// On error, sets *error_code and *error_msg
static bool extract_except_result(
    lean_object* except_result,
    lean_object** result,
    int* error_code,
    std::string* error_msg
) {
    // Except.error is ctor 0, Except.ok is ctor 1
    unsigned tag = lean_obj_tag(except_result);
    if (tag == 1) {
        // Except.ok - extract the value
        *result = lean_ctor_get(except_result, 0);
        lean_inc(*result);
        return true;
    } else {
        // Except.error - extract GrpcError
        lean_object* grpc_error = lean_ctor_get(except_result, 0);
        lean_object* code_obj = lean_ctor_get(grpc_error, 0);
        lean_object* msg_obj = lean_ctor_get(grpc_error, 1);
        *error_code = lean_unbox(code_obj);
        *error_msg = lean_string_cstr(msg_obj);
        return false;
    }
}

// Process a unary call - called from the server polling loop
static void process_unary_call(ServerCallContext* call_ctx) {
    auto* handler = call_ctx->handler;
    if (!handler || !handler->handler) {
        // No handler - send unimplemented error
        call_ctx->stream.Finish(
            grpc::Status(grpc::StatusCode::UNIMPLEMENTED, "Method not implemented"),
            call_ctx);
        call_ctx->state = ServerCallContext::State::FINISHING;
        return;
    }

    // Convert request to Lean ByteArray
    lean_object* request_bytes = bytebuffer_to_lean_bytearray(call_ctx->request);

    // Convert metadata to Lean array
    lean_object* metadata = server_metadata_to_lean(call_ctx->ctx.client_metadata());

    // Get method name
    lean_object* method_str = lean_mk_string(call_ctx->ctx.method().c_str());

    // Call the Lean handler: String → Metadata → ByteArray → IO (Except GrpcError (ByteArray × Metadata))
    // We need to apply arguments one by one
    lean_object* handler_obj = handler->handler;
    lean_inc(handler_obj);

    // Apply method string
    lean_object* h1 = lean_apply_1(handler_obj, method_str);
    // Apply metadata
    lean_object* h2 = lean_apply_1(h1, metadata);
    // Apply request bytes
    lean_object* h3 = lean_apply_1(h2, request_bytes);
    // Execute the IO action
    lean_object* io_result = lean_io_result_mk_ok(lean_apply_1(h3, lean_io_mk_world()));

    // Check if IO succeeded
    if (lean_io_result_is_error(io_result)) {
        lean_object* error = lean_io_result_get_error(io_result);
        std::string err_msg = "IO error in handler";
        if (lean_is_scalar(error)) {
            err_msg = "Unknown IO error";
        }
        lean_dec(io_result);
        call_ctx->stream.Finish(
            grpc::Status(grpc::StatusCode::INTERNAL, err_msg),
            call_ctx);
        call_ctx->state = ServerCallContext::State::FINISHING;
        return;
    }

    // Get the Except result
    lean_object* except_result = lean_io_result_get_value(io_result);

    lean_object* ok_value = nullptr;
    int error_code = 0;
    std::string error_msg;

    if (extract_except_result(except_result, &ok_value, &error_code, &error_msg)) {
        // Success - ok_value is (ByteArray × Metadata)
        lean_object* response_bytes = lean_ctor_get(ok_value, 0);
        // lean_object* trailing_metadata = lean_ctor_get(ok_value, 1);

        // Convert response to ByteBuffer
        size_t size = lean_sarray_size(response_bytes);
        uint8_t* data = lean_sarray_cptr(response_bytes);
        grpc::Slice slice(data, size);
        call_ctx->response = grpc::ByteBuffer(&slice, 1);

        lean_dec(ok_value);

        // Write response
        call_ctx->stream.Write(call_ctx->response, call_ctx);
        call_ctx->state = ServerCallContext::State::WRITING;
    } else {
        // Error
        lean_dec(io_result);
        call_ctx->stream.Finish(
            grpc::Status(static_cast<grpc::StatusCode>(error_code), error_msg),
            call_ctx);
        call_ctx->state = ServerCallContext::State::FINISHING;
        return;
    }

    lean_dec(io_result);
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_builder_new(lean_obj_arg /* world */) {
    if (!g_initialized.load()) {
        legate_init(lean_box(0));
    }

    auto* wrapper = new ServerBuilderWrapper();
    lean_object* obj = lean_alloc_external(g_server_builder_class, wrapper);
    return mk_io_result_ok(obj);
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_builder_add_listening_port(
    b_lean_obj_arg builder,
    b_lean_obj_arg addr,
    uint8_t use_tls,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerBuilderWrapper*>(lean_get_external_data(builder));
    std::string addr_str = lean_string_to_std(addr);

    if (use_tls) {
        wrapper->builder->AddListeningPort(
            addr_str,
            grpc::InsecureServerCredentials(),  // TODO: proper TLS support
            &wrapper->selected_port);
    } else {
        wrapper->builder->AddListeningPort(
            addr_str, grpc::InsecureServerCredentials(), &wrapper->selected_port);
    }

    return mk_io_result_ok(lean_box(static_cast<unsigned>(wrapper->selected_port)));
}

// Register a unary handler
extern "C" LEAN_EXPORT lean_obj_res legate_server_register_unary(
    b_lean_obj_arg builder,
    b_lean_obj_arg method,
    lean_obj_arg handler,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerBuilderWrapper*>(lean_get_external_data(builder));

    RegisteredHandler h;
    h.method = lean_string_to_std(method);
    h.type = HandlerType::UNARY;
    h.handler = handler;
    lean_inc(handler);

    wrapper->handlers.push_back(std::move(h));
    return mk_io_result_ok(lean_box(0));
}

// Register a client streaming handler
extern "C" LEAN_EXPORT lean_obj_res legate_server_register_client_streaming(
    b_lean_obj_arg builder,
    b_lean_obj_arg method,
    lean_obj_arg handler,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerBuilderWrapper*>(lean_get_external_data(builder));

    RegisteredHandler h;
    h.method = lean_string_to_std(method);
    h.type = HandlerType::CLIENT_STREAMING;
    h.handler = handler;
    lean_inc(handler);

    wrapper->handlers.push_back(std::move(h));
    return mk_io_result_ok(lean_box(0));
}

// Register a server streaming handler
extern "C" LEAN_EXPORT lean_obj_res legate_server_register_server_streaming(
    b_lean_obj_arg builder,
    b_lean_obj_arg method,
    lean_obj_arg handler,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerBuilderWrapper*>(lean_get_external_data(builder));

    RegisteredHandler h;
    h.method = lean_string_to_std(method);
    h.type = HandlerType::SERVER_STREAMING;
    h.handler = handler;
    lean_inc(handler);

    wrapper->handlers.push_back(std::move(h));
    return mk_io_result_ok(lean_box(0));
}

// Register a bidirectional streaming handler
extern "C" LEAN_EXPORT lean_obj_res legate_server_register_bidi_streaming(
    b_lean_obj_arg builder,
    b_lean_obj_arg method,
    lean_obj_arg handler,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerBuilderWrapper*>(lean_get_external_data(builder));

    RegisteredHandler h;
    h.method = lean_string_to_std(method);
    h.type = HandlerType::BIDI_STREAMING;
    h.handler = handler;
    lean_inc(handler);

    wrapper->handlers.push_back(std::move(h));
    return mk_io_result_ok(lean_box(0));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_builder_build(
    b_lean_obj_arg builder,
    lean_obj_arg /* world */
) {
    auto* b_wrapper = static_cast<ServerBuilderWrapper*>(lean_get_external_data(builder));

    auto* s_wrapper = new ServerWrapper();

    // Store service reference for RequestCall
    s_wrapper->service = &b_wrapper->service;

    // Add completion queue
    s_wrapper->cq = b_wrapper->builder->AddCompletionQueue();

    // Build the server
    s_wrapper->server = b_wrapper->builder->BuildAndStart();
    if (!s_wrapper->server) {
        delete s_wrapper;
        return mk_io_error("Failed to build server");
    }

    // Move handlers - use explicit loop since we deleted copy operations
    for (auto& h : b_wrapper->handlers) {
        s_wrapper->handlers.push_back(std::move(h));
    }
    b_wrapper->handlers.clear();

    lean_object* obj = lean_alloc_external(g_server_class, s_wrapper);
    return mk_io_result_ok(obj);
}

// Start accepting a new call
static void start_accepting(ServerWrapper* wrapper, grpc::ServerCompletionQueue* cq) {
    auto* call_ctx = new ServerCallContext(wrapper);
    wrapper->service->RequestCall(
        &call_ctx->ctx,
        &call_ctx->stream,
        cq, cq,
        call_ctx);
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_start(
    b_lean_obj_arg server,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerWrapper*>(lean_get_external_data(server));

    if (wrapper->running.load()) {
        return mk_io_result_ok(lean_box(0));
    }

    wrapper->running.store(true);

    // Start accepting first call
    start_accepting(wrapper, wrapper->cq.get());

    // Start the polling thread for handling requests
    wrapper->polling_thread = std::thread([wrapper]() {
        while (wrapper->running.load()) {
            void* tag;
            bool ok;
            auto deadline = std::chrono::system_clock::now() + std::chrono::milliseconds(100);
            auto status = wrapper->cq->AsyncNext(&tag, &ok, deadline);

            if (status == grpc::CompletionQueue::SHUTDOWN) {
                break;
            }

            if (status == grpc::CompletionQueue::GOT_EVENT) {
                auto* call_ctx = static_cast<ServerCallContext*>(tag);

                if (!ok) {
                    // Call was cancelled or failed
                    delete call_ctx;
                    continue;
                }

                switch (call_ctx->state) {
                    case ServerCallContext::State::ACCEPTING: {
                        // New call accepted - start accepting another
                        start_accepting(wrapper, wrapper->cq.get());

                        // Find handler for this method
                        std::string method = call_ctx->ctx.method();
                        call_ctx->handler = wrapper->findHandler(method);

                        if (call_ctx->handler && call_ctx->handler->type == HandlerType::UNARY) {
                            // For unary, read the request
                            call_ctx->stream.Read(&call_ctx->request, call_ctx);
                            call_ctx->state = ServerCallContext::State::READING;
                        } else {
                            // Unsupported handler type or not found
                            call_ctx->stream.Finish(
                                grpc::Status(grpc::StatusCode::UNIMPLEMENTED,
                                    "Method not implemented or handler type not supported"),
                                call_ctx);
                            call_ctx->state = ServerCallContext::State::FINISHING;
                        }
                        break;
                    }

                    case ServerCallContext::State::READING: {
                        // Request received, process it
                        call_ctx->state = ServerCallContext::State::PROCESSING;
                        process_unary_call(call_ctx);
                        break;
                    }

                    case ServerCallContext::State::WRITING: {
                        // Response written, finish the call
                        call_ctx->stream.Finish(grpc::Status::OK, call_ctx);
                        call_ctx->state = ServerCallContext::State::FINISHING;
                        break;
                    }

                    case ServerCallContext::State::FINISHING: {
                        // Call finished, clean up
                        call_ctx->state = ServerCallContext::State::DONE;
                        delete call_ctx;
                        break;
                    }

                    default:
                        delete call_ctx;
                        break;
                }
            }
        }
    });

    return mk_io_result_ok(lean_box(0));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_wait(
    b_lean_obj_arg server,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerWrapper*>(lean_get_external_data(server));
    if (wrapper->server) {
        wrapper->server->Wait();
    }
    return mk_io_result_ok(lean_box(0));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_shutdown(
    b_lean_obj_arg server,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerWrapper*>(lean_get_external_data(server));

    wrapper->running.store(false);

    if (wrapper->server) {
        wrapper->server->Shutdown();
    }
    if (wrapper->cq) {
        wrapper->cq->Shutdown();
    }
    if (wrapper->polling_thread.joinable()) {
        wrapper->polling_thread.join();
    }

    return mk_io_result_ok(lean_box(0));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_shutdown_now(
    b_lean_obj_arg server,
    lean_obj_arg /* world */
) {
    return legate_server_shutdown(server, lean_box(0));
}
