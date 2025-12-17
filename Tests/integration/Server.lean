/-
  Lean gRPC server implementing TestService.

  Can be tested by the Go client.
-/
import Legate
import Protolean

namespace Tests.integration.Server

-- Import proto types at compile time
proto_import "Proto/legate_test.proto"

open Legate
open legate.test  -- namespace from proto package

/-- Echo handler: returns "ECHO:" + request data -/
def handleEcho (ctx : ServerContext) (requestBytes : ByteArray)
    : IO (GrpcResult (ByteArray × Metadata)) := do
  match Protolean.decodeMessage requestBytes with
  | .ok (request : EchoRequest) =>
    let responseData := "ECHO:".toUTF8 ++ request.data
    let response : EchoResponse := { data := responseData }
    return .ok (Protolean.encodeMessage response, #[])
  | .error e =>
    return .error (GrpcError.mk .invalidArgument s!"Decode error: {e}" none)

/-- Collect handler: joins all messages with "|"
    Note: Streaming handlers are not yet fully implemented in the FFI.
    This is a placeholder that will be enabled when streaming is supported.
-/
def handleCollect (ctx : ServerContext) (recv : IO (Option ByteArray))
    : IO (GrpcResult (ByteArray × Metadata)) := do
  let mut parts : Array ByteArray := #[]
  let mut count : Int32 := 0

  -- Read all messages
  let rec loop : IO Unit := do
    match ← recv with
    | some bytes =>
      match Protolean.decodeMessage bytes with
      | .ok (request : CollectRequest) =>
        parts := parts.push request.data
        count := count + 1
        loop
      | .error _ => loop  -- Skip malformed messages
    | none => pure ()

  loop

  -- Join with "|"
  let joined := parts.foldl (init := ByteArray.empty) fun acc part =>
    if acc.isEmpty then part
    else acc ++ "|".toUTF8 ++ part

  let response : CollectResponse := { data := joined, count := count }
  return .ok (Protolean.encodeMessage response, #[])

/-- Expand handler: sends N numbered responses
    Note: Streaming handlers are not yet fully implemented in the FFI.
-/
def handleExpand (ctx : ServerContext) (requestBytes : ByteArray) (send : ByteArray → IO Unit)
    : IO (GrpcResult Metadata) := do
  match Protolean.decodeMessage requestBytes with
  | .ok (request : ExpandRequest) =>
    for i in [:request.count.toNat] do
      let data := s!"{String.fromUTF8! request.prefix}:{i}".toUTF8
      let response : ExpandResponse := { data := data, sequence := i.toInt32 }
      send (Protolean.encodeMessage response)
    return .ok #[]
  | .error e =>
    return .error (GrpcError.mk .invalidArgument s!"Decode error: {e}" none)

/-- BiEcho handler: echoes each message with sequence number
    Note: Streaming handlers are not yet fully implemented in the FFI.
-/
def handleBiEcho (ctx : ServerContext) (recv : IO (Option ByteArray)) (send : ByteArray → IO Unit)
    : IO (GrpcResult Metadata) := do
  let mut seq : Int32 := 0

  let rec loop : IO Unit := do
    match ← recv with
    | some bytes =>
      match Protolean.decodeMessage bytes with
      | .ok (request : BiEchoRequest) =>
        let data := s!"{seq}:{String.fromUTF8! request.data}".toUTF8
        let response : BiEchoResponse := { data := data, sequence := seq }
        send (Protolean.encodeMessage response)
        seq := seq + 1
        loop
      | .error _ => loop  -- Skip malformed
    | none => pure ()

  loop
  return .ok #[]

/-- Start the Lean TestService server -/
def runTestServer (port : Nat := 50051) : IO Unit := do
  let addr := s!"0.0.0.0:{port}"
  IO.println s!"Starting Lean TestService server on {addr}"

  runServer addr fun builder => do
    builder.registerUnary "/legate.test.TestService/Echo" handleEcho
    -- Note: Streaming handlers registration - the handlers are defined but
    -- streaming FFI support is only partially implemented.
    -- These will return UNIMPLEMENTED until streaming is fully working.
    -- builder.registerClientStreaming "/legate.test.TestService/Collect" handleCollect
    -- builder.registerServerStreaming "/legate.test.TestService/Expand" handleExpand
    -- builder.registerBidiStreaming "/legate.test.TestService/BiEcho" handleBiEcho

end Tests.integration.Server
