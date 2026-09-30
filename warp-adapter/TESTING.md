# Verification — 2026-09-30 UTC

Build environment: Linux amd64, workspace-local official Go 1.24.13. Official
`go1.24.13.linux-amd64.tar.gz` SHA-256 checked before extracting/executing:
`1fc94b57134d51669c72173ad5d49fd62afb0f1db9bf3f798fd98ee423f8d730`.
Metadata source: https://go.dev/dl/?mode=json&include=all
Archive source: https://dl.google.com/go/go1.24.13.linux-amd64.tar.gz

Passed:
- `go mod verify` (all modules verified)
- `go test -count=1 -v ./...` (11 top-level tests, including local keypair)
- `go test -count=10 ./...`
- `go test -race -count=1 ./...`
- `go vet ./...`
- `CGO_ENABLED=0 go build -trimpath -o .build/warp-registration-adapter .`
- Independent reviewer: `go test` and `go vet`, `GOPROXY=off`, `GOSUMDB=off`,
  `-mod=readonly`, using the already verified toolchain/cache

Tests include complete raw registration response persistence, exact API path and
headers, current payload fields, 204 success and 301/401/403/429/500 statuses,
Retry-After preservation, ambiguous POST errors without retries, partial response
recovery, context cancellation, invalid input before network access, file modes,
symlink rejection, nonempty recovery-file protection, local keypair lengths,
public/private relation and canonical WireGuard clamping, zero network calls,
key uniqueness, private keypair output and no-overwrite safety, pinned ClientHello shape,
and real localhost TLS handshake with trusted, wrong-host and untrusted CA cases.
TLS tests isolate the session cache when changing test trust roots.

Not tested or performed: live Cloudflare registration/get/delete, cloud account
changes, live WARP tunnel establishment, actual public IPv4 change, or installation
on the user's VPS. Builds/tests cannot guarantee Cloudflare currently accepts
registration or assigns a different egress address. The shell must validate a
changed public IPv4 and preserve rollback/recovery when it does not change.

The `.build/` toolchain, module cache, and compiled binary are local verification
artifacts only. Exclude the toolchain/cache/intermediate builds from delivered
ZIPs and source commits; only the separately checked release binaries explicitly
listed in RELEASE-BUILD.md may be included in the executable release.
The source manifest `SOURCE-SHA256SUMS` excludes itself and `.build/`.

The v5 local keypair operation passed all tests, ten repeated test runs, vet,
and the race detector. Two stripped release builds per architecture matched
byte-for-byte. Executable measurements are reported separately; arm64 execution
was not tested. The x/crypto Curve25519 compatibility check wraps crypto/ecdh
and is not an independent cryptographic implementation.
