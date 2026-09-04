#!/usr/bin/env bash
# Phase 2 acceptance (docs/PHASE2.md). Each section maps to a milestone.
# Exit 0 only if every check passes. ARVEIL_P2_KEEP=1 keeps the data dir.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
PORT="${ARVEIL_P2_PORT:-18470}"
RELAY="$ROOT/relay/bin/arveil-relay"
CLI="$ROOT/core/target/debug/arveil"
RELAY_PID=""

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
cleanup() {
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  [ -n "${ARVEIL_P2_KEEP:-}" ] && echo "data kept in $DATA" || rm -rf "$DATA"
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
# Run a command expected to fail; its output goes to $2 for inspection.
expect_fail() { local out="$1"; shift; if "$@" > "$out" 2>&1; then return 1; fi; return 0; }

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay)
(cd "$ROOT/core" && cargo build -q -p arveil-cli)

start_relay
BOOTSTRAP="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"
"$CLI" enroll --data-dir "$DATA/alice-phone" "$BOOTSTRAP" "$(invite)" > "$DATA/alice-phone.enroll"
"$CLI" enroll --data-dir "$DATA/bob" "$BOOTSTRAP" "$(invite)" > "$DATA/bob.enroll"

step "M2.1 device linking: alice's laptop joins without an invite; the root never leaves the phone"
"$CLI" device request --data-dir "$DATA/alice-laptop" | tee "$DATA/laptop.request"
REQ="$(sed -n 's/^request: //p' "$DATA/laptop.request")"
[ -n "$REQ" ] || fail "no link request printed"
"$CLI" device authorize --data-dir "$DATA/alice-phone" "$BOOTSTRAP" "$REQ" | tee "$DATA/phone.authorize"
grep -q "published: manifest 2" "$DATA/phone.authorize" || fail "manifest 2 not published"
grep -q "published: credential registered" "$DATA/phone.authorize" || fail "credential not registered"
GRANT="$(sed -n 's/^grant: //p' "$DATA/phone.authorize")"
"$CLI" device link --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" "$GRANT" | tee "$DATA/laptop.link"
grep -q "^linked: device" "$DATA/laptop.link" || fail "laptop did not link"
grep -q "^route: " "$DATA/laptop.link" || fail "laptop has no route"
"$CLI" status --data-dir "$DATA/alice-laptop" | tee "$DATA/laptop.status"
grep -q "linked device, no root key" "$DATA/laptop.status" || fail "laptop should hold no root key"
"$CLI" status --data-dir "$DATA/alice-phone" | tee "$DATA/phone.status"
[ "$(sed -n 's/^identity: \([0-9a-f]*\).*/\1/p' "$DATA/phone.status")" = "$(sed -n 's/^identity: \([0-9a-f]*\).*/\1/p' "$DATA/laptop.status")" ] || fail "identity differs between alice's devices"
grep -q "device linked: identity" "$DATA/relay.err" || fail "relay did not log the linked device"
grep -q "manifest 2 for identity" "$DATA/relay.err" || fail "relay did not log manifest 2"

step "M2.1 negative: a grant for other keys is refused; a used grant cannot link a second device"
"$CLI" device request --data-dir "$DATA/mallory" > "$DATA/mallory.request"
expect_fail "$DATA/mallory.link" "$CLI" device link --data-dir "$DATA/mallory" "$BOOTSTRAP" "$GRANT" || fail "grant for alice's laptop keys linked mallory's device"
grep -q "does not name this device's keys" "$DATA/mallory.link" || fail "unexpected refusal reason: $(cat "$DATA/mallory.link")"
expect_fail "$DATA/laptop.relink" "$CLI" device link --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" "$GRANT" || fail "laptop linked twice"
grep -q "already linked" "$DATA/laptop.relink" || fail "unexpected relink reason: $(cat "$DATA/laptop.relink")"
"$CLI" probe --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" > "$DATA/laptop.probe"
grep -q "established as enrolled device" "$DATA/laptop.probe" || fail "laptop cannot open a member session"

step "M2.2 multi-device: alice's phone adds her laptop to the group with bob; every device reads every message"
ROUTE_B="$(route_of "$DATA/bob.enroll")"
ROUTE_LAPTOP="$(route_of "$DATA/laptop.link")"
"$CLI" chat start --data-dir "$DATA/alice-phone" "$BOOTSTRAP" "$ROUTE_B" > "$DATA/phone.start"
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" > "$DATA/bob.sync0"
grep -q "joined conversation" "$DATA/bob.sync0" || fail "bob did not join"
"$CLI" chat add --data-dir "$DATA/alice-phone" "$BOOTSTRAP" "$ROUTE_LAPTOP" | tee "$DATA/phone.add"
grep -q "^added: device" "$DATA/phone.add" || fail "laptop not added"
"$CLI" chat sync --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" | tee "$DATA/laptop.sync1"
grep -q "joined conversation" "$DATA/laptop.sync1" || fail "laptop did not join"
grep -q "roster: 2 peer route(s)" "$DATA/laptop.sync1" || fail "laptop did not learn the phone and bob"
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" | tee "$DATA/bob.sync1"
grep -q "roster: 2 peer route(s)" "$DATA/bob.sync1" || fail "bob did not learn both alice devices"
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP" "hola alice, en los dos" | tee "$DATA/bob.send1"
grep -q "2 envelope(s) queued" "$DATA/bob.send1" || fail "bob did not fan out to both alice devices"
"$CLI" chat sync --data-dir "$DATA/alice-phone" "$BOOTSTRAP" | tee "$DATA/phone.sync1"
grep -q "message: hola alice, en los dos" "$DATA/phone.sync1" || fail "phone did not receive bob's message"
"$CLI" chat sync --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" | tee "$DATA/laptop.sync2"
grep -q "message: hola alice, en los dos" "$DATA/laptop.sync2" || fail "laptop did not receive bob's message"
"$CLI" chat send --data-dir "$DATA/alice-laptop" "$BOOTSTRAP" "desde el portátil de alice" | tee "$DATA/laptop.send1"
grep -q "2 envelope(s) queued" "$DATA/laptop.send1" || fail "laptop did not fan out to the phone and bob"
"$CLI" chat sync --data-dir "$DATA/alice-phone" "$BOOTSTRAP" | tee "$DATA/phone.sync2"
grep -q "message: desde el portátil" "$DATA/phone.sync2" || fail "phone did not receive the laptop's message"
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" | tee "$DATA/bob.sync2"
grep -q "message: desde el portátil" "$DATA/bob.sync2" || fail "bob did not receive the laptop's message"
"$CLI" chat history --data-dir "$DATA/alice-phone" > "$DATA/phone.hist"
"$CLI" chat history --data-dir "$DATA/alice-laptop" > "$DATA/laptop.hist"
for text in "hola alice, en los dos" "desde el portátil"; do
  grep -q "$text" "$DATA/phone.hist" || fail "phone history lacks '$text'"
  grep -q "$text" "$DATA/laptop.hist" || fail "laptop history lacks '$text'"
done
grep -q "(own)" "$DATA/phone.hist" || fail "phone history does not mark the laptop as an own device"

step "phase 2 checks so far ok"
