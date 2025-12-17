/-
  Integration Test Runner

  Runs Lean client tests against Go server, and optionally
  runs Lean server for Go client to test against.
-/
import Tests.Framework
import Tests.integration.Client
import Tests.integration.Server

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

  | "help" | "--help" | "-h" =>
    IO.println "Usage: integrationTests [client|server] [port]"
    IO.println ""
    IO.println "Modes:"
    IO.println "  client  - Run Lean client tests against Go server (default)"
    IO.println "  server  - Run Lean gRPC server for Go client testing"
    IO.println ""
    IO.println "Examples:"
    IO.println "  integrationTests client          # Test against Go server on localhost:50051"
    IO.println "  integrationTests server 50052    # Start Lean server on port 50052"
    return 0

  | _ =>
    IO.eprintln s!"Unknown mode: {mode}"
    IO.eprintln "Usage: integrationTests [client|server] [port]"
    return 1
