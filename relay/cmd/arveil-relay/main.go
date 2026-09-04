// Command arveil-relay is the Arveil realm server: a store-and-forward relay
// that never holds E2EE keys, never joins an MLS group and never keeps a
// rooms table. See docs/ARCHITECTURE.md section 2 for its module boundaries.
//
// Phase 0, milestone M0.2: serves the Noise channel over WebSocket and
// answers Ping and EndpointListGet with a signed RealmEndpointList.
package main

import (
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/endpoints"
	"github.com/Ulzuhan/arveil/relay/internal/realm"
	"github.com/Ulzuhan/arveil/relay/internal/server"
	"github.com/Ulzuhan/arveil/relay/internal/version"
)

func main() {
	var (
		dataDir     = flag.String("data-dir", "./data", "directory holding realm.db, blobs/ and server-secrets/")
		listen      = flag.String("listen", "127.0.0.1:8447", "address to listen on (plain WebSocket; TLS is the carrier's job)")
		advertise   = flag.String("advertise", "", "comma-separated endpoints to sign, as kind=url (kinds: lan, tailnet, public, admin); default: lan=ws://<listen>"+server.ChannelPath)
		showVersion = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()

	if *showVersion {
		fmt.Printf("arveil-relay %s (protocol %d)\n", version.Relay, version.Protocol)
		return
	}

	logger := log.New(os.Stderr, "arveil-relay: ", log.LstdFlags)

	id, err := realm.Load(*dataDir)
	if err != nil {
		logger.Fatalf("identity: %v", err)
	}
	seq, err := id.NextSequence()
	if err != nil {
		logger.Fatalf("endpoint sequence: %v", err)
	}

	eps, err := parseAdvertise(*advertise, *listen)
	if err != nil {
		logger.Fatalf("advertise: %v", err)
	}
	signed, err := endpoints.Sign(endpoints.RealmEndpointList{
		Version:             endpoints.Version,
		RealmID:             id.ID,
		Sequence:            seq,
		RealmNoisePublicKey: id.NoiseKey.Public,
		Endpoints:           eps,
	}, id.SigningKey)
	if err != nil {
		logger.Fatalf("sign endpoint list: %v", err)
	}

	srv := &server.Server{
		Identity:     id,
		SignedList:   signed,
		Logger:       logger,
		ReadTimeout:  90 * time.Second,
		HandshakeTTL: 10 * time.Second,
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		logger.Fatalf("listen: %v", err)
	}

	// Bootstrap line: what a device needs to reach and authenticate this
	// realm. The QR of docs/PROTOCOL.md §3 will carry the same fields.
	fmt.Printf("bootstrap: arveil-bootstrap:v0:%s:%s:%s:%s\n",
		hex.EncodeToString(id.ID),
		hex.EncodeToString(id.SigningPublic()),
		hex.EncodeToString(id.NoiseKey.Public),
		eps[0].URL)
	logger.Printf("listening on %s, endpoint list sequence %d", ln.Addr(), seq)

	httpSrv := &http.Server{
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		logger.Fatalf("serve: %v", err)
	}
}

func parseAdvertise(spec, listen string) ([]endpoints.Endpoint, error) {
	if spec == "" {
		return []endpoints.Endpoint{{Kind: endpoints.KindLAN, URL: "ws://" + listen + server.ChannelPath, Priority: 0}}, nil
	}
	var out []endpoints.Endpoint
	for i, item := range strings.Split(spec, ",") {
		kind, url, ok := strings.Cut(strings.TrimSpace(item), "=")
		if !ok {
			return nil, fmt.Errorf("item %q is not kind=url", item)
		}
		switch kind {
		case endpoints.KindLAN, endpoints.KindTailnet, endpoints.KindPublic, endpoints.KindAdmin:
		default:
			return nil, fmt.Errorf("unknown kind %q", kind)
		}
		out = append(out, endpoints.Endpoint{Kind: kind, URL: url, Priority: uint8(i)})
	}
	return out, nil
}
