import Lake
open Lake DSL System

package legate where
  version := v!"0.1.0"

require protolean from git "https://github.com/nathanial/protolean" @ "v0.0.1"
require crucible from git "https://github.com/nathanial/crucible" @ "v0.0.8"

-- FFI and gRPC link arguments using system gRPC from Homebrew
def ffiBuildDir := ".lake/build/ffi"

-- System gRPC paths (Homebrew)
def grpcPrefix := "/opt/homebrew/opt/grpc"
def abslPrefix := "/opt/homebrew/opt/abseil"

-- Abseil libraries required by gRPC (from pkg-config --libs grpc++)
def abslLibs : Array String := #[
  s!"-L{abslPrefix}/lib",
  "-labsl_statusor", "-labsl_status",
  "-labsl_log_internal_check_op", "-labsl_leak_check",
  "-labsl_log_internal_conditions", "-labsl_log_internal_message",
  "-labsl_examine_stack", "-labsl_log_internal_format",
  "-labsl_log_internal_nullguard", "-labsl_log_internal_structured_proto",
  "-labsl_log_internal_log_sink_set", "-labsl_log_internal_globals",
  "-labsl_log_globals", "-labsl_log_sink", "-labsl_log_entry",
  "-labsl_log_internal_proto", "-labsl_strerror", "-labsl_vlog_config_internal",
  "-labsl_log_internal_fnmatch", "-labsl_flags_internal", "-labsl_flags_marshalling",
  "-labsl_flags_reflection", "-labsl_flags_private_handle_accessor",
  "-labsl_flags_commandlineflag", "-labsl_flags_commandlineflag_internal",
  "-labsl_flags_config", "-labsl_flags_program_name",
  "-labsl_raw_hash_set", "-labsl_cord", "-labsl_cordz_info",
  "-labsl_cord_internal", "-labsl_cordz_functions", "-labsl_cordz_handle",
  "-labsl_crc_cord_state", "-labsl_crc32c", "-labsl_crc_internal", "-labsl_crc_cpu_detect",
  "-labsl_hashtablez_sampler", "-labsl_exponential_biased",
  "-labsl_hash", "-labsl_city", "-labsl_str_format_internal",
  "-labsl_synchronization", "-labsl_graphcycles_internal", "-labsl_kernel_timeout_internal",
  "-labsl_stacktrace", "-labsl_symbolize", "-labsl_debugging_internal",
  "-labsl_demangle_internal", "-labsl_demangle_rust", "-labsl_decode_rust_punycode",
  "-labsl_utf8_for_code_point", "-labsl_malloc_internal",
  "-labsl_time", "-labsl_civil_time", "-labsl_strings", "-labsl_strings_internal",
  "-labsl_string_view", "-labsl_int128", "-labsl_throw_delegate", "-labsl_time_zone",
  "-labsl_tracing_internal", "-labsl_base", "-labsl_raw_logging_internal",
  "-labsl_log_severity", "-labsl_spinlock_wait",
  "-labsl_random_distributions", "-labsl_random_seed_sequences",
  "-labsl_random_internal_entropy_pool", "-labsl_random_internal_randen",
  "-labsl_random_internal_randen_hwaes", "-labsl_random_internal_randen_hwaes_impl",
  "-labsl_random_internal_randen_slow", "-labsl_random_internal_platform",
  "-labsl_random_internal_seed_material", "-labsl_random_seed_gen_exception"
]

def ffiLinkArgs : Array String := #[
  s!"-L{ffiBuildDir}", "-llegate_ffi",
  s!"-L{grpcPrefix}/lib", "-lgrpc++", "-lgrpc", "-lgpr"
] ++ abslLibs

@[default_target]
lean_lib Legate where
  roots := #[`Legate]
  precompileModules := true
  moreLinkArgs := ffiLinkArgs

-- Unit tests library - let Lake handle Lean dependencies (Crucible, Legate)
-- No moreLinkArgs since tests don't call FFI directly
lean_lib Tests where
  roots := #[`Tests.ErrorTests, `Tests.MetadataTests, `Tests.StatusTests]

-- Test executable - only needs FFI for final linking
@[test_driver]
lean_exe tests where
  root := `Tests.Main
  moreLinkArgs := ffiLinkArgs

-- Integration tests library - protobuf-based tests against Go server
lean_lib IntegrationTests where
  srcDir := "."
  roots := #[
    `Tests.integration.Proto,
    `Tests.integration.Client,
    `Tests.integration.Server,
    `Tests.integration.TlsTests,
    `Tests.integration.WaitForReadyTests
  ]
  moreLinkArgs := #["-L.lake/build/lib", "-lLegate", "-L.lake/packages/protolean/.lake/build/lib", "-lProtolean"] ++ ffiLinkArgs

-- Integration test executable
lean_exe integrationTests where
  root := `Tests.integration.Main
  srcDir := "."
  moreLinkArgs := #["-L.lake/build/lib", "-lLegate", "-lIntegrationTests", "-L.lake/packages/protolean/.lake/build/lib", "-lProtolean"] ++ ffiLinkArgs

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
      "-DLEGATE_USE_SYSTEM_GRPC=ON",
      "-DCMAKE_PREFIX_PATH=/opt/homebrew",
      "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
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
