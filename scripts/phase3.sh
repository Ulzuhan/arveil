#!/usr/bin/env bash
# Phase 3 acceptance (docs/PHASE3.md). Each section maps to a milestone.
# Exit 0 only if every check passes. ARVEIL_P3_KEEP=1 keeps the data dir.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
PORT="${ARVEIL_P3_PORT:-18480}"
RELAY="$ROOT/relay/bin/arveil-relay"
CLI="$ROOT/core/target/debug/arveil"
RELAY_PID=""

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
cleanup() {
  if [ -n "${SINK_PID:-}" ]; then kill "$SINK_PID" 2>/dev/null || true; wait "$SINK_PID" 2>/dev/null || true; fi
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  [ -n "${ARVEIL_P3_KEEP:-}" ] && echo "data kept in $DATA" || rm -rf "$DATA"
}
trap cleanup EXIT

start_relay() {
  "$RELAY" -data-dir "$DATA/relay" -listen "127.0.0.1:$PORT" -sweep-interval 1s "$@" > "$DATA/relay.out" 2>> "$DATA/relay.err" &
  RELAY_PID=$!
  for _ in $(seq 1 50); do grep -q '^bootstrap: ' "$DATA/relay.out" && return; sleep 0.1; done
  fail "relay did not start"
}
stop_relay() { kill "$RELAY_PID"; wait "$RELAY_PID" 2>/dev/null || true; RELAY_PID=""; }
invite() { "$RELAY" invite -data-dir "$DATA/relay" | sed -n 's/^invite: //p'; }
route_of() { sed -n 's/^route: //p' "$1"; }
expect_fail() { local out="$1"; shift; if "$@" > "$out" 2>&1; then return 1; fi; return 0; }
# Wait until a file contains a pattern, or give up after ~20 seconds.
wait_for() {
  for _ in $(seq 1 200); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  echo "--- $1 ---"; cat "$1" 2>/dev/null || true
  fail "timed out waiting for '$2' in $1"
}

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay && go build -o bin/arveil-hintsink ./cmd/arveil-hintsink)
(cd "$ROOT/core" && cargo build -q -p arveil-cli)

start_relay
BOOTSTRAP="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"
"$CLI" enroll --data-dir "$DATA/alice" "$BOOTSTRAP" "$(invite)" > "$DATA/alice.enroll"

step "M3.1 pairing: two devices meet through the realm and show the same number"
"$CLI" device pair --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" > "$DATA/laptop.pair" 2>&1 &
PAIR_PID=$!
wait_for "$DATA/laptop.pair" "^code: "
CODE="$(sed -n 's/^code: //p' "$DATA/laptop.pair")"
"$CLI" device pair-approve --data-dir "$DATA/alice" "$BOOTSTRAP" "$CODE" | tee "$DATA/alice.approve"
wait "$PAIR_PID" || fail "the new device gave up during pairing"
SAS_ADMIN="$(sed -n 's/^verification code: //p' "$DATA/alice.approve")"
SAS_NEW="$(sed -n 's/^verification code: //p' "$DATA/laptop.pair")"
[ -n "$SAS_ADMIN" ] || fail "the administration device showed no number"
[ "$SAS_ADMIN" = "$SAS_NEW" ] || fail "the two devices show different numbers: $SAS_ADMIN vs $SAS_NEW"
echo "both devices show $SAS_ADMIN"

step "M3.1 nothing is applied before the user compares: a wrong number is refused"
expect_fail "$DATA/laptop.wrong" "$CLI" device pair-confirm --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" "0000-0000" || fail "a wrong number was accepted"
grep -q "not talking to each other" "$DATA/laptop.wrong" || fail "unexpected refusal: $(cat "$DATA/laptop.wrong")"
"$CLI" status --data-dir "$DATA/alice-laptop" > "$DATA/laptop.status0"
grep -q "^identity: none" "$DATA/laptop.status0" || fail "the device joined an identity before the number was confirmed"

step "M3.1 with the right number the device joins, and the realm logged the enrolment"
"$CLI" device pair-confirm --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" "$SAS_NEW" | tee "$DATA/laptop.confirm"
grep -q "^linked: device" "$DATA/laptop.confirm" || fail "the device did not link"
"$CLI" status --data-dir "$DATA/alice-laptop" > "$DATA/laptop.status"
"$CLI" status --data-dir "$DATA/alice" > "$DATA/alice.status"
[ "$(sed -n 's/^identity: \([0-9a-f]*\).*/\1/p' "$DATA/laptop.status")" = "$(sed -n 's/^identity: \([0-9a-f]*\).*/\1/p' "$DATA/alice.status")" ] || fail "the paired device belongs to another identity"
grep -q "linked device, no root key" "$DATA/laptop.status" || fail "the paired device should hold no root key"
grep -q "device linked: identity" "$DATA/relay.err" || fail "the realm did not log the enrolment"

