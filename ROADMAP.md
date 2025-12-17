# Legate Roadmap (Lean gRPC)

This repository aims to provide **production-grade gRPC support for Lean 4**, with **Go only used as an interop test oracle**.

The roadmap below is organized around “common gRPC features” and the **tests we need** to confidently claim support in **Lean client** and **Lean server** modes.

## Current Status (as of 2025-12-17)

What's working and covered by tests today:

- **RPC shapes:** unary, client-streaming, server-streaming, bidi-streaming
- **Protobuf:** request/response message roundtrips via `Protolean`
- **Metadata:** Full support for request headers, response headers (initial metadata), and trailers for all RPC shapes
  - Lean client: access response headers via `response.headers` (unary) or `stream.getHeaders()` (streaming)
  - Lean server: return `(response, headers, trailers)` from handlers
- **Deadlines + cancellation:** unary deadline-exceeded and unary cancel propagation, exercised cross-language
- **Lean server call context:** server handlers can query cancellation and deadline remaining time
- **Test harness:** `./run-tests.sh` builds native FFI and runs unit + integration suites

## Test Coverage Gaps (Common gRPC Features)

The items below are the most important missing pieces for “typical” gRPC usage in Lean.

### Metadata

- ~~**Response headers (initial metadata):** not exposed/validated (only trailers are tested)~~ ✅ **DONE** - Headers exposed and tested
- **Multi-value metadata keys:** not tested (multiple values for same key)
- **Binary metadata (`*-bin`):** not supported/tested
- **Reserved/transport headers:** behavior not tested (`grpc-timeout`, `content-type`, etc.)

### Deadlines & Cancellation (Streaming)

- **Deadline-exceeded on streaming RPCs:** not tested for client-stream/server-stream/bidi
- **Mid-stream cancellation:** not tested (cancel during active streaming and verify termination semantics)
- **Server-side observation:** not tested that handlers reliably see `isCancelled` and stop work promptly

### Status / Errors

- **Non-OK status propagation for streaming:** early-terminate with a specific code/message and assert client sees it
- **Rich error details:** `grpc-status-details-bin` / `google.rpc.Status` not supported/tested
- **Trailing metadata on error paths:** not systematically tested (trailers when status is non-OK)

### Channel & Call Semantics

- **`waitForReady`:** `CallOptions.waitForReady` exists but is not wired/tested end-to-end
- **Connectivity transitions:** no tests for `idle → ready → transientFailure` behaviors
- **Name resolution / multiple addresses:** not tested

### Transport & Security

- **TLS:** secure client channel and secure server credentials are not implemented/tested
- **mTLS:** client cert auth and server-side verification not implemented/tested
- **Hostname/SAN verification:** not tested

### Compression

- **gzip (and friends):** no compression configuration or tests

### Scale / Robustness

- **Large messages:** max send/recv size handling not tested
- **Backpressure / slow consumer:** no stress tests for streaming flow control
- **Concurrency:** no tests for many concurrent RPCs/streams
- **Lifecycle:** graceful server shutdown/drain behavior not tested (in-flight RPCs, new connections)

### Extensibility / Middleware

- **Interceptors (client/server):** not implemented/tested (auth, tracing, logging hooks)
- **Per-RPC credentials:** no first-class “call credentials” story (common for auth tokens)

### Service Ecosystem

- **Health checking:** gRPC health service (`grpc.health.v1.Health`) not implemented/tested
- **Server reflection:** reflection service not implemented/tested (useful for tooling)

## Roadmap

This is the suggested order to reach “common gRPC feature parity” for Lean.

### Phase 1 — Metadata Parity (Headers + Edge Cases) ✅ **COMPLETE**

**Add APIs** ✅
- ✅ Lean client: access **response headers** (initial metadata) for all RPC shapes
  - `UnaryResponse.headers` for unary calls
  - `stream.getHeaders()` for streaming calls (ServerStreamReader, BidiStream, ClientStreamWriter)
- ✅ Lean server: ability to **send initial metadata** explicitly (when needed)
  - Handler return types now include headers: `(response, headers, trailers)` for unary/client-streaming
  - `(headers, trailers)` for server-streaming/bidi-streaming
- Optional: typed helpers for multi-value metadata and `*-bin` (deferred to later)

**Add tests** ✅
- ✅ Unary + streaming: client asserts both **headers and trailers**
- Multi-value metadata key roundtrip (deferred)
- `*-bin` metadata roundtrip (deferred)

**Definition of done** ✅
- Lean client and Lean server can roundtrip metadata in/out, including headers, across all RPC shapes.

### Phase 2 — Deadlines & Cancellation for Streaming

**Add APIs**
- Ensure streaming primitives surface terminal status reliably (deadline vs cancel vs EOF)
- Server handlers: ergonomic helpers for “sleep/work that stops when cancelled”

**Add tests**
- Server-stream: cancel after N messages; assert client sees `Canceled` and trailers behavior
- Client-stream: cancel while sending; assert server observes cancellation and exits
- Bidi: cancel mid-flight; assert both sides terminate with correct status
- Streaming deadline-exceeded (timeouts during active reads/writes)

**Definition of done**
- Cancellation/deadline behavior matches “typical gRPC expectations” for all RPC shapes.

### Phase 3 — Status & Rich Errors

**Add APIs**
- Support non-OK termination for streaming handlers (explicit `FinishWithError` equivalent)
- Add optional `GrpcError.details` support via `grpc-status-details-bin` (`google.rpc.Status`)

**Add tests**
- Each RPC shape: server returns non-OK; client observes correct `StatusCode`, message, and (if present) details
- Error path trailers (and headers if present) are exposed and stable

**Definition of done**
- Lean can represent and validate common error patterns used by real gRPC services.

### Phase 4 — TLS / mTLS

**Add APIs**
- Lean server: secure creds (TLS), plus mTLS options (client cert required/optional)
- Lean client: secure channel configuration; hostname verification controls (safe defaults)

**Add tests**
- Spin up a TLS/mTLS server with test certs; assert successful and failing handshakes
- Verify hostname/SAN mismatch fails as expected

**Definition of done**
- Lean client/server can do secure gRPC in the standard configurations.

### Phase 5 — Wait-for-ready, Retries, and Resilience

**Add APIs**
- Wire `CallOptions.waitForReady` through to gRPC core (and document semantics)
- Consider service config / retry policies (if in scope)

**Add tests**
- Call made while server is down with `waitForReady=true`: succeeds when server comes up
- Without wait-for-ready: fails fast

**Definition of done**
- Lean supports the common “bring server up later” deployment use case.

### Phase 6 — Scale & Stress

**Add tests (targeted, not flaky)**
- Large unary payload (near configured limits)
- Large streaming payloads (many small messages + fewer large messages)
- Concurrency: N parallel unary + streaming sessions
- Leak/FD regression checks (best-effort on CI)

**Definition of done**
- No obvious correctness regressions under load; stable resource usage.

### Phase 7 — Interceptors / Middleware Hooks

**Add APIs**
- Client interceptors (metadata injection, logging/tracing)
- Server interceptors (auth, metrics)
- Optional: per-RPC credentials helper (token providers)

**Add tests**
- Auth header injection + verification
- Correlation IDs / tracing metadata propagation

## Notes on Testing Strategy

- The authoritative suite should remain `./run-tests.sh`.
- Prefer **Lean↔Lean** tests where possible for determinism, and keep **Go↔Lean** tests as interop checks.
- For complex features (TLS, rich errors), add a minimal Go oracle first, then add Lean↔Lean parity tests once the Lean surface area exists.
