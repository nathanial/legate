/-
  Tests for Legate.Status module
-/

import Legate.Status
import Tests.Framework

open Tests
open Legate

namespace Tests.StatusTests

def testStatusOk : TestCase := test "Status.ok" do
  let s := Status.ok
  if s.code != .ok then return .failed "code should be ok"
  if s.message != "" then return .failed "message should be empty"
  if !s.isOk then return .failed "isOk should return true"
  if s.isError then return .failed "isError should return false"
  return .passed

def testStatusMake : TestCase := test "Status.make" do
  let s := Status.make .notFound "Resource not found"
  if s.code != .notFound then return .failed "code mismatch"
  if s.message != "Resource not found" then return .failed "message mismatch"
  return .passed

def testStatusMakeNoMessage : TestCase := test "Status.make without message" do
  let s := Status.make .internal
  if s.code != .internal then return .failed "code mismatch"
  if s.message != "" then return .failed "message should be empty"
  return .passed

def testStatusIsOk : TestCase := test "Status.isOk" do
  let okStatus := Status.ok
  let errStatus := Status.make .unavailable "Server unavailable"
  if !okStatus.isOk then return .failed "ok status should be ok"
  if errStatus.isOk then return .failed "error status should not be ok"
  return .passed

def testStatusIsError : TestCase := test "Status.isError" do
  let okStatus := Status.ok
  let errStatus := Status.make .internal "Error"
  if okStatus.isError then return .failed "ok status should not be error"
  if !errStatus.isError then return .failed "error status should be error"
  return .passed

def testStatusToError : TestCase := test "Status.toError" do
  let okStatus := Status.ok
  let errStatus := Status.make .cancelled "Cancelled"

  match okStatus.toError with
  | some _ => return .failed "ok status should not convert to error"
  | none => pure ()

  match errStatus.toError with
  | some e =>
    if e.code != .cancelled then return .failed "error code mismatch"
    if e.message != "Cancelled" then return .failed "error message mismatch"
  | none => return .failed "error status should convert to error"

  return .passed

def testStatusToResult : TestCase := test "Status.toResult" do
  let okStatus := Status.ok
  let errStatus := Status.make .notFound "Not found"

  let okResult := okStatus.toResult "success"
  let errResult := errStatus.toResult "unused"

  match okResult with
  | .ok v => if v != "success" then return .failed "ok result value mismatch"
  | .error _ => return .failed "ok status should produce ok result"

  match errResult with
  | .ok _ => return .failed "error status should produce error result"
  | .error e =>
    if e.code != .notFound then return .failed "error result code mismatch"
    if e.message != "Not found" then return .failed "error result message mismatch"

  return .passed

def testStatusToString : TestCase := test "Status ToString" do
  let s1 := Status.ok
  let s2 := Status.make .internal "Something went wrong"

  let str1 := toString s1
  if !str1.containsSubstr "OK" then return .failed "ok toString should contain OK"

  let str2 := toString s2
  if !str2.containsSubstr "Internal" then return .failed "error toString should contain code"
  if !str2.containsSubstr "Something went wrong" then return .failed "error toString should contain message"

  return .passed

def testStatusEquality : TestCase := test "Status equality" do
  let s1 := Status.make .ok ""
  let s2 := Status.ok
  let s3 := Status.make .internal "Error"
  let s4 := Status.make .internal "Error"
  let s5 := Status.make .internal "Different"

  if s1 != s2 then return .failed "equivalent ok statuses should be equal"
  if s3 != s4 then return .failed "same error statuses should be equal"
  if s3 == s5 then return .failed "different messages should not be equal"

  return .passed

-- Test suite

def statusTestSuite : TestSuite := suite "Status Tests" #[
  testStatusOk,
  testStatusMake,
  testStatusMakeNoMessage,
  testStatusIsOk,
  testStatusIsError,
  testStatusToError,
  testStatusToResult,
  testStatusToString,
  testStatusEquality
]

end Tests.StatusTests
