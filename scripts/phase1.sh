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
  "$RELAY" -data-dir "$DATA/relay" -listen "127.0.0.1:$PORT" -sweep-interval 1s "$@" > "$DATA/relay.out" 2>> "$DATA/relay.err" &
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
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" > "$DATA/out1"
grep -q "synced: 0 envelope" "$DATA/out1" || fail "duplicate after ack"
"$CLI" chat history --data-dir "$DATA/bob" | tee "$DATA/bob.hist2"
[ "$(grep -c 'accepted (relay keeps it until' "$DATA/bob.hist2")" = 2 ] || fail "states did not move to accepted"
grep -q "delivered" "$DATA/bob.hist2" && fail "a relay ACK must never be shown as delivered"

step "M1.2 group chat: alice starts a group with bob and carol; everyone reads everyone"
"$CLI" enroll --data-dir "$DATA/carol" "$BOOTSTRAP" "$(invite)" > "$DATA/carol.enroll"
ROUTE_C="$(route_of "$DATA/carol.enroll")"
"$CLI" enroll --data-dir "$DATA/g-alice" "$BOOTSTRAP" "$(invite)" > "$DATA/g-alice.enroll"
"$CLI" enroll --data-dir "$DATA/g-bob" "$BOOTSTRAP" "$(invite)" > "$DATA/g-bob.enroll"
ROUTE_GB="$(route_of "$DATA/g-bob.enroll")"
"$CLI" chat start --data-dir "$DATA/g-alice" "$BOOTSTRAP" "$ROUTE_GB" "$ROUTE_C" | tee "$DATA/g.start"
grep -q "created with 2 peer(s)" "$DATA/g.start" || fail "group not created with two peers"
"$CLI" chat sync --data-dir "$DATA/g-bob" "$BOOTSTRAP" | tee "$DATA/g-bob.sync1"
grep -q "roster: 2 peer route(s)" "$DATA/g-bob.sync1" || fail "bob did not learn two routes"
"$CLI" chat sync --data-dir "$DATA/carol" "$BOOTSTRAP" | tee "$DATA/carol.sync1"
grep -q "roster: 2 peer route(s)" "$DATA/carol.sync1" || fail "carol did not learn two routes"
"$CLI" chat send --data-dir "$DATA/g-bob" "$BOOTSTRAP" "hola grupo, soy bob" | tee "$DATA/g-bob.send"
grep -q "2 envelope(s) queued" "$DATA/g-bob.send" || fail "fan-out did not produce two envelopes"
"$CLI" chat send --data-dir "$DATA/carol" "$BOOTSTRAP" "hola, soy carol" > /dev/null
"$CLI" chat sync --data-dir "$DATA/g-alice" "$BOOTSTRAP" | tee "$DATA/g-alice.sync1"
grep -q "message: hola grupo, soy bob" "$DATA/g-alice.sync1" || fail "alice missed bob"
grep -q "message: hola, soy carol" "$DATA/g-alice.sync1" || fail "alice missed carol"
"$CLI" chat sync --data-dir "$DATA/g-bob" "$BOOTSTRAP" > "$DATA/out2"
grep -q "message: hola, soy carol" "$DATA/out2" || fail "bob missed carol"
"$CLI" chat sync --data-dir "$DATA/carol" "$BOOTSTRAP" > "$DATA/out3"
grep -q "message: hola grupo, soy bob" "$DATA/out3" || fail "carol missed bob"

step "M1.2 chat add: dave joins later and reads only what follows; a non-creator cannot add"
"$CLI" enroll --data-dir "$DATA/dave" "$BOOTSTRAP" "$(invite)" > "$DATA/dave.enroll"
ROUTE_D="$(route_of "$DATA/dave.enroll")"
"$CLI" chat add --data-dir "$DATA/g-alice" "$BOOTSTRAP" "$ROUTE_D" | tee "$DATA/g.add"
grep -q "added: " "$DATA/g.add" || fail "add failed"
"$CLI" chat sync --data-dir "$DATA/g-bob" "$BOOTSTRAP" | tee "$DATA/g-bob.sync3"
grep -q "commit from leaf 0 applied (epoch 2)" "$DATA/g-bob.sync3" || fail "bob did not apply the add commit"
grep -q "roster: 3 peer route(s)" "$DATA/g-bob.sync3" || fail "bob did not learn dave's route"
"$CLI" chat sync --data-dir "$DATA/carol" "$BOOTSTRAP" > /dev/null
"$CLI" chat sync --data-dir "$DATA/dave" "$BOOTSTRAP" | tee "$DATA/dave.sync1"
grep -q "joined conversation .* (epoch 2)" "$DATA/dave.sync1" || fail "dave did not join at epoch 2"
grep -q "roster: 3 peer route(s)" "$DATA/dave.sync1" || fail "dave did not learn three routes"
"$CLI" chat send --data-dir "$DATA/g-alice" "$BOOTSTRAP" "bienvenido dave" > /dev/null
"$CLI" chat sync --data-dir "$DATA/dave" "$BOOTSTRAP" > "$DATA/out4"
grep -q "message: bienvenido dave" "$DATA/out4" || fail "dave missed the message after his add"
"$CLI" chat history --data-dir "$DATA/dave" | tee "$DATA/dave.hist"
grep -q "soy bob" "$DATA/dave.hist" && fail "dave can read history from before his add"
"$CLI" enroll --data-dir "$DATA/eve" "$BOOTSTRAP" "$(invite)" > "$DATA/eve.enroll"
ROUTE_E="$(route_of "$DATA/eve.enroll")"
if "$CLI" chat add --data-dir "$DATA/g-bob" "$BOOTSTRAP" "$ROUTE_E" > "$DATA/bob.add" 2>&1; then
  fail "a non-creator was able to add a member"
