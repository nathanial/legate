/-
  Lean gRPC server implementing TestService.

  Can be tested by the Go client.
-/
import Legate
import Protolean
import Tests.integration.Proto

namespace Tests.integration.Server

open Legate
open Legate.Test

/-- Echo incoming `x-legate-test` header back as trailing metadata. -/
def testTrailers (ctx : ServerContext) : Metadata :=
  match ctx.metadata.get? "x-legate-test" with
  | some v => #[("x-legate-test", v)]
  | none => #[]

def maybeSleepFromMetadata (ctx : ServerContext) : IO Unit := do
  match ctx.metadata.get? "x-sleep-ms" with
  | some s =>
    match s.toNat? with
    | some ms =>
      IO.sleep (UInt32.ofNat ms)
    | none => pure ()
  | none => pure ()

def maybeWaitForCancel (ctx : ServerContext) : IO Bool := do
  match ctx.metadata.get? "x-wait-cancel" with
  | none => return false
  | some _ =>
    while !(← ctx.call.isCancelled) do
      IO.sleep 10
    return true

/-- Echo handler: returns "ECHO:" + request data -/
def handleEcho (ctx : ServerContext) (requestBytes : ByteArray)
    : IO (GrpcResult (ByteArray × Metadata)) := do
  if (← maybeWaitForCancel ctx) then
    return .error (GrpcError.mk .cancelled "Cancelled" none)

  maybeSleepFromMetadata ctx

  match Protolean.decodeMessage (α := EchoRequest) requestBytes with
  | .ok request =>
    let responseData := "ECHO:".toUTF8 ++ request.data
    let response : EchoResponse := { data := responseData }
    return .ok (Protolean.encodeMessage response, testTrailers ctx)
  | .error e =>
    return .error (GrpcError.mk .invalidArgument s!"Decode error: {e}" none)

/-- Collect handler: joins all messages with "|"
    Note: Streaming handlers are not yet fully implemented in the FFI.
-/
def handleCollect (_ctx : ServerContext) (recv : IO (Option ByteArray))
    : IO (GrpcResult (ByteArray × Metadata)) := do
  -- Read all messages using a loop
  let mut parts : Array ByteArray := #[]
  let mut count : Int32 := 0
  let mut done := false
  while !done do
    match ← recv with
    | some bytes =>
      match Protolean.decodeMessage (α := CollectRequest) bytes with
      | .ok request =>
        parts := parts.push request.data
        count := count + 1
      | .error _ => pure ()  -- Skip malformed messages
    | none => done := true

  -- Join with "|"
  let joined := parts.foldl (init := ByteArray.empty) fun acc part =>
    if acc.isEmpty then part
    else acc ++ "|".toUTF8 ++ part

  let response : CollectResponse := { data := joined, count := count }
  return .ok (Protolean.encodeMessage response, testTrailers _ctx)

/-- Expand handler: sends N numbered responses
    Note: Streaming handlers are not yet fully implemented in the FFI.
-/
def handleExpand (_ctx : ServerContext) (requestBytes : ByteArray) (send : ByteArray → IO Unit)
    : IO (GrpcResult Metadata) := do
  match Protolean.decodeMessage (α := ExpandRequest) requestBytes with
  | .ok request =>
    for i in [:request.count.toInt.toNat] do
      let data := s!"{String.fromUTF8! request.prefix_}:{i}".toUTF8
      let response : ExpandResponse := { data := data, sequence := i.toInt32 }
      send (Protolean.encodeMessage response)
    return .ok (testTrailers _ctx)
  | .error e =>
    return .error (GrpcError.mk .invalidArgument s!"Decode error: {e}" none)

/-- BiEcho handler: echoes each message with sequence number
    Note: Streaming handlers are not yet fully implemented in the FFI.
-/
def handleBiEcho (_ctx : ServerContext) (recv : IO (Option ByteArray)) (send : ByteArray → IO Unit)
    : IO (GrpcResult Metadata) := do
  let mut seq : Int32 := 0
  let mut done := false
  while !done do
    match ← recv with
    | some bytes =>
      match Protolean.decodeMessage (α := BiEchoRequest) bytes with
      | .ok request =>
        let data := s!"{seq}:{String.fromUTF8! request.data}".toUTF8
        let response : BiEchoResponse := { data := data, sequence := seq }
        send (Protolean.encodeMessage response)
        seq := seq + 1
      | .error _ => pure ()  -- Skip malformed
    | none => done := true

  return .ok (testTrailers _ctx)

/-- Start the Lean TestService server -/
def runTestServer (port : Nat := 50051) : IO Unit := do
  let addr := s!"0.0.0.0:{port}"
  IO.println s!"Starting Lean TestService server on {addr}"

  runServer addr fun builder => do
    builder.registerUnary "/legate.test.TestService/Echo" handleEcho
    builder.registerClientStreaming "/legate.test.TestService/Collect" handleCollect
    builder.registerServerStreaming "/legate.test.TestService/Expand" handleExpand
    builder.registerBidiStreaming "/legate.test.TestService/BiEcho" handleBiEcho

end Tests.integration.Server
