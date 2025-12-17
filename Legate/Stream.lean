/-
  Legate - gRPC for Lean 4
  Streaming abstractions
-/

import Legate.Error
import Legate.Status
import Legate.Metadata
import Legate.Channel
import Legate.Internal.FFI

namespace Legate

-- ============================================================================
-- Client Streaming
-- ============================================================================

/-- A client stream for sending multiple requests and receiving a single response -/
structure ClientStreamWriter where
  private mk ::
  private handle : Internal.ClientStream

/-- Result of finishing a client streaming call -/
structure ClientStreamResponse where
  /-- The response payload -/
  data : ByteArray
  /-- Server initial metadata (response headers) -/
  headers : Metadata
  /-- Server trailing metadata -/
  trailers : Metadata
  /-- Final status -/
  status : Status

namespace ClientStreamWriter

/-- Write a message to the stream -/
def write (stream : ClientStreamWriter) (data : ByteArray) : IO (GrpcResult Unit) :=
  Internal.clientStreamWrite stream.handle data

/-- Signal that no more messages will be written -/
def writesDone (stream : ClientStreamWriter) : IO (GrpcResult Unit) :=
  Internal.clientStreamWritesDone stream.handle

/-- Finish the call and receive the response -/
def finish (stream : ClientStreamWriter) : IO (GrpcResult ClientStreamResponse) := do
  let result ← Internal.clientStreamFinish stream.handle
  match result with
  | .ok (data, trailers, status) =>
    -- Get headers (initial metadata) - available after finish
    let headers ← Internal.clientStreamGetHeaders stream.handle
    return .ok { data, headers, trailers, status }
  | .error e => return .error e

/-- Get initial metadata (response headers) -/
def getHeaders (stream : ClientStreamWriter) : IO Metadata :=
  Internal.clientStreamGetHeaders stream.handle

/-- Cancel the stream. The server will see the call as cancelled. -/
def cancel (stream : ClientStreamWriter) : IO Unit :=
  Internal.clientStreamCancel stream.handle

/-- Write multiple messages to the stream -/
def writeAll (stream : ClientStreamWriter) (messages : Array ByteArray) : IO (GrpcResult Unit) := do
  for msg in messages do
    match ← stream.write msg with
    | .ok () => pure ()
    | .error e => return .error e
  return .ok ()

end ClientStreamWriter

/-- Start a client streaming call -/
def clientStreamingCall
    (channel : Channel)
    (method : String)
    (options : CallOptions := {})
    : IO (GrpcResult ClientStreamWriter) := do
  let result ← Internal.clientStreamingCallStart
    channel.toInternal method options.timeoutMs options.metadata (if options.waitForReady then 1 else 0)
  match result with
  | .ok handle => return .ok ⟨handle⟩
  | .error e => return .error e

-- ============================================================================
-- Server Streaming
-- ============================================================================

/-- A server stream for receiving multiple responses -/
structure ServerStreamReader where
  private mk ::
  private handle : Internal.ServerStream

namespace ServerStreamReader

/-- Read the next message from the stream.
    Returns `none` when the stream ends.
-/
def read (stream : ServerStreamReader) : IO (GrpcResult (Option ByteArray)) :=
  Internal.serverStreamRead stream.handle

/-- Get initial metadata (response headers) -/
def getHeaders (stream : ServerStreamReader) : IO Metadata :=
  Internal.serverStreamGetHeaders stream.handle

/-- Get trailing metadata (available after stream ends) -/
def getTrailers (stream : ServerStreamReader) : IO Metadata :=
  Internal.serverStreamGetTrailers stream.handle

/-- Get the final status -/
def getStatus (stream : ServerStreamReader) : IO Status :=
  Internal.serverStreamGetStatus stream.handle

/-- Read all messages from the stream into an array -/
partial def readAll (stream : ServerStreamReader) : IO (GrpcResult (Array ByteArray)) := do
  let rec loop (acc : Array ByteArray) : IO (GrpcResult (Array ByteArray)) := do
    match ← stream.read with
    | .ok (some data) => loop (acc.push data)
    | .ok none => return .ok acc
    | .error e => return .error e
  loop #[]

