#include "legate_ffi.h"

#include <grpcpp/grpcpp.h>
#include <grpcpp/generic/generic_stub.h>
#include <grpcpp/generic/async_generic_service.h>
#include <grpcpp/impl/client_unary_call.h>
#include <grpc/byte_buffer_reader.h>

#include <memory>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <string>
#include <vector>
#include <unordered_map>
#include <thread>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

// ============================================================================
// External Class Registration
// ============================================================================

static lean_external_class* g_channel_class = nullptr;
static lean_external_class* g_client_stream_class = nullptr;
static lean_external_class* g_server_stream_class = nullptr;
static lean_external_class* g_bidi_stream_class = nullptr;
static lean_external_class* g_server_builder_class = nullptr;
static lean_external_class* g_server_class = nullptr;
static lean_external_class* g_server_io_state_class = nullptr;
static lean_external_class* g_server_call_class = nullptr;

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
    bool initial_metadata_received = false;

    StreamWrapperBase() : context(std::make_unique<grpc::ClientContext>()) {}
    virtual ~StreamWrapperBase() = default;

    // Get initial metadata (response headers) - available after first read or finish
    const std::multimap<grpc::string_ref, grpc::string_ref>& getInitialMetadata() {
        return context->GetServerInitialMetadata();
    }
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
    bool read_finished = false;
    bool finished = false;
};

// Bidirectional streaming call wrapper
struct BidiStreamWrapper : StreamWrapperBase {
    std::unique_ptr<grpc::GenericClientAsyncReaderWriter> stream;
    grpc::CompletionQueue cq;
    bool writes_done = false;
    bool read_finished = false;
    bool finished = false;
};

// Forward declaration for call context (needed for server-side streaming callbacks).
struct ServerCallContext;

// State object used for server-side streaming handler callbacks (recv/send).
struct ServerIOState {
    ServerCallContext* call_ctx = nullptr;  // non-owning
    bool read_finished = false;

    explicit ServerIOState(ServerCallContext* c) : call_ctx(c) {}
};

struct ServerCallWrapper {
    grpc::GenericServerContext* ctx = nullptr;  // non-owning
    ServerCallContext* call_ctx = nullptr;      // non-owning
    ServerCallWrapper(grpc::GenericServerContext* c, ServerCallContext* cc) : ctx(c), call_ctx(cc) {}
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
    std::unique_ptr<grpc::AsyncGenericService> service;
    std::vector<int> reserved_fds;
    int selected_port = 0;

    ServerBuilderWrapper()
        : builder(std::make_unique<grpc::ServerBuilder>())
        , service(std::make_unique<grpc::AsyncGenericService>()) {
        builder->RegisterAsyncGenericService(service.get());
    }

    ~ServerBuilderWrapper() {
        for (int fd : reserved_fds) {
            if (fd != -1) ::close(fd);
        }
        reserved_fds.clear();
    }
};

struct ServerWrapper {
    std::unique_ptr<grpc::Server> server;
    std::unique_ptr<grpc::ServerCompletionQueue> cq;
    std::vector<RegisteredHandler> handlers;
    std::unique_ptr<grpc::AsyncGenericService> service;
    std::thread polling_thread;
    std::vector<std::thread> worker_threads;
    std::mutex work_mu;
    std::condition_variable work_cv;
    std::deque<ServerCallContext*> work_q;
    std::atomic<bool> running{false};

    RegisteredHandler* findHandler(const std::string& method) {
        for (auto& h : handlers) {
            if (h.method == method) {
                return &h;
            }
        }
        return nullptr;
    }

    ~ServerWrapper();
};

// Server call context for tracking async operations
struct ServerCallContext {
    grpc::GenericServerContext ctx;
    grpc::GenericServerAsyncReaderWriter stream;
    grpc::CompletionQueue call_cq;
    ServerWrapper* server;
    RegisteredHandler* handler;
    std::string method;
    int tag_read = 0;
    int tag_write = 0;
    int tag_finish = 0;
    int tag_done = 0;
    int tag_send_initial_metadata = 0;
    bool initial_metadata_sent = false;

    explicit ServerCallContext(ServerWrapper* s)
        : stream(&ctx), server(s), handler(nullptr) {}
};

ServerWrapper::~ServerWrapper() {
    // Always try to shut down and drain, even if the user already called
    // `legate_server_shutdown`, to ensure gRPC's CQ destructor invariants.
    running.store(false);
    if (server) server->Shutdown();
    if (cq) cq->Shutdown();
    if (polling_thread.joinable()) {
        polling_thread.join();
    }
    // Stop workers.
    work_cv.notify_all();
    for (auto& t : worker_threads) {
        if (t.joinable()) t.join();
    }
    worker_threads.clear();
    // Best-effort cleanup for any still-queued calls.
    {
        std::lock_guard<std::mutex> lock(work_mu);
        while (!work_q.empty()) {
            delete work_q.front();
            work_q.pop_front();
        }
    }
    // Drain server CQ before destruction (required by gRPC).
    if (cq) {
        void* tag = nullptr;
        bool ok = false;
        while (cq->Next(&tag, &ok)) {
            delete static_cast<ServerCallContext*>(tag);
        }
    }
    // Release resources now (and in a safe order) rather than relying on member
    // destruction order, which can interact poorly with gRPC CQ invariants.
    server.reset();
    cq.reset();
    // Handlers are cleaned up by their destructors
}

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

static void server_io_state_finalizer(void* ptr) {
    delete static_cast<ServerIOState*>(ptr);
}

