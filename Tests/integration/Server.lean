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

def delayMsFromMetadata (ctx : ServerContext) : Option Nat :=
  ctx.metadata.get? "x-delay-ms" |>.bind String.toNat?

def errorAfterNFromMetadata (ctx : ServerContext) : Option Nat :=
  ctx.metadata.get? "x-error-after-n" |>.bind String.toNat?

def maybeDelayFromMetadata (ctx : ServerContext) : IO Unit := do
  match delayMsFromMetadata ctx with
  | none => pure ()
  | some ms => IO.sleep (UInt32.ofNat ms)

def maybeWaitForCancel (ctx : ServerContext) : IO Bool := do
  match ctx.metadata.get? "x-wait-cancel" with
  | none => return false
  | some _ =>
    while !(← ctx.call.isCancelled) do
      IO.sleep 10
    return true

/-- Check for x-return-error header and return error if present.
    Format: "code:message" -/
def maybeReturnError (ctx : ServerContext) : Option GrpcError :=
  match ctx.metadata.get? "x-return-error" with
  | none => none
  | some s =>
    let parts := s.splitOn ":"
    match parts with
    | [codeStr] =>
      let code := StatusCode.fromNat (codeStr.toNat?.getD 2)
      some (GrpcError.mk code "" none)
    | codeStr :: msgParts =>
      let code := StatusCode.fromNat (codeStr.toNat?.getD 2)
      let msg := ":".intercalate msgParts
      some (GrpcError.mk code msg none)
    | _ => some (GrpcError.mk .unknown "Invalid error format" none)

/-- Check for x-error-details header and return error details if present -/
def maybeGetErrorDetails (ctx : ServerContext) : Option ByteArray :=
  match ctx.metadata.get? "x-error-details" with
  | none => none
  | some s => some s.toUTF8

/-- Echo headers: echo the x-legate-test header back as initial metadata -/
def testHeaders (ctx : ServerContext) : Metadata :=
  match ctx.metadata.get? "x-legate-test" with
  | some v => #[("x-legate-response-header", v)]
  | none => #[]

/-- Echo handler: returns "ECHO:" + request data -/
def handleEcho (ctx : ServerContext) (requestBytes : ByteArray)
    : IO (GrpcResult (ByteArray × Metadata × Metadata)) := do
  if (← maybeWaitForCancel ctx) then
    return .error (GrpcError.mk .cancelled "Cancelled" none)

  maybeSleepFromMetadata ctx

  -- Check for error return request
  if let some e := maybeReturnError ctx then
    return .error { e with details := maybeGetErrorDetails ctx }

  match Protolean.decodeMessage (α := EchoRequest) requestBytes with
  | .ok request =>
    let responseData := "ECHO:".toUTF8 ++ request.data
    let response : EchoResponse := { data := responseData }
    -- Return (response, headers, trailers)
    return .ok (Protolean.encodeMessage response, testHeaders ctx, testTrailers ctx)
  | .error e =>
    return .error (GrpcError.mk .invalidArgument s!"Decode error: {e}" none)

/-- Collect handler: joins all messages with "|"
    Note: Streaming handlers are not yet fully implemented in the FFI.
-/
def handleCollect (ctx : ServerContext) (recv : IO (Option ByteArray))
    : IO (GrpcResult (ByteArray × Metadata × Metadata)) := do
  -- Check for error return request
  if let some e := maybeReturnError ctx then
    return .error { e with details := maybeGetErrorDetails ctx }

  let errorAfterN := errorAfterNFromMetadata ctx

  -- Read all messages using a loop
  let mut parts : Array ByteArray := #[]
  let mut count : Int32 := 0
  let mut done := false
  while !done do
    if (← ctx.call.isCancelled) then
      return .error (GrpcError.mk .cancelled "Cancelled" none)
    match ← recv with
    | some bytes =>
      match Protolean.decodeMessage (α := CollectRequest) bytes with
      | .ok request =>
        parts := parts.push request.data
        count := count + 1
        if let some n := errorAfterN then
          if parts.size >= n then
            return .error (GrpcError.mk .aborted s!"error after {parts.size} messages" none)
      | .error _ => pure ()  -- Skip malformed messages
      maybeDelayFromMetadata ctx
    | none => done := true

  -- Join with "|"
  let joined := parts.foldl (init := ByteArray.empty) fun acc part =>
    if acc.isEmpty then part
    else acc ++ "|".toUTF8 ++ part

  let response : CollectResponse := { data := joined, count := count }
  -- Return (response, headers, trailers)
  return .ok (Protolean.encodeMessage response, testHeaders ctx, testTrailers ctx)

