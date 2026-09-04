package store

import (
	"bytes"
	"errors"
	"testing"
	"time"
)

func TestRendezvousSlotsAreWriteOnceAndExpire(t *testing.T) {
	s, ctx, now := memberStore(t)
	id, cap, expires, err := s.BeginPair(ctx, now, time.Minute)
	if err != nil || expires != now.Add(time.Minute).Unix() {
		t.Fatalf("begin: %v", err)
	}
	// Nothing there yet, and a wrong capability is not told anything else.
	if got, err := s.GetPair(ctx, id, cap, "a", now); err != nil || got != nil {
		t.Fatalf("empty slot: %x %v", got, err)
	}
	if _, err := s.GetPair(ctx, id, bytes.Repeat([]byte{9}, 32), "a", now); !errors.Is(err, ErrPairUnknown) {
		t.Fatalf("wrong capability: %v", err)
	}
	if err := s.PutPair(ctx, id, cap, "z", []byte("x"), now); !errors.Is(err, ErrPairSlot) {
		t.Fatalf("bad slot: %v", err)
	}
	if err := s.PutPair(ctx, id, cap, "a", make([]byte, MaxPairData+1), now); !errors.Is(err, ErrPairSize) {
		t.Fatalf("oversize: %v", err)
	}
	if err := s.PutPair(ctx, id, cap, "a", []byte("hello"), now); err != nil {
		t.Fatal(err)
	}
	// Idempotent for the same bytes, a conflict for anything else.
	if err := s.PutPair(ctx, id, cap, "a", []byte("hello"), now); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if err := s.PutPair(ctx, id, cap, "a", []byte("other"), now); !errors.Is(err, ErrPairTaken) {
		t.Fatalf("overwrite: %v", err)
	}
	got, err := s.GetPair(ctx, id, cap, "a", now)
	if err != nil || string(got) != "hello" {
		t.Fatalf("read back: %q %v", got, err)
	}
	// Expired: gone for readers, then swept with its slots.
	later := now.Add(2 * time.Minute)
	if _, err := s.GetPair(ctx, id, cap, "a", later); !errors.Is(err, ErrPairUnknown) {
		t.Fatalf("expired rendezvous readable: %v", err)
	}
	n, err := s.SweepPairs(ctx, later)
	if err != nil || n != 1 {
		t.Fatalf("sweep: %d %v", n, err)
	}
	if left, err := s.Count(ctx, "rendezvous_slots"); err != nil || left != 0 {
		t.Fatalf("slots left: %d %v", left, err)
	}
}

func TestRendezvousAreBounded(t *testing.T) {
	s, ctx, now := memberStore(t)
	for i := 0; i < MaxOpenRendezvous; i++ {
		if _, _, _, err := s.BeginPair(ctx, now, time.Minute); err != nil {
			t.Fatalf("begin %d: %v", i, err)
		}
	}
	if _, _, _, err := s.BeginPair(ctx, now, time.Minute); !errors.Is(err, ErrPairBusy) {
		t.Fatalf("unbounded: %v", err)
	}
	// They stop counting once expired.
	if _, _, _, err := s.BeginPair(ctx, now.Add(2*time.Minute), time.Minute); err != nil {
		t.Fatalf("after expiry: %v", err)
	}
}
