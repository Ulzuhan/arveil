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
	"net/netip"
	"strings"
	"sync"
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
	// TrustForwardedFor reads the client address from the last
	// X-Forwarded-For entry, the one the proxy in front added. Only turn it
	// on when that proxy is yours or one you chose, and every connection
	// reaches the relay through it; otherwise a client sets its own address
	// and the limits stop meaning anything.
	TrustForwardedFor bool
	// WatchIdle is how long a session subscribed to activity notices may
	// stay silent (ADR-014). Zero means DefaultWatchIdle.
	WatchIdle time.Duration

	watchOnce sync.Once
	watchers  *watchHub
}

// Handler returns the HTTP handler mounting the channel route.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(ChannelPath, s.serveChannel)
	return mux
}

// clientAddr is what the limits are keyed on (see limitKey): the peer
// address or, when the operator trusts the proxy in front, the last
// X-Forwarded-For entry, the one that proxy added. Earlier entries come from
// the client and prove nothing: reading the first one let a client behind a
// proxy that appends, as Cloudflare does, pick its own limit bucket. An entry
// that is not an address falls back to the peer.
func (s *Server) clientAddr(r *http.Request) string {
	peer := r.RemoteAddr
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		peer = host
	}
	if s.TrustForwardedFor {
		if chain := r.Header.Values("X-Forwarded-For"); len(chain) > 0 {
			entries := strings.Split(chain[len(chain)-1], ",")
			if addr, err := netip.ParseAddr(strings.TrimSpace(entries[len(entries)-1])); err == nil {
				return limitKey(addr)
			}
		}
	}
	if addr, err := netip.ParseAddr(peer); err == nil {
		return limitKey(addr)
	}
	return peer
}

// limitKey groups addresses the way they are handed out. An IPv6 client
// usually controls a whole /64, so keying on its exact address gave it a
// fresh bucket per address; IPv4, and IPv4-mapped IPv6, stays per address.
func limitKey(addr netip.Addr) string {
	addr = addr.Unmap().WithZone("")
	if addr.Is6() {
		return netip.PrefixFrom(addr, 64).Masked().String()
	}
	return addr.String()
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

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	ch, sess, err := s.handshake(ctx, c)
	if err != nil {
		metrics.HandshakesFailed.Add(1)
		// Deliberately terse: no identifiers, no key material in logs.
		s.Logger.Printf("handshake failed")
		c.Close(websocket.StatusPolicyViolation, "handshake")
		return
	}

	fw := &frameWriter{c: c, ch: ch, timeout: s.ReadTimeout, padded: sess.watcher != nil}
	readTimeout := s.ReadTimeout
	var sub *subscription
	defer func() {
		if sub != nil {
			s.hub().unsubscribe(sess.watchDevice().DeviceID, sub)
		}
	}()
	for {
		frame, ok, err := s.readFrame(ctx, c, ch, readTimeout)
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
		if frame.Payload.Kind == channel.KindMailboxWatch {
			// Already subscribed: nothing changes, and replacing its own
			// subscription must not close a watch session.
			if sub != nil && sub.active() {
				if err := fw.write(ctx, channel.Frame{ID: frame.ID, Payload: channel.Payload{Kind: channel.KindAck}}); err != nil {
					return
				}
				continue
			}
			next, refusal := s.startWatch(sess, frame)
			if refusal != nil {
				if err := fw.write(ctx, *refusal); err != nil {
					return
				}
				continue
			}
			if sub != nil {
				s.hub().unsubscribe(sess.watchDevice().DeviceID, sub)
			}
			sub = next
			if err := fw.write(ctx, channel.Frame{ID: frame.ID, Payload: channel.Payload{Kind: channel.KindAck}}); err != nil {
				return
			}
			readTimeout = s.watchIdle()
			go s.deliver(ctx, sess, sub, fw)
			continue
		}
		var reply channel.Frame
		if sess.watcher != nil {
			reply = s.dispatchWatch(frame)
		} else {
			reply = s.dispatchSession(ctx, sess, frame, time.Now())
		}
		if err := fw.write(ctx, reply); err != nil {
			return
		}
	}
}

// frameWriter serialises writes on one connection. Replies and activity
// notices come from different goroutines, and the Noise nonce must follow
// the order in which messages reach the socket.
type frameWriter struct {
	mu      sync.Mutex
	c       *websocket.Conn
	ch      *channel.Channel
	timeout time.Duration
	// padded pads every frame, as a watch session does (ADR-014).
	padded bool
}

func (w *frameWriter) write(ctx context.Context, f channel.Frame) error {
	if w.padded {
		return w.writePadded(ctx, f)
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	msgs, err := w.ch.Seal(f)
	if err != nil {
		return err
	}
	return w.send(ctx, msgs)
}

func (w *frameWriter) writePadded(ctx context.Context, f channel.Frame) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	msgs, err := w.ch.SealPadded(f, channel.WatchFrameBytes)
	if err != nil {
		return err
	}
	return w.send(ctx, msgs)
}

func (w *frameWriter) send(ctx context.Context, msgs [][]byte) error {
	for _, m := range msgs {
		wctx, cancel := context.WithTimeout(ctx, w.timeout)
		err := w.c.Write(wctx, websocket.MessageBinary, m)
		cancel()
		if err != nil {
			return err
		}
	}
	return nil
}

func (w *frameWriter) close(reason string) {
	w.c.Close(websocket.StatusNormalClosure, reason)
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

func (s *Server) readFrame(ctx context.Context, c *websocket.Conn, ch *channel.Channel, timeout time.Duration) (channel.Frame, bool, error) {
	rctx, cancel := context.WithTimeout(ctx, timeout)
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
