package server

import (
	"context"
	"net/http"
	"time"

	"github.com/Ulzuhan/arveil/relay/internal/metrics"
)

// Admin routes (M4.3). They live on their own listener, which the operator
// binds to loopback or a private interface and keeps off the tunnel: a
// tunnel points at the channel port, and nothing else needs to be reachable
// from outside.
const (
	HealthPath  = "/healthz"
	MetricsPath = "/metrics"
)

// AdminHandler serves health and metrics. Health answers whether the store
// is usable, since that is what an operator's probe actually wants to know.
func (s *Server) AdminHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(HealthPath, func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if s.Store != nil {
			if _, err := s.Store.Count(ctx, "realm_memberships"); err != nil {
				w.WriteHeader(http.StatusServiceUnavailable)
				// The reason is for the operator's log, not the response.
				s.Logger.Printf("health: store unavailable")
				_, _ = w.Write([]byte("store unavailable\n"))
				return
			}
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc(MetricsPath, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_ = metrics.WriteTo(w, metrics.Snapshot{ActiveConnections: s.Limits.Active()})
	})
	return mux
}
