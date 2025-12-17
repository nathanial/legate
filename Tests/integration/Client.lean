/-
  Lean client integration tests against Go gRPC server.

  Tests all four RPC patterns using protobuf-encoded messages via Protolean.
-/
import Legate
import Tests.Framework
import Tests.integration.Proto

namespace Tests.integration.Client

open Tests
open Legate
open Legate.Test

-- Method paths matching Go server
def echoMethod := "/legate.test.TestService/Echo"
def collectMethod := "/legate.test.TestService/Collect"
def expandMethod := "/legate.test.TestService/Expand"
def biEchoMethod := "/legate.test.TestService/BiEcho"

-- Test configuration
def serverAddr := "localhost:50051"

/-- Test unary Echo RPC with metadata + trailing metadata -/
def testUnaryMetadata : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  let request : EchoRequest := { data := "hello".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  let opts := (CallOptions.default).withMetadata #[("x-legate-test", "lean")]
  match ← unaryCall channel echoMethod requestBytes opts with
  | .ok response =>
    match response.trailers.get? "x-legate-test" with
    | some v =>
      if v == "lean" then
        return .passed
      else
        return .failed s!"Expected trailer x-legate-test=lean, got {v}"
    | none =>
      return .failed "Missing trailer x-legate-test"
  | .error e =>
    return .failed s!"RPC error: {e}"

/-- Test unary Echo RPC with response headers (initial metadata) -/
def testUnaryHeaders : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  let request : EchoRequest := { data := "headers-test".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  let opts := (CallOptions.default).withMetadata #[("x-legate-test", "header-value")]
  match ← unaryCall channel echoMethod requestBytes opts with
  | .ok response =>
    -- Check response headers (initial metadata)
    match response.headers.get? "x-legate-response-header" with
    | some v =>
      if v == "header-value" then
        -- Also verify trailers still work
        match response.trailers.get? "x-legate-test" with
        | some tv =>
          if tv == "header-value" then
            return .passed
          else
            return .failed s!"Expected trailer x-legate-test=header-value, got {tv}"
        | none =>
          return .failed "Missing trailer x-legate-test"
      else
        return .failed s!"Expected header x-legate-response-header=header-value, got {v}"
    | none =>
      return .failed "Missing header x-legate-response-header"
  | .error e =>
    return .failed s!"RPC error: {e}"

/-- Test unary deadlines -/
def testUnaryDeadlineExceeded : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  let request : EchoRequest := { data := "hello".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  let opts :=
    (CallOptions.default.withTimeout 50).withMetadata #[("x-sleep-ms", "200")]

  match ← unaryCall channel echoMethod requestBytes opts with
  | .ok _ =>
    return .failed "Expected deadlineExceeded, got ok"
  | .error e =>
    if e.code == .deadlineExceeded then
      return .passed
    else
      return .failed s!"Expected deadlineExceeded, got {e.code}: {e.message}"

/-- Test unary Echo RPC -/
def testUnaryEcho : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  -- Create and encode request
  let request : EchoRequest := { data := "hello".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  -- Make the call
  match ← unaryCall channel echoMethod requestBytes with
  | .ok response =>
    -- Decode response
    match Protolean.decodeMessage (α := EchoResponse) response.data with
    | .ok decoded =>
      let expected := "ECHO:hello".toUTF8
      if decoded.data == expected then
        return .passed
      else
        return .failed s!"Expected 'ECHO:hello', got '{String.fromUTF8! decoded.data}'"
    | .error e =>
      return .failed s!"Decode error: {e}"
  | .error e =>
    return .failed s!"RPC error: {e}"

/-- Test client streaming Collect RPC -/
def testClientStreamingCollect : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr
  let opts := (CallOptions.default).withMetadata #[("x-legate-test", "lean")]

  match ← clientStreamingCall channel collectMethod opts with
  | .ok stream =>
    -- Send multiple messages
    let messages := #["a", "b", "c"]
    for msg in messages do
      let request : CollectRequest := { data := msg.toUTF8 }
      match ← stream.write (Protolean.encodeMessage request) with
      | .ok () => pure ()
      | .error e => return .failed s!"Write error: {e}"

    -- Signal done and get response
    match ← stream.writesDone with
    | .ok () => pure ()
    | .error e => return .failed s!"WritesDone error: {e}"

    match ← stream.finish with
    | .ok response =>
      match Protolean.decodeMessage (α := CollectResponse) response.data with
      | .ok decoded =>
        let expectedData := "a|b|c".toUTF8
        if decoded.data == expectedData && decoded.count == 3 then
          match response.trailers.get? "x-legate-test" with
          | some v => if v == "lean" then return .passed else return .failed s!"Expected trailer x-legate-test=lean, got {v}"
          | none => return .failed "Missing trailer x-legate-test"
        else
          return .failed s!"Unexpected response: data='{String.fromUTF8! decoded.data}', count={decoded.count}"
      | .error e =>
        return .failed s!"Decode error: {e}"
    | .error e =>
      return .failed s!"Finish error: {e}"
  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Test server streaming Expand RPC -/
def testServerStreamingExpand : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr
  let opts := (CallOptions.default).withMetadata #[("x-legate-test", "lean")]

  -- Create and encode request (note: prefix_ because prefix is a Lean keyword)
  let request : ExpandRequest := { count := 3, prefix_ := "test".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  match ← serverStreamingCall channel expandMethod requestBytes opts with
  | .ok stream =>
    -- Read all responses into an array using a loop
    let mut resps : Array ExpandResponse := #[]
    let mut done := false
    while !done do
      match ← stream.read with
      | .ok (some data) =>
        match Protolean.decodeMessage (α := ExpandResponse) data with
        | .ok resp => resps := resps.push resp
        | .error e => return .failed s!"Decode error: {e}"
      | .ok none => done := true
      | .error e => return .failed s!"Read error: {e}"

    if resps.size != 3 then
      return .failed s!"Expected 3 responses, got {resps.size}"
    -- Verify each response
    for i in [:3] do
      let resp := resps[i]!
      let expectedData := s!"test:{i}".toUTF8
      if resp.data != expectedData || resp.sequence != i.toInt32 then
        return .failed s!"Response {i} mismatch: got data='{String.fromUTF8! resp.data}', seq={resp.sequence}"
    let trailers ← stream.getTrailers
    match trailers.get? "x-legate-test" with
    | some v => if v == "lean" then return .passed else return .failed s!"Expected trailer x-legate-test=lean, got {v}"
    | none => return .failed "Missing trailer x-legate-test"
  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Test bidirectional streaming BiEcho RPC -/
def testBidiStreaming : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr
  let opts := (CallOptions.default).withMetadata #[("x-legate-test", "lean")]

  match ← bidiStreamingCall channel biEchoMethod opts with
  | .ok stream =>
    -- Send messages and read responses
    let messages := #["x", "y", "z"]
    let mut responses : Array BiEchoResponse := #[]

    for h : i in [:messages.size] do
      let msg := messages[i]
      let request : BiEchoRequest := { data := msg.toUTF8 }
      match ← stream.write (Protolean.encodeMessage request) with
      | .ok () => pure ()
      | .error e => return .failed s!"Write error: {e}"

      -- Read response after each write (server echoes immediately)
      match ← stream.read with
      | .ok (some data) =>
        match Protolean.decodeMessage (α := BiEchoResponse) data with
        | .ok resp => responses := responses.push resp
        | .error e => return .failed s!"Decode error: {e}"
      | .ok none => return .failed "Stream ended unexpectedly"
      | .error e => return .failed s!"Read error: {e}"

    match ← stream.writesDone with
    | .ok () => pure ()
    | .error e => return .failed s!"WritesDone error: {e}"

    -- Drain any remaining messages until stream end, then check trailers.
    match ← stream.readAll with
    | .ok _ => pure ()
    | .error e => return .failed s!"ReadAll error: {e}"

    let trailers ← stream.getTrailers
    match trailers.get? "x-legate-test" with
    | some v =>
      if v != "lean" then
        return .failed s!"Expected trailer x-legate-test=lean, got {v}"
    | none =>
      return .failed "Missing trailer x-legate-test"

    -- Verify responses
    for h : i in [:responses.size] do
      let resp := responses[i]
      -- Check sequence number
      if resp.sequence != i.toInt32 then
        return .failed s!"Response {i} sequence mismatch: expected {i}, got {resp.sequence}"

    return .passed
  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Test server streaming with headers -/
def testServerStreamingHeaders : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr
  let opts := (CallOptions.default).withMetadata #[("x-legate-test", "stream-header")]

  let request : ExpandRequest := { count := 2, prefix_ := "hdr".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  match ← serverStreamingCall channel expandMethod requestBytes opts with
  | .ok stream =>
    -- Read at least one message to ensure headers are available
    match ← stream.read with
    | .ok (some _) =>
      -- Check response headers
      let headers ← stream.getHeaders
      match headers.get? "x-legate-response-header" with
      | some v =>
        if v == "stream-header" then
          -- Drain remaining messages
          while true do
            match ← stream.read with
            | .ok (some _) => continue
            | _ => break
          return .passed
        else
          return .failed s!"Expected header x-legate-response-header=stream-header, got {v}"
      | none =>
        return .failed "Missing header x-legate-response-header"
    | .ok none => return .failed "No messages received"
    | .error e => return .failed s!"Read error: {e}"
  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Client test suite -/
def clientTestSuite : TestSuite := suite "Lean Client -> Go Server" #[
  test "Unary Echo" testUnaryEcho,
  test "Unary Metadata" testUnaryMetadata,
  test "Unary Headers" testUnaryHeaders,
  test "Unary Deadline" testUnaryDeadlineExceeded,
  test "Client Streaming Collect" testClientStreamingCollect,
  test "Server Streaming Expand" testServerStreamingExpand,
  test "Server Streaming Headers" testServerStreamingHeaders,
  test "Bidirectional BiEcho" testBidiStreaming
]

end Tests.integration.Client
