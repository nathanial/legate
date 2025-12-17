package server

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"time"

	"google.golang.org/grpc"
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
	if err := maybeWaitForCancel(ctx, md); err != nil {
		return nil, err
	}
	if err := maybeSleepFromIncomingMD(md); err != nil {
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
	var parts [][]byte
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		log.Printf("Collect: received chunk %d bytes", len(req.Data))
		parts = append(parts, req.Data)
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
	log.Printf("Expand: generating %d responses with prefix %q", req.Count, string(req.Prefix))
	for i := int32(0); i < req.Count; i++ {
		data := fmt.Sprintf("%s:%d", string(req.Prefix), i)
		if err := stream.Send(&pb.ExpandResponse{
			Data:     []byte(data),
			Sequence: i,
		}); err != nil {
			return err
		}
	}
	return nil
}

// BiEcho implements bidirectional streaming RPC - echoes each message with sequence.
func (s *Server) BiEcho(stream pb.TestService_BiEchoServer) error {
	md, _ := metadata.FromIncomingContext(stream.Context())
	maybeSetTrailerFromIncomingMD(stream.SetTrailer, md)
	seq := int32(0)
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		log.Printf("BiEcho: received message %d", seq)
		data := fmt.Sprintf("%d:%s", seq, string(req.Data))
		if err := stream.Send(&pb.BiEchoResponse{
			Data:     []byte(data),
			Sequence: seq,
		}); err != nil {
			return err
		}
		seq++
	}
}
