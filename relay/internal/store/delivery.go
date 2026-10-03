package store

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"errors"
	"time"
)

// Delivery tables (DOMAIN_MODEL §4): opaque mailboxes owned by devices,
// capabilities stored as hashes, envelopes keyed by (mailbox, delivery id).
// The relay never sees a conversation, a group id or a member list here.
const deliverySchema = `
CREATE TABLE IF NOT EXISTS mailboxes (
    mailbox_id     BLOB PRIMARY KEY,
    owner_identity BLOB NOT NULL REFERENCES realm_memberships(identity_id),
    owner_device   BLOB NOT NULL,
    created_at     INTEGER NOT NULL,
    next_seq       INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS capabilities (
    cap_hash   BLOB PRIMARY KEY,
    mailbox_id BLOB NOT NULL REFERENCES mailboxes(mailbox_id),
    scope      TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    revoked    INTEGER NOT NULL DEFAULT 0
);
-- What a mailbox creation produced, keyed by the request the client made.
-- A repeat of that request returns the same mailbox rather than a second
-- one, which matters because a route carries the write capability inside
-- it: a mailbox created twice is a route that stops working.
CREATE TABLE IF NOT EXISTS mailbox_requests (
    request_key  BLOB PRIMARY KEY,
    owner_device BLOB NOT NULL,
    mailbox_id   BLOB NOT NULL REFERENCES mailboxes(mailbox_id),
    read_hash    BLOB NOT NULL,
    write_hash   BLOB NOT NULL,
    created_at   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS notify_hints (
    device_id  BLOB PRIMARY KEY,
    url        TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
-- Queued envelopes (ADR-015 part 1). Each mailbox numbers its own queue
-- from mailboxes.next_seq, the row id is random and the expiry is coarse,
-- so neither a cursor, nor the order of rows, nor an expiry to the second
-- relates the copies of one message across mailboxes.
CREATE TABLE IF NOT EXISTS queued_envelopes (
    row_id      INTEGER PRIMARY KEY,
    mailbox_id  BLOB NOT NULL REFERENCES mailboxes(mailbox_id),
    seq         INTEGER NOT NULL,
    delivery_id BLOB NOT NULL,
    body_hash   BLOB NOT NULL,
    hpke_enc    BLOB NOT NULL,
    ciphertext  BLOB NOT NULL,
    expires_at  INTEGER NOT NULL,
    UNIQUE (mailbox_id, seq),
    UNIQUE (mailbox_id, delivery_id)
);
`

const (
	ScopeRead  = "read"
	ScopeWrite = "write"

	// MaxEnvelopeBytes is the largest ciphertext accepted (ARCHITECTURE §5:
	// 256 KiB after padding, plus AEAD tag and encapsulation overhead).
	MaxEnvelopeBytes = 256*1024 + 64
	// MaxMailboxQueue bounds pending envelopes per mailbox (prototype value).
	MaxMailboxQueue = 1000
	// DefaultEnvelopeTTL is the initial retention (ARCHITECTURE §5: 30 days).
	DefaultEnvelopeTTL = 30 * 24 * time.Hour
	// CapabilityTTL for prototype capabilities.
	CapabilityTTL = 365 * 24 * time.Hour
)

var (
	ErrCapability       = errors.New("capability: unknown, wrong scope, expired or revoked")
	ErrEnvelopeTooBig   = errors.New("envelope: too large")
	ErrMailboxFull      = errors.New("envelope: mailbox queue full")
	ErrDeliveryConflict = errors.New("envelope: delivery id reused with a different body")
	ErrUnknownMailbox   = errors.New("mailbox: unknown")
)

func (s *Store) initDelivery() error {
	if err := s.addNextSeq(); err != nil {
		return err
	}
	if _, err := s.db.Exec(deliverySchema); err != nil {
		return err
	}
	return s.migrateEnvelopeQueue(time.Now())
}

// addNextSeq gives a schema 5 mailboxes table its own queue counter. A
// fresh database gets the column from deliverySchema instead.
func (s *Store) addNextSeq() error {
	var tables, columns int
	if err := s.db.QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'mailboxes'`).Scan(&tables); err != nil {
		return err
	}
	if tables == 0 {
		return nil
	}
	if err := s.db.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('mailboxes') WHERE name = 'next_seq'`).Scan(&columns); err != nil {
		return err
	}
	if columns > 0 {
		return nil
	}
	_, err := s.db.Exec(`ALTER TABLE mailboxes ADD COLUMN next_seq INTEGER NOT NULL DEFAULT 1`)
	return err
}

