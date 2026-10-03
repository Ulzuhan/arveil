package server

import (
	"bytes"
	"context"
	"io"
	"log"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/flynn/noise"

	"github.com/Ulzuhan/arveil/relay/internal/channel"
	"github.com/Ulzuhan/arveil/relay/internal/realm"
	"github.com/Ulzuhan/arveil/relay/internal/store"
)

type watchRig struct {
	t        *testing.T
	srv      *Server
	db       *store.Store
	url      string
	identity *realm.Identity
	id       []byte
	cred     []byte
	device   []byte
	static   noise.DHKey
	mailbox  *store.Mailbox
}

func newWatchRig(t *testing.T) *watchRig {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	identity, err := realm.Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	db, err := store.Open(filepath.Join(dir, "realm.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	static, err := channel.GenerateStaticKeypair()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	r := &watchRig{
		t: t, db: db, identity: identity, static: static,
		id:     bytes.Repeat([]byte{1}, 32),
		cred:   bytes.Repeat([]byte{2}, 32),
		device: bytes.Repeat([]byte{3}, 16),
	}
	e := store.Enrollment{IdentityID: r.id, RootPublic: r.id, CredentialHash: r.cred, DeviceID: r.device,
		TransportKey: static.Public, SignedCred: []byte{5}, NotAfter: now.Add(time.Hour).Unix(),
		ManifestSeq: 1, SignedManifest: []byte{6}}
	if err := db.CreateInvite(ctx, []byte("t"), "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err := db.RedeemInvite(ctx, []byte("t"), now, e, nil); err != nil {
		t.Fatal(err)
	}
	if r.mailbox, err = db.CreateMailbox(ctx, r.id, r.device, now); err != nil {
		t.Fatal(err)
	}
	r.srv = &Server{Identity: identity, Store: db, Logger: log.New(io.Discard, "", 0),
		ReadTimeout: 5 * time.Second, HandshakeTTL: 5 * time.Second}
	hs := httptest.NewServer(r.srv.Handler())
	t.Cleanup(hs.Close)
	r.url = "ws" + strings.TrimPrefix(hs.URL, "http") + ChannelPath
	return r
}

type received struct {
	f    channel.Frame
	size int
}

type testConn struct {
	t  *testing.T
	ws *websocket.Conn
	ch *channel.Channel
	id uint64
	// in is fed by one reader goroutine: cancelling a websocket Read closes
	// the connection, so waits with a timeout happen on this channel.
	in chan received
}

// dial completes the handshake as `key`; it returns nil if the relay
// refuses the handshake.
func (r *watchRig) dial(key noise.DHKey) *testConn {
	r.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, r.url, nil)
	if err != nil {
		r.t.Fatal(err)
	}
	init, err := channel.NewInitiator(key, r.identity.NoiseKey.Public, channel.Prologue(r.identity.ID))
	if err != nil {
		r.t.Fatal(err)
	}
	m1, err := init.WriteMessage1()
	if err != nil {
		r.t.Fatal(err)
	}
	if err := ws.Write(ctx, websocket.MessageBinary, m1); err != nil {
		r.t.Fatal(err)
	}
	_, m2, err := ws.Read(ctx)
	if err != nil {
		ws.CloseNow()
		return nil
	}
	tr, err := init.ReadMessage2(m2)
	if err != nil {
		r.t.Fatal(err)
	}
	c := &testConn{t: r.t, ws: ws, ch: channel.NewChannel(tr), in: make(chan received, 16)}
	r.t.Cleanup(func() { ws.CloseNow() })
	go func() {
		defer close(c.in)
		for {
			_, msg, err := ws.Read(context.Background())
			if err != nil {
				return
			}
			// Single-fragment frames only in this test: open the transport
			// by hand to see the padded length, then drop the fragment flag.
			frag, err := tr.Open(msg)
			if err != nil {
				return
			}
			f, err := channel.Decode(frag[1:])
			if err != nil {
				return
			}
			c.in <- received{f, len(frag) - 1}
		}
	}()
	return c
}

