# Legate

A generic gRPC library for Lean 4.

Legate provides low-level gRPC transport functionality, allowing you to make and handle gRPC calls using raw bytes (`ByteArray`). This design separates transport from serialization, making it easy to integrate with any serialization library (Protocol Buffers, JSON, MessagePack, etc.).

## Features

- **Client Support**: Create channels and make RPC calls to gRPC servers
- **Server Support**: Build servers that handle incoming gRPC requests
- **All Streaming Modes**: Unary, client streaming, server streaming, and bidirectional streaming
- **Generic Transport**: Works with raw bytes - bring your own serialization
- **Type-Safe API**: Lean 4's type system ensures correct usage

## Requirements

- Lean 4 v4.26.0 or later
- CMake 3.16+
- C++17 compatible compiler

## Building

### 1. Clone with submodules

```bash
git clone --recursive https://github.com/yourusername/legate.git
cd legate
```

Or if you already cloned without `--recursive`:

```bash
git submodule update --init third_party/grpc
cd third_party/grpc
git checkout v1.68.2
git submodule update --init third_party/abseil-cpp third_party/boringssl-with-bazel \
    third_party/cares/cares third_party/protobuf third_party/re2 third_party/zlib
```

### 2. Build the FFI library

```bash
lake run buildFfi
```

This will compile gRPC and the FFI wrapper. The first build takes significant time as it compiles gRPC from source.

### 3. Build the Lean library

```bash
lake build
```

## Quick Start

### Client Usage

```lean
import Legate

def main : IO Unit := do
  -- Create a channel to the server
  let channel ← Legate.Channel.createInsecure "localhost:50051"

  -- Wait for connection (optional)
  if ← channel.waitForReady then
    -- Make a unary call
    let request := "Hello".toUTF8
    match ← Legate.unaryCall channel "/example.Greeter/SayHello" request with
    | .ok response =>
      IO.println s!"Response: {String.fromUTF8! response.data}"
    | .error e =>
      IO.eprintln s!"Error: {e}"
  else
    IO.eprintln "Failed to connect"
```

### Server Usage

```lean
import Legate

def main : IO Unit := do
  let builder ← Legate.ServerBuilder.new
  let port ← builder.addInsecurePort "0.0.0.0:50051"
  IO.println s!"Server listening on port {port}"

  -- Register handlers (simplified - full implementation requires FFI handler support)
  -- builder.registerUnary "/example.Greeter/SayHello" fun ctx request =>
  --   let response := s!"Hello, {String.fromUTF8! request}!".toUTF8
  --   return .ok (response, #[])

  let server ← builder.build
  server.run
```

### Streaming Example

```lean
import Legate

def streamingExample : IO Unit := do
  let channel ← Legate.Channel.createInsecure "localhost:50051"

  -- Server streaming: get multiple responses
  match ← Legate.serverStreamingCall channel "/example.Stream/GetData" "query".toUTF8 with
  | .ok stream =>
    -- Read all messages
    match ← stream.readAll with
    | .ok messages =>
      for msg in messages do
        IO.println s!"Received: {String.fromUTF8! msg}"
    | .error e => IO.eprintln s!"Stream error: {e}"
  | .error e => IO.eprintln s!"Call failed: {e}"
```

## API Overview

### Types

| Type | Description |
|------|-------------|
| `Channel` | Connection to a gRPC server |
| `StatusCode` | gRPC status codes (ok, cancelled, unknown, etc.) |
| `GrpcError` | Error with code, message, and optional details |
| `GrpcResult α` | `Except GrpcError α` - result type for gRPC operations |
| `Metadata` | Key-value pairs for headers/trailers |
| `CallOptions` | Timeout, metadata, wait-for-ready settings |

`CallOptions.waitForReady` follows gRPC semantics: when `true`, the RPC will wait for the channel to become ready (up to the deadline); when `false`, calls to an unavailable server fail fast with `Unavailable`.

### Client Functions

