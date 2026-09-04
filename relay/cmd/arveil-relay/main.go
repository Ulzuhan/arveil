// Command arveil-relay is the Arveil realm server: a store-and-forward relay
// that never holds E2EE keys, never joins an MLS group and never keeps a
// rooms table. See docs/ARCHITECTURE.md section 2 for its module boundaries.
//
// Phase 0, milestone M0.2: serves the Noise channel over WebSocket and
// answers Ping and EndpointListGet with a signed RealmEndpointList.
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/endpoints"
	"github.com/Ulzuhan/arveil/relay/internal/limits"
	"github.com/Ulzuhan/arveil/relay/internal/metrics"
	"github.com/Ulzuhan/arveil/relay/internal/realm"
	"github.com/Ulzuhan/arveil/relay/internal/server"
	"github.com/Ulzuhan/arveil/relay/internal/store"
	"github.com/Ulzuhan/arveil/relay/internal/version"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "invite":
			os.Exit(inviteCommand(os.Args[2:]))
		case "backup":
			os.Exit(backupCommand(os.Args[2:]))
		case "restore":
			os.Exit(restoreCommand(os.Args[2:]))
		case "healthcheck":
			os.Exit(healthcheckCommand(os.Args[2:]))
		}
	}
	serve()
}

// inviteCommand creates a one-use invite and prints its token. The relay
// stores only the token hash. Run on the admin side (loopback/LAN/tailnet).
func inviteCommand(args []string) int {
	fs := flag.NewFlagSet("invite", flag.ContinueOnError)
	dataDir := fs.String("data-dir", "./data", "relay data directory")
	ttl := fs.Duration("ttl", 24*time.Hour, "invite validity")
	uses := fs.Int("uses", 1, "number of enrollments the invite allows")
	role := fs.String("role", "member", "role granted (member or admin)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	st, err := store.Open(filepath.Join(*dataDir, "realm.db"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "store: %v\n", err)
		return 1
	}
	defer st.Close()
	token := make([]byte, 32)
	if _, err := rand.Read(token); err != nil {
		fmt.Fprintf(os.Stderr, "random: %v\n", err)
		return 1
	}
	h := sha256.Sum256(token)
	if err := st.CreateInvite(context.Background(), h[:], *role, time.Now().Add(*ttl), *uses); err != nil {
		fmt.Fprintf(os.Stderr, "create invite: %v\n", err)
		return 1
	}
	fmt.Printf("invite: %s\n", hex.EncodeToString(token))
	return 0
}

// healthcheckCommand asks the admin listener whether the relay is usable.
// It exists so a container image without a shell can still have a health
// check: the binary is the only thing in there.
func healthcheckCommand(args []string) int {
	fs := flag.NewFlagSet("healthcheck", flag.ContinueOnError)
	admin := fs.String("admin", "http://127.0.0.1:9090", "admin listener to ask")
	timeout := fs.Duration("timeout", 3*time.Second, "how long to wait")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(*admin, "/")+server.HealthPath, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 2
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "healthcheck: status %d\n", resp.StatusCode)
		return 1
	}
	fmt.Println("ok")
	return 0
}

