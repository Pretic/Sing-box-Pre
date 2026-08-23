#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

function_source="$(sed -n '/^disable_open_sub() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] || fail 'disable_open_sub is not implemented'
source <(printf '%s\n' "$function_source")

CHOICE=6
ACTION_STATUS=0
check_singbox() { return 0; }
clear() { :; }
green() { :; }
yellow() { :; }
red() { :; }
skyblue() { :; }
purple() { :; }
reading() { printf -v "$2" '%s' "$CHOICE"; }
read() { return 0; }
configure_cf_https_subscription() { return "$ACTION_STATUS"; }
disable_cf_https_subscription() { return "$ACTION_STATUS"; }
rotate_subscription_token() { return "$ACTION_STATUS"; }

for CHOICE in 6 7 8; do
    for ACTION_STATUS in 1 2 3; do
        set +e
        disable_open_sub >/dev/null 2>&1
        actual=$?
        set -e
        [[ "$actual" -eq "$ACTION_STATUS" ]] || \
            fail "subscription menu option ${CHOICE} converted rc=${ACTION_STATUS} into rc=${actual}"
    done
done

printf 'Subscription menu status tests passed.\n'