step "M3.1 the paired device is a full member: it talks in a group with a third party"
"$CLI" enroll --data-dir "$DATA/bob" "$BOOTSTRAP" "$(invite)" > "$DATA/bob.enroll"
"$CLI" chat start --data-dir "$DATA/bob" "$BOOTSTRAP" "$(route_of "$DATA/alice.enroll")" "$(route_of "$DATA/laptop.confirm")" > "$DATA/bob.start"
"$CLI" chat sync --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" | tee "$DATA/laptop.sync1"
grep -q "joined conversation" "$DATA/laptop.sync1" || fail "the paired device did not join the group"
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP" "hola desde bob" > /dev/null
"$CLI" chat sync --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" | tee "$DATA/laptop.sync2"
grep -q "message: hola desde bob" "$DATA/laptop.sync2" || fail "the paired device does not receive messages"

step "M3.1 a second device answering the same code is refused, and the rendezvous is opaque and expires"
"$CLI" device pair --data-dir "$DATA/eve-target" "$BOOTSTRAP" > "$DATA/eve.pair" 2>&1 &
PAIR2_PID=$!
wait_for "$DATA/eve.pair" "^code: "
CODE2="$(sed -n 's/^code: //p' "$DATA/eve.pair")"
"$CLI" device pair-approve --data-dir "$DATA/alice" "$BOOTSTRAP" "$CODE2" > "$DATA/alice.approve2"
expect_fail "$DATA/bob.approve2" "$CLI" device pair-approve --data-dir "$DATA/bob" "$BOOTSTRAP" "$CODE2" || fail "a second device took over a pairing already answered"
grep -q "Someone else already answered this code" "$DATA/bob.approve2" || fail "unexpected refusal: $(cat "$DATA/bob.approve2")"
wait "$PAIR2_PID" || fail "the second pairing did not finish"
if command -v sqlite3 >/dev/null; then
  sqlite3 "$DATA/relay/realm.db" 'SELECT slot, hex(data) FROM rendezvous_slots' > "$DATA/slots"
  [ -s "$DATA/slots" ] || fail "no rendezvous rows to inspect"
  for word in "arveil" "$SAS_NEW"; do
    grep -qa "$word" "$DATA/slots" && fail "'$word' is readable in a rendezvous slot"
  done
  echo "rendezvous slots hold ciphertext only"
else
  echo "sqlite3 not installed: rendezvous inventory skipped"
fi
stop_relay
start_relay -pair-ttl 2s
BOOTSTRAP2="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"
ARVEIL_PAIR_TIMEOUT_SECS=3 "$CLI" device pair --data-dir "$DATA/expired" "$BOOTSTRAP2" > "$DATA/expired.pair" 2>&1 &
EXP_PID=$!
wait_for "$DATA/expired.pair" "^code: "
EXPIRED_CODE="$(sed -n 's/^code: //p' "$DATA/expired.pair")"
# Nobody will answer this one; stop waiting for it.
kill "$EXP_PID" 2>/dev/null || true
wait "$EXP_PID" 2>/dev/null || true
sleep 4
expect_fail "$DATA/alice.expired" "$CLI" device pair-approve --data-dir "$DATA/alice" "$BOOTSTRAP2" "$EXPIRED_CODE" || fail "an expired rendezvous still worked"
grep -q "expired" "$DATA/alice.expired" || fail "unexpected error for an expired rendezvous: $(cat "$DATA/alice.expired")"
grep -q "pairing(s) removed" "$DATA/relay.err" || fail "the relay did not sweep the expired rendezvous"

