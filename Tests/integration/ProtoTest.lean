/-
  Minimal test to debug proto_import
-/
import Protolean

set_option diagnostics true

-- Test proto_import
proto_import "Proto/messages.proto"

-- Check what was generated
#check @EchoRequest
