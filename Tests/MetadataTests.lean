/-
  Tests for Legate.Metadata module
-/

import Crucible
import Legate.Metadata

open Crucible
open Legate

namespace Tests.MetadataTests

/-- Check if a string contains a substring -/
def String.containsSubstr (s : String) (sub : String) : Bool :=
  (s.splitOn sub).length > 1

testSuite "Metadata Tests"

-- Metadata tests

test "Metadata empty" := do
  let m := Metadata.empty
  ensure (m.size == 0) "empty should have size 0"

test "Metadata ofList" := do
  let m := Metadata.ofList [("key1", "value1"), ("key2", "value2")]
  ensure (m.size == 2) "should have 2 entries"

test "Metadata add" := do
  let m := Metadata.empty.add "key" "value"
  ensure (m.size == 1) "should have 1 entry"
  match m.get? "key" with
  | some v => ensure (v == "value") "value mismatch"
  | none => ensure false "key should exist"

test "Metadata get" := do
  let m := Metadata.ofList [("key1", "value1"), ("key2", "value2")]
  match m.get? "key1" with
  | some v => ensure (v == "value1") "key1 value mismatch"
  | none => ensure false "key1 should exist"
  match m.get? "key2" with
  | some v => ensure (v == "value2") "key2 value mismatch"
  | none => ensure false "key2 should exist"
  match m.get? "nonexistent" with
  | some _ => ensure false "nonexistent key should return none"
  | none => pure ()

test "Metadata getAll" := do
  let m := Metadata.ofList [("key", "value1"), ("other", "x"), ("key", "value2")]
  let values := m.getAll "key"
  ensure (values.size == 2) s!"should have 2 values for key, got {values.size}"
  ensure (values[0]! == "value1") "first value mismatch"
  ensure (values[1]! == "value2") "second value mismatch"

test "Metadata contains" := do
  let m := Metadata.ofList [("key1", "value1")]
  ensure (m.contains "key1") "should contain key1"
  ensure (!m.contains "key2") "should not contain key2"

test "Metadata remove" := do
  let m := Metadata.ofList [("key1", "value1"), ("key2", "value2"), ("key1", "value3")]
  let m' := m.remove "key1"
  ensure (!m'.contains "key1") "key1 should be removed"
  ensure (m'.contains "key2") "key2 should remain"
  ensure (m'.size == 1) "should have 1 entry after remove"

test "Metadata merge" := do
  let m1 := Metadata.ofList [("a", "1")]
  let m2 := Metadata.ofList [("b", "2")]
  let merged := m1.merge m2
  ensure (merged.contains "a") "should contain a"
  ensure (merged.contains "b") "should contain b"
  ensure (merged.size == 2) "should have 2 entries"

test "Metadata append operator" := do
  let m1 := Metadata.ofList [("a", "1")]
  let m2 := Metadata.ofList [("b", "2")]
  let merged := m1 ++ m2
  ensure (merged.size == 2) "append should work"

test "Metadata toListPairs" := do
  let m := Metadata.ofList [("a", "1"), ("b", "2")]
  let pairs := m.toListPairs
  ensure (pairs.length == 2) "should have 2 pairs"

test "Metadata ToString" := do
  let m := Metadata.ofList [("key", "value")]
  let s := toString m
  ensure (String.containsSubstr s "key") "should contain key"
  ensure (String.containsSubstr s "value") "should contain value"

-- CallOptions tests

test "CallOptions default" := do
  let opts := CallOptions.default
  ensure (opts.timeoutMs == 0) "default timeout should be 0"
  ensure (opts.metadata.size == 0) "default metadata should be empty"
  ensure (!opts.waitForReady) "default waitForReady should be false"

test "CallOptions withTimeout" := do
  let opts := CallOptions.default.withTimeout 5000
  ensure (opts.timeoutMs == 5000) "timeout should be 5000"

test "CallOptions withTimeoutSeconds" := do
  let opts := CallOptions.default.withTimeoutSeconds 5
  ensure (opts.timeoutMs == 5000) "timeout should be 5000 (5 seconds)"

test "CallOptions withMetadata" := do
  let md := Metadata.ofList [("auth", "token")]
  let opts := CallOptions.default.withMetadata md
  ensure (opts.metadata.size == 1) "should have metadata"

test "CallOptions addMetadata" := do
  let opts := CallOptions.default
    |>.addMetadata "key1" "value1"
    |>.addMetadata "key2" "value2"
  ensure (opts.metadata.size == 2) "should have 2 metadata entries"

test "CallOptions withWaitForReady" := do
  let opts := CallOptions.default.withWaitForReady
  ensure opts.waitForReady "waitForReady should be true"
  let opts2 := opts.withWaitForReady false
  ensure (!opts2.waitForReady) "waitForReady should be false"

test "CallOptions chaining" := do
  let opts := CallOptions.default
    |>.withTimeout 10000
    |>.addMetadata "authorization" "Bearer token"
    |>.withWaitForReady
  ensure (opts.timeoutMs == 10000) "timeout"
  ensure opts.waitForReady "waitForReady"
  ensure (opts.metadata.size == 1) "metadata"

#generate_tests

end Tests.MetadataTests
