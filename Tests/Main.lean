/-
  Legate Test Runner

  Run all tests with: lake test
-/

import Crucible
import Tests.ErrorTests
import Tests.MetadataTests
import Tests.StatusTests

open Crucible

def main : IO UInt32 := do
  IO.println "╔══════════════════════════════════════════════════════════════╗"
  IO.println "║                     Legate Test Suite                        ║"
  IO.println "╚══════════════════════════════════════════════════════════════╝"
  IO.println ""

  -- Error tests
  IO.println "━━━ Error Tests ━━━"
  let errorResult ← runTests "Error Tests" Tests.ErrorTests.cases
  IO.println ""

  -- Metadata tests
  IO.println "━━━ Metadata Tests ━━━"
  let metadataResult ← runTests "Metadata Tests" Tests.MetadataTests.cases
  IO.println ""

  -- Status tests
  IO.println "━━━ Status Tests ━━━"
  let statusResult ← runTests "Status Tests" Tests.StatusTests.cases
  IO.println ""

  IO.println "══════════════════════════════════════════════════════════════"

  let totalTests := Tests.ErrorTests.cases.length +
                    Tests.MetadataTests.cases.length +
                    Tests.StatusTests.cases.length
  let totalFailed := errorResult.toNat + metadataResult.toNat + statusResult.toNat

  if totalFailed == 0 then
    IO.println s!"All {totalTests} tests passed!"
    return 0
  else
    IO.println s!"{totalTests - totalFailed} passed, {totalFailed} failed"
    return 1
