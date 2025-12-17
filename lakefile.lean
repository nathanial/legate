import Lake
open Lake DSL System

package legate where
  precompileModules := true

require protolean from git "https://github.com/nathanial/protolean" @ "master"

-- FFI and gRPC link arguments
def ffiBuildDir := ".lake/build/ffi"
def abslDir := s!"{ffiBuildDir}/grpc/third_party/abseil-cpp/absl"
def abslLibs : Array String := #[
  s!"-L{abslDir}/base", "-labsl_base", "-labsl_raw_logging_internal", "-labsl_spinlock_wait",
  "-labsl_throw_delegate", "-labsl_log_severity", "-labsl_malloc_internal", "-labsl_strerror",
  s!"-L{abslDir}/strings", "-labsl_strings", "-labsl_strings_internal", "-labsl_string_view",
  "-labsl_str_format_internal",
  s!"-L{abslDir}/numeric", "-labsl_int128",
  s!"-L{abslDir}/hash", "-labsl_hash", "-labsl_city", "-labsl_low_level_hash",
  s!"-L{abslDir}/time", "-labsl_time", "-labsl_time_zone", "-labsl_civil_time",
  s!"-L{abslDir}/status", "-labsl_status", "-labsl_statusor",
  s!"-L{abslDir}/synchronization", "-labsl_synchronization", "-labsl_graphcycles_internal",
  "-labsl_kernel_timeout_internal",
  s!"-L{abslDir}/debugging", "-labsl_stacktrace", "-labsl_symbolize", "-labsl_debugging_internal",
  "-labsl_demangle_internal", "-labsl_demangle_rust", "-labsl_decode_rust_punycode",
  "-labsl_examine_stack", "-labsl_utf8_for_code_point", "-labsl_leak_check",
  s!"-L{abslDir}/log", "-labsl_log_internal_message", "-labsl_log_internal_log_sink_set",
  "-labsl_log_internal_globals", "-labsl_log_internal_format", "-labsl_log_internal_conditions",
  "-labsl_log_internal_check_op", "-labsl_log_internal_nullguard", "-labsl_log_internal_fnmatch",
  "-labsl_log_internal_proto", "-labsl_log_entry", "-labsl_log_globals", "-labsl_log_sink",
  "-labsl_log_initialize", "-labsl_die_if_null", "-labsl_vlog_config_internal",
  s!"-L{abslDir}/container", "-labsl_raw_hash_set", "-labsl_hashtablez_sampler",
  s!"-L{abslDir}/cord", "-labsl_cord", "-labsl_cord_internal", "-labsl_cordz_functions",
  "-labsl_cordz_handle", "-labsl_cordz_info",
  s!"-L{abslDir}/crc", "-labsl_crc32c", "-labsl_crc_internal", "-labsl_crc_cpu_detect",
  "-labsl_crc_cord_state",
  s!"-L{abslDir}/flags", "-labsl_flags_reflection", "-labsl_flags_internal",
  "-labsl_flags_commandlineflag", "-labsl_flags_commandlineflag_internal", "-labsl_flags_config",
  "-labsl_flags_marshalling", "-labsl_flags_program_name", "-labsl_flags_private_handle_accessor",
  s!"-L{abslDir}/random", "-labsl_random_seed_sequences", "-labsl_random_internal_pool_urbg",
  "-labsl_random_distributions", "-labsl_random_internal_seed_material",
  "-labsl_random_internal_randen", "-labsl_random_internal_randen_hwaes",
  "-labsl_random_internal_randen_hwaes_impl", "-labsl_random_internal_randen_slow",
  "-labsl_random_internal_platform", "-labsl_random_seed_gen_exception",
  s!"-L{abslDir}/profiling", "-labsl_exponential_biased",
  s!"-L{abslDir}/types", "-labsl_bad_optional_access", "-labsl_bad_variant_access"
]

def ffiLinkArgs : Array String := #[
  s!"-L{ffiBuildDir}", "-llegate_ffi",
  s!"-L{ffiBuildDir}/grpc", "-lgrpc++", "-lgrpc", "-lgpr", "-laddress_sorting",
  "-lupb_json_lib", "-lupb_textformat_lib", "-lupb_message_lib", "-lupb_base_lib",
  "-lupb_mem_lib", "-lupb_mini_descriptor_lib", "-lupb_wire_lib", "-lutf8_range_lib",
  s!"-L{ffiBuildDir}/grpc/third_party/boringssl-with-bazel", "-lssl", "-lcrypto",
  s!"-L{ffiBuildDir}/grpc/third_party/protobuf", "-lprotobuf",
  s!"-L{ffiBuildDir}/grpc/third_party/re2", "-lre2",
  s!"-L{ffiBuildDir}/grpc/third_party/cares/cares/lib", "-lcares",
  "-L/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib", "-lz",
  "-F/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks",
  "-Wl,-framework,CoreFoundation", "-Wl,-framework,SystemConfiguration"
] ++ abslLibs

@[default_target]
lean_lib Legate where
  roots := #[`Legate]
  moreLinkArgs := ffiLinkArgs

-- Tests library - modules that contain the actual tests
lean_lib Tests where
  srcDir := "."
  roots := #[`Tests.Framework, `Tests.ErrorTests, `Tests.MetadataTests, `Tests.StatusTests]
  moreLinkArgs := #["-L.lake/build/lib", "-lLegate"] ++ ffiLinkArgs

-- Test executable (build tests and run with `lake test`)
@[test_driver]
lean_exe tests where
  root := `Tests.Main
  srcDir := "."
  moreLinkArgs := #["-L.lake/build/lib", "-lLegate", "-lTests"] ++ ffiLinkArgs

-- Integration tests library - protobuf-based tests against Go server
lean_lib IntegrationTests where
  srcDir := "."
  roots := #[`Tests.integration.Proto, `Tests.integration.Client, `Tests.integration.Server, `Tests.integration.TlsTests]
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
      "-DLEGATE_USE_SYSTEM_GRPC=OFF",
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
