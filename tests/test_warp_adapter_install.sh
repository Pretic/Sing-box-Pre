#!/usr/bin/env bash
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/sing-box.sh
for n in warp_adapter_arch validate_warp_adapter_elf ensure_warp_adapter; do source <(sed -n "/^$n() {/,/^}/p" "$script"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
red(){ :; }; green(){ :; }; warp_adapter_arch(){ echo amd64; }
root="$d/root"; target="$root/usr/local/lib/sing-box-pre/warp-registration-adapter"
python3 - "$d/source" <<'PY'
import sys
b=bytearray(64);b[:7]=b'\x7fELF\x02\x01\x01';b[16]=2;b[18]=62
open(sys.argv[1],'wb').write(b+b'fixture-only-never-executed')
PY
gzip -n -c "$d/source" > "$d/source.gz"
refresh_spec(){ gzsha=$(sha256sum "$d/source.gz");gzsha=${gzsha%% *};binsha=$(sha256sum "$d/source");binsha=${binsha%% *}; }
refresh_spec
warp_adapter_release_spec(){ printf 'https://example.invalid/immutable/adapter.gz %s %s\n' "$gzsha" "$binsha"; }
curl(){
 echo called >> "$d/downloads"
 local out=''
 while (($#)); do if [[ $1 = -o ]]; then out=$2; shift 2; else shift; fi; done
 [[ ${CANCEL_DOWNLOAD:-0} != 1 ]] || { kill -TERM "$BASHPID"; return 143; }
 [[ ${FAIL_DOWNLOAD:-0} != 1 ]] || return 22
 if [[ ${BAD_BODY:-0} = 1 ]]; then echo '<html>error</html>' > "$out"; else cp "$d/source.gz" "$out"; fi
}
ensure_warp_adapter "$root"
cmp "$d/source" "$target"; [[ $(stat -c %a "$target") = 755 && $(stat -c %a "$target.sha256") = 600 ]]
[[ $(cat "$target.sha256") = "$binsha" ]]
ensure_warp_adapter "$root"; [[ $(wc -l < "$d/downloads") = 1 ]]
# Approved current binary can be adopted without a download.
rm "$target.sha256"; ensure_warp_adapter "$root"; [[ $(cat "$target.sha256") = "$binsha" ]]
oldsha=$binsha
printf changed >> "$d/source"; gzip -n -c "$d/source" > "$d/source.gz"; refresh_spec
CANCEL_DOWNLOAD=1; rc=0; ensure_warp_adapter "$root" || rc=$?; unset CANCEL_DOWNLOAD
[[ $rc = 143 && $(sha256sum "$target") = "$oldsha "* ]]
FAIL_DOWNLOAD=1; if ensure_warp_adapter "$root"; then exit 1; fi; unset FAIL_DOWNLOAD
[[ $(sha256sum "$target") = "$oldsha "* ]]
BAD_BODY=1; if ensure_warp_adapter "$root"; then exit 1; fi; unset BAD_BODY
[[ $(sha256sum "$target") = "$oldsha "* ]]
# Rename failure leaves the old executable and its ownership marker untouched.
mv(){ if [[ ${FAIL_RENAME:-0} = 1 && ${*: -1} = "$target" ]]; then return 1; fi; command mv "$@"; }
FAIL_RENAME=1; if ensure_warp_adapter "$root"; then exit 1; fi; unset FAIL_RENAME
[[ $(sha256sum "$target") = "$oldsha "* && $(cat "$target.sha256") = "$oldsha" ]]
ensure_warp_adapter "$root"; cmp "$d/source" "$target"
# Wrong-architecture bytes are refused even if the supplied fixture digest matches.
printf '\267\000' | dd of="$d/source" bs=1 seek=18 conv=notrunc status=none
gzip -n -c "$d/source" > "$d/source.gz"; refresh_spec
if ensure_warp_adapter "$root"; then exit 1; fi
[[ $(cat "$target.sha256") != "$binsha" ]]
# An unknown file, a symlink, or a custom override never gets overwritten.
echo custom > "$target"; rm "$target.sha256"
sha256sum(){ [[ ${HASH_FAILURE:-0} != 1 ]] || return 1; command sha256sum "$@"; }
HASH_FAILURE=1; if ensure_warp_adapter "$root"; then exit 1; fi; unset HASH_FAILURE
[[ $(cat "$target") = custom ]]
if ensure_warp_adapter "$root"; then exit 1; fi; [[ $(cat "$target") = custom ]]
rm "$target"; echo outside > "$d/outside"; ln -s "$d/outside" "$target"
if ensure_warp_adapter "$root"; then exit 1; fi; [[ $(cat "$d/outside") = outside ]]
printf '#!/bin/sh\nexit 1\n' > "$d/custom"; chmod 700 "$d/custom"
SB_WARP_ADAPTER="$d/custom" ensure_warp_adapter "$root"
[[ -L $target ]]
[[ -z $(find "$root/usr/local/lib/sing-box-pre" -maxdepth 1 -type d -name '.warp-adapter-stage.*' -print -quit) ]]
echo 'Adapter download/install checksum, architecture, atomicity, custom ownership and cleanup tests passed.'
