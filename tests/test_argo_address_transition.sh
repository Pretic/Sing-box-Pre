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

for function_name in format_vless_endpoint rebuild_argo_client_address_set_file; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    source <(printf '%s\n' "$function_source")
done

base_query='?encryption=none&security=tls&sni=quick.trycloudflare.com&type=ws&host=quick.trycloudflare.com&path=%2Fvless-argo'

quick_file="${tmp_dir}/quick.txt"
cat > "$quick_file" <<EOF
vless://id@edge.example.com:443${base_query}#Node-vless-ws-tls-argo
vless://id@direct.example.com:443?security=reality&type=tcp#Node-reality
EOF
rebuild_argo_client_address_set_file "$quick_file" fixed fixed.example.com edge.example.com 443 || \
    fail 'quick-to-fixed address rebuild failed'
grep -Fqx "vless://id@fixed.example.com:443${base_query}#Node-vless-ws-tls-argo" "$quick_file" || \
    fail 'fixed Tunnel stable entry was not created'
grep -Fqx "vless://id@edge.example.com:443${base_query}#Node-vless-ws-tls-argo-preferred" "$quick_file" || \
    fail 'fixed Tunnel preferred fallback was not created'
[[ "$(grep -Fc 'path=%2Fvless-argo' "$quick_file")" == 2 ]] || \
    fail 'quick-to-fixed rebuild produced the wrong Argo entry count'

rebuild_argo_client_address_set_file "$quick_file" quick quick2.trycloudflare.com edge2.example.com 2053 || \
    fail 'fixed-to-quick address rebuild failed'
grep -Fqx "vless://id@edge2.example.com:2053${base_query}#Node-vless-ws-tls-argo" "$quick_file" || \
    fail 'quick Tunnel fallback entry was not restored'
[[ "$(grep -Fc 'path=%2Fvless-argo' "$quick_file")" == 1 ]] || \
    fail 'fixed-to-quick rebuild retained a stale fixed/preferred duplicate'
grep -Fqx 'vless://id@direct.example.com:443?security=reality&type=tcp#Node-reality' "$quick_file" || \
    fail 'address-set rebuild modified a non-Argo node'

ipv6_file="${tmp_dir}/ipv6.txt"
printf '%s\n' "vless://id@edge.example.com:443${base_query}#Node-vless-ws-tls-argo" > "$ipv6_file"
rebuild_argo_client_address_set_file "$ipv6_file" fixed fixed.example.com '2606:4700:4700::1111' 8443 || \
    fail 'IPv6 preferred address rebuild failed'
grep -Fq '@fixed.example.com:8443?' "$ipv6_file" || \
    fail 'fixed stable address did not retain the configured Cloudflare port'
grep -Fq '@[2606:4700:4700::1111]:8443?' "$ipv6_file" || \
    fail 'IPv6 preferred address is not bracketed'

printf 'Argo address transition tests passed.\n'
