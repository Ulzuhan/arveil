// Package store is the relay's SQLite persistence (ADR-004): memberships,
// invites, device credentials and manifests. Queues and blobs arrive in
// M0.4. It uses modernc.org/sqlite, a pure-Go driver, so the relay stays a
// static single binary; the embedded SQLite must carry the WAL-reset fix.
package store

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// MinSQLiteVersionNumber is 3.51.3 (ADR-004, WAL-reset fix).
const MinSQLiteVersionNumber = 3051003

var (
	ErrInviteInvalid  = errors.New("invite: unknown, expired or exhausted")
	ErrAlreadyMember  = errors.New("membership: identity already a member")
	ErrDeviceKeyInUse = errors.New("credential: transport key already registered")
	// ErrAlreadyRedeemed reports a repeat of a redemption this store already
	// performed for the same token, identity and credential. It is not a
	// failure: the caller answers with the result it recorded the first time.
	ErrAlreadyRedeemed = errors.New("invite: already redeemed by this credential")
	// ErrSchemaTooNew reports a database written by a newer relay. Nothing
	// is modified: an older binary cannot know what it would break.
	ErrSchemaTooNew    = errors.New("schema: written by a newer relay")
	ErrManifestOrder   = errors.New("manifest: sequence must exceed the stored one")
	ErrUnknownIdentity = errors.New("membership: unknown identity")
	// ErrRequestConflict reports a request key reused with other parameters,
	// or by a device that does not own it.
	ErrRequestConflict = errors.New("request: key reused with other parameters")
	// ErrCapabilityInUse reports a capability already promised to another
	// mailbox. Hash equality is not authorisation.
	ErrCapabilityInUse = errors.New("capability: already in use")
)

const pragmas = `
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;
`

const schema = `
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    INTEGER PRIMARY KEY,
    applied_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS realm_memberships (
    identity_id BLOB PRIMARY KEY,
    root_public BLOB NOT NULL,
    role        TEXT NOT NULL,
    status      TEXT NOT NULL,
    created_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS invites (
    token_hash BLOB PRIMARY KEY,
    role       TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    uses_left  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS device_credentials (
    credential_hash            BLOB PRIMARY KEY,
    identity_id                BLOB NOT NULL REFERENCES realm_memberships(identity_id),
    device_id                  BLOB NOT NULL,
    transport_noise_public_key BLOB NOT NULL UNIQUE,
    signed                     BLOB NOT NULL,
    status                     TEXT NOT NULL,
    not_after                  INTEGER NOT NULL
);
-- What an invite redemption produced, kept with the consumption itself so a
-- repeat can be answered instead of refused. Detecting an existing
-- membership is not enough: a membership says nothing about which token
-- and which credential made it.
CREATE TABLE IF NOT EXISTS invite_redemptions (
    token_hash      BLOB NOT NULL,
    identity_id     BLOB NOT NULL,
    credential_hash BLOB NOT NULL,
    redeemed_at     INTEGER NOT NULL,
    PRIMARY KEY (token_hash, identity_id)
);
CREATE TABLE IF NOT EXISTS device_manifests (
    identity_id BLOB NOT NULL REFERENCES realm_memberships(identity_id),
    sequence    INTEGER NOT NULL,
    signed      BLOB NOT NULL,
    PRIMARY KEY (identity_id, sequence)
);
`

// Store wraps the connection pool.
type Store struct {
	db *sql.DB
}

