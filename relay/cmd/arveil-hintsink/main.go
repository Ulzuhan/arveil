// Command arveil-hintsink is a test tool: an HTTP endpoint that records what
// a notification hint actually contains, so `scripts/phase3.sh` can assert
// that it carries nothing but the fact that mail exists.
//
// It is not part of the relay and is never run in production.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:18490", "address to listen on")
	out := flag.String("out", "hints.log", "file to append one line per request to")
	flag.Parse()

	f, err := os.OpenFile(*out, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(io.LimitReader(r.Body, 4096))
		// Everything the endpoint could learn, on one line.
		fmt.Fprintf(f, "%s method=%s path=%q query=%q length=%d body=%q agent=%q\n",
			time.Now().UTC().Format(time.RFC3339), r.Method, r.URL.Path, r.URL.RawQuery,
			r.ContentLength, string(body), r.UserAgent())
		w.WriteHeader(http.StatusNoContent)
	})
	fmt.Printf("hintsink: listening on %s, writing %s\n", *listen, *out)
	srv := &http.Server{Addr: *listen, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(srv.ListenAndServe())
}
