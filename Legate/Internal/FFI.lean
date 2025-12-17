/-
  Legate - gRPC for Lean 4
  Low-level FFI declarations

  This module contains the raw FFI bindings to the C++ gRPC wrapper.
  These should not be used directly; use the higher-level API instead.
-/

import Legate.Error
import Legate.Status
import Legate.Metadata

namespace Legate.Internal

-- ============================================================================
-- Opaque Types
-- ============================================================================

/-- Opaque handle to a gRPC channel -/
opaque ChannelPointed : NonemptyType
def Channel := ChannelPointed.type
instance : Nonempty Channel := ChannelPointed.property

/-- Opaque handle to a client streaming call -/
opaque ClientStreamPointed : NonemptyType
def ClientStream := ClientStreamPointed.type
instance : Nonempty ClientStream := ClientStreamPointed.property

/-- Opaque handle to a server streaming call -/
opaque ServerStreamPointed : NonemptyType
def ServerStream := ServerStreamPointed.type
instance : Nonempty ServerStream := ServerStreamPointed.property

/-- Opaque handle to a bidirectional streaming call -/
opaque BidiStreamPointed : NonemptyType
def BidiStream := BidiStreamPointed.type
instance : Nonempty BidiStream := BidiStreamPointed.property

/-- Opaque handle to a server builder -/
opaque ServerBuilderPointed : NonemptyType
def ServerBuilder := ServerBuilderPointed.type
instance : Nonempty ServerBuilder := ServerBuilderPointed.property

/-- Opaque handle to a running server -/
opaque ServerPointed : NonemptyType
def Server := ServerPointed.type
instance : Nonempty Server := ServerPointed.property

-- ============================================================================
-- Initialization
-- ============================================================================

/-- Initialize the gRPC runtime -/
@[extern "legate_init"]
opaque grpcInit : IO Unit

/-- Shutdown the gRPC runtime -/
@[extern "legate_shutdown"]
opaque grpcShutdown : IO Unit

-- Note: Initialization is handled automatically by the C++ library
-- when the first FFI function is called.

-- ============================================================================
-- Channel FFI
-- ============================================================================

/-- Create an insecure channel -/
@[extern "legate_channel_create_insecure"]
opaque channelCreateInsecure (target : @& String) : IO Channel

/-- Create a secure channel with TLS -/
@[extern "legate_channel_create_secure"]
opaque channelCreateSecure
    (target : @& String)
    (rootCerts : @& String)
    (privateKey : @& String)
    (certChain : @& String)
    : IO Channel

/-- Get channel connectivity state -/
@[extern "legate_channel_get_state"]
opaque channelGetState (channel : @& Channel) (tryToConnect : UInt8) : IO UInt32

-- ============================================================================
-- Unary Call FFI
-- ============================================================================

/-- Make a unary RPC call -/
@[extern "legate_unary_call"]
opaque unaryCall
    (channel : @& Channel)
    (method : @& String)
    (request : @& ByteArray)
    (timeoutMs : UInt64)
    (metadata : @& Metadata)
    : IO (Except GrpcError (ByteArray × Metadata))

-- ============================================================================
-- Client Streaming FFI
-- ============================================================================

/-- Start a client streaming call -/
@[extern "legate_client_streaming_call_start"]
opaque clientStreamingCallStart
    (channel : @& Channel)
    (method : @& String)
    (timeoutMs : UInt64)
    (metadata : @& Metadata)
    : IO (Except GrpcError ClientStream)

/-- Write to a client stream -/
@[extern "legate_client_stream_write"]
opaque clientStreamWrite
    (stream : @& ClientStream)
    (data : @& ByteArray)
    : IO (Except GrpcError Unit)

/-- Signal that writes are done -/
@[extern "legate_client_stream_writes_done"]
opaque clientStreamWritesDone (stream : @& ClientStream) : IO (Except GrpcError Unit)

/-- Finish the call and get the response -/
@[extern "legate_client_stream_finish"]
opaque clientStreamFinish
    (stream : @& ClientStream)
    : IO (Except GrpcError (ByteArray × Metadata × Status))

-- ============================================================================
-- Server Streaming FFI
-- ============================================================================

/-- Start a server streaming call -/
@[extern "legate_server_streaming_call_start"]
opaque serverStreamingCallStart
    (channel : @& Channel)
    (method : @& String)
    (request : @& ByteArray)
    (timeoutMs : UInt64)
    (metadata : @& Metadata)
    : IO (Except GrpcError ServerStream)

