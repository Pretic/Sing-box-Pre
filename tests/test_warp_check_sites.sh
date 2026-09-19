#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in render_warp_check_sites render_warp_route_family set_warp_check_sites; do
    source <(sed -n "/^${f}() {/,/^}/p" "$script")
done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d/conf"; mkdir -p "$conf_dir"
cat > "$d/original" <<'JSON'
{"route":{"final":"direct","rule_set":[{"tag":"custom","type":"inline","rules":[{"domain":["example.test"]}]}],"rules":[{"action":"sniff"},{"rule_set":["custom"],"action":"route","outbound":"direct"}]}}
JSON
render_warp_check_sites "$d/original" on > "$d/enabled"
render_warp_route_family "$d/enabled" "$d/rendered" 6
jq -e '.route.final == "direct" and (.route.rule_set|length)==2 and any(.route.rules[]; .action=="resolve" and .rule_set==["prenet-ip-check"] and .strategy=="prefer_ipv6") and any(.route.rules[]; .outbound=="direct" and .rule_set==["custom"])' "$d/rendered" >/dev/null
render_warp_check_sites "$d/rendered" on > "$d/enabled2"
render_warp_route_family "$d/enabled2" "$d/rendered2" 6
cmp "$d/rendered" "$d/rendered2"
render_warp_check_sites "$d/rendered" off > "$d/off"
render_warp_route_family "$d/off" "$d/disabled" 4
jq -S . "$d/original" > "$d/normalized"
cmp "$d/normalized" <(jq -S . "$d/disabled")
jq '.route.rule_set += [{tag:"prenet-ip-check",type:"remote",url:"https://example.test"}]' "$d/original" > "$d/conflict"
if render_warp_check_sites "$d/conflict" on >/dev/null 2>&1; then exit 1; fi
# Transaction failures restore the exact previous route and restart it.
acquire_proxy_transaction_lock_checked() { return 0; }
release_proxy_transaction_lock() { return 0; }
singbox_service_is_active() { return 0; }
singbox_service_is_stably_active() { return 0; }
warp_endpoint_is_valid() { return 0; }
extract_warp_endpoint() { echo '{}'; }
get_warp_preferred_family() { echo 6; }
red() { :; }; green() { :; }
restart_singbox_checked() { printf 'restart\n' >> "$d/restarts"; return 0; }
validate_singbox_config() { return "${VALID_RC:-0}"; }
cp "$d/original" "$conf_dir/route.json"
VALID_RC=1
if set_warp_check_sites on; then exit 1; fi
cmp "$d/original" "$conf_dir/route.json"
VALID_RC=0
set_warp_check_sites on
set_warp_check_sites off
cmp "$d/normalized" <(jq -S . "$conf_dir/route.json")
echo 'WARP query-site routing and rollback tests passed.'
