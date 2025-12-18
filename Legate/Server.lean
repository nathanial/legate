/-
  Legate - gRPC for Lean 4
  Server-side abstractions
-/

import Legate.Error
import Legate.Status
import Legate.Metadata
import Legate.Internal.FFI

namespace Legate

/-- Handle to an in-flight server call (deadline/cancellation). -/
structure ServerCall where
  private mk ::
  private handle : Internal.ServerCall

namespace ServerCall

/-- Check whether the client has cancelled this call. -/
def isCancelled (call : ServerCall) : IO Bool :=
  Internal.serverCallIsCancelled call.handle

/-- Send initial metadata (response headers) for this call.

    This is primarily useful for server-streaming and bidi-streaming handlers
    that need response headers available before the first message is sent.
    It must be called before sending the first response message.
-/
def sendInitialMetadata (call : ServerCall) (headers : Metadata) : IO Unit :=
  Internal.serverCallSendInitialMetadata call.handle headers

/-- Remaining time until the call deadline (ms), or `none` if no deadline. -/
def deadlineRemainingMs (call : ServerCall) : IO (Option UInt64) :=
  Internal.serverCallDeadlineRemainingMs call.handle

end ServerCall

/-- Context for an incoming server call -/
structure ServerContext where
  /-- The full method name being called -/
  method : String
  /-- Client metadata (headers) -/
  metadata : Metadata
  /-- Call handle for deadline/cancellation queries -/
  call : ServerCall
  /-- The peer address (if available) -/
  peer : String := ""

/-- Client certificate authentication type for mTLS -/
inductive ClientAuthType where
  /-- Don't request client certificate -/
  | none
  /-- Request client certificate, verify if provided -/
  | request
  /-- Require client certificate and verify -/
  | require
  deriving Repr, DecidableEq, BEq

namespace ClientAuthType

def toUInt8 (t : ClientAuthType) : UInt8 :=
  match t with
  | .none => 0
  | .request => 1
  | .require => 2

end ClientAuthType

/-- SSL/TLS credentials for secure server connections -/
structure SslServerCredentials where
  /-- PEM-encoded server certificate chain -/
  serverCert : String
  /-- PEM-encoded server private key -/
  serverKey : String
  /-- PEM-encoded root certificates for client verification (optional, for mTLS) -/
  rootCerts : String := ""
  /-- Client certificate authentication type -/
  clientAuth : ClientAuthType := .none
  deriving Repr

/-- A builder for configuring a gRPC server -/
structure ServerBuilder where
  private mk ::
  private handle : Internal.ServerBuilder

/-- A running gRPC server -/
structure Server where
  private mk ::
  private handle : Internal.Server

-- ============================================================================
-- Handler Types
-- ============================================================================

/-- Handler for unary RPCs: receives request, returns (response, headers, trailers) -/
abbrev UnaryHandler :=
  ServerContext → ByteArray → IO (GrpcResult (ByteArray × Metadata × Metadata))

/-- Handler for client streaming RPCs: receives stream of requests, returns (response, headers, trailers) -/
abbrev ClientStreamingHandler :=
  ServerContext → (IO (Option ByteArray)) → IO (GrpcResult (ByteArray × Metadata × Metadata))

/-- Handler for server streaming RPCs: receives request, writes to response stream, returns (headers, trailers) -/
abbrev ServerStreamingHandler :=
  ServerContext → ByteArray → (ByteArray → IO Unit) → IO (GrpcResult (Metadata × Metadata))

/-- Handler for bidirectional streaming RPCs: returns (headers, trailers) -/
abbrev BidiStreamingHandler :=
  ServerContext → (IO (Option ByteArray)) → (ByteArray → IO Unit) → IO (GrpcResult (Metadata × Metadata))

/-- Type of service handler -/
inductive HandlerType where
  | unary
  | clientStreaming
  | serverStreaming
  | bidiStreaming
  deriving Repr, DecidableEq

namespace HandlerType

def toUInt8 (t : HandlerType) : UInt8 :=
  match t with
  | .unary => 0
  | .clientStreaming => 1
  | .serverStreaming => 2
  | .bidiStreaming => 3

end HandlerType

-- ============================================================================
-- Server Builder
-- ============================================================================

namespace ServerBuilder

/-- Create a new server builder -/
def new : IO ServerBuilder := do
  let handle ← Internal.serverBuilderNew
  return ⟨handle⟩

/-- Add a listening port for insecure connections.

    Returns the actually bound port (which may differ if 0 was specified).
-/
def addInsecurePort (builder : ServerBuilder) (addr : String) : IO UInt32 :=
  Internal.serverBuilderAddListeningPort builder.handle addr 0

/-- Add a listening port for TLS connections.

    Returns the actually bound port (which may differ if 0 was specified).

    Example:
    ```lean
    let creds : SslServerCredentials := {
      serverCert := serverCertPem,
      serverKey := serverKeyPem,
      -- For mTLS, also set:
      -- rootCerts := caCertPem,
      -- clientAuth := .require
    }
    let port ← builder.addSecurePort "0.0.0.0:0" creds
    ```
