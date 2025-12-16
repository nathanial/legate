import Lake
open Lake DSL System

package legate where
  precompileModules := true

@[default_target]
lean_lib Legate where
  roots := #[`Legate]

/-- Build script that invokes CMake to build the FFI library -/
script buildFfi do
  -- Get Lean sysroot
  let leanOut ← IO.Process.output {
    cmd := "lean"
    args := #["--print-prefix"]
  }
  if leanOut.exitCode != 0 then
    IO.eprintln "Failed to get Lean sysroot"
    return 1

  let leanIncDir := leanOut.stdout.trim ++ "/include"
  let srcDir := "ffi"
  let buildDir := ".lake/build/ffi"

  -- Create build directory
  IO.FS.createDirAll buildDir

  -- Run CMake configure
  IO.println s!"Configuring CMake in {buildDir}..."
  let configureOut ← IO.Process.output {
    cmd := "cmake"
    args := #[
      "-S", srcDir,
      "-B", buildDir,
      s!"-DLEAN_INCLUDE_DIR={leanIncDir}",
      "-DCMAKE_BUILD_TYPE=Release",
      "-DLEGATE_USE_SYSTEM_GRPC=OFF"
    ]
  }
  if configureOut.exitCode != 0 then
    IO.eprintln "CMake configure failed:"
    IO.eprintln configureOut.stderr
    return 1

  -- Run CMake build
  IO.println "Building FFI library..."
  let buildOut ← IO.Process.output {
    cmd := "cmake"
    args := #["--build", buildDir, "--parallel", "--target", "legate_ffi"]
  }
  if buildOut.exitCode != 0 then
    IO.eprintln "CMake build failed:"
    IO.eprintln buildOut.stderr
    return 1

  IO.println "FFI library built successfully!"
  return 0
