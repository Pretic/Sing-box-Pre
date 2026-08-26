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

function_source="$(sed -n '/^rotate_subscription_token() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] || fail 'rotate_subscription_token is not implemented'
source <(printf '%s\n' "$function_source")

# Durable mutation and rollback are covered by the subscription frontend
# transaction suites. This test locks the public wrapper contract: one lock,
# one mutation, one release, and exact propagation of status 0/1/2/3.
conf_dir="${tmp_dir}/conf"
mkdir -p "$conf_dir"
call_log="${tmp_dir}/calls.log"
LOCK_STATUS=0
MUTATION_STATUS=0

acquire_proxy_transaction_lock_checked() {
    printf 'lock|%s|%s\n' "$1" "$2" >> "$call_log"
    return "$LOCK_STATUS"
}

_rotate_subscription_token_locked() {
    printf 'mutate|%s\n' "$*" >> "$call_log"
    return "$MUTATION_STATUS"
}

release_proxy_transaction_lock() {
    printf 'release\n' >> "$call_log"
}

run_rotation() {
    local status

    if rotate_subscription_token alpha beta; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$status"
}

for LOCK_STATUS in 1 2; do
    : > "$call_log"
    MUTATION_STATUS=0
    status="$(run_rotation)"
    [[ "$status" -eq "$LOCK_STATUS" ]] ||
        fail "lock status ${LOCK_STATUS} was not propagated"
    [[ "$(wc -l < "$call_log")" -eq 1 ]] ||
        fail "failed lock still mutated or released the transaction"
    grep -Fqx "lock|${conf_dir}|订阅密钥轮换" "$call_log" ||
        fail 'wrapper did not lock the authoritative config directory'
done

LOCK_STATUS=0
for MUTATION_STATUS in 0 1 2 3; do
    : > "$call_log"
    status="$(run_rotation)"
    [[ "$status" -eq "$MUTATION_STATUS" ]] ||
        fail "mutation status ${MUTATION_STATUS} was not propagated"
    [[ "$(grep -Fc 'lock|' "$call_log")" -eq 1 ]] ||
        fail 'wrapper did not acquire exactly one lock'
    grep -Fqx 'mutate|alpha beta' "$call_log" ||
        fail 'wrapper did not forward transaction arguments'
    [[ "$(grep -Fxc release "$call_log")" -eq 1 ]] ||
        fail 'wrapper did not release exactly once'
done

printf 'Subscription token wrapper transaction tests passed.\n'
