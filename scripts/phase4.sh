#!/usr/bin/env bash
# Phase 4 acceptance (docs/PHASE4.md). Each section maps to a milestone.
# Exit 0 only if every check passes. ARVEIL_P4_KEEP=1 keeps the data dir.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$(mktemp -d)"
PORT="${ARVEIL_P4_PORT:-18500}"
ADMIN_PORT=$((PORT + 1))
TLS_PORT=$((PORT + 2))
RELAY="$ROOT/relay/bin/arveil-relay"
CLI="$ROOT/core/target/debug/arveil"
RELAY_PID=""

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
cleanup() {
  for pid in ${EXTRA_PIDS:-}; do kill "$pid" 2>/dev/null || true; done
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null || true; wait "$RELAY_PID" 2>/dev/null || true; fi
  [ -n "${ARVEIL_P4_KEEP:-}" ] && echo "data kept in $DATA" || rm -rf "$DATA"
}
trap cleanup EXIT
EXTRA_PIDS=""

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
wait_for() {
  for _ in $(seq 1 200); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  cat "$1" 2>/dev/null || true; fail "timed out waiting for '$2' in $1"
}

(cd "$ROOT/relay" && go build -o bin/arveil-relay ./cmd/arveil-relay)
(cd "$ROOT/core" && cargo build -q -p arveil-cli)

step "M4.3 health and metrics answer on their own listener, and only there"
start_relay -admin-listen "127.0.0.1:$ADMIN_PORT"
BOOTSTRAP="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"
curl -fsS "http://127.0.0.1:$ADMIN_PORT/healthz" > "$DATA/health"
grep -qx "ok" "$DATA/health" || fail "health did not answer ok: $(cat "$DATA/health")"
"$RELAY" healthcheck -admin "http://127.0.0.1:$ADMIN_PORT" > "$DATA/healthcheck"
grep -qx "ok" "$DATA/healthcheck" || fail "the healthcheck subcommand did not answer ok"
curl -fsS "http://127.0.0.1:$ADMIN_PORT/metrics" > "$DATA/metrics"
for m in arveil_uptime_seconds arveil_connections_total arveil_connections_active arveil_envelopes_stored_total; do
  grep -q "^$m " "$DATA/metrics" || fail "metric $m missing"
done
grep -q "{" "$DATA/metrics" && fail "metrics carry labels, which is where a per-person dimension would arrive"
# The channel port serves the channel and nothing else.
curl -fsS "http://127.0.0.1:$PORT/healthz" > /dev/null 2>&1 && fail "health is served on the public channel port"
curl -fsS "http://127.0.0.1:$PORT/metrics" > /dev/null 2>&1 && fail "metrics are served on the public channel port"
echo "health and metrics only on the admin listener"

step "M4.6 KeyPackages are replenished before anybody is refused a conversation"
"$CLI" enroll --data-dir "$DATA/ana" "$BOOTSTRAP" "$(invite)" > "$DATA/ana.enroll"
ROUTE_ANA="$(route_of "$DATA/ana.enroll")"
# The batch published at enrolment is five: five people consume it.
for i in 1 2 3 4 5; do
  "$CLI" enroll --data-dir "$DATA/p$i" "$BOOTSTRAP" "$(invite)" > "$DATA/p$i.enroll"
  "$CLI" chat start --data-dir "$DATA/p$i" "$BOOTSTRAP" "$ROUTE_ANA" > "$DATA/p$i.start"
done
"$CLI" enroll --data-dir "$DATA/p6" "$BOOTSTRAP" "$(invite)" > "$DATA/p6.enroll"
expect_fail "$DATA/p6.start" "$CLI" chat start --data-dir "$DATA/p6" "$BOOTSTRAP" "$ROUTE_ANA" || fail "a sixth conversation started with an empty shelf"
grep -q "no key package available" "$DATA/p6.start" || fail "unexpected refusal: $(cat "$DATA/p6.start")"
"$CLI" chat sync --data-dir "$DATA/ana" "$BOOTSTRAP" | tee "$DATA/ana.sync1"
grep -q "key packages: 0 left at the realm, 10 more published" "$DATA/ana.sync1" || fail "the client did not top up its key packages"
"$CLI" chat start --data-dir "$DATA/p6" "$BOOTSTRAP" "$ROUTE_ANA" > "$DATA/p6.start2"
grep -q "^conversation: " "$DATA/p6.start2" || fail "the sixth conversation still cannot start"
"$CLI" chat sync --data-dir "$DATA/ana" "$BOOTSTRAP" > "$DATA/ana.sync2"

