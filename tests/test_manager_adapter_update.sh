#!/usr/bin/env bash
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/sing-box.sh
source <(sed -n '/^update_local_manager() {/,/^}/p' "$script")
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
root="$d/root"; manager="$root/usr/local/lib/sing-box-pre/sing-box.sh"
mkdir -p "$(dirname "$manager")"; echo 'old-manager' > "$manager"
cat > "$d/new" <<'NEW'
#!/bin/bash
dispatch_cli_action() {
 :
}
update_shortcut() {
 :
}
menu() {
 :
}
dispatch_cli_action "$1"
NEW
red(){ :; }; green(){ :; }
curl(){ local out=''; while (($#)); do if [[ $1 = -o ]]; then out=$2; shift 2; else shift; fi; done; cp "$d/new" "$out"; }
ensure_warp_adapter(){ printf '%s\n' "$1" > "$d/root-seen"; return 1; }
if update_local_manager "$root"; then exit 1; fi
[[ $(cat "$manager") = old-manager && $(cat "$d/root-seen") = "$root" && ! -e "$manager.previous" ]]
[[ -z $(find "$(dirname "$manager")" -name '.sing-box.sh.new.*' -print -quit) ]]
echo 'Manager update preserves old executable when companion preparation fails.'
