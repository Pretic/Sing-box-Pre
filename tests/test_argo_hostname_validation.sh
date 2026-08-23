#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

for function_name in is_valid_subscription_domain is_argo_hostname; do
    function_source="$(sed -n "/^${function_name}() {/,/^}/p" "$script")"
    [[ -n "$function_source" ]] || fail "${function_name} is not implemented"
    source <(printf '%s\n' "$function_source")
done

for hostname in fixed.example.com a-b.cdn.example.co.uk A1.Example.COM; do
    is_argo_hostname "$hostname" || fail "valid Argo hostname was rejected: ${hostname}"
done

long_label="$(printf 'a%.0s' {1..64})"
for hostname in \
    '-bad.example.com' 'bad-.example.com' '.bad.example.com' \
    'bad.example.com.' 'bad..example.com' 'bad_name.example.com' \
    '192.0.2.1' 'single-label' "${long_label}.example.com"; do
    if is_argo_hostname "$hostname"; then
        fail "invalid Argo hostname was accepted: ${hostname}"
    fi
done

printf 'Argo hostname validation tests passed.\n'