fi
grep -q "only the lowest active leaf may commit" "$DATA/bob.add" || { cat "$DATA/bob.add"; fail "unexpected refusal reason"; }
echo "refused as expected: $(grep -o 'only the lowest active leaf may commit[^)]*' "$DATA/bob.add" | head -1)"

step "M1.3 TTL: a 2-second envelope is swept before the receiver syncs; the sender shows expired/unknown"
stop_relay
start_relay
ARVEIL_ENVELOPE_TTL_SECS=2 "$CLI" chat send --data-dir "$DATA/bob" "$BOOTSTRAP" "mensaje efímero" > "$DATA/ttl.send"
grep -q "published: 1" "$DATA/ttl.send" || fail "ephemeral message not published"
sleep 4
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" > "$DATA/ttl.sync"
grep -q "synced: 0 envelope" "$DATA/ttl.sync" || { cat "$DATA/ttl.sync"; fail "expired envelope was still delivered"; }
grep -q "sweep: 1 envelope(s)" "$DATA/relay.err" || { tail -3 "$DATA/relay.err"; fail "relay did not log the sweep"; }
"$CLI" chat history --data-dir "$DATA/bob" > "$DATA/ttl.hist"
grep -q "mensaje efímero" "$DATA/ttl.hist" || fail "sender lost its local copy"
grep -A1 "mensaje efímero" "$DATA/ttl.hist" | grep -q "expired/unknown" || { grep -A1 "mensaje efímero" "$DATA/ttl.hist"; fail "sender does not show expired/unknown"; }
echo "expired envelope swept; sender keeps the message and shows expired/unknown"

step "M1.4 endpoint fallback: the relay advertises a dead endpoint first; clients skip it"
stop_relay
start_relay -advertise "lan=ws://127.0.0.1:$DEAD_PORT/v1/channel,public=ws://127.0.0.1:$PORT/v1/channel"
# First contact still uses the stored list (one live endpoint) and learns the new one.
"$CLI" chat sync --data-dir "$DATA/alice" "$BOOTSTRAP" > "$DATA/ep1"
grep -q "endpoint list: sequence .* with 2 endpoint(s) stored" "$DATA/ep1" || { cat "$DATA/ep1"; fail "new endpoint list not stored"; }
# From now on the dead endpoint is tried first and skipped.
"$CLI" chat send --data-dir "$DATA/alice" "$BOOTSTRAP" "llego por el segundo endpoint" > "$DATA/ep2"
grep -q "endpoint: ws://127.0.0.1:$DEAD_PORT/v1/channel failed" "$DATA/ep2" || { cat "$DATA/ep2"; fail "dead endpoint not reported"; }
grep -q "endpoint: ws://127.0.0.1:$PORT/v1/channel (earlier endpoints unreachable)" "$DATA/ep2" || fail "live endpoint not used"
grep -q "published: 1" "$DATA/ep2" || fail "message not published through the fallback endpoint"
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" > "$DATA/ep3"
grep -q "message: llego por el segundo endpoint" "$DATA/ep3" || fail "bob did not receive through the fallback"
"$CLI" status --data-dir "$DATA/bob" | tee "$DATA/ep4" | grep -q "$DEAD_PORT" || fail "status does not list both endpoints"

step "M1.5 attachments: a 1 MiB file round-trips with matching hash; the relay stores only ciphertext"
head -c 1048576 /dev/urandom > "$DATA/photo.bin"
"$CLI" chat send-file --data-dir "$DATA/alice" "$BOOTSTRAP" "$DATA/photo.bin" > "$DATA/f1"
grep -q "blob: .* uploaded" "$DATA/f1" || { cat "$DATA/f1"; fail "upload failed"; }
grep -q "published: 1" "$DATA/f1" || fail "descriptor not published"
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" > "$DATA/f2"
grep -q "file: photo.bin saved to" "$DATA/f2" || { cat "$DATA/f2"; fail "bob did not download the file"; }
cmp "$DATA/photo.bin" "$DATA/bob/downloads/photo.bin" || fail "downloaded file differs"
BLOB_FILE="$(ls "$DATA/relay/blobs" | head -1)"
[ -n "$BLOB_FILE" ] || fail "no blob file on the relay"
if grep -q "$(head -c 48 "$DATA/photo.bin" | xxd -p | tr -d '\n')" <(xxd -p "$DATA/relay/blobs/$BLOB_FILE" | tr -d '\n'); then
  fail "plaintext bytes found in the relay blob"
fi
"$CLI" chat history --data-dir "$DATA/bob" > "$DATA/f3"
grep -q "received-file" "$DATA/f3" || fail "history lacks the received file"
echo "1 MiB file delivered and verified; relay blob holds ciphertext only"

step "M1.5 attachments: an expired blob is reported as unavailable, never silently skipped"
ARVEIL_BLOB_TTL_SECS=2 "$CLI" chat send-file --data-dir "$DATA/alice" "$BOOTSTRAP" "$DATA/photo.bin" > "$DATA/f4"
sleep 4
"$CLI" chat sync --data-dir "$DATA/bob" "$BOOTSTRAP" > "$DATA/f5"
grep -q "file unavailable: photo.bin" "$DATA/f5" || { cat "$DATA/f5"; fail "expired blob not reported"; }
grep -q "sweep: .* 1 blob(s)" "$DATA/relay.err" || { tail -3 "$DATA/relay.err"; fail "blob sweep not logged"; }
"$CLI" chat history --data-dir "$DATA/bob" > "$DATA/f6"
grep -q "file-unavailable" "$DATA/f6" || fail "history lacks the unavailable file"
echo "expired blob swept and reported as unavailable"

step "phase 1 ok"