step "M4.7 several conversations: the client says which, instead of guessing"
"$CLI" chat list --data-dir "$DATA/ana" | tee "$DATA/ana.list"
[ "$(grep -c '^[0-9a-f]\{64\} ' "$DATA/ana.list")" -ge 6 ] || fail "chat list does not show every conversation"
expect_fail "$DATA/ana.ambiguous" "$CLI" chat send --data-dir "$DATA/ana" "$BOOTSTRAP" "hola" || fail "a send with several conversations picked one on its own"
grep -q "choose one with --group" "$DATA/ana.ambiguous" || fail "unexpected refusal: $(cat "$DATA/ana.ambiguous")"
G1="$(sed -n '1s/^\([0-9a-f]\{12\}\).*/\1/p' "$DATA/ana.list")"
G2="$(sed -n '2s/^\([0-9a-f]\{12\}\).*/\1/p' "$DATA/ana.list")"
"$CLI" chat send --data-dir "$DATA/ana" --group "$G1" "$BOOTSTRAP" "para la primera" > "$DATA/ana.send1"
"$CLI" chat send --data-dir "$DATA/ana" --group "$G2" "$BOOTSTRAP" "para la segunda" > "$DATA/ana.send2"
"$CLI" chat sync --data-dir "$DATA/p1" "$BOOTSTRAP" > "$DATA/p1.sync"
"$CLI" chat sync --data-dir "$DATA/p2" "$BOOTSTRAP" > "$DATA/p2.sync"
grep -q "message: para la primera" "$DATA/p1.sync" || fail "the first conversation did not receive its message"
grep -q "message: para la segunda" "$DATA/p2.sync" || fail "the second conversation did not receive its message"
grep -q "para la segunda" "$DATA/p1.sync" && fail "a message went to the wrong conversation"
expect_fail "$DATA/ana.unknown" "$CLI" chat send --data-dir "$DATA/ana" --group ffffffffffff "$BOOTSTRAP" "nadie" || fail "an unknown prefix was accepted"
grep -q "no conversation starts with" "$DATA/ana.unknown" || fail "unexpected refusal for an unknown prefix"
expect_fail "$DATA/ana.wide" "$CLI" chat send --data-dir "$DATA/ana" --group "" "$BOOTSTRAP" "todos" || fail "an ambiguous prefix was accepted"
grep -q "conversations:" "$DATA/ana.wide" || fail "an ambiguous prefix does not list the candidates"

step "M4.8 contacts have local names, and the names authenticate nothing"
"$CLI" contact list --data-dir "$DATA/p1" > "$DATA/p1.contacts"
ANA_ID="$(sed -n 's/^contact \([0-9a-f]*\) .*/\1/p' "$DATA/p1.contacts" | head -1)"
NUM_BEFORE="$(sed -n 's/^  safety number: //p' "$DATA/p1.contacts" | head -1)"
"$CLI" contact name --data-dir "$DATA/p1" "$ANA_ID" "Ana" | tee "$DATA/p1.name"
grep -q "shown as Ana on this device only" "$DATA/p1.name" || fail "the name was not stored"
"$CLI" contact list --data-dir "$DATA/p1" > "$DATA/p1.contacts2"
grep -q "^contact $ANA_ID \[not verified\] Ana" "$DATA/p1.contacts2" || fail "the name is not shown in the contact list"
NUM_AFTER="$(sed -n 's/^  safety number: //p' "$DATA/p1.contacts2" | head -1)"
[ "$NUM_BEFORE" = "$NUM_AFTER" ] || fail "naming a contact changed its safety number"
"$CLI" chat history --data-dir "$DATA/p1" > "$DATA/p1.history"
grep -q "peers: Ana/" "$DATA/p1.history" || fail "the name is not used in the history"
if command -v sqlite3 >/dev/null; then
  sqlite3 "$DATA/relay/realm.db" '.dump' > "$DATA/relay.dump"
  grep -qa "Ana" "$DATA/relay.dump" && fail "a local name reached the realm"
fi
"$CLI" contact name --data-dir "$DATA/p1" "$ANA_ID" "" > "$DATA/p1.unname"
grep -q "name removed" "$DATA/p1.unname" || fail "a name cannot be removed"

