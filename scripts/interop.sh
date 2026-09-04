#!/usr/bin/env bash
# Cross-language check for milestones M0.2 and M0.3: the Go relay serves the
# Noise channel over WebSocket; the Rust CLI enrolls a device with an invite,
# reconnects as a member, and the negative cases are refused.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
PORT="${ARVEIL_INTEROP_PORT:-18447}"
RELAY="$ROOT/relay/bin/arveil-relay"
CLI="$ROOT/core/target/debug/arveil"

cleanup() {
  if [ -n "${RELAY_PID:-}" ]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  rm -rf "$DATA"
}
trap cleanup EXIT

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay)
(cd "$ROOT/core" && cargo build -q -p arveil-cli)

"$RELAY" -data-dir "$DATA/relay" -listen "127.0.0.1:$PORT" > "$DATA/relay.out" 2> "$DATA/relay.err" &
RELAY_PID=$!

BOOTSTRAP=""
for _ in $(seq 1 50); do
  BOOTSTRAP="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"
  [ -n "$BOOTSTRAP" ] && break
  sleep 0.1
done
if [ -z "$BOOTSTRAP" ]; then
  echo "relay did not print a bootstrap line"; cat "$DATA/relay.err"; exit 1
fi
echo "relay: $BOOTSTRAP"

echo "--- M0.2: provisional probe"
"$CLI" probe "$BOOTSTRAP"

echo "--- M0.2: tampered realm id refused"
TAMPERED="$(echo "$BOOTSTRAP" | awk -F: 'BEGIN{OFS=":"} {$3=substr($3,1,62)"ff"; print}')"
if "$CLI" probe "$TAMPERED" >/dev/null 2>&1; then
  echo "probe with tampered realm id unexpectedly succeeded"; exit 1
fi
echo "refused as expected"

echo "--- M0.3: invite, identity, enrollment"
INVITE="$("$RELAY" invite -data-dir "$DATA/relay" -uses 1 | sed -n 's/^invite: //p')"
[ -n "$INVITE" ] || { echo "no invite token"; exit 1; }
"$CLI" identity new --data-dir "$DATA/alice"
"$CLI" enroll --data-dir "$DATA/alice" "$BOOTSTRAP" "$INVITE"
"$CLI" status --data-dir "$DATA/alice"

echo "--- M0.3: member probe with the enrolled device key"
"$CLI" probe --data-dir "$DATA/alice" "$BOOTSTRAP"

echo "--- M0.3: consumed invite refused for a second identity"
if "$CLI" enroll --data-dir "$DATA/bob" "$BOOTSTRAP" "$INVITE" > "$DATA/bob.out" 2>&1; then
  echo "second enrollment with a consumed invite unexpectedly succeeded"; cat "$DATA/bob.out"; exit 1
fi
grep -q "(410)" "$DATA/bob.out" || { echo "expected a 410 refusal, got:"; cat "$DATA/bob.out"; exit 1; }
echo "refused with 410 as expected"

echo "--- M0.3: forged invite token refused"
if "$CLI" enroll --data-dir "$DATA/carol" "$BOOTSTRAP" "$(printf '00%.0s' $(seq 1 32))" > "$DATA/carol.out" 2>&1; then
  echo "enrollment with a forged token unexpectedly succeeded"; exit 1
fi
grep -q "(410)" "$DATA/carol.out" || { echo "expected a 410 refusal, got:"; cat "$DATA/carol.out"; exit 1; }
echo "refused with 410 as expected"

echo "--- M0.4: mailbox, envelope put/fetch/ack between two enrolled devices"
INVITE2="$("$RELAY" invite -data-dir "$DATA/relay" -uses 1 | sed -n 's/^invite: //p')"
"$CLI" enroll --data-dir "$DATA/dave" "$BOOTSTRAP" "$INVITE2" > /dev/null
ROUTE="$("$CLI" mailbox create --data-dir "$DATA/alice" "$BOOTSTRAP" | sed -n 's/^route: //p')"
[ -n "$ROUTE" ] || { echo "no route"; exit 1; }
"$CLI" send --data-dir "$DATA/dave" "$BOOTSTRAP" "$ROUTE" "hola alice, soy dave"
"$CLI" fetch --data-dir "$DATA/alice" "$BOOTSTRAP" | tee "$DATA/fetch1.out"
grep -q "message: hola alice, soy dave" "$DATA/fetch1.out" || { echo "message not received"; exit 1; }
"$CLI" fetch --data-dir "$DATA/alice" "$BOOTSTRAP" | tee "$DATA/fetch2.out"
grep -q "fetched: 0 envelope(s)" "$DATA/fetch2.out" || { echo "acked envelope was delivered again"; exit 1; }
echo "--- M0.4: a provisional (unenrolled) session cannot put envelopes"
"$CLI" identity new --data-dir "$DATA/eve" > /dev/null
if "$CLI" send --data-dir "$DATA/eve" "$BOOTSTRAP" "$ROUTE" "spam" > "$DATA/eve.out" 2>&1; then
  echo "unenrolled sender unexpectedly succeeded"; cat "$DATA/eve.out"; exit 1
fi
echo "refused as expected"

echo "--- relay database inventory (I-01 spot check)"
if command -v sqlite3 >/dev/null; then
  sqlite3 "$DATA/relay/realm.db" '.tables'
  sqlite3 "$DATA/relay/realm.db" 'SELECT COUNT(*) AS memberships FROM realm_memberships; SELECT COUNT(*) AS credentials FROM device_credentials; SELECT COUNT(*) AS manifests FROM device_manifests; SELECT COUNT(*) AS mailboxes FROM mailboxes; SELECT COUNT(*) AS envelopes_left FROM envelopes;'
  if sqlite3 "$DATA/relay/realm.db" 'SELECT hex(ciphertext) FROM envelopes' | grep -qi "$(printf 'hola alice' | xxd -p)"; then echo "PLAINTEXT FOUND IN RELAY"; exit 1; fi
fi
echo "interop ok"
