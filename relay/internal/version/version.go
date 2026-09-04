// Package version exposes build identity for diagnostics and the health frame.
package version

// Relay is the relay's own version, set at build time via -ldflags in releases.
var Relay = "0.0.1-dev"

// Revision is the commit a release was built from, injected with -ldflags so
// a binary can be traced back to source (M3.5). Empty in local builds.
var Revision = ""

// Full is what `-version` prints: version, revision when known, protocol.
func Full() string {
	if Revision == "" {
		return Relay
	}
	return Relay + "+" + Revision
}

// Protocol is the wire protocol major version accepted by this relay.
// 0 means pre-release with no compatibility promise; see docs/PROTOCOL.md.
const Protocol uint16 = 0
