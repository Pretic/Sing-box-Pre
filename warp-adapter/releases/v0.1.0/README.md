# WARP adapter v0.1.0

Prebuilt Linux executables for Sing-box-Pre. The manager downloads only the matching architecture and verifies both archive and executable SHA-256 before installation. No Go toolchain is required on the VPS.

- Source: `../../`, verified by `../../SOURCE-SHA256SUMS`
- Archive checksums: `SHA256SUMS`
- Executable checksums: `SHA256SUMS.ELF`
- Build provenance and architecture limits: `BUILD-MANIFEST.json`
- Redistribution notices: `THIRD-PARTY-NOTICES.md`

Only amd64 has been runtime-tested. Other architectures are reproducible cross-builds with ELF verification. Actual Cloudflare registration and 128 MiB whole-system operation have not been verified.