/-- Expand handler: sends N numbered responses
    Note: Streaming handlers are not yet fully implemented in the FFI.
-/
def handleExpand (ctx : ServerContext) (requestBytes : ByteArray) (send : ByteArray → IO Unit)
    : IO (GrpcResult (Metadata × Metadata)) := do
  -- Check for error return request
  if let some e := maybeReturnError ctx then
    return .error { e with details := maybeGetErrorDetails ctx }

  match Protolean.decodeMessage (α := ExpandRequest) requestBytes with
  | .ok request =>
    -- Send initial metadata (response headers) before the first message
    ctx.call.sendInitialMetadata (testHeaders ctx)
    let errorAfterN := errorAfterNFromMetadata ctx
    for i in [:request.count.toInt.toNat] do
      if (← ctx.call.isCancelled) then
        return .error (GrpcError.mk .cancelled "Cancelled" none)
      if let some n := errorAfterN then
        if i >= n then
          return .error (GrpcError.mk .aborted s!"error after {i} messages" none)
      let data := s!"{String.fromUTF8! request.prefix_}:{i}".toUTF8
      let response : ExpandResponse := { data := data, sequence := i.toInt32 }
      send (Protolean.encodeMessage response)
      maybeDelayFromMetadata ctx
    -- Return (headers, trailers)
    return .ok (testHeaders ctx, testTrailers ctx)
  | .error e =>
    return .error (GrpcError.mk .invalidArgument s!"Decode error: {e}" none)

/-- BiEcho handler: echoes each message with sequence number
    Note: Streaming handlers are not yet fully implemented in the FFI.
-/
def handleBiEcho (ctx : ServerContext) (recv : IO (Option ByteArray)) (send : ByteArray → IO Unit)
    : IO (GrpcResult (Metadata × Metadata)) := do
  -- Check for error return request
  if let some e := maybeReturnError ctx then
    return .error { e with details := maybeGetErrorDetails ctx }

  -- Send initial metadata (response headers) before the first message
  ctx.call.sendInitialMetadata (testHeaders ctx)
  let errorAfterN := errorAfterNFromMetadata ctx

  let mut seq : Int32 := 0
  let mut done := false
  while !done do
    if (← ctx.call.isCancelled) then
      return .error (GrpcError.mk .cancelled "Cancelled" none)
    match ← recv with
    | some bytes =>
      match Protolean.decodeMessage (α := BiEchoRequest) bytes with
      | .ok request =>
        if let some n := errorAfterN then
          if seq.toInt.toNat >= n then
            return .error (GrpcError.mk .aborted s!"error after {seq} messages" none)
        let data := s!"{seq}:{String.fromUTF8! request.data}".toUTF8
        let response : BiEchoResponse := { data := data, sequence := seq }
        send (Protolean.encodeMessage response)
        seq := seq + 1
        maybeDelayFromMetadata ctx
      | .error _ => pure ()  -- Skip malformed
    | none => done := true

  -- Return (headers, trailers)
  return .ok (testHeaders ctx, testTrailers ctx)

/-- Start the Lean TestService server on an ephemeral port, returning (server, port). -/
def startTestServer : IO (Server × UInt32) := do
  let builder ← ServerBuilder.new
  let port ← builder.addInsecurePort "127.0.0.1:0"
  builder.registerUnary "/legate.test.TestService/Echo" handleEcho
  builder.registerClientStreaming "/legate.test.TestService/Collect" handleCollect
  builder.registerServerStreaming "/legate.test.TestService/Expand" handleExpand
  builder.registerBidiStreaming "/legate.test.TestService/BiEcho" handleBiEcho
  let server ← builder.build
  server.start
  IO.sleep 100
  return (server, port)

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
