package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Activity notices (ADR-014). A device may register one watch key: a
// separate X25519 Noise key whose sessions may only wait for notices. The
// relay already knows which mailbox belongs to which device, so the key is
// bound to the device that registered it, named by identity and device id
// together, and to nothing else.
const watchSchema = `
CREATE TABLE IF NOT EXISTS watch_keys (
    identity_id BLOB NOT NULL,
    device_id   BLOB NOT NULL,
    watch_key   BLOB NOT NULL UNIQUE,
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (identity_id, device_id)
);
`

// WatchKeyBytes is the length of an X25519 public key.
const WatchKeyBytes = 32

var (
	ErrWatchKeyInUse = errors.New("watch key: already a transport or watch key")
	ErrWatchKeyShape = errors.New("watch key: must be 32 bytes")
)

func (s *Store) initWatch() error {
	_, err := s.db.Exec(watchSchema)
	return err
}

// SetWatchKey registers, replaces or (with an empty key) removes the watch
// key of one device. A key that is any device's transport key, or another
// device's watch key, is refused: a watch session must never be mistaken
// for a member session, nor two devices for each other.
func (s *Store) SetWatchKey(ctx context.Context, identityID, deviceID, key []byte, now time.Time) error {
	if len(key) == 0 {
		_, err := s.db.ExecContext(ctx, `DELETE FROM watch_keys WHERE identity_id = ? AND device_id = ?`, identityID, deviceID)
		return err
	}
	if len(key) != WatchKeyBytes {
		return ErrWatchKeyShape
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var transport int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM device_credentials WHERE transport_noise_public_key = ?`, key).Scan(&transport); err != nil {
		return err
	}
	if transport > 0 {
		return ErrWatchKeyInUse
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO watch_keys (identity_id, device_id, watch_key, created_at) VALUES (?, ?, ?, ?)
		 ON CONFLICT(identity_id, device_id) DO UPDATE SET watch_key = excluded.watch_key, created_at = excluded.created_at`,
		identityID, deviceID, key, coarseHour(now)); err != nil {
		if isConstraint(err) {
			return ErrWatchKeyInUse
		}
		return err
	}
	return tx.Commit()
}

// DeviceByWatchKey returns the newest active credential of the device that
// registered `key`. found reports whether the key is registered at all, so
// that a key whose device has no active credential left is refused rather
// than treated as unknown.
func (s *Store) DeviceByWatchKey(ctx context.Context, key []byte, now time.Time) (d *Device, found bool, err error) {
	var identityID, deviceID []byte
	err = s.db.QueryRowContext(ctx, `SELECT identity_id, device_id FROM watch_keys WHERE watch_key = ?`, key).Scan(&identityID, &deviceID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	d, err = s.activeDevice(ctx, identityID, deviceID, now)
	return d, true, err
}

// DeviceActive reports whether a device still has an active, unexpired
// credential.
func (s *Store) DeviceActive(ctx context.Context, identityID, deviceID []byte, now time.Time) (bool, error) {
	d, err := s.activeDevice(ctx, identityID, deviceID, now)
	return d != nil, err
}

func (s *Store) activeDevice(ctx context.Context, identityID, deviceID []byte, now time.Time) (*Device, error) {
	d := &Device{}
	err := s.db.QueryRowContext(ctx,
		`SELECT credential_hash, identity_id, device_id, status, not_after FROM device_credentials
		 WHERE identity_id = ? AND device_id = ? AND status = 'active' AND not_after > ? ORDER BY not_after DESC LIMIT 1`,
		identityID, deviceID, now.Unix()).Scan(&d.CredentialHash, &d.IdentityID, &d.DeviceID, &d.Status, &d.NotAfter)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return d, nil
}

// forgetWatchKey removes the watch key of a device that has no active
// credential left. Called inside the revocation transactions.
func forgetWatchKey(ctx context.Context, tx *sql.Tx, identityID, deviceID []byte) error {
	_, err := tx.ExecContext(ctx,
		`DELETE FROM watch_keys WHERE identity_id = ? AND device_id = ?
		 AND NOT EXISTS (SELECT 1 FROM device_credentials WHERE identity_id = ? AND device_id = ? AND status = 'active')`,
		identityID, deviceID, identityID, deviceID)
	return err
}

// MailboxOwner returns the identity and device that own a mailbox, or nils.
func (s *Store) MailboxOwner(ctx context.Context, mailboxID []byte) (identityID, deviceID []byte, err error) {
	err = s.db.QueryRowContext(ctx, `SELECT owner_identity, owner_device FROM mailboxes WHERE mailbox_id = ?`, mailboxID).
		Scan(&identityID, &deviceID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, nil
	}
	return identityID, deviceID, err
}

// DeviceHasMail reports whether any mailbox of a device holds an envelope
// that has not expired. A subscription that starts on such a mailbox gets a
// notice at once, which is how a notice lost while offline is recovered.
func (s *Store) DeviceHasMail(ctx context.Context, identityID, deviceID []byte, now time.Time) (bool, error) {
	var has bool
	err := s.db.QueryRowContext(ctx,
		`SELECT EXISTS (SELECT 1 FROM queued_envelopes e JOIN mailboxes m ON m.mailbox_id = e.mailbox_id
		 WHERE m.owner_identity = ? AND m.owner_device = ? AND e.expires_at > ?)`,
		identityID, deviceID, now.Unix()).Scan(&has)
	return has, err
}
