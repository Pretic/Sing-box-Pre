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
    atomic_write_secret_file write_argo_systemd_service \
    use_quick_argo_fallback is_valid_ipv4_address is_valid_ipv6_address \
    is_valid_endpoint_hostname parse_cfip_endpoint format_vless_endpoint \
    rebuild_argo_client_address_set_file get_current_argo_preferred_endpoint \
    create_argo_transition_snapshot restore_argo_transition_snapshot \
    strip_local_tunnel_subscription_rule remove_local_tunnel_subscription_rule \
    apply_local_tunnel_subscription_removal \
    activate_argo_service_mode transition_to_quick_argo transition_to_fixed_argo; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    source <(printf '%s\n' "$function_source")
done

root="${tmp_dir}/root"
work_dir="${root}/etc/sing-box"
client_dir="${work_dir}/url.txt"
subscription_state_file="${work_dir}/subscription.conf"
NGINX_SUBSCRIPTION_CONF="${root}/etc/nginx/conf.d/sing-box.conf"
ARGO_TRANSITION_ROOT="$root"
ARGO_PORT=18001
CFIP=default-edge.example.com
CFPORT=443

mkdir -p "${root}/etc/systemd/system" "${root}/etc/nginx/conf.d" "$work_dir"
printf '%s\n' '#!/bin/sh' 'exit 0' > "${work_dir}/argo"
chmod 700 "${work_dir}/argo"
cat > "${root}/etc/systemd/system/argo.service" <<'EOF'
[Service]
EnvironmentFile=-/etc/sing-box/argo.env
ExecStart=/etc/sing-box/argo tunnel --no-autoupdate run
EOF
printf '%s\n' 'TUNNEL_TOKEN=old-token' > "${work_dir}/argo.env"
printf '%s\n' '{"TunnelID":"fixture"}' > "${work_dir}/tunnel.json"
cat > "${work_dir}/tunnel.yml" <<'EOF'
tunnel: fixture
credentials-file: /etc/sing-box/tunnel.json
ingress:
  # sing-box-subscription:start
  - hostname: fixed.example.com
    path: ^/sub/token$
    service: http://127.0.0.1:18080
  # sing-box-subscription:end
  - hostname: fixed.example.com
    service: http://127.0.0.1:18001
  - service: http_status:404
EOF
cat > "$client_dir" <<'EOF'
vless://id@fixed.example.com:443?security=tls&sni=fixed.example.com&type=ws&host=fixed.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo
vless://id@user-edge.example.com:8443?security=tls&sni=fixed.example.com&type=ws&host=fixed.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo-preferred
EOF
printf '%s\n' 'nginx-with-https' > "$NGINX_SUBSCRIPTION_CONF"
printf '%s\n' enabled > "$subscription_state_file"

ARGO_DOMAIN=fixed.example.com
ARGO_AUTH=old-token
ARGO_FIXED_READY=1
ArgoDomain=fixed.example.com

detect_usable_init_system() { printf 'systemd\n'; }
detected_mode=local
detect_argo_tunnel_mode() { printf '%s\n' "$detected_mode"; }
systemctl() { return 0; }
restart_argo() { return 0; }
get_quick_tunnel() { ArgoDomain=quick.trycloudflare.com; }
change_argo_domain() { return 0; }
update_sub() { return 0; }
load_subscription_state() {
    if [[ "$(< "$subscription_state_file")" == disabled ]]; then
        SUB_TOKEN=token
        SUB_HTTP_PATH=/token
        SUB_HTTPS_ENABLED=0
        SUB_HTTPS_DOMAIN=''
        SUB_HTTPS_DOMAIN_MODE=''
        SUB_HTTPS_PATH=''
        SUB_TUNNEL_MODE=''
        SUB_HTTPS_VERIFIED_AT=''
    else
        SUB_TOKEN=token
        SUB_HTTP_PATH=/token
        SUB_HTTPS_ENABLED=1
        SUB_HTTPS_DOMAIN=fixed.example.com
        SUB_HTTPS_DOMAIN_MODE=reuse
        SUB_HTTPS_PATH=/sub/token
        SUB_TUNNEL_MODE=local
        SUB_HTTPS_VERIFIED_AT=now
    fi
}
save_subscription_state() {
    if [[ "${SUB_HTTPS_ENABLED:-0}" == 0 ]]; then
        printf '%s\n' disabled > "$subscription_state_file"
    else
        printf '%s\n' enabled > "$subscription_state_file"
    fi
}
disable_cf_https_subscription() {
    load_subscription_state
    [ "${SUB_HTTPS_ENABLED:-0}" = 1 ] || return 0
    [ "${SUB_TUNNEL_MODE:-}" = local ] || return 1
    apply_local_tunnel_subscription_removal "${work_dir}/tunnel.yml" || return $?
    SUB_HTTPS_ENABLED=0
    SUB_HTTPS_DOMAIN=''
    SUB_HTTPS_DOMAIN_MODE=''
    SUB_HTTPS_PATH=''
    SUB_TUNNEL_MODE=''
    SUB_HTTPS_VERIFIED_AT=''
    save_subscription_state
}
get_nginx_subscription_port() { printf '18080\n'; }
get_nginx_subscription_paths() { printf '/token\n'; }
is_valid_http_subscription_path() { return 0; }
apply_nginx_subscription_config() {
    if [[ -n "${3:-}" ]]; then
        printf '%s\n' nginx-with-https > "$NGINX_SUBSCRIPTION_CONF"
    else
        printf '%s\n' nginx-http-only > "$NGINX_SUBSCRIPTION_CONF"
    fi
}
nginx() { return 0; }
restart_nginx() { return 0; }
red() { printf '%s\n' "$*" >&2; }
yellow() { :; }
green() { :; }

