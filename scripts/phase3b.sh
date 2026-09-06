#!/usr/bin/env bash
# Phase 3b acceptance (docs/PHASE3B.md). Client-facing behaviour the
# graphical client depends on and the other phases do not cover.
# Exit 0 only if every check passes. ARVEIL_P3B_KEEP=1 keeps the data dir.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
PORT="${ARVEIL_P3B_PORT:-18490}"
RELAY="$ROOT/relay/bin/arveil-relay"
CLI="$ROOT/core/target/debug/arveil"
RELAY_PID=""

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
cleanup() {
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  [ -n "${ARVEIL_P3B_KEEP:-}" ] && echo "data kept in $DATA" || rm -rf "$DATA"
}
trap cleanup EXIT

start_relay() {
  "$RELAY" -data-dir "$DATA/relay" -listen "127.0.0.1:$PORT" -sweep-interval 1s "$@" > "$DATA/relay.out" 2>> "$DATA/relay.err" &
  RELAY_PID=$!
  for _ in $(seq 1 50); do grep -q '^bootstrap: ' "$DATA/relay.out" && return; sleep 0.1; done
  fail "relay did not start"
}
invite() { "$RELAY" invite -data-dir "$DATA/relay" | sed -n 's/^invite: //p'; }
route_of() { sed -n 's/^route: //p' "$1"; }

command -v sqlite3 > /dev/null || { echo "sqlite3 not available: skipping"; exit 0; }

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay)
(cd "$ROOT/core" && cargo build -q -p arveil-cli)

start_relay
BOOTSTRAP="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"

step "M3b.2 a mailbox creation that is repeated returns the same mailbox and the same route"
"$CLI" enroll --data-dir "$DATA/alice" "$BOOTSTRAP" "$(invite)" > "$DATA/alice.enroll"
ROUTE_BEFORE="$(route_of "$DATA/alice.enroll")"
[ -n "$ROUTE_BEFORE" ] || fail "enrollment produced no route"
MAILBOXES_BEFORE="$(sqlite3 "$DATA/relay/realm.db" 'SELECT count(*) FROM mailboxes;')"
[ "$MAILBOXES_BEFORE" = "1" ] || fail "expected one mailbox on the realm, found $MAILBOXES_BEFORE"

# The answer was lost: the relay made the mailbox, the client never recorded
# it. What it did record, before asking, is the request itself.
sqlite3 "$DATA/alice/client.db" 'DELETE FROM mailbox_own;'
"$CLI" mailbox create --data-dir "$DATA/alice" "$BOOTSTRAP" > "$DATA/alice.again"
ROUTE_AFTER="$(route_of "$DATA/alice.again")"
[ "$ROUTE_AFTER" = "$ROUTE_BEFORE" ] || fail "the route changed: $ROUTE_BEFORE -> $ROUTE_AFTER"
MAILBOXES_AFTER="$(sqlite3 "$DATA/relay/realm.db" 'SELECT count(*) FROM mailboxes;')"
[ "$MAILBOXES_AFTER" = "1" ] || fail "a second mailbox was created ($MAILBOXES_AFTER total)"
CAPS="$(sqlite3 "$DATA/relay/realm.db" 'SELECT count(*) FROM capabilities;')"
[ "$CAPS" = "2" ] || fail "expected two capabilities, found $CAPS"
echo "same mailbox, same route, no second capability pair"

step "M3b.2 the realm still refuses a request key that belongs to another device"
"$CLI" enroll --data-dir "$DATA/bob" "$BOOTSTRAP" "$(invite)" > "$DATA/bob.enroll"
REQUEST="$(sqlite3 "$DATA/alice/client.db" 'SELECT hex(request_key) FROM mailbox_request;')"
sqlite3 "$DATA/bob/client.db" "UPDATE mailbox_request SET request_key = x'$REQUEST';"
sqlite3 "$DATA/bob/client.db" 'DELETE FROM mailbox_own;'
if "$CLI" mailbox create --data-dir "$DATA/bob" "$BOOTSTRAP" > "$DATA/bob.steal" 2>&1; then
  fail "another device reused a request key: $(cat "$DATA/bob.steal")"
fi
grep -qi "conflict\|reused" "$DATA/bob.steal" || fail "unexpected refusal: $(cat "$DATA/bob.steal")"
echo "refused, and the message says why"

printf '\n\033[1m== phase 3b ok\033[0m\n'
