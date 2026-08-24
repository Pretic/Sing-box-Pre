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

for function_name in \
    is_valid_ipv4_address is_valid_ipv6_address is_valid_endpoint_hostname \
    parse_cfip_endpoint format_vless_endpoint update_argo_preferred_address_file \
    update_vless_argo_domain_file update_argo_subscription_file update_cfip_subscription_file \
    update_vless_argo_domain change_argo_domain change_cfip; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    source <(printf '%s\n' "$function_source")
done

clear() { :; }
green() { :; }
yellow() { :; }
red() { :; }
purple() { :; }
command_exists() { return 1; }
publish_attempts=0
update_sub() { publish_attempts=$((publish_attempts + 1)); return 1; }
mutate_base_subscription() {
    local callback="$1" staged_file publish_status
    shift
    staged_file=$(mktemp "${work_dir}/.argo-publish-fixture.XXXXXX") || return 1
    cp -p -- "$client_dir" "$staged_file" || { rm -f -- "$staged_file"; return 1; }
    "$callback" "$staged_file" "$@" || { rm -f -- "$staged_file"; return 1; }
    if update_sub "$staged_file"; then
        mv -f -- "$staged_file" "$client_dir"
    else
        publish_status=$?
        rm -f -- "$staged_file"
        return "$publish_status"
    fi
}
detect_argo_tunnel_mode() { printf 'local\n'; }
reading() { cfip_input='new.example.com:8443'; }
purple=''
re=''

work_dir="${tmp_dir}/work"
mkdir -p "$work_dir"
client_dir="${work_dir}/url.txt"
cat > "$client_dir" <<'EOF'
vless://id@stable.example.com:443?encryption=none&security=tls&sni=old.example.com&type=ws&host=old.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo
vless://id@old-edge.example.com:443?encryption=none&security=tls&sni=old.example.com&type=ws&host=old.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo-preferred
EOF
cp "$client_dir" "${work_dir}/cfy-url.txt"

before_base="$(command cat "$client_dir")"
before_cfy="$(command cat "${work_dir}/cfy-url.txt")"
if change_cfip >/dev/null 2>&1; then
    fail 'change_cfip reported success after subscription publication failed'
fi
[[ "$publish_attempts" -ge 1 ]] || fail 'change_cfip never attempted subscription publication'
[[ "$(command cat "$client_dir")" == "$before_base" ]] || \
    fail 'change_cfip left the base source modified after publish failure'
[[ "$(command cat "${work_dir}/cfy-url.txt")" == "$before_cfy" ]] || \
    fail 'change_cfip left the cfy source modified after publish failure'

ArgoDomain='new-quick.trycloudflare.com'
publish_attempts=0
if change_argo_domain >/dev/null 2>&1; then
    fail 'change_argo_domain reported success after subscription publication failed'
fi
[[ "$publish_attempts" -ge 1 ]] || fail 'change_argo_domain never attempted subscription publication'
[[ "$(command cat "$client_dir")" == "$before_base" ]] || \
    fail 'change_argo_domain left the base source modified after publish failure'
[[ "$(command cat "${work_dir}/cfy-url.txt")" == "$before_cfy" ]] || \
    fail 'change_argo_domain left the cfy source modified after publish failure'

printf 'Argo publication failure tests passed.\n'
