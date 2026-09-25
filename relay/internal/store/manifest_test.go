package store

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestPublishedManifestRetrySurvivesRestartAndRejectsForkOrRollback(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	now := time.Now()
	e := enrollment(1)
	if err := s.CreateInvite(ctx, []byte("fixture"), "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, []byte("fixture"), now, e, nil); err != nil {
		t.Fatal(err)
	}
	mb, err := s.CreateMailbox(ctx, e.IdentityID, e.DeviceID, now)
	if err != nil {
		t.Fatal(err)
	}
	signed := []byte("verified manifest 2")
	if n, err := s.PublishManifest(ctx, e.IdentityID, 2, signed, [][]byte{e.CredentialHash}); err != nil || n != 1 {
		t.Fatalf("first publication: %d %v", n, err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	// The caller lost the ACK. Same signed bytes still succeed after restart.
	if n, err := s.PublishManifest(ctx, e.IdentityID, 2, signed, [][]byte{e.CredentialHash}); err != nil || n != 0 {
		t.Fatalf("repeated publication: %d %v", n, err)
	}
	if err := s.CheckCapability(ctx, mb.MailboxID, mb.WriteCapability, ScopeWrite, now); !errors.Is(err, ErrCapability) {
		t.Fatalf("revoked capability survived: %v", err)
	}
	for _, changed := range []struct {
		seq    uint64
		signed []byte
	}{{2, []byte("fork")}, {1, e.SignedManifest}} {
		if _, err := s.PublishManifest(ctx, e.IdentityID, changed.seq, changed.signed, nil); !errors.Is(err, ErrManifestOrder) {
			t.Fatalf("conflicting manifest accepted: %v", err)
		}
	}
	if n, _ := s.Count(ctx, "device_manifests"); n != 2 {
		t.Fatalf("duplicate manifest rows: %d", n)
	}
}

func TestManifestAndCapabilitiesCommitTogetherAndResumeLegacyPartialPublication(t *testing.T) {
	s, ctx, now := memberStore(t)
	e := enrollment(1)
	mb, err := s.CreateMailbox(ctx, e.IdentityID, e.DeviceID, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.ExecContext(ctx, `CREATE TRIGGER fail_revocation BEFORE UPDATE ON capabilities BEGIN SELECT RAISE(ABORT, 'injected failure'); END`); err != nil {
		t.Fatal(err)
	}
	signed := []byte("verified revocation 2")
	if _, err := s.PublishManifest(ctx, e.IdentityID, 2, signed, [][]byte{e.CredentialHash}); err == nil {
		t.Fatal("injected revocation failure was ignored")
	}
	seq, saved, err := s.LatestManifest(ctx, e.IdentityID)
	if err != nil || seq != 1 || !bytes.Equal(saved, e.SignedManifest) {
		t.Fatalf("manifest escaped rollback: %d %v", seq, err)
	}
	device, err := s.DeviceByTransportKey(ctx, e.TransportKey)
	if err != nil || device.Status != "active" {
		t.Fatalf("credential escaped rollback: %v", err)
	}
	if err := s.CheckCapability(ctx, mb.MailboxID, mb.WriteCapability, ScopeWrite, now); err != nil {
		t.Fatalf("capability escaped rollback: %v", err)
	}
	if _, err := s.db.ExecContext(ctx, `DROP TRIGGER fail_revocation`); err != nil {
		t.Fatal(err)
	}
	// An older relay could have stopped between these two independent steps.
	if err := s.PutManifest(ctx, e.IdentityID, 2, signed); err != nil {
		t.Fatal(err)
	}
	if n, err := s.PublishManifest(ctx, e.IdentityID, 2, signed, [][]byte{e.CredentialHash}); err != nil || n != 1 {
		t.Fatalf("legacy partial publication did not resume: %d %v", n, err)
	}
	if err := s.CheckCapability(ctx, mb.MailboxID, mb.ReadCapability, ScopeRead, now); !errors.Is(err, ErrCapability) {
		t.Fatalf("revoked read capability survived: %v", err)
	}
}
