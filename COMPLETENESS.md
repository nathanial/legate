# Completeness Plan (Standard gRPC Use Cases)

This document is a **plan** for closing several “standard gRPC” gaps in Legate’s **API surface** and **test suite**.
It is intentionally oriented around **shipping tests first** (or alongside the API) so we can claim the behavior is supported.

## Scope

Address the following omissions (from feedback):

1. **Compression** (e.g., gzip)
2. **Binary metadata** (`*-bin`)
3. **Max message size** (send/recv limits)
4. **Unix Domain Sockets (UDS)**
5. **Keepalives** (client/server tuning knobs)
6. **Server-side cancellation verification** (prove the handler actually stops)

Non-goals for this plan:
- Implementing retries/service-config policies (already covered elsewhere in `ROADMAP.md`).
- Full production-grade interceptor stack (also elsewhere).

## Guiding Principles

- Prefer **Lean↔Lean** tests as the primary signal, but keep **Go↔Lean interop** as an oracle where it adds confidence.
- Keep tests **deterministic** (avoid “sleep for 30s and hope a proxy drops the connection”).
- When adding knobs, expose them **both**:
  - **Channel-side** (client behavior), and
  - **Server-side** (server limits/transport behavior),
  unless the gRPC surface area makes one side irrelevant.

## Milestones (Recommended Order)

### Milestone A — Frequently-needed production features

1) **Binary metadata (`*-bin`)** (API + tests)
2) **Max message size** (API + tests)

### Milestone B — Transport/config completeness

3) **Compression (gzip)** (API + tests)
4) **Unix domain sockets** (API + tests)

### Milestone C — Robustness knobs & test strengthening

5) **Keepalives** (API + best-effort tests)
6) **Server-side cancellation verification** (test strengthening)

## 1) Compression (gzip)

### Current status
- No compression configuration is exposed in `Legate/Channel.lean`, `Legate/Call.lean`, or `Legate/Server.lean`.
- No tests cover compressed messages.

### Plan
- Add a small `CompressionAlgorithm` enum (at least `.gzip`, optionally `.identity` and placeholders).
- Expose configuration at two layers:
  - **Per-RPC**: extend `CallOptions` with `requestCompression : Option CompressionAlgorithm`.
  - **Server response** (optional): add a `ServerCall` method to set response compression for streaming/unary before the first write.
- Wire through `Legate/Internal/FFI.lean` → `ffi/src/legate_ffi.cpp`:
  - Client: set compression on `grpc::ClientContext` for unary and for streaming call starts.
  - Server: set compression on the `grpc::GenericServerContext` (via the stored `ServerCall` handle) before sending headers/first message.

### Tests to add
- **Lean↔Lean**: unary RPC where client enables gzip compression and server echoes request; assert success.
- **Interop** (optional but valuable):
  - Lean client (gzip) → Go server, assert success.
  - Go client (gzip) → Lean server, assert success.

### Definition of done
- At least one end-to-end test proves **compressed request messages** are accepted and decoded.
- Optional: a test proves **compressed responses** are decoded by the client.

## 2) Binary Metadata (`*-bin`)

### Current status
- `Legate/Metadata.lean` models metadata as `Array (String × String)`.
- Tests only use ASCII metadata keys/values.
- There is no explicit support for `*-bin` keys carrying arbitrary bytes.

### Plan
This likely requires an API extension (and possibly a breaking change). Two viable approaches:

**Option A (non-breaking, additive):**
- Keep existing `Metadata := Array (String × String)` for “text metadata”.
- Introduce `BinaryMetadata := Array (String × ByteArray)` restricted to keys ending in `-bin`.
- Add `CallOptions.binMetadata : BinaryMetadata := #[]` and server handler return types include binary headers/trailers in parallel.
- Update FFI to apply both, using binary-safe gRPC metadata APIs (`grpc::string_ref` / `std::string` with explicit lengths).

**Option B (breaking, cleaner long-term):**
- Redefine `Metadata` as `Array MetadataEntry` where `MetadataEntry.value` is `String` or `ByteArray`.
- Provide helpers `Metadata.addText`, `Metadata.addBin`, `Metadata.getText?`, `Metadata.getBin?`.
- Update all call/server APIs to use the new `Metadata`.

Recommendation: start with **Option A** to minimize churn, then consolidate later if desired.

### Implementation notes
- Ensure the FFI never treats binary values as C-strings.
- Ensure receive paths preserve raw bytes for `*-bin` values (don’t roundtrip through UTF-8).

### Tests to add
- **Lean↔Lean**:
  - Send request metadata with key `x-test-bin` and a value containing `0x00` bytes.
  - Server echoes the same bytes back in either initial metadata or trailers.
  - Client asserts exact byte-for-byte equality.
- **Go↔Lean interop**:
  - Go client sends `x-test-bin` with bytes including NUL; Lean server sees the correct bytes and echoes them back.
  - Lean client sends `x-test-bin`; Go server receives correct bytes.

### Definition of done
- Tests prove that `*-bin` values are **binary-safe** (including NUL bytes) and **interop-compatible** with Go.

## 3) Max Message Size

### Current status
- No API to set max send/receive message sizes on `Channel` or `ServerBuilder`.
- No tests for “too large” message behavior.

### Plan
- Add configuration on both ends:
  - **Channel options**: `maxReceiveMessageBytes`, `maxSendMessageBytes` (optional `Nat`/`Int`).
  - **Server builder options**: `maxReceiveMessageBytes`, `maxSendMessageBytes`.
