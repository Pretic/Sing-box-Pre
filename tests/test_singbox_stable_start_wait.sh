#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

stable_block=$(sed -n '/^singbox_service_is_stably_active() {/,/^}/p' "$script")
[[ -n "$stable_block" ]] || fail 'stable sing-box service helper is missing'
# shellcheck disable=SC1090
source /dev/stdin <<< "$stable_block"

ACTIVE_CALLS=0
SLEEP_CALLS=0
detect_usable_init_system() { printf '%s\n' systemd; }
sleep() { SLEEP_CALLS=$((SLEEP_CALLS + 1)); }
systemctl() {
    case "$*" in
      'is-active --quiet sing-box')
        ACTIVE_CALLS=$((ACTIVE_CALLS + 1))
        [ "$ACTIVE_CALLS" -ge 6 ]
        ;;
      'show -p MainPID --value sing-box')
        printf '%s\n' 4321
        ;;
      *) return 1 ;;
    esac
}

singbox_service_is_stably_active ||
    fail 'a valid but slow sing-box startup was rejected before its endpoint became ready'
[[ "$ACTIVE_CALLS" -ge 7 ]] || fail 'stable PID verification was not completed'
[[ "$SLEEP_CALLS" -ge 6 ]] || fail 'helper did not wait for the slow startup and stable PID window'

echo 'Sing-box stable startup wait tests passed.'
