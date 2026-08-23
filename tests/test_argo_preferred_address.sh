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

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

for function_name in is_valid_ipv4_address is_valid_ipv6_address is_valid_endpoint_hostname parse_cfip_endpoint format_vless_endpoint update_argo_preferred_address_file; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    source <(printf '%s\n' "$function_source")
done

assert_parse() {
    local expected="$1"
    shift
    local actual
    actual="$(parse_cfip_endpoint "$@")" || fail "parse rejected valid endpoint: $*"
    [[ "$actual" == "$expected" ]] || \
        fail "parse mismatch for '$*': expected '$expected', got '$actual'"
}

assert_parse $'cdns.doon.eu.org\t443' 4
assert_parse $'edge.example.com\t8443' edge.example.com:8443
assert_parse $'203.0.113.7\t2053' 203.0.113.7:2053
assert_parse $'2606:4700:4700::1111\t8443' '[2606:4700:4700::1111]:8443'
assert_parse $'2606:4700:4700::1111\t443' '2606:4700:4700::1111'
if parse_cfip_endpoint 'edge.example.com:0' >/dev/null 2>&1 || \
   parse_cfip_endpoint '[2606:4700::1111]:70000' >/dev/null 2>&1 || \
   parse_cfip_endpoint 'https://edge.example.com' >/dev/null 2>&1 || \
   parse_cfip_endpoint '::::' >/dev/null 2>&1 || \
   parse_cfip_endpoint 'foo..bar' >/dev/null 2>&1 || \
   parse_cfip_endpoint '999.1.1.1' >/dev/null 2>&1 || \
   parse_cfip_endpoint '[2606:4700:::1111]:443' >/dev/null 2>&1; then
    fail 'unsafe or invalid endpoint was accepted'
fi

[[ "$(format_vless_endpoint '2606:4700:4700::1111' 8443)" == '[2606:4700:4700::1111]:8443' ]] || \
    fail 'IPv6 VLESS endpoint is not bracketed'
[[ "$(format_vless_endpoint 'edge.example.com' 443)" == 'edge.example.com:443' ]] || \
    fail 'hostname VLESS endpoint was formatted incorrectly'

fixed_file="${tmp_dir}/fixed.txt"
cat > "$fixed_file" <<'EOF'
vless://id@fixed.example.com:443?encryption=none&path=%2Fvless-argo#Node-vless-ws-tls-argo
vless://id@old.example.com:443?encryption=none&path=%2Fvless-argo#Node-vless-ws-tls-argo-preferred
vless://id@direct.example.com:443?encryption=none&type=tcp#Node-reality
EOF
update_argo_preferred_address_file "$fixed_file" '2606:4700:4700::1111' 8443 fixed || \
    fail 'fixed Tunnel preferred address update failed'
grep -Fqx 'vless://id@fixed.example.com:443?encryption=none&path=%2Fvless-argo#Node-vless-ws-tls-argo' "$fixed_file" || \
    fail 'fixed Tunnel stable hostname was overwritten'
grep -Fqx 'vless://id@[2606:4700:4700::1111]:8443?encryption=none&path=%2Fvless-argo#Node-vless-ws-tls-argo-preferred' "$fixed_file" || \
    fail 'fixed Tunnel preferred IPv6 endpoint was not updated'
grep -Fqx 'vless://id@direct.example.com:443?encryption=none&type=tcp#Node-reality' "$fixed_file" || \
    fail 'non-Argo node was modified'

quick_file="${tmp_dir}/quick.txt"
printf '%s\n' 'vless://id@old.example.com:443?encryption=none&path=%2Fvless-argo#Node-vless-ws-tls-argo' > "$quick_file"
update_argo_preferred_address_file "$quick_file" edge.example.com 2053 quick || \
    fail 'quick Tunnel address update failed'
grep -Fqx 'vless://id@edge.example.com:2053?encryption=none&path=%2Fvless-argo#Node-vless-ws-tls-argo' "$quick_file" || \
    fail 'quick Tunnel address was not updated'

fixed_stable_only="${tmp_dir}/fixed-stable-only.txt"
printf '%s\n' 'vless://id@fixed.example.com:443?encryption=none&path=%2Fvless-argo#Node-vless-ws-tls-argo' > "$fixed_stable_only"
update_argo_preferred_address_file "$fixed_stable_only" edge.example.com 2053 fixed || \
    fail 'fixed Tunnel with only a stable entry rejected a preferred endpoint'
grep -Fqx 'vless://id@fixed.example.com:443?encryption=none&path=%2Fvless-argo#Node-vless-ws-tls-argo' "$fixed_stable_only" || \
    fail 'fixed-only stable hostname was overwritten'
grep -Fqx 'vless://id@edge.example.com:2053?encryption=none&path=%2Fvless-argo#Node-vless-ws-tls-argo-preferred' "$fixed_stable_only" || \
    fail 'fixed-only stable entry did not gain a separate preferred endpoint'
[[ "$(grep -Fc 'path=%2Fvless-argo' "$fixed_stable_only")" == 2 ]] || \
    fail 'fixed-only stable entry produced the wrong address count'

if update_argo_preferred_address_file "$quick_file" edge.example.com 443 unknown >/dev/null 2>&1; then
    fail 'unknown Argo mode was accepted for preferred endpoint update'
fi

printf 'Argo preferred address tests passed.\n'
