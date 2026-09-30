package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	utls "github.com/refraction-networking/utls"
	"golang.org/x/crypto/curve25519"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func output(t *testing.T) *os.File {
	t.Helper()
	f, e := os.CreateTemp(t.TempDir(), "response-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { f.Close() })
	return f
}
func validInput() input {
	return input{Key: base64.StdEncoding.EncodeToString(make([]byte, 32)), TOS: "2026-09-30T00:00:00Z", DeviceID: "fixture-device", Token: "fixture-token"}
}
func TestRegisterPreservesRawCompleteResponse(t *testing.T) {
	raw := `{"id":"fixture-device","token":"fixture-token","client_id":"AQID","config":{"interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700::1"}},"peers":[{"public_key":"fixture-key","endpoint":{"v4":"162.159.192.1","ports":[2408]}}]}}`
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != "POST" || r.URL.Path != "/v0a5641/reg" {
			t.Error("wrong request")
		}
		if r.Header.Get("Content-Type") != "application/json; charset=UTF-8" || r.Header.Get("CF-Client-Version") != "a-6.38.9-5641" || r.Header.Get("Accept") != "" {
			t.Error("wrong headers")
		}
		var p map[string]string
		json.NewDecoder(r.Body).Decode(&p)
		if p["tunnel_type"] != "wireguard" || p["os_version"] != "16.0.0" || p["key"] != validInput().Key {
			t.Error("wrong payload")
		}
		w.WriteHeader(201)
		io.WriteString(w, raw)
	}))
	defer srv.Close()
	f := output(t)
	m := call(context.Background(), srv.Client().Transport, srv.URL, "register", validInput(), f)
	got, _ := os.ReadFile(f.Name())
	if string(got) != raw || m.HTTPStatus != 201 || m.Error != "" || m.RequestState != "response_received" || calls != 1 {
		t.Fatalf("incorrect result: %+v calls=%d", m, calls)
	}
}
func TestHTTPStatusesAndDelete(t *testing.T) {
	for _, status := range []int{204, 301, 401, 403, 429, 500} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			calls := 0
			rt := roundTripFunc(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Method != "DELETE" || r.URL.Path != "/v0a5641/reg/fixture-device" || r.Header.Get("Authorization") != "Bearer fixture-token" {
					t.Error("wrong delete")
				}
				return &http.Response{StatusCode: status, Header: http.Header{"Retry-After": []string{"120"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
			})
			m := call(context.Background(), rt, "https://example.invalid", "delete", validInput(), output(t))
			if m.HTTPStatus != status || m.RetryAfter != "120" || m.RequestState != "response_received" || calls != 1 {
				t.Fatal(m)
			}
			if (m.Error == "") != (status == 204) {
				t.Fatal(m)
			}
		})
	}
}
func TestAmbiguousTransportNeverRetries(t *testing.T) {
	calls := 0
	m := call(context.Background(), roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls++
		return nil, errors.New("sensitive server detail")
	}), "https://example.invalid", "register", validInput(), output(t))
	if calls != 1 || m.Error != "transport_error" || m.RequestState != "unknown" {
		t.Fatal(m)
	}
}

type brokenBody struct{}

func (brokenBody) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }
func (brokenBody) Close() error             { return nil }
func TestPartialResponseIsAmbiguous(t *testing.T) {
	f := output(t)
	m := call(context.Background(), roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{}, Body: struct {
			io.Reader
			io.Closer
		}{io.MultiReader(strings.NewReader(`{"id":"recover-me",`), brokenBody{}), io.NopCloser(strings.NewReader(""))}}, nil
	}), "https://example.invalid", "register", validInput(), f)
	got, _ := os.ReadFile(f.Name())
	if m.RequestState != "unknown" || m.Error != "response_incomplete" || !strings.Contains(string(got), "recover-me") {
		t.Fatal(m)
	}
}
func TestCancellation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond)
	defer cancel()
	m := call(ctx, roundTripFunc(func(r *http.Request) (*http.Response, error) { <-r.Context().Done(); return nil, r.Context().Err() }), "https://example.invalid", "register", validInput(), output(t))
	if m.RequestState != "unknown" {
		t.Fatal(m)
	}
}
func TestInvalidInputNeverSent(t *testing.T) {
	m := call(context.Background(), roundTripFunc(func(*http.Request) (*http.Response, error) { t.Fatal("network called"); return nil, nil }), "https://example.invalid", "register", input{}, output(t))
	if m.RequestState != "not_sent" {
		t.Fatal(m)
	}
}
func TestCLIFileSafety(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	in := filepath.Join(dir, "in")
	out := filepath.Join(dir, "out")
	meta := filepath.Join(dir, "meta")
	os.WriteFile(in, []byte(`{}`), 0600)
	if run([]string{"register", "--input", in, "--response", out, "--metadata", meta}) != 1 {
		t.Fatal("invalid input exit")
	}
	b, _ := os.ReadFile(meta)
	if !strings.Contains(string(b), `"request_state":"not_sent"`) {
		t.Fatal(string(b))
	}
	for _, p := range []string{out, meta} {
		s, _ := os.Stat(p)
		if s.Mode().Perm() != 0600 {
			t.Fatal("bad permissions")
		}
	}
	if run([]string{"register", "--input", in, "--response", out, "--metadata", meta}) != 2 {
		t.Fatal("overwrote old metadata")
	}
	link := filepath.Join(dir, "link")
	os.Symlink(in, link)
	if f, e := privateFile(link, false); e == nil {
		f.Close()
		t.Fatal("accepted symlink")
	}
	os.Chmod(in, 0644)
	if f, e := privateFile(in, false); e == nil {
		f.Close()
		t.Fatal("accepted public input")
	}
}
func TestTransportFingerprint(t *testing.T) {
	s := warpClientHelloSpec()
	if s.TLSVersMin != 0x0303 || s.TLSVersMax != 0x0303 || len(s.CipherSuites) != 2 || len(s.Extensions) != 10 {
		t.Fatal("unexpected pinned fingerprint")
	}
	if DefaultTransport.Proxy != nil || DefaultTransport.ForceAttemptHTTP2 || warpTLSConfig.InsecureSkipVerify {
		t.Fatal("unsafe transport")
	}
}

