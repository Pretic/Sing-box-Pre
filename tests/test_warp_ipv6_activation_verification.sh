#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

verify_block=$(sed -n '/^verify_activated_warp() {/,/^}/p' "$script")
[[ -n "$verify_block" ]] || fail 'verify_activated_warp could not be extracted'
# shellcheck disable=SC1090
source /dev/stdin <<< "$verify_block"

ACTUAL_IP=''
conf_dir=/unused-test-conf
READY=false
STARTS=0
STOPS=0
extract_warp_endpoint() { printf '{}\n'; }
start_warp_candidate_proxy() { STARTS=$((STARTS + 1)); READY=false; WARP_PROBE_PROXY=proxy; }
stop_warp_candidate_proxy() { STOPS=$((STOPS + 1)); READY=false; }
probe_active_warp() {
    start_warp_candidate_proxy
    probe_warp_trace
    stop_warp_candidate_proxy
}
probe_warp_trace() {
    READY=true
    WARP_PROBE_IP="$ACTUAL_IP"
    WARP_PROBE_STATE=on
}

# Cloudflare can assign a different IPv6 address to the next connection made by
# the same WARP identity. IPv6 activation therefore verifies the address family,
# not byte-for-byte equality with the candidate probe.
ACTUAL_IP='2001:db8::2'
verify_activated_warp '2001:db8::1' '' 6 || \
    fail 'IPv6 activation rejected a valid WARP IPv6 address that changed between probes'

ACTUAL_IP='198.51.100.20'
if verify_activated_warp '2001:db8::1' '' 6; then
    fail 'IPv6 activation accepted an IPv4 probe result'
fi

ACTUAL_IP='198.51.100.20'
verify_activated_warp '198.51.100.20' '' 4 || fail 'matching IPv4 activation was rejected'

ACTUAL_IP='198.51.100.21'
if verify_activated_warp '198.51.100.20' '' 4; then
    fail 'IPv4 activation accepted a different address'
fi

run_selected_unlock_checks() {
    [[ "$READY" == true ]] || fail 'activation checks ran on a newly started, unready proxy'
}
STARTS=0; STOPS=0
verify_activated_warp '' 1234 4 || fail 'ready activation was rejected'
[[ "$STARTS" == 1 && "$STOPS" == 1 ]] || fail 'activation did not reuse and clean up one proxy'
STOPS=0
run_selected_unlock_checks() { return 2; }
if verify_activated_warp '' 1234 4; then fail 'inconclusive platforms were accepted'; else rc=$?; fi
[[ "$rc" == 2 && "$STOPS" == 1 ]] || fail 'activation failure lost its result or left a probe running'

ACTUAL_IP='198.51.100.20'
run_selected_unlock_checks() { WARP_PROBE_IP='198.51.100.21'; return 0; }
if verify_activated_warp '198.51.100.20' 1234 4; then
    fail 'platform recovery invalidated the expected IPv4 check'
fi

echo 'WARP IPv6 activation verification tests passed.'
