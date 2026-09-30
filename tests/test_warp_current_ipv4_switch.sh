#!/usr/bin/env bash
set -euo pipefail
ensure_warp_adapter() { return 0; }
generate_warp_keypair() { "$singbox_bin" generate wg-keypair; }
warp_use_serial_probe() { return 1; }
require_warp_candidate_memory() { return 0; }
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in switch_current_warp_to_ipv4 render_warp_route_family write_warp_preferred_family is_valid_ipv4_address; do source <(sed -n "/^${f}() {/,/^}/p" "$script"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d/conf"; mkdir -p "$conf_dir/warp"
red(){ :; }; yellow(){ :; }; green(){ :; }
acquire_proxy_transaction_lock_checked(){ :; }; release_proxy_transaction_lock(){ :; }
singbox_service_is_active(){ [[ "$CASE" != stopped ]]; }
singbox_service_is_stably_active(){ return 0; }
restart_singbox_checked(){ echo restart >> "$d/restarts"; }
generate_unique_warp_identity(){ echo unexpected >> "$d/register"; return 99; }
delete_warp_registration(){ echo unexpected >> "$d/delete"; return 99; }
probe_active_warp(){
 local n=0; [[ ! -e "$d/probes" ]] || n=$(cat "$d/probes"); n=$((n+1)); echo "$n" > "$d/probes"
 [[ "$1" == 4 && "$CASE" != unavailable ]] || return 1
 [[ "$CASE" != postfail || "$n" == 1 ]] || return 1
 WARP_PROBE_IP=198.51.100.1
}
apply_proxy_config_transaction(){
 [[ "$PROXY_TX_WARP_FAMILY" == 4 && "$PROXY_TX_PRESERVE_STOPPED" == 1 ]]
 [[ "$CASE" != invalid ]] || return 1
 render_warp_route_family "$conf_dir/route.json" "$d/next" 4
 mv "$d/next" "$conf_dir/route.json"
 [[ "$CASE" != restartfail ]]
}
for CASE in success stopped unavailable invalid restartfail postfail; do
 rm -f "$d/probes" "$d/restarts"
 printf '{"route":{"rules":[{"rule_set":["openai"],"action":"route","outbound":"wireguard-out"}],"final":"direct"}}' > "$conf_dir/route.json"
 printf '{"outbounds":[{"type":"direct","tag":"direct"}]}' > "$conf_dir/outbounds.json"
 printf 'same-identity' > "$conf_dir/warp/account.json"
 printf '6\n' > "$conf_dir/warp/preferred-family"
 cp "$conf_dir/route.json" "$d/before-route"
 rc=0; switch_current_warp_to_ipv4 || rc=$?
 [[ "$(cat "$conf_dir/warp/account.json")" == same-identity && ! -e "$d/register" && ! -e "$d/delete" ]]
 if [[ "$CASE" == success ]]; then
  [[ "$rc" == 0 && "$(cat "$conf_dir/warp/preferred-family")" == 4 && "$(cat "$d/probes")" == 2 ]]
  jq -e '.route.rules[0].strategy=="ipv4_only"' "$conf_dir/route.json" >/dev/null
 else
  [[ "$rc" != 0 && "$(cat "$conf_dir/warp/preferred-family")" == 6 ]]
  cmp "$conf_dir/route.json" "$d/before-route"
 fi
 [[ "$CASE" != stopped || ! -e "$d/probes" && ! -e "$d/restarts" ]]
done
echo 'Current identity IPv4 switch verifies twice, preserves identity, and rolls back failure without starting stopped service.'

CASE=success; rm -f "$d/probes" "$d/restarts" "$conf_dir/outbounds.json"
printf 'outside-sentinel' > "$d/outside"
ln -s "$d/outside" "$conf_dir/outbounds.json"
rc=0; switch_current_warp_to_ipv4 || rc=$?
[[ "$rc" != 0 && "$(cat "$d/outside")" == outside-sentinel && ! -e "$d/probes" && ! -e "$d/restarts" ]]
echo 'Unsafe outbound symlink is rejected before probes, writes or restarts.'

rm -f "$conf_dir/outbounds.json"
for invalid_file in route.json outbounds.json; do
 printf '{"route":{"rules":[],"final":"direct"}}' > "$conf_dir/route.json"
 printf '{"outbounds":[]}' > "$conf_dir/outbounds.json"
 printf 'damaged-json' > "$conf_dir/$invalid_file"
 rc=0; switch_current_warp_to_ipv4 || rc=$?
 [[ "$rc" != 0 && ! -e "$d/probes" && ! -e "$d/restarts" && "$(cat "$conf_dir/$invalid_file")" == damaged-json ]]
done
echo 'Preexisting malformed disk JSON never triggers a disruptive core restart.'

printf '{"route":{"rules":[],"final":"direct"}}' > "$conf_dir/route.json"
printf '{"outbounds":[]}' > "$conf_dir/outbounds.json"
cp(){ [[ "${*: -1}" != *'.ipv4-switch.'* ]] || return 1; command cp "$@"; }
rc=0; switch_current_warp_to_ipv4 || rc=$?
unset -f cp
[[ "$rc" != 0 && ! -e "$d/restarts" ]]
echo 'Snapshot failure before mutation does not restart the working core.'
