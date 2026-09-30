# Additional architecture build provenance

Source remained frozen, verified against SOURCE-SHA256SUMS:
66497e773eb03fa40f3ad7a1c7018495c67e0d7549e844a3c33cce7701f91ad5.

Official checksum-verified Go 1.24.13 and cached pinned modules only.
GOTOOLCHAIN=local, GOPROXY=off, GOSUMDB=off; no module network activity.
CGO_ENABLED=0, GOOS=linux, -mod=readonly -trimpath -buildvcs=false
-ldflags="-s -w -buildid=" for all builds. Additional targets:

- linux-386: GOARCH=386, default GO386=sse2
- linux-armv7: GOARCH=arm, GOARM=7
- linux-s390x: GOARCH=s390x

Each target built twice; byte comparisons matched. file verified all are static,
stripped ELF executables with expected machine/endianness. See BUILD-MANIFEST.json
for exact sizes, SHA-256 values, machine identities and architecture settings.
SHA256SUMS contains the five uncompressed executable checksums. Recompressing
for delivery requires a separate compressed-asset checksum manifest.

Only amd64 was executed. The 386 test executable compiled, but this host rejected
execution with "exec format error", so 386 runtime validation is unavailable.
armv7, arm64 and s390x are cross-builds without matching-host runtime tests.
No live Cloudflare actions or installation occurred. Include the existing
THIRD-PARTY-NOTICES.md beside redistributed binaries. User machines require the
matching architecture; no Go compiler or source compilation on the VPS is needed.
