#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for n in warp_adapter_release_spec validate_warp_adapter_elf; do source <(sed -n "/^$n() {/,/^}/p" "$root/sing-box.sh"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
release="$root/warp-adapter/releases/v0.1.0"
for arch in amd64 arm64 386 armv7 s390x; do
 spec=$(warp_adapter_release_spec "$arch")
 read -r url gzsha binsha <<< "$spec"
 name="warp-registration-adapter-linux-$arch"
 [[ $url = "https://github.com/Pretic/Sing-box-Pre/releases/download/warp-adapter-v0.1.0/$name.gz" ]]
 grep -Fxq "$gzsha  $name.gz" "$release/SHA256SUMS"
 grep -Fxq "$binsha  $name" "$release/SHA256SUMS.ELF"
 # Clean checkouts carry manifests; local release builders can additionally
 # validate their artifacts without making CI download or execute binaries.
 if [[ -f "$release/$name.gz" ]]; then
   [[ $(sha256sum "$release/$name.gz") = "$gzsha "* ]]
   gzip -dc "$release/$name.gz" > "$d/$arch"
   [[ $(sha256sum "$d/$arch") = "$binsha "* ]]
   validate_warp_adapter_elf "$d/$arch" "$arch"
 fi
done
if warp_adapter_release_spec unsupported >/dev/null; then exit 1; fi
echo 'Versioned release URLs match all five checked-in archive and ELF digests.'