// migrateEnvelopeQueue moves a schema 5 queue, numbered once for the whole
// realm, into queued_envelopes. Rows keep their numbers, so every cursor a
// client holds stays exact; each mailbox then continues above the highest
// number the old table ever handed out, which AUTOINCREMENT keeps in
// sqlite_sequence even after its row is gone. That starting point is the
// same for every mailbox and says nothing about any of them. The old
// numbers leave with their envelopes, within one retention period.
func (s *Store) migrateEnvelopeQueue(now time.Time) error {
	var legacy int
	if err := s.db.QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'envelopes'`).Scan(&legacy); err != nil {
		return err
	}
	if legacy == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var high int64
	if err := tx.QueryRow(`SELECT MAX(
		COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'envelopes'), 0),
		COALESCE((SELECT MAX(seq) FROM envelopes), 0))`).Scan(&high); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE mailboxes SET next_seq = ? WHERE next_seq <= ?`, high+1, high); err != nil {
		return err
	}
	// Random row ids and coarse expiries, as PutEnvelope writes them. The
	// CASE is coarseExpiry in SQL.
	if _, err := tx.Exec(`
		INSERT INTO queued_envelopes (row_id, mailbox_id, seq, delivery_id, body_hash, hpke_enc, ciphertext, expires_at)
		SELECT random() & 9223372036854775807, mailbox_id, seq, delivery_id, body_hash, hpke_enc, ciphertext,
		       CASE
		         WHEN expires_at - ?1 >= 172800 THEN expires_at - expires_at % 86400
		         WHEN expires_at - ?1 >= 7200 THEN expires_at - expires_at % 3600
		         WHEN expires_at - ?1 >= 120 THEN expires_at - expires_at % 60
		         ELSE expires_at
		       END
		FROM envelopes ORDER BY random()`, now.Unix()); err != nil {
		return err
	}
	if _, err := tx.Exec(`DROP TABLE envelopes`); err != nil {
		return err
	}
	return tx.Commit()
}

// coarseExpiry rounds an expiry down so that what is stored says the day of
// arrival, not the second (ADR-015 part 1). Lives of two days or more round
// to a UTC day, of two hours or more to the hour, of two minutes or more to
// the minute. The protocol allows a shorter effective expiry, which the
// relay declares; rounding never takes more than half the life away.
func coarseExpiry(expiry int64, now time.Time) int64 {
	life := expiry - now.Unix()
	for _, unit := range []int64{86400, 3600, 60} {
		if life >= 2*unit {
			return expiry - expiry%unit
		}
	}
	return expiry
}

// randomRowID is a row id that orders nothing.
func randomRowID() (int64, error) {
	b, err := randomBytes(8)
	if err != nil {
		return 0, err
	}
	return int64(binary.BigEndian.Uint64(b) >> 1), nil
}

// Mailbox is what the owner receives at creation; the relay keeps only the
// capability hashes.
type Mailbox struct {
	MailboxID       []byte
	ReadCapability  []byte
	WriteCapability []byte
}

func randomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	_, err := rand.Read(b)
	return b, err
}

func capHash(cap []byte) []byte {
	h := sha256.Sum256(cap)
	return h[:]
}

// CreateMailbox creates a mailbox for a device with one read and one write
// capability, in one transaction.
// CreateMailboxForRequest creates one mailbox for a client's request, or
// returns the one that request already created. The capabilities are the
// client's own bytes and only their hashes are stored, so a repeat can be
// answered exactly: the relay could not reconstruct capabilities it minted
// itself, and a route that embeds one cannot survive being reissued.
func (s *Store) CreateMailboxForRequest(
	ctx context.Context,
	ownerIdentity, ownerDevice, requestKey, readCap, writeCap []byte,
	now time.Time,
) (*Mailbox, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var mailboxID, device, readHash, writeHash []byte
	err = tx.QueryRowContext(ctx,
		`SELECT mailbox_id, owner_device, read_hash, write_hash FROM mailbox_requests WHERE request_key = ?`,
		requestKey).Scan(&mailboxID, &device, &readHash, &writeHash)
	switch {
	case err == nil:
		// The same request from the same device with the same capabilities
		// is the same request. Anything else reuses a key it does not own.
		if !bytes.Equal(device, ownerDevice) ||
			!bytes.Equal(readHash, capHash(readCap)) ||
			!bytes.Equal(writeHash, capHash(writeCap)) {
			return nil, ErrRequestConflict
		}
		return &Mailbox{
			MailboxID:       mailboxID,
			ReadCapability:  readCap,
			WriteCapability: writeCap,
		}, nil
	case !errors.Is(err, sql.ErrNoRows):
		return nil, err
	}

	id, err := randomBytes(16)
	if err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO mailboxes (mailbox_id, owner_identity, owner_device, created_at) VALUES (?, ?, ?, ?)`,
		id, ownerIdentity, ownerDevice, now.Unix()); err != nil {
		return nil, err
	}
	exp := now.Add(CapabilityTTL).Unix()
	for _, c := range []struct {
		cap   []byte
		scope string
	}{{readCap, ScopeRead}, {writeCap, ScopeWrite}} {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO capabilities (cap_hash, mailbox_id, scope, expires_at) VALUES (?, ?, ?, ?)`,
			capHash(c.cap), id, c.scope, exp); err != nil {
			// Capability hashes are unique across the realm, and a
			// collision is a token already promised to another mailbox.
			// Hash equality is not authorisation, so this is refused
			// rather than shared.
			if isConstraint(err) {
				return nil, ErrCapabilityInUse
			}
			return nil, err
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO mailbox_requests (request_key, owner_device, mailbox_id, read_hash, write_hash, created_at)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		requestKey, ownerDevice, id, capHash(readCap), capHash(writeCap), now.Unix()); err != nil {
		if isConstraint(err) {
			return nil, ErrRequestConflict
		}
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &Mailbox{MailboxID: id, ReadCapability: readCap, WriteCapability: writeCap}, nil
}

