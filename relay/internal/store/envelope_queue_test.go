package store

import (
	"bytes"
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

func TestCoarseExpiry(t *testing.T) {
	now := time.Date(2026, 10, 2, 13, 47, 21, 0, time.UTC)
	at := func(d time.Duration) int64 { return now.Add(d).Unix() }
	for _, c := range []struct {
		expiry, want int64
	}{
		{at(30 * 24 * time.Hour), time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC).Unix()},
		{at(48 * time.Hour), time.Date(2026, 10, 4, 0, 0, 0, 0, time.UTC).Unix()},
		{at(47 * time.Hour), time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC).Unix()},
		{at(2 * time.Hour), time.Date(2026, 10, 2, 15, 0, 0, 0, time.UTC).Unix()},
		{at(119 * time.Minute), time.Date(2026, 10, 2, 15, 46, 0, 0, time.UTC).Unix()},
		{at(time.Minute), at(time.Minute)},
	} {
		got := coarseExpiry(c.expiry, now)
		if got != c.want {
			t.Errorf("coarseExpiry(%d) = %d, want %d", c.expiry, got, c.want)
		}
		if got <= now.Unix() || c.expiry-got > (c.expiry-now.Unix())/2 {
			t.Errorf("coarseExpiry(%d) = %d took more than half the life", c.expiry, got)
		}
	}
}

