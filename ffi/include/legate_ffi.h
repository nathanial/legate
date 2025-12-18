#ifndef LEGATE_FFI_H
#define LEGATE_FFI_H

#include <lean/lean.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Initialization
// ============================================================================

// Initialize the gRPC runtime. Called automatically on module load.
LEAN_EXPORT lean_obj_res legate_init(lean_obj_arg world);

// Shutdown the gRPC runtime. Called automatically on process exit.
LEAN_EXPORT lean_obj_res legate_shutdown(lean_obj_arg world);

// ============================================================================
// Channel operations
// ============================================================================

// Create an insecure channel to the given target (e.g., "localhost:50051")
LEAN_EXPORT lean_obj_res legate_channel_create_insecure(b_lean_obj_arg target, lean_obj_arg world);

// Create a secure channel with SSL/TLS credentials
LEAN_EXPORT lean_obj_res legate_channel_create_secure(
    b_lean_obj_arg target,
    b_lean_obj_arg root_certs,      // Optional PEM root certificates (can be empty string)
    b_lean_obj_arg private_key,     // Optional PEM private key (can be empty string)
    b_lean_obj_arg cert_chain,      // Optional PEM certificate chain (can be empty string)
    b_lean_obj_arg ssl_target_name_override,  // Optional override for hostname verification (can be empty string)
    lean_obj_arg world
);

// Get the current state of a channel
// Returns: 0=IDLE, 1=CONNECTING, 2=READY, 3=TRANSIENT_FAILURE, 4=SHUTDOWN
LEAN_EXPORT lean_obj_res legate_channel_get_state(b_lean_obj_arg channel, uint8_t try_connect, lean_obj_arg world);

// ============================================================================
// Unary Call
// ============================================================================

// Make a unary RPC call
// Returns: Except GrpcError (ByteArray × Metadata × Metadata) = (data, headers, trailers)
LEAN_EXPORT lean_obj_res legate_unary_call(
    b_lean_obj_arg channel,
    b_lean_obj_arg method,          // Full method name, e.g., "/package.Service/Method"
    b_lean_obj_arg request,         // ByteArray request payload
    uint64_t timeout_ms,            // Timeout in milliseconds (0 = no timeout)
    b_lean_obj_arg metadata,        // Array of (String × String) for headers
    uint8_t wait_for_ready,         // 0 = fail fast if not ready; 1 = wait until ready (until deadline)
    lean_obj_arg world
);

// ============================================================================
// Client Streaming Call
// ============================================================================

// Start a client streaming call
// Returns: Except GrpcError ClientStreamCall
LEAN_EXPORT lean_obj_res legate_client_streaming_call_start(
    b_lean_obj_arg channel,
    b_lean_obj_arg method,
    uint64_t timeout_ms,
    b_lean_obj_arg metadata,
    uint8_t wait_for_ready,
    lean_obj_arg world
);

// Write a message to the client stream
LEAN_EXPORT lean_obj_res legate_client_stream_write(
    b_lean_obj_arg stream,
    b_lean_obj_arg data,
    lean_obj_arg world
);

// Signal that no more messages will be written
LEAN_EXPORT lean_obj_res legate_client_stream_writes_done(b_lean_obj_arg stream, lean_obj_arg world);

// Finish the client streaming call and get the response
// Returns: Except GrpcError (ByteArray × Metadata × Status)
LEAN_EXPORT lean_obj_res legate_client_stream_finish(b_lean_obj_arg stream, lean_obj_arg world);

// Get initial metadata (response headers) from a client stream
LEAN_EXPORT lean_obj_res legate_client_stream_get_headers(b_lean_obj_arg stream, lean_obj_arg world);

// Cancel the client stream
LEAN_EXPORT lean_obj_res legate_client_stream_cancel(b_lean_obj_arg stream, lean_obj_arg world);

// ============================================================================
// Server Streaming Call
// ============================================================================

// Start a server streaming call
// Returns: Except GrpcError ServerStreamCall
LEAN_EXPORT lean_obj_res legate_server_streaming_call_start(
    b_lean_obj_arg channel,
    b_lean_obj_arg method,
    b_lean_obj_arg request,
    uint64_t timeout_ms,
    b_lean_obj_arg metadata,
    uint8_t wait_for_ready,
    lean_obj_arg world
);

// Read the next message from the server stream
// Returns: Except GrpcError (Option ByteArray) -- None when stream ends
LEAN_EXPORT lean_obj_res legate_server_stream_read(b_lean_obj_arg stream, lean_obj_arg world);

// Get trailing metadata after stream ends
LEAN_EXPORT lean_obj_res legate_server_stream_get_trailers(b_lean_obj_arg stream, lean_obj_arg world);

// Get initial metadata (response headers) from a server stream
LEAN_EXPORT lean_obj_res legate_server_stream_get_headers(b_lean_obj_arg stream, lean_obj_arg world);

// Get the final status
LEAN_EXPORT lean_obj_res legate_server_stream_get_status(b_lean_obj_arg stream, lean_obj_arg world);

