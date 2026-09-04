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
