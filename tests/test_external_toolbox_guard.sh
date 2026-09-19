#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^launch_external_toolbox() {/,/^}/p' "$script")
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
yellow() { :; }; red() { :; }
reading() { printf -v "$2" '%s' "${ANSWER:-n}"; }
curl() { echo called >> "$d/curl"; local dest=''; while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then dest="$2"; break; fi; shift; done; printf '#!/bin/bash\necho should-not-execute > "%s/executed"\n' "$d" > "$dest"; return 0; }
launch_external_toolbox
[[ ! -e "$d/curl" ]]
ANSWER=y
if launch_external_toolbox; then exit 1; fi
[[ -e "$d/curl" && ! -e "$d/executed" ]]
echo 'External toolbox opt-in and checksum guard tests passed.'
