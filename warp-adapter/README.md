# WARP registration transport adapter (Linux)

The shell installs the matching prebuilt adapter during fresh installation,
updates, or first WARP use. Downloads use a versioned GitHub Release in
`Pretic/Sing-box-Pre`; compressed and executable SHA-256 checksums plus ELF
architecture checks must pass before atomic installation. Unmanaged existing
binaries are not silently overwritten. **No Go installation or compilation is
needed on the VPS**, and the helper adds no resident service.

`keypair` runs entirely locally. Registration changes a Cloudflare account and
requires the user's authorization and applicable terms acceptance. A successful
build or registration does not guarantee a different public exit IPv4.

## Provenance

TLS ClientHello implementation adapted from ViRb3/wgcf v2.3.0 commit
`ace873cbaa618365beebde5790a7fb3481e5a211`, `cloudflare/api.go`:
https://github.com/ViRb3/wgcf/blob/ace873cbaa618365beebde5790a7fb3481e5a211/cloudflare/api.go

Its MIT notice is in `LICENSE.wgcf`. The snapshot is included as
`upstream-api.go.txt` for comparison; `transport.go` is its transport-only prefix,
with package/import simplification and standard `fmt.Errorf` instead of the
upstream errors package. The generated API schema confirmed POST
`/v0a5641/reg` and DELETE/GET `/v0a5641/reg/{sourceDeviceId}`. The payload follows
upstream `registrationRequest`. This is a pinned reviewed snapshot, not a promise
that the unsupported third-party Cloudflare API will remain compatible.

uTLS is pinned to v1.8.2 with checksums and explicit transitive pins. Its actual
custom Android TLS fingerprint is used, not merely curl headers. TLS verifies
public CA certificates and hostnames, uses TLS 1.2 and HTTP/1.1, and ignores
HTTP(S)_PROXY (upstream explains CONNECT bypasses the custom handshake).

## Optional developer build

Build on a development machine, not a low-memory VPS. Use verified official Go
from https://go.dev/dl/ (Go 1.24.13 reproduces the published builds):

    GOTOOLCHAIN=local go mod download
    GOTOOLCHAIN=local go test ./...
    GOTOOLCHAIN=local go vet ./...
    GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -mod=readonly -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o warp-registration-adapter .

For a custom build, install it explicitly or set `SB_WARP_ADAPTER` to its absolute
path. The shell leaves that custom path under your control. Cross-compile with
`GOOS=linux` and the destination's `GOARCH`; ARMv7 additionally uses `GOARM=7`.
Keep the toolchain/cache off the target VPS. Redistribute THIRD-PARTY-NOTICES.md
with executable releases.

## Shell interface

    warp-registration-adapter keypair --input empty-object.json --response keys.json --metadata status.json
    warp-registration-adapter register --input request.json --response raw.json --metadata status.json
    warp-registration-adapter delete --input credentials.json --response raw.json --metadata status.json
    warp-registration-adapter get --input credentials.json --response raw.json --metadata status.json

All files must be regular, nonsymlink files with no group/other permissions in
private directories (0700). Output files may be absent or existing empty 0600
files; nonempty files are refused to avoid overwriting recovery evidence. The
three paths must identify different files. `--input -` accepts JSON from stdin.
No credentials, public keys, tokens, bodies or device IDs are command-line flags.
Never put file contents in logs or enable shell tracing around credential work.

Keypair input: `{}`. Response: `{"private_key":"base64 32-byte scalar","public_key":"base64 32-byte X25519 public key"}`.
The private scalar is WireGuard-clamped; `crypto/rand` provides randomness and
`crypto/ecdh.X25519` derives the corresponding public key. Output is fsynced
before metadata. No HTTP request is made. Success metadata has `http_status:0`,
`request_state:"not_sent"`, `error:""`; exit status is 0. Private keys never go
to stdout/stderr. Persist the key file before submitting registration.

Register input: `{"key":"base64-encoded 32-byte public key","tos":"RFC3339 timestamp"}`.
Extra input properties are accepted but not forwarded. The shell must persist
its private key before registering; the API cannot return a missing private key.
Delete/get input: `{"device_id":"registered ID","token":"registration token"}`.

`raw.json` is the **unchanged** API body, including all response fields (device ID,
token, client_id, interface addresses, peer public keys, endpoints and ports),
without reducing the schema. It is persisted and fsynced before metadata. There
is no optional follow-up request, so follow-up failure cannot lose registration
credentials. API JSON is not guaranteed complete or valid; the caller must
validate the complete fields before switching configuration. Partial bodies are
also retained for recovery. Keep input/private key, raw response and metadata
until cleanup is confirmed. This cannot eliminate orphan accounts when a server
accepts POST but its response is lost.

Metadata: `{"http_status":200,"retry_after":"","request_state":"response_received","error":""}`.
`request_state` is `not_sent`, `unknown`, or `response_received`. Transport errors
and truncated/oversized/unpersisted bodies are `unknown`; never automatically
repeat registration on them. 429 preserves Retry-After (seconds or HTTP-date) for
the caller. Definitive HTTP error responses have `error:"http_error"`. Transport
errors are sanitized to `transport_error`; response-read errors are
`response_incomplete`. HTTP redirects are returned as errors, never followed.

For register/get/delete, exit 0 means a fully persisted 2xx response, not a
validated working WARP tunnel. For keypair, it means locally generated keys were
fully persisted.
Exit 1 means inspect metadata. Exit 2 is local I/O/argument failure; metadata may
be absent, so the caller must treat missing metadata conservatively. No sensitive
stdout/stderr is emitted. API commands make one request (keypair makes none),
with no application retries and a 45-second network context
bound, 64 KiB input cap and 4 MiB response cap. Tests inject transports or use
localhost httptest servers; no test sends data to Cloudflare.


## Reproducible v5 release builds

Go 1.24.13, pinned go.mod/go.sum, CGO_ENABLED=0, GOOS=linux, and GOARCH=amd64
or arm64 were used with `-mod=readonly -trimpath -buildvcs=false` and
`-ldflags="-s -w -buildid="`. Defaults are GOAMD64=v1 and GOARM64=v8.0.
Each architecture was built twice and compared byte-for-byte. These stripped
binaries are architecture-specific; arm64 was cross-compiled, not executed here.
See RELEASE-BUILD.md for exact checksums, sizes, and reproduction commands.
Redistribute THIRD-PARTY-NOTICES.md alongside executable releases.
