#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
work_dir="$tmp_dir"
subscription_state_file="${work_dir}/subscription.conf"

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

assert_rejected() {
    local description="$1"
    shift
    if "$@"; then
        echo "FAIL: accepted ${description}" >&2
        exit 1
    fi
}

for function_name in \
    format_url_host \
    is_valid_subscription_token \
    is_valid_subscription_domain \
    is_valid_subscription_path \
    is_valid_http_subscription_path \
    atomic_write_file \
    reset_subscription_state \
    load_subscription_state \
    get_nginx_subscription_port \
    get_nginx_subscription_paths \
    select_nginx_http_subscription_path \
    build_http_subscription_url \
    build_https_subscription_url \
    resolve_subscription_source_url \
    resolve_installed_subscription_source_url \
    render_terminal_qr \
    show_subscription_links; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
    source <(printf '%s\n' "$function_source")
done

url="$(build_http_subscription_url '2001:db8::1' 8080 '/0123456789abcdefghjkmnpqrstvwxyz')"
[[ "$url" == 'http://[2001:db8::1]:8080/0123456789abcdefghjkmnpqrstvwxyz' ]]
[[ "$(build_http_subscription_url '203.0.113.10' 80 '/LegacySubscriptionPath123')" == \
   'http://203.0.113.10/LegacySubscriptionPath123' ]]
assert_rejected 'HTTP URL without port' build_http_subscription_url '203.0.113.10' '' '/0123456789abcdefghjkmnpqrstvwxyz'
assert_rejected 'HTTP URL without host' build_http_subscription_url '' 8080 '/0123456789abcdefghjkmnpqrstvwxyz'
assert_rejected 'HTTP URL with invalid port' build_http_subscription_url '203.0.113.10' 70000 '/0123456789abcdefghjkmnpqrstvwxyz'
assert_rejected 'HTTP URL with path traversal' build_http_subscription_url '203.0.113.10' 8080 '/../etc/passwd'

[[ "$(build_https_subscription_url 'Sub.Example.com' '/0123456789abcdefghjkmnpqrstvwxyz')" == \
   'https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' ]]
assert_rejected 'HTTPS URL with protocol in domain' \
    build_https_subscription_url 'https://sub.example.com' '/0123456789abcdefghjkmnpqrstvwxyz'

SUB_HTTPS_ENABLED=1
SUB_HTTPS_DOMAIN='sub.example.com'
SUB_HTTPS_PATH='/0123456789abcdefghjkmnpqrstvwxyz'
SUB_HTTPS_VERIFIED_AT='2026-08-15T00:00:00Z'
[[ "$(resolve_subscription_source_url '203.0.113.10' 8080 '/LegacySubscriptionPath123')" == \
   'https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' ]]

SUB_HTTPS_ENABLED=0
[[ "$(resolve_subscription_source_url '203.0.113.10' 8080 '/LegacySubscriptionPath123')" == \
   'http://203.0.113.10:8080/LegacySubscriptionPath123' ]]

SUB_HTTPS_ENABLED=1
SUB_HTTPS_DOMAIN='bad/domain'
SUB_HTTPS_PATH='/invalid'
SUB_HTTPS_VERIFIED_AT='2026-08-15T00:00:00Z'
[[ "$(resolve_subscription_source_url '203.0.113.10' 8080 '/LegacySubscriptionPath123')" == \
   'http://203.0.113.10:8080/LegacySubscriptionPath123' ]]

assert_rejected 'subscription source without valid HTTPS or HTTP data' \
    resolve_subscription_source_url '203.0.113.10' '' ''

nginx_fixture="${tmp_dir}/sing-box.conf"
cat > "$nginx_fixture" <<'NGINX'
server {
    listen 8080;
    listen [::]:8080;
    location = /LegacySubscriptionPath123 {
        alias /etc/sing-box/sub.txt;
    }
}
NGINX
rm -f "$subscription_state_file"
[[ "$(resolve_installed_subscription_source_url '203.0.113.10' "$nginx_fixture")" == \
   'http://203.0.113.10:8080/LegacySubscriptionPath123' ]]

