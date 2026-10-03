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
// bound to the device that registered it and to nothing else.
const watchSchema = `
CREATE TABLE IF NOT EXISTS watch_keys (
    device_id  BLOB PRIMARY KEY,
    watch_key  BLOB NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
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
func (s *Store) SetWatchKey(ctx context.Context, deviceID, key []byte, now time.Time) error {
	if len(key) == 0 {
		_, err := s.db.ExecContext(ctx, `DELETE FROM watch_keys WHERE device_id = ?`, deviceID)
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
		`INSERT INTO watch_keys (device_id, watch_key, created_at) VALUES (?, ?, ?)
		 ON CONFLICT(device_id) DO UPDATE SET watch_key = excluded.watch_key, created_at = excluded.created_at`,
		deviceID, key, coarseHour(now)); err != nil {
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
	var deviceID []byte
	err = s.db.QueryRowContext(ctx, `SELECT device_id FROM watch_keys WHERE watch_key = ?`, key).Scan(&deviceID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	d, err = s.activeDevice(ctx, deviceID, now)
	return d, true, err
}

// DeviceActive reports whether a device still has an active, unexpired
// credential.
func (s *Store) DeviceActive(ctx context.Context, deviceID []byte, now time.Time) (bool, error) {
	d, err := s.activeDevice(ctx, deviceID, now)
	return d != nil, err
}

func (s *Store) activeDevice(ctx context.Context, deviceID []byte, now time.Time) (*Device, error) {
	d := &Device{}
	err := s.db.QueryRowContext(ctx,
		`SELECT credential_hash, identity_id, device_id, status, not_after FROM device_credentials
		 WHERE device_id = ? AND status = 'active' AND not_after > ? ORDER BY not_after DESC LIMIT 1`,
		deviceID, now.Unix()).Scan(&d.CredentialHash, &d.IdentityID, &d.DeviceID, &d.Status, &d.NotAfter)
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
func forgetWatchKey(ctx context.Context, tx *sql.Tx, deviceID []byte) error {
	_, err := tx.ExecContext(ctx,
		`DELETE FROM watch_keys WHERE device_id = ?
		 AND NOT EXISTS (SELECT 1 FROM device_credentials WHERE device_id = ? AND status = 'active')`,
		deviceID, deviceID)
	return err
}

// MailboxOwnerDevice returns the device that owns a mailbox, or nil.
func (s *Store) MailboxOwnerDevice(ctx context.Context, mailboxID []byte) ([]byte, error) {
	var device []byte
	err := s.db.QueryRowContext(ctx, `SELECT owner_device FROM mailboxes WHERE mailbox_id = ?`, mailboxID).Scan(&device)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return device, err
}

// DeviceHasMail reports whether any mailbox of a device holds an envelope
// that has not expired. A subscription that starts on such a mailbox gets a
// notice at once, which is how a notice lost while offline is recovered.
func (s *Store) DeviceHasMail(ctx context.Context, deviceID []byte, now time.Time) (bool, error) {
	var has bool
	err := s.db.QueryRowContext(ctx,
		`SELECT EXISTS (SELECT 1 FROM queued_envelopes e JOIN mailboxes m ON m.mailbox_id = e.mailbox_id
		 WHERE m.owner_device = ? AND e.expires_at > ?)`,
		deviceID, now.Unix()).Scan(&has)
	return has, err
}
