/-
  Legate Test Runner

  Run all tests with: lake test
-/

import Tests.Framework
import Tests.ErrorTests
import Tests.MetadataTests
import Tests.StatusTests

open Tests

def main : IO UInt32 := do
  IO.println "Legate Test Suite"
  IO.println "================="
  runAllSuites #[
    ErrorTests.errorTestSuite,
    MetadataTests.metadataTestSuite,
    StatusTests.statusTestSuite
  ]
