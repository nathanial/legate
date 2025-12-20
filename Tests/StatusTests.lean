/-
  Tests for Legate.Status module
-/

import Crucible
import Legate.Status

open Crucible
open Legate

namespace Tests.StatusTests

/-- Check if a string contains a substring -/
def String.containsSubstr (s : String) (sub : String) : Bool :=
  (s.splitOn sub).length > 1

testSuite "Status Tests"

test "Status ok" := do
  let s := Status.ok
  ensure (s.code == .ok) "code should be ok"
  ensure (s.message == "") "message should be empty"
  ensure s.isOk "isOk should return true"
  ensure (!s.isError) "isError should return false"

test "Status make" := do
  let s := Status.make .notFound "Resource not found"
  ensure (s.code == .notFound) "code mismatch"
  ensure (s.message == "Resource not found") "message mismatch"

test "Status make without message" := do
  let s := Status.make .internal
  ensure (s.code == .internal) "code mismatch"
  ensure (s.message == "") "message should be empty"

test "Status isOk" := do
  let okStatus := Status.ok
  let errStatus := Status.make .unavailable "Server unavailable"
  ensure okStatus.isOk "ok status should be ok"
  ensure (!errStatus.isOk) "error status should not be ok"

test "Status isError" := do
  let okStatus := Status.ok
  let errStatus := Status.make .internal "Error"
  ensure (!okStatus.isError) "ok status should not be error"
  ensure errStatus.isError "error status should be error"

test "Status toError" := do
  let okStatus := Status.ok
  let errStatus := Status.make .cancelled "Cancelled"

  match okStatus.toError with
  | some _ => ensure false "ok status should not convert to error"
  | none => pure ()

  match errStatus.toError with
  | some e =>
    ensure (e.code == .cancelled) "error code mismatch"
    ensure (e.message == "Cancelled") "error message mismatch"
  | none => ensure false "error status should convert to error"

test "Status toResult" := do
  let okStatus := Status.ok
  let errStatus := Status.make .notFound "Not found"

  let okResult := okStatus.toResult "success"
  let errResult := errStatus.toResult "unused"

  match okResult with
  | .ok v => ensure (v == "success") "ok result value mismatch"
  | .error _ => ensure false "ok status should produce ok result"

  match errResult with
  | .ok _ => ensure false "error status should produce error result"
  | .error e =>
    ensure (e.code == .notFound) "error result code mismatch"
    ensure (e.message == "Not found") "error result message mismatch"

test "Status ToString" := do
  let s1 := Status.ok
  let s2 := Status.make .internal "Something went wrong"

  let str1 := toString s1
  ensure (String.containsSubstr str1 "OK") "ok toString should contain OK"

  let str2 := toString s2
  ensure (String.containsSubstr str2 "Internal") "error toString should contain code"
  ensure (String.containsSubstr str2 "Something went wrong") "error toString should contain message"

test "Status equality" := do
  let s1 := Status.make .ok ""
  let s2 := Status.ok
  let s3 := Status.make .internal "Error"
  let s4 := Status.make .internal "Error"
  let s5 := Status.make .internal "Different"

  ensure (s1 == s2) "equivalent ok statuses should be equal"
  ensure (s3 == s4) "same error statuses should be equal"
  ensure (s3 != s5) "different messages should not be equal"

#generate_tests

end Tests.StatusTests
