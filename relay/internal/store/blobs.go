package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Blobs (PROTOCOL §7, ADR-004): ciphertext files under <data>/blobs, staged
// under <data>/staging until committed. The database row is the source of
// truth for state; the file is renamed into place before the row moves to
// `committed`, and a reconciler removes files without a committed row.
const blobSchema = `
CREATE TABLE IF NOT EXISTS blobs (
    blob_id        BLOB PRIMARY KEY,
    owner_identity BLOB NOT NULL REFERENCES realm_memberships(identity_id),
    read_cap_hash  BLOB NOT NULL,
    declared_size  INTEGER NOT NULL,
    stored_size    INTEGER NOT NULL DEFAULT 0,
    state          TEXT NOT NULL,
    created_at     INTEGER NOT NULL,
    expires_at     INTEGER
);
`

const (
	BlobStaging   = "staging"
	BlobCommitted = "committed"

	// MaxBlobBytes is the file limit (ARCHITECTURE §5: 25 MiB).
	MaxBlobBytes = 25 * 1024 * 1024
	// MaxBlobChunk bounds one chunk frame.
	MaxBlobChunk = 60 * 1024
	// DefaultBlobTTL from commit (ARCHITECTURE §5: 30 days).
	DefaultBlobTTL = 30 * 24 * time.Hour
	// StagingTTL for uploads that never commit.
	StagingTTL = 24 * time.Hour
	// QuotaPerIdentity bounds committed bytes per member (prototype value).
	QuotaPerIdentity = 200 * 1024 * 1024
)

var (
	ErrBlobUnknown   = errors.New("blob: unknown or not readable with that capability")
	ErrBlobState     = errors.New("blob: wrong state for this operation")
	ErrBlobOffset    = errors.New("blob: chunk offset is not the current end of the staging file")
	ErrBlobSize      = errors.New("blob: size exceeds the declared size or the limit")
	ErrBlobHash      = errors.New("blob: ciphertext hash does not match")
	ErrBlobQuota     = errors.New("blob: identity quota exceeded")
	ErrBlobExpired   = errors.New("blob: expired")
	ErrBlobsDisabled = errors.New("blob: no blob directory configured")
)

// BlobStore couples the database with the two directories.
type BlobStore struct {
	s          *Store
	blobsDir   string
	stagingDir string
}

func (s *Store) initBlobs() error {
	_, err := s.db.Exec(blobSchema)
	return err
}

// Blobs opens the file store under dataDir and reconciles leftovers.
func (s *Store) Blobs(dataDir string) (*BlobStore, error) {
	b := &BlobStore{s: s, blobsDir: filepath.Join(dataDir, "blobs"), stagingDir: filepath.Join(dataDir, "staging")}
	for _, d := range []string{b.blobsDir, b.stagingDir} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return nil, err
		}
	}
	return b, b.Reconcile(context.Background())
}

func (b *BlobStore) stagingPath(id []byte) string {
	return filepath.Join(b.stagingDir, hex.EncodeToString(id))
}
func (b *BlobStore) finalPath(id []byte) string {
	return filepath.Join(b.blobsDir, hex.EncodeToString(id))
}

