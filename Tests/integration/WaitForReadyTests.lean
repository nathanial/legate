/-
  Wait-for-ready integration tests for Legate.

  Validates `CallOptions.waitForReady` behavior end-to-end.
-/
import Legate
import Tests.Framework

namespace Tests.integration.WaitForReadyTests

open Tests
open Legate

def echoMethod := "/legate.test.TestService/Echo"

def handleEcho (_ctx : ServerContext) (requestBytes : ByteArray)
    : IO (GrpcResult (ByteArray × Metadata × Metadata)) := do
  return .ok (requestBytes, #[], #[])

def testWaitForReadySucceeds : IO TestResult := do
  let builder ← ServerBuilder.new
  let port ← builder.addInsecurePort "127.0.0.1:0"
  builder.registerUnary echoMethod handleEcho

  let channel ← Channel.createInsecure s!"localhost:{port}"

  let serverTask ← IO.asTask (do
    IO.sleep 200
    let server ← builder.build
    server.start
    return server
  )

  let opts : CallOptions := { timeoutMs := 5000, waitForReady := true }
  let req := "wait-for-ready".toUTF8
  let result ← unaryCall channel echoMethod req opts

  match serverTask.get with
  | .error err =>
    return .failed s!"Server task failed: {err}"
  | .ok server =>
    try
      match result with
      | .ok resp =>
        if resp.data == req then
          return .passed
        else
          return .failed "Unexpected response payload"
      | .error e =>
        return .failed s!"Expected success, got error: {e}"
    finally
      server.shutdownNow

def testNoWaitForReadyFailsFast : IO TestResult := do
  let builder ← ServerBuilder.new
  let port ← builder.addInsecurePort "127.0.0.1:0"
  -- Intentionally never build/start the server.

  let channel ← Channel.createInsecure s!"localhost:{port}"
  let opts : CallOptions := { timeoutMs := 200, waitForReady := false }
  let req := "no-wait-for-ready".toUTF8

  match ← unaryCall channel echoMethod req opts with
  | .ok _ =>
    return .failed "Expected failure without waitForReady, got success"
  | .error e =>
    if e.code == .unavailable || e.code == .deadlineExceeded then
      return .passed
    else
      return .failed s!"Expected unavailable/deadlineExceeded, got {e.code}: {e.message}"

def waitForReadyTestSuite : TestSuite := suite "WaitForReady" #[
  test "waitForReady succeeds when server starts" testWaitForReadySucceeds,
  test "no waitForReady fails fast" testNoWaitForReadyFailsFast
]

end Tests.integration.WaitForReadyTests