# Replacing one fixed Tunnel with another while HTTPS is still enabled cannot
# be migrated without Cloudflare credentials or a manual route action. It must
# fail before changing service, credentials, subscription source, or state.
before_service="$(< "${root}/etc/systemd/system/argo.service")"
before_client="$(< "$client_dir")"
before_tunnel="$(< "${work_dir}/tunnel.yml")"
set +e
fixed_output="$(transition_to_fixed_argo fixed2.example.com token new-token 2>&1)"
fixed_status=$?
set -e
[[ "$fixed_status" -ne 0 ]] || fail 'fixed-to-fixed replacement ignored active HTTPS state'
[[ "$fixed_output" == *'先关闭'*HTTPS* ]] || \
    fail 'fixed-to-fixed rejection did not explain that HTTPS must be disabled first'
[[ "$(< "${root}/etc/systemd/system/argo.service")" == "$before_service" ]] || \
    fail 'fixed-to-fixed rejection changed the service definition'
[[ "$(< "$client_dir")" == "$before_client" ]] || \
    fail 'fixed-to-fixed rejection changed the subscription source'
[[ "$(< "${work_dir}/tunnel.yml")" == "$before_tunnel" ]] || \
    fail 'fixed-to-fixed rejection changed the Tunnel configuration'
[[ "$(< "$subscription_state_file")" == enabled ]] || \
    fail 'fixed-to-fixed rejection changed HTTPS state'

# Token-managed fixed Tunnels are reported as remote/unknown by different
# service detectors. Active HTTPS state is authoritative, so they must be
# rejected by the same side-effect-free preflight.
detected_mode=remote
set +e
remote_output="$(transition_to_fixed_argo fixed3.example.com token newer-token 2>&1)"
remote_status=$?
set -e
[[ "$remote_status" -ne 0 ]] || fail 'remote fixed-to-fixed replacement ignored active HTTPS state'
[[ "$remote_output" == *'先关闭'*HTTPS* ]] || \
    fail 'remote fixed-to-fixed rejection did not explain that HTTPS must be disabled first'
[[ "$(< "${root}/etc/systemd/system/argo.service")" == "$before_service" ]] || \
    fail 'remote fixed-to-fixed rejection changed the service definition'
[[ "$(< "$client_dir")" == "$before_client" ]] || \
    fail 'remote fixed-to-fixed rejection changed the subscription source'
[[ "$(< "$subscription_state_file")" == enabled ]] || \
    fail 'remote fixed-to-fixed rejection changed HTTPS state'

# A local fixed Tunnel with HTTPS enabled must be able to switch to a quick
# Tunnel in one transaction. The implementation must keep tunnel.yml available
# until the HTTPS ingress has been removed, then delete fixed credentials.
detected_mode=local
transition_to_quick_argo >/dev/null 2>&1 || \
    fail 'local fixed+HTTPS could not switch to a quick Tunnel'
[[ "$(< "$subscription_state_file")" == disabled ]] || \
    fail 'HTTPS state stayed enabled after switching to a quick Tunnel'
[[ ! -e "${work_dir}/tunnel.yml" && ! -e "${work_dir}/tunnel.json" && \
   ! -e "${work_dir}/argo.env" ]] || \
    fail 'fixed Tunnel credentials survived a successful quick transition'
grep -Fq '@user-edge.example.com:8443?' "$client_dir" || \
    fail 'the user-selected preferred endpoint was lost during the transition'

# Refreshing one quick Tunnel into another has no separate preferred record.
# Its current stable endpoint is nevertheless the user's working fallback and
# must be carried forward instead of being silently replaced by the script
# default.
detected_mode=quick
cat > "$client_dir" <<'EOF'
vless://id@old-quick.trycloudflare.com:443?security=tls&sni=old-quick.trycloudflare.com&type=ws&host=old-quick.trycloudflare.com&path=%2Fvless-argo#Node-vless-ws-tls-argo
EOF
transition_to_quick_argo >/dev/null 2>&1 || \
    fail 'quick-to-quick Tunnel refresh failed'
grep -Fq '@old-quick.trycloudflare.com:443?' "$client_dir" || \
    fail 'quick-to-quick refresh lost the current stable endpoint'

printf 'Argo HTTPS mode matrix tests passed.\n'
