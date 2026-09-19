#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in validate_port_value render_warp_health_config warp_health_config_is_valid probe_active_warp start_warp_active_proxy stop_warp_candidate_proxy; do
    source <(sed -n "/^${f}() {/,/^}/p" "$script")
done
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
conf_dir="$test_dir/conf"
mkdir -p "$conf_dir/warp"
printf '%048d' 1 > "$test_dir/secret"
render_warp_health_config 30101 30102 30103 "$test_dir/secret" > "$conf_dir/00-prenet-health.json"
warp_health_config_is_valid
jq -e 'all(.inbounds[]; .listen=="127.0.0.1" and (.users|length)==1) and (.endpoints==null)' "$conf_dir/00-prenet-health.json" >/dev/null
ensure_warp_health_inbounds() { warp_health_config_is_valid; }
singbox_service_is_active() { return 0; }
start_warp_candidate_proxy() { echo 'active identity duplicated' >&2; exit 99; }
probe_warp_trace() {
    [[ "$WARP_PROBE_MODE" == active ]]
    [[ "$WARP_PROBE_PROXY" == socks5h://127.0.0.1:* ]]
    [[ "$WARP_PROBE_PROXY" != *@* ]]
    [[ "${WARP_PROBE_CURL_ARGS[0]}" == --config ]]
    [[ -r "${WARP_PROBE_CURL_ARGS[1]}" && -z "${WARP_PROBE_PID:-}" ]]
    [[ "$(stat -c %a "${WARP_PROBE_CURL_ARGS[1]}")" == 600 ]]
    WARP_PROBE_IP=192.0.2.1; WARP_PROBE_STATE=on
    return "${PROBE_RC:-0}"
}
for family in 4 6; do
    probe_active_warp "$family"
    [[ "$WARP_PROBE_STATE" == on && -z "${WARP_PROBE_DIR:-}" ]]
done
PROBE_RC=1
if probe_active_warp 4; then exit 1; fi
[[ -z "${WARP_PROBE_DIR:-}" ]]
if start_warp_active_proxy invalid; then exit 1; fi
for filter in '.inbounds[0].listen="0.0.0.0"' '.inbounds[0].users=[]' '.route.rules[2].outbound="direct"' '.inbounds[1].listen_port=30101'; do
    render_warp_health_config 30101 30102 30103 "$test_dir/secret" | jq "$filter" > "$conf_dir/00-prenet-health.json"
    if warp_health_config_is_valid; then echo "accepted unsafe health config" >&2; exit 1; fi
done
if render_warp_health_config 1 1 2 "$test_dir/secret" >/dev/null; then exit 1; fi
printf 'invalid' > "$test_dir/secret"
if render_warp_health_config 30101 30102 30103 "$test_dir/secret" >/dev/null 2>&1; then exit 1; fi
echo 'Active WARP runtime diagnostics tests passed.'
