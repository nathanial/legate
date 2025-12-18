/-
  Integration Test Runner

  Runs Lean client tests against Go server, and optionally
  runs Lean server for Go client to test against.
-/
import Tests.Framework
import Tests.integration.Client
import Tests.integration.Server
import Tests.integration.TlsTests
import Tests.integration.WaitForReadyTests

open Tests

def main (args : List String) : IO UInt32 := do
  let mode := args.head?.getD "client"

  match mode with
  | "client" =>
    -- Run Lean client tests (assumes Go server is running)
    IO.println "Lean Integration Tests (Client Mode)"
    IO.println "====================================="
    IO.println "Testing Lean client against Go server..."
    IO.println ""
    runAllSuites #[Tests.integration.Client.clientTestSuite]

  | "server" =>
    -- Run Lean server (for Go client to test against)
    let port := args.drop 1 |>.head?.bind String.toNat? |>.getD 50051
    Tests.integration.Server.runTestServer port
    return 0

  | "lean" =>
    -- Run Lean client tests against a Lean server (Lean<->Lean parity)
    IO.println "Lean Integration Tests (Lean↔Lean Mode)"
    IO.println "========================================="
    IO.println "Testing Lean client against Lean server..."
    IO.println ""
    let (server, port) ← Tests.integration.Server.startTestServer
    try
      runAllSuites #[Tests.integration.Client.mkClientTestSuite "Lean Client ↔ Lean Server" s!"localhost:{port}"]
    finally
      server.shutdownNow

  | "tls" =>
    -- Run TLS/mTLS tests (Lean client <-> Lean server)
    IO.println "Lean Integration Tests (TLS Mode)"
    IO.println "=================================="
    IO.println "Testing TLS/mTLS connections..."
    IO.println ""
    runAllSuites #[Tests.integration.TlsTests.tlsTestSuite]

  | "ready" =>
    -- Run wait-for-ready tests (Lean client <-> Lean server)
    IO.println "Lean Integration Tests (WaitForReady Mode)"
    IO.println "==========================================="
    IO.println "Testing CallOptions.waitForReady behavior..."
    IO.println ""
    runAllSuites #[Tests.integration.WaitForReadyTests.waitForReadyTestSuite]

  | "help" | "--help" | "-h" =>
    IO.println "Usage: integrationTests [client|server|lean|tls|ready] [port]"
    IO.println ""
    IO.println "Modes:"
    IO.println "  client  - Run Lean client tests against Go server (default)"
    IO.println "  server  - Run Lean gRPC server for Go client testing"
    IO.println "  lean    - Run Lean client tests against Lean server"
    IO.println "  tls     - Run TLS/mTLS tests (Lean client <-> Lean server)"
    IO.println "  ready   - Run wait-for-ready tests (Lean client <-> Lean server)"
    IO.println ""
    IO.println "Examples:"
    IO.println "  integrationTests client          # Test against Go server on localhost:50051"
    IO.println "  integrationTests server 50052    # Start Lean server on port 50052"
    IO.println "  integrationTests lean            # Test Lean client against Lean server"
    IO.println "  integrationTests tls             # Run TLS tests"
    IO.println "  integrationTests ready           # Run wait-for-ready tests"
    return 0

  | _ =>
    IO.eprintln s!"Unknown mode: {mode}"
    IO.eprintln "Usage: integrationTests [client|server|lean|tls|ready] [port]"
    return 1