func (s *Store) CreateMailbox(ctx context.Context, ownerIdentity, ownerDevice []byte, now time.Time) (*Mailbox, error) {
	id, err := randomBytes(16)
	if err != nil {
		return nil, err
	}
	readCap, err := randomBytes(32)
	if err != nil {
		return nil, err
	}
	writeCap, err := randomBytes(32)
	if err != nil {
		return nil, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO mailboxes (mailbox_id, owner_identity, owner_device, created_at) VALUES (?, ?, ?, ?)`,
		id, ownerIdentity, ownerDevice, now.Unix()); err != nil {
		return nil, err
	}
	exp := now.Add(CapabilityTTL).Unix()
	for _, c := range []struct {
		cap   []byte
		scope string
	}{{readCap, ScopeRead}, {writeCap, ScopeWrite}} {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO capabilities (cap_hash, mailbox_id, scope, expires_at) VALUES (?, ?, ?, ?)`,
			capHash(c.cap), id, c.scope, exp); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &Mailbox{MailboxID: id, ReadCapability: readCap, WriteCapability: writeCap}, nil
}

// CheckCapability verifies a presented capability for a mailbox and scope.
func (s *Store) CheckCapability(ctx context.Context, mailboxID, capability []byte, scope string, now time.Time) error {
	var n int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM capabilities WHERE cap_hash = ? AND mailbox_id = ? AND scope = ? AND revoked = 0 AND expires_at > ?`,
		capHash(capability), mailboxID, scope, now.Unix()).Scan(&n)
	if err != nil {
		return err
	}
	if n != 1 {
		return ErrCapability
	}
	return nil
}

// PutResult reports how an envelope put was resolved.
type PutResult struct {
	EffectiveExpiry int64
	Duplicate       bool // same delivery id and same body: idempotent retry
	// WasEmpty is true when this envelope is the first one waiting in that
	// mailbox. Only that transition is worth a notification hint (M3.4):
	// anything finer would let whoever runs the notifier count messages.
	WasEmpty bool
}

// SetNotifyHint stores, replaces or (with an empty url) removes the
// notification endpoint of one device. The realm learns nothing new from
// it: it already knows that mailbox received an envelope.
func (s *Store) SetNotifyHint(ctx context.Context, deviceID []byte, url string, now time.Time) error {
	if url == "" {
		_, err := s.db.ExecContext(ctx, `DELETE FROM notify_hints WHERE device_id = ?`, deviceID)
		return err
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO notify_hints (device_id, url, created_at) VALUES (?, ?, ?)
		 ON CONFLICT(device_id) DO UPDATE SET url = excluded.url, created_at = excluded.created_at`,
		deviceID, url, now.Unix())
	return err
}

// NotifyHintForMailbox returns the endpoint configured by the device that
// owns a mailbox, or "" when there is none.
func (s *Store) NotifyHintForMailbox(ctx context.Context, mailboxID []byte) (string, error) {
	var url string
	err := s.db.QueryRowContext(ctx,
		`SELECT h.url FROM notify_hints h JOIN mailboxes m ON m.owner_device = h.device_id WHERE m.mailbox_id = ?`,
		mailboxID).Scan(&url)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return url, err
}

