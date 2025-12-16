/-
  Legate - gRPC for Lean 4
  Error types and status codes
-/

namespace Legate

/-- gRPC status codes as defined in the gRPC specification -/
inductive StatusCode where
  | ok
  | cancelled
  | unknown
  | invalidArgument
  | deadlineExceeded
  | notFound
  | alreadyExists
  | permissionDenied
  | resourceExhausted
  | failedPrecondition
  | aborted
  | outOfRange
  | unimplemented
  | internal
  | unavailable
  | dataLoss
  | unauthenticated
  deriving Repr, DecidableEq, Inhabited, BEq

namespace StatusCode

/-- Convert a raw status code number to StatusCode -/
def fromNat (n : Nat) : StatusCode :=
  match n with
  | 0 => .ok
  | 1 => .cancelled
  | 2 => .unknown
  | 3 => .invalidArgument
  | 4 => .deadlineExceeded
  | 5 => .notFound
  | 6 => .alreadyExists
  | 7 => .permissionDenied
  | 8 => .resourceExhausted
  | 9 => .failedPrecondition
  | 10 => .aborted
  | 11 => .outOfRange
  | 12 => .unimplemented
  | 13 => .internal
  | 14 => .unavailable
  | 15 => .dataLoss
  | 16 => .unauthenticated
  | _ => .unknown

/-- Convert StatusCode to its numeric value -/
def toNat (c : StatusCode) : Nat :=
  match c with
  | .ok => 0
  | .cancelled => 1
  | .unknown => 2
  | .invalidArgument => 3
  | .deadlineExceeded => 4
  | .notFound => 5
  | .alreadyExists => 6
  | .permissionDenied => 7
  | .resourceExhausted => 8
  | .failedPrecondition => 9
  | .aborted => 10
  | .outOfRange => 11
  | .unimplemented => 12
  | .internal => 13
  | .unavailable => 14
  | .dataLoss => 15
  | .unauthenticated => 16

/-- Get a human-readable description of the status code -/
def description (c : StatusCode) : String :=
  match c with
  | .ok => "OK"
  | .cancelled => "Cancelled"
  | .unknown => "Unknown"
  | .invalidArgument => "Invalid Argument"
  | .deadlineExceeded => "Deadline Exceeded"
  | .notFound => "Not Found"
  | .alreadyExists => "Already Exists"
  | .permissionDenied => "Permission Denied"
  | .resourceExhausted => "Resource Exhausted"
  | .failedPrecondition => "Failed Precondition"
  | .aborted => "Aborted"
  | .outOfRange => "Out of Range"
  | .unimplemented => "Unimplemented"
  | .internal => "Internal"
  | .unavailable => "Unavailable"
  | .dataLoss => "Data Loss"
  | .unauthenticated => "Unauthenticated"

instance : ToString StatusCode where
  toString := description

end StatusCode

/-- A gRPC error containing the status code, message, and optional details -/
structure GrpcError where
  /-- The gRPC status code -/
  code : StatusCode
  /-- Human-readable error message -/
  message : String
  /-- Optional binary error details (e.g., for rich error model) -/
  details : Option ByteArray := none

instance : Repr GrpcError where
  reprPrec e _ := s!"GrpcError(\{code := {repr e.code}, message := {repr e.message}, details := {e.details.isSome}})"

namespace GrpcError

/-- Create a simple error with just a code and message -/
def simple (code : StatusCode) (message : String) : GrpcError :=
  { code, message, details := none }

/-- Check if this is an OK status (which shouldn't typically be an error) -/
def isOk (e : GrpcError) : Bool :=
  e.code == .ok

instance : ToString GrpcError where
  toString e := s!"GrpcError({e.code}: {e.message})"

end GrpcError

/-- Result type for gRPC operations -/
abbrev GrpcResult (α : Type) := Except GrpcError α

namespace GrpcResult

/-- Check if the result is successful -/
def isOk {α : Type} (r : GrpcResult α) : Bool :=
  match r with
  | .ok _ => true
  | .error _ => false

/-- Get the value or a default -/
def getD {α : Type} (r : GrpcResult α) (default : α) : α :=
  match r with
  | .ok v => v
  | .error _ => default

/-- Map over the success value -/
def map {α β : Type} (f : α → β) (r : GrpcResult α) : GrpcResult β :=
  match r with
  | .ok v => .ok (f v)
  | .error e => .error e

/-- Flat map (bind) for GrpcResult -/
def bind {α β : Type} (r : GrpcResult α) (f : α → GrpcResult β) : GrpcResult β :=
  match r with
  | .ok v => f v
  | .error e => .error e

instance : Monad GrpcResult where
  pure := .ok
  bind := bind

instance : MonadExcept GrpcError GrpcResult where
  throw := .error
  tryCatch r handler :=
    match r with
    | .ok v => .ok v
    | .error e => handler e

end GrpcResult

end Legate
