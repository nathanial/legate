package server

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	pb "legate/tests/integration/go/pb"
)

// Server implements the TestService gRPC server.
type Server struct {
	pb.UnimplementedTestServiceServer
	grpcServer *grpc.Server
}

// New creates a new Server instance.
func New() *Server {
	return &Server{}
}

func maybeSetTrailerFromIncomingMD(setTrailer func(metadata.MD), md metadata.MD) {
	vals := md.Get("x-legate-test")
	if len(vals) == 0 {
		return
	}
	setTrailer(metadata.Pairs("x-legate-test", vals[0]))
}

// maybeSetHeaderFromIncomingMD echoes the x-legate-test header back as x-legate-response-header
func maybeSetHeaderFromIncomingMD(ctx context.Context, md metadata.MD) error {
	vals := md.Get("x-legate-test")
	if len(vals) == 0 {
		return nil
	}
	return grpc.SendHeader(ctx, metadata.Pairs("x-legate-response-header", vals[0]))
}

func maybeSleepFromIncomingMD(md metadata.MD) error {
	vals := md.Get("x-sleep-ms")
	if len(vals) == 0 {
		return nil
	}
	ms, err := strconv.Atoi(vals[0])
	if err != nil {
		return fmt.Errorf("invalid x-sleep-ms: %w", err)
	}
	if ms > 0 {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
	return nil
}

func maybeWaitForCancel(ctx context.Context, md metadata.MD) error {
	if len(md.Get("x-wait-cancel")) == 0 {
		return nil
	}
	<-ctx.Done()
	return status.FromContextError(ctx.Err()).Err()
}

// maybeReturnError checks for x-return-error header with format "code:message"
// and returns an error if present. Also checks x-error-details for binary details.
func maybeReturnError(md metadata.MD) error {
	vals := md.Get("x-return-error")
	if len(vals) == 0 {
		return nil
	}
	// Parse "code:message" format
	parts := strings.SplitN(vals[0], ":", 2)
	code, err := strconv.Atoi(parts[0])
	if err != nil {
		code = int(codes.Unknown)
	}
	msg := ""
	if len(parts) > 1 {
		msg = parts[1]
	}

	// Check for optional error details
	detailVals := md.Get("x-error-details")
	if len(detailVals) > 0 {
		// Return error with details
		st := status.New(codes.Code(code), msg)
		// gRPC error details are typically proto-encoded, but for testing
		// we'll use the status.WithDetails API if we had proto messages.
		// For raw binary details, we use the grpc-status-details-bin trailer.
		// However, the standard Go API doesn't easily support raw binary details.
		// For now, return error without rich details; we'll test via Lean server.
		return st.Err()
	}

	return status.Error(codes.Code(code), msg)
}

// Start begins listening on the given address.
func (s *Server) Start(addr string) error {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("failed to listen: %w", err)
	}

	s.grpcServer = grpc.NewServer()
	pb.RegisterTestServiceServer(s.grpcServer, s)

	return s.grpcServer.Serve(lis)
}

// Stop gracefully shuts down the server.
func (s *Server) Stop() {
	if s.grpcServer != nil {
		s.grpcServer.GracefulStop()
	}
}

// Echo implements unary RPC - returns "ECHO:" + request data.
func (s *Server) Echo(ctx context.Context, req *pb.EchoRequest) (*pb.EchoResponse, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	maybeSetTrailerFromIncomingMD(func(m metadata.MD) { grpc.SetTrailer(ctx, m) }, md)
	// Send response headers (initial metadata)
	if err := maybeSetHeaderFromIncomingMD(ctx, md); err != nil {
		log.Printf("Echo: failed to send header: %v", err)
	}
	if err := maybeWaitForCancel(ctx, md); err != nil {
		return nil, err
	}
	if err := maybeSleepFromIncomingMD(md); err != nil {
		return nil, err
	}
	// Check if we should return an error
	if err := maybeReturnError(md); err != nil {
		log.Printf("Echo: returning error: %v", err)
		return nil, err
	}

	log.Printf("Echo: received %d bytes", len(req.Data))
	return &pb.EchoResponse{
		Data: append([]byte("ECHO:"), req.Data...),
	}, nil
}

// Collect implements client streaming RPC - joins all messages with "|".
func (s *Server) Collect(stream pb.TestService_CollectServer) error {
	md, _ := metadata.FromIncomingContext(stream.Context())
	maybeSetTrailerFromIncomingMD(stream.SetTrailer, md)
	// Send response headers (initial metadata)
	if err := maybeSetHeaderFromIncomingMD(stream.Context(), md); err != nil {
		log.Printf("Collect: failed to send header: %v", err)
	}
	// Check if we should return an error immediately
	if err := maybeReturnError(md); err != nil {
		log.Printf("Collect: returning error immediately: %v", err)
		return err
	}
	// Check if we should delay (for deadline/cancellation testing)
	delayMs := 0
	if vals := md.Get("x-delay-ms"); len(vals) > 0 {
		if d, err := strconv.Atoi(vals[0]); err == nil {
			delayMs = d
		}
	}
	// Check if we should error after N messages
	errorAfterN := -1
	if vals := md.Get("x-error-after-n"); len(vals) > 0 {
		if n, err := strconv.Atoi(vals[0]); err == nil {
			errorAfterN = n
		}
	}
	var parts [][]byte
	for {
		// Check for cancellation
		select {
		case <-stream.Context().Done():
			log.Printf("Collect: cancelled after %d messages", len(parts))
			return status.FromContextError(stream.Context().Err()).Err()
		default:
		}
		req, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			log.Printf("Collect: recv error after %d messages: %v", len(parts), err)
			return err
		}
		log.Printf("Collect: received chunk %d bytes", len(req.Data))
		parts = append(parts, req.Data)
		// Check if we should error after receiving N messages
		if errorAfterN >= 0 && len(parts) >= errorAfterN {
			log.Printf("Collect: returning error after %d messages", len(parts))
			return status.Error(codes.Aborted, fmt.Sprintf("error after %d messages", len(parts)))
		}
		if delayMs > 0 {
			time.Sleep(time.Duration(delayMs) * time.Millisecond)
		}
	}

	joined := bytes.Join(parts, []byte("|"))
	log.Printf("Collect: sending response with %d parts", len(parts))
	return stream.SendAndClose(&pb.CollectResponse{
		Data:  joined,
		Count: int32(len(parts)),
	})
}

