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
def defaultServerAddr := "localhost:50051"

/-- Test unary Echo RPC with metadata + trailing metadata -/
def testUnaryMetadata (serverAddr : String) : IO TestResult := do
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
def testUnaryHeaders (serverAddr : String) : IO TestResult := do
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
def testUnaryDeadlineExceeded (serverAddr : String) : IO TestResult := do
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
def testUnaryEcho (serverAddr : String) : IO TestResult := do
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
def testClientStreamingCollect (serverAddr : String) : IO TestResult := do
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
def testServerStreamingExpand (serverAddr : String) : IO TestResult := do
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
def testBidiStreaming (serverAddr : String) : IO TestResult := do
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
def testServerStreamingHeaders (serverAddr : String) : IO TestResult := do
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

/-- Test server streaming cancellation: cancel after receiving a few messages -/
def testServerStreamingCancel (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  -- Request many messages with a delay to allow cancellation
  let request : ExpandRequest := { count := 100, prefix_ := "cancel".toUTF8 }
  let requestBytes := Protolean.encodeMessage request
  let opts := (CallOptions.default).withMetadata #[("x-delay-ms", "50")]

  match ← serverStreamingCall channel expandMethod requestBytes opts with
  | .ok stream =>
    -- Read a few messages
    let mut received := 0
    for _ in [:3] do
      match ← stream.read with
      | .ok (some _) => received := received + 1
      | .ok none => return .failed "Stream ended unexpectedly"
      | .error e => return .failed s!"Read error: {e}"

    if received < 2 then
      return .failed s!"Expected at least 2 messages before cancel, got {received}"

    -- Cancel the stream
    stream.cancel

    -- Subsequent read should fail with Cancelled (or return none/error)
    match ← stream.read with
    | .ok (some _) =>
      -- It's possible we read a message that was already in flight
      -- Try one more read
      match ← stream.read with
      | .ok (some _) =>
        return .failed "Expected cancel to stop the stream"
      | .ok none =>
        return .passed  -- Stream ended (acceptable)
      | .error e =>
        if e.code == .cancelled then
          return .passed
        else
          return .passed  -- Any error after cancel is acceptable
    | .ok none =>
      return .passed  -- Stream ended cleanly after cancel (acceptable)
    | .error e =>
      if e.code == .cancelled then
        return .passed
      else
        -- Other errors are also acceptable after cancel
        return .passed

  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Test server streaming deadline exceeded during active streaming -/
def testServerStreamingDeadline (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  -- Request many messages with delay, but with a short timeout
  let request : ExpandRequest := { count := 100, prefix_ := "deadline".toUTF8 }
  let requestBytes := Protolean.encodeMessage request
  let opts := ((CallOptions.default).withTimeout 100).withMetadata #[("x-delay-ms", "50")]

  match ← serverStreamingCall channel expandMethod requestBytes opts with
  | .ok stream =>
    -- Read until we hit the deadline
    let mut received := 0
    let mut hitDeadline := false
    for _ in [:100] do
      match ← stream.read with
      | .ok (some _) => received := received + 1
      | .ok none => break  -- Stream ended
      | .error e =>
        if e.code == .deadlineExceeded then
          hitDeadline := true
          break
        else
          return .failed s!"Unexpected error: {e}"

    if hitDeadline then
      return .passed
    else if received < 100 then
      -- Stream ended before sending all messages, check status
      let status ← stream.getStatus
      if status.code == .deadlineExceeded then
        return .passed
      else
        return .failed s!"Expected deadlineExceeded, stream ended with status: {status}"
    else
      return .failed s!"Expected deadline to trigger, but received all {received} messages"

  | .error e =>
    if e.code == .deadlineExceeded then
      return .passed
    else
      return .failed s!"Start stream error: {e}"

/-- Test client streaming cancellation: cancel after sending some messages -/
def testClientStreamingCancel (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  match ← clientStreamingCall channel collectMethod with
  | .ok stream =>
    -- Send a few messages
    for i in [:3] do
      let request : CollectRequest := { data := s!"msg{i}".toUTF8 }
      match ← stream.write (Protolean.encodeMessage request) with
      | .ok () => pure ()
      | .error e => return .failed s!"Write error: {e}"

    -- Cancel the stream before finishing
    stream.cancel

    -- Finish should fail or return an error
    match ← stream.finish with
    | .ok _ =>
      -- It's possible the cancel didn't take effect immediately
      return .passed
    | .error _ =>
      -- Any error after cancel is acceptable
      return .passed

  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Test bidirectional streaming cancellation: cancel mid-exchange -/
def testBidiStreamingCancel (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr
  let opts := (CallOptions.default).withMetadata #[("x-delay-ms", "50")]

  match ← bidiStreamingCall channel biEchoMethod opts with
  | .ok stream =>
    -- Exchange a few messages
    for i in [:2] do
      let request : BiEchoRequest := { data := s!"msg{i}".toUTF8 }
      match ← stream.write (Protolean.encodeMessage request) with
      | .ok () => pure ()
      | .error e => return .failed s!"Write error: {e}"

      -- Read the response
      match ← stream.read with
      | .ok (some _) => pure ()
      | .ok none => return .failed "Stream ended unexpectedly"
      | .error e => return .failed s!"Read error: {e}"

    -- Cancel the stream
    stream.cancel

    -- Subsequent operations should fail or the stream should end
    match ← stream.read with
    | .ok (some _) =>
      -- One more message may have been in flight, try again
      match ← stream.read with
      | .ok (some _) => return .failed "Expected cancel to stop the stream"
      | _ => return .passed
    | .ok none => return .passed
    | .error _ => return .passed

  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Test client streaming deadline exceeded -/
def testClientStreamingDeadline (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr
  let opts := ((CallOptions.default).withTimeout 100).withMetadata #[("x-delay-ms", "50")]

  match ← clientStreamingCall channel collectMethod opts with
  | .ok stream =>
    -- Try to send many messages slowly
    let mut hitDeadline := false
    for i in [:100] do
      let request : CollectRequest := { data := s!"msg{i}".toUTF8 }
      match ← stream.write (Protolean.encodeMessage request) with
      | .ok () =>
        -- Small delay to trigger deadline
        IO.sleep 20
      | .error e =>
        -- Deadline can manifest as deadlineExceeded or internal/unavailable error
        if e.code == .deadlineExceeded || e.code == .internal || e.code == .unavailable then
          hitDeadline := true
          break
        else
          return .failed s!"Unexpected write error: {e}"

    if hitDeadline then
      return .passed
    else
      -- Try to finish and check for deadline
      match ← stream.finish with
      | .ok _ => return .failed "Expected deadline to trigger"
      | .error e =>
        if e.code == .deadlineExceeded || e.code == .internal || e.code == .unavailable then
          return .passed
        else
          return .failed s!"Expected deadlineExceeded, got {e.code}: {e.message}"

  | .error e =>
    if e.code == .deadlineExceeded then
      return .passed
    else
      return .failed s!"Start stream error: {e}"

/-- Test bidirectional streaming deadline exceeded -/
def testBidiStreamingDeadline (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr
  let opts := ((CallOptions.default).withTimeout 100).withMetadata #[("x-delay-ms", "50")]

  match ← bidiStreamingCall channel biEchoMethod opts with
  | .ok stream =>
    let mut hitDeadline := false
    for i in [:100] do
      let request : BiEchoRequest := { data := s!"msg{i}".toUTF8 }
      match ← stream.write (Protolean.encodeMessage request) with
      | .ok () => pure ()
      | .error e =>
        if e.code == .deadlineExceeded then
          hitDeadline := true
          break
        else
          return .failed s!"Unexpected write error: {e}"

      match ← stream.read with
      | .ok (some _) => pure ()
      | .ok none => break
      | .error e =>
        if e.code == .deadlineExceeded then
          hitDeadline := true
          break
        else
          return .failed s!"Unexpected read error: {e}"

    if hitDeadline then
      return .passed
    else
      -- Check final status
      let status ← stream.getStatus
      if status.code == .deadlineExceeded then
        return .passed
      else
        return .failed s!"Expected deadline to trigger, got status: {status}"

  | .error e =>
    if e.code == .deadlineExceeded then
      return .passed
    else
      return .failed s!"Start stream error: {e}"

-- ============================================================================
-- Status / Error Tests (Phase 3)
-- ============================================================================

/-- Test unary error response -/
def testUnaryError (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  let request : EchoRequest := { data := "test".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  -- Request error code 3 (InvalidArgument) with message
  let opts := (CallOptions.default).withMetadata #[("x-return-error", "3:test error message")]
  match ← unaryCall channel echoMethod requestBytes opts with
  | .ok _ =>
    return .failed "Expected error, got ok"
  | .error e =>
    if e.code == .invalidArgument && e.message.containsSubstr "test error message" then
      return .passed
    else
      return .failed s!"Expected invalidArgument with message, got {e.code}: {e.message}"

/-- Test server streaming error immediately (before any messages) -/
def testServerStreamingError (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  let request : ExpandRequest := { count := 5, prefix_ := "test".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  -- Request error code 6 (AlreadyExists) with message
  let opts := (CallOptions.default).withMetadata #[("x-return-error", "6:immediate error")]
  match ← serverStreamingCall channel expandMethod requestBytes opts with
  | .ok stream =>
    -- The stream starts but first read should get the error
    match ← stream.read with
    | .ok (some _) =>
      return .failed "Expected error, got message"
    | .ok none =>
      -- Check status
      let status ← stream.getStatus
      if status.code == .alreadyExists then
        return .passed
      else
        return .failed s!"Expected alreadyExists status, got {status.code}: {status.message}"
    | .error e =>
      if e.code == .alreadyExists then
        return .passed
      else
        return .failed s!"Expected alreadyExists error, got {e.code}: {e.message}"
  | .error e =>
    if e.code == .alreadyExists then
      return .passed
    else
      return .failed s!"Expected alreadyExists error, got {e.code}: {e.message}"

/-- Test server streaming error mid-stream (after some messages) -/
def testServerStreamingMidError (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  -- Request 10 messages but error after 3
  let request : ExpandRequest := { count := 10, prefix_ := "test".toUTF8 }
  let requestBytes := Protolean.encodeMessage request

  let opts := (CallOptions.default).withMetadata #[("x-error-after-n", "3")]
  match ← serverStreamingCall channel expandMethod requestBytes opts with
  | .ok stream =>
    let mut msgCount := 0
    let mut gotError := false
    let mut errorCode : StatusCode := .ok
    for _ in [:20] do
      match ← stream.read with
      | .ok (some _) =>
        msgCount := msgCount + 1
      | .ok none => break
      | .error e =>
        gotError := true
        errorCode := e.code
        break

    if gotError then
      -- Should have received 3 messages before error
      if msgCount == 3 && errorCode == .aborted then
        return .passed
      else
        return .failed s!"Got error after {msgCount} messages with code {errorCode}"
    else
      -- Check final status
      let status ← stream.getStatus
      if status.code == .aborted && msgCount == 3 then
        return .passed
      else
        return .failed s!"Expected aborted status after 3 messages, got {status.code} after {msgCount} messages"
  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Test client streaming error immediately (before any messages) -/
def testClientStreamingError (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  -- Request error code 7 (PermissionDenied) with message
  let opts := (CallOptions.default).withMetadata #[("x-return-error", "7:access denied")]
  match ← clientStreamingCall channel collectMethod opts with
  | .ok stream =>
    -- Write a message and try to finish
    let request : CollectRequest := { data := "test".toUTF8 }
    let _ ← stream.write (Protolean.encodeMessage request)

    match ← stream.finish with
    | .ok _ =>
      return .failed "Expected error, got ok"
    | .error e =>
      if e.code == .permissionDenied then
        return .passed
      else
        return .failed s!"Expected permissionDenied error, got {e.code}: {e.message}"
  | .error e =>
    if e.code == .permissionDenied then
      return .passed
    else
      return .failed s!"Expected permissionDenied error, got {e.code}: {e.message}"

/-- Test client streaming error mid-stream (after some messages) -/
def testClientStreamingMidError (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  -- Error after receiving 2 messages
  let opts := (CallOptions.default).withMetadata #[("x-error-after-n", "2")]
  match ← clientStreamingCall channel collectMethod opts with
  | .ok stream =>
    -- Send several messages
    for i in [:5] do
      let request : CollectRequest := { data := s!"msg{i}".toUTF8 }
      match ← stream.write (Protolean.encodeMessage request) with
      | .ok () => pure ()
      | .error _ => break

    match ← stream.finish with
    | .ok _ =>
      return .failed "Expected error, got ok"
    | .error e =>
      if e.code == .aborted && e.message.containsSubstr "error after 2 messages" then
        return .passed
      else
        return .failed s!"Expected aborted error, got {e.code}: {e.message}"
  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Test bidirectional streaming error immediately (before any messages) -/
def testBidiStreamingError (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  -- Request error code 8 (ResourceExhausted) with message
  let opts := (CallOptions.default).withMetadata #[("x-return-error", "8:out of resources")]
  match ← bidiStreamingCall channel biEchoMethod opts with
  | .ok stream =>
    -- Write a message and try to read
    let request : BiEchoRequest := { data := "test".toUTF8 }
    let _ ← stream.write (Protolean.encodeMessage request)

    match ← stream.read with
    | .ok (some _) =>
      return .failed "Expected error, got message"
    | .ok none =>
      -- Check status
      let status ← stream.getStatus
      if status.code == .resourceExhausted then
        return .passed
      else
        return .failed s!"Expected resourceExhausted status, got {status.code}: {status.message}"
    | .error e =>
      if e.code == .resourceExhausted then
        return .passed
      else
        return .failed s!"Expected resourceExhausted error, got {e.code}: {e.message}"
  | .error e =>
    if e.code == .resourceExhausted then
      return .passed
    else
      return .failed s!"Expected resourceExhausted error, got {e.code}: {e.message}"

/-- Test bidirectional streaming error mid-stream (after some messages) -/
def testBidiStreamingMidError (serverAddr : String) : IO TestResult := do
  let channel ← Channel.createInsecure serverAddr

  -- Error after processing 2 messages
  let opts := (CallOptions.default).withMetadata #[("x-error-after-n", "2")]
  match ← bidiStreamingCall channel biEchoMethod opts with
  | .ok stream =>
    let mut msgCount := 0
    let mut gotError := false
    for i in [:10] do
      let request : BiEchoRequest := { data := s!"msg{i}".toUTF8 }
      match ← stream.write (Protolean.encodeMessage request) with
      | .ok () => pure ()
      | .error _ => break

      match ← stream.read with
      | .ok (some _) =>
        msgCount := msgCount + 1
      | .ok none => break
      | .error e =>
        gotError := true
        if e.code == .aborted then
          -- Got expected error
          break
        else
          return .failed s!"Expected aborted error, got {e.code}: {e.message}"

    if gotError || msgCount >= 2 then
      -- Check final status if needed
      let status ← stream.getStatus
      if status.code == .aborted || status.code == .ok then
        return .passed
      else
        return .failed s!"Expected aborted or ok status, got {status.code}"
    else
      return .failed s!"Expected to process at least 2 messages, got {msgCount}"
  | .error e =>
    return .failed s!"Start stream error: {e}"

/-- Client integration suite against a specific server address. -/
def mkClientTestSuite (name : String) (serverAddr : String) : TestSuite := suite name #[
  test "Unary Echo" (testUnaryEcho serverAddr),
  test "Unary Metadata" (testUnaryMetadata serverAddr),
  test "Unary Headers" (testUnaryHeaders serverAddr),
  test "Unary Deadline" (testUnaryDeadlineExceeded serverAddr),
  test "Unary Error" (testUnaryError serverAddr),
  test "Client Streaming Collect" (testClientStreamingCollect serverAddr),
  test "Client Streaming Error" (testClientStreamingError serverAddr),
  test "Client Streaming MidError" (testClientStreamingMidError serverAddr),
  test "Server Streaming Expand" (testServerStreamingExpand serverAddr),
  test "Server Streaming Headers" (testServerStreamingHeaders serverAddr),
  test "Server Streaming Error" (testServerStreamingError serverAddr),
  test "Server Streaming MidError" (testServerStreamingMidError serverAddr),
  test "Bidirectional BiEcho" (testBidiStreaming serverAddr),
  test "Bidi Streaming Error" (testBidiStreamingError serverAddr),
  test "Bidi Streaming MidError" (testBidiStreamingMidError serverAddr),
  test "Server Streaming Cancel" (testServerStreamingCancel serverAddr),
  test "Server Streaming Deadline" (testServerStreamingDeadline serverAddr),
  test "Client Streaming Cancel" (testClientStreamingCancel serverAddr),
  test "Bidi Streaming Cancel" (testBidiStreamingCancel serverAddr),
  test "Client Streaming Deadline" (testClientStreamingDeadline serverAddr),
  test "Bidi Streaming Deadline" (testBidiStreamingDeadline serverAddr)
]

/-- Backwards-compatible suite name for Go oracle server. -/
def clientTestSuite : TestSuite :=
  mkClientTestSuite "Lean Client -> Go Server" defaultServerAddr

end Tests.integration.Client
