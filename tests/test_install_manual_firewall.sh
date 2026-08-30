#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

source_text="$(extract_function open_install_firewall_ports)"
[[ -n "$source_text" ]] || fail 'open_install_firewall_ports is not implemented'
source <(printf '%s\n' "$source_text")

vless_port=25001
nginx_port=25002
tuic_port=25001
hy2_port=25002
MOCK_ALLOW_STATUS=1
MOCK_ALLOW_REASON=manual-firewall
MOCK_CONFIRM=y
PROMPT_COUNT=0

allow_port() {
    [[ "$*" == '--families 1 0 25001/tcp 25002/tcp 25001/udp 25002/udp' ]] ||
        fail "unexpected firewall rules: $*"
    FIREWALL_LAST_RESULT_REASON="$MOCK_ALLOW_REASON"
    FIREWALL_LAST_ADDED_RECORDS=()
    return "$MOCK_ALLOW_STATUS"
}

reading() {
    PROMPT_COUNT=$((PROMPT_COUNT + 1))
    printf -v "$2" '%s' "$MOCK_CONFIRM"
}

red() { :; }
yellow() { :; }

open_install_firewall_ports 1 0 ||
    fail 'explicit manual-firewall confirmation did not continue installation'
[[ "$PROMPT_COUNT" -eq 1 ]] || fail 'manual-firewall confirmation was not requested exactly once'

MOCK_CONFIRM=n
if open_install_firewall_ports 1 0; then
    fail 'installation continued after manual-firewall confirmation was declined'
fi

MOCK_ALLOW_REASON=''
MOCK_CONFIRM=y
PROMPT_COUNT=0
if open_install_firewall_ports 1 0; then
    fail 'ordinary firewall failure was incorrectly downgraded'
fi
[[ "$PROMPT_COUNT" -eq 0 ]] || fail 'ordinary firewall failure prompted for an unsafe bypass'

MOCK_ALLOW_STATUS=2
MOCK_ALLOW_REASON=manual-firewall
PROMPT_COUNT=0
status=0
open_install_firewall_ports 1 0 || status=$?
[[ "$status" -eq 2 ]] || fail "unknown firewall state was downgraded to status ${status}"
[[ "$PROMPT_COUNT" -eq 0 ]] || fail 'unknown firewall state prompted for an unsafe bypass'

printf 'PASS: install manual-firewall confirmation\n'