step "M3.2 contact verification: both sides read the same number and pin each other"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP2" > "$DATA/alice.sync1" 2>&1 || true
"$CLI" contact list --data-dir "$DATA/alice" | tee "$DATA/alice.contacts"
"$CLI" contact list --data-dir "$DATA/bob" | tee "$DATA/bob.contacts"
ALICE_ID="$(sed -n 's/^identity: \([0-9a-f]*\).*/\1/p' "$DATA/alice.status")"
BOB_ID="$(sed -n 's/^identity: //p' "$DATA/bob.enroll" | sed 's/ .*//' | head -1)"
[ -n "$BOB_ID" ] || fail "could not read bob's identity"
NUM_A="$(grep -A1 "^contact $BOB_ID" "$DATA/alice.contacts" | sed -n 's/^  safety number: //p')"
NUM_B="$(grep -A1 "^contact $ALICE_ID" "$DATA/bob.contacts" | sed -n 's/^  safety number: //p')"
[ -n "$NUM_A" ] || fail "alice has no safety number for bob"
[ "$NUM_A" = "$NUM_B" ] || fail "the two sides show different numbers: '$NUM_A' vs '$NUM_B'"
echo "both sides read $NUM_A"
expect_fail "$DATA/alice.badverify" "$CLI" contact verify --data-dir "$DATA/alice" "$BOB_ID" "00000 00000 00000 00000 00000 00000 00000 00000" || fail "a wrong number verified a contact"
grep -q "does not match" "$DATA/alice.badverify" || fail "unexpected refusal: $(cat "$DATA/alice.badverify")"
"$CLI" contact verify --data-dir "$DATA/alice" "$BOB_ID" "$NUM_A" | tee "$DATA/alice.verify"
grep -q "^verified: $BOB_ID" "$DATA/alice.verify" || fail "verification did not take"
"$CLI" contact verify --data-dir "$DATA/bob" "$ALICE_ID" "$NUM_B" > "$DATA/bob.verify"
"$CLI" contact list --data-dir "$DATA/alice" > "$DATA/alice.contacts2"
grep -q "^contact $BOB_ID \[verified\]" "$DATA/alice.contacts2" || fail "the contact is not shown as verified"
[ "$(grep -c '^contact ' "$DATA/alice.contacts2")" = 1 ] || fail "own devices must not appear as contacts"
"$CLI" chat history --data-dir "$DATA/bob" | tee "$DATA/bob.history"
grep -q "(verified)" "$DATA/bob.history" || fail "history does not mark verified peers"

step "M3.2 the number belongs to the identities, not to the devices"
# Alice's laptop, paired in M3.1, is a second device of the same identity:
# bob reads the same number for her.
"$CLI" contact list --data-dir "$DATA/bob" > "$DATA/bob.contacts2"
[ "$(grep -c "^contact $ALICE_ID" "$DATA/bob.contacts2")" = 1 ] || fail "a second device of the same identity should not be a second contact"
NUM_B2="$(grep -A1 "^contact $ALICE_ID" "$DATA/bob.contacts2" | sed -n 's/^  safety number: //p')"
[ "$NUM_B2" = "$NUM_B" ] || fail "the number changed when a device was added"
# A different identity gives a different number.
"$CLI" enroll --data-dir "$DATA/carol" "$BOOTSTRAP2" "$(invite)" > "$DATA/carol.enroll"
"$CLI" chat add --data-dir "$DATA/bob" "$BOOTSTRAP2" "$(route_of "$DATA/carol.enroll")" > "$DATA/bob.addcarol"
CAROL_ID="$(sed -n 's/^identity: //p' "$DATA/carol.enroll" | sed 's/ .*//' | head -1)"
"$CLI" contact list --data-dir "$DATA/bob" > "$DATA/bob.contacts3"
NUM_C="$(grep -A1 "^contact $CAROL_ID" "$DATA/bob.contacts3" | sed -n 's/^  safety number: //p')"
[ -n "$NUM_C" ] || fail "carol is not a contact of bob"
[ "$NUM_C" != "$NUM_B" ] || fail "two identities produced the same number"

step "M3.3 resumable transfers: an interrupted upload continues where it stopped"
head -c 400000 /dev/urandom > "$DATA/foto.bin"
set +e
ARVEIL_CRASH_AFTER_CHUNKS=2 "$CLI" chat send-file --data-dir "$DATA/bob" "$BOOTSTRAP2" "$DATA/foto.bin" > "$DATA/bob.upload1" 2>&1
rc=$?
set -e
[ "$rc" = 4 ] || { cat "$DATA/bob.upload1"; fail "expected the simulated interruption to exit 4, got $rc"; }
grep -q "simulated interruption after 2 chunk" "$DATA/bob.upload1" || fail "the upload was not interrupted where expected"
"$CLI" chat send-file --data-dir "$DATA/bob" "$BOOTSTRAP2" "$DATA/foto.bin" | tee "$DATA/bob.upload2"
grep -q "upload: resuming foto.bin at 122880 of" "$DATA/bob.upload2" || fail "the upload did not resume at what the realm already held"
grep -q "^blob: .* uploaded" "$DATA/bob.upload2" || fail "the resumed upload did not finish"

