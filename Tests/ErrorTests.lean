/-
  Tests for Legate.Error module
-/

import Legate.Error
import Tests.Framework

open Tests
open Legate

namespace Tests.ErrorTests

-- StatusCode tests

def testStatusCodeFromNat : TestCase := test "StatusCode.fromNat" do
  -- Test all status codes
  if StatusCode.fromNat 0 != .ok then return .failed "0 should be ok"
  if StatusCode.fromNat 1 != .cancelled then return .failed "1 should be cancelled"
  if StatusCode.fromNat 2 != .unknown then return .failed "2 should be unknown"
  if StatusCode.fromNat 3 != .invalidArgument then return .failed "3 should be invalidArgument"
  if StatusCode.fromNat 4 != .deadlineExceeded then return .failed "4 should be deadlineExceeded"
  if StatusCode.fromNat 5 != .notFound then return .failed "5 should be notFound"
  if StatusCode.fromNat 6 != .alreadyExists then return .failed "6 should be alreadyExists"
  if StatusCode.fromNat 7 != .permissionDenied then return .failed "7 should be permissionDenied"
  if StatusCode.fromNat 8 != .resourceExhausted then return .failed "8 should be resourceExhausted"
  if StatusCode.fromNat 9 != .failedPrecondition then return .failed "9 should be failedPrecondition"
  if StatusCode.fromNat 10 != .aborted then return .failed "10 should be aborted"
  if StatusCode.fromNat 11 != .outOfRange then return .failed "11 should be outOfRange"
  if StatusCode.fromNat 12 != .unimplemented then return .failed "12 should be unimplemented"
  if StatusCode.fromNat 13 != .internal then return .failed "13 should be internal"
  if StatusCode.fromNat 14 != .unavailable then return .failed "14 should be unavailable"
  if StatusCode.fromNat 15 != .dataLoss then return .failed "15 should be dataLoss"
  if StatusCode.fromNat 16 != .unauthenticated then return .failed "16 should be unauthenticated"
  return .passed

def testStatusCodeToNat : TestCase := test "StatusCode.toNat" do
  if StatusCode.ok.toNat != 0 then return .failed "ok should be 0"
  if StatusCode.cancelled.toNat != 1 then return .failed "cancelled should be 1"
  if StatusCode.unknown.toNat != 2 then return .failed "unknown should be 2"
  if StatusCode.invalidArgument.toNat != 3 then return .failed "invalidArgument should be 3"
  if StatusCode.internal.toNat != 13 then return .failed "internal should be 13"
  if StatusCode.unauthenticated.toNat != 16 then return .failed "unauthenticated should be 16"
  return .passed

def testStatusCodeRoundTrip : TestCase := test "StatusCode round-trip" do
  -- All status codes should round-trip through toNat/fromNat
  let codes := #[
    StatusCode.ok, .cancelled, .unknown, .invalidArgument, .deadlineExceeded,
    .notFound, .alreadyExists, .permissionDenied, .resourceExhausted,
    .failedPrecondition, .aborted, .outOfRange, .unimplemented, .internal,
    .unavailable, .dataLoss, .unauthenticated
  ]
  for code in codes do
    if StatusCode.fromNat code.toNat != code then
      return .failed s!"Round-trip failed for {code}"
  return .passed

def testStatusCodeUnknownMapping : TestCase := test "StatusCode unknown values map to unknown" do
  -- Out of range values should map to unknown
  if StatusCode.fromNat 100 != .unknown then return .failed "100 should map to unknown"
  if StatusCode.fromNat 999 != .unknown then return .failed "999 should map to unknown"
  return .passed

def testStatusCodeDescription : TestCase := test "StatusCode.description" do
  if StatusCode.ok.description != "OK" then return .failed "ok description"
  if StatusCode.cancelled.description != "Cancelled" then return .failed "cancelled description"
  if StatusCode.notFound.description != "Not Found" then return .failed "notFound description"
  if StatusCode.internal.description != "Internal" then return .failed "internal description"
  return .passed

def testStatusCodeToString : TestCase := test "StatusCode ToString" do
  if toString StatusCode.ok != "OK" then return .failed "ok toString"
  if toString StatusCode.unavailable != "Unavailable" then return .failed "unavailable toString"
  return .passed

-- GrpcError tests

