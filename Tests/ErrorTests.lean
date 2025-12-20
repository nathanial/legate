/-
  Tests for Legate.Error module
-/

import Crucible
import Legate.Error

open Crucible
open Legate

namespace Tests.ErrorTests

/-- Check if a string contains a substring -/
def String.containsSubstr (s : String) (sub : String) : Bool :=
  (s.splitOn sub).length > 1

testSuite "Error Tests"

-- StatusCode tests

test "StatusCode fromNat" := do
  ensure (StatusCode.fromNat 0 == .ok) "0 should be ok"
  ensure (StatusCode.fromNat 1 == .cancelled) "1 should be cancelled"
  ensure (StatusCode.fromNat 2 == .unknown) "2 should be unknown"
  ensure (StatusCode.fromNat 3 == .invalidArgument) "3 should be invalidArgument"
  ensure (StatusCode.fromNat 4 == .deadlineExceeded) "4 should be deadlineExceeded"
  ensure (StatusCode.fromNat 5 == .notFound) "5 should be notFound"
  ensure (StatusCode.fromNat 6 == .alreadyExists) "6 should be alreadyExists"
  ensure (StatusCode.fromNat 7 == .permissionDenied) "7 should be permissionDenied"
  ensure (StatusCode.fromNat 8 == .resourceExhausted) "8 should be resourceExhausted"
  ensure (StatusCode.fromNat 9 == .failedPrecondition) "9 should be failedPrecondition"
  ensure (StatusCode.fromNat 10 == .aborted) "10 should be aborted"
  ensure (StatusCode.fromNat 11 == .outOfRange) "11 should be outOfRange"
  ensure (StatusCode.fromNat 12 == .unimplemented) "12 should be unimplemented"
  ensure (StatusCode.fromNat 13 == .internal) "13 should be internal"
  ensure (StatusCode.fromNat 14 == .unavailable) "14 should be unavailable"
  ensure (StatusCode.fromNat 15 == .dataLoss) "15 should be dataLoss"
  ensure (StatusCode.fromNat 16 == .unauthenticated) "16 should be unauthenticated"

test "StatusCode toNat" := do
  ensure (StatusCode.ok.toNat == 0) "ok should be 0"
  ensure (StatusCode.cancelled.toNat == 1) "cancelled should be 1"
  ensure (StatusCode.unknown.toNat == 2) "unknown should be 2"
  ensure (StatusCode.invalidArgument.toNat == 3) "invalidArgument should be 3"
  ensure (StatusCode.internal.toNat == 13) "internal should be 13"
  ensure (StatusCode.unauthenticated.toNat == 16) "unauthenticated should be 16"

test "StatusCode roundtrip" := do
  let codes := #[
    StatusCode.ok, .cancelled, .unknown, .invalidArgument, .deadlineExceeded,
    .notFound, .alreadyExists, .permissionDenied, .resourceExhausted,
    .failedPrecondition, .aborted, .outOfRange, .unimplemented, .internal,
    .unavailable, .dataLoss, .unauthenticated
  ]
  for code in codes do
    ensure (StatusCode.fromNat code.toNat == code) s!"Round-trip failed for {code}"

test "StatusCode unknown values map to unknown" := do
  ensure (StatusCode.fromNat 100 == .unknown) "100 should map to unknown"
  ensure (StatusCode.fromNat 999 == .unknown) "999 should map to unknown"

test "StatusCode description" := do
  ensure (StatusCode.ok.description == "OK") "ok description"
  ensure (StatusCode.cancelled.description == "Cancelled") "cancelled description"
  ensure (StatusCode.notFound.description == "Not Found") "notFound description"
  ensure (StatusCode.internal.description == "Internal") "internal description"

test "StatusCode ToString" := do
  ensure (toString StatusCode.ok == "OK") "ok toString"
  ensure (toString StatusCode.unavailable == "Unavailable") "unavailable toString"

-- GrpcError tests

test "GrpcError simple" := do
  let err := GrpcError.simple .notFound "Resource not found"
  ensure (err.code == .notFound) "code mismatch"
  ensure (err.message == "Resource not found") "message mismatch"
  ensure err.details.isNone "details should be none"

test "GrpcError isOk" := do
  let okErr := GrpcError.simple .ok "OK"
  let notOkErr := GrpcError.simple .internal "Error"
  ensure okErr.isOk "ok error should return true"
  ensure (!notOkErr.isOk) "non-ok error should return false"

test "GrpcError ToString" := do
  let err := GrpcError.simple .unavailable "Server busy"
  let s := toString err
  ensure (String.containsSubstr s "Unavailable") "should contain status"
  ensure (String.containsSubstr s "Server busy") "should contain message"

test "GrpcError with details" := do
  let details := "extra info".toUTF8
  let err : GrpcError := { code := .internal, message := "Error", details := some details }
  ensure err.details.isSome "details should be some"
  match err.details with
  | some d => ensure (d == details) "details mismatch"
  | none => ensure false "unreachable"

-- GrpcResult tests

test "GrpcResult ok" := do
  let result : GrpcResult String := .ok "success"
  ensure result.isOk "should be ok"
  ensure (result.getD "default" == "success") "getD failed"

test "GrpcResult error" := do
  let err := GrpcError.simple .internal "Error"
  let result : GrpcResult String := .error err
  ensure (!result.isOk) "should be error"
  ensure (result.getD "default" == "default") "getD should return default"

test "GrpcResult map" := do
  let ok : GrpcResult Int := .ok 42
  let err : GrpcResult Int := .error (GrpcError.simple .internal "Error")

  let okMapped := ok.map (· * 2)
  let errMapped := err.map (· * 2)

  match okMapped with
  | .ok v => ensure (v == 84) "map on ok should transform value"
  | .error _ => ensure false "map on ok should stay ok"

  match errMapped with
  | .ok _ => ensure false "map on error should stay error"
  | .error _ => pure ()

test "GrpcResult bind" := do
  let ok : GrpcResult Int := .ok 42
  let err : GrpcResult Int := .error (GrpcError.simple .internal "Error")

  let double : Int → GrpcResult Int := fun x => .ok (x * 2)
  let fail : Int → GrpcResult Int := fun _ => .error (GrpcError.simple .cancelled "Cancelled")

  match ok.bind double with
  | .ok v => ensure (v == 84) "bind double on ok"
  | .error _ => ensure false "bind double should succeed"

  match ok.bind fail with
  | .ok _ => ensure false "bind fail should fail"
  | .error e => ensure (e.code == .cancelled) "bind fail wrong error"

  match err.bind double with
  | .ok _ => ensure false "bind on error should stay error"
  | .error e => ensure (e.code == .internal) "bind preserves error"

test "GrpcResult monad syntax" := do
  let computation : GrpcResult Int := do
    let a ← (pure 10 : GrpcResult Int)
    let b ← (pure 20 : GrpcResult Int)
    return a + b

  match computation with
  | .ok v => ensure (v == 30) "monad computation failed"
  | .error _ => ensure false "monad should succeed"

#generate_tests

end Tests.ErrorTests
