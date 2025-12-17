# Legate gRPC Integration Test Application

A Go gRPC application for integration testing the Legate Lean 4 gRPC library.

## Prerequisites

- Go 1.21 or later
- Protocol Buffer compiler (`protoc`)
- Go gRPC plugins

### Installing protoc

macOS:
```bash
brew install protobuf
```

Linux:
```bash
apt install -y protobuf-compiler
```

### Installing Go gRPC Plugins

```bash
make install-tools
```

Or manually:
```bash
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
```

## Building

```bash
# Generate proto and build binary
make all

# Or step by step:
make proto   # Generate Go code from proto
make build   # Build the testapp binary
```

## Usage

### Running the Server

```bash
# Default: listen on 0.0.0.0:50051
./testapp server

# Custom port
./testapp server -port 50052

# Custom host and port
./testapp server -host 127.0.0.1 -port 50052
```

### Running the Client

```bash
# Run all tests against localhost:50051
./testapp client -test all

# Run specific test
./testapp client -test unary
./testapp client -test client-stream
./testapp client -test server-stream
./testapp client -test bidi

# Custom server address
./testapp client -addr localhost:50052 -test all

# Custom test data and count
./testapp client -test bidi -data "test" -count 10
```

## Test Service

The `TestService` implements all four gRPC patterns:

| Method | Type | Description |
|--------|------|-------------|
| `Echo` | Unary | Returns `"ECHO:" + request` |
| `Collect` | Client Streaming | Joins messages with `"\|"` |
| `Expand` | Server Streaming | Sends N numbered responses |
| `BiEcho` | Bidirectional | Echoes with sequence numbers |

### gRPC Method Paths

For use with Legate's transport-only API:

- `/legate.test.TestService/Echo`
- `/legate.test.TestService/Collect`
- `/legate.test.TestService/Expand`
- `/legate.test.TestService/BiEcho`

## Integration Testing with Legate

### Testing Lean Client with Go Server

Terminal 1:
```bash
cd tests/integration/go
./testapp server -port 50051
```

Terminal 2:
```bash
cd /path/to/legate
# Run Lean client tests that connect to localhost:50051
```

### Testing Lean Server with Go Client

Terminal 1:
```bash
cd /path/to/legate
# Start Lean server on port 50051
```

Terminal 2:
```bash
cd tests/integration/go
./testapp client -addr localhost:50051 -test all
```

## Test Data Flow

### Unary (Echo)
```
Client                    Server
  |-- "hello" ----------->|
  |<----- "ECHO:hello" ---|
```

### Client Streaming (Collect)
```
Client                    Server
  |-- "a" --------------->|
  |-- "b" --------------->|
  |-- "c" --------------->|
  |<----- "a|b|c" --------|
```

### Server Streaming (Expand)
```
Client                    Server
  |-- count=3, prefix="x" |
  |<----- "x:0" ----------|
  |<----- "x:1" ----------|
  |<----- "x:2" ----------|
```

### Bidirectional (BiEcho)
```
Client                    Server
  |-- "a" --------------->|
  |<----- "0:a" ----------|
  |-- "b" --------------->|
  |<----- "1:b" ----------|
```

## Cleaning Up

```bash
make clean  # Remove generated files and binary
```