func (c *testConn) send(p channel.Payload) uint64 {
	c.t.Helper()
	c.id++
	msgs, err := c.ch.Seal(channel.Frame{ID: c.id, Payload: p})
	if err != nil {
		c.t.Fatal(err)
	}
	for _, m := range msgs {
		if err := c.ws.Write(context.Background(), websocket.MessageBinary, m); err != nil {
			c.t.Fatal(err)
		}
	}
	return c.id
}

// recv returns the next frame and the size of its encoding, or ok=false if
// nothing arrives within `wait` or the connection ends.
func (c *testConn) recv(wait time.Duration) (f channel.Frame, size int, ok bool) {
	select {
	case r, open := <-c.in:
		return r.f, r.size, open
	case <-time.After(wait):
		return channel.Frame{}, 0, false
	}
}

func (c *testConn) call(p channel.Payload) (channel.Frame, int) {
	c.t.Helper()
	id := c.send(p)
	f, size, ok := c.recv(2 * time.Second)
	if !ok || f.ID != id {
		c.t.Fatalf("no reply to %s (got %+v)", p.Kind, f)
	}
	return f, size
}

func (r *watchRig) registerWatchKey(member *testConn) noise.DHKey {
	r.t.Helper()
	key, err := channel.GenerateStaticKeypair()
	if err != nil {
		r.t.Fatal(err)
	}
	if f, _ := member.call(channel.Payload{Kind: channel.KindWatchKeySet, WatchKey: key.Public}); f.Payload.Kind != channel.KindAck {
		r.t.Fatalf("watch key refused: %+v", f.Payload)
	}
	return key
}

func (r *watchRig) put(member *testConn, delivery string) {
	r.t.Helper()
	f, _ := member.call(channel.Payload{Kind: channel.KindEnvelopePut, MailboxID: r.mailbox.MailboxID,
		WriteCapability: r.mailbox.WriteCapability, DeliveryID: []byte(delivery), HpkeEnc: []byte("enc"), Ciphertext: []byte("ct")})
	if f.Payload.Kind != channel.KindEnvelopeAccepted {
		r.t.Fatalf("put refused: %+v", f.Payload)
	}
}