/-- Read from a server stream -/
@[extern "legate_server_stream_read"]
opaque serverStreamRead (stream : @& ServerStream) : IO (Except GrpcError (Option ByteArray))

/-- Get trailing metadata -/
@[extern "legate_server_stream_get_trailers"]
opaque serverStreamGetTrailers (stream : @& ServerStream) : IO Metadata

/-- Get the final status -/
@[extern "legate_server_stream_get_status"]
opaque serverStreamGetStatus (stream : @& ServerStream) : IO Status

-- ============================================================================
-- Bidirectional Streaming FFI
-- ============================================================================

/-- Start a bidirectional streaming call -/
@[extern "legate_bidi_streaming_call_start"]
opaque bidiStreamingCallStart
    (channel : @& Channel)
    (method : @& String)
    (timeoutMs : UInt64)
    (metadata : @& Metadata)
    : IO (Except GrpcError BidiStream)

/-- Write to a bidi stream -/
@[extern "legate_bidi_stream_write"]
opaque bidiStreamWrite
    (stream : @& BidiStream)
    (data : @& ByteArray)
    : IO (Except GrpcError Unit)

/-- Signal that writes are done -/
@[extern "legate_bidi_stream_writes_done"]
opaque bidiStreamWritesDone (stream : @& BidiStream) : IO (Except GrpcError Unit)

/-- Read from a bidi stream -/
@[extern "legate_bidi_stream_read"]
opaque bidiStreamRead (stream : @& BidiStream) : IO (Except GrpcError (Option ByteArray))

/-- Get the final status -/
@[extern "legate_bidi_stream_get_status"]
opaque bidiStreamGetStatus (stream : @& BidiStream) : IO Status

-- ============================================================================
-- Server FFI
-- ============================================================================

/-- Create a new server builder -/
@[extern "legate_server_builder_new"]
opaque serverBuilderNew : IO ServerBuilder

/-- Add a listening port -/
@[extern "legate_server_builder_add_listening_port"]
opaque serverBuilderAddListeningPort
    (builder : @& ServerBuilder)
    (addr : @& String)
    (useTls : UInt8)
    : IO UInt32

/-- Register a unary handler.
    Handler receives: method name, client metadata, request bytes
    Returns: response bytes and trailing metadata, or error
-/
@[extern "legate_server_register_unary"]
opaque serverRegisterUnary
    (builder : @& ServerBuilder)
    (method : @& String)
    (handler : String → Metadata → ByteArray → IO (Except GrpcError (ByteArray × Metadata)))
    : IO Unit

/-- Register a client streaming handler.
    Handler receives: method name, client metadata, recv function
    Returns: response bytes and trailing metadata, or error
-/
@[extern "legate_server_register_client_streaming"]
opaque serverRegisterClientStreaming
    (builder : @& ServerBuilder)
    (method : @& String)
    (handler : String → Metadata → IO (Option ByteArray) → IO (Except GrpcError (ByteArray × Metadata)))
    : IO Unit

/-- Register a server streaming handler.
    Handler receives: method name, client metadata, request bytes, send function
    Returns: trailing metadata, or error
-/
@[extern "legate_server_register_server_streaming"]
opaque serverRegisterServerStreaming
    (builder : @& ServerBuilder)
    (method : @& String)
    (handler : String → Metadata → ByteArray → (ByteArray → IO Unit) → IO (Except GrpcError Metadata))
    : IO Unit

/-- Register a bidirectional streaming handler.
    Handler receives: method name, client metadata, recv function, send function
    Returns: trailing metadata, or error
-/
@[extern "legate_server_register_bidi_streaming"]
opaque serverRegisterBidiStreaming
    (builder : @& ServerBuilder)
    (method : @& String)
    (handler : String → Metadata → IO (Option ByteArray) → (ByteArray → IO Unit) → IO (Except GrpcError Metadata))
    : IO Unit

/-- Build the server -/
@[extern "legate_server_builder_build"]
opaque serverBuilderBuild (builder : @& ServerBuilder) : IO Server

/-- Start the server -/
@[extern "legate_server_start"]
opaque serverStart (server : @& Server) : IO Unit

/-- Wait for the server to shutdown -/
@[extern "legate_server_wait"]
opaque serverWait (server : @& Server) : IO Unit

/-- Shutdown the server gracefully -/
@[extern "legate_server_shutdown"]
opaque serverShutdown (server : @& Server) : IO Unit

/-- Shutdown the server immediately -/
@[extern "legate_server_shutdown_now"]
opaque serverShutdownNow (server : @& Server) : IO Unit

end Legate.Internal
