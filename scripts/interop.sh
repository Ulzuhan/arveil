#!/usr/bin/env bash
# Cross-language check for milestone M0.2: the Go relay serves the Noise
# channel over WebSocket; the Rust CLI connects, verifies the signed endpoint
# list and exchanges a ping. Exit 0 only if every step succeeds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
PORT="${ARVEIL_INTEROP_PORT:-18447}"
cleanup() {
  if [ -n "${RELAY_PID:-}" ]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  rm -rf "$DATA"
}
trap cleanup EXIT

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay)
(cd "$ROOT/core" && cargo build -q -p arveil-cli)

"$ROOT/relay/bin/arveil-relay" -data-dir "$DATA" -listen "127.0.0.1:$PORT" > "$DATA/relay.out" 2> "$DATA/relay.err" &
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

"$ROOT/core/target/debug/arveil" probe "$BOOTSTRAP"

# Negative check: a tampered realm id must fail before any frame.
TAMPERED="$(echo "$BOOTSTRAP" | awk -F: 'BEGIN{OFS=":"} {$3=substr($3,1,62)"ff"; print}')"
if "$ROOT/core/target/debug/arveil" probe "$TAMPERED" >/dev/null 2>&1; then
  echo "probe with tampered realm id unexpectedly succeeded"; exit 1
fi
echo "tampered realm id: refused as expected"
echo "interop ok"
