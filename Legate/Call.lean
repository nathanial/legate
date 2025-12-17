/-
  Legate - gRPC for Lean 4
  RPC call functions
-/

import Legate.Error
import Legate.Status
import Legate.Metadata
import Legate.Channel
import Legate.Internal.FFI

namespace Legate

/-- Result of a unary call: response bytes, headers, and trailing metadata -/
structure UnaryResponse where
  /-- The response payload -/
  data : ByteArray
  /-- Server initial metadata (response headers) -/
  headers : Metadata
  /-- Server trailing metadata -/
  trailers : Metadata

/-- Make a unary RPC call.

    A unary call sends a single request and receives a single response.

    - `channel`: The channel to make the call on
    - `method`: The full method name (e.g., "/package.Service/Method")
    - `request`: The request payload as bytes
    - `options`: Call options (timeout, metadata, etc.)

    Returns the response data and trailing metadata, or an error.
-/
def unaryCall
    (channel : Channel)
    (method : String)
    (request : ByteArray)
    (options : CallOptions := {})
    : IO (GrpcResult UnaryResponse) := do
  let result ← Internal.unaryCall
    channel.toInternal method request options.timeoutMs options.metadata (if options.waitForReady then 1 else 0)
  match result with
  | .ok (data, headers, trailers) => return .ok { data, headers, trailers }
  | .error e => return .error e

/-- Convenience function for unary calls that only need the response data -/
def unaryCallData
    (channel : Channel)
    (method : String)
    (request : ByteArray)
    (options : CallOptions := {})
    : IO (GrpcResult ByteArray) := do
  let result ← unaryCall channel method request options
  return result.map (·.data)

end Legate
