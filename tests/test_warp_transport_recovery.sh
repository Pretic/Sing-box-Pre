#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for name in warp_platform_curl run_selected_unlock_checks; do
 source <(sed -n "/^${name}() {/,/^}/p" "$script")
done
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
conf_dir="$tmp/conf"; WARP_PROBE_DIR="$conf_dir/warp/.probe.fixture"; mkdir -p "$WARP_PROBE_DIR"
fail() { echo "FAIL: $*" >&2; exit 1; }
declare -F warp_platform_curl >/dev/null || fail 'platform transport classification missing'
curl() {
 local n=0; [[ ! -e "$tmp/calls" ]] || read -r n < "$tmp/calls"
 n=$((n+1)); echo "$n" > "$tmp/calls"
 [[ "$scenario" == recover && "$n" == 2 ]] && { echo ok; return 0; }
 return 28
}
check_unlock_netflix() {
 local response
 response=$(warp_platform_curl https://fixture.invalid) || { WARP_UNLOCK_STATUS='检测失败'; return 2; }
 WARP_UNLOCK_STATUS='解锁 (US)'
}
probe_warp_trace() { traces=$((traces+1)); [[ "$scenario" != disconnected ]]; }
scenario=recover; traces=0
run_selected_unlock_checks proxy 1 || fail 'same-identity recovery did not retry failed transport'
[[ "$(cat "$tmp/calls")" == 2 && "$traces" == 1 && "$WARP_UNLOCK_TRANSPORT_FAILED" == 0 ]] || fail 'recovery not bounded/cleared'
scenario=disconnected; traces=0; rm -f "$tmp/calls"
if run_selected_unlock_checks proxy 1; then fail 'disconnected proxy passed'; fi
[[ "$(cat "$tmp/calls")" == 1 && "$traces" == 1 && "$WARP_UNLOCK_TRANSPORT_FAILED" == 1 ]] || fail 'persistent network failure not classified'
check_unlock_netflix() { WARP_UNLOCK_STATUS='受限'; return 1; }
traces=0
if run_selected_unlock_checks proxy 1; then fail 'restricted platform passed'; fi
[[ "$traces" == 0 && "$WARP_UNLOCK_TRANSPORT_FAILED" == 0 ]] || fail 'restriction retried or stale network flag'
check_unlock_netflix() { WARP_UNLOCK_STATUS='检测结果不明'; return 2; }
if run_selected_unlock_checks proxy 1; then fail 'ambiguous platform passed'; fi
[[ "$traces" == 0 && "$WARP_UNLOCK_TRANSPORT_FAILED" == 0 ]] || fail 'ambiguous response incorrectly classified as transport failure'
echo 'WARP transport recovery tests passed.'