step "M4.5 a backup taken while the realm runs restores into a working realm"
"$CLI" chat send --data-dir "$DATA/p1" "$BOOTSTRAP" "antes de la copia" > /dev/null
"$RELAY" backup -data-dir "$DATA/relay" -out "$DATA/realm.tar.gz" | tee "$DATA/backup.out"
grep -q "^backup: .* written" "$DATA/backup.out" || fail "the backup was not written"
grep -q "encrypt it" "$DATA/backup.out" || fail "the backup does not say what it holds"
expect_fail "$DATA/backup.again" "$RELAY" backup -data-dir "$DATA/relay" -out "$DATA/realm.tar.gz" || fail "a backup silently overwrote an existing archive"
expect_fail "$DATA/restore.live" "$RELAY" restore -in "$DATA/realm.tar.gz" -data-dir "$DATA/relay" || fail "a restore overwrote a live data directory"
grep -q "is not empty" "$DATA/restore.live" || fail "unexpected refusal: $(cat "$DATA/restore.live")"
"$RELAY" restore -in "$DATA/realm.tar.gz" -data-dir "$DATA/restored" | tee "$DATA/restore.out"
grep -q "^restore: " "$DATA/restore.out" || fail "the restore did not run"
stop_relay
mv "$DATA/relay" "$DATA/relay.old"
mv "$DATA/restored" "$DATA/relay"
start_relay -admin-listen "127.0.0.1:$ADMIN_PORT"
BOOTSTRAP2="$(sed -n 's/^bootstrap: //p' "$DATA/relay.out" | head -1)"
[ "${BOOTSTRAP2%%:ws*}" = "${BOOTSTRAP%%:ws*}" ] || fail "the restored realm has another identity"
"$CLI" chat sync --data-dir "$DATA/ana" "$BOOTSTRAP" | tee "$DATA/ana.sync3"
grep -q "message: antes de la copia" "$DATA/ana.sync3" || fail "the restored realm lost a message it had accepted"
"$CLI" chat send --data-dir "$DATA/ana" --group "$G1" "$BOOTSTRAP" "después de restaurar" > /dev/null
"$CLI" chat sync --data-dir "$DATA/p1" "$BOOTSTRAP" | tee "$DATA/p1.sync2"
grep -q "message: después de restaurar" "$DATA/p1.sync2" || fail "the conversation does not continue after the restore"

step "M4.2 one address cannot take the realm's pairing capacity"
stop_relay
start_relay -max-pairings-per-addr 1 -max-conns-per-addr 1 -admin-listen "127.0.0.1:$ADMIN_PORT"
ARVEIL_PAIR_TIMEOUT_SECS=3 "$CLI" device pair --data-dir "$DATA/newdev" "$BOOTSTRAP" > "$DATA/newdev.pair" 2>&1 &
PAIR_PID=$!
EXTRA_PIDS="$EXTRA_PIDS $PAIR_PID"
wait_for "$DATA/newdev.pair" "^code: "
# A second connection from the same address is refused while the first holds one.
expect_fail "$DATA/probe.refused" "$CLI" probe "$BOOTSTRAP" || fail "the connection limit did not bite"
kill "$PAIR_PID" 2>/dev/null || true; wait "$PAIR_PID" 2>/dev/null || true
grep -q "connection refused by a limit" "$DATA/relay.err" || fail "the relay did not log the refusal"
# The refusal says a limit bit, never which address hit it. The relay's own
# listen addresses are elsewhere in the log and are the operator's business.
grep "refused by a" "$DATA/relay.err" > "$DATA/refusals"
grep -qE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|::1" "$DATA/refusals" && fail "a refusal line names an address"
# The second rendezvous from this address is refused, and the log says so.
expect_fail "$DATA/newdev2.pair" "$CLI" device pair --data-dir "$DATA/newdev2" "$BOOTSTRAP" || fail "a second rendezvous from the same address was allowed"
grep -q "429" "$DATA/newdev2.pair" || fail "unexpected refusal: $(cat "$DATA/newdev2.pair")"
grep -q "pairing refused by a per-address limit" "$DATA/relay.err" || fail "the pairing refusal is not logged"
curl -fsS "http://127.0.0.1:$ADMIN_PORT/metrics" > "$DATA/metrics2"
grep -q "^arveil_pairings_refused_total 1" "$DATA/metrics2" || fail "the refusal is not counted"
grep -q "^arveil_connections_refused_total 1" "$DATA/metrics2" || fail "the connection refusal is not counted"

step "M4.4 the relay serves TLS itself when told to"
stop_relay
# A certificate authority and a leaf signed by it: a self-signed
# certificate presented as the server's own is refused by the client, and
# rightly so.
{
  openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes \
    -keyout "$DATA/ca.key" -out "$DATA/ca.crt" -subj "/CN=arveil-test-ca"
  openssl req -newkey rsa:2048 -nodes -keyout "$DATA/relay.key" -out "$DATA/relay.csr" \
    -subj "/CN=arveil-relay"
  printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > "$DATA/leaf.ext"
  openssl x509 -req -in "$DATA/relay.csr" -CA "$DATA/ca.crt" -CAkey "$DATA/ca.key" \
    -CAcreateserial -out "$DATA/relay.crt" -days 2 -sha256 -extfile "$DATA/leaf.ext"
} > /dev/null 2>&1 || fail "could not make a certificate"
"$RELAY" -data-dir "$DATA/relay" -listen "127.0.0.1:$TLS_PORT" -tls-cert "$DATA/relay.crt" -tls-key "$DATA/relay.key" > "$DATA/tls.out" 2>> "$DATA/relay.err" &
RELAY_PID=$!
for _ in $(seq 1 50); do grep -q '^bootstrap: ' "$DATA/tls.out" && break; sleep 0.1; done
TLS_BOOTSTRAP="$(sed -n 's/^bootstrap: //p' "$DATA/tls.out" | head -1)"
case "$TLS_BOOTSTRAP" in
  *wss://*) : ;;
  *) fail "a TLS relay advertised a plain ws:// endpoint: $TLS_BOOTSTRAP" ;;
