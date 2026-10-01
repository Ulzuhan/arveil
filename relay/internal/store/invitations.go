package store

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/binary"
	"errors"
	"time"
)

// Personal invitations add admission metadata, never names/contact routes.
// Request keys start with an eight-byte big-endian creation time followed by
// sixteen random bytes. Once receipts are swept, old requests cannot reissue.
const InvitationTTL = 7 * 24 * time.Hour
const InvitationRetention = 37 * 24 * time.Hour
const InvitationDailyLimit = 20
const InvitationPendingLimit = 50

var ErrInvitePermission = errors.New("invitation: permission denied")
var ErrInviteQuota = errors.New("invitation: quota exceeded")
var ErrInviteRequest = errors.New("invitation: malformed request")
var ErrInviteUsed = errors.New("invitation: already used")

const invitationSchema = `
CREATE TABLE IF NOT EXISTS issued_invitations (
 seq INTEGER PRIMARY KEY AUTOINCREMENT,
 token_hash BLOB NOT NULL UNIQUE,
 issuer BLOB NOT NULL REFERENCES realm_memberships(identity_id),
 request_key BLOB NOT NULL,
 created_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL,
 ttl INTEGER NOT NULL,
 state TEXT NOT NULL,
 claimed_identity BLOB NOT NULL DEFAULT X'',
 claimed_at INTEGER NOT NULL DEFAULT 0,
 UNIQUE(issuer, request_key)
);
CREATE INDEX IF NOT EXISTS invitations_by_issuer ON issued_invitations(issuer, seq);
CREATE TABLE IF NOT EXISTS invitation_audit (
 seq INTEGER PRIMARY KEY AUTOINCREMENT,
 actor BLOB NOT NULL,
 action TEXT NOT NULL,
 happened_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS key_package_claim_receipts (
 claimant BLOB NOT NULL,
 request_key BLOB NOT NULL,
 identity_id BLOB NOT NULL,
 device_id BLOB NOT NULL,
 package BLOB NOT NULL,
 created_at INTEGER NOT NULL,
 PRIMARY KEY(claimant, request_key)
);
`

func (s *Store) initInvitations() error { _, err := s.db.Exec(invitationSchema); return err }

// activeRole is checked inside each write transaction, not cached at handshake.
func activeRole(ctx context.Context, tx *sql.Tx, credential []byte, now time.Time) ([]byte, string, error) {
	var id []byte
	var role string
	err := tx.QueryRowContext(ctx, `SELECT m.identity_id, m.role FROM device_credentials d JOIN realm_memberships m ON m.identity_id=d.identity_id WHERE d.credential_hash=? AND d.status='active' AND d.not_after>=? AND m.status='active'`, credential, now.Unix()).Scan(&id, &role)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", ErrInvitePermission
	}
	return id, role, err
}

func (s *Store) InvitationPolicy(ctx context.Context, credential []byte, now time.Time) (bool, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	_, role, err := activeRole(ctx, tx, credential, now)
	return role == "owner", err
}

