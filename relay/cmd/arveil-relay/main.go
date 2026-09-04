// Command arveil-relay is the Arveil realm server: a store-and-forward relay
// that never holds E2EE keys, never joins an MLS group and never keeps a
// rooms table. See docs/ARCHITECTURE.md section 2 for its module boundaries.
//
// Phase 0 status: skeleton only. Flags are the ones the final binary will
// keep; the listener, SQLite store and Noise channel arrive milestone by
// milestone (docs/PHASE0.md).
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/Ulzuhan/arveil/relay/internal/version"
)

func main() {
	var (
		dataDir     = flag.String("data-dir", "./data", "directory holding config.toml, realm.db, blobs/ and server-secrets/")
		showVersion = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()

	if *showVersion {
		fmt.Printf("arveil-relay %s (protocol %d)\n", version.Relay, version.Protocol)
		return
	}

	fmt.Fprintf(os.Stderr, "arveil-relay: data directory %q; serving is not implemented yet (Phase 0 milestone M0.2)\n", *dataDir)
	os.Exit(2)
}