- Wire to gRPC:
  - Prefer native builder methods where available (`ServerBuilder::SetMaxReceiveMessageSize`, `SetMaxSendMessageSize`).
  - For channel use `grpc::ChannelArguments` / standard args (`grpc.max_receive_message_length`, `grpc.max_send_message_length`).

### Tests to add (deterministic)
- **Server receive limit**:
  - Start server with `maxReceiveMessageBytes = 1 MiB`.
  - Client sends 2 MiB unary request.
  - Assert client gets `ResourceExhausted`.
- **Client receive limit**:
  - Start server that returns a 2 MiB unary response.
  - Client channel configured with `maxReceiveMessageBytes = 1 MiB`.
  - Assert client gets `ResourceExhausted`.
- Mirror at least one test in **Lean↔Go** direction to validate interop semantics.

### Definition of done
- Tests prove limits are enforced and surfaced as `ResourceExhausted` with predictable behavior.

## 4) Unix Domain Sockets (UDS)

### Current status
- `Channel.createInsecure` accepts a target string and may work with `unix:///path`.
- `ServerBuilder.addInsecurePort` returns a `UInt32` port and contains TCP-only port selection logic in the FFI; UDS has no “port”.
- No tests cover UDS.

### Plan
- Add explicit APIs so UDS is not an accidental “string hack”:
  - `ServerBuilder.addInsecureUnixSocket (path : String) : IO Unit` (or return the bound path).
  - Optional: `Channel.createInsecureUnixSocket (path : String) : IO Channel` as a convenience wrapper over `unix:///...`.
- Update FFI server listening logic to **skip TCP port reservation** when the address is a `unix:///...` target.

### Tests to add
- **Lean↔Lean**: start server bound to a temp socket path; client connects to `unix:///...` and completes a unary echo.
- **Go↔Lean** (optional): Go client dials UDS and calls into Lean server.

### Definition of done
- A test demonstrates UDS works reliably on supported platforms (macOS/Linux).

## 5) Keepalives

### Current status
- No API to configure keepalive timeouts/intervals.
- No tests cover idle connections surviving long-enough to be realistic.

### Plan
- Expose best-practice subset of keepalive knobs:
  - Channel:
    - `keepaliveTimeMs`
    - `keepaliveTimeoutMs`
    - `keepalivePermitWithoutCalls`
  - Server:
    - `keepaliveTimeMs`
    - `keepaliveTimeoutMs`
    - (optional) `http2MinTimeBetweenPingsMs`, `http2MaxPingStrikes`
- Wire via standard gRPC channel/server args (documented arg names in the code).

### Tests to add (best-effort / avoid flakiness)
- Prefer **unit-level “wiring tests”** where possible (e.g., build channel/server with args and ensure no errors).
- Add one minimal **integration smoke test**:
  - Run a long-lived stream or keep a channel idle for a short duration with aggressive keepalive settings.
  - Verify the channel remains usable by performing a call after the idle period.
- Document that “proxy/load-balancer survivability” is inherently environment-dependent and not fully testable in-repo.

### Definition of done
- Keepalive knobs exist and are documented; at least a smoke test shows no regressions and that the channel remains usable.

## 6) Server-side Cancellation Verification (Stronger Proof)

### Current status
- `ServerCall.isCancelled` exists.
- Current streaming cancel tests primarily assert the **client** receives a cancellation-related error; they may not strictly prove the server handler stopped promptly.

### Plan
- Strengthen tests to prove the handler observed cancellation and stopped doing work:
  - Add a server method that loops doing “work units” (e.g., increments a counter and/or tries to send messages).
  - On cancellation, the handler records a terminal signal (e.g., sets an `IO.Ref Bool` / `MVar`) and exits.
  - The test asserts:
    1) client cancellation triggers a non-OK termination, and
    2) the server-side signal is observed within a bounded time.
- Prefer **Lean↔Lean** verification first (shared in-process signaling), then mirror as much as possible in **Go↔Lean** (e.g., via an additional RPC that queries server state, or via trailers).

### Definition of done
- A test demonstrates cancellation causes the server handler to stop within a small bound (e.g., < 250ms), not merely that the client observes an error.

## Work Breakdown (Where Changes Likely Land)

- Metadata/binary metadata:
  - `Legate/Metadata.lean`
  - `Legate/Internal/FFI.lean`
  - `ffi/src/legate_ffi.cpp`
  - `Tests/integration/Client.lean`, `Tests/integration/Server.lean`
  - `Tests/integration/go/*` (interop additions)
- Compression / keepalives / max message sizes:
  - `Legate/Metadata.lean` (for `CallOptions` additions)
  - `Legate/Channel.lean` (new channel constructors/options)
  - `Legate/Server.lean` (server builder options)
  - `Legate/Internal/FFI.lean`, `ffi/src/legate_ffi.cpp`
- UDS:
  - `Legate/Server.lean`, `Legate/Channel.lean`
  - `ffi/src/legate_ffi.cpp` (server port helper behavior)
  - Integration tests for socket-path lifecycle (create/remove socket paths safely)

## Acceptance Checklist

- [ ] Binary metadata (`*-bin`) is supported and tested (including NUL bytes).
- [ ] Max message size options exist (channel + server) and have deterministic `ResourceExhausted` tests.
- [ ] gzip compression can be enabled and has end-to-end tests.
- [ ] UDS is explicitly supported via API and has an end-to-end test.
- [ ] Keepalive knobs exist; at least one smoke test ensures channels remain usable after idling.
- [ ] Cancellation tests prove server handlers stop work promptly.