// PutEnvelope stores an envelope durably. A retry with identical bytes is
// idempotent; a different body under the same delivery id is a conflict.
func (s *Store) PutEnvelope(ctx context.Context, mailboxID, deliveryID, hpkeEnc, ciphertext []byte, requestedExpiry int64, now time.Time) (*PutResult, error) {
	if len(ciphertext) > MaxEnvelopeBytes || len(hpkeEnc) > 64 || len(deliveryID) == 0 || len(deliveryID) > 32 {
		return nil, ErrEnvelopeTooBig
	}
	maxExpiry := now.Add(DefaultEnvelopeTTL).Unix()
	expiry := requestedExpiry
	if expiry <= 0 || expiry > maxExpiry {
		expiry = maxExpiry
	}
	expiry = coarseExpiry(expiry, now)
	h := sha256.New()
	h.Write(hpkeEnc)
	h.Write(ciphertext)
	bodyHash := h.Sum(nil)

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var existingHash []byte
	var existingExpiry int64
	err = tx.QueryRowContext(ctx, `SELECT body_hash, expires_at FROM queued_envelopes WHERE mailbox_id = ? AND delivery_id = ?`, mailboxID, deliveryID).
		Scan(&existingHash, &existingExpiry)
	switch {
	case err == nil:
		if string(existingHash) != string(bodyHash) {
			return nil, ErrDeliveryConflict
		}
		return &PutResult{EffectiveExpiry: existingExpiry, Duplicate: true}, nil
	case !errors.Is(err, sql.ErrNoRows):
		return nil, err
	}

	var queued int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM queued_envelopes WHERE mailbox_id = ?`, mailboxID).Scan(&queued); err != nil {
		return nil, err
	}
	if queued >= MaxMailboxQueue {
		return nil, ErrMailboxFull
	}
	var seq int64
	err = tx.QueryRowContext(ctx,
		`UPDATE mailboxes SET next_seq = next_seq + 1 WHERE mailbox_id = ? RETURNING next_seq - 1`,
		mailboxID).Scan(&seq)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return nil, ErrUnknownMailbox
	case err != nil:
		return nil, err
	}
	rowID, err := randomRowID()
	if err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO queued_envelopes (row_id, mailbox_id, seq, delivery_id, body_hash, hpke_enc, ciphertext, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		rowID, mailboxID, seq, deliveryID, bodyHash, hpkeEnc, ciphertext, expiry); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &PutResult{EffectiveExpiry: expiry, WasEmpty: queued == 0}, nil
}

// Envelope is one queued item as returned to the owner.
type Envelope struct {
	Seq        uint64
	DeliveryID []byte
	HpkeEnc    []byte
	Ciphertext []byte
}

// FetchEnvelopes returns up to `limit` envelopes with seq > cursor, oldest
// first, and the cursor to continue from.
func (s *Store) FetchEnvelopes(ctx context.Context, mailboxID []byte, cursor uint64, limit int, now time.Time) ([]Envelope, uint64, error) {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT seq, delivery_id, hpke_enc, ciphertext FROM queued_envelopes WHERE mailbox_id = ? AND seq > ? AND expires_at > ? ORDER BY seq LIMIT ?`,
		mailboxID, cursor, now.Unix(), limit)
	if err != nil {
		return nil, cursor, err
	}
	defer rows.Close()
	var out []Envelope
	next := cursor
	for rows.Next() {
		var e Envelope
		if err := rows.Scan(&e.Seq, &e.DeliveryID, &e.HpkeEnc, &e.Ciphertext); err != nil {
			return nil, cursor, err
		}
		out = append(out, e)
		next = e.Seq
	}
	return out, next, rows.Err()
}

// AckEnvelopes deletes the named envelopes of a mailbox. Idempotent.
func (s *Store) AckEnvelopes(ctx context.Context, mailboxID []byte, deliveryIDs [][]byte) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, d := range deliveryIDs {
		if _, err := tx.ExecContext(ctx, `DELETE FROM queued_envelopes WHERE mailbox_id = ? AND delivery_id = ?`, mailboxID, d); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ExpireEnvelopes removes envelopes past their TTL. Called periodically.
func (s *Store) ExpireEnvelopes(ctx context.Context, now time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM queued_envelopes WHERE expires_at <= ?`, now.Unix())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// SweepResult counts what a periodic sweep removed.
type SweepResult struct {
	Envelopes int64
	Invites   int64
}

// Sweep removes expired envelopes and expired or exhausted invites. It is
// idempotent and safe to run on a timer; the relay logs only the counts.
func (s *Store) Sweep(ctx context.Context, now time.Time) (SweepResult, error) {
	var r SweepResult
	n, err := s.ExpireEnvelopes(ctx, now)
	if err != nil {
		return r, err
	}
	r.Envelopes = n
	res, err := s.db.ExecContext(ctx, `DELETE FROM invites WHERE (expires_at <= ? OR uses_left <= 0) AND token_hash NOT IN (SELECT token_hash FROM issued_invitations)`, now.Unix())
	if err != nil {
		return r, err
	}
	r.Invites, _ = res.RowsAffected()
	return r, s.sweepInvitationHistory(ctx, now)
}
