#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

rotate_block=$(sed -n '/^rotate_warp_identity_once() {/,/^}/p' "$script")
auto_block=$(sed -n '/^auto_select_warp_candidate() {/,/^}/p' "$script")
[[ -n "$rotate_block" && -n "$auto_block" ]] || fail 'WARP rotation functions are missing'
# shellcheck disable=SC1090
source /dev/stdin <<< "$rotate_block"
# shellcheck disable=SC1090
source /dev/stdin <<< "$auto_block"

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
run_selected_unlock_checks() { WARP_UNLOCK_SUMMARY='ok'; return 0; }
activate_warp_candidate() {
    ACTIVATE_CALLS=$((ACTIVATE_CALLS + 1))
    ACTIVATE_IP="${2:-}"
    ACTIVATE_FAMILY="${4:-4}"
}

rotate_warp_identity_once || fail 'IPv4-pinned candidate with a usable IPv6 path was rejected'
[[ "$ACTIVATE_CALLS" -eq 1 ]] || fail "rotation activated ${ACTIVATE_CALLS} candidates, expected one"
[[ "$ACTIVATE_FAMILY" = 6 ]] || fail "rotation activated family ${ACTIVATE_FAMILY:-unset}, expected IPv6"
[[ "$ACTIVATE_IP" = '2001:db8::10' ]] || fail "rotation activated unexpected IPv6 probe result: ${ACTIVATE_IP:-unset}"
[[ "$LOG" == *'固定了当前 POP 的 IPv4 出口'* && "$LOG" == *'优先使用 IPv6'* ]] ||
    fail 'rotation did not explain the IPv4 pinning and IPv6 fallback'

rm -rf -- "$conf_dir/warp"
mkdir -p "$conf_dir/warp"
LOG=''
ACTIVATE_CALLS=0
ACTIVATE_FAMILY=''
ACTIVATE_IP=''
GENERATE_CALLS=0
DELETE_CALLS=0

auto_select_warp_candidate 134 || fail 'auto selection rejected an unlocking candidate with a usable IPv6 path'
[[ "$ACTIVATE_CALLS" -eq 1 ]] || fail "auto selection activated ${ACTIVATE_CALLS} candidates, expected one"
[[ "$ACTIVATE_FAMILY" = 6 ]] || fail "auto selection activated family ${ACTIVATE_FAMILY:-unset}, expected IPv6"
[[ "$ACTIVATE_IP" = '2001:db8::10' ]] || fail "auto selection activated unexpected IPv6 probe result: ${ACTIVATE_IP:-unset}"

echo 'WARP dual-family rotation tests passed.'
