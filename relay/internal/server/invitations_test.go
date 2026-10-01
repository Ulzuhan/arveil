package server

import (
	"bytes"
	"context"
	"encoding/binary"
	"github.com/Ulzuhan/arveil/relay/internal/channel"
	"github.com/Ulzuhan/arveil/relay/internal/limits"
	"github.com/Ulzuhan/arveil/relay/internal/store"
	"path/filepath"
	"testing"
	"time"
)

func TestInvitationsRecheckAuthorizationAndBoundAttempts(t *testing.T) {
	ctx := context.Background()
	now := time.Now()
	db, err := store.Open(filepath.Join(t.TempDir(), "realm.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	srv := &Server{Store: db, Limits: limits.New(limits.Config{InvitationsPerAddr: 3})}
	frame := channel.Frame{ID: 1, Payload: channel.Payload{Kind: channel.KindInvitePolicyGet}}
	if got := srv.invitation(ctx, &session{}, frame, now); got.Payload.Code != channel.CodeUnauthorized {
		t.Fatal("provisional session queried policy")
	}
	id := bytes.Repeat([]byte{1}, 32)
	cred := bytes.Repeat([]byte{2}, 32)
	e := store.Enrollment{IdentityID: id, RootPublic: id, CredentialHash: cred, DeviceID: bytes.Repeat([]byte{3}, 16), TransportKey: bytes.Repeat([]byte{4}, 32), SignedCred: []byte{5}, NotAfter: now.Add(time.Hour).Unix(), ManifestSeq: 1, SignedManifest: []byte{6}}
	if err = db.CreateInvite(ctx, id, "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err = db.RedeemInvite(ctx, id, now, e, nil); err != nil {
		t.Fatal(err)
	}
	member := func() *session {
		return &session{device: &store.Device{CredentialHash: cred}, addr: "same-test-address"}
	}
	if got := srv.invitation(ctx, member(), frame, now); got.Payload.Kind != channel.KindInvitePolicy || got.Payload.CanInvite {
		t.Fatal("member permission")
	}
	key := make([]byte, 24)
	binary.BigEndian.PutUint64(key, uint64(now.Unix()))
	key[23] = 1
	create := channel.Frame{ID: 2, Payload: channel.Payload{Kind: channel.KindInviteCreate, RequestKey: key, TokenHash: bytes.Repeat([]byte{7}, 32), TTL: 60}}
	if got := srv.invitation(ctx, member(), create, now); got.Payload.Code != channel.CodeForbidden {
		t.Fatal("member issued")
	}
	if err = db.MakeOwner(ctx, id, now); err != nil {
		t.Fatal(err)
	}
	ownerSession := member()
	if got := srv.invitation(ctx, ownerSession, create, now); got.Payload.Kind != channel.KindInvitation {
		t.Fatalf("owner issuance: %s", got.Payload.Kind)
	}
	// A new connection cannot evade the shared address budget.
	if got := srv.invitation(ctx, member(), frame, now); got.Payload.Code != channel.CodeQuota {
		t.Fatal("connection reset bypassed limit")
	}
	now = now.Add(61 * time.Second)
	if got := srv.invitation(ctx, ownerSession, frame, now); got.Payload.Kind != channel.KindInvitePolicy {
		t.Fatal("window did not expire")
	}
	if _, err = db.SetCredentialStatus(ctx, id, [][]byte{cred}, "revoked"); err != nil {
		t.Fatal(err)
	}
	if got := srv.invitation(ctx, ownerSession, create, now); got.Payload.Code != channel.CodeForbidden {
		t.Fatal("old authenticated session retained authority")
	}
}
