#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
subscription_state_file="${work_dir}/subscription.conf"

for function_name in \
    is_valid_subscription_token \
    generate_subscription_token \
    is_valid_subscription_domain \
    is_valid_subscription_path \
    atomic_write_file \
    reset_subscription_state \
    load_subscription_state \
    save_subscription_state; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
    source <(printf '%s\n' "$function_source")
done

tokens_file="${work_dir}/tokens"
for _ in {1..40}; do
    token="$(generate_subscription_token)"
    [[ "$token" =~ ^[0123456789abcdefghjkmnpqrstvwxyz]{32}$ ]] || {
        echo "FAIL: invalid generated token: $token" >&2
        exit 1
    }
    printf '%s\n' "$token" >> "$tokens_file"
done
[[ "$(sort -u "$tokens_file" | wc -l | tr -d ' ')" -gt 1 ]] || {
    echo 'FAIL: generated tokens are not varying' >&2
    exit 1
}

is_valid_subscription_token '0123456789abcdefghjkmnpqrstvwxyz'
! is_valid_subscription_token '0123456789abcdefghjkmnpqrstvwxyi'

is_valid_subscription_domain 'sub.example.com'
is_valid_subscription_domain 'Sub.Example.com'
! is_valid_subscription_domain 'https://sub.example.com/path'
! is_valid_subscription_domain '*.example.com'
! is_valid_subscription_domain '-bad.example.com'
! is_valid_subscription_domain 'bad-.example.com'
! is_valid_subscription_domain 'bad..example.com'

is_valid_subscription_path '/0123456789abcdefghjkmnpqrstvwxyz'
is_valid_subscription_path '/sub/0123456789abcdefghjkmnpqrstvwxyz'
! is_valid_subscription_path '/../etc/passwd'
! is_valid_subscription_path '/sub/short'

cat > "$subscription_state_file" <<'STATE'
SUB_TOKEN=0123456789abcdefghjkmnpqrstvwxyz
SUB_HTTP_PATH=/0123456789abcdefghjkmnpqrstvwxyz
SUB_HTTPS_ENABLED=1
SUB_HTTPS_DOMAIN=Sub.Example.com
SUB_HTTPS_DOMAIN_MODE=separate
SUB_HTTPS_PATH=/0123456789abcdefghjkmnpqrstvwxyz
SUB_TUNNEL_MODE=remote
SUB_HTTPS_VERIFIED_AT=2026-08-15T00:00:00Z
EVIL=$(touch "$work_dir/pwned")
STATE

load_subscription_state
[[ "$SUB_TOKEN" == '0123456789abcdefghjkmnpqrstvwxyz' ]]
[[ "$SUB_HTTP_PATH" == '/0123456789abcdefghjkmnpqrstvwxyz' ]]
[[ "$SUB_HTTPS_DOMAIN" == 'sub.example.com' ]]
[[ "$SUB_HTTPS_ENABLED" == 1 ]]
[[ "$SUB_HTTPS_DOMAIN_MODE" == separate ]]
[[ "$SUB_TUNNEL_MODE" == remote ]]
[[ ! -e "${work_dir}/pwned" ]]

save_subscription_state
if [[ "$(uname -s)" == MINGW* ]]; then
    grep -Fq 'atomic_write_file "$subscription_state_file" 600' <<< "$(extract_function save_subscription_state)"
else
    [[ "$(stat -c '%a' "$subscription_state_file")" == 600 ]]
fi
! grep -q '^EVIL=' "$subscription_state_file"

cat > "$subscription_state_file" <<'STATE'
SUB_TOKEN=invalid
SUB_HTTP_PATH=/invalid
SUB_HTTPS_ENABLED=1
SUB_HTTPS_DOMAIN=https://bad.example.com/
SUB_HTTPS_DOMAIN_MODE=unknown
SUB_HTTPS_PATH=/invalid
SUB_TUNNEL_MODE=quick
SUB_HTTPS_VERIFIED_AT=not-a-time
STATE

load_subscription_state
[[ "$SUB_HTTPS_ENABLED" == 0 ]]
[[ -z "$SUB_TOKEN" ]]
[[ -z "$SUB_HTTPS_DOMAIN" ]]
[[ -z "$SUB_HTTPS_VERIFIED_AT" ]]

echo 'Subscription state tests passed.'
