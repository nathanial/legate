/-
  Tests for Legate.Metadata module
-/

import Legate.Metadata
import Tests.Framework

open Tests
open Legate

namespace Tests.MetadataTests

-- Metadata tests

def testMetadataEmpty : TestCase := test "Metadata.empty" do
  let m := Metadata.empty
  if m.size != 0 then return .failed "empty should have size 0"
  return .passed

def testMetadataOfList : TestCase := test "Metadata.ofList" do
  let m := Metadata.ofList [("key1", "value1"), ("key2", "value2")]
  if m.size != 2 then return .failed "should have 2 entries"
  return .passed

def testMetadataAdd : TestCase := test "Metadata.add" do
  let m := Metadata.empty.add "key" "value"
  if m.size != 1 then return .failed "should have 1 entry"
  match m.get? "key" with
  | some v => if v != "value" then return .failed "value mismatch"
  | none => return .failed "key should exist"
  return .passed

def testMetadataGet : TestCase := test "Metadata.get?" do
  let m := Metadata.ofList [("key1", "value1"), ("key2", "value2")]
  match m.get? "key1" with
  | some v => if v != "value1" then return .failed "key1 value mismatch"
  | none => return .failed "key1 should exist"
  match m.get? "key2" with
  | some v => if v != "value2" then return .failed "key2 value mismatch"
  | none => return .failed "key2 should exist"
  match m.get? "nonexistent" with
  | some _ => return .failed "nonexistent key should return none"
  | none => pure ()
  return .passed

def testMetadataGetAll : TestCase := test "Metadata.getAll" do
  let m := Metadata.ofList [("key", "value1"), ("other", "x"), ("key", "value2")]
  let values := m.getAll "key"
  if values.size != 2 then return .failed s!"should have 2 values for key, got {values.size}"
  if values[0]! != "value1" then return .failed "first value mismatch"
  if values[1]! != "value2" then return .failed "second value mismatch"
  return .passed

def testMetadataContains : TestCase := test "Metadata.contains" do
  let m := Metadata.ofList [("key1", "value1")]
  if !m.contains "key1" then return .failed "should contain key1"
  if m.contains "key2" then return .failed "should not contain key2"
  return .passed

def testMetadataRemove : TestCase := test "Metadata.remove" do
  let m := Metadata.ofList [("key1", "value1"), ("key2", "value2"), ("key1", "value3")]
  let m' := m.remove "key1"
  if m'.contains "key1" then return .failed "key1 should be removed"
  if !m'.contains "key2" then return .failed "key2 should remain"
  if m'.size != 1 then return .failed "should have 1 entry after remove"
  return .passed

def testMetadataMerge : TestCase := test "Metadata.merge" do
  let m1 := Metadata.ofList [("a", "1")]
  let m2 := Metadata.ofList [("b", "2")]
  let merged := m1.merge m2
  if !merged.contains "a" then return .failed "should contain a"
  if !merged.contains "b" then return .failed "should contain b"
  if merged.size != 2 then return .failed "should have 2 entries"
  return .passed

def testMetadataAppend : TestCase := test "Metadata append operator" do
  let m1 := Metadata.ofList [("a", "1")]
  let m2 := Metadata.ofList [("b", "2")]
  let merged := m1 ++ m2
  if merged.size != 2 then return .failed "append should work"
  return .passed

def testMetadataToListPairs : TestCase := test "Metadata.toListPairs" do
  let m := Metadata.ofList [("a", "1"), ("b", "2")]
  let pairs := m.toListPairs
  if pairs.length != 2 then return .failed "should have 2 pairs"
  return .passed

def testMetadataToString : TestCase := test "Metadata ToString" do
  let m := Metadata.ofList [("key", "value")]
  let s := toString m
  if !s.containsSubstr "key" then return .failed "should contain key"
  if !s.containsSubstr "value" then return .failed "should contain value"
  return .passed

-- CallOptions tests

def testCallOptionsDefault : TestCase := test "CallOptions.default" do
  let opts := CallOptions.default
  if opts.timeoutMs != 0 then return .failed "default timeout should be 0"
  if opts.metadata.size != 0 then return .failed "default metadata should be empty"
  if opts.waitForReady then return .failed "default waitForReady should be false"
  return .passed

def testCallOptionsWithTimeout : TestCase := test "CallOptions.withTimeout" do
  let opts := CallOptions.default.withTimeout 5000
  if opts.timeoutMs != 5000 then return .failed "timeout should be 5000"
  return .passed

def testCallOptionsWithTimeoutSeconds : TestCase := test "CallOptions.withTimeoutSeconds" do
  let opts := CallOptions.default.withTimeoutSeconds 5
  if opts.timeoutMs != 5000 then return .failed "timeout should be 5000 (5 seconds)"
  return .passed

def testCallOptionsWithMetadata : TestCase := test "CallOptions.withMetadata" do
  let md := Metadata.ofList [("auth", "token")]
  let opts := CallOptions.default.withMetadata md
  if opts.metadata.size != 1 then return .failed "should have metadata"
  return .passed

def testCallOptionsAddMetadata : TestCase := test "CallOptions.addMetadata" do
  let opts := CallOptions.default
    |>.addMetadata "key1" "value1"
    |>.addMetadata "key2" "value2"
  if opts.metadata.size != 2 then return .failed "should have 2 metadata entries"
  return .passed

def testCallOptionsWithWaitForReady : TestCase := test "CallOptions.withWaitForReady" do
  let opts := CallOptions.default.withWaitForReady
  if !opts.waitForReady then return .failed "waitForReady should be true"
  let opts2 := opts.withWaitForReady false
  if opts2.waitForReady then return .failed "waitForReady should be false"
  return .passed

def testCallOptionsChaining : TestCase := test "CallOptions chaining" do
  let opts := CallOptions.default
    |>.withTimeout 10000
    |>.addMetadata "authorization" "Bearer token"
    |>.withWaitForReady
  if opts.timeoutMs != 10000 then return .failed "timeout"
  if !opts.waitForReady then return .failed "waitForReady"
  if opts.metadata.size != 1 then return .failed "metadata"
  return .passed

-- Test suite

def metadataTestSuite : TestSuite := suite "Metadata Tests" #[
  testMetadataEmpty,
  testMetadataOfList,
  testMetadataAdd,
  testMetadataGet,
  testMetadataGetAll,
  testMetadataContains,
  testMetadataRemove,
  testMetadataMerge,
  testMetadataAppend,
  testMetadataToListPairs,
  testMetadataToString,
  testCallOptionsDefault,
  testCallOptionsWithTimeout,
  testCallOptionsWithTimeoutSeconds,
  testCallOptionsWithMetadata,
  testCallOptionsAddMetadata,
  testCallOptionsWithWaitForReady,
  testCallOptionsChaining
]

end Tests.MetadataTests
