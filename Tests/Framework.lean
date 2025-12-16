/-
  Simple test framework for Legate
-/

namespace Tests

/-- Check if a string contains a substring -/
def String.containsSubstr (s : String) (sub : String) : Bool :=
  (s.splitOn sub).length > 1

/-- A test result -/
inductive TestResult where
  | passed
  | failed (message : String)
  deriving Repr

/-- A single test case -/
structure TestCase where
  name : String
  run : IO TestResult

/-- A test suite containing multiple test cases -/
structure TestSuite where
  name : String
  tests : Array TestCase

/-- Run a single test and print the result -/
def runTest (test : TestCase) : IO Bool := do
  IO.print s!"  {test.name}... "
  try
    match ← test.run with
    | .passed =>
      IO.println "PASSED"
      return true
    | .failed msg =>
      IO.println s!"FAILED: {msg}"
      return false
  catch e =>
    IO.println s!"ERROR: {e}"
    return false

/-- Run a test suite and return (passed, failed) counts -/
def runSuite (suite : TestSuite) : IO (Nat × Nat) := do
  IO.println s!"\n{suite.name}"
  IO.println ("".pushn '-' suite.name.length)
  let mut passed := 0
  let mut failed := 0
  for test in suite.tests do
    if ← runTest test then
      passed := passed + 1
    else
      failed := failed + 1
  return (passed, failed)

/-- Run all test suites and print summary -/
def runAllSuites (suites : Array TestSuite) : IO UInt32 := do
  let mut totalPassed := 0
  let mut totalFailed := 0
  for suite in suites do
    let (p, f) ← runSuite suite
    totalPassed := totalPassed + p
    totalFailed := totalFailed + f
  IO.println ""
  IO.println "================================"
  IO.println s!"Total: {totalPassed + totalFailed} tests"
  IO.println s!"Passed: {totalPassed}"
  IO.println s!"Failed: {totalFailed}"
  IO.println "================================"
  return if totalFailed > 0 then 1 else 0

-- Test assertion helpers

/-- Assert that a condition is true -/
def assertTrue (cond : Bool) (msg : String := "Expected true") : IO TestResult :=
  if cond then return .passed else return .failed msg

/-- Assert that a condition is false -/
def assertFalse (cond : Bool) (msg : String := "Expected false") : IO TestResult :=
  if !cond then return .passed else return .failed msg

/-- Assert that two values are equal -/
def assertEqual [BEq α] [ToString α] (actual expected : α) : IO TestResult :=
  if actual == expected then
    return .passed
  else
    return .failed s!"Expected {expected}, got {actual}"

/-- Assert that two values are not equal -/
def assertNotEqual [BEq α] [ToString α] (actual notExpected : α) : IO TestResult :=
  if actual != notExpected then
    return .passed
  else
    return .failed s!"Expected value different from {notExpected}"

/-- Assert that an Option is some -/
def assertSome {α : Type} (opt : Option α) (msg : String := "Expected Some") : IO TestResult :=
  match opt with
  | some _ => return .passed
  | none => return .failed msg

/-- Assert that an Option is none -/
def assertNone {α : Type} (opt : Option α) (msg : String := "Expected None") : IO TestResult :=
  match opt with
  | none => return .passed
  | some _ => return .failed msg

/-- Assert that an Except is ok -/
def assertOk {ε α : Type} (result : Except ε α) (msg : String := "Expected Ok") : IO TestResult :=
  match result with
  | .ok _ => return .passed
  | .error _ => return .failed msg

/-- Assert that an Except is error -/
def assertError {ε α : Type} (result : Except ε α) (msg : String := "Expected Error") : IO TestResult :=
  match result with
  | .error _ => return .passed
  | .ok _ => return .failed msg

/-- Create a test case from a name and IO action returning TestResult -/
def test (name : String) (action : IO TestResult) : TestCase :=
  { name, run := action }

/-- Create a test suite from a name and array of test cases -/
def suite (name : String) (tests : Array TestCase) : TestSuite :=
  { name, tests }

end Tests
