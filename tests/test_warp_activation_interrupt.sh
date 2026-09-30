#!/usr/bin/env bash
set -euo pipefail
warp_use_serial_probe() { return 1; }
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in warp_activation_generation extract_warp_endpoint warp_endpoint_is_valid activate_warp_candidate _activate_warp_candidate_locked rollback_warp_activation_files render_warp_route_family remove_warp_activation_backup; do
    source <(sed -n "/^${f}() {/,/^}/p" "$script")
done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d/conf"; candidate="$d/candidate"; mkdir -p "$conf_dir/warp" "$candidate"
red() { :; }; yellow() { :; }; green() { :; }
acquire_proxy_transaction_lock_checked() { echo lock >> "$d/events"; }
release_proxy_transaction_lock() { echo unlock >> "$d/events"; }
singbox_service_is_active() { return "${STOPPED:-0}"; }
restart_singbox_checked() { echo restart >> "$d/events"; }
singbox_service_is_stably_active() { return 0; }
validate_singbox_config() { return 0; }
verify_activated_warp() { return "${VERIFY_RC:-0}"; }
write_warp_status_cache() { :; }
delete_warp_registration() { echo delete >> "$d/events"; }
reset() {
    printf '{"type":"wireguard","tag":"wireguard-out","address":["172.16.0.2/32"],"private_key":"old","peers":[{"address":"engage.cloudflareclient.com","port":2408,"public_key":"peer","allowed_ips":["0.0.0.0/0"],"reserved":[1,2,3]}]}' > "$conf_dir/warp/endpoint.json"
    jq '{endpoints:[.]}' "$conf_dir/warp/endpoint.json" > "$conf_dir/endpoints.json"
    jq '.private_key="new"' "$conf_dir/warp/endpoint.json" > "$candidate/endpoint.json"
    printf '{"id":"old"}' > "$conf_dir/warp/account.json"
    printf '{"id":"new"}' > "$candidate/account.json"
    printf '{"route":{"rules":[],"final":"direct"}}' > "$conf_dir/route.json"
    printf '4\n' > "$conf_dir/warp/preferred-family"
    cp -a "$conf_dir" "$d/before"
    : > "$d/events"
}
reset
install() {
    command install "$@" || return $?
    [[ "$3" != "$candidate/account.json" ]] || kill -TERM "$BASHPID"
}
rc=0; activate_warp_candidate "$candidate" '' '' 6 || rc=$?
unset -f install
[[ "$rc" == 143 ]]
for file in endpoints.json route.json warp/account.json warp/endpoint.json warp/preferred-family; do cmp "$conf_dir/$file" "$d/before/$file"; done
! grep -q '^delete$' "$d/events"
[[ "$(grep -c '^lock$' "$d/events")" == 1 && "$(grep -c '^unlock$' "$d/events")" == 1 ]]
[[ "$(grep -c '^restart$' "$d/events")" == 1 ]]
rm -rf "$d/before"
reset
STOPPED=1; rc=0; activate_warp_candidate "$candidate" || rc=$?; STOPPED=0
[[ "$rc" == 1 ]]; ! grep -q '^restart$' "$d/events"
cmp "$conf_dir/warp/account.json" "$d/before/warp/account.json"
# Ordinary success commits once, then retires the previous cloud registration.
activate_warp_candidate "$candidate" '' '' 6
jq -e '.id=="new"' "$conf_dir/warp/account.json" >/dev/null
[[ "$(cat "$conf_dir/warp/preferred-family")" == 6 ]]
[[ "$(grep -c '^delete$' "$d/events")" == 1 ]]
echo 'WARP activation interruption restores identity, route and family; stopped service remains stopped.'

# A candidate staged against an old identity/config cannot overwrite a new edit.
baseline_generation=$(warp_activation_generation)
printf '{"route":{"rules":[],"final":"newer-custom-route"}}' > "$conf_dir/route.json"
cp "$conf_dir/route.json" "$d/newer-route"
rc=0; activate_warp_candidate "$candidate" '' '' 4 '' "$baseline_generation" || rc=$?
[[ "$rc" == 9 ]]
cmp "$conf_dir/route.json" "$d/newer-route"
echo 'Stale candidate generation cannot overwrite a newer configuration.'
