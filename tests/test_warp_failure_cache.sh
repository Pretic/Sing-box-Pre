#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^get_warp_menu_status() {/,/^}/p' "$script")
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
conf_dir="$test_dir/conf"
mkdir -p "$conf_dir/warp"
extract_warp_endpoint() { printf '{}\n'; }
warp_endpoint_is_valid() { return 0; }
probe_active_warp() { : > "$test_dir/unexpected-probe"; return 1; }
start_warp_candidate_proxy() { : > "$test_dir/unexpected-probe"; return 1; }
cache="$conf_dir/warp/status.json"
[[ "$(get_warp_menu_status)" == 'not checked' ]]
[[ ! -e "$cache" && ! -e "$test_dir/unexpected-probe" ]]
now=$(date +%s)
for state in failed on plus unknown; do
    jq -n --arg state "$state" --argjson now "$now" '{checked_at:$now,warp:$state}' > "$cache"
    case "$state" in failed) expected=degraded ;; on|plus) expected='cached success' ;; *) expected='not checked' ;; esac
    [[ "$(get_warp_menu_status)" == "$expected" ]]
    [[ "$(get_warp_menu_status)" == "$expected" ]]
done
for stamp in 0 -1 1 999999999999999999999 9999999999 'not-a-number' 'x[$(touch unexpected)]' 08; do
    jq -n --arg stamp "$stamp" '{checked_at:$stamp,warp:"on"}' > "$cache"
    [[ "$(get_warp_menu_status)" == 'not checked' ]]
done
printf 'invalid json' > "$cache"
[[ "$(get_warp_menu_status)" == 'not checked' ]]
warp_endpoint_is_valid() { return 1; }
[[ "$(get_warp_menu_status)" == 'not configured' ]]
[[ ! -e "$test_dir/unexpected-probe" ]]
echo 'Passive WARP menu cache tests passed.'
