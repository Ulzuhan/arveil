package store

import (
	"bytes"
	"errors"
	"testing"
	"time"
)

func TestWatchKeyLifecycle(t *testing.T) {
	s, ctx, now := memberStore(t)
	e := enrollment(1)
	key := bytes.Repeat([]byte{0xAA}, WatchKeyBytes)
	// The fixture's transport key is short; the server test covers a real
	// transport key offered as a watch key.
	if err := s.SetWatchKey(ctx, e.IdentityID, e.DeviceID, e.TransportKey, now); !errors.Is(err, ErrWatchKeyShape) {
		t.Fatalf("short key accepted: %v", err)
	}
	if err := s.SetWatchKey(ctx, e.IdentityID, e.DeviceID, key, now); err != nil {
		t.Fatal(err)
	}
	if err := s.SetWatchKey(ctx, e.IdentityID, []byte("another device"), key, now); !errors.Is(err, ErrWatchKeyInUse) {
		t.Fatalf("one watch key for two devices: %v", err)
	}
	d, found, err := s.DeviceByWatchKey(ctx, key, now)
	if err != nil || !found || d == nil || !bytes.Equal(d.DeviceID, e.DeviceID) {
		t.Fatalf("lookup: %v %v %+v", err, found, d)
	}
	var created int64
	if err := s.db.QueryRow(`SELECT created_at FROM watch_keys`).Scan(&created); err != nil || created%3600 != 0 {
		t.Fatalf("created_at %d kept to the second: %v", created, err)
	}
	// An expired credential leaves the key registered but refused.
	if _, found, _ := s.DeviceByWatchKey(ctx, key, now.Add(24*365*time.Hour*10)); !found {
		t.Fatal("registered key reported unknown")
	}
	// Revocation forgets the key.
	if _, err := s.RevokeCredentials(ctx, e.IdentityID, [][]byte{e.CredentialHash}); err != nil {
		t.Fatal(err)
	}
	if d, found, err := s.DeviceByWatchKey(ctx, key, now); err != nil || found || d != nil {
		t.Fatalf("revoked device's watch key survived: %v %v %+v", err, found, d)
	}
	if err := s.SetWatchKey(ctx, e.IdentityID, e.DeviceID, nil, now); err != nil {
		t.Fatal(err)
	}
}

func TestTransportKeyCannotBeAWatchKey(t *testing.T) {
	s, ctx, now := memberStore(t)
	key := bytes.Repeat([]byte{0xBB}, WatchKeyBytes)
	if err := s.SetWatchKey(ctx, enrollment(1).IdentityID, enrollment(1).DeviceID, key, now); err != nil {
		t.Fatal(err)
	}
	e := enrollment(2)
	e.TransportKey = key
	if err := s.CreateInvite(ctx, []byte("u"), "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, []byte("u"), now, e, nil); !errors.Is(err, ErrDeviceKeyInUse) {
		t.Fatalf("a watch key became a transport key: %v", err)
	}
}

// A device id is signed only by its own root, so a member could reuse
// another identity's: the realm refuses it, and nothing keyed by device id
// can be claimed across identities.
func TestDeviceIDBelongsToOneIdentity(t *testing.T) {
	s, ctx, now := memberStore(t)
	victim := enrollment(1)
	e := enrollment(2)
	e.DeviceID = victim.DeviceID
	if err := s.CreateInvite(ctx, []byte("u"), "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, []byte("u"), now, e, nil); !errors.Is(err, ErrDeviceKeyInUse) {
		t.Fatalf("another identity enrolled with the victim's device id: %v", err)
	}
}