// MakeOwner is a host-only recovery/bootstrap action on an existing identity.
func (s *Store) MakeOwner(ctx context.Context, identity []byte, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `UPDATE realm_memberships SET role='owner' WHERE identity_id=? AND status='active'`, identity)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n != 1 {
		return ErrUnknownIdentity
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO invitation_audit(actor,action,happened_at) VALUES(?,'host-owner',?)`, identity, now.Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

func validRequestKey(key []byte, now time.Time) bool {
	if len(key) != 24 {
		return false
	}
	timestamp := binary.BigEndian.Uint64(key[:8])
	n := uint64(now.Unix())
	return timestamp <= n+300 && timestamp+uint64(InvitationTTL/time.Second) >= n
}

type Invitation struct {
	Sequence        uint64
	ID              []byte
	CreatedAt       uint64
	ExpiresAt       uint64
	State           string
	ClaimedIdentity []byte
	ClaimedAt       uint64
}

const invitationColumns = `seq,token_hash,created_at,expires_at,state,claimed_identity,claimed_at`

func scanInvitation(row interface{ Scan(...any) error }, now time.Time) (Invitation, error) {
	var i Invitation
	err := row.Scan(&i.Sequence, &i.ID, &i.CreatedAt, &i.ExpiresAt, &i.State, &i.ClaimedIdentity, &i.ClaimedAt)
	if i.State == "pending" && i.ExpiresAt <= uint64(now.Unix()) {
		i.State = "expired"
	}
	return i, err
}

func (s *Store) IssueInvitation(ctx context.Context, credential, key, hash []byte, ttl uint64, now time.Time) (Invitation, error) {
	var empty Invitation
	if len(hash) != 32 || len(key) != 24 || ttl == 0 || ttl > uint64(InvitationTTL/time.Second) {
		return empty, ErrInviteRequest
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return empty, err
	}
	defer tx.Rollback()
	actor, role, err := activeRole(ctx, tx, credential, now)
	if err != nil {
		return empty, err
	}
	if role != "owner" {
		return empty, ErrInvitePermission
	}
	var oldHash []byte
	var oldTTL uint64
	err = tx.QueryRowContext(ctx, `SELECT token_hash,ttl FROM issued_invitations WHERE issuer=? AND request_key=?`, actor, key).Scan(&oldHash, &oldTTL)
	if err == nil {
		if !bytes.Equal(hash, oldHash) || ttl != oldTTL {
			return empty, ErrRequestConflict
		}
		return scanInvitation(tx.QueryRowContext(ctx, `SELECT `+invitationColumns+` FROM issued_invitations WHERE issuer=? AND request_key=?`, actor, key), now)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return empty, err
	}
	if !validRequestKey(key, now) {
		return empty, ErrInviteInvalid
	}
	var daily, pending int
	if err = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM issued_invitations WHERE issuer=? AND created_at>?`, actor, now.Add(-24*time.Hour).Unix()).Scan(&daily); err != nil {
		return empty, err
	}
	if err = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM issued_invitations WHERE state='pending' AND expires_at>?`, now.Unix()).Scan(&pending); err != nil {
		return empty, err
	}
	if daily >= InvitationDailyLimit || pending >= InvitationPendingLimit {
		return empty, ErrInviteQuota
	}
	var redeemed int
	if err = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM invite_redemptions WHERE token_hash=?`, hash).Scan(&redeemed); err != nil {
		return empty, err
	}
	if redeemed != 0 {
		return empty, ErrRequestConflict
	}
	expiry := now.Unix() + int64(ttl)
	if _, err = tx.ExecContext(ctx, `INSERT INTO invites(token_hash,role,expires_at,uses_left) VALUES(?,'member',?,1)`, hash, expiry); err != nil {
		if isConstraint(err) {
			return empty, ErrRequestConflict
		}
		return empty, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO issued_invitations(token_hash,issuer,request_key,created_at,expires_at,ttl,state) VALUES(?,?,?,?,?,?,'pending')`, hash, actor, key, now.Unix(), expiry, ttl); err != nil {
		return empty, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO invitation_audit(actor,action,happened_at) VALUES(?,'issue',?)`, actor, now.Unix()); err != nil {
		return empty, err
	}
	result, err := scanInvitation(tx.QueryRowContext(ctx, `SELECT `+invitationColumns+` FROM issued_invitations WHERE token_hash=?`, hash), now)
	if err != nil {
		return empty, err
	}
	return result, tx.Commit()
}