func TestPinnedTLSHandshakeAndCertificateVerification(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	srv.Config.ErrorLog = log.New(io.Discard, "", 0)
	roots := x509.NewCertPool()
	roots.AddCert(srv.Certificate())
	for _, tc := range []struct {
		name    string
		roots   *x509.CertPool
		host    string
		success bool
	}{{"trusted", roots, "example.com", true}, {"wrong-host", roots, "invalid.example", false}, {"untrusted", x509.NewCertPool(), "example.com", false}} {
		t.Run(tc.name, func(t *testing.T) {
			warpSessionCache = utls.NewLRUClientSessionCache(64) // Isolate trust roots and fresh handshakes.
			raw, err := net.Dial("tcp", srv.Listener.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			defer raw.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			conn, err := handshakeWarpTLS(ctx, raw, tc.host, &tls.Config{RootCAs: tc.roots})
			if (err == nil) != tc.success {
				t.Fatalf("unexpected handshake result: %v", err)
			}
			if err == nil {
				defer conn.Close()
				if conn.ConnectionState().Version != tls.VersionTLS12 {
					t.Fatal("wrong TLS version")
				}
			}
		})
	}
}

func checkPair(t *testing.T, path string) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var pair map[string]string
	if err = json.Unmarshal(raw, &pair); err != nil {
		t.Fatal(err)
	}
	private, err := base64.StdEncoding.DecodeString(pair["private_key"])
	if err != nil || len(private) != 32 {
		t.Fatal("invalid private key encoding")
	}
	public, err := base64.StdEncoding.DecodeString(pair["public_key"])
	if err != nil || len(public) != 32 {
		t.Fatal("invalid public key encoding")
	}
	if private[0]&7 != 0 || private[31]&128 != 0 || private[31]&64 == 0 {
		t.Fatal("noncanonical WireGuard scalar")
	}
	key, err := ecdh.X25519().NewPrivateKey(private)
	if err != nil || !bytes.Equal(key.PublicKey().Bytes(), public) {
		t.Fatal("key relation mismatch")
	}
	// Verify the pinned x/crypto compatibility API too (it wraps crypto/ecdh).
	derived, err := curve25519.X25519(private, curve25519.Basepoint)
	if err != nil || !bytes.Equal(derived, public) {
		t.Fatal("WireGuard public key mismatch")
	}
	return pair
}
func TestLocalKeypairNeverUsesTransport(t *testing.T) {
	rt := roundTripFunc(func(*http.Request) (*http.Response, error) { t.Fatal("keypair contacted network"); return nil, nil })
	f := output(t)
	m := call(context.Background(), rt, "invalid network URL", "keypair", input{}, f)
	if m.Error != "" || m.RequestState != "not_sent" || m.HTTPStatus != 0 {
		t.Fatal(m)
	}
	first := checkPair(t, f.Name())
	next := output(t)
	m = call(context.Background(), rt, "invalid network URL", "keypair", input{}, next)
	if m.Error != "" {
		t.Fatal(m)
	}
	second := checkPair(t, next.Name())
	if first["private_key"] == second["private_key"] {
		t.Fatal("reused key")
	}
}
func TestKeypairCLIPrivateOutputAndSafety(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	in, out, meta := filepath.Join(dir, "in"), filepath.Join(dir, "keys"), filepath.Join(dir, "meta")
	if err := os.WriteFile(in, []byte(`{}`), 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"keypair", "--input", in, "--response", out, "--metadata", meta}
	if code := run(args); code != 0 {
		t.Fatalf("keypair exit%d", code)
	}
	checkPair(t, out)
	before, _ := os.ReadFile(out)
	for _, p := range []string{out, meta} {
		st, err := os.Stat(p)
		if err != nil || st.Mode().Perm() != 0600 {
			t.Fatal("unsafe output permissions")
		}
	}
	raw, _ := os.ReadFile(meta)
	var m metadata
	if json.Unmarshal(raw, &m) != nil || m.RequestState != "not_sent" || m.HTTPStatus != 0 || m.Error != "" {
		t.Fatal("wrong keypair metadata")
	}
	if run(args) != 2 {
		t.Fatal("overwrote existing keypair")
	}
	after, _ := os.ReadFile(out)
	if !bytes.Equal(before, after) {
		t.Fatal("old keypair modified")
	}
	os.Remove(meta)
	os.Remove(out)
	os.Symlink(in, out)
	if run(args) != 2 {
		t.Fatal("followed output symlink")
	}
	os.Remove(out)
	os.Chmod(dir, 0755)
	if run(args) != 2 {
		t.Fatal("accepted public output directory")
	}
}
