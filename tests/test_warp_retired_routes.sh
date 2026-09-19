#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in render_retired_warp_routes migrate_retired_warp_routes; do source <(sed -n "/^${f}() {/,/^}/p" "$script"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d/conf"; mkdir -p "$conf_dir"
cat > "$d/old" <<'JSON'
{"route":{"final":"direct","rule_set":[{"tag":"prenet-ip-check","type":"inline","rules":[{"domain_suffix":["ip.sb","ifconfig.co","icanhazip.com"]}]},{"tag":"google","type":"inline","rules":[{"domain_suffix":["google.com"]}]}],"rules":[{"action":"sniff"},{"rule_set":["google","prenet-ip-check"],"network":["tcp","udp"],"action":"resolve","strategy":"prefer_ipv6"},{"rule_set":["prenet-ip-check"],"action":"route","outbound":"wireguard-out"},{"rule_set":["google"],"action":"route","outbound":"wireguard-out"}]}}
JSON
render_retired_warp_routes "$d/old" > "$d/new"
jq -e '.route.final=="direct" and (.route.rule_set|length)==1 and (.route.rules|length)==3 and .route.rules[1].rule_set==["google"] and .route.rules[2].outbound=="wireguard-out"' "$d/new" >/dev/null
! grep -q 'prenet-ip-check' "$d/new"
render_retired_warp_routes "$d/new" > "$d/twice"; cmp "$d/new" "$d/twice"
for mutation in '.route.rule_set[0].rules[0].domain_suffix=["custom.example"]' '.route.rules[2].invert=true' '.route.rules[2].outbound="custom"'; do
 jq "$mutation" "$d/old" > "$d/custom"
 if render_retired_warp_routes "$d/custom" >/dev/null 2>&1; then echo 'custom rule deleted'; exit 1; fi
done
acquire_proxy_transaction_lock_checked() { :; }; release_proxy_transaction_lock() { :; }
singbox_service_is_active() { return "${INACTIVE:-0}"; }
singbox_service_is_stably_active() { :; }
validate_singbox_config() { return "${INVALID:-0}"; }
restart_singbox_checked() { echo restart >> "$d/restarts"; }
green() { :; }; red() { :; }
cp "$d/old" "$conf_dir/route.json"; INVALID=1
if migrate_retired_warp_routes; then exit 1; fi
cmp "$d/old" "$conf_dir/route.json"
INVALID=0; migrate_retired_warp_routes
cmp "$d/new" "$conf_dir/route.json"
n=$(wc -l < "$d/restarts"); migrate_retired_warp_routes
[[ "$(wc -l < "$d/restarts")" == "$n" ]]
# Cleaning a stopped instance must never start it.
cp "$d/old" "$conf_dir/route.json"; INACTIVE=1
migrate_retired_warp_routes
[[ "$(wc -l < "$d/restarts")" == "$n" ]]
# No entry capable of reinstalling the removed feature remains.
! grep -q '^set_warp_check_sites()\|^render_warp_check_sites()\|--warp-check-sites\|查询网站 WARP 分流' "$script"
echo 'Retired-route cleanup, customization guard, rollback and idempotence tests passed.'