func TestWatchSessionOnlyWatchesAndIsPadded(t *testing.T) {
	r := newWatchRig(t)
	member := r.dial(r.static)
	if f, _ := member.call(channel.Payload{Kind: channel.KindWatchKeySet, WatchKey: r.static.Public}); f.Payload.Code != channel.CodeConflict {
		t.Fatalf("transport key accepted as watch key: %+v", f.Payload)
	}
	if f, _ := member.call(channel.Payload{Kind: channel.KindWatchKeySet, WatchKey: []byte{1, 2}}); f.Payload.Code != channel.CodeBadRequest {
		t.Fatalf("short watch key accepted: %+v", f.Payload)
	}
	key := r.registerWatchKey(member)

	watch := r.dial(key)
	if watch == nil {
		t.Fatal("watch handshake refused")
	}
	for _, p := range []channel.Payload{
		{Kind: channel.KindEnvelopeFetch, MailboxID: r.mailbox.MailboxID, ReadCapability: r.mailbox.ReadCapability},
		{Kind: channel.KindEnvelopeAck, MailboxID: r.mailbox.MailboxID, ReadCapability: r.mailbox.ReadCapability, DeliveryIDs: [][]byte{[]byte("x")}},
		{Kind: channel.KindEnvelopePut, MailboxID: r.mailbox.MailboxID, WriteCapability: r.mailbox.WriteCapability, DeliveryID: []byte("x"), HpkeEnc: []byte("e"), Ciphertext: []byte("c")},
		{Kind: channel.KindMailboxCreate},
		{Kind: channel.KindKeyPackagesStatus},
		{Kind: channel.KindManifestGet, IdentityID: r.id},
		{Kind: channel.KindInviteRedeem, Token: []byte("t")},
		{Kind: channel.KindPairBegin},
		{Kind: channel.KindNotifyHintSet, URL: "https://example.org/x"},
		{Kind: channel.KindWatchKeySet, WatchKey: key.Public},
		{Kind: channel.KindBlobUploadBegin, Size: 10},
	} {
		f, size := watch.call(p)
		if f.Payload.Code != channel.CodeForbidden {
			t.Errorf("%s on a watch session: %+v", p.Kind, f.Payload)
		}
		if size != channel.WatchFrameBytes {
			t.Errorf("%s refusal is %d bytes, want %d", p.Kind, size, channel.WatchFrameBytes)
		}
	}
	pong, size := watch.call(channel.Payload{Kind: channel.KindPing})
	if pong.Payload.Kind != channel.KindPong || size != channel.WatchFrameBytes {
		t.Fatalf("pong %+v, %d bytes", pong.Payload, size)
	}
	ack, size := watch.call(channel.Payload{Kind: channel.KindMailboxWatch})
	if ack.Payload.Kind != channel.KindAck || size != channel.WatchFrameBytes {
		t.Fatalf("watch ack %+v, %d bytes", ack.Payload, size)
	}
	// Nothing waiting, nothing said.
	if f, _, ok := watch.recv(200 * time.Millisecond); ok {
		t.Fatalf("notice on an empty mailbox: %+v", f)
	}
	r.put(member, "d1")
	wake, size, ok := watch.recv(2 * time.Second)
	if !ok || wake.ID != 0 || wake.Payload.Kind != channel.KindMailboxWakeup || size != channel.WatchFrameBytes {
		t.Fatalf("notice %+v, %d bytes, ok %v", wake, size, ok)
	}
	// Only the empty to non-empty transition is announced.
	r.put(member, "d2")
	if f, _, ok := watch.recv(200 * time.Millisecond); ok {
		t.Fatalf("second notice for a mailbox already holding mail: %+v", f)
	}
}

func TestWatchRecoversReplacesAndEndsOnRevocation(t *testing.T) {
	r := newWatchRig(t)
	member := r.dial(r.static)
	key := r.registerWatchKey(member)
	r.put(member, "d1")

	// Mail already waiting: the subscription is told at once.
	first := r.dial(key)
	first.call(channel.Payload{Kind: channel.KindMailboxWatch})
	if f, _, ok := first.recv(2 * time.Second); !ok || f.Payload.Kind != channel.KindMailboxWakeup {
		t.Fatalf("no notice for waiting mail: %+v", f)
	}

	// A second subscription replaces the first, which closes.
	second := r.dial(key)
	second.call(channel.Payload{Kind: channel.KindMailboxWatch})
	if f, _, ok := second.recv(2 * time.Second); !ok || f.Payload.Kind != channel.KindMailboxWakeup {
		t.Fatalf("replacement not told of waiting mail: %+v", f)
	}
	if f, _, ok := first.recv(2 * time.Second); ok {
		t.Fatalf("replaced watch session still open: %+v", f)
	}

	// Revoking the device ends its watch session and refuses its key.
	ctx := context.Background()
	if _, err := r.db.SetCredentialStatus(ctx, r.id, [][]byte{r.cred}, "revoked"); err != nil {
		t.Fatal(err)
	}
	r.srv.recheckWatchers(ctx, r.id, time.Now())
	if f, _, ok := second.recv(2 * time.Second); ok {
		t.Fatalf("watch session of a revoked device still open: %+v", f)
	}
	if again := r.dial(key); again != nil {
		t.Fatal("watch key of a revoked device completed a handshake")
	}
}

