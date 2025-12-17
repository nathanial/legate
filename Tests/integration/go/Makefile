.PHONY: all proto build clean test run-server run-client install-tools

# Paths
PROTO_DIR := proto
PB_DIR := pb
CMD_DIR := cmd/testapp
BINARY := testapp

# Tools
PROTOC := protoc
GO := go

all: proto build

# Generate protobuf code
proto:
	@mkdir -p $(PB_DIR)
	$(PROTOC) \
		--proto_path=$(PROTO_DIR) \
		--go_out=$(PB_DIR) \
		--go_opt=paths=source_relative \
		--go-grpc_out=$(PB_DIR) \
		--go-grpc_opt=paths=source_relative \
		$(PROTO_DIR)/legate_test.proto

# Build the binary
build: proto
	$(GO) build -o $(BINARY) ./$(CMD_DIR)

# Clean generated files and binary
clean:
	rm -rf $(PB_DIR)
	rm -f $(BINARY)

# Run tests (Go unit tests)
test: proto
	$(GO) test -v ./...

# Run server (default port 50051)
run-server: build
	./$(BINARY) server -port 50051

# Run client tests against server
run-client: build
	./$(BINARY) client -addr localhost:50051 -test all

# Install protoc plugins (run once)
install-tools:
	$(GO) install google.golang.org/protobuf/cmd/protoc-gen-go@latest
	$(GO) install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# Help
help:
	@echo "Available targets:"
	@echo "  all           - Generate proto and build binary (default)"
	@echo "  proto         - Generate Go code from proto files"
	@echo "  build         - Build the testapp binary"
	@echo "  clean         - Remove generated files and binary"
	@echo "  test          - Run Go unit tests"
	@echo "  run-server    - Start the gRPC server on port 50051"
	@echo "  run-client    - Run all client tests against localhost:50051"
	@echo "  install-tools - Install protoc-gen-go plugins"