// A message to several devices leaves nothing in the database that groups
// its copies: each mailbox numbers its own queue, row ids are random and the
// expiry says the day, not the second (ADR-015 part 1, THREAT_MODEL I-15).
func TestFanOutLeavesNoRealmWideOrder(t *testing.T) {
	s, ctx, now := memberStore(t)
	var boxes []*Mailbox
	for i := byte(0); i < 6; i++ {
		mb, err := s.CreateMailbox(ctx, []byte{1, 1}, []byte{1, i}, now)
		if err != nil {
			t.Fatal(err)
		}
		boxes = append(boxes, mb)
	}
	for msg := 0; msg < 3; msg++ {
		for _, mb := range boxes {
			id := []byte(fmt.Sprintf("m%d", msg))
			r, err := s.PutEnvelope(ctx, mb.MailboxID, id, []byte("enc"), []byte("ct"), 0, now)
			if err != nil {
				t.Fatal(err)
			}
			if r.EffectiveExpiry%86400 != 0 {
				t.Fatalf("expiry %d is not a day boundary", r.EffectiveExpiry)
			}
		}
	}
	for _, mb := range boxes {
		items, next, err := s.FetchEnvelopes(ctx, mb.MailboxID, 0, 10, now)
		if err != nil || len(items) != 3 || next != 3 {
			t.Fatalf("fetch: %v %d next %d", err, len(items), next)
		}
		for i, e := range items {
			if e.Seq != uint64(i+1) {
				t.Fatalf("mailbox sequence %d at position %d", e.Seq, i)
			}
		}
	}
	rows, err := s.db.Query(`SELECT row_id FROM queued_envelopes ORDER BY seq, mailbox_id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	consecutive := 0
	for i := 1; i < len(ids); i++ {
		if ids[i] == ids[i-1]+1 {
			consecutive++
		}
	}
	if consecutive > 0 {
		t.Fatalf("row ids follow arrival: %v", ids)
	}
}

// A schema 5 database keeps every cursor its clients hold: old envelopes keep
// their numbers, and every mailbox continues above the highest number the old
// table handed out, including numbers of envelopes already acknowledged.
func TestEnvelopeQueueMigrationKeepsCursors(t *testing.T) {
	ctx := context.Background()
	now := time.Now()
	path := filepath.Join(t.TempDir(), "realm.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.CreateInvite(ctx, []byte("t"), "member", now.Add(time.Hour), 1); err != nil {
		t.Fatal(err)
	}
	if err := s.RedeemInvite(ctx, []byte("t"), now, enrollment(1), nil); err != nil {
		t.Fatal(err)
	}
	a, err := s.CreateMailbox(ctx, []byte{1, 1}, []byte{1, 1}, now)
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.CreateMailbox(ctx, []byte{1, 1}, []byte{1, 2}, now)
	if err != nil {
		t.Fatal(err)
	}
	// Rebuild the schema 5 queue: one realm-wide AUTOINCREMENT sequence,
	// expiries to the second, no per-mailbox counter.
	exact := now.Add(DefaultEnvelopeTTL).Unix() | 1
	if _, err := s.db.Exec(`
		DROP TABLE queued_envelopes;
		ALTER TABLE mailboxes DROP COLUMN next_seq;
		CREATE TABLE envelopes (
		    seq         INTEGER PRIMARY KEY AUTOINCREMENT,
		    mailbox_id  BLOB NOT NULL REFERENCES mailboxes(mailbox_id),
		    delivery_id BLOB NOT NULL,
		    body_hash   BLOB NOT NULL,
		    hpke_enc    BLOB NOT NULL,
		    ciphertext  BLOB NOT NULL,
		    expires_at  INTEGER NOT NULL,
		    UNIQUE (mailbox_id, delivery_id)
		);
		DELETE FROM schema_migrations WHERE version >= 6;
		INSERT OR IGNORE INTO schema_migrations VALUES (5, 0);`); err != nil {
		t.Fatal(err)
	}
	put := func(mb []byte, id string) {
		if _, err := s.db.Exec(
			`INSERT INTO envelopes (mailbox_id, delivery_id, body_hash, hpke_enc, ciphertext, expires_at) VALUES (?, ?, x'00', x'00', x'00', ?)`,
			mb, []byte(id), exact); err != nil {
			t.Fatal(err)
		}
	}
	put(a.MailboxID, "a1") // 1
	put(b.MailboxID, "b1") // 2
	put(a.MailboxID, "a2") // 3
	put(b.MailboxID, "b2") // 4, acknowledged below: the high mark stays 4
	if _, err := s.db.Exec(`DELETE FROM envelopes WHERE seq = 4`); err != nil {
		t.Fatal(err)
	}
	s.Close()

	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var legacy, version int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'envelopes'`).Scan(&legacy); err != nil || legacy != 0 {
		t.Fatalf("legacy table left behind: %v %d", err, legacy)
	}
	if err := s.db.QueryRow(`SELECT MAX(version) FROM schema_migrations`).Scan(&version); err != nil || version != SchemaVersion {
		t.Fatalf("schema version %d: %v", version, err)
	}

	// A client of a that had read up to 1 sees a2 with its old number.
	items, next, err := s.FetchEnvelopes(ctx, a.MailboxID, 1, 10, now)
	if err != nil || len(items) != 1 || items[0].Seq != 3 || !bytes.Equal(items[0].DeliveryID, []byte("a2")) || next != 3 {
		t.Fatalf("migrated fetch: %v %+v next %d", err, items, next)
	}
	// A client of b that had read up to 4 (b2, since acknowledged) must see
	// the next envelope, so new numbers start above 4 in every mailbox.
	for _, mb := range []*Mailbox{a, b} {
		if _, err := s.PutEnvelope(ctx, mb.MailboxID, []byte("new"), []byte("enc"), []byte("ct"), 0, now); err != nil {
			t.Fatal(err)
		}
	}
	items, _, err = s.FetchEnvelopes(ctx, b.MailboxID, 4, 10, now)
	if err != nil || len(items) != 1 || items[0].Seq != 5 {
		t.Fatalf("b after migration: %v %+v", err, items)
	}
	items, _, err = s.FetchEnvelopes(ctx, a.MailboxID, 3, 10, now)
	if err != nil || len(items) != 1 || items[0].Seq != 5 {
		t.Fatalf("a after migration: %v %+v", err, items)
	}
	var stale int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM queued_envelopes WHERE expires_at % 86400 != 0`).Scan(&stale); err != nil || stale != 0 {
		t.Fatalf("%d expiries kept to the second: %v", stale, err)
	}
}
