#!/usr/bin/env bash
# Phase 0 demo (milestone M0.6): two CLI clients chat through the Go relay
# with real MLS, the relay restarts mid-conversation, a client crashes after
# committing a message and before publishing it, and the relay database is
# inventoried for plaintext, group ids and conversation tables.
#
# Exit 0 only if every check passes. Set ARVEIL_DEMO_KEEP=1 to keep the data
# directory for inspection.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${ARVEIL_DEMO_DATA:-$(mktemp -d)}"
PORT="${ARVEIL_DEMO_PORT:-18448}"
RELAY="$ROOT/relay/bin/arveil-relay"
CLI="$ROOT/core/target/debug/arveil"
RELAY_PID=""

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

cleanup() {
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  [ -n "${ARVEIL_DEMO_KEEP:-}" ] && echo "data kept in $DATA" || rm -rf "$DATA"
}
trap cleanup EXIT

start_relay() {
  "$RELAY" -data-dir "$DATA/relay" -listen "127.0.0.1:$PORT" > "$DATA/relay.out" 2>> "$DATA/relay.err" &
  RELAY_PID=$!
  for _ in $(seq 1 50); do
    if grep -q '^bootstrap: ' "$DATA/relay.out"; then return; fi
    sleep 0.1
  done
  fail "relay did not start";
}

stop_relay() {
  kill "$RELAY_PID"; wait "$RELAY_PID" 2>/dev/null || true; RELAY_PID=""
}

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay)
(cd "$ROOT/core" && cargo build -q -p arveil-cli)

step "relay starts; prints the bootstrap string (realm id, signing key, noise key, endpoint)"
start_relay
BOOTSTRAP="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"
echo "$BOOTSTRAP"

step "operator creates two one-use invites"
INV_A="$("$RELAY" invite -data-dir "$DATA/relay" | sed -n 's/^invite: //p')"
INV_B="$("$RELAY" invite -data-dir "$DATA/relay" | sed -n 's/^invite: //p')"

step "alice enrolls: root key, device credential, first manifest, mailbox, 5 KeyPackages"
"$CLI" enroll --data-dir "$DATA/alice" "$BOOTSTRAP" "$INV_A" | tee "$DATA/alice.enroll"
ROUTE_A="$(sed -n 's/^route: //p' "$DATA/alice.enroll")"

step "bob enrolls"
"$CLI" enroll --data-dir "$DATA/bob" "$BOOTSTRAP" "$INV_B" | tee "$DATA/bob.enroll"
ROUTE_B="$(sed -n 's/^route: //p' "$DATA/bob.enroll")"

step "alice starts a conversation with bob (claims his KeyPackage, MLS group with policy, Welcome + route sealed to his mailbox)"
"$CLI" chat start --data-dir "$DATA/alice" "$BOOTSTRAP" "$ROUTE_B"

step "bob syncs: joins from the Welcome, learns alice's route inside the group"
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" | tee "$DATA/bob.sync1"
grep -q "joined conversation" "$DATA/bob.sync1" || fail "bob did not join"
grep -q "peer route learned" "$DATA/bob.sync1" || fail "bob did not learn the route"

step "bob -> alice, alice -> bob"
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP" "hola alice, soy bob"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" | tee "$DATA/alice.sync1"
grep -q "message: hola alice, soy bob" "$DATA/alice.sync1" || fail "alice did not receive bob's message"
"$CLI" chat send --data-dir "$DATA/alice" "$BOOTSTRAP" "hola bob, soy alice"

step "relay restarts mid-conversation (same data directory)"
stop_relay
start_relay
BOOTSTRAP2="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | tail -1)"
[ "${BOOTSTRAP2%%:ws*}" = "${BOOTSTRAP%%:ws*}" ] || fail "realm identity changed across restart"
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" | tee "$DATA/bob.sync2"
grep -q "message: hola bob, soy alice" "$DATA/bob.sync2" || fail "bob did not receive after the restart"

step "bob crashes after committing a message and before publishing (I-04)"
set +e
ARVEIL_CRASH_AFTER_COMMIT=1 "$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP" "este mensaje sobrevive a la caída"
rc=$?
set -e
[ "$rc" = 3 ] || fail "expected simulated crash exit code 3, got $rc"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" | tee "$DATA/alice.sync2"
grep -q "synced: 0 envelope" "$DATA/alice.sync2" || fail "nothing should have been published before the crash"

step "bob comes back: the stored envelope is retransmitted, alice receives it exactly once"
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" | tee "$DATA/bob.sync3"
grep -q "published: 1 pending" "$DATA/bob.sync3" || fail "pending envelope not retransmitted"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" | tee "$DATA/alice.sync3"
grep -q "message: este mensaje sobrevive" "$DATA/alice.sync3" || fail "alice did not receive the retransmitted message"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" | tee "$DATA/alice.sync4"
grep -q "synced: 0 envelope" "$DATA/alice.sync4" || fail "duplicate delivery after ACK"

step "histories"
"$CLI" chat history --data-dir "$DATA/alice" | tee "$DATA/alice.history"
"$CLI" chat history --data-dir "$DATA/bob" | tee "$DATA/bob.history"
[ "$(grep -c 'sobrevive' "$DATA/alice.history")" = 1 ] || fail "alice has the crash-test message more or less than once"
GROUP_ID="$(sed -n 's/^conversation \([0-9a-f]*\) with.*/\1/p' "$DATA/alice.history" | head -1)"

step "relay database inventory (I-01): tables, no plaintext, no MLS group id"
stop_relay
if command -v sqlite3 >/dev/null; then
  sqlite3 "$DATA/relay/realm.db" '.tables' | tee "$DATA/tables"
  for forbidden in conversation room message group; do
    if grep -qi "$forbidden" "$DATA/tables"; then fail "relay has a table named like '$forbidden'"; fi
  done
  DUMP="$(sqlite3 "$DATA/relay/realm.db" '.dump' | tr -d '\n')"
  for word in "hola alice" "soy bob" "sobrevive" ; do
    echo "$DUMP" | grep -qi "$(printf '%s' "$word" | xxd -p)" && fail "plaintext '$word' found in the relay database"
    echo "$DUMP" | grep -qi "$word" && fail "plaintext '$word' found in the relay database"
  done
  echo "$DUMP" | grep -qi "$GROUP_ID" && fail "MLS group id found in the relay database"
  echo "no plaintext, no group id ($GROUP_ID), no conversation table"
  sqlite3 "$DATA/relay/realm.db" 'SELECT "memberships", COUNT(*) FROM realm_memberships; SELECT "mailboxes", COUNT(*) FROM mailboxes; SELECT "envelopes left", COUNT(*) FROM envelopes; SELECT "key packages consumed", COUNT(*) FROM key_packages WHERE consumed = 1;'
else
  echo "sqlite3 not installed: inventory skipped"
fi

step "demo ok"