token='0123456789abcdefghjkmnpqrstvwxyz'
cat > "$nginx_fixture" <<NGINX
server {
    listen 8080;
    listen [::]:8080;
    location = /${token} { alias /etc/sing-box/sub.txt; }
    location = /sub/${token} { alias /etc/sing-box/sub.txt; }
}
NGINX
cat > "$subscription_state_file" <<STATE
SUB_TOKEN=${token}
SUB_HTTP_PATH=/${token}
SUB_HTTPS_ENABLED=1
SUB_HTTPS_DOMAIN=sub.example.com
SUB_HTTPS_DOMAIN_MODE=separate
SUB_HTTPS_PATH=/${token}
SUB_TUNNEL_MODE=remote
SUB_HTTPS_VERIFIED_AT=2026-08-15T00:00:00Z
STATE
[[ "$(select_nginx_http_subscription_path "$nginx_fixture")" == "/${token}" ]]
[[ "$(resolve_installed_subscription_source_url '203.0.113.10' "$nginx_fixture")" == \
   "https://sub.example.com/${token}" ]]

sed -i 's/SUB_HTTPS_VERIFIED_AT=.*/SUB_HTTPS_VERIFIED_AT=invalid/' "$subscription_state_file"
[[ "$(resolve_installed_subscription_source_url '203.0.113.10' "$nginx_fixture")" == \
   "http://203.0.113.10:8080/${token}" ]]
assert_rejected 'installed subscription without nginx config' \
    resolve_installed_subscription_source_url '203.0.113.10' "${tmp_dir}/missing.conf"

installed_source="$(extract_function resolve_installed_subscription_source_url)"
if grep -Fq 'curl ' <<< "$installed_source"; then
    echo 'FAIL: installed subscription resolver probes public HTTP reachability (breaks NAT semantics)' >&2
    exit 1
fi

check_source="$(extract_function check_nodes)"
grep -Fq 'resolve_installed_subscription_source_url' <<< "$check_source"
if grep -Fq 'base64_url="http://${server_ip}:${sub_port}/${lujing}"' <<< "$check_source"; then
    echo 'FAIL: check_nodes still constructs malformed subscription URLs directly' >&2
    exit 1
fi

status_source="$(extract_function show_subscription_status)"
grep -Fq 'resolve_installed_subscription_source_url' <<< "$status_source" || {
    echo 'FAIL: subscription status bypasses the installed subscription resolver' >&2
    exit 1
}

install_flow_source="$(extract_function run_install_flow)"
add_line="$(grep -n 'add_nginx_conf' <<< "$install_flow_source" | head -1 | cut -d: -f1)"
info_line="$(grep -n 'get_info' <<< "$install_flow_source" | head -1 | cut -d: -f1)"
[[ -n "$add_line" && -n "$info_line" && "$add_line" -lt "$info_line" ]] || {
    echo 'FAIL: shared install flow prints subscription links before nginx configuration exists' >&2
    exit 1
}

qr_source="$(extract_function render_terminal_qr)"
grep -Fq '"$encoder" -t ANSIUTF8 -m 1 -- "$url"' <<< "$qr_source"
if grep -nE '^[[:space:]]*(\[[^]]+\][[:space:]]*&&[[:space:]]*)?("\$\{work_dir\}/qrencode"|\$work_dir/qrencode)[[:space:]]+"' "$script"; then
    echo 'FAIL: direct qrencode invocation remains outside render_terminal_qr' >&2
    exit 1
fi

green() { printf '%b\n' "$1"; }
yellow() { printf '%b\n' "$1"; }
purple=''
re=''
work_dir='/nonexistent'

links="$(show_subscription_links 'https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz')"
grep -Fq 'https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' <<< "$links"
grep -Fq 'https://sublink.eooce.com/clash?config=https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' <<< "$links"
grep -Fq 'https://sublink.eooce.com/singbox?config=https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' <<< "$links"
grep -Fq 'https://sublink.eooce.com/surge?config=https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' <<< "$links"

empty_links="$(show_subscription_links '')"
grep -Fq '订阅未配置' <<< "$empty_links"
if grep -Fq 'config=' <<< "$empty_links"; then
    echo 'FAIL: empty subscription generated converter links' >&2
    exit 1
fi

echo 'Subscription URL and QR tests passed.'
