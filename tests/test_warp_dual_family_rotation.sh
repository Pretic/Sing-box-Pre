#!/usr/bin/env bash
set -euo pipefail
ensure_warp_adapter() { return 0; }
generate_warp_keypair() { "$singbox_bin" generate wg-keypair; }
warp_use_serial_probe() { return 1; }
begin_warp_serial_probe() { return 0; }
end_warp_serial_probe() { return 0; }
require_warp_candidate_memory() { return 0; }

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

rotate_block=$(sed -n '/^_rotate_warp_identity_once() {/,/^}/p' "$script")
auto_block=$(sed -n '/^_auto_select_warp_candidate() {/,/^}/p' "$script")
[[ -n "$rotate_block" && -n "$auto_block" ]] || fail 'WARP rotation functions are missing'
# shellcheck disable=SC1090
source /dev/stdin <<< "${rotate_block/#_rotate_warp_identity_once()/rotate_warp_identity_once()}"
# shellcheck disable=SC1090
source /dev/stdin <<< "${auto_block/#_auto_select_warp_candidate()/auto_select_warp_candidate()}"

warp_activation_generation() { printf 'baseline'; }

tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT
conf_dir="$tmp_root/conf"
mkdir -p "$conf_dir/warp"
printf '{}\n' > "$conf_dir/endpoints.json"

LOG=''
CURRENT_FAMILY=4
ACTIVATE_CALLS=0
ACTIVATE_FAMILY=''
ACTIVATE_IP=''
GENERATE_CALLS=0
DELETE_CALLS=0

red() { LOG+="red:$*"$'\n'; }
yellow() { LOG+="yellow:$*"$'\n'; }
green() { LOG+="green:$*"$'\n'; }
sleep() { :; }
warp_endpoint_is_valid() { return 0; }
extract_warp_endpoint() { printf '%s\n' '{}'; }
probe_active_warp() {
    case "${1:-4}" in
      4) WARP_PROBE_IP='198.51.100.10' ;;
      6) WARP_PROBE_IP='2001:db8::10' ;;
      *) return 1 ;;
    esac
    WARP_PROBE_STATE=on
}
generate_unique_warp_identity() {
    local candidate_dir="$1"
    GENERATE_CALLS=$((GENERATE_CALLS + 1))
    printf '{}\n' > "$candidate_dir/endpoint.json"
    printf '{}\n' > "$candidate_dir/account.json"
}
start_warp_candidate_proxy() {
    CURRENT_FAMILY="${2:-4}"
    WARP_PROBE_PROXY=mock-proxy
}
probe_warp_trace() {
    case "$CURRENT_FAMILY" in
      4) WARP_PROBE_IP='198.51.100.10' ;;
      6) WARP_PROBE_IP='2001:db8::10' ;;
      *) return 1 ;;
    esac
    WARP_PROBE_STATE=on
}
stop_warp_candidate_proxy() { :; }
delete_warp_registration() { DELETE_CALLS=$((DELETE_CALLS + 1)); }
remove_warp_candidate_dir() { rm -rf -- "$1"; }
run_selected_unlock_checks() {
    [[ "$CURRENT_FAMILY" == "${PLATFORM_FAMILY:-6}" ]] || return 1
    WARP_UNLOCK_SUMMARY='ok'; return 0
}
activate_warp_candidate() {
    [[ "$LOG" != *'并将所选分流规则切换为'* ]] || fail 'candidate was reported as switched before activation'
    ACTIVATE_CALLS=$((ACTIVATE_CALLS + 1))
    ACTIVATE_IP="${2:-}"
    ACTIVATE_FAMILY="${4:-4}"
}

rc=0; rotate_warp_identity_once || rc=$?
[[ "$rc" == 6 && "$ACTIVATE_CALLS" == 0 && "$GENERATE_CALLS" == 5 ]] || fail 'same IPv4 silently fell back to IPv6'
LOG=''; ACTIVATE_CALLS=0; GENERATE_CALLS=0; DELETE_CALLS=0
rc=0; rotate_warp_identity_once 6 || rc=$?
[[ "$rc" == 6 && "$ACTIVATE_CALLS" == 0 ]] || fail 'unchanged IPv6 was called a changed exit'
# A genuinely different observed IPv6 may be selected only when requested.
probe_warp_trace() {
    if [[ "$CURRENT_FAMILY" == 4 ]]; then WARP_PROBE_IP=198.51.100.10; else WARP_PROBE_IP=2001:db8::20; fi
    WARP_PROBE_STATE=on
}
LOG=''; ACTIVATE_CALLS=0; GENERATE_CALLS=0
rotate_warp_identity_once 6 || fail 'explicit different IPv6 was rejected'
[[ "$ACTIVATE_CALLS" == 1 && "$ACTIVATE_FAMILY" == 6 && "$ACTIVATE_IP" == 2001:db8::20 ]]
LOG=''; ACTIVATE_CALLS=0; GENERATE_CALLS=0
auto_select_warp_candidate 134 6 || fail 'explicit IPv6 platform choice failed'
[[ "$ACTIVATE_CALLS" == 1 && "$ACTIVATE_FAMILY" == 6 ]]
LOG=''; ACTIVATE_CALLS=0; GENERATE_CALLS=0; PLATFORM_FAMILY=4
if auto_select_warp_candidate 3; then fail 'unchanged IPv4 was presented as a new exit'; fi
[[ "$ACTIVATE_CALLS" == 0 ]]
echo 'Explicit WARP family and observed exit-change tests passed.'
