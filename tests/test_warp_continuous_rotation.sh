#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

controller_block=$(sed -n '/^warp_rotation_now() {/,/^auto_select_warp_candidate() {/p' "$script" | sed '$d')
[[ -n "$controller_block" ]] || fail 'rotate_warp_identity_until_new is not implemented'
# shellcheck disable=SC1090
source /dev/stdin <<< "$controller_block"

LOG=''
ROTATE_CALLS=0
MOCK_NOW=0
ADVANCE_AFTER_FIRST=false
ROTATE_QUEUE=()

red() { LOG+="red:$*"$'\n'; }
yellow() { LOG+="yellow:$*"$'\n'; }
green() { LOG+="green:$*"$'\n'; }
sleep() { :; }
warp_rotation_now() { printf '%s\n' "$MOCK_NOW"; }
rotate_warp_identity_once() {
    local queue_index=$ROTATE_CALLS
    local result="${ROTATE_QUEUE[$queue_index]:-1}"
    ROTATE_CALLS=$((ROTATE_CALLS + 1))
    if [ "$ADVANCE_AFTER_FIRST" = true ] && [ "$ROTATE_CALLS" -eq 1 ]; then
        MOCK_NOW=601
    fi
    return "$result"
}

reset_case() {
    LOG=''
    ROTATE_CALLS=0
    MOCK_NOW=0
    ADVANCE_AFTER_FIRST=false
    ROTATE_QUEUE=("$@")
    unset WARP_ROTATION_MAX_BATCHES WARP_ROTATION_MAX_SECONDS
}

reset_case 1 1 0
WARP_ROTATION_MAX_BATCHES=4
WARP_ROTATION_MAX_SECONDS=600
rotate_warp_identity_until_new || fail 'bounded controller did not continue to a later successful batch'
[[ "$ROTATE_CALLS" -eq 3 ]] || fail "success path used ${ROTATE_CALLS} batches, expected 3"
[[ "$LOG" == *'批次 3/4'* ]] || fail 'success path omitted batch progress'

reset_case 2 0
if rotate_warp_identity_until_new; then unsafe_rc=0; else unsafe_rc=$?; fi
[[ "$unsafe_rc" -eq 2 ]] || fail "unsafe result returned ${unsafe_rc}, expected 2"
[[ "$ROTATE_CALLS" -eq 1 ]] || fail 'unsafe result did not stop immediately'

reset_case 4 0
if rotate_warp_identity_until_new; then network_rc=0; else network_rc=$?; fi
[[ "$network_rc" -eq 4 ]] || fail "network stop returned ${network_rc}, expected 4"
[[ "$ROTATE_CALLS" -eq 1 ]] || fail 'network outage started another registration batch'

reset_case 1 1 1 1 0
WARP_ROTATION_MAX_BATCHES=4
if rotate_warp_identity_until_new; then capped_rc=0; else capped_rc=$?; fi
[[ "$capped_rc" -eq 1 ]] || fail "batch exhaustion returned ${capped_rc}, expected 1"
[[ "$ROTATE_CALLS" -eq 4 ]] || fail "batch limit used ${ROTATE_CALLS} batches, expected 4"
[[ "$LOG" == *'4 批上限'* ]] || fail 'batch-limit conclusion was not reported'

reset_case 1 0
WARP_ROTATION_MAX_BATCHES=4
WARP_ROTATION_MAX_SECONDS=600
ADVANCE_AFTER_FIRST=true
if rotate_warp_identity_until_new; then timed_rc=0; else timed_rc=$?; fi
[[ "$timed_rc" -eq 1 ]] || fail "time exhaustion returned ${timed_rc}, expected 1"
[[ "$ROTATE_CALLS" -eq 1 ]] || fail 'controller started another batch after its time budget expired'
[[ "$LOG" == *'600 秒时间上限'* ]] || fail 'time-limit conclusion was not reported'

reset_case 1 1 1 0
WARP_ROTATION_MAX_BATCHES=invalid
WARP_ROTATION_MAX_SECONDS=invalid
rotate_warp_identity_until_new || fail 'invalid limit values did not fall back to safe defaults'
[[ "$ROTATE_CALLS" -eq 4 ]] || fail "invalid batch limit did not use default 4; calls=${ROTATE_CALLS}"

reset_case 1 0
WARP_ROTATION_MAX_BATCHES=0
if rotate_warp_identity_until_new; then minimum_rc=0; else minimum_rc=$?; fi
[[ "$minimum_rc" -eq 1 ]] || fail "minimum clamp returned ${minimum_rc}, expected 1"
[[ "$ROTATE_CALLS" -eq 1 ]] || fail "zero batch limit was not clamped to one; calls=${ROTATE_CALLS}"

reset_case 1 1 1 1 1 1 1 1 1 1 1 1 0
WARP_ROTATION_MAX_BATCHES=999
WARP_ROTATION_MAX_SECONDS=3600
if rotate_warp_identity_until_new; then maximum_rc=0; else maximum_rc=$?; fi
[[ "$maximum_rc" -eq 1 ]] || fail "maximum clamp returned ${maximum_rc}, expected 1"
[[ "$ROTATE_CALLS" -eq 12 ]] || fail "excessive batch limit was not clamped to 12; calls=${ROTATE_CALLS}"

echo 'WARP continuous rotation tests passed.'
