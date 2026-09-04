package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Pairing rendezvous (PROTOCOL §8, M3.1): two devices exchange a handshake
// and one sealed grant through the realm, which stores opaque blobs under a
// random id and a bearer capability. This is the only surface a session
// that is not yet a member may write to, which is why everything about it
// is bounded: a short life, a small size, three slots, and a cap on how
// many exist at once.
const pairingSchema = `
CREATE TABLE IF NOT EXISTS rendezvous (
    pair_id    BLOB PRIMARY KEY,
    cap_hash   BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS rendezvous_slots (
    pair_id BLOB NOT NULL REFERENCES rendezvous(pair_id),
    slot    TEXT NOT NULL,
    data    BLOB NOT NULL,
    PRIMARY KEY (pair_id, slot)
);
`

const (
	// DefaultPairTTL is how long a rendezvous lives (ARCHITECTURE §5 scale).
	DefaultPairTTL = 10 * time.Minute
	// MaxPairData bounds one slot.
	MaxPairData = 8 * 1024
	// MaxOpenRendezvous bounds how many can be live at once, since a
	// provisional session may create them.
	MaxOpenRendezvous = 32
)

var (
	ErrPairUnknown = errors.New("pairing: unknown rendezvous or wrong capability")
	ErrPairSlot    = errors.New("pairing: unknown slot")
	ErrPairTaken   = errors.New("pairing: slot already holds different bytes")
	ErrPairSize    = errors.New("pairing: payload too large")
	ErrPairBusy    = errors.New("pairing: too many rendezvous open right now")
)

func validSlot(s string) bool { return s == "a" || s == "b" || s == "c" }

func (s *Store) initPairing() error {
	_, err := s.db.Exec(pairingSchema)
	return err
}

// BeginPair creates a rendezvous and returns its id and capability.
func (s *Store) BeginPair(ctx context.Context, now time.Time, ttl time.Duration) (id, capability []byte, expires int64, err error) {
	var open int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM rendezvous WHERE expires_at > ?`, now.Unix()).Scan(&open); err != nil {
		return nil, nil, 0, err
	}
	if open >= MaxOpenRendezvous {
		return nil, nil, 0, ErrPairBusy
	}
	if id, err = randomBytes(16); err != nil {
		return nil, nil, 0, err
	}
	if capability, err = randomBytes(32); err != nil {
		return nil, nil, 0, err
	}
	expires = now.Add(ttl).Unix()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO rendezvous (pair_id, cap_hash, created_at, expires_at) VALUES (?, ?, ?, ?)`,
		id, capHash(capability), now.Unix(), expires); err != nil {
		return nil, nil, 0, err
	}
	return id, capability, expires, nil
}

func (s *Store) pairExists(ctx context.Context, id, capability []byte, now time.Time) error {
	var n int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM rendezvous WHERE pair_id = ? AND cap_hash = ? AND expires_at > ?`,
		id, capHash(capability), now.Unix()).Scan(&n)
	if err != nil {
		return err
	}
	if n != 1 {
		return ErrPairUnknown
	}
	return nil
}

// PutPair writes one slot. Writing the same bytes twice is idempotent;
// different bytes under a slot already written is a conflict, so whoever
// answered first cannot be quietly replaced.
func (s *Store) PutPair(ctx context.Context, id, capability []byte, slot string, data []byte, now time.Time) error {
	if !validSlot(slot) {
		return ErrPairSlot
	}
	if len(data) == 0 || len(data) > MaxPairData {
		return ErrPairSize
	}
	if err := s.pairExists(ctx, id, capability, now); err != nil {
		return err
	}
	var existing []byte
	err := s.db.QueryRowContext(ctx, `SELECT data FROM rendezvous_slots WHERE pair_id = ? AND slot = ?`, id, slot).Scan(&existing)
	switch {
	case errors.Is(err, sql.ErrNoRows):
	case err != nil:
		return err
	case string(existing) == string(data):
		return nil
	default:
		return ErrPairTaken
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO rendezvous_slots (pair_id, slot, data) VALUES (?, ?, ?)`, id, slot, data)
	return err
}

// GetPair reads one slot, returning nil when it has not been written yet.
func (s *Store) GetPair(ctx context.Context, id, capability []byte, slot string, now time.Time) ([]byte, error) {
	if !validSlot(slot) {
		return nil, ErrPairSlot
	}
	if err := s.pairExists(ctx, id, capability, now); err != nil {
		return nil, err
	}
	var data []byte
	err := s.db.QueryRowContext(ctx, `SELECT data FROM rendezvous_slots WHERE pair_id = ? AND slot = ?`, id, slot).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return data, err
}

// SweepPairs removes expired rendezvous with their slots.
func (s *Store) SweepPairs(ctx context.Context, now time.Time) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM rendezvous_slots WHERE pair_id IN (SELECT pair_id FROM rendezvous WHERE expires_at <= ?)`,
		now.Unix()); err != nil {
		return 0, err
	}
	res, err := tx.ExecContext(ctx, `DELETE FROM rendezvous WHERE expires_at <= ?`, now.Unix())
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, tx.Commit()
}
