package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func enrollment(id byte) Enrollment {
	return Enrollment{
		IdentityID:     []byte{id, 1},
		RootPublic:     []byte{id, 2},
		CredentialHash: []byte{id, 3},
		DeviceID:       []byte{id, 4},
		TransportKey:   []byte{id, 5},
		SignedCred:     []byte{id, 6},
		NotAfter:       time.Now().Add(time.Hour).Unix(),
		ManifestSeq:    1,
		SignedManifest: []byte{id, 7},
	}
}

func TestEmbeddedSQLiteMeetsADR004(t *testing.T) {
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	v, n, err := s.SQLiteVersion()
	if err != nil {
		t.Fatal(err)
	}
	if n < MinSQLiteVersionNumber {
		t.Fatalf("embedded SQLite %s (%d) is older than 3.51.3", v, n)
	}
	t.Logf("embedded SQLite %s", v)
}

func TestRedeemInviteIsAtomic(t *testing.T) {
	ctx := context.Background()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now()
	token := []byte("token-hash")
	if err := s.CreateInvite(ctx, token, "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}

	// Failure injected between consuming the invite and creating the
	// membership: nothing may persist, and the invite keeps its use.
	boom := errors.New("crash")
	err = s.RedeemInvite(ctx, token, now, enrollment(1), func() error { return boom })
	if !errors.Is(err, boom) {
		t.Fatalf("expected injected failure, got %v", err)
	}
	for _, table := range []string{"realm_memberships", "device_credentials", "device_manifests"} {
		if n, _ := s.Count(ctx, table); n != 0 {
			t.Fatalf("%s has %d rows after a failed redeem", table, n)
		}
	}

	// Success consumes the single use.
	if err := s.RedeemInvite(ctx, token, now, enrollment(1), nil); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, token, now, enrollment(2), nil); !errors.Is(err, ErrInviteInvalid) {
		t.Fatalf("second redeem of a one-use invite: %v", err)
	}
	d, err := s.DeviceByTransportKey(ctx, []byte{1, 5})
	if err != nil || d == nil || d.Status != "active" {
		t.Fatalf("device lookup: %v %+v", err, d)
	}

	// Expired invite.
	if err := s.CreateInvite(ctx, []byte("old"), "member", now.Add(-time.Minute), 5); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, []byte("old"), now, enrollment(3), nil); !errors.Is(err, ErrInviteInvalid) {
		t.Fatalf("expired invite: %v", err)
	}

	// Manifest ordering.
	if err := s.PutManifest(ctx, []byte{1, 1}, 1, []byte("dup")); !errors.Is(err, ErrManifestOrder) {
		t.Fatalf("same sequence accepted: %v", err)
	}
	if err := s.PutManifest(ctx, []byte{1, 1}, 2, []byte("m2")); err != nil {
		t.Fatal(err)
	}
	seq, _ := s.LatestManifestSequence(ctx, []byte{1, 1})
	if seq != 2 {
		t.Fatalf("latest sequence %d", seq)
	}

	// Same transport key cannot be registered twice.
	e := enrollment(9)
	e.IdentityID = []byte{1, 1}
	e.TransportKey = []byte{1, 5}
	if err := s.PutCredential(ctx, e); !errors.Is(err, ErrDeviceKeyInUse) {
		t.Fatalf("duplicate transport key: %v", err)
	}
}
