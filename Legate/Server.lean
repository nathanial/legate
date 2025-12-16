/-
  Legate - gRPC for Lean 4
  Server-side abstractions
-/

import Legate.Error
import Legate.Status
import Legate.Metadata
import Legate.Internal.FFI

namespace Legate

/-- Context for an incoming server call -/
structure ServerContext where
  /-- The full method name being called -/
  method : String
  /-- Client metadata (headers) -/
  metadata : Metadata
  /-- The peer address (if available) -/
  peer : String := ""
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

/-- Handler for unary RPCs: receives request, returns response -/
abbrev UnaryHandler :=
  ServerContext → ByteArray → IO (GrpcResult (ByteArray × Metadata))

/-- Handler for client streaming RPCs: receives stream of requests, returns response -/
abbrev ClientStreamingHandler :=
  ServerContext → (IO (Option ByteArray)) → IO (GrpcResult (ByteArray × Metadata))

/-- Handler for server streaming RPCs: receives request, writes to response stream -/
abbrev ServerStreamingHandler :=
  ServerContext → ByteArray → (ByteArray → IO Unit) → IO (GrpcResult Metadata)

/-- Handler for bidirectional streaming RPCs -/
abbrev BidiStreamingHandler :=
  ServerContext → (IO (Option ByteArray)) → (ByteArray → IO Unit) → IO (GrpcResult Metadata)

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
    Note: TLS credentials configuration is not yet fully implemented.
-/
def addSecurePort (builder : ServerBuilder) (addr : String) : IO UInt32 :=
  Internal.serverBuilderAddListeningPort builder.handle addr 1

/-- Register a unary handler for a method -/
def registerUnary
    (builder : ServerBuilder)
    (method : String)
    (handler : UnaryHandler)
    : IO Unit := do
  -- Note: The actual handler registration with proper Lean closure support
  -- requires more complex FFI. This is a placeholder.
  Internal.serverBuilderRegisterHandler builder.handle method 0 (pure ())

/-- Register a client streaming handler for a method -/
def registerClientStreaming
    (builder : ServerBuilder)
    (method : String)
    (handler : ClientStreamingHandler)
    : IO Unit := do
  Internal.serverBuilderRegisterHandler builder.handle method 1 (pure ())

/-- Register a server streaming handler for a method -/
def registerServerStreaming
    (builder : ServerBuilder)
    (method : String)
    (handler : ServerStreamingHandler)
    : IO Unit := do
  Internal.serverBuilderRegisterHandler builder.handle method 2 (pure ())

/-- Register a bidirectional streaming handler for a method -/
def registerBidiStreaming
    (builder : ServerBuilder)
    (method : String)
    (handler : BidiStreamingHandler)
    : IO Unit := do
  Internal.serverBuilderRegisterHandler builder.handle method 3 (pure ())

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
        return .ok (req, #[])
    ```
-/
def runServer (addr : String) (configure : ServerBuilder → IO Unit) : IO Unit := do
  let builder ← ServerBuilder.new
  let _ ← builder.addInsecurePort addr
  configure builder
  let server ← builder.build
  server.run

end Legate
