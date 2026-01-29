# CLAUDE.md - Legate

gRPC library for Lean 4. Provides generic transport layer (raw bytes) - serialization handled separately (use Protolean for Protocol Buffers).

## Build

```bash
# First time: build FFI (compiles gRPC C++ from Homebrew)
lake run buildFfi

# Then build Lean library
lake build

# Run tests
./run-tests.sh        # Full suite (unit + integration)
lake test             # Unit tests only
```

**Requires:** Homebrew gRPC (`brew install grpc abseil`)

## Project Structure

```
Legate/
  Error.lean      # StatusCode, GrpcError, GrpcResult
  Status.lean     # Status (code + message + details)
  Metadata.lean   # Headers/trailers, CallOptions
  Channel.lean    # Client connection, TLS/mTLS
  Call.lean       # Unary RPC
  Stream.lean     # Streaming RPC (client/server/bidi)
  Server.lean     # Server-side API
  Internal/
    FFI.lean      # Low-level FFI bindings
ffi/
  src/legate_ffi.cpp   # C++ gRPC wrapper
  CMakeLists.txt
Tests/                 # Unit tests
tests/integration/     # Go interop tests
```

## Key Types

| Type | Description |
|------|-------------|
| `Channel` | Connection to gRPC server |
| `StatusCode` | gRPC status codes (.ok, .cancelled, .unavailable, etc.) |
| `GrpcError` | Error with code, message, optional details |
| `GrpcResult α` | `Except GrpcError α` |
| `Metadata` | `Array (String × String)` for headers/trailers |
| `CallOptions` | timeoutMs, metadata, waitForReady |
| `Status` | Final RPC status (code, message, details) |

## Client API

```lean
import Legate

-- Create channel
let channel ← Channel.createInsecure "localhost:50051"
let channel ← Channel.createSecure "host:443" { rootCerts, privateKey, certChain }

-- Unary call
let response ← unaryCall channel "/pkg.Service/Method" requestBytes
-- response : GrpcResult UnaryResponse
-- response.data : ByteArray, response.headers, response.trailers

-- Client streaming (send many, receive one)
let stream ← clientStreamingCall channel "/pkg.Service/Method"
stream.write msg1
stream.write msg2
stream.writesDone
let response ← stream.finish

-- Server streaming (send one, receive many)
let stream ← serverStreamingCall channel "/pkg.Service/Method" requestBytes
stream.readAll  -- or stream.forEach, stream.fold

-- Bidirectional streaming
let stream ← bidiStreamingCall channel "/pkg.Service/Method"
stream.write msg
let response ← stream.read  -- Option ByteArray
stream.writesDone
```

## Server API

```lean
import Legate

def main : IO Unit := do
  let builder ← ServerBuilder.new
  let port ← builder.addInsecurePort "0.0.0.0:50051"

  -- Register handlers
  builder.registerUnary "/pkg.Service/Method" fun ctx request =>
    return .ok (responseBytes, trailers)

  builder.registerServerStreaming "/pkg.Service/Stream" fun ctx request send =>
    send msg1
    send msg2
    return .ok trailers

  let server ← builder.build
  server.run
```

## CallOptions

```lean
-- With timeout (milliseconds)
unaryCall channel method request { timeoutMs := 5000 }

-- With metadata (headers)
unaryCall channel method request { metadata := #[("auth", "token123")] }

-- Wait for channel ready (default: fail fast)
unaryCall channel method request { waitForReady := true }
```

## TLS/mTLS

```lean
-- TLS with system roots
Channel.createSecure "host:443"

-- TLS with custom CA
Channel.createSecure "host:443" { rootCerts := caPem }

-- mTLS (mutual TLS)
Channel.createSecure "host:443" {
  rootCerts := caPem
  privateKey := clientKeyPem
  certChain := clientCertPem
}

-- Server with TLS
builder.addSecurePort "0.0.0.0:443" serverCertPem serverKeyPem rootCertsPem
```

## Error Handling

```lean
match ← unaryCall channel method request with
| .ok response => IO.println s!"Got: {response.data.size} bytes"
| .error e =>
  IO.eprintln s!"Error: {e.code} - {e.message}"
  -- e.details : Option ByteArray (rich error details)
```

Common status codes: `.ok`, `.cancelled`, `.deadlineExceeded`, `.unavailable`, `.unauthenticated`, `.permissionDenied`, `.notFound`, `.internal`

## Stream Cancellation

```lean
-- Client cancels stream
stream.cancel

-- Server checks if cancelled
ctx.isCancelled
ctx.getDeadlineRemaining  -- Option UInt64 (ms)
```

## Dependencies

- `protolean` - Protocol Buffers for Lean (message serialization)
- `crucible` - Test framework

## FFI Pattern

```lean
-- Opaque handle (Legate/Internal/FFI.lean)
opaque ChannelPointed : NonemptyType
def Channel : Type := ChannelPointed.type

@[extern "legate_channel_create_insecure"]
opaque channelCreateInsecure : String → IO Channel
```

## Environment Variables

- `LEGATE_SERVER_WORKERS` - Worker pool size for server handlers
- `LEGATE_DEBUG_SERVER` - Enable debug output

## Current Limitations

- Synchronous streaming (async Task integration planned)
- No connection pooling
- No client/server interceptors
- No compression support
- No binary metadata (`*-bin` keys)

See ROADMAP.md for planned features.