// Open opens or creates the database at path (":memory:" for tests), applies
// pragmas and the schema, and refuses an embedded SQLite older than 3.51.3.
func Open(path string) (*Store, error) {
	dsn := path
	if path == ":memory:" {
		// One shared in-memory database for the pool.
		dsn = "file::memory:?cache=shared"
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	if path == ":memory:" {
		db.SetMaxOpenConns(1)
	}
	s := &Store{db: db}
	if err := s.checkVersion(); err != nil {
		db.Close()
		return nil, err
	}
	// Before the pragmas and before the schema: refusing a database after
	// writing to it is not refusing it. A pragma alone can rewrite the file
	// header, and `CREATE TABLE IF NOT EXISTS` is still a modification of a
	// database this binary just said it does not understand.
	if err := s.refuseFutureSchema(); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.Exec(pragmas); err != nil {
		db.Close()
		return nil, fmt.Errorf("pragmas: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	if err := s.initDelivery(); err != nil {
		db.Close()
		return nil, fmt.Errorf("delivery schema: %w", err)
	}
	if err := s.initKeyPackages(); err != nil {
		db.Close()
		return nil, fmt.Errorf("key package schema: %w", err)
	}
	if err := s.initBlobs(); err != nil {
		db.Close()
		return nil, fmt.Errorf("blob schema: %w", err)
	}
	if err := s.initPairing(); err != nil {
		db.Close()
		return nil, fmt.Errorf("pairing schema: %w", err)
	}
	if err := s.recordSchemaVersion(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

// SQLiteVersion reports the embedded library version.
func (s *Store) SQLiteVersion() (string, int, error) {
	var v string
	var n int
	if err := s.db.QueryRow(`SELECT sqlite_version(), sqlite_version_number()`).Scan(&v, &n); err != nil {
		// sqlite_version_number() is not a SQL function; derive from the string.
		if err2 := s.db.QueryRow(`SELECT sqlite_version()`).Scan(&v); err2 != nil {
			return "", 0, err2
		}
		var a, b, c int
		if _, err := fmt.Sscanf(v, "%d.%d.%d", &a, &b, &c); err != nil {
			return v, 0, err
		}
		n = a*1000000 + b*1000 + c
	}
	return v, n, nil
}

func (s *Store) checkVersion() error {
	v, n, err := s.SQLiteVersion()
	if err != nil {
		return err
	}
	if n < MinSQLiteVersionNumber {
		return fmt.Errorf("embedded SQLite %s is older than 3.51.3 (ADR-004 WAL-reset fix)", v)
	}
	return nil
}

// SchemaVersion is what this binary writes and understands. Every change so
// far has been additive, which is why one number is enough: a database at an
// older version is brought forward by the schema itself, and a database at a
// newer one is refused rather than guessed at.
const SchemaVersion = 3

// refuseFutureSchema reads the recorded version and refuses a database from
// a newer relay. It reads only: a database with no `schema_migrations` table
// is a fresh one, not an unreadable one.
func (s *Store) refuseFutureSchema() error {
	var highest sql.NullInt64
	err := s.db.QueryRow(`SELECT MAX(version) FROM schema_migrations`).Scan(&highest)
	switch {
	case err != nil && strings.Contains(err.Error(), "no such table"):
		return nil
	case err != nil:
		return err
	case highest.Valid && highest.Int64 > SchemaVersion:
		return fmt.Errorf(
			"%w: the database is at version %d and this relay understands %d",
			ErrSchemaTooNew, highest.Int64, SchemaVersion)
	}
	return nil
}

// recordSchemaVersion notes that this version has been applied. The refusal
// happened before anything was written; this only records what was done.
func (s *Store) recordSchemaVersion() error {
	_, err := s.db.Exec(
		`INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (?, ?)`,
		SchemaVersion, time.Now().Unix())
	return err
}

// CreateInvite stores the hash of a token with its policy.
func (s *Store) CreateInvite(ctx context.Context, tokenHash []byte, role string, expiresAt time.Time, uses int) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO invites (token_hash, role, expires_at, uses_left) VALUES (?, ?, ?, ?)`,
		tokenHash, role, expiresAt.Unix(), uses)
	return err
}

// Enrollment is what a redeemed invite creates, atomically.
type Enrollment struct {
	IdentityID     []byte
	RootPublic     []byte
	CredentialHash []byte
	DeviceID       []byte
	TransportKey   []byte
	SignedCred     []byte
	NotAfter       int64
	ManifestSeq    uint64
	SignedManifest []byte
}

// RedeemInvite consumes one use of the invite and creates membership,
// credential and manifest in a single transaction. `between` is a fault
// injection hook run after the invite is consumed and before the membership
// is written; an error aborts the whole transaction (M0.3 acceptance: no
// half state).
func (s *Store) RedeemInvite(ctx context.Context, tokenHash []byte, now time.Time, e Enrollment, between func() error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// A repeat of a redemption already performed is answered from what was
	// recorded, and consumes nothing. The token, the identity and the exact
	// credential must all match: a membership on its own says nothing about
	// which token made it.
	var recorded []byte
	err = tx.QueryRowContext(ctx,
		`SELECT credential_hash FROM invite_redemptions WHERE token_hash = ? AND identity_id = ?`,
		tokenHash, e.IdentityID).Scan(&recorded)
	switch {
	case err == nil && bytes.Equal(recorded, e.CredentialHash):
		return ErrAlreadyRedeemed
	case err == nil:
		return ErrAlreadyMember
	case !errors.Is(err, sql.ErrNoRows):
		return err
	}

	res, err := tx.ExecContext(ctx,
		`UPDATE invites SET uses_left = uses_left - 1 WHERE token_hash = ? AND expires_at > ? AND uses_left > 0`,
		tokenHash, now.Unix())
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return ErrInviteInvalid
	}
	var role string
	if err := tx.QueryRowContext(ctx, `SELECT role FROM invites WHERE token_hash = ?`, tokenHash).Scan(&role); err != nil {
		return err
	}

	if between != nil {
		if err := between(); err != nil {
			return err
		}
	}

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO realm_memberships (identity_id, root_public, role, status, created_at) VALUES (?, ?, ?, 'active', ?)`,
		e.IdentityID, e.RootPublic, role, now.Unix()); err != nil {
		if isConstraint(err) {
			return ErrAlreadyMember
		}
		return err
	}
	if err := insertCredential(ctx, tx, e); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO device_manifests (identity_id, sequence, signed) VALUES (?, ?, ?)`,
		e.IdentityID, e.ManifestSeq, e.SignedManifest); err != nil {
		return err
	}
	// Written inside the same transaction as the consumption, so a crash
	// between them cannot leave a used invite nobody can prove they used.
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO invite_redemptions (token_hash, identity_id, credential_hash, redeemed_at)
		 VALUES (?, ?, ?, ?)`,
		tokenHash, e.IdentityID, e.CredentialHash, now.Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

func insertCredential(ctx context.Context, tx *sql.Tx, e Enrollment) error {
	_, err := tx.ExecContext(ctx,
		`INSERT INTO device_credentials (credential_hash, identity_id, device_id, transport_noise_public_key, signed, status, not_after)
		 VALUES (?, ?, ?, ?, ?, 'active', ?)`,
		e.CredentialHash, e.IdentityID, e.DeviceID, e.TransportKey, e.SignedCred, e.NotAfter)
	if err != nil && isConstraint(err) {
		return ErrDeviceKeyInUse
	}
	return err
}

// Device is the row the handshake looks up by transport key.
type Device struct {
	CredentialHash []byte
	IdentityID     []byte
	DeviceID       []byte
	Status         string
	NotAfter       int64
}

// DeviceByTransportKey returns the credential registered for a Noise static key.
func (s *Store) DeviceByTransportKey(ctx context.Context, key []byte) (*Device, error) {
	d := &Device{}
	err := s.db.QueryRowContext(ctx,
		`SELECT credential_hash, identity_id, device_id, status, not_after FROM device_credentials WHERE transport_noise_public_key = ?`, key).
		Scan(&d.CredentialHash, &d.IdentityID, &d.DeviceID, &d.Status, &d.NotAfter)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return d, nil
}

// RootPublic returns the root key stored for an identity.
func (s *Store) RootPublic(ctx context.Context, identityID []byte) ([]byte, error) {
	var root []byte
	err := s.db.QueryRowContext(ctx, `SELECT root_public FROM realm_memberships WHERE identity_id = ? AND status = 'active'`, identityID).Scan(&root)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUnknownIdentity
	}
	return root, err
}

// LatestManifestSequence returns the highest stored sequence, 0 if none.
func (s *Store) LatestManifestSequence(ctx context.Context, identityID []byte) (uint64, error) {
	var seq sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT MAX(sequence) FROM device_manifests WHERE identity_id = ?`, identityID).Scan(&seq); err != nil {
		return 0, err
	}
	if !seq.Valid {
		return 0, nil
	}
	return uint64(seq.Int64), nil
}

// PutManifest stores a newer manifest; the sequence must exceed the stored one.
func (s *Store) PutManifest(ctx context.Context, identityID []byte, seq uint64, signed []byte) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var cur sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT MAX(sequence) FROM device_manifests WHERE identity_id = ?`, identityID).Scan(&cur); err != nil {
		return err
	}
	if cur.Valid && uint64(cur.Int64) >= seq {
		return ErrManifestOrder
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO device_manifests (identity_id, sequence, signed) VALUES (?, ?, ?)`, identityID, seq, signed); err != nil {
		return err
	}
	return tx.Commit()
}

// LatestManifest returns the newest stored manifest for an identity (nil if none).
func (s *Store) LatestManifest(ctx context.Context, identityID []byte) (uint64, []byte, error) {
	var seq uint64
	var signed []byte
	err := s.db.QueryRowContext(ctx, `SELECT sequence, signed FROM device_manifests WHERE identity_id = ? ORDER BY sequence DESC LIMIT 1`, identityID).Scan(&seq, &signed)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil, nil
	}
	return seq, signed, err
}

// SetCredentialStatus marks credentials (by hash) of one identity; used when
// a manifest revokes them. Returns how many rows changed.
func (s *Store) SetCredentialStatus(ctx context.Context, identityID []byte, hashes [][]byte, status string) (int64, error) {
	var n int64
	for _, h := range hashes {
		res, err := s.db.ExecContext(ctx, `UPDATE device_credentials SET status = ? WHERE identity_id = ? AND credential_hash = ? AND status != ?`, status, identityID, h, status)
		if err != nil {
			return n, err
		}
		k, _ := res.RowsAffected()
		n += k
	}
	return n, nil
}

// RecoverIdentity registers a new device for an identity that already
// belongs to the realm, authorized by its root alone: the identity kit path
// of ADR-006. The manifest must advance the chain the realm holds and list
// the credential as active; every credential the manifest revokes loses its
// status and its mailboxes' capabilities in the same transaction. Returns
// the sequence the realm held before the call, so a device recovering from
// a kit can see a realm restored from an older snapshot (I-08).
func (s *Store) RecoverIdentity(ctx context.Context, e Enrollment, revoked [][]byte) (uint64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var prev sql.NullInt64
	if err := tx.QueryRowContext(ctx, `SELECT MAX(sequence) FROM device_manifests WHERE identity_id = ?`, e.IdentityID).Scan(&prev); err != nil {
		return 0, err
	}
	previous := uint64(0)
	if prev.Valid {
		previous = uint64(prev.Int64)
	}
	if e.ManifestSeq <= previous {
		return previous, ErrManifestOrder
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO device_manifests (identity_id, sequence, signed) VALUES (?, ?, ?)`,
		e.IdentityID, e.ManifestSeq, e.SignedManifest); err != nil {
		return previous, err
	}
	if err := insertCredential(ctx, tx, e); err != nil {
		return previous, err
	}
	for _, h := range revoked {
		var deviceID []byte
		err := tx.QueryRowContext(ctx, `SELECT device_id FROM device_credentials WHERE identity_id = ? AND credential_hash = ?`, e.IdentityID, h).Scan(&deviceID)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return previous, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE device_credentials SET status = 'revoked' WHERE credential_hash = ?`, h); err != nil {
			return previous, err
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE capabilities SET revoked = 1 WHERE mailbox_id IN (SELECT mailbox_id FROM mailboxes WHERE owner_identity = ? AND owner_device = ?)`,
			e.IdentityID, deviceID); err != nil {
			return previous, err
		}
	}
	return previous, tx.Commit()
}