// Cancel the server stream
LEAN_EXPORT lean_obj_res legate_server_stream_cancel(b_lean_obj_arg stream, lean_obj_arg world);

// ============================================================================
// Bidirectional Streaming Call
// ============================================================================

// Start a bidirectional streaming call
// Returns: Except GrpcError BidiStreamCall
LEAN_EXPORT lean_obj_res legate_bidi_streaming_call_start(
    b_lean_obj_arg channel,
    b_lean_obj_arg method,
    uint64_t timeout_ms,
    b_lean_obj_arg metadata,
    uint8_t wait_for_ready,
    lean_obj_arg world
);

// Write a message to the bidi stream (uses client_stream_write internally)
LEAN_EXPORT lean_obj_res legate_bidi_stream_write(
    b_lean_obj_arg stream,
    b_lean_obj_arg data,
    lean_obj_arg world
);

// Signal writes done on bidi stream
LEAN_EXPORT lean_obj_res legate_bidi_stream_writes_done(b_lean_obj_arg stream, lean_obj_arg world);

// Read from bidi stream (uses server_stream_read internally)
LEAN_EXPORT lean_obj_res legate_bidi_stream_read(b_lean_obj_arg stream, lean_obj_arg world);

// Get status from bidi stream
LEAN_EXPORT lean_obj_res legate_bidi_stream_get_status(b_lean_obj_arg stream, lean_obj_arg world);

// Get trailing metadata from bidi stream
LEAN_EXPORT lean_obj_res legate_bidi_stream_get_trailers(b_lean_obj_arg stream, lean_obj_arg world);

// Get initial metadata (response headers) from a bidi stream
LEAN_EXPORT lean_obj_res legate_bidi_stream_get_headers(b_lean_obj_arg stream, lean_obj_arg world);

// Cancel the bidi stream
LEAN_EXPORT lean_obj_res legate_bidi_stream_cancel(b_lean_obj_arg stream, lean_obj_arg world);

// ============================================================================
// Server operations
// ============================================================================

// Create a new server builder
LEAN_EXPORT lean_obj_res legate_server_builder_new(lean_obj_arg world);

// Add a listening port to the server builder (insecure)
// Returns the actually bound port (may differ if port was 0)
LEAN_EXPORT lean_obj_res legate_server_builder_add_listening_port(
    b_lean_obj_arg builder,
    b_lean_obj_arg addr,
    uint8_t use_tls,                // Ignored, always insecure. Use secure version for TLS.
    lean_obj_arg world
);

// Add a secure listening port with TLS credentials
// Returns the actually bound port (may differ if port was 0)
LEAN_EXPORT lean_obj_res legate_server_builder_add_secure_listening_port(
    b_lean_obj_arg builder,
    b_lean_obj_arg addr,
    b_lean_obj_arg root_certs,      // PEM root certs for client verification (empty = no client auth)
    b_lean_obj_arg server_cert,     // PEM server certificate chain
    b_lean_obj_arg server_key,      // PEM server private key
    uint8_t client_auth_type,       // 0 = none, 1 = request+verify, 2 = require+verify
    lean_obj_arg world
);

// Register a handler for a specific method
// handler_type: 0=unary, 1=client_streaming, 2=server_streaming, 3=bidi
LEAN_EXPORT lean_obj_res legate_server_builder_register_handler(
    b_lean_obj_arg builder,
    b_lean_obj_arg method,
    uint8_t handler_type,
    lean_obj_arg handler,           // The Lean closure to call
    lean_obj_arg world
);

// Build and return the server
LEAN_EXPORT lean_obj_res legate_server_builder_build(b_lean_obj_arg builder, lean_obj_arg world);

// Start the server (non-blocking)
LEAN_EXPORT lean_obj_res legate_server_start(b_lean_obj_arg server, lean_obj_arg world);

// Wait for the server to shutdown
LEAN_EXPORT lean_obj_res legate_server_wait(b_lean_obj_arg server, lean_obj_arg world);

// Shutdown the server gracefully
LEAN_EXPORT lean_obj_res legate_server_shutdown(b_lean_obj_arg server, lean_obj_arg world);

// Shutdown the server immediately
LEAN_EXPORT lean_obj_res legate_server_shutdown_now(b_lean_obj_arg server, lean_obj_arg world);

// ============================================================================
// Server call context helpers (deadline/cancellation)
// ============================================================================

// Check whether the client has cancelled the call.
LEAN_EXPORT lean_obj_res legate_server_call_is_cancelled(b_lean_obj_arg call, lean_obj_arg world);

// Send initial metadata (response headers) for a call. Must be called before first response write.
LEAN_EXPORT lean_obj_res legate_server_call_send_initial_metadata(
    b_lean_obj_arg call,
    b_lean_obj_arg metadata,
    lean_obj_arg world
);

// Remaining time until deadline in milliseconds, or none if no deadline.
LEAN_EXPORT lean_obj_res legate_server_call_deadline_remaining_ms(b_lean_obj_arg call, lean_obj_arg world);

#ifdef __cplusplus
}
#endif

#endif // LEGATE_FFI_H
