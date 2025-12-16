/-
  Legate - gRPC for Lean 4
  Metadata types for request/response headers and trailers
-/

namespace Legate

/-- gRPC metadata is a collection of key-value pairs (headers/trailers) -/
abbrev Metadata := Array (String × String)

namespace Metadata

/-- Empty metadata -/
def empty : Metadata := #[]

/-- Create metadata from a list of key-value pairs -/
def ofList (pairs : List (String × String)) : Metadata :=
  pairs.toArray

/-- Add a key-value pair to metadata -/
def add (m : Metadata) (key : String) (value : String) : Metadata :=
  m.push (key, value)

/-- Get the first value for a given key -/
def get? (m : Metadata) (key : String) : Option String :=
  m.findSome? fun (k, v) => if k == key then some v else none

/-- Get all values for a given key -/
def getAll (m : Metadata) (key : String) : Array String :=
  m.filterMap fun (k, v) => if k == key then some v else none

/-- Check if a key exists -/
def contains (m : Metadata) (key : String) : Bool :=
  m.any fun (k, _) => k == key

/-- Remove all entries for a given key -/
def remove (m : Metadata) (key : String) : Metadata :=
  m.filter fun (k, _) => k != key

/-- Merge two metadata collections -/
def merge (m1 m2 : Metadata) : Metadata :=
  m1 ++ m2

/-- Convert metadata to a list -/
def toListPairs (m : Metadata) : List (String × String) :=
  Array.toList m

instance : Append Metadata where
  append := merge

instance : EmptyCollection Metadata where
  emptyCollection := empty

instance : ToString Metadata where
  toString m :=
    let pairs := m.map fun (k, v) => s!"{k}: {v}"
    s!"[{String.intercalate ", " pairs.toList}]"

end Metadata

/-- Options for making an RPC call -/
structure CallOptions where
  /-- Timeout in milliseconds (0 = no timeout) -/
  timeoutMs : UInt64 := 0
  /-- Request metadata (headers) -/
  metadata : Metadata := #[]
  /-- Wait for the channel to be ready before making the call -/
  waitForReady : Bool := false
  deriving Repr, Inhabited

namespace CallOptions

/-- Default call options -/
def default : CallOptions := {}

/-- Set the timeout -/
def withTimeout (opts : CallOptions) (ms : UInt64) : CallOptions :=
  { opts with timeoutMs := ms }

/-- Set timeout in seconds -/
def withTimeoutSeconds (opts : CallOptions) (s : UInt64) : CallOptions :=
  { opts with timeoutMs := s * 1000 }

/-- Add metadata -/
def withMetadata (opts : CallOptions) (m : Metadata) : CallOptions :=
  { opts with metadata := m }

/-- Add a single metadata entry -/
def addMetadata (opts : CallOptions) (key : String) (value : String) : CallOptions :=
  { opts with metadata := opts.metadata.add key value }

/-- Set wait for ready -/
def withWaitForReady (opts : CallOptions) (wait : Bool := true) : CallOptions :=
  { opts with waitForReady := wait }

end CallOptions

end Legate
