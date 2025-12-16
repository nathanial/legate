/-
  Legate - gRPC for Lean 4

  A generic gRPC library providing transport features for Lean 4 applications.
  Supports all four RPC types: unary, client streaming, server streaming,
  and bidirectional streaming.

  This library handles the gRPC transport layer. For message serialization
  (Protocol Buffers), use a separate protobuf library.

  ## Quick Start

  ### Client Usage

  ```lean
  import Legate

  def main : IO Unit := do
    -- Create a channel to the server
    let channel ← Legate.Channel.createInsecure "localhost:50051"

    -- Make a unary call
    let request := "Hello".toUTF8
    match ← Legate.unaryCall channel "/example.Greeter/SayHello" request with
    | .ok response => IO.println s!"Response: {String.fromUTF8! response.data}"
    | .error e => IO.eprintln s!"Error: {e}"
  ```

  ### Server Usage

  ```lean
  import Legate

  def main : IO Unit := do
    Legate.runServer "0.0.0.0:50051" fun builder => do
      builder.registerUnary "/example.Greeter/SayHello" fun _ctx request =>
        let response := s!"Hello, {String.fromUTF8! request}!".toUTF8
        return .ok (response, #[])
  ```

  ## Module Structure

  - `Legate.Error`: Error types and status codes
  - `Legate.Status`: RPC status type
  - `Legate.Metadata`: Headers and trailers
  - `Legate.Channel`: Client channel abstraction
  - `Legate.Call`: Unary RPC functions
  - `Legate.Stream`: Streaming RPC abstractions
  - `Legate.Server`: Server-side abstractions
-/

import Legate.Error
import Legate.Status
import Legate.Metadata
import Legate.Channel
import Legate.Call
import Legate.Stream
import Legate.Server
