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
probe_active_warp() {
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

echo 'WARP IPv6 activation verification tests passed.'
