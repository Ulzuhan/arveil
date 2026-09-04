// Command arveil-tlsproxy is a test tool for ADR-008 acceptance (Q3): a
// TLS-terminating reverse proxy that forwards WebSocket connections to a
// plaintext relay and records every WebSocket frame it sees, unmasked, to a
// capture file. It plays the role of Cloudflare Tunnel or any intermediary
// that terminates TLS. Anything readable in the capture is what such an
// intermediary learns.
//
// It is not part of the product and has no security properties of its own.
package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"sync"
	"time"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:18450", "TLS listen address")
	upstream := flag.String("upstream", "127.0.0.1:18448", "plaintext relay address")
	capture := flag.String("capture", "capture.log", "file receiving one line per WebSocket frame")
	caOut := flag.String("ca-out", "proxy-ca.pem", "file receiving the self-signed certificate (PEM) for clients to trust")
	flag.Parse()

	cert, err := selfSigned(*caOut)
	if err != nil {
		log.Fatalf("certificate: %v", err)
	}
	capFile, err := os.Create(*capture)
	if err != nil {
		log.Fatalf("capture: %v", err)
	}
	defer capFile.Close()
	var mu sync.Mutex
	record := func(dir string, opcode byte, payload []byte) {
		mu.Lock()
		defer mu.Unlock()
		fmt.Fprintf(capFile, "%s opcode=%d len=%d %s\n", dir, opcode, len(payload), hex.EncodeToString(payload))
	}

	ln, err := tls.Listen("tcp", *listen, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	fmt.Printf("tlsproxy: listening on wss://%s, forwarding to ws://%s, capture in %s\n", *listen, *upstream, *capture)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go proxy(c, *upstream, record)
	}
}

// proxy forwards one connection: HTTP upgrade request and response verbatim,
// then WebSocket frames parsed and re-emitted so their payloads can be
// recorded unmasked.
func proxy(client net.Conn, upstream string, record func(string, byte, []byte)) {
	defer client.Close()
	server, err := net.Dial("tcp", upstream)
	if err != nil {
		log.Printf("dial upstream: %v", err)
		return
	}
	defer server.Close()

	cr := bufio.NewReader(client)
	req, err := http.ReadRequest(cr)
	if err != nil {
		return
	}
	// The intermediary sees the HTTP layer in full: method, path, headers.
	record("client->server", 0, []byte(fmt.Sprintf("HTTP %s %s", req.Method, req.URL.Path)))
	if err := req.Write(server); err != nil {
		return
	}
	sr := bufio.NewReader(server)
	resp, err := http.ReadResponse(sr, req)
	if err != nil {
		return
	}
	if err := resp.Write(client); err != nil {
		return
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		return
	}
	done := make(chan struct{}, 2)
	go func() { relayFrames(cr, server, "client->server", record); done <- struct{}{} }()
	go func() { relayFrames(sr, client, "server->client", record); done <- struct{}{} }()
	<-done
}

// relayFrames parses RFC 6455 frames from src, records the unmasked payload
// and writes the original frame bytes to dst.
func relayFrames(src *bufio.Reader, dst net.Conn, dir string, record func(string, byte, []byte)) {
	for {
		hdr := make([]byte, 2)
		if _, err := io.ReadFull(src, hdr); err != nil {
			return
		}
		raw := append([]byte(nil), hdr...)
		opcode := hdr[0] & 0x0f
		masked := hdr[1]&0x80 != 0
		length := uint64(hdr[1] & 0x7f)
		switch length {
		case 126:
			ext := make([]byte, 2)
			if _, err := io.ReadFull(src, ext); err != nil {
				return
			}
			raw = append(raw, ext...)
			length = uint64(binary.BigEndian.Uint16(ext))
		case 127:
			ext := make([]byte, 8)
			if _, err := io.ReadFull(src, ext); err != nil {
				return
			}
			raw = append(raw, ext...)
			length = binary.BigEndian.Uint64(ext)
		}
		var mask []byte
		if masked {
			mask = make([]byte, 4)
			if _, err := io.ReadFull(src, mask); err != nil {
				return
			}
			raw = append(raw, mask...)
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(src, payload); err != nil {
			return
		}
		raw = append(raw, payload...)
		unmasked := append([]byte(nil), payload...)
		if masked {
			for i := range unmasked {
				unmasked[i] ^= mask[i%4]
			}
		}
		record(dir, opcode, unmasked)
		if _, err := dst.Write(raw); err != nil {
			return
		}
	}
}

func selfSigned(out string) (tls.Certificate, error) {
	// A throwaway CA and a server certificate signed by it, so that clients
	// can trust the CA file the way they would trust a private CA.
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(time.Now().UnixNano()),
		Subject:               pkix.Name{CommonName: "arveil-tlsproxy test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		return tls.Certificate{}, err
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		return tls.Certificate{}, err
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano() + 1),
		Subject:      pkix.Name{CommonName: "arveil-tlsproxy (test only)"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		DNSNames:     []string{"localhost"},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := os.WriteFile(out, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), 0o644); err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{leafDER, caDER}, PrivateKey: leafKey}, nil
}
