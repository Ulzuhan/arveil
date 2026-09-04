#!/usr/bin/env bash
# ADR-008 acceptance, Q3 of docs/PHASE0.md: run the Phase 0 enrollment and
# chat through a TLS-terminating proxy that records every WebSocket frame it
# sees (unmasked, after TLS), then assert the capture contains only opaque
# Noise messages: no frame names, no identifiers, no capabilities, no text.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
RELAY_PORT="${ARVEIL_Q3_RELAY_PORT:-18451}"
PROXY_PORT="${ARVEIL_Q3_PROXY_PORT:-18452}"
RELAY="$ROOT/relay/bin/arveil-relay"
PROXY="$ROOT/relay/bin/arveil-tlsproxy"
CLI="$ROOT/core/target/debug/arveil"
CAPTURE="${ARVEIL_Q3_CAPTURE:-$DATA/capture.log}"
PIDS=()

cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null && wait "$p" 2>/dev/null || true; done
  [ -n "${ARVEIL_Q3_KEEP:-}" ] && echo "data kept in $DATA" || rm -rf "$DATA"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay && go build -o bin/arveil-tlsproxy ./cmd/arveil-tlsproxy)
(cd "$ROOT/core" && cargo build -q -p arveil-cli)

# The relay advertises the proxy's wss:// URL as its public endpoint; the
# proxy forwards to the relay in plaintext, exactly like a tunnel.
"$RELAY" -data-dir "$DATA/relay" -listen "127.0.0.1:$RELAY_PORT" \
  -advertise "public=wss://127.0.0.1:$PROXY_PORT/v1/channel" > "$DATA/relay.out" 2> "$DATA/relay.err" &
PIDS+=($!)
"$PROXY" -listen "127.0.0.1:$PROXY_PORT" -upstream "127.0.0.1:$RELAY_PORT" \
  -capture "$CAPTURE" -ca-out "$DATA/proxy-ca.pem" > "$DATA/proxy.out" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do grep -q '^bootstrap: ' "$DATA/relay.out" && [ -s "$DATA/proxy-ca.pem" ] && break; sleep 0.1; done
BOOTSTRAP="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"
case "$BOOTSTRAP" in *wss://127.0.0.1:$PROXY_PORT*) ;; *) fail "bootstrap does not point at the proxy: $BOOTSTRAP";; esac
export ARVEIL_TLS_CA="$DATA/proxy-ca.pem"
echo "relay behind TLS proxy: $BOOTSTRAP"

INV_A="$("$RELAY" invite -data-dir "$DATA/relay" | sed -n 's/^invite: //p')"
INV_B="$("$RELAY" invite -data-dir "$DATA/relay" | sed -n 's/^invite: //p')"
"$CLI" enroll --data-dir "$DATA/alice" "$BOOTSTRAP" "$INV_A" > "$DATA/alice.enroll"
"$CLI" enroll --data-dir "$DATA/bob" "$BOOTSTRAP" "$INV_B" > "$DATA/bob.enroll"
ROUTE_B="$(sed -n 's/^route: //p' "$DATA/bob.enroll")"
"$CLI" chat start --data-dir "$DATA/alice" "$BOOTSTRAP" "$ROUTE_B" > /dev/null
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" > /dev/null
"$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP" "secreto de familia" > /dev/null
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" > "$DATA/alice.sync"
grep -q "message: secreto de familia" "$DATA/alice.sync" || fail "chat through the proxy failed"

echo "--- capture: $(wc -l < "$CAPTURE") frames recorded by the TLS-terminating proxy"
HTTPHEX="$(printf 'HTTP GET /v1/channel' | xxd -p | tr -d '\n')"
CONNS=$(grep -c "$HTTPHEX" "$CAPTURE" || true)
BIN=$(grep -c "opcode=2" "$CAPTURE" || true)
TEXT=$(grep -c "opcode=1" "$CAPTURE" || true)
echo "connections: $CONNS, binary frames: $BIN, text frames: $TEXT"
[ "$TEXT" = 0 ] || fail "text WebSocket frames present"

# What the intermediary must NOT be able to read.
ROUTE_A="$(sed -n 's/^route: //p' "$DATA/alice.enroll")"
IDENT_A="$(echo "$ROUTE_A" | cut -d: -f3)"
MAILBOX_B="$(echo "$ROUTE_B" | cut -d: -f4)"
WRITECAP_B="$(echo "$ROUTE_B" | cut -d: -f5)"
PAYLOADS="$(grep -v "HTTP" "$CAPTURE" | awk '{print $4}' | tr -d '\n')"
for hexword in "$IDENT_A" "$MAILBOX_B" "$WRITECAP_B"; do
  echo "$PAYLOADS" | grep -qi "$hexword" && fail "identifier or capability visible to the proxy: $hexword"
done
for ascii in EndpointListGet InviteRedeem EnvelopePut EnvelopeFetch KeyPackages MailboxCreate Ping "secreto de familia" arveil-route; do
  echo "$PAYLOADS" | grep -qi "$(printf '%s' "$ascii" | xxd -p | tr -d '\n')" && fail "frame name or text visible to the proxy: $ascii"
done
echo "no frame names, identifiers, capabilities or message text in the capture"
# What it CAN see: the HTTP upgrade, the path, sizes and timing.
echo "visible to the proxy: $(grep "$HTTPHEX" "$CAPTURE" | head -1 | awk '{print $4}' | xxd -r -p), plus $BIN opaque binary frames with their sizes and timing"
echo "q3 ok"
