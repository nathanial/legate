/-
  Shared protobuf type definitions for integration tests.

  Both Client and Server import this module to get the same types.
-/
import Protolean

-- Import proto types at compile time
proto_import "Proto/messages.proto"
