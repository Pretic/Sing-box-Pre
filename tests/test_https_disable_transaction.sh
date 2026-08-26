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

finish_source="$(sed -n '/^finish_transaction_release() {/,/^}/p' "$script")"
[[ -n "$finish_source" ]] || fail 'finish_transaction_release is not implemented'
source <(printf '%s\n' "$finish_source")

function_source="$(sed -n '/^disable_cf_https_subscription() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] || fail 'disable_cf_https_subscription is not implemented'
source <(printf '%s\n' "$function_source")

# Durable local/remote mutation, rollback, signal, and cleanup cases live in
# the subscription frontend suites. This test protects the public lock and
# exact status-propagation contract.
conf_dir="${tmp_dir}/conf"
mkdir -p "$conf_dir"
call_log="${tmp_dir}/calls.log"
LOCK_STATUS=0
MUTATION_STATUS=0

acquire_proxy_transaction_lock_checked() {
    printf 'lock|%s|%s\n' "$1" "$2" >> "$call_log"
    return "$LOCK_STATUS"
}

_disable_cf_https_subscription_locked() {
    printf 'mutate|%s\n' "$*" >> "$call_log"
    return "$MUTATION_STATUS"
}

release_proxy_transaction_lock() {
    printf 'release\n' >> "$call_log"
}

run_operation() {
    local status

    if disable_cf_https_subscription fixture-argument; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$status"
}

for LOCK_STATUS in 1 2; do
    : > "$call_log"
    MUTATION_STATUS=0
    status="$(run_operation)"
    [[ "$status" -eq "$LOCK_STATUS" ]] ||
        fail "lock status ${LOCK_STATUS} was not propagated"
    [[ "$(wc -l < "$call_log")" -eq 1 ]] ||
        fail 'failed lock still mutated or released the transaction'
    grep -Fqx "lock|${conf_dir}|HTTPS 订阅操作" "$call_log" ||
        fail 'wrapper did not lock the authoritative config directory'
done

LOCK_STATUS=0
for MUTATION_STATUS in 0 1 2 3; do
    : > "$call_log"
    status="$(run_operation)"
    [[ "$status" -eq "$MUTATION_STATUS" ]] ||
        fail "mutation status ${MUTATION_STATUS} was not propagated"
    [[ "$(grep -Fxc 'lock|' "$call_log")" -eq 0 ]] ||
        fail 'lock record unexpectedly lost its context'
    [[ "$(grep -Fc 'lock|' "$call_log")" -eq 1 ]] ||
        fail 'wrapper did not acquire exactly one lock'
    grep -Fqx 'mutate|fixture-argument' "$call_log" ||
        fail 'wrapper did not forward transaction arguments'
    [[ "$(grep -Fxc release "$call_log")" -eq 1 ]] ||
        fail 'wrapper did not release exactly once'
done

printf 'HTTPS disable wrapper transaction tests passed.\n'
