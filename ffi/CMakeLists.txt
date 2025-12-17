cmake_minimum_required(VERSION 3.16)
project(legate_ffi CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Option to use system gRPC or build from submodule
option(LEGATE_USE_SYSTEM_GRPC "Use system-installed gRPC instead of submodule" OFF)

if(LEGATE_USE_SYSTEM_GRPC)
    find_package(gRPC CONFIG REQUIRED)
    # gRPC brings in protobuf transitively, no need to find it separately
    set(GRPC_LIBRARIES gRPC::grpc++ gRPC::grpc)
    set(PROTOBUF_LIBRARIES "")
else()
    # Build gRPC from submodule
    set(GRPC_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/grpc")

    # gRPC build options - disable unnecessary components
    set(gRPC_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_CSHARP_EXT OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_CPP_PLUGIN ON CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_PYTHON_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_RUBY_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_PHP_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_CSHARP_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_NODE_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_OBJECTIVE_C_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_CODEGEN OFF CACHE BOOL "" FORCE)

    # Use bundled dependencies except for zlib which has conflicts on macOS
    set(gRPC_ABSL_PROVIDER "module" CACHE STRING "" FORCE)
    set(gRPC_CARES_PROVIDER "module" CACHE STRING "" FORCE)
    set(gRPC_PROTOBUF_PROVIDER "module" CACHE STRING "" FORCE)
    set(gRPC_RE2_PROVIDER "module" CACHE STRING "" FORCE)
    set(gRPC_SSL_PROVIDER "module" CACHE STRING "" FORCE)
    set(gRPC_ZLIB_PROVIDER "package" CACHE STRING "" FORCE)

    # Add gRPC subdirectory
    add_subdirectory(${GRPC_SOURCE_DIR} ${CMAKE_BINARY_DIR}/grpc EXCLUDE_FROM_ALL)

    set(GRPC_LIBRARIES grpc++ grpc gpr)
    set(PROTOBUF_LIBRARIES libprotobuf)
endif()

# Lean include directory (passed from lakefile)
if(NOT DEFINED LEAN_INCLUDE_DIR)
    message(FATAL_ERROR "LEAN_INCLUDE_DIR must be set to the Lean installation include directory")
endif()

# FFI library sources
set(FFI_SOURCES
    src/legate_ffi.cpp
)

add_library(legate_ffi STATIC ${FFI_SOURCES})

target_include_directories(legate_ffi
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${LEAN_INCLUDE_DIR}
)

target_link_libraries(legate_ffi
    PUBLIC
        ${GRPC_LIBRARIES}
        ${PROTOBUF_LIBRARIES}
)

# Ensure we're building with the right flags for Lean FFI
target_compile_definitions(legate_ffi PRIVATE
    LEAN_MULTI_THREAD
)

# On macOS, we may need additional frameworks
if(APPLE)
    find_library(COREFOUNDATION_LIBRARY CoreFoundation)
    if(COREFOUNDATION_LIBRARY)
        target_link_libraries(legate_ffi PUBLIC ${COREFOUNDATION_LIBRARY})
    endif()
endif()

# Install target
install(TARGETS legate_ffi
    ARCHIVE DESTINATION lib
    LIBRARY DESTINATION lib
)

install(DIRECTORY include/
    DESTINATION include
    FILES_MATCHING PATTERN "*.h"
)
