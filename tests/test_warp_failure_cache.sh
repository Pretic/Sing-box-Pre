#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^get_warp_menu_status() {/,/^}/p' "$script")
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d/conf"; mkdir -p "$conf_dir/warp"
extract_warp_endpoint() { printf '{}\n'; }
warp_endpoint_is_valid() { return "${INVALID_RC:-0}"; }
singbox_service_is_active() { return "${SERVICE_RC:-0}"; }
probe_active_warp() { touch "$d/unexpected"; return 1; }
start_warp_candidate_proxy() { touch "$d/unexpected"; return 1; }
printf '{"route":{"final":"direct","rules":[]}}' > "$conf_dir/route.json"
[[ "$(get_warp_menu_status)" == disabled ]]
printf '{"route":{"final":"wireguard-out","rules":[]}}' > "$conf_dir/route.json"
[[ "$(get_warp_menu_status)" == enabled ]]
# Stale, malformed and failed caches cannot override actual enablement.
for c in 'invalid' '{"warp":"failed","checked_at":0}' '{"warp":"on","checked_at":9999999999}'; do
 printf '%s' "$c" > "$conf_dir/warp/status.json"
 [[ "$(get_warp_menu_status)" == enabled ]]
done
SERVICE_RC=1; [[ "$(get_warp_menu_status)" == stopped ]]; SERVICE_RC=0
INVALID_RC=1; [[ "$(get_warp_menu_status)" == invalid ]]; INVALID_RC=0
printf 'invalid' > "$conf_dir/route.json"; [[ "$(get_warp_menu_status)" == invalid ]]
extract_warp_endpoint() { :; }; [[ "$(get_warp_menu_status)" == 'not configured' ]]
[[ ! -e "$d/unexpected" ]]
echo 'WARP routing enablement and passive menu tests passed.'
