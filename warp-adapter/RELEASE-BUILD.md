# v5 adapter release build

Source: this directory, Go 1.24.13 (official archive checksum in TESTING.md).
No registration, get, delete, or live account changes were performed.
Builds used the already checksum-verified local module cache with GOPROXY=off,
GOSUMDB=off, GOTOOLCHAIN=local, and -mod=readonly.

Reproduction commands from the source directory, using an installed Go 1.24.13:

    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 GOTOOLCHAIN=local go build -mod=readonly -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o warp-registration-adapter-linux-amd64 .
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOARM64=v8.0 GOTOOLCHAIN=local go build -mod=readonly -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o warp-registration-adapter-linux-arm64 .

Both architectures were built twice and the pairs compared byte-for-byte.

| File | Bytes | SHA-256 |
|---|---:|---|
| warp-registration-adapter-linux-amd64 | 7,577,748 | 622f2766917cd2dcdc22a789a8ec232e6f2150eee2daf18f5c10d96f5363d9c2 |
| warp-registration-adapter-linux-arm64 | 7,143,572 | ca7f6924a460a5d210bb0108cef339dad7fa90604b1a8ffb59a63070210fded5 |

These are stripped static Linux executables; they do not need Go or the source
on the target VPS. amd64 tests ran locally; arm64 was cross-built and ELF checked
but was not executed. System trusted CA certificates are still needed for API
requests. Local keypair generation does not need CA certificates or networking.

Ship THIRD-PARTY-NOTICES.md alongside redistributed binaries. Do not redistribute
`.build/go`, module caches, test binaries, or redundant rebuild copies. Only the
exact checked release binary for the user's architecture needs installation.
