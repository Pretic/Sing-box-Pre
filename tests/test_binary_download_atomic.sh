#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^download_binary() {/,/^}/p' "$script")
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
red() { :; }
curl() { local dest=''; while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then dest="$2"; break; fi; shift; done; cp "$d/input" "$dest"; return "${CURL_RC:-0}"; }
printf old > "$d/target"
for fixture in '' '<html>Error</html>' $'\177ELF'; do
    printf %s "$fixture" > "$d/input"
    if download_binary https://example.test/asset "$d/target"; then exit 1; fi
    [[ "$(cat "$d/target")" == old ]]
done
{ printf '\177ELF'; printf '%080d' 0; } > "$d/input"
sha=$(sha256sum "$d/input"); sha=${sha%% *}
CURL_RC=1
if download_binary https://example.test/asset "$d/target"; then exit 1; fi
[[ "$(cat "$d/target")" == old ]]
CURL_RC=0
if download_binary https://example.test/asset "$d/target" "${sha/a/b}BAD"; then exit 1; fi
[[ "$(cat "$d/target")" == old ]]
if download_binary http://example.test/asset "$d/target"; then exit 1; fi
download_binary https://example.test/asset "$d/target" "$sha"
cmp "$d/input" "$d/target"
[[ "$(stat -c %a "$d/target")" == 755 ]]
ln -s "$d/target" "$d/link"
if download_binary https://example.test/asset "$d/link"; then exit 1; fi
[[ "$(find "$d" -name '.binary-download.*' | wc -l)" == 0 ]]
echo 'Atomic ELF download and optional digest tests passed.'