step "M3.3 an interrupted download continues, and the file matches"
set +e
ARVEIL_CRASH_AFTER_DOWNLOAD_CHUNKS=2 "$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP2" > "$DATA/alice.dl1" 2>&1
rc=$?
set -e
[ "$rc" = 4 ] || { cat "$DATA/alice.dl1"; fail "expected the download interruption to exit 4, got $rc"; }
[ -f "$DATA/alice/downloads/foto.bin.part" ] || fail "no partial file was kept"
[ ! -f "$DATA/alice/downloads/foto.bin" ] || fail "an unverified file was written"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP2" | tee "$DATA/alice.dl2"
grep -q "file: resuming foto.bin at 122880 bytes" "$DATA/alice.dl2" || fail "the download did not resume"
grep -q "file: foto.bin saved to" "$DATA/alice.dl2" || fail "the resumed download did not finish"
cmp "$DATA/foto.bin" "$DATA/alice/downloads/foto.bin" || fail "the resumed file does not match the original"
[ ! -f "$DATA/alice/downloads/foto.bin.part" ] || fail "the partial file was left behind"

step "M3.3 a changed file starts a new upload instead of mixing bytes"
ARVEIL_CRASH_AFTER_CHUNKS=1 "$CLI" chat send-file --data-dir "$DATA/bob" "$BOOTSTRAP2" "$DATA/foto.bin" > "$DATA/bob.upload3" 2>&1 || true
head -c 400000 /dev/urandom > "$DATA/foto.bin"
"$CLI" chat send-file --data-dir "$DATA/bob" "$BOOTSTRAP2" "$DATA/foto.bin" | tee "$DATA/bob.upload4"
grep -q "changed since the interrupted attempt; starting again" "$DATA/bob.upload4" || fail "a changed file was resumed as if it were the same"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP2" > "$DATA/alice.dl3"
cmp "$DATA/foto.bin" "$DATA/alice/downloads/foto.bin" || fail "the second file does not match"

step "M3.4 push hint: the realm pokes an endpoint that learns only that mail exists"
SINK_PORT=$((PORT + 10))
"$ROOT/relay/bin/arveil-hintsink" -listen "127.0.0.1:$SINK_PORT" -out "$DATA/hints.log" > "$DATA/sink.out" 2>&1 &
SINK_PID=$!
for _ in $(seq 1 50); do grep -q "listening" "$DATA/sink.out" && break; sleep 0.1; done
grep -q "listening" "$DATA/sink.out" || fail "the hint sink did not start"
"$CLI" notify set --data-dir "$DATA/alice" "$BOOTSTRAP2" "http://127.0.0.1:$SINK_PORT/alice-token" | tee "$DATA/alice.notify"
grep -q "^notify: the realm will poke" "$DATA/alice.notify" || fail "the hint was not accepted"
expect_fail "$DATA/alice.badnotify" "$CLI" notify set --data-dir "$DATA/alice" "$BOOTSTRAP2" "ftp://nope/x" || fail "a non-http endpoint was accepted"

# Alice's mailbox is empty right now: the first envelope fires one hint.
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP2" "primero" > /dev/null
sleep 1
[ "$(wc -l < "$DATA/hints.log")" -ge 1 ] || fail "no hint was sent for the first envelope"
FIRST="$(wc -l < "$DATA/hints.log")"
# A second envelope into a mailbox that is no longer empty fires nothing.
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP2" "segundo" > /dev/null
sleep 1
[ "$(wc -l < "$DATA/hints.log")" = "$FIRST" ] || fail "a hint was sent for a mailbox that was already holding mail"
# After alice reads and acknowledges, the next envelope fires again.
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP2" > "$DATA/alice.sync3"
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP2" "tercero" > /dev/null
sleep 1
[ "$(wc -l < "$DATA/hints.log")" -gt "$FIRST" ] || fail "no hint after the mailbox was emptied"
cat "$DATA/hints.log"
grep -q 'body="arveil-hint/v1"' "$DATA/hints.log" || fail "the hint body is not the fixed marker"
grep -q 'query=""' "$DATA/hints.log" || fail "the realm added something to the URL"
for word in "primero" "segundo" "tercero" "$BOB_ID" "$ALICE_ID"; do
  grep -qa "$word" "$DATA/hints.log" && fail "'$word' reached the notification endpoint"
done
echo "the endpoint learned only that mail exists"

step "M3.4 with no endpoint configured nothing is sent and nothing is stored"
LINES="$(wc -l < "$DATA/hints.log")"
"$CLI" notify clear --data-dir "$DATA/alice" "$BOOTSTRAP2" | tee "$DATA/alice.notifyclear"
grep -q "hint removed" "$DATA/alice.notifyclear" || fail "the hint was not removed"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP2" > /dev/null
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP2" "cuarto" > /dev/null
sleep 1
[ "$(wc -l < "$DATA/hints.log")" = "$LINES" ] || fail "a hint was sent after the endpoint was removed"
if command -v sqlite3 >/dev/null; then
  [ "$(sqlite3 "$DATA/relay/realm.db" 'SELECT COUNT(*) FROM notify_hints')" = 0 ] || fail "the realm still stores an endpoint"
fi

step "phase 3 checks so far ok"
