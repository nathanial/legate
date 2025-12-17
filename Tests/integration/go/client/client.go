package client

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	pb "legate/tests/integration/go/pb"
)

// Client wraps the gRPC TestService client.
type Client struct {
	conn   *grpc.ClientConn
	client pb.TestServiceClient
}

// New creates a new Client connected to the given address.
func New(addr string) (*Client, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := grpc.DialContext(ctx, addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithBlock(),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to dial: %w", err)
	}

	return &Client{
		conn:   conn,
		client: pb.NewTestServiceClient(conn),
	}, nil
}

// Close closes the client connection.
func (c *Client) Close() error {
	return c.conn.Close()
}

// TestUnary tests the Echo RPC.
func (c *Client) TestUnary(data []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	resp, err := c.client.Echo(ctx, &pb.EchoRequest{Data: data})
	if err != nil {
		return fmt.Errorf("Echo failed: %w", err)
	}

	expected := append([]byte("ECHO:"), data...)
	if !bytes.Equal(resp.Data, expected) {
		return fmt.Errorf("unexpected response: got %q, want %q", resp.Data, expected)
	}

	log.Printf("Unary test passed: %q -> %q", data, resp.Data)
	return nil
}

// TestClientStream tests the Collect RPC.
func (c *Client) TestClientStream(data []byte, count int) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := c.client.Collect(ctx)
	if err != nil {
		return fmt.Errorf("Collect failed to start: %w", err)
	}

	// Send multiple messages
	var expectedParts [][]byte
	for i := 0; i < count; i++ {
		msg := []byte(fmt.Sprintf("%s-%d", string(data), i))
		expectedParts = append(expectedParts, msg)
		if err := stream.Send(&pb.CollectRequest{Data: msg}); err != nil {
			return fmt.Errorf("Collect send failed: %w", err)
		}
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		return fmt.Errorf("Collect close failed: %w", err)
	}

	if resp.Count != int32(count) {
		return fmt.Errorf("unexpected count: got %d, want %d", resp.Count, count)
	}

	expectedData := bytes.Join(expectedParts, []byte("|"))
	if !bytes.Equal(resp.Data, expectedData) {
		return fmt.Errorf("unexpected data: got %q, want %q", resp.Data, expectedData)
	}

	log.Printf("Client streaming test passed: sent %d messages, got %q", count, resp.Data)
	return nil
}

// TestServerStream tests the Expand RPC.
func (c *Client) TestServerStream(prefix []byte, count int) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := c.client.Expand(ctx, &pb.ExpandRequest{
		Count:  int32(count),
		Prefix: prefix,
	})
	if err != nil {
		return fmt.Errorf("Expand failed: %w", err)
	}

	received := 0
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("Expand recv failed: %w", err)
		}

		expected := fmt.Sprintf("%s:%d", string(prefix), resp.Sequence)
		if string(resp.Data) != expected {
			return fmt.Errorf("unexpected data at seq %d: got %q, want %q",
				resp.Sequence, resp.Data, expected)
		}
		received++
	}

	if received != count {
		return fmt.Errorf("unexpected message count: got %d, want %d", received, count)
	}

	log.Printf("Server streaming test passed: received %d messages", received)
	return nil
}

// TestBidi tests the BiEcho RPC.
func (c *Client) TestBidi(data []byte, count int) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := c.client.BiEcho(ctx)
	if err != nil {
		return fmt.Errorf("BiEcho failed to start: %w", err)
	}

	// Interleave send/recv to verify "immediate" streaming semantics.
	for i := 0; i < count; i++ {
		msg := []byte(fmt.Sprintf("%s-%d", string(data), i))
		if err := stream.Send(&pb.BiEchoRequest{Data: msg}); err != nil {
			return fmt.Errorf("BiEcho send failed: %w", err)
		}

		resp, err := stream.Recv()
		if err != nil {
			return fmt.Errorf("BiEcho recv failed: %w", err)
		}

		expectedPrefix := fmt.Sprintf("%d:", resp.Sequence)
		if !bytes.HasPrefix(resp.Data, []byte(expectedPrefix)) {
			return fmt.Errorf("unexpected response format at seq %d: %q", resp.Sequence, resp.Data)
		}
	}

	if err := stream.CloseSend(); err != nil {
		return fmt.Errorf("BiEcho close send failed: %w", err)
	}

	// No extra responses expected after CloseSend.
	if resp, err := stream.Recv(); err != io.EOF {
		if err != nil {
			return fmt.Errorf("BiEcho recv after CloseSend failed: %w", err)
		}
		return fmt.Errorf("unexpected extra response after CloseSend: %q", resp.Data)
	}

	log.Printf("Bidirectional streaming test passed: exchanged %d messages", count)
	return nil
}

// TestAll runs all tests.
func (c *Client) TestAll(data []byte, count int) error {
	tests := []struct {
		name string
		fn   func() error
	}{
		{"unary", func() error { return c.TestUnary(data) }},
		{"client-stream", func() error { return c.TestClientStream(data, count) }},
		{"server-stream", func() error { return c.TestServerStream(data, count) }},
		{"bidi", func() error { return c.TestBidi(data, count) }},
	}

	for _, t := range tests {
		log.Printf("Running test: %s", t.name)
		if err := t.fn(); err != nil {
			return fmt.Errorf("%s: %w", t.name, err)
		}
	}

	return nil
}