func TestMemberSessionCanWatch(t *testing.T) {
	r := newWatchRig(t)
	sender := r.dial(r.static)
	watcher := r.dial(r.static)
	if f, _ := watcher.call(channel.Payload{Kind: channel.KindMailboxWatch}); f.Payload.Kind != channel.KindAck {
		t.Fatalf("member watch refused: %+v", f.Payload)
	}
	r.put(sender, "d1")
	if f, _, ok := watcher.recv(2 * time.Second); !ok || f.ID != 0 || f.Payload.Kind != channel.KindMailboxWakeup {
		t.Fatalf("member session not told: %+v", f)
	}
	// The member session keeps working as one.
	if f, _ := watcher.call(channel.Payload{Kind: channel.KindEnvelopeFetch, MailboxID: r.mailbox.MailboxID,
		ReadCapability: r.mailbox.ReadCapability, Limit: 10}); f.Payload.Kind != channel.KindEnvelopes {
		t.Fatalf("fetch after watching: %+v", f.Payload)
	}
}

func TestEncodePaddedReachesTheSize(t *testing.T) {
	for _, p := range []channel.Payload{
		{Kind: channel.KindPing}, {Kind: channel.KindAck},
		{Kind: channel.KindMailboxWakeup},
		{Kind: channel.KindError, Code: channel.CodeForbidden, Message: "not allowed on a watch session"},
	} {
		for _, id := range []uint64{0, 1, 300, 1 << 40} {
			b, err := channel.EncodePadded(channel.Frame{ID: id, Payload: p}, channel.WatchFrameBytes)
			if err != nil {
				t.Fatal(err)
			}
			if len(b) != channel.WatchFrameBytes {
				t.Errorf("%s id %d: %d bytes", p.Kind, id, len(b))
			}
			f, err := channel.Decode(b)
			if err != nil || f.ID != id || f.Payload.Kind != p.Kind {
				t.Errorf("padded %s does not decode: %v %+v", p.Kind, err, f)
			}
		}
	}
}

func TestWatchKeyRotationAndRepeatedSubscription(t *testing.T) {
	r := newWatchRig(t)
	member := r.dial(r.static)
	// The member session subscribes too, as macOS does.
	if f, _ := member.call(channel.Payload{Kind: channel.KindMailboxWatch}); f.Payload.Kind != channel.KindAck {
		t.Fatalf("member watch: %+v", f.Payload)
	}
	old := r.registerWatchKey(member)
	watch := r.dial(old)
	watch.call(channel.Payload{Kind: channel.KindMailboxWatch})
	// Subscribing again on the same session keeps it, and it still hears.
	if f, _ := watch.call(channel.Payload{Kind: channel.KindMailboxWatch}); f.Payload.Kind != channel.KindAck {
		t.Fatalf("repeated watch: %+v", f.Payload)
	}
	other := r.dial(r.static)
	r.put(other, "d1")
	if f, _, ok := watch.recv(2 * time.Second); !ok || f.Payload.Kind != channel.KindMailboxWakeup {
		t.Fatalf("watch session lost its subscription: %+v %v", f, ok)
	}
	// A new key ends the session still holding the old one.
	r.registerWatchKey(member)
	if f, _, ok := watch.recv(2 * time.Second); ok {
		t.Fatalf("session with a replaced key still open: %+v", f)
	}
	if again := r.dial(old); again != nil {
		again.call(channel.Payload{Kind: channel.KindPing})
		if f, _ := again.call(channel.Payload{Kind: channel.KindWatchKeySet}); f.Payload.Code != channel.CodeUnauthorized && f.Payload.Code != channel.CodeForbidden {
			t.Fatalf("replaced key still acts: %+v", f.Payload)
		}
	}
}

func TestRemovingTheWatchKeyLeavesAMemberSubscription(t *testing.T) {
	r := newWatchRig(t)
	member := r.dial(r.static)
	r.registerWatchKey(member)
	watcher := r.dial(r.static)
	watcher.call(channel.Payload{Kind: channel.KindMailboxWatch})
	if f, _ := member.call(channel.Payload{Kind: channel.KindWatchKeySet}); f.Payload.Kind != channel.KindAck {
		t.Fatalf("removing the key: %+v", f.Payload)
	}
	r.put(member, "d1")
	if f, _, ok := watcher.recv(2 * time.Second); !ok || f.Payload.Kind != channel.KindMailboxWakeup {
		t.Fatalf("member subscription ended with the watch key: %+v %v", f, ok)
	}
}
