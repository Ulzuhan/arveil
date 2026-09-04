package store

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func blobStore(t *testing.T) (*BlobStore, context.Context, time.Time, string) {
	t.Helper()
	s, ctx, now := memberStore(t)
	dir := t.TempDir()
	b, err := s.Blobs(dir)
	if err != nil {
		t.Fatal(err)
	}
	return b, ctx, now, dir
}

func TestBlobUploadCommitReadAndSweep(t *testing.T) {
	b, ctx, now, dir := blobStore(t)
	owner := []byte{1, 1}
	data := make([]byte, 150_000)
	rand.Read(data)
	sum := sha256.Sum256(data)

	id, cap, err := b.Begin(ctx, owner, uint64(len(data)), now)
	if err != nil {
		t.Fatal(err)
	}
	// Chunks must be contiguous.
	if err := b.Chunk(ctx, owner, id, 10, data[:100]); !errors.Is(err, ErrBlobOffset) {
		t.Fatalf("gap accepted: %v", err)
	}
	for off := 0; off < len(data); off += MaxBlobChunk {
		end := off + MaxBlobChunk
		if end > len(data) {
			end = len(data)
		}
		if err := b.Chunk(ctx, owner, id, uint64(off), data[off:end]); err != nil {
			t.Fatal(err)
		}
	}
	// Wrong hash refused; nothing moves.
	if _, err := b.Commit(ctx, owner, id, bytes.Repeat([]byte{1}, 32), 0, now); !errors.Is(err, ErrBlobHash) {
		t.Fatalf("bad hash accepted: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "blobs")); err != nil {
		t.Fatal(err)
	}
	exp, err := b.Commit(ctx, owner, id, sum[:], now.Add(2*time.Second).Unix(), now)
	if err != nil {
		t.Fatal(err)
	}
	if exp != now.Add(2*time.Second).Unix() {
		t.Fatalf("expiry %d", exp)
	}
	// Reads with the capability, in chunks; wrong capability refused.
	var got []byte
	for {
		chunk, total, err := b.Read(ctx, id, cap, uint64(len(got)), MaxBlobChunk, now)
		if err != nil {
			t.Fatal(err)
		}
		if total != uint64(len(data)) {
			t.Fatalf("total %d", total)
		}
		if len(chunk) == 0 {
			break
		}
		got = append(got, chunk...)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("read back mismatch")
	}
	if _, _, err := b.Read(ctx, id, bytes.Repeat([]byte{9}, 32), 0, 10, now); !errors.Is(err, ErrBlobUnknown) {
		t.Fatalf("wrong capability: %v", err)
	}
	// Expired: refused, then swept with its file.
	if _, _, err := b.Read(ctx, id, cap, 0, 10, now.Add(3*time.Second)); !errors.Is(err, ErrBlobExpired) {
		t.Fatalf("expired blob readable: %v", err)
	}
	n, err := b.Sweep(ctx, now.Add(3*time.Second))
	if err != nil || n != 1 {
		t.Fatalf("sweep %d %v", n, err)
	}
	entries, _ := os.ReadDir(filepath.Join(dir, "blobs"))
	if len(entries) != 0 {
		t.Fatal("blob file not removed")
	}
}

func TestStagedOffsetDrivesResume(t *testing.T) {
	b, ctx, now, _ := blobStore(t)
	owner := []byte{1, 1}
	data := make([]byte, 100_000)
	rand.Read(data)
	sum := sha256.Sum256(data)
	id, _, err := b.Begin(ctx, owner, uint64(len(data)), now)
	if err != nil {
		t.Fatal(err)
	}
	if off, err := b.StagedOffset(ctx, owner, id); err != nil || off != 0 {
		t.Fatalf("fresh offset: %d %v", off, err)
	}
	if err := b.Chunk(ctx, owner, id, 0, data[:MaxBlobChunk]); err != nil {
		t.Fatal(err)
	}
	off, err := b.StagedOffset(ctx, owner, id)
	if err != nil || off != MaxBlobChunk {
		t.Fatalf("offset after one chunk: %d %v", off, err)
	}
	// Rewriting bytes the realm already holds is refused, so a resumed
	// upload cannot quietly replace what was sent before.
	if err := b.Chunk(ctx, owner, id, 0, data[:10]); !errors.Is(err, ErrBlobOffset) {
		t.Fatalf("rewrite accepted: %v", err)
	}
	// Another member learns nothing and cannot resume it.
	if _, err := b.StagedOffset(ctx, []byte{2, 2}, id); !errors.Is(err, ErrBlobUnknown) {
		t.Fatalf("foreign offset: %v", err)
	}
	if err := b.Chunk(ctx, owner, id, off, data[off:]); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Commit(ctx, owner, id, sum[:], 0, now); err != nil {
		t.Fatal(err)
	}
	if _, err := b.StagedOffset(ctx, owner, id); !errors.Is(err, ErrBlobState) {
		t.Fatalf("committed blob still resumable: %v", err)
	}
}

func TestBlobLimitsAndReconcile(t *testing.T) {
	b, ctx, now, dir := blobStore(t)
	owner := []byte{1, 1}
	if _, _, err := b.Begin(ctx, owner, MaxBlobBytes+1, now); !errors.Is(err, ErrBlobSize) {
		t.Fatalf("oversize begin: %v", err)
	}
	id, _, _ := b.Begin(ctx, owner, 10, now)
	if err := b.Chunk(ctx, owner, id, 0, make([]byte, 11)); !errors.Is(err, ErrBlobSize) {
		t.Fatalf("over-declared chunk: %v", err)
	}
	if _, err := b.Commit(ctx, owner, id, make([]byte, 32), 0, now); !errors.Is(err, ErrBlobSize) {
		t.Fatalf("incomplete commit: %v", err)
	}
	// Orphan files are removed by reconciliation.
	os.WriteFile(filepath.Join(dir, "blobs", "00ff"), []byte("x"), 0o600)
	if err := b.Reconcile(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "blobs", "00ff")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("orphan not removed")
	}
	// Stale staging uploads are swept.
	n, err := b.Sweep(ctx, now.Add(StagingTTL+time.Hour))
	if err != nil || n != 1 {
		t.Fatalf("staging sweep %d %v", n, err)
	}
}
