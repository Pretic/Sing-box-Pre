#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

function_source="$(sed -n '/^manage_argo() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] || fail 'manage_argo is not implemented'
source <(printf '%s\n' "$function_source")

transition_log="${tmp_dir}/transition.log"
transition_status=0

clear() { :; }
green() { :; }
yellow() { printf '%s\n' "$*" >&2; }
red() { printf '%s\n' "$*" >&2; }
purple() { :; }
skyblue() { :; }
check_argo() { printf 'running\n'; }
reading() { choice=5; }
transition_to_quick_argo() {
    printf '%s\n' transactional-switch >> "$transition_log"
    return "$transition_status"
}
menu() { :; }

manage_argo >/dev/null 2>&1 || fail 'fixed-to-quick transition unexpectedly failed'
expected='transactional-switch'
actual="$(command cat "$transition_log")"
[[ "$actual" == "$expected" ]] || \
    fail "manage_argo bypassed the transactional switch: ${actual//$'\n'/,}"

: > "$transition_log"
transition_status=1
if manage_argo >/dev/null 2>&1; then
    fail 'fixed-to-quick transition hid a transactional failure'
fi
[[ "$(command cat "$transition_log")" == transactional-switch ]] || \
    fail 'failed transition executed non-transactional fallback steps'

: > "$transition_log"
transition_status=2
set +e
menu_output="$(manage_argo 2>&1)"
menu_status=$?
set -e
[[ "$menu_status" -eq 2 ]] || \
    fail "manage_argo converted incomplete rollback rc=2 into rc=${menu_status}"
[[ "$menu_output" == *'自动回滚不完整'* ]] || \
    fail 'manage_argo did not distinguish incomplete rollback from full rollback'
[[ "$(command cat "$transition_log")" == transactional-switch ]] || \
    fail 'rc=2 transition executed non-transactional fallback steps'

: > "$transition_log"
transition_status=3
set +e
menu_output="$(manage_argo 2>&1)"
menu_status=$?
set -e
[[ "$menu_status" -eq 3 ]] || \
    fail "manage_argo converted committed-with-residue rc=3 into rc=${menu_status}"
[[ "$menu_output" == *'已成功'*'清理'* ]] || \
    fail 'manage_argo reported rc=3 as a failed or rolled-back transition'

printf 'Argo HTTPS transition tests passed.\n'