/-- Iterate over all messages in the stream, calling a function for each -/
partial def forEach (stream : ServerStreamReader) (f : ByteArray → IO Unit) : IO Status := do
  let rec loop : IO Status := do
    match ← stream.read with
    | .ok (some data) =>
      f data
      loop
    | .ok none => stream.getStatus
    | .error e => return ⟨e.code, e.message, e.details⟩
  loop

/-- Fold over all messages in the stream -/
partial def fold {α : Type} (stream : ServerStreamReader) (init : α) (f : α → ByteArray → IO α) : IO (GrpcResult α) := do
  let rec loop (acc : α) : IO (GrpcResult α) := do
    match ← stream.read with
    | .ok (some data) =>
      let newAcc ← f acc data
      loop newAcc
    | .ok none => return .ok acc
    | .error e => return .error e
  loop init

/-- Cancel the stream. Subsequent reads will fail. -/
def cancel (stream : ServerStreamReader) : IO Unit :=
  Internal.serverStreamCancel stream.handle

end ServerStreamReader

/-- Start a server streaming call -/
def serverStreamingCall
    (channel : Channel)
    (method : String)
    (request : ByteArray)
    (options : CallOptions := {})
    : IO (GrpcResult ServerStreamReader) := do
  let result ← Internal.serverStreamingCallStart
    channel.toInternal method request options.timeoutMs options.metadata (if options.waitForReady then 1 else 0)
  match result with
  | .ok handle => return .ok ⟨handle⟩
  | .error e => return .error e

-- ============================================================================
-- Bidirectional Streaming
-- ============================================================================

/-- A bidirectional stream for sending and receiving messages concurrently -/
structure BidiStream where
  private mk ::
  private handle : Internal.BidiStream

namespace BidiStream

/-- Write a message to the stream -/
def write (stream : BidiStream) (data : ByteArray) : IO (GrpcResult Unit) :=
  Internal.bidiStreamWrite stream.handle data

/-- Signal that no more messages will be written -/
def writesDone (stream : BidiStream) : IO (GrpcResult Unit) :=
  Internal.bidiStreamWritesDone stream.handle

/-- Read the next message from the stream.
    Returns `none` when the stream ends.
-/
def read (stream : BidiStream) : IO (GrpcResult (Option ByteArray)) :=
  Internal.bidiStreamRead stream.handle

/-- Get the final status -/
def getStatus (stream : BidiStream) : IO Status :=
  Internal.bidiStreamGetStatus stream.handle

/-- Get initial metadata (response headers) -/
def getHeaders (stream : BidiStream) : IO Metadata :=
  Internal.bidiStreamGetHeaders stream.handle

/-- Get trailing metadata (available after stream ends) -/
def getTrailers (stream : BidiStream) : IO Metadata :=
  Internal.bidiStreamGetTrailers stream.handle

/-- Write multiple messages to the stream -/
def writeAll (stream : BidiStream) (messages : Array ByteArray) : IO (GrpcResult Unit) := do
  for msg in messages do
    match ← stream.write msg with
    | .ok () => pure ()
    | .error e => return .error e
  return .ok ()

/-- Read all messages from the stream into an array -/
partial def readAll (stream : BidiStream) : IO (GrpcResult (Array ByteArray)) := do
  let rec loop (acc : Array ByteArray) : IO (GrpcResult (Array ByteArray)) := do
    match ← stream.read with
    | .ok (some data) => loop (acc.push data)
    | .ok none => return .ok acc
    | .error e => return .error e
  loop #[]

/-- Cancel the stream. The server will see the call as cancelled. -/
def cancel (stream : BidiStream) : IO Unit :=
  Internal.bidiStreamCancel stream.handle

end BidiStream

/-- Start a bidirectional streaming call -/
def bidiStreamingCall
    (channel : Channel)
    (method : String)
    (options : CallOptions := {})
    : IO (GrpcResult BidiStream) := do
  let result ← Internal.bidiStreamingCallStart
    channel.toInternal method options.timeoutMs options.metadata (if options.waitForReady then 1 else 0)
  match result with
  | .ok handle => return .ok ⟨handle⟩
  | .error e => return .error e

end Legate
