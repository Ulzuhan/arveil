package store

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

func diskStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestWriteTransactionsReserveWriterBeforeReading(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s := diskStore(t)
	// Hold several connections so the policy is exercised on new pool
	// connections, not just the one Open happened to initialize.
	var conns []*sql.Conn
	for range 4 {
		c, err := s.db.Conn(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		conns = append(conns, c)
	}
	other, err := s.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	// Fail immediately instead of using sleep or racing goroutines to
	// observe whether a writer reservation exists.
	if _, err := other.ExecContext(ctx, `PRAGMA busy_timeout = 0`); err != nil {
		t.Fatal(err)
	}
	insert := `INSERT INTO invites (token_hash, role, expires_at, uses_left) VALUES (?, 'member', 1, 1)`
	for i, c := range conns {
		tx, err := c.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		var count int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM invite_redemptions`).Scan(&count); err != nil {
			t.Fatal(err)
		}
		// WAL readers must remain available while this transaction owns
		// the writer reservation.
		if err := other.QueryRowContext(ctx, `SELECT COUNT(*) FROM invites`).Scan(&count); err != nil {
			t.Fatalf("reader blocked by a write transaction: %v", err)
		}
		_, competingErr := other.ExecContext(ctx, insert, []byte{byte(i), 0})
		if competingErr == nil {
			// With deferred BEGIN the other connection commits after our
			// SELECT. The following upgrade then fails with BUSY_SNAPSHOT,
			// even though every connection has a busy timeout.
			_, upgradeErr := tx.ExecContext(ctx, insert, []byte{byte(i), 1})
			t.Fatalf("connection %d allowed a competing writer; read-to-write upgrade: %v", i, upgradeErr)
		}
		var coded interface{ Code() int }
		if !errors.As(competingErr, &coded) || coded.Code() != 5 { // SQLITE_BUSY
			t.Fatalf("expected competing writer to be busy: %v", competingErr)
		}
		if _, err := tx.ExecContext(ctx, insert, []byte{byte(i), 1}); err != nil {
			t.Fatalf("reserved writer could not write: %v", err)
		}
		if err := tx.Commit(); err != nil {
			t.Fatal(err)
		}
		if _, err := other.ExecContext(ctx, insert, []byte{byte(i), 0}); err != nil {
			t.Fatalf("writer reservation not released on commit: %v", err)
		}
	}
}

func TestConcurrentEnrollmentAndMailboxRetriesWithSweep(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s := diskStore(t)
	now := time.Now()
	token := []byte("disposable-invite-hash")
	if err := s.CreateInvite(ctx, token, "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	e := enrollment(1)
	request := bytes.Repeat([]byte{1}, 16)
	readCap, writeCap := bytes.Repeat([]byte{2}, 32), bytes.Repeat([]byte{3}, 32)
	const workers = 8
	start := make(chan struct{})
	type result struct {
		mailbox *Mailbox
		err     error
	}
	results := make(chan result, workers)
	for range workers {
		go func() {
			<-start
			if err := s.RedeemInvite(ctx, token, now, e, nil); err != nil && !errors.Is(err, ErrAlreadyRedeemed) {
				results <- result{err: fmt.Errorf("enrollment: %w", err)}
				return
			}
			mb, err := s.CreateMailboxForRequest(ctx, e.IdentityID, e.DeviceID, request, readCap, writeCap, now)
			results <- result{mb, err}
		}()
	}
	swept := make(chan error, 1)
	go func() {
		<-start
		for range 24 {
			if _, err := s.Sweep(ctx, now); err != nil {
				swept <- err
				return
			}
		}
		swept <- nil
	}()
	close(start)
	var first *Mailbox
	for range workers {
		r := <-results
		if r.err != nil {
			t.Errorf("retry during cleanup: %v", r.err)
			continue
		}
		if first == nil {
			first = r.mailbox
		}
		if !bytes.Equal(first.MailboxID, r.mailbox.MailboxID) ||
			!bytes.Equal(readCap, r.mailbox.ReadCapability) || !bytes.Equal(writeCap, r.mailbox.WriteCapability) {
			t.Error("concurrent retry changed the mailbox or capabilities")
		}
	}
	if err := <-swept; err != nil {
		t.Errorf("cleanup: %v", err)
	}
	for _, table := range []string{"realm_memberships", "device_credentials", "invite_redemptions", "mailboxes", "mailbox_requests"} {
		if n, err := s.Count(ctx, table); err != nil || n != 1 {
			t.Errorf("%s: rows=%d err=%v", table, n, err)
		}
	}
}

func TestConcurrentKeyPackageClaimsConsumeDistinctPackages(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s := diskStore(t)
	now := time.Now()
	e := enrollment(1)
	if err := s.CreateInvite(ctx, []byte("test-invite"), "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, []byte("test-invite"), now, e, nil); err != nil {
		t.Fatal(err)
	}
	const workers = 8
	batch := make([][]byte, workers)
	for i := range batch {
		batch[i] = []byte{byte(i), 1}
	}
	if err := s.PublishKeyPackages(ctx, e.IdentityID, e.DeviceID, batch, now); err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	type result struct {
		pkg []byte
		err error
	}
	results := make(chan result, workers)
	for range workers {
		go func() {
			<-start
			p, err := s.ClaimKeyPackage(ctx, e.IdentityID, nil)
			results <- result{p, err}
		}()
	}
	close(start)
	seen := make(map[string]bool)
	for range workers {
		r := <-results
		if r.err != nil {
			t.Errorf("claim: %v", r.err)
			continue
		}
		if seen[string(r.pkg)] {
			t.Error("same package returned to two claimants")
		}
		seen[string(r.pkg)] = true
	}
	if n, err := s.AvailableKeyPackages(ctx, e.DeviceID); err != nil || n != 0 || len(seen) != workers {
		t.Fatalf("claimed=%d remaining=%d err=%v", len(seen), n, err)
	}
}
