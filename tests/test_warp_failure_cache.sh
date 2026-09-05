#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for name in get_warp_menu_status write_warp_status_cache get_warp_preferred_family; do
    source <(sed -n "/^${name}() {/,/^}/p" "$script")
done
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
conf_dir="$test_dir/conf"
extract_warp_endpoint() { printf '{}\n'; }
warp_endpoint_is_valid() { return 0; }
probe_active_warp() { printf 'probe\n' >> "$test_dir/probes"; return 1; }
WARP_PROBE_IP=192.0.2.1; WARP_PROBE_LOC=US; WARP_PROBE_COLO=LAX; WARP_PROBE_STATE=on
[[ "$(get_warp_menu_status)" == degraded ]] || exit 1
[[ "$(get_warp_menu_status)" == degraded ]] || exit 1
[[ "$(wc -l < "$test_dir/probes")" -eq 1 ]] || {
    echo 'FAIL: failed WARP probe was repeated on the next menu redraw' >&2; exit 1;
}
jq -e '.warp == "failed" and .ip == "" and .loc == "" and .colo == "" and .checked_at > 0' "$conf_dir/warp/status.json" >/dev/null || {
    echo 'FAIL: cached failure retained stale successful exit metadata' >&2; exit 1;
}
echo 'WARP failure cache tests passed.'
