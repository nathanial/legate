#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ------------------------------------------------------------------------------
# Build native FFI (CMake) and force relink
# ------------------------------------------------------------------------------
# Lake doesn't always notice changes in the native (CMake-built) archive when
# deciding whether to relink Lean dylibs/executables, so do it explicitly here.
if [ -d "$SCRIPT_DIR/.lake/build/ffi" ]; then
echo -e "${YELLOW}[0/6] Building native FFI...${NC}"
    echo "----------------------------------------"
    cmake --build "$SCRIPT_DIR/.lake/build/ffi" --parallel --target legate_ffi
    # Force relink of Lean shared libs/exes that embed the native archive
    rm -f "$SCRIPT_DIR/.lake/build/lib/libLegate."* 2>/dev/null || true
    rm -f "$SCRIPT_DIR/.lake/build/lib/libIntegrationTests."* 2>/dev/null || true
    rm -f "$SCRIPT_DIR/.lake/build/bin/integrationTests" 2>/dev/null || true
    echo
fi

# On macOS, Lake/Lean-built dylibs may depend on libLake_shared.dylib via @rpath.
# Ensure the Lean toolchain lib directory is discoverable when running test executables.
if [[ "$(uname -s)" == "Darwin" ]]; then
    LEAN_PREFIX="$(lean --print-prefix 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "$LEAN_PREFIX" ]]; then
        export DYLD_LIBRARY_PATH="$LEAN_PREFIX/lib/lean${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    fi
fi

echo "========================================"
echo "Legate Test Suite"
echo "========================================"
echo

# Track overall result
FAILED=0

# ------------------------------------------------------------------------------
# Unit Tests (Lean)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[1/6] Running Lean unit tests...${NC}"
echo "----------------------------------------"

if lake test; then
    echo -e "${GREEN}Lean unit tests passed${NC}"
else
    echo -e "${RED}Lean unit tests failed${NC}"
    FAILED=1
fi

echo

# ------------------------------------------------------------------------------
# Integration Tests (Go client -> Go server)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[2/6] Running Go gRPC integration tests...${NC}"
echo "----------------------------------------"

GO_TEST_DIR="$SCRIPT_DIR/Tests/integration/go"

if [ ! -d "$GO_TEST_DIR" ]; then
    echo -e "${RED}Go integration test directory not found: $GO_TEST_DIR${NC}"
    FAILED=1
else
    cd "$GO_TEST_DIR"

    # Build if needed
    if [ ! -f "testapp" ] || [ "testapp" -ot "cmd/testapp/main.go" ] || \
       [ "testapp" -ot "server/server.go" ] || [ "testapp" -ot "client/client.go" ]; then
        echo "Building Go test application..."
        export PATH="$PATH:$(go env GOPATH)/bin"
        make proto build
    fi

    # Start server in background
    echo "Starting Go gRPC test server..."
    ./testapp server -port 50051 &
    GO_SERVER_PID=$!

    # Wait for server to start
    sleep 1

    # Check if server started successfully
    if ! kill -0 $GO_SERVER_PID 2>/dev/null; then
        echo -e "${RED}Failed to start Go gRPC test server${NC}"
        FAILED=1
    else
        # Run Go client tests
        echo "Running Go client tests..."
        if ./testapp client -addr localhost:50051 -test all; then
            echo -e "${GREEN}Go gRPC integration tests passed${NC}"
        else
            echo -e "${RED}Go gRPC integration tests failed${NC}"
            FAILED=1
        fi
    fi
fi

cd "$SCRIPT_DIR"

echo

# ------------------------------------------------------------------------------
# Cross-Language Tests: Lean client -> Go server
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[3/6] Running Lean client -> Go server tests...${NC}"
echo "----------------------------------------"

# Build Lean integration tests
echo "Building Lean integration tests..."
INTEGRATION_BUILT=0
if ! lake build integrationTests 2>&1; then
    echo -e "${RED}Failed to build Lean integration tests${NC}"
    FAILED=1
else
    INTEGRATION_BUILT=1
    # Check if Go server is still running, if not restart it
    if ! kill -0 $GO_SERVER_PID 2>/dev/null; then
        echo "Starting Go server for Lean client tests..."
        cd "$GO_TEST_DIR"
        ./testapp server -port 50051 &
        GO_SERVER_PID=$!
        sleep 1
        cd "$SCRIPT_DIR"
    fi

    # Run Lean client tests against Go server
    echo "Running Lean client tests against Go server..."
    if .lake/build/bin/integrationTests client; then
        echo -e "${GREEN}Lean client -> Go server tests passed${NC}"
    else
        echo -e "${RED}Lean client -> Go server tests failed${NC}"
        FAILED=1
    fi
fi

# Stop Go server
echo "Stopping Go gRPC test server..."
kill $GO_SERVER_PID 2>/dev/null || true
wait $GO_SERVER_PID 2>/dev/null || true

echo

# ------------------------------------------------------------------------------
# Lean TLS/mTLS Tests: Lean client <-> Lean server
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[4/6] Running Lean TLS/mTLS tests...${NC}"
echo "----------------------------------------"

if [ $INTEGRATION_BUILT -eq 1 ]; then
    echo "Running Lean TLS/mTLS integration tests..."
    if .lake/build/bin/integrationTests tls; then
        echo -e "${GREEN}Lean TLS/mTLS tests passed${NC}"
    else
        echo -e "${RED}Lean TLS/mTLS tests failed${NC}"
        FAILED=1
    fi
else
    echo -e "${RED}Skipping TLS/mTLS tests (integrationTests failed to build)${NC}"
    FAILED=1
fi

echo

# ------------------------------------------------------------------------------
# Lean WaitForReady Tests: Lean client <-> Lean server
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[5/6] Running Lean WaitForReady tests...${NC}"
echo "----------------------------------------"

if [ $INTEGRATION_BUILT -eq 1 ]; then
    echo "Running Lean wait-for-ready integration tests..."
    if .lake/build/bin/integrationTests ready; then
        echo -e "${GREEN}Lean WaitForReady tests passed${NC}"
    else
        echo -e "${RED}Lean WaitForReady tests failed${NC}"
        FAILED=1
    fi
else
    echo -e "${RED}Skipping WaitForReady tests (integrationTests failed to build)${NC}"
    FAILED=1
fi

echo

# ------------------------------------------------------------------------------
# Cross-Language Tests: Go client -> Lean server
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[6/6] Running Go client -> Lean server tests...${NC}"
echo "----------------------------------------"

# Start Lean server
echo "Starting Lean gRPC server on port 50052..."
.lake/build/bin/integrationTests server 50052 &
LEAN_SERVER_PID=$!
sleep 2

# Check if Lean server started successfully
if ! kill -0 $LEAN_SERVER_PID 2>/dev/null; then
    echo -e "${RED}Failed to start Lean gRPC server${NC}"
    FAILED=1
else
    # Run Go client tests against Lean server
    echo "Running Go client tests against Lean server..."
    cd "$GO_TEST_DIR"
    if ./testapp client -addr localhost:50052 -test all; then
        echo -e "${GREEN}Go client -> Lean server tests passed${NC}"
    else
        echo -e "${RED}Go client -> Lean server tests failed${NC}"
        FAILED=1
    fi
    cd "$SCRIPT_DIR"

    # Stop Lean server
    echo "Stopping Lean gRPC server..."
    kill $LEAN_SERVER_PID 2>/dev/null || true
    wait $LEAN_SERVER_PID 2>/dev/null || true
fi

echo
echo "========================================"
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
