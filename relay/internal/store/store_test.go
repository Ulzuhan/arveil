package store

import (
	"context"
	"errors"
	"path/filepath"
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

func TestRedeemInviteAnswersARepeatWithoutConsumingAnotherUse(t *testing.T) {
	ctx := context.Background()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now()
	token := []byte("token-hash")
	// Two uses, so an accidental second consumption would go unnoticed if
	// the count were all this checked.
	if err := s.CreateInvite(ctx, token, "member", now.Add(time.Hour), 2); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, token, now, enrollment(1), nil); err != nil {
		t.Fatal(err)
	}

	// The same token, identity and credential: the work was done, and
	// saying so is not the same as doing it again.
	if err := s.RedeemInvite(ctx, token, now, enrollment(1), nil); !errors.Is(err, ErrAlreadyRedeemed) {
		t.Fatalf("a repeat should be recognised, got %v", err)
	}
	for _, table := range []string{"realm_memberships", "device_credentials", "device_manifests"} {
		if n, _ := s.Count(ctx, table); n != 1 {
			t.Fatalf("%s has %d rows after a repeated redeem", table, n)
		}
	}

	// The second use is still there for somebody else.
	if err := s.RedeemInvite(ctx, token, now, enrollment(2), nil); err != nil {
		t.Fatalf("the untouched use should still redeem: %v", err)
	}
	if err := s.RedeemInvite(ctx, token, now, enrollment(3), nil); !errors.Is(err, ErrInviteInvalid) {
		t.Fatalf("a third redeem of a two-use invite: %v", err)
	}
}

func TestRedeemInviteRefusesAnotherCredentialForTheSameIdentity(t *testing.T) {
	ctx := context.Background()
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now()
	token := []byte("token-hash")
	if err := s.CreateInvite(ctx, token, "member", now.Add(time.Hour), 5); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, token, now, enrollment(1), nil); err != nil {
		t.Fatal(err)
	}

	// Same identity, different credential: this is a second device asking,
	// not the first one asking twice, and it is refused rather than handed
	// the earlier answer.
	other := enrollment(1)
	other.CredentialHash = []byte{9, 9}
	other.TransportKey = []byte{9, 5}
	if err := s.RedeemInvite(ctx, token, now, other, nil); !errors.Is(err, ErrAlreadyMember) {
		t.Fatalf("another credential should conflict, got %v", err)
	}
}

func TestOpenRefusesADatabaseFromANewerRelay(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(
		`INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)`,
		SchemaVersion+1, time.Now().Unix()); err != nil {
		t.Fatal(err)
	}
	s.Close()

	// Nothing is modified: an older binary cannot know what it would break.
	if _, err := Open(path); !errors.Is(err, ErrSchemaTooNew) {
		t.Fatalf("expected a refusal, got %v", err)
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

func TestRevokeCredentialsInvalidatesMailboxes(t *testing.T) {
	s, ctx, now := memberStore(t)
	e := enrollment(1)
	mb, err := s.CreateMailbox(ctx, e.IdentityID, e.DeviceID, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.CheckCapability(ctx, mb.MailboxID, mb.WriteCapability, ScopeWrite, now); err != nil {
		t.Fatal(err)
	}
	n, err := s.RevokeCredentials(ctx, e.IdentityID, [][]byte{e.CredentialHash, []byte("unknown")})
	if err != nil || n != 1 {
		t.Fatalf("revoke: %d %v", n, err)
	}
	if err := s.CheckCapability(ctx, mb.MailboxID, mb.WriteCapability, ScopeWrite, now); !errors.Is(err, ErrCapability) {
		t.Fatalf("capability survived revocation: %v", err)
	}
	d, _ := s.DeviceByTransportKey(ctx, e.TransportKey)
	if d == nil || d.Status != "revoked" {
		t.Fatalf("credential not revoked: %+v", d)
	}
	n, _ = s.RevokeCredentials(ctx, e.IdentityID, [][]byte{e.CredentialHash})
	if n != 0 {
		t.Fatalf("second revoke changed %d", n)
	}
}

func TestLatestManifestAndCredentialStatus(t *testing.T) {
	s, ctx, _ := memberStore(t)
	e := enrollment(1)
	seq, signed, err := s.LatestManifest(ctx, e.IdentityID)
	if err != nil || seq != e.ManifestSeq || string(signed) != string(e.SignedManifest) {
		t.Fatalf("latest manifest: %d %v", seq, err)
	}
	if _, _, err := s.LatestManifest(ctx, []byte("nobody")); err != nil {
		t.Fatal(err)
	}
	n, err := s.SetCredentialStatus(ctx, e.IdentityID, [][]byte{e.CredentialHash}, "revoked")
	if err != nil || n != 1 {
		t.Fatalf("revoke: %d %v", n, err)
	}
	d, err := s.DeviceByTransportKey(ctx, e.TransportKey)
	if err != nil || d == nil || d.Status != "revoked" {
		t.Fatalf("status not applied: %+v %v", d, err)
	}
	// Idempotent and scoped to the identity.
	n, _ = s.SetCredentialStatus(ctx, e.IdentityID, [][]byte{e.CredentialHash}, "revoked")
	if n != 0 {
		t.Fatalf("second revoke changed %d rows", n)
	}
}
