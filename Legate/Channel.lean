/-
  Legate - gRPC for Lean 4
  Client channel abstraction
-/

import Legate.Error
import Legate.Metadata
import Legate.Internal.FFI

namespace Legate

/-- A gRPC channel represents a connection to a server -/
structure Channel where
  private mk ::
  private handle : Internal.Channel

/-- Channel connectivity state -/
inductive ConnectivityState where
  | idle
  | connecting
  | ready
  | transientFailure
  | shutdown
  deriving Repr, DecidableEq, BEq

namespace ConnectivityState

def fromNat (n : Nat) : ConnectivityState :=
  match n with
  | 0 => .idle
  | 1 => .connecting
  | 2 => .ready
  | 3 => .transientFailure
  | 4 => .shutdown
  | _ => .idle

instance : ToString ConnectivityState where
  toString s :=
    match s with
    | .idle => "IDLE"
    | .connecting => "CONNECTING"
    | .ready => "READY"
    | .transientFailure => "TRANSIENT_FAILURE"
    | .shutdown => "SHUTDOWN"

end ConnectivityState

/-- SSL/TLS credentials for secure connections -/
structure SslCredentials where
  /-- PEM-encoded root certificates (optional, uses system roots if empty) -/
  rootCerts : String := ""
  /-- PEM-encoded private key (optional, for mutual TLS) -/
  privateKey : String := ""
  /-- PEM-encoded certificate chain (optional, for mutual TLS) -/
  certChain : String := ""
  /-- Override the hostname used for TLS verification (advanced).

      This is passed through to gRPC as `grpc.ssl_target_name_override`.
      Leave empty for safe defaults (verify against the channel target host).
  -/
  sslTargetNameOverride : String := ""
  deriving Repr, Inhabited

namespace Channel

/-- Create an insecure channel (no TLS) to the given target.

    The target should be in the form "host:port", e.g., "localhost:50051".
-/
def createInsecure (target : String) : IO Channel := do
  let handle ← Internal.channelCreateInsecure target
  return ⟨handle⟩

/-- Create a secure channel with TLS credentials.

    The target should be in the form "host:port".
-/
def createSecure (target : String) (creds : SslCredentials := {}) : IO Channel := do
  let handle ← Internal.channelCreateSecure
    target
    creds.rootCerts
    creds.privateKey
    creds.certChain
    creds.sslTargetNameOverride
  return ⟨handle⟩

/-- Get the current connectivity state of the channel.

    If `tryToConnect` is true, the channel will attempt to connect
    if it is currently idle.
-/
def getState (channel : Channel) (tryToConnect : Bool := false) : IO ConnectivityState := do
  let n ← Internal.channelGetState channel.handle (if tryToConnect then 1 else 0)
  return ConnectivityState.fromNat n.toNat

/-- Check if the channel is ready to make calls -/
def isReady (channel : Channel) : IO Bool := do
  let state ← channel.getState
  return state == .ready

/-- Wait for the channel to be ready, with optional timeout.

    Returns true if the channel became ready, false if timeout occurred.
-/
partial def waitForReady (channel : Channel) (timeoutMs : UInt64 := 5000) : IO Bool := do
  let startTime ← IO.monoMsNow
  let rec loop : IO Bool := do
    let state ← channel.getState true
    if state == .ready then
      return true
    if state == .shutdown then
      return false
    let elapsed := (← IO.monoMsNow) - startTime
    if elapsed >= timeoutMs.toNat then
      return false
    IO.sleep 10  -- Small delay between checks
    loop
  loop

/-- Access the internal handle (for FFI operations) -/
def toInternal (channel : Channel) : Internal.Channel :=
  channel.handle

end Channel

end Legate