esac
ARVEIL_TLS_CA="$DATA/ca.crt" "$CLI" probe "$TLS_BOOTSTRAP" | tee "$DATA/tls.probe"
grep -q "probe ok" "$DATA/tls.probe" || fail "no client could reach the relay over TLS"
expect_fail "$DATA/tls.noca" "$CLI" probe "$TLS_BOOTSTRAP" || fail "a client trusted an unknown certificate"

step "M4.1 packaging: the unit and the compose file are valid, and the image serves a realm"
[ -f "$ROOT/relay/Dockerfile" ] || fail "no Dockerfile"
[ -f "$ROOT/relay/compose.yaml" ] || fail "no compose file"
[ -f "$ROOT/relay/packaging/arveil-relay.service" ] || fail "no systemd unit"
if command -v systemd-analyze >/dev/null; then
  # Verify a copy whose ExecStart points at the binary just built: the unit
  # ships with the installed path, which is not there on a build machine,
  # and that absence would be the only thing verify complained about.
  sed "s#^ExecStart=/usr/local/bin/arveil-relay#ExecStart=$RELAY#" \
    "$ROOT/relay/packaging/arveil-relay.service" > "$DATA/arveil-relay.service"
  systemd-analyze verify "$DATA/arveil-relay.service" > "$DATA/unit.verify" 2>&1 || true
  if [ -s "$DATA/unit.verify" ]; then
    cat "$DATA/unit.verify"
    fail "systemd-analyze had something to say about the unit"
  fi
  echo "systemd unit verified"
else
  echo "systemd-analyze not installed: unit checked for its required directives only"
  for directive in ExecStart User StateDirectory NoNewPrivileges ProtectSystem; do
    grep -q "^$directive" "$ROOT/relay/packaging/arveil-relay.service" || fail "the unit has no $directive"
  done
fi
if docker info > /dev/null 2>&1; then
  docker compose -f "$ROOT/relay/compose.yaml" config > /dev/null || fail "the compose file is not valid"
  docker build -q -f "$ROOT/relay/Dockerfile" -t arveil-relay:phase4 "$ROOT" > "$DATA/image" || fail "the image did not build"
  CPORT=$((PORT + 3))
  CID="$(docker run -d -p "127.0.0.1:$CPORT:8447" arveil-relay:phase4 \
      -data-dir /data -listen 0.0.0.0:8447 -advertise "lan=ws://127.0.0.1:$CPORT/v1/channel")"
  for _ in $(seq 1 50); do docker logs "$CID" 2>&1 | grep -q '^bootstrap: ' && break; sleep 0.2; done
  docker logs "$CID" > "$DATA/container.log" 2>&1
  CBOOT="$(sed -n 's/^bootstrap: //p' "$DATA/container.log" | head -1)"
  [ -n "$CBOOT" ] || { cat "$DATA/container.log"; docker rm -f "$CID" > /dev/null; fail "the container printed no bootstrap"; }
  CINV="$(docker exec "$CID" /arveil-relay invite -data-dir /data | sed -n 's/^invite: //p')"
  CINV2="$(docker exec "$CID" /arveil-relay invite -data-dir /data | sed -n 's/^invite: //p')"
  "$CLI" enroll --data-dir "$DATA/c1" "$CBOOT" "$CINV" > "$DATA/c1.enroll"
  "$CLI" enroll --data-dir "$DATA/c2" "$CBOOT" "$CINV2" > "$DATA/c2.enroll"
  "$CLI" chat start --data-dir "$DATA/c1" "$CBOOT" "$(route_of "$DATA/c2.enroll")" > /dev/null
  "$CLI" chat sync --data-dir "$DATA/c2" "$CBOOT" > /dev/null
  "$CLI" chat send --data-dir "$DATA/c2" "$CBOOT" "hola desde el contenedor" > /dev/null
  "$CLI" chat sync --data-dir "$DATA/c1" "$CBOOT" > "$DATA/c1.sync"
  docker rm -f "$CID" > /dev/null
  grep -q "message: hola desde el contenedor" "$DATA/c1.sync" || fail "the container did not carry a conversation"
  echo "the image builds and serves a real conversation"
else
  echo "docker not available: image build skipped"
fi

step "phase 4 ok"
