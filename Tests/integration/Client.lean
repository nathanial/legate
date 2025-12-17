/-
  Lean client integration tests against Go gRPC server.

  Tests all four RPC patterns using protobuf-encoded messages via Protolean.
-/
import Legate
import Protolean
import Tests.Framework

namespace Tests.integration.Client

-- Import proto types at compile time
-- The path is relative to this source file's directory
proto_import "Proto/legate_test.proto"

open Tests
open Legate
open legate.test  -- namespace from proto package

-- Method paths matching Go server
def echoMethod := "/legate.test.TestService/Echo"
def collectMethod := "/legate.test.TestService/Collect"
def expandMethod := "/legate.test.TestService/Expand"
def biEchoMethod := "/legate.test.TestService/BiEcho"

-- Test configuration
def serverAddr := "localhost:50051"

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
    match Protolean.decodeMessage response.data with
    | .ok (decoded : EchoResponse) =>
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

  match ← clientStreamingCall channel collectMethod with
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
      match Protolean.decodeMessage response.data with
      | .ok (decoded : CollectResponse) =>
        let expectedData := "a|b|c".toUTF8
        if decoded.data == expectedData && decoded.count == 3 then
          return .passed
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

  -- Create and encode request
  let request : ExpandRequest := { count := 3, prefix := "test".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  match ← serverStreamingCall channel expandMethod requestBytes with
  | .ok stream =>
    -- Read all responses
    let mut responses : Array ExpandResponse := #[]
    let rec readLoop : IO (GrpcResult (Array ExpandResponse)) := do
      match ← stream.read with
      | .ok (some data) =>
        match Protolean.decodeMessage data with
        | .ok resp =>
          responses := responses.push resp
          readLoop
        | .error e => return .error (GrpcError.mk .internal s!"Decode error: {e}" none)
      | .ok none => return .ok responses
      | .error e => return .error e

    match ← readLoop with
    | .ok resps =>
      if resps.size != 3 then
        return .failed s!"Expected 3 responses, got {resps.size}"
      -- Verify each response
      for i in [:3] do
        let resp := resps[i]!
        let expectedData := s!"test:{i}".toUTF8
        if resp.data != expectedData || resp.sequence != i.toInt32 then
          return .failed s!"Response {i} mismatch: got data='{String.fromUTF8! resp.data}', seq={resp.sequence}"
      return .passed
    | .error e =>
      return .failed s!"Read error: {e}"
  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Test bidirectional streaming BiEcho RPC -/
def testBidiStreaming : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  match ← bidiStreamingCall channel biEchoMethod with
  | .ok stream =>
    -- Send messages and read responses
    let messages := #["x", "y", "z"]
    let mut responses : Array BiEchoResponse := #[]

    for (msg, i) in messages.zipWithIndex do
      let request : BiEchoRequest := { data := msg.toUTF8 }
      match ← stream.write (Protolean.encodeMessage request) with
      | .ok () => pure ()
      | .error e => return .failed s!"Write error: {e}"

      -- Read response after each write (server echoes immediately)
      match ← stream.read with
      | .ok (some data) =>
        match Protolean.decodeMessage data with
        | .ok resp => responses := responses.push resp
        | .error e => return .failed s!"Decode error: {e}"
      | .ok none => return .failed "Stream ended unexpectedly"
      | .error e => return .failed s!"Read error: {e}"

    match ← stream.writesDone with
    | .ok () => pure ()
    | .error e => return .failed s!"WritesDone error: {e}"

    -- Verify responses
    for (resp, i) in responses.zipWithIndex do
      let expectedPrefix := s!"{i}:".toUTF8
      -- Check that data starts with the sequence prefix
      if !resp.data.toList.take expectedPrefix.size == expectedPrefix.toList then
        return .failed s!"Response {i} missing sequence prefix"
      if resp.sequence != i.toInt32 then
        return .failed s!"Response {i} sequence mismatch: expected {i}, got {resp.sequence}"

    return .passed
  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Client test suite -/
def clientTestSuite : TestSuite := suite "Lean Client -> Go Server" #[
  test "Unary Echo" testUnaryEcho,
  test "Client Streaming Collect" testClientStreamingCollect,
  test "Server Streaming Expand" testServerStreamingExpand,
  test "Bidirectional BiEcho" testBidiStreaming
]

end Tests.integration.Client
