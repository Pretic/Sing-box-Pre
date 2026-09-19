#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for f in run_cfy manage_cfy; do source <(sed -n "/^${f}() {/,/^}/p" "$repo/sing-box.sh"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
touch "$d/cfy"
cfy_executable_path() { printf '%s\n' "$d/cfy"; }
validate_cfy_target_path() { [[ "$1" == "$d/cfy" ]]; }
run_cfy_existing() { printf '%s\n' "$*" > "$d/arguments"; }
install_cfy() { echo 'unexpected install' >&2; exit 99; }
run_cfy --manual
[[ $(cat "$d/arguments") == --manual ]]
clear() { :; }
green() { printf '%s\n' "$1"; }
purple() { printf '%s\n' "$1"; }
yellow() { printf '%s\n' "$1"; }
red() { printf '%s\n' "$1"; }
reading() { IFS= read -r "$2"; }
printf '5\n\n4\n' > "$d/choices"
manage_cfy < "$d/choices" > "$d/menu"
grep -q '5. 手动粘贴节点优选' "$d/menu"
[[ $(cat "$d/arguments") == --manual ]]
echo 'sb manual cfy entry, argument forwarding and return path tests passed.'
