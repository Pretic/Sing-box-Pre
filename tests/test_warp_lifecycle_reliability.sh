#!/usr/bin/env bash
set -euo pipefail
warp_use_serial_probe() { return 1; }
script="${SB_TEST_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh}"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
load() { source <(sed -n "/^$1() {/,/^}/p" "$script"); }
for f in restore_direct_outbound set_global_outbound add_rule_menu; do load "$f"; done
red() { :; }; green() { :; }; yellow() { :; }; purple() { :; }; skyblue() { :; }
clear() { :; }; sleep() { :; }; warp_manage() { :; }
green=''; purple=''; skyblue=''; re=''
route_file="$d/route.json"; outbound_file="$d/outbounds.json"
printf '{"route":{"rules":[]}}' > "$route_file"
printf '{"outbounds":[{"tag":"direct","type":"direct"},{"tag":"my-proxy","type":"socks"}]}' > "$outbound_file"
ensure_warp_prerequisites() { echo unexpected >> "$d/registrations"; return 1; }
restore_direct_route() { echo direct >> "$d/choices"; }
restore_direct_outbound
[[ "$(cat "$d/choices")" == direct && ! -e "$d/registrations" ]]
set_global_route() { echo "$1" >> "$d/choices"; }
reading() { case "$2" in add_choice) printf -v "$2" 1 ;; out_choice) printf -v "$2" 2 ;; esac; }
set_global_outbound
[[ "$(tail -1 "$d/choices")" == my-proxy && ! -e "$d/registrations" ]]
add_service_route() { printf '%s:%s\n' "$1" "$2" >> "$d/choices"; }
add_rule_menu
[[ "$(tail -1 "$d/choices")" == openai:my-proxy && ! -e "$d/registrations" ]]

# Use the actual shared route transaction, with only OS/service effects mocked.
source <(sed -n '/^extract_warp_endpoint() {/,/^warp_manage() {/p' "$script" | sed '$d')
load finish_transaction_release
conf_dir="$d/conf"; work_dir="$d"; mkdir -p "$conf_dir"
route_file="$conf_dir/route.json"; outbound_file="$conf_dir/outbounds.json"
acquire_proxy_transaction_lock_checked() { echo lock >> "$d/events"; }
release_proxy_transaction_lock() { echo unlock >> "$d/events"; }
singbox_service_is_active() { return 1; }
restart_singbox_checked() { echo unexpected-restart >> "$d/events"; return 1; }
singbox_check_config_dir() { return "${INVALID:-0}"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
printf '{"route":{"rules":[],"final":"wireguard-out"}}' > "$route_file"
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}' > "$outbound_file"
restore_direct_route
jq -e '.route.final=="direct"' "$route_file" >/dev/null
! grep -q unexpected-restart "$d/events"
[[ "$(grep -c '^lock$' "$d/events")" == 1 && "$(grep -c '^unlock$' "$d/events")" == 1 ]]
cp "$route_file" "$d/original"
INVALID=1
if set_global_route wireguard-out; then echo 'invalid candidate committed'; exit 1; fi
cmp "$route_file" "$d/original"
INVALID=0
# SIGTERM between route and outbounds commit restores both production files.
proxy_transaction_hook() { [[ "$1" != after-route-commit ]] || kill -TERM "$BASHPID"; }
rc=0
(trap - EXIT; set_global_route wireguard-out) || rc=$?
[[ "$rc" == 143 ]]
cmp "$route_file" "$d/original"
! grep -q unexpected-restart "$d/events"

# Repairing a WARP configuration must preserve existing custom builtin tags
# and keep other outbound credentials private.
warp_endpoint_json() { printf '{"tag":"wireguard-out","type":"wireguard"}'; }
validate_singbox_config() { return 0; }
jq '.route.rule_set=[{"tag":"openai","type":"inline","rules":[{"domain":["private.example"]}]}]' "$route_file" > "$d/route-custom"
env mv "$d/route-custom" "$route_file"
env chmod 600 "$outbound_file"
ensure_warp_prerequisites
jq -e '.route.rule_set[]|select(.tag=="openai")|.type=="inline" and .rules[0].domain==["private.example"]' "$route_file" >/dev/null
[[ "$(stat -c %a "$outbound_file")" == 600 ]]
cp "$route_file" "$d/prereq-route.before"
cp "$outbound_file" "$d/prereq-outbound.before"
cp "$conf_dir/endpoints.json" "$d/prereq-endpoint.before"
chmod() {
    [[ "$*" != "600 $conf_dir/endpoints.json $route_file $outbound_file" ]] || return 1
    command chmod "$@"
}
if ensure_warp_prerequisites; then echo 'permission failure reported success'; exit 1; fi
unset -f chmod
cmp "$route_file" "$d/prereq-route.before"
cmp "$outbound_file" "$d/prereq-outbound.before"
# Interrupt after the first live prerequisite rename; all three files recover.
mv() {
    command mv "$@" || return $?
    [[ "${*: -1}" != "$conf_dir/endpoints.json" ]] || kill -TERM "$BASHPID"
}
rc=0; ensure_warp_prerequisites || rc=$?
unset -f mv
[[ "$rc" == 143 ]]
cmp "$route_file" "$d/prereq-route.before"
cmp "$outbound_file" "$d/prereq-outbound.before"
cmp "$conf_dir/endpoints.json" "$d/prereq-endpoint.before"
printf 'damaged json' > "$route_file"
if ensure_warp_prerequisites; then echo 'damaged custom config overwritten'; exit 1; fi
[[ "$(cat "$route_file")" == 'damaged json' ]]
echo 'WARP disable independence, stopped-state, locked rollback and custom configuration tests passed.'
