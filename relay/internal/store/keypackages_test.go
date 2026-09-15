package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestKeyPackagesPublishAndClaimOnce(t *testing.T) {
	s, ctx, now := memberStore(t)
	id, dev := []byte{1, 1}, []byte{1, 4}
	if err := s.PublishKeyPackages(ctx, id, dev, [][]byte{[]byte("kp1"), []byte("kp2"), []byte("kp1")}, now); err != nil {
		t.Fatal(err)
	}
	n, _ := s.AvailableKeyPackages(ctx, dev)
	if n != 2 {
		t.Fatalf("available %d, want 2 (duplicate ignored)", n)
	}
	a, err := s.ClaimKeyPackage(ctx, id, nil)
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.ClaimKeyPackage(ctx, id, nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(a) == string(b) {
		t.Fatal("same package claimed twice")
	}
	if _, err := s.ClaimKeyPackage(ctx, id, nil); !errors.Is(err, ErrNoKeyPackage) {
		t.Fatalf("third claim: %v", err)
	}
	if _, err := s.ClaimKeyPackage(ctx, []byte("nobody"), nil); !errors.Is(err, ErrNoKeyPackage) {
		t.Fatalf("unknown identity: %v", err)
	}
	big := make([][]byte, MaxKeyPackagesPerDevice+1)
	for i := range big {
		big[i] = []byte{byte(i), 1}
	}
	if err := s.PublishKeyPackages(ctx, id, dev, big, now); !errors.Is(err, ErrKeyPackageBatch) {
		t.Fatalf("batch bound: %v", err)
	}
	_ = context.Background()
	_ = time.Now()
}

func TestKeyPackageRetriesAtCapacityDoNotReviveConsumedPackages(t *testing.T) {
	s, ctx, now := memberStore(t)
	id, dev := []byte{1, 1}, []byte{1, 4}
	batch := make([][]byte, MaxKeyPackagesPerDevice)
	for i := range batch {
		batch[i] = []byte{byte(i), 1}
	}
	for attempt := 0; attempt < 2; attempt++ {
		if err := s.PublishKeyPackages(ctx, id, dev, batch, now); err != nil {
			t.Fatalf("attempt %d: %v", attempt, err)
		}
	}
	consumed, err := s.ClaimKeyPackage(ctx, id, dev)
	if err != nil {
		t.Fatal(err)
	}
	// 49 existing entries, one duplicate, and one genuinely new entry.
	if err := s.PublishKeyPackages(ctx, id, dev, [][]byte{batch[1], []byte("new"), []byte("new")}, now); err != nil {
		t.Fatal(err)
	}
	if err := s.PublishKeyPackages(ctx, id, dev, [][]byte{consumed}, now); err != nil {
		t.Fatalf("retry of consumed package: %v", err)
	}
	for i := 0; i < MaxKeyPackagesPerDevice; i++ {
		p, err := s.ClaimKeyPackage(ctx, id, dev)
		if err != nil {
			t.Fatal(err)
		}
		if string(p) == string(consumed) {
			t.Fatal("retry revived a consumed package")
		}
	}
	if _, err := s.ClaimKeyPackage(ctx, id, dev); !errors.Is(err, ErrNoKeyPackage) {
		t.Fatalf("expected all packages consumed: %v", err)
	}
}

func TestKeyPackageOverflowRollsBackWholeBatch(t *testing.T) {
	s, ctx, now := memberStore(t)
	id, dev := []byte{1, 1}, []byte{1, 4}
	batch := make([][]byte, MaxKeyPackagesPerDevice-1)
	for i := range batch {
		batch[i] = []byte{byte(i), 1}
	}
	if err := s.PublishKeyPackages(ctx, id, dev, batch, now); err != nil {
		t.Fatal(err)
	}
	if err := s.PublishKeyPackages(ctx, id, dev, [][]byte{[]byte("new-a"), []byte("new-b")}, now); !errors.Is(err, ErrKeyPackageBatch) {
		t.Fatalf("expected quota rejection: %v", err)
	}
	n, err := s.AvailableKeyPackages(ctx, dev)
	if err != nil || n != MaxKeyPackagesPerDevice-1 {
		t.Fatalf("overflow partially committed: count=%d err=%v", n, err)
	}
}
