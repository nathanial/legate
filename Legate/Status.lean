/-
  Legate - gRPC for Lean 4
  Status type for RPC responses
-/

import Legate.Error

namespace Legate

/-- gRPC status returned from RPC calls -/
structure Status where
  /-- The status code -/
  code : StatusCode
  /-- Optional status message -/
  message : String := ""
  deriving Repr, BEq

namespace Status

/-- The OK status -/
def ok : Status :=
  { code := .ok, message := "" }

/-- Create a status from a code and message -/
def make (code : StatusCode) (message : String := "") : Status :=
  { code, message }

/-- Check if this status indicates success -/
def isOk (s : Status) : Bool :=
  s.code == .ok

/-- Check if this status indicates an error -/
def isError (s : Status) : Bool :=
  s.code != .ok

/-- Convert a Status to a GrpcError (for non-ok statuses) -/
def toError (s : Status) : Option GrpcError :=
  if s.isOk then none
  else some { code := s.code, message := s.message }

/-- Convert a Status to a GrpcResult -/
def toResult {α : Type} (s : Status) (value : α) : GrpcResult α :=
  if s.isOk then .ok value
  else .error { code := s.code, message := s.message }

instance : ToString Status where
  toString s :=
    if s.message.isEmpty then
      s!"{s.code}"
    else
      s!"{s.code}: {s.message}"

end Status

end Legate
