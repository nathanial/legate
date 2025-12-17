#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================"
echo "Legate Test Suite"
echo "========================================"
echo

# Track overall result
FAILED=0

# ------------------------------------------------------------------------------
# Unit Tests (Lean)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[1/2] Running Lean unit tests...${NC}"
echo "----------------------------------------"

if lake test; then
    echo -e "${GREEN}Lean unit tests passed${NC}"
else
    echo -e "${RED}Lean unit tests failed${NC}"
    FAILED=1
fi

echo

# ------------------------------------------------------------------------------
# Integration Tests (Go gRPC)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[2/2] Running Go gRPC integration tests...${NC}"
echo "----------------------------------------"

GO_TEST_DIR="$SCRIPT_DIR/tests/integration/go"

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
    echo "Starting gRPC test server..."
    ./testapp server -port 50051 &
    SERVER_PID=$!

    # Wait for server to start
    sleep 1

    # Check if server started successfully
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo -e "${RED}Failed to start gRPC test server${NC}"
        FAILED=1
    else
        # Run client tests
        echo "Running client tests..."
        if ./testapp client -addr localhost:50051 -test all; then
            echo -e "${GREEN}Go gRPC integration tests passed${NC}"
        else
            echo -e "${RED}Go gRPC integration tests failed${NC}"
            FAILED=1
        fi

        # Stop server
        echo "Stopping gRPC test server..."
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
fi

cd "$SCRIPT_DIR"

echo
echo "========================================"
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