static void server_call_finalizer(void* ptr) {
    delete static_cast<ServerCallWrapper*>(ptr);
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
        g_server_io_state_class = lean_register_external_class(server_io_state_finalizer, noop_foreach);
        g_server_call_class = lean_register_external_class(server_call_finalizer, noop_foreach);
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

// Note: Lean may pack scalars (like StatusCode) into the scalar part of a
// constructor object. We must mirror the actual generated layout instead of
// assuming every field is a pointer slot.

static lean_object* mk_except_error(const grpc::Status& status) {
    // GrpcError layout (from generated C):
    //   ctor tag 0, 2 pointer fields: (message, details), 1 scalar (uint8): code.
    uint8_t code = static_cast<uint8_t>(status.error_code());

    // Error message
    std::string msg_s = status.error_message();
    lean_object* msg = lean_mk_string(msg_s.c_str());

    // Details (Option ByteArray) - extract from grpc::Status::error_details()
    lean_object* details;
    std::string details_str = status.error_details();
    if (details_str.empty()) {
        details = lean_box(0);  // Option.none
    } else {
        // Create ByteArray from details string
        lean_object* ba = lean_alloc_sarray(1, details_str.size(), details_str.size());
        std::memcpy(lean_sarray_cptr(ba), details_str.data(), details_str.size());
        // Wrap in Option.some
        details = lean_alloc_ctor(1, 1, 0);
        lean_ctor_set(details, 0, ba);
    }

    // Create GrpcError structure
    lean_object* grpc_error = lean_alloc_ctor(0, 2, 1);
    lean_ctor_set(grpc_error, 0, msg);
    lean_ctor_set(grpc_error, 1, details);
    lean_ctor_set_uint8(grpc_error, sizeof(void*) * 2, code);

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

static bool debug_server_io_enabled() {
    const char* v = std::getenv("LEGATE_DEBUG_SERVER_IO");
    return v && v[0] != '\0' && v[0] != '0';
}

static bool cq_wait_for_tag(grpc::CompletionQueue& cq, void* expected_tag, bool* ok_out);

static unsigned server_worker_count() {
    const char* v = std::getenv("LEGATE_SERVER_WORKERS");
    if (v && v[0] != '\0') {
        char* end = nullptr;
        long n = std::strtol(v, &end, 10);
        if (end != v && n > 0 && n < 1024) return static_cast<unsigned>(n);
    }
    unsigned n = std::thread::hardware_concurrency();
    if (n == 0) n = 4;
    if (n < 2) n = 2;
    if (n > 8) n = 8;
    return n;
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_call_is_cancelled(
    b_lean_obj_arg call,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerCallWrapper*>(lean_get_external_data(call));
    bool cancelled = false;
    if (wrapper && wrapper->ctx) {
        cancelled = wrapper->ctx->IsCancelled();
    }
    return mk_io_result_ok(lean_box(cancelled ? 1 : 0));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_call_send_initial_metadata(
    b_lean_obj_arg call,
    b_lean_obj_arg metadata,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerCallWrapper*>(lean_get_external_data(call));
    if (!wrapper || !wrapper->ctx || !wrapper->call_ctx) {
        return mk_io_result_ok(lean_box(0));
    }

    auto* call_ctx = wrapper->call_ctx;
    if (call_ctx->initial_metadata_sent) {
        return mk_io_result_ok(lean_box(0));
    }

    // Add initial metadata entries.
    size_t len = lean_array_size(metadata);
    for (size_t i = 0; i < len; i++) {
        lean_object* pair = lean_array_get_core(metadata, i);
        lean_object* key = lean_ctor_get(pair, 0);
        lean_object* val = lean_ctor_get(pair, 1);
        wrapper->ctx->AddInitialMetadata(lean_string_to_std(key), lean_string_to_std(val));
    }

    // Send initial metadata on the stream.
    void* expected = &call_ctx->tag_send_initial_metadata;
    call_ctx->stream.SendInitialMetadata(expected);
    bool ok = false;
    cq_wait_for_tag(call_ctx->call_cq, expected, &ok);
    call_ctx->initial_metadata_sent = true;
    return mk_io_result_ok(lean_box(0));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_call_deadline_remaining_ms(
    b_lean_obj_arg call,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerCallWrapper*>(lean_get_external_data(call));
    if (!wrapper || !wrapper->ctx) {
        return mk_io_result_ok(mk_option_none());
    }

    auto deadline = wrapper->ctx->deadline();
    if (deadline == std::chrono::system_clock::time_point::max()) {
        return mk_io_result_ok(mk_option_none());
    }

    auto now = std::chrono::system_clock::now();
    auto diff = deadline - now;
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(diff).count();
    if (ms < 0) ms = 0;

    lean_object* boxed = lean_box_uint64(static_cast<uint64_t>(ms));
    return mk_io_result_ok(mk_option_some(boxed));
}

// IO callback: recv next message (IO (Option ByteArray))
static lean_obj_res legate_server_recv_impl(lean_obj_arg state_obj, lean_obj_arg /* world */) {
    auto* state = static_cast<ServerIOState*>(lean_get_external_data(state_obj));
    if (!state->call_ctx || state->read_finished) {
        state->read_finished = true;
        return mk_io_result_ok(mk_option_none());
    }

    grpc::ByteBuffer msg;
    if (debug_server_io_enabled()) {
        std::fprintf(stderr, "[legate] server recv: Read\n");
        std::fflush(stderr);
    }
    void* expected = &state->call_ctx->tag_read;
    state->call_ctx->stream.Read(&msg, expected);
    bool ok = false;
    cq_wait_for_tag(state->call_ctx->call_cq, expected, &ok);
    if (debug_server_io_enabled()) {
        std::fprintf(stderr, "[legate] server recv: Read done ok=%d tag=%p\n", ok ? 1 : 0, expected);
        std::fflush(stderr);
    }
    if (!ok) {
        state->read_finished = true;
        return mk_io_result_ok(mk_option_none());
    }

    lean_object* data = bytebuffer_to_lean_bytearray(msg);
    return mk_io_result_ok(mk_option_some(data));
}

// IO callback: record a response message (ByteArray → IO Unit)
static lean_obj_res legate_server_send_impl(
    lean_obj_arg state_obj,
    b_lean_obj_arg data,
    lean_obj_arg /* world */
) {
    auto* state = static_cast<ServerIOState*>(lean_get_external_data(state_obj));
    if (!state->call_ctx) {
        return mk_io_result_ok(lean_box(0));
    }

    // A write will trigger initial metadata to be sent if it hasn't been already.
    state->call_ctx->initial_metadata_sent = true;

    grpc::ByteBuffer buf = lean_bytearray_to_bytebuffer(data);
    if (debug_server_io_enabled()) {
        std::fprintf(stderr, "[legate] server send: Write\n");
        std::fflush(stderr);
    }
    void* expected = &state->call_ctx->tag_write;
    state->call_ctx->stream.Write(buf, expected);
    bool ok = false;
    cq_wait_for_tag(state->call_ctx->call_cq, expected, &ok);
    if (debug_server_io_enabled()) {
        std::fprintf(stderr, "[legate] server send: Write done ok=%d tag=%p\n", ok ? 1 : 0, expected);
        std::fflush(stderr);
    }
    return mk_io_result_ok(lean_box(0));
}

static lean_object* mk_server_recv_action(lean_object* state_obj) {
    // arity 2: (state, world) -> IO.Result (Option ByteArray)
    lean_object* c = lean_alloc_closure((void*)legate_server_recv_impl, 2, 1);
    lean_closure_set(c, 0, state_obj);
    return c;
}

static lean_object* mk_server_send_fn(lean_object* state_obj) {
    // arity 3: (state, ByteArray, world) -> IO.Result Unit
    lean_object* c = lean_alloc_closure((void*)legate_server_send_impl, 3, 1);
    lean_closure_set(c, 0, state_obj);
    return c;
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

// Convert gRPC metadata (trailing or initial) to Lean array
static lean_object* metadata_to_lean(
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

// Alias for backwards compatibility - convert gRPC trailing metadata to Lean array
static lean_object* trailing_metadata_to_lean(
    const std::multimap<grpc::string_ref, grpc::string_ref>& metadata
) {
    return metadata_to_lean(metadata);
}

// Convert gRPC initial metadata (response headers) to Lean array
static lean_object* initial_metadata_to_lean(
    const std::multimap<grpc::string_ref, grpc::string_ref>& metadata
) {
    return metadata_to_lean(metadata);
}

// Apply timeout to context
static void apply_timeout(grpc::ClientContext* ctx, uint64_t timeout_ms) {
    if (timeout_ms > 0) {
        ctx->set_deadline(std::chrono::system_clock::now() +
                         std::chrono::milliseconds(timeout_ms));
    }
}

// ============================================================================
// Server port helpers
// ============================================================================

static bool split_host_port(const std::string& addr_uri, std::string* prefix,
                            std::string* host, int* port) {
    *prefix = "";
    std::string hostport = addr_uri;
    size_t scheme_pos = addr_uri.find(":///");
    if (scheme_pos != std::string::npos) {
        *prefix = addr_uri.substr(0, scheme_pos + 4); // include ":///"
        hostport = addr_uri.substr(scheme_pos + 4);
    }

    if (hostport.empty()) return false;

    if (hostport.front() == '[') {
        size_t close = hostport.find(']');
        if (close == std::string::npos) return false;
        if (close + 2 > hostport.size() || hostport[close + 1] != ':') return false;
        *host = hostport.substr(1, close - 1);
        std::string port_s = hostport.substr(close + 2);
        char* end = nullptr;
        long p = std::strtol(port_s.c_str(), &end, 10);
        if (end == nullptr || *end != '\0' || p < 0 || p > 65535) return false;
        *port = static_cast<int>(p);
        return true;
    }

    size_t colon = hostport.rfind(':');
    if (colon == std::string::npos) return false;
    *host = hostport.substr(0, colon);
    std::string port_s = hostport.substr(colon + 1);
    char* end = nullptr;
    long p = std::strtol(port_s.c_str(), &end, 10);
    if (end == nullptr || *end != '\0' || p < 0 || p > 65535) return false;
    *port = static_cast<int>(p);
    return true;
}

static std::string join_host_port(const std::string& prefix, const std::string& host, int port) {
    std::string port_s = std::to_string(port);
    if (host.find(':') != std::string::npos) {
        return prefix + "[" + host + "]:" + port_s;
    }
    return prefix + host + ":" + port_s;
}

static int reserve_tcp_port(const std::string& host, int* out_port) {
    *out_port = 0;
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;

    struct addrinfo* res = nullptr;
    int rc = getaddrinfo(host.empty() ? nullptr : host.c_str(), "0", &hints, &res);
    if (rc != 0 || res == nullptr) return -1;

    int reserved_fd = -1;
    for (struct addrinfo* ai = res; ai != nullptr; ai = ai->ai_next) {
        int fd = ::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;

        int one = 1;
        (void)::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        if (::bind(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            struct sockaddr_storage ss;
            socklen_t slen = sizeof(ss);
            if (::getsockname(fd, reinterpret_cast<struct sockaddr*>(&ss), &slen) == 0) {
                if (ss.ss_family == AF_INET) {
                    auto* sin = reinterpret_cast<struct sockaddr_in*>(&ss);
                    *out_port = ntohs(sin->sin_port);
                } else if (ss.ss_family == AF_INET6) {
                    auto* sin6 = reinterpret_cast<struct sockaddr_in6*>(&ss);
                    *out_port = ntohs(sin6->sin6_port);
                }
            }
            if (*out_port != 0) {
                reserved_fd = fd;
                break;
            }
            ::close(fd);
            continue;
        }
        ::close(fd);
    }

    freeaddrinfo(res);
    return reserved_fd;
}

// Apply Lean Metadata (Array (String × String)) as trailing metadata on a server context
static void apply_trailing_metadata(grpc::ServerContext* ctx, b_lean_obj_arg metadata) {
    size_t len = lean_array_size(metadata);
    for (size_t i = 0; i < len; i++) {
        lean_object* pair = lean_array_get_core(metadata, i);
        lean_object* key = lean_ctor_get(pair, 0);
        lean_object* val = lean_ctor_get(pair, 1);
        ctx->AddTrailingMetadata(lean_string_to_std(key), lean_string_to_std(val));
    }
}

// Apply Lean Metadata (Array (String × String)) as initial metadata on a server context
static void apply_initial_metadata(grpc::ServerContext* ctx, b_lean_obj_arg metadata) {
    size_t len = lean_array_size(metadata);
    for (size_t i = 0; i < len; i++) {
        lean_object* pair = lean_array_get_core(metadata, i);
        lean_object* key = lean_ctor_get(pair, 0);
        lean_object* val = lean_ctor_get(pair, 1);
        ctx->AddInitialMetadata(lean_string_to_std(key), lean_string_to_std(val));
    }
}

// Create Lean Status structure
static lean_object* mk_status(const grpc::Status& status) {
    // Status layout (from generated C):
    //   ctor tag 0, 2 pointer fields: (message, details), 1 scalar (uint8): code.
    uint8_t code = static_cast<uint8_t>(status.error_code());
    std::string msg_s = status.error_message();
    lean_object* msg = lean_mk_string(msg_s.c_str());

    // Details (Option ByteArray) - extract from grpc::Status::error_details()
    lean_object* details;
    std::string details_str = status.error_details();
    if (details_str.empty()) {
        details = lean_box(0);  // Option.none
    } else {
        // Create ByteArray from details string
        lean_object* ba = lean_alloc_sarray(1, details_str.size(), details_str.size());
        std::memcpy(lean_sarray_cptr(ba), details_str.data(), details_str.size());
        // Wrap in Option.some
        details = lean_alloc_ctor(1, 1, 0);
        lean_ctor_set(details, 0, ba);
    }

    lean_object* s = lean_alloc_ctor(0, 2, 1);
    lean_ctor_set(s, 0, msg);
    lean_ctor_set(s, 1, details);
    lean_ctor_set_uint8(s, sizeof(void*) * 2, code);
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
    b_lean_obj_arg ssl_target_name_override,
    lean_obj_arg /* world */
) {
    if (!g_initialized.load()) {
        legate_init(lean_box(0));
    }

    std::string target_str = lean_string_to_std(target);
    std::string root_certs_str = lean_string_to_std(root_certs);
    std::string private_key_str = lean_string_to_std(private_key);
    std::string cert_chain_str = lean_string_to_std(cert_chain);
    std::string ssl_target_name_override_str = lean_string_to_std(ssl_target_name_override);

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
    grpc::ChannelArguments args;
    if (!ssl_target_name_override_str.empty()) {
        args.SetSslTargetNameOverride(ssl_target_name_override_str);
    }
    auto channel = grpc::CreateCustomChannel(target_str, creds, args);

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
    uint8_t wait_for_ready,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ChannelWrapper*>(lean_get_external_data(channel));
    std::string method_str = lean_string_to_std(method);

    grpc::ClientContext context;
    apply_timeout(&context, timeout_ms);
    apply_metadata(&context, metadata);
    context.set_wait_for_ready(wait_for_ready != 0);

    grpc::ByteBuffer request_buf = lean_bytearray_to_bytebuffer(request);
    grpc::ByteBuffer response_buf;

    grpc::Status status = grpc::internal::BlockingUnaryCall(
        wrapper->channel.get(),
        grpc::internal::RpcMethod(
            method_str.c_str(),
            /*suffix_for_stats=*/nullptr,
            grpc::internal::RpcMethod::NORMAL_RPC),
        &context,
        request_buf,
        &response_buf);

    if (status.ok()) {
        lean_object* response = bytebuffer_to_lean_bytearray(response_buf);
        lean_object* headers = initial_metadata_to_lean(context.GetServerInitialMetadata());
        lean_object* trailers = trailing_metadata_to_lean(context.GetServerTrailingMetadata());
        // Return (ByteArray × Metadata × Metadata) = (data, headers, trailers)
        // Lean tuple (A × B × C) is (A × (B × C)), so nest the pairs
        lean_object* inner = mk_pair(headers, trailers);
        lean_object* result = mk_pair(response, inner);
        return mk_io_result_ok(mk_except_ok(result));
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
    uint8_t wait_for_ready,
    lean_obj_arg /* world */
) {
    auto* ch_wrapper = static_cast<ChannelWrapper*>(lean_get_external_data(channel));
    std::string method_str = lean_string_to_std(method);

    auto* wrapper = new ClientStreamWrapper();
    apply_timeout(wrapper->context.get(), timeout_ms);
    apply_metadata(wrapper->context.get(), metadata);
    wrapper->context->set_wait_for_ready(wait_for_ready != 0);

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
        // Validate we constructed a proper nested tuple; if not, return a structured GrpcError
        // rather than letting the Lean side segfault when it tries to deconstruct it.
        if (inner == nullptr || result == nullptr || trailers == nullptr || response == nullptr || status == nullptr) {
            grpc::Status err(grpc::StatusCode::INTERNAL,
                             "legate_client_stream_finish: constructed null Lean object");
            return mk_io_result_ok(mk_except_error(err));
        }
        if (lean_ctor_get(inner, 0) == nullptr || lean_ctor_get(inner, 1) == nullptr) {
            grpc::Status err(grpc::StatusCode::INTERNAL,
                             "legate_client_stream_finish: constructed invalid (trailers, status) tuple");
            return mk_io_result_ok(mk_except_error(err));
        }

        return mk_io_result_ok(mk_except_ok(result));
    } else {
        return mk_io_result_ok(mk_except_error(wrapper->status));
    }
}

extern "C" LEAN_EXPORT lean_obj_res legate_client_stream_get_headers(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ClientStreamWrapper*>(lean_get_external_data(stream));
    // Initial metadata is available after first communication with server
    lean_object* headers = initial_metadata_to_lean(
        wrapper->context->GetServerInitialMetadata());
    return mk_io_result_ok(headers);
}

extern "C" LEAN_EXPORT lean_obj_res legate_client_stream_cancel(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ClientStreamWrapper*>(lean_get_external_data(stream));
    if (wrapper && wrapper->context) {
        wrapper->context->TryCancel();
    }
    return mk_io_result_ok(lean_box(0));
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
    uint8_t wait_for_ready,
    lean_obj_arg /* world */
) {
    auto* ch_wrapper = static_cast<ChannelWrapper*>(lean_get_external_data(channel));
    std::string method_str = lean_string_to_std(method);

    auto* wrapper = new ServerStreamWrapper();
    apply_timeout(wrapper->context.get(), timeout_ms);
    apply_metadata(wrapper->context.get(), metadata);
    wrapper->context->set_wait_for_ready(wait_for_ready != 0);

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

    if (wrapper->read_finished) {
        return mk_io_result_ok(mk_except_ok(mk_option_none()));
    }

    grpc::ByteBuffer response;
    wrapper->stream->Read(&response, reinterpret_cast<void*>(4));

    void* tag;
    bool ok;
    wrapper->cq.Next(&tag, &ok);

    if (!ok) {
        // Stream ended
        wrapper->read_finished = true;
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
    if (!wrapper->finished) {
        wrapper->stream->Finish(&wrapper->status, reinterpret_cast<void*>(5));
        void* tag;
        bool ok;
        wrapper->cq.Next(&tag, &ok);
        wrapper->finished = true;
    }
    lean_object* trailers = trailing_metadata_to_lean(
        wrapper->context->GetServerTrailingMetadata());
    return mk_io_result_ok(trailers);
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_stream_get_headers(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerStreamWrapper*>(lean_get_external_data(stream));
    // Initial metadata is available after first read or after call starts
    lean_object* headers = initial_metadata_to_lean(
        wrapper->context->GetServerInitialMetadata());
    return mk_io_result_ok(headers);
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_stream_get_status(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerStreamWrapper*>(lean_get_external_data(stream));

    if (!wrapper->finished) {
        wrapper->stream->Finish(&wrapper->status, reinterpret_cast<void*>(5));
        void* tag;
        bool ok;
        wrapper->cq.Next(&tag, &ok);
        wrapper->finished = true;
    }

    return mk_io_result_ok(mk_status(wrapper->status));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_stream_cancel(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerStreamWrapper*>(lean_get_external_data(stream));
    if (wrapper && wrapper->context) {
        wrapper->context->TryCancel();
    }
    return mk_io_result_ok(lean_box(0));
}

// ============================================================================
// Bidirectional Streaming Call
// ============================================================================

extern "C" LEAN_EXPORT lean_obj_res legate_bidi_streaming_call_start(
    b_lean_obj_arg channel,
    b_lean_obj_arg method,
    uint64_t timeout_ms,
    b_lean_obj_arg metadata,
    uint8_t wait_for_ready,
    lean_obj_arg /* world */
) {
    auto* ch_wrapper = static_cast<ChannelWrapper*>(lean_get_external_data(channel));
    std::string method_str = lean_string_to_std(method);

    auto* wrapper = new BidiStreamWrapper();
    apply_timeout(wrapper->context.get(), timeout_ms);
    apply_metadata(wrapper->context.get(), metadata);
    wrapper->context->set_wait_for_ready(wait_for_ready != 0);

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

    if (!wrapper->finished) {
        wrapper->stream->Finish(&wrapper->status, reinterpret_cast<void*>(5));
        void* tag;
        bool ok;
        wrapper->cq.Next(&tag, &ok);
        wrapper->finished = true;
    }

    return mk_io_result_ok(mk_status(wrapper->status));
}

extern "C" LEAN_EXPORT lean_obj_res legate_bidi_stream_get_trailers(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<BidiStreamWrapper*>(lean_get_external_data(stream));
    if (!wrapper->writes_done) {
        legate_bidi_stream_writes_done(stream, lean_box(0));
    }
    if (!wrapper->finished) {
        wrapper->stream->Finish(&wrapper->status, reinterpret_cast<void*>(5));
        void* tag;
        bool ok;
        wrapper->cq.Next(&tag, &ok);
        wrapper->finished = true;
    }
    lean_object* trailers = trailing_metadata_to_lean(
        wrapper->context->GetServerTrailingMetadata());
    return mk_io_result_ok(trailers);
}

extern "C" LEAN_EXPORT lean_obj_res legate_bidi_stream_get_headers(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<BidiStreamWrapper*>(lean_get_external_data(stream));
    // Initial metadata is available after first read or after call starts
    lean_object* headers = initial_metadata_to_lean(
        wrapper->context->GetServerInitialMetadata());
    return mk_io_result_ok(headers);
}

extern "C" LEAN_EXPORT lean_obj_res legate_bidi_stream_cancel(
    b_lean_obj_arg stream,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<BidiStreamWrapper*>(lean_get_external_data(stream));
    if (wrapper && wrapper->context) {
        wrapper->context->TryCancel();
    }
    return mk_io_result_ok(lean_box(0));
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
// On error, sets *error_code, *error_msg, and optionally *error_details
static bool extract_except_result(
    lean_object* except_result,
    lean_object** result,
    int* error_code,
    std::string* error_msg,
    std::string* error_details = nullptr
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
        // GrpcError is packed: msg at idx 0, details at idx 1, code stored as uint8 after pointers.
        uint8_t code = lean_ctor_get_uint8(grpc_error, sizeof(void*) * 2);
        lean_object* msg_obj = lean_ctor_get(grpc_error, 0);
        *error_code = static_cast<int>(code);
        *error_msg = lean_string_cstr(msg_obj);

        // Extract details (Option ByteArray) if requested
        if (error_details) {
            lean_object* details_opt = lean_ctor_get(grpc_error, 1);
            if (lean_obj_tag(details_opt) == 1) {
                // Option.some - extract ByteArray
                lean_object* ba = lean_ctor_get(details_opt, 0);
                size_t len = lean_sarray_size(ba);
                uint8_t* ptr = lean_sarray_cptr(ba);
                *error_details = std::string(reinterpret_cast<char*>(ptr), len);
            } else {
                error_details->clear();
            }
        }
        return false;
    }
}

// Process a unary call - called from the server polling loop
static grpc::Status grpc_status_from_lean_error(int error_code, const std::string& error_msg, const std::string& error_details = "") {
    // Lean StatusCode uses the same numeric mapping as gRPC core status codes.
    // The third parameter is error_details (binary, typically google.rpc.Status protobuf)
    return grpc::Status(static_cast<grpc::StatusCode>(error_code), error_msg, error_details);
}

static bool cq_wait_for_tag(grpc::CompletionQueue& cq, void* expected_tag, bool* ok_out) {
    while (true) {
        void* tag = nullptr;
        bool ok = false;
        bool alive = cq.Next(&tag, &ok);
        if (!alive) {
            if (ok_out) *ok_out = false;
            return false;
        }
        if (tag == expected_tag) {
            if (ok_out) *ok_out = ok;
            return true;
        }
        // Unexpected event: drain it and keep waiting. With our server design,
        // this usually means a leftover event from a previous call.
        if (debug_server_io_enabled()) {
            std::fprintf(stderr, "[legate] server cq: unexpected tag=%p expected=%p ok=%d\n", tag, expected_tag, ok ? 1 : 0);
            std::fflush(stderr);
        }
    }
}

static bool server_read_one(ServerCallContext* call_ctx, grpc::ByteBuffer* out) {
    void* expected = &call_ctx->tag_read;
    call_ctx->stream.Read(out, expected);
    bool ok = false;
    cq_wait_for_tag(call_ctx->call_cq, expected, &ok);
    return ok;
}

static void server_finish(ServerCallContext* call_ctx, const grpc::Status& status) {
    void* expected = &call_ctx->tag_finish;
    call_ctx->stream.Finish(status, expected);
    bool ok = false;
    cq_wait_for_tag(call_ctx->call_cq, expected, &ok);

    // Shutdown and drain the per-call CQ before deleting the call context.
    call_ctx->call_cq.Shutdown();
    while (true) {
        void* tag = nullptr;
        bool ok2 = false;
        bool alive = call_ctx->call_cq.Next(&tag, &ok2);
        if (!alive) break;
    }
}

static void handle_server_call(ServerCallContext* call_ctx) {
    auto* handler = call_ctx->handler;
    if (!handler || !handler->handler) {
        server_finish(call_ctx, grpc::Status(grpc::StatusCode::UNIMPLEMENTED, "Method not implemented"));
        return;
    }

    // Ensure cancellation status can be queried safely via ServerContext::IsCancelled().
    call_ctx->ctx.AsyncNotifyWhenDone(&call_ctx->tag_done);

    auto* call_wrapper = new ServerCallWrapper(&call_ctx->ctx, call_ctx);
    lean_object* call_obj = lean_alloc_external(g_server_call_class, call_wrapper);
    // Keep the external object alive even if the Lean handler doesn't use it.
    // Otherwise the finalizer may delete call_wrapper early, and we'd write to
    // freed memory when clearing wrapper->ctx at the end of this call.
    lean_inc(call_obj);
    struct CallObjPin {
        ServerCallWrapper* wrapper;
        lean_object* obj;
        ~CallObjPin() {
            if (wrapper) wrapper->ctx = nullptr;
            if (obj) lean_dec(obj);
        }
    } call_pin{call_wrapper, call_obj};

    // Convert metadata to Lean array
    lean_object* metadata = server_metadata_to_lean(call_ctx->ctx.client_metadata());
    // Method name
    lean_object* method_str = lean_mk_string(call_ctx->method.c_str());

    switch (handler->type) {
        case HandlerType::UNARY: {
            grpc::ByteBuffer request;
            if (!server_read_one(call_ctx, &request)) {
                server_finish(call_ctx, grpc::Status(grpc::StatusCode::INTERNAL, "Failed to read unary request"));
                return;
            }

            lean_object* request_bytes = bytebuffer_to_lean_bytearray(request);

            lean_object* handler_obj = handler->handler;
            lean_inc(handler_obj);
            lean_object* h0 = lean_apply_1(handler_obj, call_obj);
            lean_object* h1 = lean_apply_1(h0, method_str);
            lean_object* h2 = lean_apply_1(h1, metadata);
            lean_object* h3 = lean_apply_1(h2, request_bytes);
            lean_object* io_result = lean_apply_1(h3, lean_io_mk_world());

            if (lean_io_result_is_error(io_result)) {
                lean_dec(io_result);
                server_finish(call_ctx, grpc::Status(grpc::StatusCode::INTERNAL, "IO error in unary handler"));
                return;
            }

            lean_object* except_result = lean_io_result_get_value(io_result);
            lean_object* ok_value = nullptr;
            int error_code = 0;
            std::string error_msg;
            std::string error_details;
            if (!extract_except_result(except_result, &ok_value, &error_code, &error_msg, &error_details)) {
                lean_dec(io_result);
                server_finish(call_ctx, grpc_status_from_lean_error(error_code, error_msg, error_details));
                return;
            }

            // ok_value : (ByteArray × Metadata × Metadata) = (response, headers, trailers)
            // Lean tuple (A × B × C) is (A × (B × C)), so we need to unpack nested pairs
            lean_object* response_bytes = lean_ctor_get(ok_value, 0);
            lean_object* inner_pair = lean_ctor_get(ok_value, 1);
            lean_object* headers = lean_ctor_get(inner_pair, 0);
            lean_object* trailers = lean_ctor_get(inner_pair, 1);

            // Apply initial metadata (response headers)
            apply_initial_metadata(&call_ctx->ctx, headers);
            // Apply trailing metadata
            apply_trailing_metadata(&call_ctx->ctx, trailers);

            grpc::ByteBuffer response = lean_bytearray_to_bytebuffer(response_bytes);
            void* expected = &call_ctx->tag_write;
            call_ctx->stream.Write(response, expected);
            bool ok = false;
            cq_wait_for_tag(call_ctx->call_cq, expected, &ok);
            lean_dec(ok_value);
            lean_dec(io_result);

            server_finish(call_ctx, grpc::Status::OK);
            return;
        }

        case HandlerType::CLIENT_STREAMING: {
            auto* state = new ServerIOState(call_ctx);
            lean_object* state_obj = lean_alloc_external(g_server_io_state_class, state);
            lean_inc(state_obj);
            struct StateObjPin {
                ServerIOState* state;
                lean_object* obj;
                ~StateObjPin() {
                    if (state) state->call_ctx = nullptr;
                    if (obj) lean_dec(obj);
                }
            } state_pin{state, state_obj};
            lean_object* recv_action = mk_server_recv_action(state_obj);

            lean_object* handler_obj = handler->handler;
            lean_inc(handler_obj);
            lean_object* h0 = lean_apply_1(handler_obj, call_obj);
            lean_object* h1 = lean_apply_1(h0, method_str);
            lean_object* h2 = lean_apply_1(h1, metadata);
            lean_object* h3 = lean_apply_1(h2, recv_action);
            lean_object* io_result = lean_apply_1(h3, lean_io_mk_world());

            if (lean_io_result_is_error(io_result)) {
                lean_dec(io_result);
                server_finish(call_ctx, grpc::Status(grpc::StatusCode::INTERNAL, "IO error in client-streaming handler"));
                return;
            }

            lean_object* except_result = lean_io_result_get_value(io_result);
            lean_object* ok_value = nullptr;
            int error_code = 0;
            std::string error_msg;
            std::string error_details;
            if (!extract_except_result(except_result, &ok_value, &error_code, &error_msg, &error_details)) {
                lean_dec(io_result);
                server_finish(call_ctx, grpc_status_from_lean_error(error_code, error_msg, error_details));
                return;
            }

            // ok_value : (ByteArray × Metadata × Metadata) = (response, headers, trailers)
            // Lean tuple (A × B × C) is (A × (B × C)), so we need to unpack nested pairs
            lean_object* response_bytes = lean_ctor_get(ok_value, 0);
            lean_object* inner_pair = lean_ctor_get(ok_value, 1);
            lean_object* headers = lean_ctor_get(inner_pair, 0);
            lean_object* trailers = lean_ctor_get(inner_pair, 1);

            // Apply initial metadata (response headers)
            apply_initial_metadata(&call_ctx->ctx, headers);
            // Apply trailing metadata
            apply_trailing_metadata(&call_ctx->ctx, trailers);

            grpc::ByteBuffer response = lean_bytearray_to_bytebuffer(response_bytes);
            void* expected = &call_ctx->tag_write;
            call_ctx->stream.Write(response, expected);
            bool ok = false;
            cq_wait_for_tag(call_ctx->call_cq, expected, &ok);
            lean_dec(ok_value);
            lean_dec(io_result);

            server_finish(call_ctx, grpc::Status::OK);
            return;
        }

        case HandlerType::SERVER_STREAMING: {
            grpc::ByteBuffer request;
            if (!server_read_one(call_ctx, &request)) {
                server_finish(call_ctx, grpc::Status(grpc::StatusCode::INTERNAL, "Failed to read server-streaming request"));
                return;
            }

            lean_object* request_bytes = bytebuffer_to_lean_bytearray(request);

            auto* state = new ServerIOState(call_ctx);
            lean_object* state_obj = lean_alloc_external(g_server_io_state_class, state);
            lean_inc(state_obj);
            struct StateObjPin {
                ServerIOState* state;
                lean_object* obj;
                ~StateObjPin() {
                    if (state) state->call_ctx = nullptr;
                    if (obj) lean_dec(obj);
                }
            } state_pin{state, state_obj};
            lean_object* send_fn = mk_server_send_fn(state_obj);

            lean_object* handler_obj = handler->handler;
            lean_inc(handler_obj);
            lean_object* h0 = lean_apply_1(handler_obj, call_obj);
            lean_object* h1 = lean_apply_1(h0, method_str);
            lean_object* h2 = lean_apply_1(h1, metadata);
            lean_object* h3 = lean_apply_1(h2, request_bytes);
            lean_object* h4 = lean_apply_1(h3, send_fn);
            lean_object* io_result = lean_apply_1(h4, lean_io_mk_world());

            if (lean_io_result_is_error(io_result)) {
                lean_dec(io_result);
                server_finish(call_ctx, grpc::Status(grpc::StatusCode::INTERNAL, "IO error in server-streaming handler"));
                return;
            }

            lean_object* except_result = lean_io_result_get_value(io_result);
            lean_object* ok_value = nullptr;
            int error_code = 0;
            std::string error_msg;
            std::string error_details;
            if (!extract_except_result(except_result, &ok_value, &error_code, &error_msg, &error_details)) {
                lean_dec(io_result);
                server_finish(call_ctx, grpc_status_from_lean_error(error_code, error_msg, error_details));
                return;
            }

            // ok_value : (Metadata × Metadata) = (headers, trailers)
            lean_object* headers = lean_ctor_get(ok_value, 0);
            lean_object* trailers = lean_ctor_get(ok_value, 1);

            // Apply initial metadata (response headers) if no write has triggered it yet.
            if (!call_ctx->initial_metadata_sent) {
                apply_initial_metadata(&call_ctx->ctx, headers);
                void* expected = &call_ctx->tag_send_initial_metadata;
                call_ctx->stream.SendInitialMetadata(expected);
                bool ok = false;
                cq_wait_for_tag(call_ctx->call_cq, expected, &ok);
                call_ctx->initial_metadata_sent = true;
            }
            // Apply trailing metadata
            apply_trailing_metadata(&call_ctx->ctx, trailers);
            lean_dec(ok_value);
            lean_dec(io_result);

            server_finish(call_ctx, grpc::Status::OK);
            return;
        }

        case HandlerType::BIDI_STREAMING: {
            auto* state = new ServerIOState(call_ctx);
            lean_object* state_obj = lean_alloc_external(g_server_io_state_class, state);
            lean_inc(state_obj);
            struct StateObjPin {
                ServerIOState* state;
                lean_object* obj;
                ~StateObjPin() {
                    if (state) state->call_ctx = nullptr;
                    if (obj) lean_dec(obj);
                }
            } state_pin{state, state_obj};
            lean_object* recv_action = mk_server_recv_action(state_obj);
            lean_inc(state_obj);
            lean_object* send_fn = mk_server_send_fn(state_obj);

            lean_object* handler_obj = handler->handler;
            lean_inc(handler_obj);
            lean_object* h0 = lean_apply_1(handler_obj, call_obj);
            lean_object* h1 = lean_apply_1(h0, method_str);
            lean_object* h2 = lean_apply_1(h1, metadata);
            lean_object* h3 = lean_apply_1(h2, recv_action);
            lean_object* h4 = lean_apply_1(h3, send_fn);
            lean_object* io_result = lean_apply_1(h4, lean_io_mk_world());

            if (lean_io_result_is_error(io_result)) {
                lean_dec(io_result);
                server_finish(call_ctx, grpc::Status(grpc::StatusCode::INTERNAL, "IO error in bidi handler"));
                return;
            }

            lean_object* except_result = lean_io_result_get_value(io_result);
            lean_object* ok_value = nullptr;
            int error_code = 0;
            std::string error_msg;
            std::string error_details;
            if (!extract_except_result(except_result, &ok_value, &error_code, &error_msg, &error_details)) {
                lean_dec(io_result);
                server_finish(call_ctx, grpc_status_from_lean_error(error_code, error_msg, error_details));
                return;
            }

            // ok_value : (Metadata × Metadata) = (headers, trailers)
            lean_object* headers = lean_ctor_get(ok_value, 0);
            lean_object* trailers = lean_ctor_get(ok_value, 1);

            // Apply initial metadata (response headers) if no write has triggered it yet.
            if (!call_ctx->initial_metadata_sent) {
                apply_initial_metadata(&call_ctx->ctx, headers);
                void* expected = &call_ctx->tag_send_initial_metadata;
                call_ctx->stream.SendInitialMetadata(expected);
                bool ok = false;
                cq_wait_for_tag(call_ctx->call_cq, expected, &ok);
                call_ctx->initial_metadata_sent = true;
            }
            // Apply trailing metadata
            apply_trailing_metadata(&call_ctx->ctx, trailers);
            lean_dec(ok_value);
            lean_dec(io_result);

            server_finish(call_ctx, grpc::Status::OK);
            return;
        }
    }

    server_finish(call_ctx, grpc::Status(grpc::StatusCode::UNIMPLEMENTED, "Handler type not supported"));
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

    std::string prefix, host;
    int port = 0;
    if (split_host_port(addr_str, &prefix, &host, &port) && port == 0) {
        int chosen = 0;
        int fd = reserve_tcp_port(host, &chosen);
        if (fd != -1 && chosen != 0) {
            wrapper->reserved_fds.push_back(fd);
            port = chosen;
            addr_str = join_host_port(prefix, host, port);
        } else if (fd != -1) {
            ::close(fd);
        }
    }
    wrapper->selected_port = port;

    // Note: For TLS support, use legate_server_builder_add_secure_listening_port
    wrapper->builder->AddListeningPort(addr_str, grpc::InsecureServerCredentials(), nullptr);

    return mk_io_result_ok(lean_box(static_cast<unsigned>(wrapper->selected_port)));
}

// Add a secure listening port with TLS credentials
extern "C" LEAN_EXPORT lean_obj_res legate_server_builder_add_secure_listening_port(
    b_lean_obj_arg builder,
    b_lean_obj_arg addr,
    b_lean_obj_arg root_certs,      // PEM root certs for client verification (empty = no client auth)
    b_lean_obj_arg server_cert,     // PEM server certificate chain
    b_lean_obj_arg server_key,      // PEM server private key
    uint8_t client_auth_type,       // 0 = none, 1 = request, 2 = require
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerBuilderWrapper*>(lean_get_external_data(builder));
    std::string addr_str = lean_string_to_std(addr);
    std::string root_certs_str = lean_string_to_std(root_certs);
    std::string server_cert_str = lean_string_to_std(server_cert);
    std::string server_key_str = lean_string_to_std(server_key);

    std::string prefix, host;
    int port = 0;
    if (split_host_port(addr_str, &prefix, &host, &port) && port == 0) {
        int chosen = 0;
        int fd = reserve_tcp_port(host, &chosen);
        if (fd != -1 && chosen != 0) {
            wrapper->reserved_fds.push_back(fd);
            port = chosen;
            addr_str = join_host_port(prefix, host, port);
        } else if (fd != -1) {
            ::close(fd);
        }
    }
    wrapper->selected_port = port;

    grpc::SslServerCredentialsOptions opts;

    // Set client certificate request type
    switch (client_auth_type) {
        case 0:
            opts.client_certificate_request = GRPC_SSL_DONT_REQUEST_CLIENT_CERTIFICATE;
            break;
        case 1:
            opts.client_certificate_request = GRPC_SSL_REQUEST_CLIENT_CERTIFICATE_AND_VERIFY;
            break;
        case 2:
            opts.client_certificate_request = GRPC_SSL_REQUEST_AND_REQUIRE_CLIENT_CERTIFICATE_AND_VERIFY;
            break;
        default:
            opts.client_certificate_request = GRPC_SSL_DONT_REQUEST_CLIENT_CERTIFICATE;
            break;
    }

    // Set root certs for client verification (if mTLS)
    if (!root_certs_str.empty()) {
        opts.pem_root_certs = root_certs_str;
    }

    // Add server key-cert pair
    grpc::SslServerCredentialsOptions::PemKeyCertPair key_cert_pair;
    key_cert_pair.private_key = server_key_str;
    key_cert_pair.cert_chain = server_cert_str;
    opts.pem_key_cert_pairs.push_back(key_cert_pair);

    auto creds = grpc::SslServerCredentials(opts);
    wrapper->builder->AddListeningPort(addr_str, creds, nullptr);

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

    // Transfer service ownership to the server wrapper so it outlives the builder.
    // The service must remain alive as long as the server is running.
    s_wrapper->service = std::move(b_wrapper->service);
    if (!s_wrapper->service) {
        delete s_wrapper;
        return mk_io_error("Failed to build server: missing AsyncGenericService");
    }

    // Add completion queue
    s_wrapper->cq = b_wrapper->builder->AddCompletionQueue();

    // If we reserved any ephemeral ports (addr :0), release them immediately
    // before BuildAndStart() so gRPC can bind to the same ports.
    for (int fd : b_wrapper->reserved_fds) {
        if (fd != -1) ::close(fd);
    }
    b_wrapper->reserved_fds.clear();

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

// Start accepting a new call (notification events are delivered on wrapper->cq).
static void start_accepting(ServerWrapper* wrapper) {
    auto* call_ctx = new ServerCallContext(wrapper);
    wrapper->service->RequestCall(
        &call_ctx->ctx,
        &call_ctx->stream,
        &call_ctx->call_cq,
        wrapper->cq.get(),
        call_ctx);
}

static void ensure_worker_pool_started(ServerWrapper* wrapper) {
    if (!wrapper || !wrapper->worker_threads.empty()) return;
    unsigned n = server_worker_count();
    if (debug_server_io_enabled()) {
        std::fprintf(stderr, "[legate] server: starting %u worker(s)\n", n);
        std::fflush(stderr);
    }
    wrapper->worker_threads.reserve(n);
    for (unsigned i = 0; i < n; ++i) {
        wrapper->worker_threads.emplace_back([wrapper]() {
            while (true) {
                ServerCallContext* call_ctx = nullptr;
                {
                    std::unique_lock<std::mutex> lock(wrapper->work_mu);
                    wrapper->work_cv.wait(lock, [wrapper]() {
                        return !wrapper->work_q.empty() || !wrapper->running.load();
                    });
                    if (!wrapper->work_q.empty()) {
                        call_ctx = wrapper->work_q.front();
                        wrapper->work_q.pop_front();
                    } else if (!wrapper->running.load()) {
                        break;
                    }
                }
                if (call_ctx) {
                    handle_server_call(call_ctx);
                    delete call_ctx;
                }
            }
        });
    }
}

static void enqueue_server_call(ServerWrapper* wrapper, ServerCallContext* call_ctx) {
    {
        std::lock_guard<std::mutex> lock(wrapper->work_mu);
        wrapper->work_q.push_back(call_ctx);
    }
    wrapper->work_cv.notify_one();
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_start(
    b_lean_obj_arg server,
    lean_obj_arg /* world */
) {
    auto* wrapper = static_cast<ServerWrapper*>(lean_get_external_data(server));

    if (!wrapper->server || !wrapper->cq) {
        return mk_io_error("Server has been shut down");
    }

    if (wrapper->running.load()) {
        return mk_io_result_ok(lean_box(0));
    }

    wrapper->running.store(true);

    ensure_worker_pool_started(wrapper);

    // Start accepting first call
    start_accepting(wrapper);

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

                // New call accepted - start accepting another immediately.
                start_accepting(wrapper);

                // Find handler for this method and handle the call synchronously.
                call_ctx->method = call_ctx->ctx.method();
                call_ctx->handler = wrapper->findHandler(call_ctx->method);
                enqueue_server_call(wrapper, call_ctx);
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
    if (wrapper->cq) wrapper->cq->Shutdown();
    if (wrapper->polling_thread.joinable()) {
        wrapper->polling_thread.join();
    }
    // Stop workers.
    wrapper->work_cv.notify_all();
    for (auto& t : wrapper->worker_threads) {
        if (t.joinable()) t.join();
    }
    wrapper->worker_threads.clear();
    {
        std::lock_guard<std::mutex> lock(wrapper->work_mu);
        while (!wrapper->work_q.empty()) {
            delete wrapper->work_q.front();
            wrapper->work_q.pop_front();
        }
    }
    // Drain server CQ before returning (required by gRPC).
    if (wrapper->cq) {
        void* tag = nullptr;
        bool ok = false;
        while (wrapper->cq->Next(&tag, &ok)) {
            delete static_cast<ServerCallContext*>(tag);
        }
    }
    // Prevent accidental restart of a shut down server.
    wrapper->server.reset();
    wrapper->cq.reset();

    return mk_io_result_ok(lean_box(0));
}

extern "C" LEAN_EXPORT lean_obj_res legate_server_shutdown_now(
    b_lean_obj_arg server,
    lean_obj_arg /* world */
) {
    return legate_server_shutdown(server, lean_box(0));
}
