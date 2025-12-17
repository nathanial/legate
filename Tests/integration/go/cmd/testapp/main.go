package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"legate/tests/integration/go/client"
	"legate/tests/integration/go/server"
)

func main() {
	// Subcommands
	serverCmd := flag.NewFlagSet("server", flag.ExitOnError)
	clientCmd := flag.NewFlagSet("client", flag.ExitOnError)

	// Server flags
	serverPort := serverCmd.Int("port", 50051, "Port to listen on")
	serverHost := serverCmd.String("host", "0.0.0.0", "Host to bind to")

	// Client flags
	clientAddr := clientCmd.String("addr", "localhost:50051", "Server address")
	clientTest := clientCmd.String("test", "all", "Test to run: unary|client-stream|server-stream|bidi|deadline|cancel|all")
	clientData := clientCmd.String("data", "hello", "Test data payload")
	clientCount := clientCmd.Int("count", 5, "Count for streaming tests")

	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "server":
		serverCmd.Parse(os.Args[2:])
		runServer(*serverHost, *serverPort)
	case "client":
		clientCmd.Parse(os.Args[2:])
		runClient(*clientAddr, *clientTest, *clientData, *clientCount)
	case "help", "-h", "--help":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n\n", os.Args[1])
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println("Legate gRPC Integration Test Application")
	fmt.Println()
	fmt.Println("Usage: testapp <command> [options]")
	fmt.Println()
	fmt.Println("Commands:")
	fmt.Println("  server   Start the gRPC test server")
	fmt.Println("  client   Run client tests against a server")
	fmt.Println()
	fmt.Println("Server options:")
	fmt.Println("  -host string   Host to bind to (default \"0.0.0.0\")")
	fmt.Println("  -port int      Port to listen on (default 50051)")
	fmt.Println()
	fmt.Println("Client options:")
	fmt.Println("  -addr string   Server address (default \"localhost:50051\")")
	fmt.Println("  -test string   Test to run: unary|client-stream|server-stream|bidi|deadline|cancel|all (default \"all\")")
	fmt.Println("  -data string   Test data payload (default \"hello\")")
	fmt.Println("  -count int     Count for streaming tests (default 5)")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  testapp server -port 50051")
	fmt.Println("  testapp client -addr localhost:50051 -test unary")
	fmt.Println("  testapp client -test all -count 10")
}

func runServer(host string, port int) {
	addr := fmt.Sprintf("%s:%d", host, port)
	srv := server.New()

	// Handle graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Shutting down server...")
		srv.Stop()
	}()

	log.Printf("Starting gRPC server on %s", addr)
	if err := srv.Start(addr); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func runClient(addr, test, data string, count int) {
	c, err := client.New(addr)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer c.Close()

	var testErr error
	switch test {
	case "unary":
		testErr = c.TestUnary([]byte(data))
	case "client-stream":
		testErr = c.TestClientStream([]byte(data), count)
	case "server-stream":
		testErr = c.TestServerStream([]byte(data), count)
		case "bidi":
			testErr = c.TestBidi([]byte(data), count)
		case "deadline":
			testErr = c.TestUnaryDeadlineExceeded([]byte(data))
		case "cancel":
			testErr = c.TestUnaryCancel([]byte(data))
		case "all":
			testErr = c.TestAll([]byte(data), count)
	default:
		log.Fatalf("Unknown test: %s", test)
	}

	if testErr != nil {
		log.Fatalf("Test failed: %v", testErr)
	}
	log.Println("All tests passed!")
}
