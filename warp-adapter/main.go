// WARP registration bridge. No credentials are written to stdout/stderr.
package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"time"
)

const maxBody = 4 << 20

type input struct {
	Key      string `json:"key"`
	TOS      string `json:"tos"`
	DeviceID string `json:"device_id"`
	Token    string `json:"token"`
}
type metadata struct {
	HTTPStatus   int    `json:"http_status"`
	RetryAfter   string `json:"retry_after"`
	RequestState string `json:"request_state"`
	Error        string `json:"error"`
}

// Call performs one request, or a strictly local keypair generation.
// Injected RoundTrippers are used only in tests;
// the executable has no endpoint override or proxy support.
func call(ctx context.Context, rt http.RoundTripper, base, operation string, in input, out *os.File) metadata {
	m := metadata{RequestState: "not_sent"}
	method, path := http.MethodPost, "/"+ApiVersion+"/reg"
	var payload []byte
	switch operation {
	case "keypair":
		key, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			m.Error = "key_generation_failed"
			return m
		}
		// WireGuard exports a clamped Curve25519 scalar. X25519 also clamps
		// internally, but canonicalize the stored private bytes for wg parity.
		private := key.Bytes()
		private[0] &= 248
		private[31] &= 127
		private[31] |= 64
		key, err = ecdh.X25519().NewPrivateKey(private)
		if err != nil {
			m.Error = "key_generation_failed"
			return m
		}
		pair := map[string]string{
			"private_key": base64.StdEncoding.EncodeToString(private),
			"public_key":  base64.StdEncoding.EncodeToString(key.PublicKey().Bytes()),
		}
		if err := json.NewEncoder(out).Encode(pair); err != nil {
			m.Error = "key_persist_failed"
			return m
		}
		if err := out.Sync(); err != nil {
			m.Error = "key_persist_failed"
		}
		return m
	case "register":
		key, err := base64.StdEncoding.DecodeString(in.Key)
		if err != nil || len(key) != 32 {
			m.Error = "invalid_public_key"
			return m
		}
		if _, err := time.Parse(time.RFC3339Nano, in.TOS); err != nil {
			m.Error = "invalid_tos_timestamp"
			return m
		}
		payload, _ = json.Marshal(map[string]string{"key": in.Key, "tos": in.TOS, "fcm_token": "", "install_id": "", "locale": "en_US", "model": "PC", "serial_number": "", "os_version": "16.0.0", "key_type": "curve25519", "tunnel_type": "wireguard"})
	case "delete", "get":
		if !regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`).MatchString(in.DeviceID) || in.Token == "" || len(in.Token) > 4096 || regexp.MustCompile(`[\x00-\x20\x7f]`).MatchString(in.Token) {
			m.Error = "invalid_device_credentials"
			return m
		}
		method = http.MethodDelete
		if operation == "get" {
			method = http.MethodGet
		}
		path += "/" + in.DeviceID
	default:
		m.Error = "invalid_operation"
		return m
	}
	req, err := http.NewRequestWithContext(ctx, method, base+path, bytes.NewReader(payload))
	if err != nil {
		m.Error = "invalid_request"
		return m
	}
	for k, v := range DefaultHeaders {
		req.Header.Set(k, v)
	}
	if operation == "register" {
		req.Header.Set("Content-Type", "application/json")
	} else {
		req.Header.Set("Authorization", "Bearer "+in.Token)
	}
	m.RequestState = "unknown"
	resp, err := (cloudflareResponseTransport{base: rt}).RoundTrip(req)
	if err != nil || resp == nil {
		m.Error = "transport_error"
		return m
	}
	defer resp.Body.Close()
	m.HTTPStatus = resp.StatusCode
	m.RetryAfter = resp.Header.Get("Retry-After")
	if len(m.RetryAfter) > 512 {
		m.RetryAfter = ""
	}
	// Persist raw response immediately, including partial responses useful for
	// manual recovery. Do not make optional follow-up API requests.
	n, readErr := io.Copy(out, io.LimitReader(resp.Body, maxBody+1))
	syncErr := out.Sync()
	if readErr != nil || n > maxBody {
		m.Error = "response_incomplete"
		return m
	}
	if syncErr != nil {
		m.Error = "response_persist_failed"
		return m
	}
	m.RequestState = "response_received"
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		m.Error = "http_error"
	}
	return m
}

// Linux-only bridge: O_NOFOLLOW rejects symlinks; restrictive parent directory
// is mandatory to prevent another user replacing an input/output pathname.
func privateFile(path string, write bool) (*os.File, error) {
	parent, err := os.Stat(filepath.Dir(path))
	if err != nil || !parent.IsDir() || parent.Mode().Perm()&0077 != 0 {
		return nil, errors.New("insecure parent directory")
	}
	flags := syscall.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_NONBLOCK
	if write {
		flags = syscall.O_WRONLY | syscall.O_CREAT | syscall.O_NOFOLLOW | syscall.O_NONBLOCK
	}
	fd, err := syscall.Open(path, flags, 0600)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 {
		f.Close()
		return nil, errors.New("insecure file")
	}
	return f, nil
}
func run(args []string) int {
	if len(args) < 1 {
		return 2
	}
	fs := flag.NewFlagSet("warp-registration-adapter", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	inPath := fs.String("input", "", "private JSON input, or - for stdin")
	outPath := fs.String("response", "", "private raw response path")
	metaPath := fs.String("metadata", "", "private status JSON path")
	if fs.Parse(args[1:]) != nil || fs.NArg() != 0 || *inPath == "" || *outPath == "" || *metaPath == "" {
		return 2
	}
	out, err := privateFile(*outPath, true)
	if err != nil {
		return 2
	}
	defer out.Close()
	meta, err := privateFile(*metaPath, true)
	if err != nil {
		return 2
	}
	defer meta.Close()
	os1, _ := out.Stat()
	ms, _ := meta.Stat()
	if os.SameFile(os1, ms) {
		return 2
	}
	var source io.Reader = os.Stdin
	if *inPath != "-" {
		f, e := privateFile(*inPath, false)
		if e != nil {
			return 2
		}
		defer f.Close()
		is, _ := f.Stat()
		if os.SameFile(is, os1) || os.SameFile(is, ms) {
			return 2
		}
		source = f
	}
	// Refuse nonempty output files rather than destroying earlier recovery data.
	if os1.Size() != 0 || ms.Size() != 0 {
		return 2
	}
	m := metadata{RequestState: "not_sent", Error: "invalid_input"}
	data, err := io.ReadAll(io.LimitReader(source, 65537))
	var in input
	if err == nil && len(data) <= 65536 && json.Unmarshal(data, &in) == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		m = call(ctx, DefaultTransport, ApiUrl, args[0], in, out)
	}
	if json.NewEncoder(meta).Encode(m) != nil || meta.Sync() != nil {
		return 2
	}
	if m.Error != "" {
		return 1
	}
	return 0
}
func main() {
	code := run(os.Args[1:])
	if code == 2 {
		fmt.Fprintln(os.Stderr, "adapter local I/O or arguments failed; retain recovery files")
	}
	os.Exit(code)
}
