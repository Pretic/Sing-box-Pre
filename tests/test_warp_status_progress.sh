#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^show_warp_status_and_unlocks() {/,/^}/p' "$script")
source <(sed -n '/^run_selected_unlock_checks() {/,/^}/p' "$script")
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
conf_dir="$test_dir/conf"
mkdir -p "$conf_dir/warp"
printf '{"id":"test-device"}\n' > "$conf_dir/warp/account.json"
output="$test_dir/output"
starts=0
stops=0
ready=false
fail() { echo "FAIL: $*" >&2; exit 1; }
green() { printf '%s\n' "$*"; }
yellow() { printf '%s\n' "$*"; }
red() { printf '%s\n' "$*"; }
extract_warp_endpoint() { printf '{}\n'; }
warp_endpoint_is_valid() { return 0; }
get_warp_preferred_family() { printf '4\n'; }
start_warp_candidate_proxy() {
    starts=$((starts + 1)); ready=false; WARP_PROBE_PROXY=proxy
}
stop_warp_candidate_proxy() { stops=$((stops + 1)); ready=false; }
probe_warp_trace() {
    [[ -s "$output" ]] || fail 'status page is blank while the WARP handshake runs'
    ready=true
    WARP_PROBE_IP=104.28.1.2; WARP_PROBE_STATE=on
    WARP_PROBE_LOC=US; WARP_PROBE_COLO=LAX
}
probe_active_warp() {
    start_warp_candidate_proxy '{}'
    probe_warp_trace proxy
    stop_warp_candidate_proxy
}
check_unlock_netflix() {
    [[ "$ready" == true ]] || fail 'platform checks used a new, unready proxy'
    grep -q 'WARP: on' "$output" || fail 'connection result was withheld until all platforms finished'
    grep -q '正在检测 Netflix' "$output" || fail 'platform progress was not printed before the request'
    WARP_UNLOCK_STATUS='解锁 (US)'
}
check_unlock_disney() {
    grep -q 'Netflix: 解锁 (US)' "$output" || fail 'completed platform result was not shown immediately'
    WARP_UNLOCK_STATUS='检测超时'; return 2
}
check_unlock_chatgpt() { WARP_UNLOCK_STATUS='受限'; return 1; }
check_unlock_gemini() { WARP_UNLOCK_STATUS='网络/地区可用'; }
write_warp_status_cache() { return 0; }

show_warp_status_and_unlocks > "$output"
[[ "$starts" == 1 && "$stops" == 1 ]] || fail 'status checks did not reuse and clean up a single proxy'
grep -q 'Disney+: 检测超时' "$output" || fail 'failed platform result is missing'
grep -q 'Gemini: 网络/地区可用' "$output" || fail 'later platforms were skipped after a failure'

starts=0; stops=0
probe_warp_trace() { return 1; }
if show_warp_status_and_unlocks > "$output"; then fail 'failed WARP handshake was accepted'; fi
[[ "$stops" == 1 ]] || fail 'failed handshake left the probe running'
grep -q '探测失败' "$output" || fail 'failed handshake did not explain the failure'

menu_block=$(sed -n '/^warp_manage() {/,/^}/p' "$script")
grep -Fq 'show_warp_status_and_unlocks || true' <<< "$menu_block" || \
    fail 'status failure can abort the menu under errexit'
echo 'WARP status progress tests passed.'