// RevokeCredentials marks credentials revoked and revokes every capability
// of the mailboxes owned by those devices, in one transaction. Returns how
// many credentials changed state.
func (s *Store) RevokeCredentials(ctx context.Context, identityID []byte, hashes [][]byte) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var n int64
	for _, h := range hashes {
		var deviceID []byte
		err := tx.QueryRowContext(ctx, `SELECT device_id FROM device_credentials WHERE identity_id = ? AND credential_hash = ? AND status != 'revoked'`, identityID, h).Scan(&deviceID)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return n, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE device_credentials SET status = 'revoked' WHERE credential_hash = ?`, h); err != nil {
			return n, err
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE capabilities SET revoked = 1 WHERE mailbox_id IN (SELECT mailbox_id FROM mailboxes WHERE owner_identity = ? AND owner_device = ?)`,
			identityID, deviceID); err != nil {
			return n, err
		}
		n++
	}
	return n, tx.Commit()
}

// PutCredential registers an additional credential for a member.
func (s *Store) PutCredential(ctx context.Context, e Enrollment) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := insertCredential(ctx, tx, e); err != nil {
		return err
	}
	return tx.Commit()
}

// BackupTo writes a consistent copy of the database to path while the relay
// keeps serving. `VACUUM INTO` reads one transaction, so the copy is a point
// in time under WAL, and it never blocks writers for the whole file.
func (s *Store) BackupTo(ctx context.Context, path string) error {
	if strings.ContainsAny(path, "'\x00") {
		return fmt.Errorf("backup path must not contain quotes or NUL")
	}
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("%s already exists", path)
	}
	_, err := s.db.ExecContext(ctx, "VACUUM INTO '"+path+"'")
	return err
}

// Count is a test and diagnostics helper.
func (s *Store) Count(ctx context.Context, table string) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM `+table).Scan(&n)
	return n, err
}

func isConstraint(err error) bool {
	// modernc.org/sqlite wraps constraint failures with this text.
	return err != nil && (contains(err.Error(), "constraint failed") || contains(err.Error(), "UNIQUE"))
}

func contains(s, sub string) bool {
	return len(sub) <= len(s) && (func() bool {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})()
}
