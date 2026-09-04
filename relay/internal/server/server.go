// Package server serves the device↔realm channel over WebSocket.
//
// One WebSocket connection carries one Noise IK session. Every binary
// WebSocket message is exactly one Noise message. The server processes no
// frame before the handshake completes. The initiator's static key decides
// the session state (see session.go): unknown keys get a provisional session
// that may only redeem an invite; keys bound to an active credential get a
// member session; revoked or expired credentials are refused before
// message 2.
package server

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
	"github.com/Ulzuhan/arveil/relay/internal/limits"
	"github.com/Ulzuhan/arveil/relay/internal/metrics"
	"github.com/Ulzuhan/arveil/relay/internal/realm"
	"github.com/Ulzuhan/arveil/relay/internal/store"
)

// ChannelPath is the only WebSocket route.
const ChannelPath = "/v1/channel"

// Server holds what a connection needs.
type Server struct {
	Identity   *realm.Identity
	Store      *store.Store // nil only in carrier-level tests
	Blobs      *store.BlobStore
	SignedList []byte // current signed RealmEndpointList
	Logger     *log.Logger
	// PairTTL is how long a pairing rendezvous lives.
	PairTTL      time.Duration
	ReadTimeout  time.Duration // per message; keepalive pings must arrive within it
	HandshakeTTL time.Duration
	// Limits bounds what one address can take. Nil allows everything.
	Limits *limits.Gate
	// TrustForwardedFor reads the client address from X-Forwarded-For.
	// Only turn it on when the proxy in front is yours and overwrites that
	// header, otherwise a client sets its own address and the limits stop
	// meaning anything.
	TrustForwardedFor bool
}

// Handler returns the HTTP handler mounting the channel route.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(ChannelPath, s.serveChannel)
	return mux
}

// clientAddr is what the limits are keyed on: the peer address, or the
// first entry of X-Forwarded-For when the operator says the proxy is theirs.
func (s *Server) clientAddr(r *http.Request) string {
	if s.TrustForwardedFor {
		if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
			if first, _, found := strings.Cut(fwd, ","); found {
				return strings.TrimSpace(first)
			}
			return strings.TrimSpace(fwd)
		}
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

func (s *Server) serveChannel(w http.ResponseWriter, r *http.Request) {
	addr := s.clientAddr(r)
	release, ok := s.Limits.Acquire(addr)
	if !ok {
		metrics.ConnectionsRefused.Add(1)
		// The address is not logged: a refusal says a limit bit, not who.
		s.Logger.Printf("connection refused by a limit")
		http.Error(w, "too many connections", http.StatusTooManyRequests)
		return
	}
	defer release()
	metrics.ConnectionsTotal.Add(1)

	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Native clients send no Origin; browsers are not a supported client.
		OriginPatterns: nil,
	})
	if err != nil {
		s.Logger.Printf("accept: %v", err)
		return
	}
	defer c.CloseNow()
	c.SetReadLimit(channel.MaxNoiseMessage)

	ctx := r.Context()
	ch, sess, err := s.handshake(ctx, c)
	if err != nil {
		metrics.HandshakesFailed.Add(1)
		// Deliberately terse: no identifiers, no key material in logs.
		s.Logger.Printf("handshake failed")
		c.Close(websocket.StatusPolicyViolation, "handshake")
		return
	}

	for {
		frame, ok, err := s.readFrame(ctx, c, ch)
		if err != nil {
			if !errors.Is(err, context.Canceled) && websocket.CloseStatus(err) == -1 {
				s.Logger.Printf("channel closed: %v", errKind(err))
			}
			return
		}
		if !ok {
			continue
		}
		sess.addr = addr
		metrics.FramesHandled.Add(1)
		reply := s.dispatchSession(ctx, sess, frame, time.Now())
		if err := s.writeFrame(ctx, c, ch, reply); err != nil {
			return
		}
	}
}

func (s *Server) handshake(ctx context.Context, c *websocket.Conn) (*channel.Channel, *session, error) {
	hctx, cancel := context.WithTimeout(ctx, s.HandshakeTTL)
	defer cancel()

	typ, m1, err := c.Read(hctx)
	if err != nil {
		return nil, nil, err
	}
	if typ != websocket.MessageBinary {
		return nil, nil, errors.New("handshake: text frame")
	}
	resp, err := channel.NewResponder(s.Identity.NoiseKey, channel.Prologue(s.Identity.ID))
	if err != nil {
		return nil, nil, err
	}
	remoteStatic, err := resp.ReadMessage1(m1)
	if err != nil {
		return nil, nil, err
	}
	// Unknown keys get a provisional session (they may only redeem an
	// invite); revoked or expired credentials are refused before message 2.
	sess, err := s.authorize(hctx, remoteStatic, time.Now())
	if err != nil {
		return nil, nil, err
	}
	m2, t, err := resp.WriteMessage2()
	if err != nil {
		return nil, nil, err
	}
	if err := c.Write(hctx, websocket.MessageBinary, m2); err != nil {
		return nil, nil, err
	}
	return channel.NewChannel(t), sess, nil
}

func (s *Server) readFrame(ctx context.Context, c *websocket.Conn, ch *channel.Channel) (channel.Frame, bool, error) {
	rctx, cancel := context.WithTimeout(ctx, s.ReadTimeout)
	defer cancel()
	typ, msg, err := c.Read(rctx)
	if err != nil {
		return channel.Frame{}, false, err
	}
	if typ != websocket.MessageBinary {
		return channel.Frame{}, false, errors.New("text frame on channel")
	}
	return ch.Open(msg)
}

func (s *Server) writeFrame(ctx context.Context, c *websocket.Conn, ch *channel.Channel, f channel.Frame) error {
	msgs, err := ch.Seal(f)
	if err != nil {
		return err
	}
	for _, m := range msgs {
		wctx, cancel := context.WithTimeout(ctx, s.ReadTimeout)
		err := c.Write(wctx, websocket.MessageBinary, m)
		cancel()
		if err != nil {
			return err
		}
	}
	return nil
}

// errKind strips anything that could carry identifiers from an error before logging.
func errKind(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, channel.ErrTooLarge):
		return "frame too large"
	default:
		return "protocol error"
	}
}
