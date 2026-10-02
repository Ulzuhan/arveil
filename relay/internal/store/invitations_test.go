package store

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/binary"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func requestKey(now time.Time, id byte) []byte {
	k := make([]byte, 24)
	binary.BigEndian.PutUint64(k, uint64(now.Unix()))
	k[23] = id
	return k
}
func invitationFixture(t *testing.T) (*Store, Enrollment, Enrollment, time.Time) {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "realm.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	now := time.Now()
	a, b := enrollment(31), enrollment(32)
	for _, e := range []Enrollment{a, b} {
		if err = s.CreateInvite(context.Background(), e.IdentityID, "member", now.Add(time.Hour), 1); err != nil {
			t.Fatal(err)
		}
		if err = s.RedeemInvite(context.Background(), e.IdentityID, now, e, nil); err != nil {
			t.Fatal(err)
		}
	}
	if err = s.MakeOwner(context.Background(), a.IdentityID, now); err != nil {
		t.Fatal(err)
	}
	return s, a, b, now
}
func TestPersonalInvitationPermissionsReplayAndRevocation(t *testing.T) {
	s, a, b, now := invitationFixture(t)
	ctx := context.Background()
	hash := bytes.Repeat([]byte{4}, 32)
	key := requestKey(now, 1)
	if _, err := s.IssueInvitation(ctx, b.CredentialHash, key, hash, 3600, now); !errors.Is(err, ErrInvitePermission) {
		t.Fatalf("member issued: %v", err)
	}
	if _, err := s.db.Exec(`UPDATE realm_memberships SET role='admin' WHERE identity_id=?`, b.IdentityID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.IssueInvitation(ctx, b.CredentialHash, key, hash, 3600, now); !errors.Is(err, ErrInvitePermission) {
		t.Fatalf("legacy admin issued: %v", err)
	}
	first, err := s.IssueInvitation(ctx, a.CredentialHash, key, hash, 3600, now)
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.IssueInvitation(ctx, a.CredentialHash, key, hash, 3600, now.Add(time.Minute))
	if err != nil || second.Sequence != first.Sequence || second.ExpiresAt != first.ExpiresAt {
		t.Fatalf("retry changed result: %+v %v", second, err)
	}
	if _, err = s.IssueInvitation(ctx, a.CredentialHash, key, hash, 3601, now); !errors.Is(err, ErrRequestConflict) {
		t.Fatal(err)
	}
	if list, err := s.ListInvitations(ctx, b.CredentialHash, 0, 50, now); err != nil || len(list) != 0 {
		t.Fatalf("issuer privacy: %v %v", list, err)
	}
	if _, err = s.RevokeInvitation(ctx, b.CredentialHash, hash, now); !errors.Is(err, ErrInvitePermission) {
		t.Fatal(err)
	}
	if _, err = s.RevokeInvitation(ctx, a.CredentialHash, hash, now); err != nil {
		t.Fatal(err)
	}
	if _, err = s.RevokeInvitation(ctx, a.CredentialHash, hash, now); err != nil {
		t.Fatal(err)
	}
	if _, err = s.AcceptInvitation(ctx, b.CredentialHash, hash, now); !errors.Is(err, ErrInviteInvalid) {
		t.Fatal(err)
	}
	if err = s.RedeemInvite(ctx, hash, now, enrollment(33), nil); !errors.Is(err, ErrInviteInvalid) {
		t.Fatal(err)
	}
	if _, err = s.db.Exec(`UPDATE device_credentials SET status='revoked' WHERE credential_hash=?`, a.CredentialHash); err != nil {
		t.Fatal(err)
	}
	if _, err = s.InvitationPolicy(ctx, a.CredentialHash, now); !errors.Is(err, ErrInvitePermission) {
		t.Fatal(err)
	}
}
func TestPersonalInvitationExistingMemberSpendsUseAndKeepsRole(t *testing.T) {
	s, a, b, now := invitationFixture(t)
	ctx := context.Background()
	hash := bytes.Repeat([]byte{7}, 32)
	if _, err := s.IssueInvitation(ctx, a.CredentialHash, requestKey(now, 2), hash, 60, now); err != nil {
		t.Fatal(err)
	}
	i, err := s.AcceptInvitation(ctx, b.CredentialHash, hash, now)
	if err != nil || i.State != "used" {
		t.Fatal(i, err)
	}
	// A delayed repeat remains the same result after expiry and sweep.
	if _, err = s.Sweep(ctx, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	i, err = s.AcceptInvitation(ctx, b.CredentialHash, hash, now.Add(10*time.Minute))
	if err != nil || !bytes.Equal(i.ClaimedIdentity, b.IdentityID) {
		t.Fatal(i, err)
	}
	if _, err = s.RevokeInvitation(ctx, a.CredentialHash, hash, now); !errors.Is(err, ErrInviteUsed) {
		t.Fatal(err)
	}
	if err = s.RedeemInvite(ctx, hash, now, enrollment(35), nil); !errors.Is(err, ErrInviteInvalid) {
		t.Fatal(err)
	}
	var role string
	if err = s.db.QueryRow(`SELECT role FROM realm_memberships WHERE identity_id=?`, b.IdentityID).Scan(&role); err != nil || role != "member" {
		t.Fatal(role, err)
	}
	var n int
	if err = s.db.QueryRow(`SELECT COUNT(*) FROM realm_memberships`).Scan(&n); err != nil || n != 2 {
		t.Fatal(n, err)
	}
}
func TestPersonalInvitationRedeemAndRevokeRace(t *testing.T) {
	s, a, b, now := invitationFixture(t)
	ctx := context.Background()
	for index := byte(1); index <= 10; index++ {
		hash := bytes.Repeat([]byte{index}, 32)
		if _, err := s.IssueInvitation(ctx, a.CredentialHash, requestKey(now, index), hash, 3600, now); err != nil {
			t.Fatal(err)
		}
		var accepted, revoked error
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); _, accepted = s.AcceptInvitation(ctx, b.CredentialHash, hash, now) }()
		go func() { defer wg.Done(); _, revoked = s.RevokeInvitation(ctx, a.CredentialHash, hash, now) }()
		wg.Wait()
		if (accepted == nil) == (revoked == nil) {
			t.Fatalf("need exactly one winner: %v %v", accepted, revoked)
		}
	}
}
func TestPersonalInvitationNewEnrollmentReceiptSurvivesSweep(t *testing.T) {
	s, a, _, now := invitationFixture(t)
	ctx := context.Background()
	hash := bytes.Repeat([]byte{8}, 32)
	e := enrollment(40)
	if _, err := s.IssueInvitation(ctx, a.CredentialHash, requestKey(now, 1), hash, 60, now); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, hash, now, e, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Sweep(ctx, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	i, err := s.GetInvitation(ctx, a.CredentialHash, hash, now)
	if err != nil || i.State != "used" || !bytes.Equal(i.ClaimedIdentity, e.IdentityID) {
		t.Fatal(i, err)
	}
	if err = s.RedeemInvite(ctx, hash, now.Add(time.Hour), e, nil); !errors.Is(err, ErrAlreadyRedeemed) {
		t.Fatal(err)
	}
}
func TestPersonalInvitationQuotaAndStaleRequest(t *testing.T) {
	s, a, _, now := invitationFixture(t)
	ctx := context.Background()
	for i := byte(0); i < InvitationDailyLimit; i++ {
		if _, err := s.IssueInvitation(ctx, a.CredentialHash, requestKey(now, i), bytes.Repeat([]byte{i}, 32), 60, now); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.IssueInvitation(ctx, a.CredentialHash, requestKey(now, 90), bytes.Repeat([]byte{90}, 32), 60, now); !errors.Is(err, ErrInviteQuota) {
		t.Fatal(err)
	}
	if _, err := s.Sweep(ctx, now.Add(50*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	// Extend the fixture's credentials so the request-age guard is what fails.
	if _, err := s.db.Exec(`UPDATE device_credentials SET not_after=?`, now.Add(100*24*time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	if _, err := s.IssueInvitation(ctx, a.CredentialHash, requestKey(now, 0), bytes.Repeat([]byte{0}, 32), 60, now.Add(50*24*time.Hour)); !errors.Is(err, ErrInviteInvalid) {
		t.Fatal(err)
	}
}
func TestKeyPackageReplyIsDurableAndBoundToClaimantAndTarget(t *testing.T) {
	s, a, b, now := invitationFixture(t)
	ctx := context.Background()
	id := bytes.Repeat([]byte{42}, 32)
	device := bytes.Repeat([]byte{43}, 16)
	// Match a production-sized target while keeping the fixture credential valid.
	e := enrollment(43)
	e.IdentityID = id
	e.DeviceID = device
	if err := s.CreateInvite(ctx, id, "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, id, now, e, nil); err != nil {
		t.Fatal(err)
	}
	if err := s.PublishKeyPackages(ctx, id, device, [][]byte{[]byte("first"), []byte("second")}, now); err != nil {
		t.Fatal(err)
	}
	key := requestKey(now, 1)
	one, err := s.ClaimKeyPackageOnce(ctx, a.CredentialHash, key, id, device, now)
	if err != nil {
		t.Fatal(err)
	}
	two, err := s.ClaimKeyPackageOnce(ctx, a.CredentialHash, key, id, device, now.Add(time.Minute))
	if err != nil || !bytes.Equal(one, two) {
		t.Fatal(err)
	}
	if n, err := s.AvailableKeyPackages(ctx, device); err != nil || n != 1 {
		t.Fatal(n, err)
	}
	if _, err = s.ClaimKeyPackageOnce(ctx, a.CredentialHash, key, bytes.Repeat([]byte{1}, 32), device, now); !errors.Is(err, ErrRequestConflict) {
		t.Fatal(err)
	}
	other, err := s.ClaimKeyPackageOnce(ctx, b.CredentialHash, key, id, device, now)
	if err != nil || bytes.Equal(other, one) {
		t.Fatal(err)
	}
}

func TestInvitationMigrationBackupAndDurableReplay(t *testing.T) {
	ctx := context.Background()
	now := time.Now()
	dir := t.TempDir()
	path := filepath.Join(dir, "realm.db")
	snapshot := filepath.Join(dir, "v4.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	a := enrollment(71)
	if err = s.CreateInvite(ctx, []byte("legacy"), "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err = s.RedeemInvite(ctx, []byte("legacy"), now, a, nil); err != nil {
		t.Fatal(err)
	}
	// Reconstruct the actual v4 table set, keeping a real enrolled identity.
	if _, err = s.db.Exec(`DROP TABLE issued_invitations; DROP TABLE invitation_audit; DROP TABLE key_package_claim_receipts; DELETE FROM schema_migrations WHERE version>=5; INSERT OR IGNORE INTO schema_migrations VALUES(4,0);`); err != nil {
		t.Fatal(err)
	}
	if err = s.BackupTo(ctx, snapshot); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.RedeemInvite(ctx, []byte("legacy"), now, a, nil); !errors.Is(err, ErrAlreadyRedeemed) {
		t.Fatalf("legacy receipt lost: %v", err)
	}
	if allowed, err := s.InvitationPolicy(ctx, a.CredentialHash, now); err != nil || allowed {
		t.Fatal("migration promoted an existing member")
	}
	if err = s.MakeOwner(ctx, a.IdentityID, now); err != nil {
		t.Fatal(err)
	}
	hash := bytes.Repeat([]byte{72}, 32)
	key := requestKey(now, 71)
	first, err := s.IssueInvitation(ctx, a.CredentialHash, key, hash, 60, now)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	second, err := s.IssueInvitation(ctx, a.CredentialHash, key, hash, 60, now.Add(time.Minute))
	if err != nil || first.ExpiresAt != second.ExpiresAt || first.Sequence != second.Sequence {
		t.Fatal("restart extended or duplicated invitation")
	}
	backup, err := sql.Open("sqlite", snapshot)
	if err != nil {
		t.Fatal(err)
	}
	defer backup.Close()
	var version, count int
	if err = backup.QueryRow(`SELECT max(version) FROM schema_migrations`).Scan(&version); err != nil {
		t.Fatal(err)
	}
	if err = backup.QueryRow(`SELECT count(*) FROM realm_memberships`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if version != 4 || count != 1 {
		t.Fatal("backup is not a coherent v4 rollback point")
	}
}
