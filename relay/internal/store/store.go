// Package store is the relay's SQLite persistence (ADR-004): memberships,
// invites, device credentials and manifests. Queues and blobs arrive in
// M0.4. It uses modernc.org/sqlite, a pure-Go driver, so the relay stays a
// static single binary; the embedded SQLite must carry the WAL-reset fix.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

// MinSQLiteVersionNumber is 3.51.3 (ADR-004, WAL-reset fix).
const MinSQLiteVersionNumber = 3051003

var (
	ErrInviteInvalid   = errors.New("invite: unknown, expired or exhausted")
	ErrAlreadyMember   = errors.New("membership: identity already a member")
	ErrDeviceKeyInUse  = errors.New("credential: transport key already registered")
	ErrManifestOrder   = errors.New("manifest: sequence must exceed the stored one")
	ErrUnknownIdentity = errors.New("membership: unknown identity")
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
	if _, err := db.Exec(`INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (1, ?)`, time.Now().Unix()); err != nil {
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
