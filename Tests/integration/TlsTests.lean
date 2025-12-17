/-
  TLS/mTLS integration tests for Legate.

  Tests secure connections between Lean client and Lean server.
-/
import Legate
import Tests.Framework
import Tests.integration.Proto

namespace Tests.integration.TlsTests

open Tests
open Legate
open Legate.Test

-- Method paths
def echoMethod := "/legate.test.TestService/Echo"

-- Certificate file paths (relative to project root, must be absolute at runtime)
def certsDir : IO String := do
  let cwd ← IO.currentDir
  return s!"{cwd}/Tests/integration/certs"

/-- Read a certificate file -/
def readCertFile (name : String) : IO String := do
  let dir ← certsDir
  IO.FS.readFile s!"{dir}/{name}"

/-- Simple echo handler for test server -/
def handleEcho (_ctx : ServerContext) (requestBytes : ByteArray)
    : IO (GrpcResult (ByteArray × Metadata × Metadata)) := do
  match Protolean.decodeMessage (α := EchoRequest) requestBytes with
  | .ok request =>
    let responseData := "ECHO:".toUTF8 ++ request.data
    let response : EchoResponse := { data := responseData }
    return .ok (Protolean.encodeMessage response, #[], #[])
  | .error e =>
    return .error (GrpcError.mk .invalidArgument s!"Decode error: {e}" none)

/-- Start a TLS test server in the background, returns (server, port) -/
def startTlsServer (creds : SslServerCredentials) : IO (Server × UInt32) := do
  let builder ← ServerBuilder.new
  let port ← builder.addSecurePort "127.0.0.1:0" creds
  builder.registerUnary echoMethod handleEcho
  let server ← builder.build
  server.start
  -- Give server time to start
  IO.sleep 100
  return (server, port)

/-- Test basic TLS connection (server auth only) -/
def testTlsBasic : IO TestResult := do
  -- Read certificates
  let caCert ← readCertFile "ca.crt"
  let serverCert ← readCertFile "server.crt"
  let serverKey ← readCertFile "server.key"

  -- Start TLS server
  let serverCreds : SslServerCredentials := {
    serverCert := serverCert
    serverKey := serverKey
  }
  let (server, port) ← startTlsServer serverCreds

  try
    -- Create TLS client channel with CA cert
    let clientCreds : SslCredentials := {
      rootCerts := caCert
    }
    let channel ← Channel.createSecure s!"localhost:{port}" clientCreds

    -- Make a test call
    let request : EchoRequest := { data := "tls-test".toUTF8 }
    let requestBytes := Protolean.encodeMessage request

    match ← unaryCall channel echoMethod requestBytes with
    | .ok response =>
      match Protolean.decodeMessage (α := EchoResponse) response.data with
      | .ok decoded =>
        let expected := "ECHO:tls-test".toUTF8
        if decoded.data == expected then
          return .passed
        else
          return .failed s!"Expected 'ECHO:tls-test', got '{String.fromUTF8! decoded.data}'"
      | .error e =>
        return .failed s!"Decode error: {e}"
    | .error e =>
      return .failed s!"RPC error: {e}"
  finally
    server.shutdownNow

/-- Test mTLS connection (mutual authentication) -/
def testMtls : IO TestResult := do
  -- Read certificates
  let caCert ← readCertFile "ca.crt"
  let serverCert ← readCertFile "server.crt"
  let serverKey ← readCertFile "server.key"
  let clientCert ← readCertFile "client.crt"
  let clientKey ← readCertFile "client.key"

  -- Start mTLS server (requires client certificate)
  let serverCreds : SslServerCredentials := {
    serverCert := serverCert
    serverKey := serverKey
    rootCerts := caCert  -- For verifying client certs
    clientAuth := .require
  }
  let (server, port) ← startTlsServer serverCreds

  try
    -- Create mTLS client channel with CA cert and client cert
    let clientCreds : SslCredentials := {
      rootCerts := caCert
      privateKey := clientKey
      certChain := clientCert
    }
    let channel ← Channel.createSecure s!"localhost:{port}" clientCreds

    -- Make a test call
    let request : EchoRequest := { data := "mtls-test".toUTF8 }
    let requestBytes := Protolean.encodeMessage request

    match ← unaryCall channel echoMethod requestBytes with
    | .ok response =>
      match Protolean.decodeMessage (α := EchoResponse) response.data with
      | .ok decoded =>
        let expected := "ECHO:mtls-test".toUTF8
        if decoded.data == expected then
          return .passed
        else
          return .failed s!"Expected 'ECHO:mtls-test', got '{String.fromUTF8! decoded.data}'"
      | .error e =>
        return .failed s!"Decode error: {e}"
    | .error e =>
      return .failed s!"RPC error: {e}"
  finally
    server.shutdownNow

/-- Test mTLS failure when client doesn't provide certificate -/
def testMtlsNoClientCert : IO TestResult := do
  -- Read certificates
  let caCert ← readCertFile "ca.crt"
  let serverCert ← readCertFile "server.crt"
  let serverKey ← readCertFile "server.key"

  -- Start mTLS server (requires client certificate)
  let serverCreds : SslServerCredentials := {
    serverCert := serverCert
    serverKey := serverKey
    rootCerts := caCert
    clientAuth := .require
  }
  let (server, port) ← startTlsServer serverCreds

  try
    -- Create TLS client WITHOUT client certificate
    let clientCreds : SslCredentials := {
      rootCerts := caCert
      -- No client cert/key
    }
    let channel ← Channel.createSecure s!"localhost:{port}" clientCreds

    -- Make a test call - should fail
    let request : EchoRequest := { data := "test".toUTF8 }
    let requestBytes := Protolean.encodeMessage request

    match ← unaryCall channel echoMethod requestBytes with
    | .ok _ =>
      return .failed "Expected connection to fail without client certificate"
    | .error e =>
      -- Connection should fail due to missing client cert
      -- Expected: unavailable (connection failed) or unauthenticated
      if e.code == .unavailable || e.code == .unauthenticated || e.code == .internal then
        return .passed
      else
        return .failed s!"Expected unavailable/unauthenticated error, got {e.code}: {e.message}"
  finally
    server.shutdownNow

/-- Test mTLS "request" mode: server requests client cert but does not require it. -/
def testMtlsRequestNoClientCert : IO TestResult := do
  -- Read certificates
  let caCert ← readCertFile "ca.crt"
  let serverCert ← readCertFile "server.crt"
  let serverKey ← readCertFile "server.key"

  -- Start mTLS server (requests client certificate, but does not require)
  let serverCreds : SslServerCredentials := {
    serverCert := serverCert
    serverKey := serverKey
    rootCerts := caCert
    clientAuth := .request
  }
  let (server, port) ← startTlsServer serverCreds

  try
    -- Create TLS client WITHOUT client certificate
    let clientCreds : SslCredentials := {
      rootCerts := caCert
    }
    let channel ← Channel.createSecure s!"localhost:{port}" clientCreds

    -- Make a test call - should succeed
    let request : EchoRequest := { data := "mtls-request-no-client-cert".toUTF8 }
    let requestBytes := Protolean.encodeMessage request

    match ← unaryCall channel echoMethod requestBytes with
    | .ok response =>
      match Protolean.decodeMessage (α := EchoResponse) response.data with
      | .ok decoded =>
        let expected := "ECHO:mtls-request-no-client-cert".toUTF8
        if decoded.data == expected then
          return .passed
        else
          return .failed s!"Expected 'ECHO:mtls-request-no-client-cert', got '{String.fromUTF8! decoded.data}'"
      | .error e =>
        return .failed s!"Decode error: {e}"
    | .error e =>
      return .failed s!"RPC error: {e}"
  finally
    server.shutdownNow

/-- Test hostname verification failure (wrong server cert) -/
def testHostnameVerificationFailure : IO TestResult := do
  -- Read certificates
  let caCert ← readCertFile "ca.crt"
  let wrongHostCert ← readCertFile "wrong-host.crt"
  let wrongHostKey ← readCertFile "wrong-host.key"

  -- Start TLS server with wrong hostname cert
  let serverCreds : SslServerCredentials := {
    serverCert := wrongHostCert
    serverKey := wrongHostKey
  }
  let (server, port) ← startTlsServer serverCreds

  try
    -- Create TLS client expecting localhost but server has wronghost.example.com
    let clientCreds : SslCredentials := {
      rootCerts := caCert
    }
    -- Connecting to localhost, but cert is for wronghost.example.com
    let channel ← Channel.createSecure s!"localhost:{port}" clientCreds

    -- Make a test call - should fail due to hostname mismatch
    let request : EchoRequest := { data := "test".toUTF8 }
    let requestBytes := Protolean.encodeMessage request

    match ← unaryCall channel echoMethod requestBytes with
    | .ok _ =>
      return .failed "Expected hostname verification to fail"
    | .error e =>
      -- Connection should fail due to hostname mismatch
      if e.code == .unavailable || e.code == .internal then
        return .passed
      else
        return .failed s!"Expected unavailable/internal error, got {e.code}: {e.message}"
  finally
    server.shutdownNow

/-- Test hostname override: connect to server with non-matching cert and override verification hostname. -/
def testHostnameOverrideSuccess : IO TestResult := do
  -- Read certificates
  let caCert ← readCertFile "ca.crt"
  let wrongHostCert ← readCertFile "wrong-host.crt"
  let wrongHostKey ← readCertFile "wrong-host.key"

  -- Start TLS server with cert for wronghost.example.com
  let serverCreds : SslServerCredentials := {
    serverCert := wrongHostCert
    serverKey := wrongHostKey
  }
  let (server, port) ← startTlsServer serverCreds

  try
    -- Override hostname verification to match the cert, even though we connect to localhost
    let clientCreds : SslCredentials := {
      rootCerts := caCert
      sslTargetNameOverride := "wronghost.example.com"
    }
    let channel ← Channel.createSecure s!"localhost:{port}" clientCreds

    let request : EchoRequest := { data := "hostname-override".toUTF8 }
    let requestBytes := Protolean.encodeMessage request

    match ← unaryCall channel echoMethod requestBytes with
    | .ok response =>
      match Protolean.decodeMessage (α := EchoResponse) response.data with
      | .ok decoded =>
        let expected := "ECHO:hostname-override".toUTF8
        if decoded.data == expected then
          return .passed
        else
          return .failed s!"Expected 'ECHO:hostname-override', got '{String.fromUTF8! decoded.data}'"
      | .error e =>
        return .failed s!"Decode error: {e}"
    | .error e =>
      return .failed s!"RPC error: {e}"
  finally
    server.shutdownNow

/-- Test TLS with insecure client (should fail) -/
def testTlsWithInsecureClient : IO TestResult := do
  -- Read certificates
  let serverCert ← readCertFile "server.crt"
  let serverKey ← readCertFile "server.key"

  -- Start TLS server
  let serverCreds : SslServerCredentials := {
    serverCert := serverCert
    serverKey := serverKey
  }
  let (server, port) ← startTlsServer serverCreds

  try
    -- Create insecure client channel (no TLS)
    let channel ← Channel.createInsecure s!"localhost:{port}"

    -- Make a test call - should fail
    let request : EchoRequest := { data := "test".toUTF8 }
    let requestBytes := Protolean.encodeMessage request

    match ← unaryCall channel echoMethod requestBytes with
    | .ok _ =>
      return .failed "Expected connection to fail with insecure client"
    | .error e =>
      -- Connection should fail (protocol mismatch)
      if e.code == .unavailable || e.code == .internal then
        return .passed
      else
        return .failed s!"Expected unavailable/internal error, got {e.code}: {e.message}"
  finally
    server.shutdownNow

/-- TLS test suite -/
def tlsTestSuite : TestSuite := suite "TLS/mTLS" #[
  test "TLS Basic" testTlsBasic,
  test "mTLS" testMtls,
  test "mTLS No Client Cert" testMtlsNoClientCert,
  test "mTLS Request No Client Cert" testMtlsRequestNoClientCert,
  test "Hostname Verification Failure" testHostnameVerificationFailure,
  test "Hostname Override Success" testHostnameOverrideSuccess,
  test "TLS with Insecure Client" testTlsWithInsecureClient
]

end Tests.integration.TlsTests
