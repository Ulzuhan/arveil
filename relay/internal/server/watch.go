package server

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
	"github.com/Ulzuhan/arveil/relay/internal/metrics"
	"github.com/Ulzuhan/arveil/relay/internal/store"
)

// Activity notices (ADR-014). A session sends MailboxWatch to be told,
// with an empty MailboxWakeup, when a mailbox of its device goes from empty
// to non-empty. A device has at most one subscription: a new one replaces
// the previous, and a watch session whose subscription is replaced closes.
//
// Nothing here is durable. A subscription that starts on a mailbox holding
// mail is notified at once, so a notice lost while the device was away is
// recovered by reconnecting.

// DefaultWatchIdle is how long a subscribed session may stay silent before
// the relay closes it. Clients ping well within it; tunnels and NATs often
// close idle connections sooner, which is the client's to measure.
const DefaultWatchIdle = 10 * time.Minute

type subscription struct {
	identity []byte
	// watchKey is the key a watch session authenticated with; nil for a
	// member session that subscribed.
	watchKey []byte
	wake     chan struct{} // capacity 1: notices coalesce
	done     chan struct{}
	once     sync.Once
}

func (s *subscription) cancel() { s.once.Do(func() { close(s.done) }) }

func (s *subscription) active() bool {
	select {
	case <-s.done:
		return false
	default:
		return true
	}
}

type watchHub struct {
	mu   sync.Mutex
	subs map[string]*subscription
}

func (h *watchHub) subscribe(identity, device, watchKey []byte) *subscription {
	sub := &subscription{identity: identity, watchKey: watchKey, wake: make(chan struct{}, 1), done: make(chan struct{})}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subs == nil {
		h.subs = map[string]*subscription{}
	}
	if old := h.subs[string(device)]; old != nil {
		old.cancel()
	}
	h.subs[string(device)] = sub
	metrics.WatchSubscriptions.Store(int64(len(h.subs)))
	return sub
}

// unsubscribe removes sub if it is still the device's subscription.
func (h *watchHub) unsubscribe(device []byte, sub *subscription) {
	sub.cancel()
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subs[string(device)] == sub {
		delete(h.subs, string(device))
	}
	metrics.WatchSubscriptions.Store(int64(len(h.subs)))
}

func (h *watchHub) wake(device []byte) {
	h.mu.Lock()
	sub := h.subs[string(device)]
	h.mu.Unlock()
	if sub == nil {
		return
	}
	select {
	case sub.wake <- struct{}{}:
	default:
	}
}

// devicesOf lists the subscribed devices of one identity.
func (h *watchHub) devicesOf(identity []byte) [][]byte {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out [][]byte
	for device, sub := range h.subs {
		if string(sub.identity) == string(identity) {
			out = append(out, []byte(device))
		}
	}
	return out
}

// dropStaleWatch ends the device's subscription if a watch session holds
// it with a key other than `current` (nil: the key was removed). A member
// session's subscription is left alone.
func (h *watchHub) dropStaleWatch(device, current []byte) {
	h.mu.Lock()
	sub := h.subs[string(device)]
	if sub == nil || sub.watchKey == nil || string(sub.watchKey) == string(current) {
		h.mu.Unlock()
		return
	}
	delete(h.subs, string(device))
	metrics.WatchSubscriptions.Store(int64(len(h.subs)))
	h.mu.Unlock()
	sub.cancel()
}

func (h *watchHub) drop(device []byte) {
	h.mu.Lock()
	sub := h.subs[string(device)]
	delete(h.subs, string(device))
	metrics.WatchSubscriptions.Store(int64(len(h.subs)))
	h.mu.Unlock()
	if sub != nil {
		sub.cancel()
	}
}

func (srv *Server) hub() *watchHub {
	srv.watchOnce.Do(func() { srv.watchers = &watchHub{} })
	return srv.watchers
}

func (srv *Server) watchIdle() time.Duration {
	if srv.WatchIdle > 0 {
		return srv.WatchIdle
	}
	return DefaultWatchIdle
}

