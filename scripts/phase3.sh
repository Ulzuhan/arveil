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

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay)
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

step "phase 3 checks so far ok"