```lean
-- Create channels
Channel.createInsecure : String → IO Channel
Channel.createSecure : String → SslCredentials → IO Channel

-- Unary call
unaryCall : Channel → String → ByteArray → CallOptions → IO (GrpcResult UnaryResponse)

-- Streaming calls
clientStreamingCall : Channel → String → CallOptions → IO (GrpcResult ClientStreamWriter)
serverStreamingCall : Channel → String → ByteArray → CallOptions → IO (GrpcResult ServerStreamReader)
bidiStreamingCall : Channel → String → CallOptions → IO (GrpcResult BidiStream)
```

### Stream Operations

```lean
-- Client stream (for sending)
ClientStreamWriter.write : ByteArray → IO (GrpcResult Unit)
ClientStreamWriter.writesDone : IO (GrpcResult Unit)
ClientStreamWriter.finish : IO (GrpcResult ClientStreamResponse)

-- Server stream (for receiving)
ServerStreamReader.read : IO (GrpcResult (Option ByteArray))
ServerStreamReader.readAll : IO (GrpcResult (Array ByteArray))
ServerStreamReader.forEach : (ByteArray → IO Unit) → IO Status

-- Bidirectional stream
BidiStream.write : ByteArray → IO (GrpcResult Unit)
BidiStream.read : IO (GrpcResult (Option ByteArray))
BidiStream.writesDone : IO (GrpcResult Unit)
```

## Architecture

```
┌─────────────────────────────────────────┐
│           Lean Application              │
├─────────────────────────────────────────┤
│  Legate (Lean 4 gRPC Library)           │
│  - Channel, Server, Stream types        │
│  - Error handling, Metadata             │
├─────────────────────────────────────────┤
│  FFI Layer (C++ with C ABI)             │
│  - legate_ffi.cpp                       │
│  - Wrappers for gRPC objects            │
├─────────────────────────────────────────┤
│  gRPC C++ (v1.68.x)                     │
│  - Generic stub/service                 │
│  - All transport functionality          │
└─────────────────────────────────────────┘
```

## Testing

Run the complete test suite (unit + integration tests):

```bash
./run-tests.sh
```

Or run tests separately:

```bash
# Lean unit tests only
lake test

# Go gRPC integration tests only
cd tests/integration/go
make build
./testapp server -port 50051 &
./testapp client -addr localhost:50051 -test all
```

The integration tests use a Go gRPC application that acts as both server and client to verify all four RPC patterns work correctly with real gRPC communication.

## Project Structure

```
legate/
├── Legate.lean              # Main library entry point
├── Legate/
│   ├── Call.lean            # Unary RPC
│   ├── Channel.lean         # Client channels
│   ├── Error.lean           # Error types and status codes
│   ├── Metadata.lean        # Headers/trailers/options
│   ├── Server.lean          # Server-side API
│   ├── Status.lean          # RPC status
│   ├── Stream.lean          # Streaming RPC
│   └── Internal/
│       └── FFI.lean         # Low-level FFI bindings
├── ffi/
│   ├── CMakeLists.txt       # CMake build config
│   └── src/
│       └── legate_ffi.cpp   # C++ gRPC wrapper
├── Tests/                   # Lean unit tests
├── tests/
│   └── integration/
│       └── go/              # Go gRPC integration tests
├── third_party/
│   └── grpc/                # gRPC C++ submodule
├── lakefile.lean            # Lake build configuration
└── run-tests.sh             # Test runner script
```

## Project Status

This library provides the core gRPC transport layer. Current status:

- [x] Channel creation (insecure and TLS)
- [x] Mutual TLS (mTLS) client auth
- [x] Unary calls
- [x] Client streaming
- [x] Server streaming
- [x] Bidirectional streaming
- [x] Metadata support
- [x] Timeout support
- [ ] Server handler dispatch (placeholder implementation)
- [ ] Async Task integration
- [ ] Connection pooling
- [ ] Load balancing configuration

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions are welcome! Please open an issue or pull request.
