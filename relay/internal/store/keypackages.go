package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"time"
)

// KeyPackages (PROTOCOL §5): published in bounded batches by a device,
// claimed once each by an atomic operation. The relay treats them as opaque
// bytes and never marks a package as trustworthy; the client validates the
// credential binding when it uses one.
const keyPackageSchema = `
CREATE TABLE IF NOT EXISTS key_packages (
    ref         BLOB PRIMARY KEY,
    identity_id BLOB NOT NULL REFERENCES realm_memberships(identity_id),
    device_id   BLOB NOT NULL,
    bytes       BLOB NOT NULL,
    published   INTEGER NOT NULL,
    consumed    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS key_packages_by_identity ON key_packages (identity_id, consumed, published);
`

const (
	// MaxKeyPackagesPerDevice bounds the available (unconsumed) batch.
	MaxKeyPackagesPerDevice = 50
	// MaxKeyPackageBytes bounds one package.
	MaxKeyPackageBytes = 8 * 1024
)

var (
	ErrKeyPackageBatch = errors.New("key packages: batch exceeds the per-device bound")
	ErrNoKeyPackage    = errors.New("key packages: none available for that identity")
)

func (s *Store) initKeyPackages() error {
	_, err := s.db.Exec(keyPackageSchema)
	return err
}

// PublishKeyPackages stores a batch for a device, refusing to exceed the
// available bound. Duplicates (same bytes) are ignored.
func (s *Store) PublishKeyPackages(ctx context.Context, identityID, deviceID []byte, packages [][]byte, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var available int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM key_packages WHERE device_id = ? AND consumed = 0`, deviceID).Scan(&available); err != nil {
		return err
	}
	if available+len(packages) > MaxKeyPackagesPerDevice {
		return ErrKeyPackageBatch
	}
	for _, p := range packages {
		if len(p) == 0 || len(p) > MaxKeyPackageBytes {
			return ErrEnvelopeTooBig
		}
		ref := sha256.Sum256(p)
		if _, err := tx.ExecContext(ctx,
			`INSERT OR IGNORE INTO key_packages (ref, identity_id, device_id, bytes, published) VALUES (?, ?, ?, ?, ?)`,
			ref[:], identityID, deviceID, p, now.Unix()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ClaimKeyPackage atomically consumes one available package of an identity
// (any of its devices, oldest first) and returns its bytes. A lost reply
// wastes the package; it never returns to circulation.
// An empty deviceID accepts any device of the identity.
func (s *Store) ClaimKeyPackage(ctx context.Context, identityID, deviceID []byte) ([]byte, error) {
	if deviceID == nil {
		deviceID = []byte{}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var ref, bytes []byte
	err = tx.QueryRowContext(ctx,
		`SELECT ref, bytes FROM key_packages WHERE identity_id = ? AND (? = X'' OR device_id = ?) AND consumed = 0 ORDER BY published, ref LIMIT 1`, identityID, deviceID, deviceID).
		Scan(&ref, &bytes)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoKeyPackage
	}
	if err != nil {
		return nil, err
	}
	res, err := tx.ExecContext(ctx, `UPDATE key_packages SET consumed = 1 WHERE ref = ? AND consumed = 0`, ref)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return nil, ErrNoKeyPackage
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return bytes, nil
}

// AvailableKeyPackages counts unconsumed packages of a device.
func (s *Store) AvailableKeyPackages(ctx context.Context, deviceID []byte) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM key_packages WHERE device_id = ? AND consumed = 0`, deviceID).Scan(&n)
	return n, err
}