// Expand implements server streaming RPC - sends N numbered responses.
func (s *Server) Expand(req *pb.ExpandRequest, stream pb.TestService_ExpandServer) error {
	md, _ := metadata.FromIncomingContext(stream.Context())
	maybeSetTrailerFromIncomingMD(stream.SetTrailer, md)
	// Send response headers (initial metadata)
	if err := maybeSetHeaderFromIncomingMD(stream.Context(), md); err != nil {
		log.Printf("Expand: failed to send header: %v", err)
	}
	// Check if we should return an error immediately
	if err := maybeReturnError(md); err != nil {
		log.Printf("Expand: returning error immediately: %v", err)
		return err
	}
	// Check if we should delay between sends (for cancellation testing)
	delayMs := 0
	if vals := md.Get("x-delay-ms"); len(vals) > 0 {
		if d, err := strconv.Atoi(vals[0]); err == nil {
			delayMs = d
		}
	}
	// Check if we should error after N messages
	errorAfterN := -1
	if vals := md.Get("x-error-after-n"); len(vals) > 0 {
		if n, err := strconv.Atoi(vals[0]); err == nil {
			errorAfterN = n
		}
	}
	log.Printf("Expand: generating %d responses with prefix %q (delay=%dms)", req.Count, string(req.Prefix), delayMs)
	for i := int32(0); i < req.Count; i++ {
		// Check for cancellation before sending
		select {
		case <-stream.Context().Done():
			log.Printf("Expand: cancelled after %d messages", i)
			return status.FromContextError(stream.Context().Err()).Err()
		default:
		}
		// Check if we should error after sending N messages
		if errorAfterN >= 0 && int(i) >= errorAfterN {
			log.Printf("Expand: returning error after %d messages", i)
			return status.Error(codes.Aborted, fmt.Sprintf("error after %d messages", i))
		}
		data := fmt.Sprintf("%s:%d", string(req.Prefix), i)
		if err := stream.Send(&pb.ExpandResponse{
			Data:     []byte(data),
			Sequence: i,
		}); err != nil {
			log.Printf("Expand: send error after %d messages: %v", i, err)
			return err
		}
		if delayMs > 0 {
			time.Sleep(time.Duration(delayMs) * time.Millisecond)
		}
	}
	return nil
}

// BiEcho implements bidirectional streaming RPC - echoes each message with sequence.
func (s *Server) BiEcho(stream pb.TestService_BiEchoServer) error {
	md, _ := metadata.FromIncomingContext(stream.Context())
	maybeSetTrailerFromIncomingMD(stream.SetTrailer, md)
	// Send response headers (initial metadata)
	if err := maybeSetHeaderFromIncomingMD(stream.Context(), md); err != nil {
		log.Printf("BiEcho: failed to send header: %v", err)
	}
	// Check if we should return an error immediately
	if err := maybeReturnError(md); err != nil {
		log.Printf("BiEcho: returning error immediately: %v", err)
		return err
	}
	// Check if we should delay (for deadline/cancellation testing)
	delayMs := 0
	if vals := md.Get("x-delay-ms"); len(vals) > 0 {
		if d, err := strconv.Atoi(vals[0]); err == nil {
			delayMs = d
		}
	}
	// Check if we should error after N messages
	errorAfterN := -1
	if vals := md.Get("x-error-after-n"); len(vals) > 0 {
		if n, err := strconv.Atoi(vals[0]); err == nil {
			errorAfterN = n
		}
	}
	seq := int32(0)
	for {
		// Check for cancellation
		select {
		case <-stream.Context().Done():
			log.Printf("BiEcho: cancelled after %d messages", seq)
			return status.FromContextError(stream.Context().Err()).Err()
		default:
		}
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			log.Printf("BiEcho: recv error after %d messages: %v", seq, err)
			return err
		}

		log.Printf("BiEcho: received message %d", seq)
		// Check if we should error after processing N messages
		if errorAfterN >= 0 && int(seq) >= errorAfterN {
			log.Printf("BiEcho: returning error after %d messages", seq)
			return status.Error(codes.Aborted, fmt.Sprintf("error after %d messages", seq))
		}
		data := fmt.Sprintf("%d:%s", seq, string(req.Data))
		if err := stream.Send(&pb.BiEchoResponse{
			Data:     []byte(data),
			Sequence: seq,
		}); err != nil {
			log.Printf("BiEcho: send error after %d messages: %v", seq, err)
			return err
		}
		seq++
		if delayMs > 0 {
			time.Sleep(time.Duration(delayMs) * time.Millisecond)
		}
	}
}
