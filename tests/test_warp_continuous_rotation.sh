#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^rotate_warp_identity_until_new() {/,/^}/p' "$script")
fail() { echo "FAIL: $*" >&2; exit 1; }
red() { :; }; yellow() { :; }
warp_rotation_now() { printf '%s' "$MOCK_NOW"; }
sleep() {
    WAITS+=("$1"); MOCK_NOW=$((MOCK_NOW+$1))
    [[ "${CANCEL_WAIT:-0}" != 1 ]]
}
warp_rotation_wait() { sleep "$1" || return 130; }
rotate_warp_identity_once() {
    [[ "$1" == 4 ]] || fail 'requestedIPv4 not passed to attempt'
    local rc="${QUEUE[$CALLS]:-99}"
    CALLS=$((CALLS+1)); WARP_REGISTRATION_RETRY_AFTER=900
    return "$rc"
}
reset() { QUEUE=("$@"); CALLS=0; MOCK_NOW=0; WAITS=(); CANCEL_WAIT=0; unset WARP_ROTATION_MAX_BATCHES WARP_ROTATION_MAX_SECONDS; }
reset 6 6 6 6 6 0
rotate_warp_identity_until_new
[[ "$CALLS" == 6 && "${WAITS[*]}" == '30 60 120 240 300' ]] || fail 'stopped at old batch cap or backoff missing'
reset 4 0
rotate_warp_identity_until_new
[[ "$CALLS" == 2 && "${WAITS[0]}" == 30 ]] || fail 'transient network failure was terminal'
reset 7 0
rotate_warp_identity_until_new
[[ "$CALLS" == 2 && "${WAITS[0]}" == 900 ]] || fail 'Retry-After ignored'
for terminal in 2 5 8 130 143; do
    reset "$terminal" 0; rc=0; rotate_warp_identity_until_new || rc=$?
    [[ "$rc" == "$terminal" && "$CALLS" == 1 && "${#WAITS[@]}" == 0 ]] || fail 'terminal result retried'
done
reset 6 6 0; WARP_ROTATION_MAX_BATCHES=2
rc=0; rotate_warp_identity_until_new || rc=$?
[[ "$rc" == 6 && "$CALLS" == 2 ]] || fail 'explicit batch budget ignored'
reset 6 6 0; WARP_ROTATION_MAX_SECONDS=20
rc=0; rotate_warp_identity_until_new || rc=$?
[[ "$rc" == 6 && "$CALLS" == 1 ]] || fail 'explicit duration budget ignored'
reset 6 0; CANCEL_WAIT=1
rc=0; rotate_warp_identity_until_new || rc=$?
[[ "$rc" == 130 && "$CALLS" == 1 ]] || fail 'cancelled wait continued'
echo 'SustainedIPv4 loop, backoff, rate-limit delay, explicit budgets and cancellation tests passed.'
