package server

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net"

	"google.golang.org/grpc"

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
	log.Printf("Echo: received %d bytes", len(req.Data))
	return &pb.EchoResponse{
		Data: append([]byte("ECHO:"), req.Data...),
	}, nil
}

// Collect implements client streaming RPC - joins all messages with "|".
func (s *Server) Collect(stream pb.TestService_CollectServer) error {
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
