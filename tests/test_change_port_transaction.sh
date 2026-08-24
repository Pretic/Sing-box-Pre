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

function_source="$(sed -n '/^change_public_inbound_port_transaction() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] ||
    fail 'change_public_inbound_port_transaction is not implemented'
source <(printf '%s\n' "$function_source")

# The firewall ownership suite exercises config mutation, HY2 hopping,
# rollback, recovery evidence, and old-rule cleanup. This file protects the
# public serialization wrapper and exact 0/1/2/3 status propagation.
call_log="${tmp_dir}/calls.log"
LOCK_STATUS=0
MUTATION_STATUS=0

acquire_public_port_change_lock() {
    printf 'lock\n' >> "$call_log"
    return "$LOCK_STATUS"
}

_change_public_inbound_port_transaction_locked() {
    printf 'mutate|%s\n' "$*" >> "$call_log"
    return "$MUTATION_STATUS"
}

release_public_port_change_lock() {
    printf 'release\n' >> "$call_log"
}

run_change() {
    local status

    if change_public_inbound_port_transaction /tmp/inbounds.json hysteria2 24443 udp; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$status"
}

for LOCK_STATUS in 1 2; do
    : > "$call_log"
    MUTATION_STATUS=0
    status="$(run_change)"
    [[ "$status" -eq "$LOCK_STATUS" ]] ||
        fail "lock status ${LOCK_STATUS} was not propagated"
    [[ "$(wc -l < "$call_log")" -eq 1 ]] ||
        fail 'failed lock still mutated or released the transaction'
done

LOCK_STATUS=0
for MUTATION_STATUS in 0 1 2 3; do
    : > "$call_log"
    status="$(run_change)"
    [[ "$status" -eq "$MUTATION_STATUS" ]] ||
        fail "mutation status ${MUTATION_STATUS} was not propagated"
    [[ "$(grep -Fxc lock "$call_log")" -eq 1 ]] ||
        fail 'wrapper did not acquire exactly one lock'
    grep -Fqx 'mutate|/tmp/inbounds.json hysteria2 24443 udp' "$call_log" ||
        fail 'wrapper did not forward all mutation arguments'
    [[ "$(grep -Fxc release "$call_log")" -eq 1 ]] ||
        fail 'wrapper did not release exactly once'
done

printf 'Public port transaction wrapper tests passed.\n'