def testGrpcErrorSimple : TestCase := test "GrpcError.simple" do
  let err := GrpcError.simple .notFound "Resource not found"
  if err.code != .notFound then return .failed "code mismatch"
  if err.message != "Resource not found" then return .failed "message mismatch"
  if err.details.isSome then return .failed "details should be none"
  return .passed

def testGrpcErrorIsOk : TestCase := test "GrpcError.isOk" do
  let okErr := GrpcError.simple .ok "OK"
  let notOkErr := GrpcError.simple .internal "Error"
  if !okErr.isOk then return .failed "ok error should return true"
  if notOkErr.isOk then return .failed "non-ok error should return false"
  return .passed

def testGrpcErrorToString : TestCase := test "GrpcError ToString" do
  let err := GrpcError.simple .unavailable "Server busy"
  let s := toString err
  if !s.containsSubstr "Unavailable" then return .failed "should contain status"
  if !s.containsSubstr "Server busy" then return .failed "should contain message"
  return .passed

def testGrpcErrorWithDetails : TestCase := test "GrpcError with details" do
  let details := "extra info".toUTF8
  let err : GrpcError := { code := .internal, message := "Error", details := some details }
  if err.details.isNone then return .failed "details should be some"
  match err.details with
  | some d => if d != details then return .failed "details mismatch"
  | none => return .failed "unreachable"
  return .passed

-- GrpcResult tests

def testGrpcResultOk : TestCase := test "GrpcResult ok" do
  let result : GrpcResult String := .ok "success"
  if !result.isOk then return .failed "should be ok"
  if result.getD "default" != "success" then return .failed "getD failed"
  return .passed

def testGrpcResultError : TestCase := test "GrpcResult error" do
  let err := GrpcError.simple .internal "Error"
  let result : GrpcResult String := .error err
  if result.isOk then return .failed "should be error"
  if result.getD "default" != "default" then return .failed "getD should return default"
  return .passed

def testGrpcResultMap : TestCase := test "GrpcResult.map" do
  let ok : GrpcResult Int := .ok 42
  let err : GrpcResult Int := .error (GrpcError.simple .internal "Error")

  let okMapped := ok.map (· * 2)
  let errMapped := err.map (· * 2)

  match okMapped with
  | .ok v => if v != 84 then return .failed "map on ok should transform value"
  | .error _ => return .failed "map on ok should stay ok"

  match errMapped with
  | .ok _ => return .failed "map on error should stay error"
  | .error _ => pure ()

  return .passed

def testGrpcResultBind : TestCase := test "GrpcResult.bind" do
  let ok : GrpcResult Int := .ok 42
  let err : GrpcResult Int := .error (GrpcError.simple .internal "Error")

  let double : Int → GrpcResult Int := fun x => .ok (x * 2)
  let fail : Int → GrpcResult Int := fun _ => .error (GrpcError.simple .cancelled "Cancelled")

  match ok.bind double with
  | .ok v => if v != 84 then return .failed "bind double on ok"
  | .error _ => return .failed "bind double should succeed"

  match ok.bind fail with
  | .ok _ => return .failed "bind fail should fail"
  | .error e => if e.code != .cancelled then return .failed "bind fail wrong error"

  match err.bind double with
  | .ok _ => return .failed "bind on error should stay error"
  | .error e => if e.code != .internal then return .failed "bind preserves error"

  return .passed

def testGrpcResultMonad : TestCase := test "GrpcResult monad syntax" do
  let computation : GrpcResult Int := do
    let a ← (pure 10 : GrpcResult Int)
    let b ← (pure 20 : GrpcResult Int)
    return a + b

  match computation with
  | .ok v => if v != 30 then return .failed "monad computation failed"
  | .error _ => return .failed "monad should succeed"

  return .passed

-- Test suite

def errorTestSuite : TestSuite := suite "Error Tests" #[
  testStatusCodeFromNat,
  testStatusCodeToNat,
  testStatusCodeRoundTrip,
  testStatusCodeUnknownMapping,
  testStatusCodeDescription,
  testStatusCodeToString,
  testGrpcErrorSimple,
  testGrpcErrorIsOk,
  testGrpcErrorToString,
  testGrpcErrorWithDetails,
  testGrpcResultOk,
  testGrpcResultError,
  testGrpcResultMap,
  testGrpcResultBind,
  testGrpcResultMonad
]

end Tests.ErrorTests