// wakeMailbox notifies the subscription of the device owning a mailbox
// that has just stopped being empty.
func (srv *Server) wakeMailbox(ctx context.Context, mailboxID []byte) {
	device, err := srv.Store.MailboxOwnerDevice(ctx, mailboxID)
	if err != nil || device == nil {
		return
	}
	srv.hub().wake(device)
}

// recheckWatchers closes the subscriptions of an identity's devices that no
// longer have an active credential, after a manifest or a recovery revoked
// some of them.
func (srv *Server) recheckWatchers(ctx context.Context, identity []byte, now time.Time) {
	for _, device := range srv.hub().devicesOf(identity) {
		if active, err := srv.Store.DeviceActive(ctx, device, now); err == nil && !active {
			srv.hub().drop(device)
		}
	}
}

// watchDevice is the device a session may subscribe for.
func (s *session) watchDevice() *store.Device {
	if s.watcher != nil {
		return s.watcher
	}
	return s.device
}

// dispatchWatch is all a watch session may do. Every other frame is
// refused, including those a provisional session could send.
func (srv *Server) dispatchWatch(f channel.Frame) channel.Frame {
	switch f.Payload.Kind {
	case channel.KindPing:
		return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindPong}}
	case channel.KindEndpointListGet:
		return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindEndpointList, Signed: srv.SignedList}}
	default:
		return errFrame(f.ID, channel.CodeForbidden, "not allowed on a watch session")
	}
}

// watchKeySet registers, replaces or removes this device's watch key.
func (srv *Server) watchKeySet(ctx context.Context, s *session, f channel.Frame, now time.Time) channel.Frame {
	if !s.member() {
		return errFrame(f.ID, channel.CodeUnauthorized, "not a member session")
	}
	err := srv.Store.SetWatchKey(ctx, s.device.DeviceID, f.Payload.WatchKey, now)
	switch {
	case errors.Is(err, store.ErrWatchKeyShape):
		return errFrame(f.ID, channel.CodeBadRequest, "a watch key is 32 bytes")
	case errors.Is(err, store.ErrWatchKeyInUse):
		return errFrame(f.ID, channel.CodeConflict, "watch key already in use")
	case err != nil:
		return errFrame(f.ID, channel.CodeInternal, "store error")
	}
	// A removed or replaced key must not keep a session alive.
	srv.hub().dropStaleWatch(s.device.DeviceID, f.Payload.WatchKey)
	return channel.Frame{ID: f.ID, Payload: channel.Payload{Kind: channel.KindAck}}
}

// startWatch subscribes the session's device and returns the subscription,
// or an error frame. The caller answers Ack and then runs deliver.
func (srv *Server) startWatch(s *session, f channel.Frame) (*subscription, *channel.Frame) {
	d := s.watchDevice()
	if d == nil {
		e := errFrame(f.ID, channel.CodeUnauthorized, "not a member or watch session")
		return nil, &e
	}
	var watchKey []byte
	if s.watcher != nil {
		watchKey = s.remoteStatic
	}
	return srv.hub().subscribe(d.IdentityID, d.DeviceID, watchKey), nil
}

// deliver writes one MailboxWakeup per notice until the subscription or
// the connection ends. It first checks for mail already waiting.
func (srv *Server) deliver(ctx context.Context, s *session, sub *subscription, w *frameWriter) {
	if has, err := srv.Store.DeviceHasMail(ctx, s.watchDevice().DeviceID, time.Now()); err == nil && has {
		select {
		case sub.wake <- struct{}{}:
		default:
		}
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-sub.done:
			if s.watcher != nil {
				// A watch session exists only to be told; replaced or
				// revoked, it has nothing left to do.
				w.close("subscription ended")
			}
			return
		case <-sub.wake:
			if err := w.writePadded(ctx, channel.Frame{Payload: channel.Payload{Kind: channel.KindMailboxWakeup}}); err != nil {
				return
			}
			metrics.WakeupsSent.Add(1)
		}
	}
}
