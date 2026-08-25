#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

assert_rejected() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: accepted ${description}" >&2
        exit 1
    fi
}

for function_name in \
    is_valid_subscription_path \
    is_valid_http_subscription_path \
    render_nginx_subscription_location \
    render_nginx_subscription_server \
    get_nginx_subscription_port \
    get_nginx_subscription_paths; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
    source <(printf '%s\n' "$function_source")
done

token='0123456789abcdefghjkmnpqrstvwxyz'
config="$(render_nginx_subscription_server 8080 "/${token}" "/sub/${token}")"

grep -Fq 'listen 8080;' <<< "$config"
grep -Fq 'listen [::]:8080;' <<< "$config"
[[ "$(grep -Fc 'alias /etc/sing-box/sub.txt;' <<< "$config")" == 2 ]]
grep -Fq "location = /${token} {" <<< "$config"
grep -Fq "location = /sub/${token} {" <<< "$config"
grep -Fq 'add_header Cache-Control "private, no-store";' <<< "$config"
grep -Fq 'add_header X-Content-Type-Options nosniff;' <<< "$config"
grep -Fq 'access_log off;' <<< "$config"
grep -Fq 'location / { return 404; }' <<< "$config"
if grep -Fq 'autoindex on' <<< "$config"; then
    echo 'FAIL: nginx config enables directory indexing' >&2
    exit 1
fi

same_path="$(render_nginx_subscription_server 8080 "/${token}" "/${token}")"
[[ "$(grep -Fc 'alias /etc/sing-box/sub.txt;' <<< "$same_path")" == 1 ]]

legacy="$(render_nginx_subscription_server 8080 '/LegacySubscriptionPath123' '')"
grep -Fq 'location = /LegacySubscriptionPath123 {' <<< "$legacy"

nginx_fixture="$(mktemp)"
trap 'rm -f "$nginx_fixture"' EXIT
printf '%s\n' "$config" > "$nginx_fixture"
[[ "$(get_nginx_subscription_port "$nginx_fixture")" == 8080 ]]
expected_paths="/${token}
/sub/${token}"
[[ "$(get_nginx_subscription_paths "$nginx_fixture")" == "$expected_paths" ]]

assert_rejected 'nginx port zero' render_nginx_subscription_server 0 "/${token}" ''
assert_rejected 'nginx port above 65535' render_nginx_subscription_server 65536 "/${token}" ''
assert_rejected 'unsafe HTTP path' render_nginx_subscription_server 8080 '/../etc/passwd' ''
assert_rejected 'unsafe HTTPS path' render_nginx_subscription_server 8080 "/${token}" '/sub/short'

apply_source="$(extract_function apply_nginx_subscription_config)"
[[ -n "$apply_source" ]] || {
    echo 'FAIL: apply_nginx_subscription_config is not implemented' >&2
    exit 1
}
grep -Fq 'nginx -t' <<< "$apply_source"
grep -Fq '.bak.sb' <<< "$apply_source"
source <(printf '%s\n' "$apply_source")

rollback_dir="$(mktemp -d)"
rollback_config="${rollback_dir}/sing-box.conf"
NGINX_SUBSCRIPTION_CONF="$rollback_config"
command_exists() { [[ "$1" == nginx ]]; }
detect_usable_init_system() { printf 'systemd\n'; }
nginx() { [[ "${1:-}" == -t ]]; }
systemctl() { return 1; }
if apply_nginx_subscription_config 8080 "/${token}" ''; then
    echo 'FAIL: nginx apply succeeded despite reload/start failure' >&2
    exit 1
fi
[[ ! -e "$rollback_config" ]] || {
    echo 'FAIL: failed first-time nginx configuration was left behind' >&2
    exit 1
}
rm -rf "$rollback_dir"

add_source="$(extract_function add_nginx_conf)"
if grep -Fq 'pkill nginx' <<< "$add_source" || grep -Fq 'manage_service "nginx" "stop"' <<< "$add_source"; then
    echo 'FAIL: add_nginx_conf interrupts a healthy nginx before validation' >&2
    exit 1
fi

menu_source="$(extract_function disable_open_sub)"
grep -Fq 'stop_subscription_service_transaction' <<< "$menu_source"
for status_call in \
    restart_subscription_service_transaction \
    configure_cf_https_subscription \
    disable_cf_https_subscription \
    rotate_subscription_token; do
    grep -Fq "${status_call} || return \$?" <<< "$menu_source" || {
        echo "FAIL: subscription menu hides ${status_call} failure status" >&2
        exit 1
    }
done
if grep -Fq 'sed -i "s|\(location = /\)' <<< "$menu_source" || \
   grep -Fq "sed -i 's/listen" <<< "$menu_source"; then
    echo 'FAIL: subscription menu edits nginx configuration without transaction validation' >&2
    exit 1
fi

# Every path that rewrites an existing subscription server must first prove
# that the exact config is script-managed.  A parseable listen/location pair
# alone must never authorize overwriting a user's custom Nginx server.
for managed_writer in \
    _configure_cf_https_subscription_locked \
    _disable_cf_https_subscription_locked \
    _rotate_subscription_token_locked; do
    managed_source="$(extract_function "$managed_writer")"
    grep -Fq 'validate_managed_subscription_runtime' <<< "$managed_source" || {
        echo "FAIL: ${managed_writer} bypasses managed Nginx runtime validation" >&2
        exit 1
    }
done
configure_source="$(extract_function _configure_cf_https_subscription_locked)"
grep -Fq 'NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf' <<< "$configure_source" || {
    echo 'FAIL: HTTPS configuration ignores the configured Nginx subscription path' >&2
    exit 1
}

echo 'Subscription nginx tests passed.'
