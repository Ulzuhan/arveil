package store

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"
)

func memberStore(t *testing.T) (*Store, context.Context, time.Time) {
	t.Helper()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	ctx := context.Background()
	now := time.Now()
	if err := s.CreateInvite(ctx, []byte("t"), "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, []byte("t"), now, enrollment(1), nil); err != nil {
		t.Fatal(err)
	}
	return s, ctx, now
}

func TestMailboxCapabilitiesAndEnvelopeLifecycle(t *testing.T) {
	s, ctx, now := memberStore(t)
	mb, err := s.CreateMailbox(ctx, []byte{1, 1}, []byte{1, 4}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(mb.MailboxID) != 16 || len(mb.ReadCapability) != 32 || len(mb.WriteCapability) != 32 {
		t.Fatalf("unexpected sizes %+v", mb)
	}

	// Scopes are independent; unknown capabilities fail.
	if err := s.CheckCapability(ctx, mb.MailboxID, mb.WriteCapability, ScopeWrite, now); err != nil {
		t.Fatal(err)
	}
	if err := s.CheckCapability(ctx, mb.MailboxID, mb.WriteCapability, ScopeRead, now); !errors.Is(err, ErrCapability) {
		t.Fatalf("write cap accepted for read: %v", err)
	}
	if err := s.CheckCapability(ctx, mb.MailboxID, bytes.Repeat([]byte{9}, 32), ScopeRead, now); !errors.Is(err, ErrCapability) {
		t.Fatalf("unknown cap accepted: %v", err)
	}

	// Put, idempotent retry, conflicting retry.
	r1, err := s.PutEnvelope(ctx, mb.MailboxID, []byte("d1"), []byte("enc"), []byte("ct"), 0, now)
	if err != nil || r1.Duplicate {
		t.Fatalf("first put: %v %+v", err, r1)
	}
	r2, err := s.PutEnvelope(ctx, mb.MailboxID, []byte("d1"), []byte("enc"), []byte("ct"), 0, now)
	if err != nil || !r2.Duplicate || r2.EffectiveExpiry != r1.EffectiveExpiry {
		t.Fatalf("idempotent retry: %v %+v", err, r2)
	}
	if _, err := s.PutEnvelope(ctx, mb.MailboxID, []byte("d1"), []byte("enc"), []byte("other"), 0, now); !errors.Is(err, ErrDeliveryConflict) {
		t.Fatalf("conflicting retry: %v", err)
	}
	if _, err := s.PutEnvelope(ctx, mb.MailboxID, []byte("big"), []byte("enc"), make([]byte, MaxEnvelopeBytes+1), 0, now); !errors.Is(err, ErrEnvelopeTooBig) {
		t.Fatalf("oversize: %v", err)
	}
	// Requested expiry beyond the TTL is clamped.
	r3, _ := s.PutEnvelope(ctx, mb.MailboxID, []byte("d2"), []byte("enc"), []byte("ct2"), now.Add(400*24*time.Hour).Unix(), now)
	if r3.EffectiveExpiry > now.Add(DefaultEnvelopeTTL).Unix() {
		t.Fatal("expiry not clamped")
	}

	// Fetch with cursor, then ack.
	items, next, err := s.FetchEnvelopes(ctx, mb.MailboxID, 0, 10, now)
	if err != nil || len(items) != 2 || next != items[1].Seq {
		t.Fatalf("fetch: %v %d %d", err, len(items), next)
	}
	again, _, _ := s.FetchEnvelopes(ctx, mb.MailboxID, next, 10, now)
	if len(again) != 0 {
		t.Fatal("cursor did not advance")
	}
	if err := s.AckEnvelopes(ctx, mb.MailboxID, [][]byte{[]byte("d1")}); err != nil {
		t.Fatal(err)
	}
	if err := s.AckEnvelopes(ctx, mb.MailboxID, [][]byte{[]byte("d1")}); err != nil {
		t.Fatal("ack not idempotent")
	}
	rest, _, _ := s.FetchEnvelopes(ctx, mb.MailboxID, 0, 10, now)
	if len(rest) != 1 || string(rest[0].DeliveryID) != "d2" {
		t.Fatalf("after ack: %+v", rest)
	}

	// Expiry sweep.
	n, err := s.ExpireEnvelopes(ctx, now.Add(DefaultEnvelopeTTL+time.Hour))
	if err != nil || n != 1 {
		t.Fatalf("expire: %v %d", err, n)
	}
}

func TestMailboxQueueBound(t *testing.T) {
	s, ctx, now := memberStore(t)
	mb, _ := s.CreateMailbox(ctx, []byte{1, 1}, []byte{1, 4}, now)
	for i := 0; i < MaxMailboxQueue; i++ {
		if _, err := s.PutEnvelope(ctx, mb.MailboxID, []byte{byte(i >> 8), byte(i)}, []byte("e"), []byte("c"), 0, now); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.PutEnvelope(ctx, mb.MailboxID, []byte("overflow"), []byte("e"), []byte("c"), 0, now); !errors.Is(err, ErrMailboxFull) {
		t.Fatalf("queue bound: %v", err)
	}
}

func TestSweepRemovesExpiredEnvelopesAndInvites(t *testing.T) {
	s, ctx, now := memberStore(t)
	mb, _ := s.CreateMailbox(ctx, []byte{1, 1}, []byte{1, 4}, now)
	// Short requested expiry is honoured; a zero request gets the cap.
	if _, err := s.PutEnvelope(ctx, mb.MailboxID, []byte("short"), []byte("e"), []byte("c"), now.Add(2*time.Second).Unix(), now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.PutEnvelope(ctx, mb.MailboxID, []byte("long"), []byte("e"), []byte("c"), 0, now); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateInvite(ctx, []byte("stale"), "member", now.Add(-time.Second), 1); err != nil {
		t.Fatal(err)
	}
	r, err := s.Sweep(ctx, now.Add(3*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if r.Envelopes != 1 || r.Invites != 2 { // "stale" plus the consumed invite from memberStore
		t.Fatalf("sweep removed %+v", r)
	}
	left, _, _ := s.FetchEnvelopes(ctx, mb.MailboxID, 0, 10, now.Add(3*time.Second))
	if len(left) != 1 || string(left[0].DeliveryID) != "long" {
		t.Fatalf("after sweep: %+v", left)
	}
}

func TestCreateMailboxForRequestIsRepeatable(t *testing.T) {
	s, ctx, now := memberStore(t)
	identity, device := []byte{1, 1}, []byte{1, 4}
	request := []byte("request-key-0001")
	read, write := make([]byte, 32), make([]byte, 32)
	for i := range read {
		read[i], write[i] = byte(i), byte(255-i)
	}

	first, err := s.CreateMailboxForRequest(ctx, identity, device, request, read, write, now)
	if err != nil {
		t.Fatal(err)
	}

	// The same request returns the same mailbox and the same capabilities,
	// which is what keeps a route that already embeds one working.
	again, err := s.CreateMailboxForRequest(ctx, identity, device, request, read, write, now)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.MailboxID, again.MailboxID) ||
		!bytes.Equal(first.WriteCapability, again.WriteCapability) {
		t.Fatal("a repeat produced a different mailbox")
	}
	if n, _ := s.Count(ctx, "mailboxes"); n != 1 {
		t.Fatalf("%d mailboxes after a repeated request", n)
	}
	if n, _ := s.Count(ctx, "capabilities"); n != 2 {
		t.Fatalf("%d capabilities after a repeated request", n)
	}

	// Everything the capability lets a peer do still works afterwards.
	if err := s.CheckCapability(ctx, first.MailboxID, write, ScopeWrite, now); err != nil {
		t.Fatalf("the write capability stopped working: %v", err)
	}

	// The same key with other capabilities is a different request wearing
	// the same name.
	other := make([]byte, 32)
	other[0] = 7
	if _, err := s.CreateMailboxForRequest(ctx, identity, device, request, read, other, now); !errors.Is(err, ErrRequestConflict) {
		t.Fatalf("other capabilities should conflict, got %v", err)
	}

	// And another device may not claim a key it does not own.
	if _, err := s.CreateMailboxForRequest(ctx, identity, []byte{1, 9}, request, read, write, now); !errors.Is(err, ErrRequestConflict) {
		t.Fatalf("another device should conflict, got %v", err)
	}

	// A capability already promised to one mailbox is not shared with
	// another: hash equality is not authorisation.
	if _, err := s.CreateMailboxForRequest(ctx, identity, device, []byte("request-key-0002"), read, write, now); !errors.Is(err, ErrCapabilityInUse) {
		t.Fatalf("a reused capability should conflict, got %v", err)
	}
}