func serve() {
	var (
		dataDir     = flag.String("data-dir", "./data", "directory holding realm.db, blobs/ and server-secrets/")
		listen      = flag.String("listen", "127.0.0.1:8447", "address to listen on (plain WebSocket; TLS is the carrier's job)")
		advertise   = flag.String("advertise", "", "comma-separated endpoints to sign, as kind=url (kinds: lan, tailnet, public, admin); default: lan=ws://<listen>"+server.ChannelPath)
		sweepEvery  = flag.Duration("sweep-interval", 5*time.Minute, "how often expired envelopes, invites, blobs and pairings are removed")
		pairTTL     = flag.Duration("pair-ttl", store.DefaultPairTTL, "how long a pairing rendezvous stays open")
		showVersion = flag.Bool("version", false, "print version and exit")

		adminListen = flag.String("admin-listen", "", "address for /healthz and /metrics (empty: not served); keep it off the tunnel")
		tlsCert     = flag.String("tls-cert", "", "certificate for serving wss:// directly (empty: plain ws, TLS is the carrier's job)")
		tlsKey      = flag.String("tls-key", "", "private key matching -tls-cert")

		maxConns     = flag.Int("max-conns", limits.Default().MaxTotal, "concurrent channels on the whole relay (0: unlimited)")
		maxPerAddr   = flag.Int("max-conns-per-addr", limits.Default().MaxPerAddr, "concurrent channels from one address (0: unlimited)")
		maxPairings  = flag.Int("max-pairings-per-addr", limits.Default().PairingsPerAddr, "pairing rendezvous one address may open per window (0: unlimited)")
		pairWindow   = flag.Duration("pairing-window", limits.Default().PairingWindow, "window for -max-pairings-per-addr")
		trustForward = flag.Bool("trust-forwarded-for", false, "read the client address from X-Forwarded-For; only with a proxy of yours that overwrites it")
	)
	flag.Parse()

	if *showVersion {
		fmt.Printf("arveil-relay %s (protocol %d)\n", version.Full(), version.Protocol)
		return
	}

	logger := log.New(os.Stderr, "arveil-relay: ", log.LstdFlags)

	id, err := realm.Load(*dataDir)
	if err != nil {
		logger.Fatalf("identity: %v", err)
	}
	st, err := store.Open(filepath.Join(*dataDir, "realm.db"))
	if err != nil {
		logger.Fatalf("store: %v", err)
	}
	defer st.Close()
	blobs, err := st.Blobs(*dataDir)
	if err != nil {
		logger.Fatalf("blobs: %v", err)
	}
	seq, err := id.NextSequence()
	if err != nil {
		logger.Fatalf("endpoint sequence: %v", err)
	}

	eps, err := parseAdvertise(*advertise, *listen, *tlsCert != "")
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
		Identity:   id,
		Store:      st,
		Blobs:      blobs,
		SignedList: signed,
		Logger:     logger,
		PairTTL:    *pairTTL,
		Limits: limits.New(limits.Config{
			MaxTotal:        *maxConns,
			MaxPerAddr:      *maxPerAddr,
			PairingsPerAddr: *maxPairings,
			PairingWindow:   *pairWindow,
		}),
		TrustForwardedFor: *trustForward,
		ReadTimeout:       90 * time.Second,
		HandshakeTTL:      10 * time.Second,
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		logger.Fatalf("listen: %v", err)
	}

	// Periodic cleanup: counts only in logs, never identifiers.
	go func() {
		t := time.NewTicker(*sweepEvery)
		defer t.Stop()
		for range t.C {
			r, err := st.Sweep(context.Background(), time.Now())
			if err != nil {
				logger.Printf("sweep failed")
				continue
			}
			nb, err := blobs.Sweep(context.Background(), time.Now())
			if err != nil {
				logger.Printf("blob sweep failed")
			}
			np, err := st.SweepPairs(context.Background(), time.Now())
			if err != nil {
				logger.Printf("pairing sweep failed")
			}
			metrics.EnvelopesSwept.Add(r.Envelopes)
			metrics.BlobsSwept.Add(nb)
			if r.Envelopes > 0 || r.Invites > 0 || nb > 0 || np > 0 {
				logger.Printf("sweep: %d envelope(s), %d invite(s), %d blob(s), %d pairing(s) removed", r.Envelopes, r.Invites, nb, np)
			}
		}
	}()

	// Bootstrap line: what a device needs to reach and authenticate this
	// realm. The QR of docs/PROTOCOL.md §3 will carry the same fields.
	fmt.Printf("bootstrap: arveil-bootstrap:v0:%s:%s:%s:%s\n",
		hex.EncodeToString(id.ID),
		hex.EncodeToString(id.SigningPublic()),
		hex.EncodeToString(id.NoiseKey.Public),
		eps[0].URL)
	logger.Printf("listening on %s, endpoint list sequence %d", ln.Addr(), seq)

	// Health and metrics on their own listener, only when asked for.
	if *adminListen != "" {
		adminLn, err := net.Listen("tcp", *adminListen)
		if err != nil {
			logger.Fatalf("admin listen: %v", err)
		}
		adminSrv := &http.Server{Handler: srv.AdminHandler(), ReadHeaderTimeout: 5 * time.Second}
		go func() {
			if err := adminSrv.Serve(adminLn); err != nil && err != http.ErrServerClosed {
				logger.Printf("admin listener stopped")
			}
		}()
		logger.Printf("admin listening on %s (%s, %s)", adminLn.Addr(), server.HealthPath, server.MetricsPath)
	}

	httpSrv := &http.Server{
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	var serveErr error
	if *tlsCert != "" {
		// TLS served here, for a realm reached directly instead of through
		// a tunnel that terminates it. The Noise channel protects the
		// content either way; this only protects the metadata a passive
		// observer of the network would otherwise see.
		serveErr = httpSrv.ServeTLS(ln, *tlsCert, *tlsKey)
	} else {
		serveErr = httpSrv.Serve(ln)
	}
	if serveErr != nil && serveErr != http.ErrServerClosed {
		logger.Fatalf("serve: %v", serveErr)
	}
}

func parseAdvertise(spec, listen string, tls bool) ([]endpoints.Endpoint, error) {
	if spec == "" {
		scheme := "ws://"
		if tls {
			scheme = "wss://"
		}
		return []endpoints.Endpoint{{Kind: endpoints.KindLAN, URL: scheme + listen + server.ChannelPath, Priority: 0}}, nil
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
