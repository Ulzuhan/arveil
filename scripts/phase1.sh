#!/usr/bin/env bash
# Phase 1 acceptance (docs/PHASE1.md). Each section maps to a milestone.
# Exit 0 only if every check passes. ARVEIL_P1_KEEP=1 keeps the data dir.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
PORT="${ARVEIL_P1_PORT:-18460}"
DEAD_PORT="${ARVEIL_P1_DEAD_PORT:-18461}"
RELAY="$ROOT/relay/bin/arveil-relay"
CLI="$ROOT/core/target/debug/arveil"
RELAY_PID=""

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
cleanup() {
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  [ -n "${ARVEIL_P1_KEEP:-}" ] && echo "data kept in $DATA" || rm -rf "$DATA"
}
trap cleanup EXIT

start_relay() {
  "$RELAY" -data-dir "$DATA/relay" -listen "127.0.0.1:$PORT" "$@" > "$DATA/relay.out" 2>> "$DATA/relay.err" &
  RELAY_PID=$!
  for _ in $(seq 1 50); do grep -q '^bootstrap: ' "$DATA/relay.out" && return; sleep 0.1; done
  fail "relay did not start"
}
stop_relay() { kill "$RELAY_PID"; wait "$RELAY_PID" 2>/dev/null || true; RELAY_PID=""; }
invite() { "$RELAY" invite -data-dir "$DATA/relay" | sed -n 's/^invite: //p'; }
route_of() { sed -n 's/^route: //p' "$1"; }

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay)
(cd "$ROOT/core" && cargo build -q -p arveil-cli)

start_relay
BOOTSTRAP="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"
"$CLI" enroll --data-dir "$DATA/alice" "$BOOTSTRAP" "$(invite)" > "$DATA/alice.enroll"
"$CLI" enroll --data-dir "$DATA/bob" "$BOOTSTRAP" "$(invite)" > "$DATA/bob.enroll"
ROUTE_B="$(route_of "$DATA/bob.enroll")"
"$CLI" chat start --data-dir "$DATA/alice" "$BOOTSTRAP" "$ROUTE_B" > /dev/null
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" > /dev/null

step "M1.1 offline outbox: relay down, two sends queued, relay up, one sync publishes both"
stop_relay
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP" "primero sin red" | tee "$DATA/off1"
grep -q "queued: relay unreachable" "$DATA/off1" || fail "send did not report the queued state"
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP" "segundo sin red" > /dev/null
"$CLI" chat history --data-dir "$DATA/bob" | tee "$DATA/bob.hist1"
[ "$(grep -c ': queued' "$DATA/bob.hist1")" = 2 ] || fail "expected two queued deliveries"
start_relay
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" | tee "$DATA/bob.sync"
grep -q "published: 2 pending" "$DATA/bob.sync" || fail "pending envelopes not published"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" | tee "$DATA/alice.sync"
[ "$(grep -c '^message: ' "$DATA/alice.sync")" = 2 ] || fail "alice did not receive both"
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" | grep -q "synced: 0 envelope" || fail "duplicate after ack"
"$CLI" chat history --data-dir "$DATA/bob" | tee "$DATA/bob.hist2"
[ "$(grep -c 'accepted (relay keeps it until' "$DATA/bob.hist2")" = 2 ] || fail "states did not move to accepted"
grep -q "delivered" "$DATA/bob.hist2" && fail "a relay ACK must never be shown as delivered"

step "phase 1 checks so far ok"