// Begin creates a staging blob for a member and returns its id and read capability.
func (b *BlobStore) Begin(ctx context.Context, ownerIdentity []byte, size uint64, now time.Time) (id, readCap []byte, err error) {
	if size == 0 || size > MaxBlobBytes {
		return nil, nil, ErrBlobSize
	}
	var used sql.NullInt64
	if err := b.s.db.QueryRowContext(ctx, `SELECT SUM(stored_size) FROM blobs WHERE owner_identity = ? AND state = ?`, ownerIdentity, BlobCommitted).Scan(&used); err != nil {
		return nil, nil, err
	}
	if used.Valid && used.Int64+int64(size) > QuotaPerIdentity {
		return nil, nil, ErrBlobQuota
	}
	id, err = randomBytes(16)
	if err != nil {
		return nil, nil, err
	}
	readCap, err = randomBytes(32)
	if err != nil {
		return nil, nil, err
	}
	if _, err := b.s.db.ExecContext(ctx,
		`INSERT INTO blobs (blob_id, owner_identity, read_cap_hash, declared_size, state, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		id, ownerIdentity, capHash(readCap), size, BlobStaging, now.Unix()); err != nil {
		return nil, nil, err
	}
	f, err := os.OpenFile(b.stagingPath(id), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, nil, err
	}
	f.Close()
	return id, readCap, nil
}

// Chunk appends data at `offset`, which must be the current staging size.
func (b *BlobStore) Chunk(ctx context.Context, ownerIdentity, id []byte, offset uint64, data []byte) error {
	if len(data) == 0 || len(data) > MaxBlobChunk {
		return ErrBlobSize
	}
	var declared, stored int64
	var state string
	err := b.s.db.QueryRowContext(ctx, `SELECT declared_size, stored_size, state FROM blobs WHERE blob_id = ? AND owner_identity = ?`, id, ownerIdentity).
		Scan(&declared, &stored, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrBlobUnknown
	}
	if err != nil {
		return err
	}
	if state != BlobStaging {
		return ErrBlobState
	}
	if uint64(stored) != offset {
		return ErrBlobOffset
	}
	if stored+int64(len(data)) > declared {
		return ErrBlobSize
	}
	f, err := os.OpenFile(b.stagingPath(id), os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	_, err = b.s.db.ExecContext(ctx, `UPDATE blobs SET stored_size = stored_size + ? WHERE blob_id = ?`, len(data), id)
	return err
}

// Commit verifies size and hash, fsyncs, renames into place, then marks the
// row committed with its expiry. Returns the effective expiry.
func (b *BlobStore) Commit(ctx context.Context, ownerIdentity, id, ciphertextHash []byte, requestedExpiry int64, now time.Time) (int64, error) {
	var declared, stored int64
	var state string
	err := b.s.db.QueryRowContext(ctx, `SELECT declared_size, stored_size, state FROM blobs WHERE blob_id = ? AND owner_identity = ?`, id, ownerIdentity).
		Scan(&declared, &stored, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrBlobUnknown
	}
	if err != nil {
		return 0, err
	}
	if state != BlobStaging {
		return 0, ErrBlobState
	}
	if stored != declared {
		return 0, ErrBlobSize
	}
	f, err := os.Open(b.stagingPath(id))
	if err != nil {
		return 0, err
	}
	h := sha256.New()
	buf := make([]byte, 64*1024)
	for {
		n, rerr := f.Read(buf)
		h.Write(buf[:n])
		if rerr != nil {
			break
		}
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return 0, err
	}
	f.Close()
	if string(h.Sum(nil)) != string(ciphertextHash) {
		return 0, ErrBlobHash
	}
	maxExpiry := now.Add(DefaultBlobTTL).Unix()
	expiry := requestedExpiry
	if expiry <= 0 || expiry > maxExpiry {
		expiry = maxExpiry
	}
	if err := os.Rename(b.stagingPath(id), b.finalPath(id)); err != nil {
		return 0, err
	}
	if _, err := b.s.db.ExecContext(ctx, `UPDATE blobs SET state = ?, expires_at = ? WHERE blob_id = ?`, BlobCommitted, expiry, id); err != nil {
		return 0, err
	}
	return expiry, nil
}

// Read returns `length` bytes at `offset` of a committed blob readable with
// `readCap`, and the total size.
func (b *BlobStore) Read(ctx context.Context, id, readCap []byte, offset uint64, length int, now time.Time) ([]byte, uint64, error) {
	var size, expires int64
	err := b.s.db.QueryRowContext(ctx,
		`SELECT stored_size, expires_at FROM blobs WHERE blob_id = ? AND read_cap_hash = ? AND state = ?`,
		id, capHash(readCap), BlobCommitted).Scan(&size, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, 0, ErrBlobUnknown
	}
	if err != nil {
		return nil, 0, err
	}
	if expires <= now.Unix() {
		return nil, 0, ErrBlobExpired
	}
	if length <= 0 || length > MaxBlobChunk {
		length = MaxBlobChunk
	}
	if offset >= uint64(size) {
		return []byte{}, uint64(size), nil
	}
	f, err := os.Open(b.finalPath(id))
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	buf := make([]byte, length)
	n, err := f.ReadAt(buf, int64(offset))
	if err != nil && n == 0 {
		return nil, 0, err
	}
	return buf[:n], uint64(size), nil
}

// Sweep removes expired committed blobs and stale staging uploads.
func (b *BlobStore) Sweep(ctx context.Context, now time.Time) (int64, error) {
	rows, err := b.s.db.QueryContext(ctx,
		`SELECT blob_id, state FROM blobs WHERE (state = ? AND expires_at <= ?) OR (state = ? AND created_at <= ?)`,
		BlobCommitted, now.Unix(), BlobStaging, now.Add(-StagingTTL).Unix())
	if err != nil {
		return 0, err
	}
	type victim struct {
		id    []byte
		state string
	}
	var victims []victim
	for rows.Next() {
		var v victim
		if err := rows.Scan(&v.id, &v.state); err != nil {
			rows.Close()
			return 0, err
		}
		victims = append(victims, v)
	}
	rows.Close()
	var n int64
	for _, v := range victims {
		path := b.finalPath(v.id)
		if v.state == BlobStaging {
			path = b.stagingPath(v.id)
		}
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return n, err
		}
		if _, err := b.s.db.ExecContext(ctx, `DELETE FROM blobs WHERE blob_id = ?`, v.id); err != nil {
			return n, err
		}
		n++
	}
	return n, nil
}

// Reconcile removes files that have no matching row (crash between rename
// and row update, or between staging create and row insert).
func (b *BlobStore) Reconcile(ctx context.Context) error {
	for _, dir := range []string{b.blobsDir, b.stagingDir} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return err
		}
		for _, e := range entries {
			id, err := hex.DecodeString(e.Name())
			if err != nil {
				continue
			}
			var state string
			err = b.s.db.QueryRowContext(ctx, `SELECT state FROM blobs WHERE blob_id = ?`, id).Scan(&state)
			switch {
			case errors.Is(err, sql.ErrNoRows):
				_ = os.Remove(filepath.Join(dir, e.Name()))
			case err != nil:
				return err
			case dir == b.blobsDir && state != BlobCommitted:
				// File renamed but row not updated: finish the commit is not
				// possible without the hash check; treat as orphan.
				_ = os.Remove(filepath.Join(dir, e.Name()))
				_, _ = b.s.db.ExecContext(ctx, `DELETE FROM blobs WHERE blob_id = ?`, id)
			}
		}
	}
	return nil
}

func (b *BlobStore) String() string {
	return fmt.Sprintf("blobs at %s (staging %s)", b.blobsDir, b.stagingDir)
}
