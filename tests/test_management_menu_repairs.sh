#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for name in red green yellow purple skyblue menu set_global_outbound manage_argo; do
    source <(sed -n "/^${name}() {/,/^}/p" "$script")
done
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
purple=''; green=''; red=''; skyblue=''; yellow=''; re=''
failed=0
fail() { echo "FAIL: $*" >&2; failed=$((failed+1)); }
clear() { :; }; sleep() { :; }
check_singbox() { echo running; }; check_argo() { echo running; }; check_nginx() { echo running; }
get_warp_menu_status() { echo running; }
line=$(menu | grep 'WARP 状态:')
[[ "$line" == *$'\033[1;32mrunning'* ]] || fail 'WARP running is not green'

outbound_file="$tmp/outbounds.json"
printf '{"outbounds":[{"type":"direct","tag":"direct"}]}\n' > "$outbound_file"
ensure_warp_prerequisites() { return 0; }
reading() { printf -v "$2" '%s' "$answer"; }
add_rule_menu() { :; }; warp_manage() { :; }
selected=''; set_global_route() { selected=$1; }
answer=1
set_global_outbound >/dev/null
[[ "$selected" == wireguard-out ]] || fail 'global menu omitted built-in WARP'

menu() { :; }
answer=3; restarted=0
detect_argo_tunnel_mode() { echo fixed; }
restart_argo() { restarted=$((restarted+1)); }
manage_argo "$tmp/argo.service" <<< '' >/dev/null || true
[[ "$restarted" == 1 ]] || fail 'fixed Argo restart did not restart the service'
# The subscription function already pauses. Its main-loop caller must not pause again.
grep -Eq '7\) *disable_open_sub; *need_pause=false' "$script" || fail 'subscription main loop pauses a second time'
[[ "$failed" == 0 ]] || exit 1
echo 'Management menu repair tests passed.'