func (s *Store) ListInvitations(ctx context.Context, credential []byte, cursor uint64, limit uint16, now time.Time) ([]Invitation, error) {
	if limit == 0 || limit > 50 {
		return nil, ErrInviteRequest
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	actor, _, err := activeRole(ctx, tx, credential, now)
	if err != nil {
		return nil, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT `+invitationColumns+` FROM issued_invitations WHERE issuer=? AND seq>? ORDER BY seq LIMIT ?`, actor, cursor, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Invitation{}
	for rows.Next() {
		i, err := scanInvitation(rows, now)
		if err != nil {
			return nil, err
		}
		result = append(result, i)
	}
	return result, rows.Err()
}

func (s *Store) GetInvitation(ctx context.Context, credential, hash []byte, now time.Time) (Invitation, error) {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return Invitation{}, err
	}
	defer tx.Rollback()
	actor, _, err := activeRole(ctx, tx, credential, now)
	if err != nil {
		return Invitation{}, err
	}
	i, err := scanInvitation(tx.QueryRowContext(ctx, `SELECT `+invitationColumns+` FROM issued_invitations WHERE token_hash=? AND (issuer=? OR claimed_identity=?)`, hash, actor, actor), now)
	if errors.Is(err, sql.ErrNoRows) {
		err = ErrInviteInvalid
	}
	return i, err
}

func (s *Store) RevokeInvitation(ctx context.Context, credential, hash []byte, now time.Time) (Invitation, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Invitation{}, err
	}
	defer tx.Rollback()
	actor, role, err := activeRole(ctx, tx, credential, now)
	if err != nil {
		return Invitation{}, err
	}
	if role != "owner" {
		return Invitation{}, ErrInvitePermission
	}
	i, err := scanInvitation(tx.QueryRowContext(ctx, `SELECT `+invitationColumns+` FROM issued_invitations WHERE token_hash=? AND issuer=?`, hash, actor), now)
	if errors.Is(err, sql.ErrNoRows) {
		err = ErrInviteInvalid
	}
	if err != nil {
		return i, err
	}
	if i.State == "used" {
		return i, ErrInviteUsed
	}
	if i.State == "revoked" {
		return i, nil
	}
	if _, err = tx.ExecContext(ctx, `UPDATE invites SET uses_left=0 WHERE token_hash=?`, hash); err != nil {
		return i, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE issued_invitations SET state='revoked' WHERE token_hash=?`, hash); err != nil {
		return i, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO invitation_audit(actor,action,happened_at) VALUES(?,'revoke',?)`, actor, now.Unix()); err != nil {
		return i, err
	}
	i.State = "revoked"
	return i, tx.Commit()
}

// An existing member spends the same personal use without creating an identity.
func (s *Store) AcceptInvitation(ctx context.Context, credential, hash []byte, now time.Time) (Invitation, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Invitation{}, err
	}
	defer tx.Rollback()
	actor, _, err := activeRole(ctx, tx, credential, now)
	if err != nil {
		return Invitation{}, err
	}
	var issuer []byte
	if err = tx.QueryRowContext(ctx, `SELECT issuer FROM issued_invitations WHERE token_hash=?`, hash).Scan(&issuer); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			err = ErrInviteInvalid
		}
		return Invitation{}, err
	}
	if bytes.Equal(actor, issuer) {
		return Invitation{}, ErrInviteRequest
	}
	i, err := scanInvitation(tx.QueryRowContext(ctx, `SELECT `+invitationColumns+` FROM issued_invitations WHERE token_hash=?`, hash), now)
	if err != nil {
		return i, err
	}
	if i.State == "used" {
		var usedCredential []byte
		if err := tx.QueryRowContext(ctx, `SELECT credential_hash FROM invite_redemptions WHERE token_hash=? AND identity_id=?`, hash, actor).Scan(&usedCredential); err == nil && bytes.Equal(usedCredential, credential) {
			return i, nil
		}
		return i, ErrInviteUsed
	}
	if i.State != "pending" {
		return i, ErrInviteInvalid
	}
	if _, err = tx.ExecContext(ctx, `UPDATE invites SET uses_left=0 WHERE token_hash=?`, hash); err != nil {
		return i, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE issued_invitations SET state='used',claimed_identity=?,claimed_at=? WHERE token_hash=?`, actor, now.Unix(), hash); err != nil {
		return i, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO invite_redemptions(token_hash,identity_id,credential_hash,redeemed_at) VALUES(?,?,?,?)`, hash, actor, credential, now.Unix()); err != nil {
		return i, err
	}
	i.State = "used"
	i.ClaimedIdentity = actor
	i.ClaimedAt = uint64(now.Unix())
	return i, tx.Commit()
}

// A request is bound to the active claimant credential and exact target. The
// package is consumed and its reply saved in the same transaction.
func (s *Store) ClaimKeyPackageOnce(ctx context.Context, credential, key, identity, device []byte, now time.Time) ([]byte, error) {
	if len(key) != 24 || len(identity) != 32 || len(device) != 16 {
		return nil, ErrInviteRequest
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, _, err = activeRole(ctx, tx, credential, now); err != nil {
		return nil, err
	}
	var oldIdentity, oldDevice, pkg []byte
	err = tx.QueryRowContext(ctx, `SELECT identity_id,device_id,package FROM key_package_claim_receipts WHERE claimant=? AND request_key=?`, credential, key).Scan(&oldIdentity, &oldDevice, &pkg)
	if err == nil {
		if !bytes.Equal(oldIdentity, identity) || !bytes.Equal(oldDevice, device) {
			return nil, ErrRequestConflict
		}
		return pkg, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if !validRequestKey(key, now) {
		return nil, ErrInviteInvalid
	}
	var count int
	if err = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM key_package_claim_receipts WHERE claimant=? AND created_at>?`, credential, now.Add(-24*time.Hour).Unix()).Scan(&count); err != nil {
		return nil, err
	}
	if count >= 100 {
		return nil, ErrInviteQuota
	}
	var ref []byte
	err = tx.QueryRowContext(ctx, `SELECT ref,bytes FROM key_packages WHERE identity_id=? AND device_id=? AND consumed=0 ORDER BY published,ref LIMIT 1`, identity, device).Scan(&ref, &pkg)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoKeyPackage
	}
	if err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE key_packages SET consumed=1 WHERE ref=?`, ref); err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO key_package_claim_receipts(claimant,request_key,identity_id,device_id,package,created_at) VALUES(?,?,?,?,?,?)`, credential, key, identity, device, pkg, now.Unix()); err != nil {
		return nil, err
	}
	return pkg, tx.Commit()
}

func (s *Store) sweepInvitationHistory(ctx context.Context, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	cutoff := now.Add(-InvitationRetention).Unix()
	if _, err = tx.ExecContext(ctx, `DELETE FROM invites WHERE token_hash IN (SELECT token_hash FROM issued_invitations WHERE expires_at<? AND claimed_at<?)`, cutoff, cutoff); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM issued_invitations WHERE expires_at<? AND claimed_at<?`, cutoff, cutoff); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM key_package_claim_receipts WHERE created_at<?`, cutoff); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM invitation_audit WHERE happened_at<?`, cutoff); err != nil {
		return err
	}
	return tx.Commit()
}