-/
def addSecurePort (builder : ServerBuilder) (addr : String) (creds : SslServerCredentials) : IO UInt32 :=
  Internal.serverBuilderAddSecureListeningPort
    builder.handle
    addr
    creds.rootCerts
    creds.serverCert
    creds.serverKey
    creds.clientAuth.toUInt8

/-- Register a unary handler for a method -/
def registerUnary
    (builder : ServerBuilder)
    (method : String)
    (handler : UnaryHandler)
    : IO Unit := do
  -- Adapt user handler to FFI signature
  let ffiHandler := fun (c : Internal.ServerCall) (m : String) (md : Metadata) (req : ByteArray) => do
    let ctx : ServerContext := { method := m, metadata := md, call := ⟨c⟩ }
    handler ctx req
  Internal.serverRegisterUnary builder.handle method ffiHandler

/-- Register a client streaming handler for a method -/
def registerClientStreaming
    (builder : ServerBuilder)
    (method : String)
    (handler : ClientStreamingHandler)
    : IO Unit := do
  -- Adapt user handler to FFI signature
  let ffiHandler := fun (c : Internal.ServerCall) (m : String) (md : Metadata) (recv : IO (Option ByteArray)) => do
    let ctx : ServerContext := { method := m, metadata := md, call := ⟨c⟩ }
    handler ctx recv
  Internal.serverRegisterClientStreaming builder.handle method ffiHandler

/-- Register a server streaming handler for a method -/
def registerServerStreaming
    (builder : ServerBuilder)
    (method : String)
    (handler : ServerStreamingHandler)
    : IO Unit := do
  -- Adapt user handler to FFI signature
  let ffiHandler := fun (c : Internal.ServerCall) (m : String) (md : Metadata) (req : ByteArray) (send : ByteArray → IO Unit) => do
    let ctx : ServerContext := { method := m, metadata := md, call := ⟨c⟩ }
    handler ctx req send
  Internal.serverRegisterServerStreaming builder.handle method ffiHandler

/-- Register a bidirectional streaming handler for a method -/
def registerBidiStreaming
    (builder : ServerBuilder)
    (method : String)
    (handler : BidiStreamingHandler)
    : IO Unit := do
  -- Adapt user handler to FFI signature
  let ffiHandler := fun (c : Internal.ServerCall) (m : String) (md : Metadata) (recv : IO (Option ByteArray)) (send : ByteArray → IO Unit) => do
    let ctx : ServerContext := { method := m, metadata := md, call := ⟨c⟩ }
    handler ctx recv send
  Internal.serverRegisterBidiStreaming builder.handle method ffiHandler

/-- Build the server.

    After this call, the builder should not be used again.
-/
def build (builder : ServerBuilder) : IO Server := do
  let handle ← Internal.serverBuilderBuild builder.handle
  return ⟨handle⟩

end ServerBuilder

-- ============================================================================
-- Server
-- ============================================================================

namespace Server

/-- Start the server (non-blocking).

    After this call, the server will begin accepting connections.
-/
def start (server : Server) : IO Unit :=
  Internal.serverStart server.handle

/-- Wait for the server to shut down.

    This blocks until the server is shut down via `shutdown`.
-/
def wait (server : Server) : IO Unit :=
  Internal.serverWait server.handle

/-- Gracefully shut down the server.

    Existing RPCs will be allowed to complete.
-/
def shutdown (server : Server) : IO Unit :=
  Internal.serverShutdown server.handle

/-- Immediately shut down the server.

    In-flight RPCs will be cancelled.
-/
def shutdownNow (server : Server) : IO Unit :=
  Internal.serverShutdownNow server.handle

/-- Run the server until shutdown.

    This is a convenience function that starts the server and waits
    for it to shut down. Use `shutdown` from another task/thread
    to stop the server.
-/
def run (server : Server) : IO Unit := do
  server.start
  server.wait

end Server

-- ============================================================================
-- Convenience Functions
-- ============================================================================

/-- Create and run a simple server.

    Example:
    ```lean
    Legate.runServer "0.0.0.0:50051" fun builder => do
      builder.registerUnary "/example.Echo/Echo" fun ctx req =>
        -- Return (response, headers, trailers)
        return .ok (req, #[], #[])
    ```
-/
def runServer (addr : String) (configure : ServerBuilder → IO Unit) : IO Unit := do
  let builder ← ServerBuilder.new
  let _ ← builder.addInsecurePort addr
  configure builder
  let server ← builder.build
  server.run

/-- Create and run a TLS server.

    Example:
    ```lean
    let creds : SslServerCredentials := {
      serverCert := serverCertPem,
      serverKey := serverKeyPem,
    }
    Legate.runSecureServer "0.0.0.0:50051" creds fun builder => do
      builder.registerUnary "/example.Echo/Echo" fun ctx req =>
        return .ok (req, #[], #[])
    ```
-/
def runSecureServer (addr : String) (creds : SslServerCredentials) (configure : ServerBuilder → IO Unit) : IO Unit := do
  let builder ← ServerBuilder.new
  let _ ← builder.addSecurePort addr creds
  configure builder
  let server ← builder.build
  server.run

end Legate
