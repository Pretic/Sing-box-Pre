#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^probe_warp_trace() {/,/^}/p' "$script")
for name in is_valid_ipv4_address is_valid_ipv6_address; do
    source <(sed -n "/^${name}() {/,/^}/p" "$script")
done
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
attempt_file="$test_dir/attempts"
clock_file="$test_dir/clock"
printf '0\n' > "$clock_file"
date() { printf '%s\n' "$((1700000000 + $(cat "$clock_file")))"; }
sleep() { printf '%s\n' "$(($(cat "$clock_file") + $1))" > "$clock_file"; }
curl() {
    local attempt=0
    [[ ! -f "$attempt_file" ]] || read -r attempt < "$attempt_file"
    attempt=$((attempt + 1))
    printf '%s\n' "$attempt" > "$attempt_file"
    case "$scenario" in
      warming)
        [[ "$attempt" -ge 6 ]] || return 97
        printf 'ip=104.28.1.2\nloc=US\ncolo=LAX\nwarp=on\n'
        ;;
      failed) return 28 ;;
      direct) printf 'ip=192.0.2.1\nwarp=off\n' ;;
      ipv4) printf 'ip=104.28.1.2\nwarp=on\n' ;;
      ipv6) printf 'ip=2606:4700::1\nwarp=on\n' ;;
    esac
}
scenario=warming
probe_warp_trace socks5h://127.0.0.1:20000 || { echo 'FAIL: transient WireGuard startup failures were not retried' >&2; exit 1; }
[[ "$WARP_PROBE_STATE" == on && "$WARP_PROBE_IP" == 104.28.1.2 ]] || exit 1
scenario=failed
printf '0\n' > "$attempt_file"
if probe_warp_trace socks5h://127.0.0.1:20000; then echo 'FAIL: failed transport was accepted' >&2; exit 1; fi
[[ "$(cat "$attempt_file")" -le 16 ]] || { echo 'FAIL: retries are not bounded' >&2; exit 1; }
[[ -z "${WARP_PROBE_IP:-}" && -z "${WARP_PROBE_STATE:-}" ]] || { echo 'FAIL: failed probe retained stale success metadata' >&2; exit 1; }
scenario=direct
rm -f "$attempt_file"
if probe_warp_trace socks5h://127.0.0.1:20000; then echo 'FAIL: direct connection was accepted as WARP' >&2; exit 1; fi
[[ "$(cat "$attempt_file")" == 1 ]] || { echo 'FAIL: definitive non-WARP response was retried' >&2; exit 1; }
for WARP_PROBE_FAMILY in 4 6; do
    scenario="ipv${WARP_PROBE_FAMILY}"
    probe_warp_trace socks5h://127.0.0.1:20000 || exit 1
    if [[ "$WARP_PROBE_FAMILY" == 4 ]]; then scenario=ipv6; else scenario=ipv4; fi
    if probe_warp_trace socks5h://127.0.0.1:20000; then
        echo 'FAIL: wrong exit IP family was accepted' >&2; exit 1
    fi
done
echo 'WARP probe readiness tests passed.'
