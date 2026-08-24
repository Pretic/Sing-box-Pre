#!/bin/bash

# =========================
# 老王sing-box四合一安装脚本
# vless-version-reality|vless-ws-tls(tunnel)|hysteria2|tuic5|[可额外添加Anytls，socks5，ss2022等协议]
# 最后更新时间: 2026.8.15[修复WARP共享身份冲突与空闲失活]
# =========================

export LANG=en_US.UTF-8
umask 077
# 定义颜色
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }
reading_secret() {
    local prompt="$1"
    local variable_name="$2"

    read -rs -p "$(red "$prompt")" "$variable_name"
    printf '\n'
}

validate_port_value() {
    local value="${1:-}"
    local label="${2:-port}"

    [[ "$value" =~ ^[1-9][0-9]*$ ]] && \
        [ "$value" -ge 1 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null || {
        echo "${label} 必须是 1-65535 的整数。" >&2
        return 1
    }
}

resolve_service_ports() {
    local base_port="${PORT:-}"
    local label value variable_name proto seen_tcp=' ' seen_udp=' '

    validate_port_value "$base_port" PORT || return 1
    vless_port="${REALITY_PORT:-$base_port}"
    nginx_port="${NGINX_PORT:-$((10#$base_port + 1))}"
    tuic_port="${TUIC_PORT:-$((10#$base_port + 2))}"
    hy2_port="${HY2_PORT:-$((10#$base_port + 3))}"
    argo_port="${ARGO_PORT:-8001}"

    for label in vless nginx tuic hy2 argo; do
        variable_name="${label}_port"
        value="${!variable_name}"
        validate_port_value "$value" "${label}_port" || return 1
        case "$label" in
            vless|nginx|argo) proto=tcp ;;
            tuic|hy2) proto=udp ;;
            *) return 1 ;;
        esac
        if [ "$proto" = tcp ]; then
            case "$seen_tcp" in
                *" $value "*) echo "TCP 端口重复: $value" >&2; return 1 ;;
            esac
            seen_tcp="${seen_tcp}${value} "
        else
            case "$seen_udp" in
                *" $value "*) echo "UDP 端口重复: $value" >&2; return 1 ;;
            esac
            seen_udp="${seen_udp}${value} "
        fi
    done

    export vless_port nginx_port tuic_port hy2_port argo_port
    export ARGO_PORT="$argo_port"
}

get_listener_address() {
    local has_v4="${1:-0}"
    local has_v6="${2:-0}"
    local bindv6only="${3:-0}"

    [[ "$has_v4" =~ ^[01]$ && "$has_v6" =~ ^[01]$ && "$bindv6only" =~ ^[01]$ ]] || return 1
    if [ "$has_v4" = 1 ] && [ "$has_v6" = 1 ] && [ "$bindv6only" = 1 ]; then
        printf '%s\n' '0.0.0.0' '::'
    elif [ "$has_v6" = 1 ] && { [ "$has_v4" = 0 ] || [ "$bindv6only" = 0 ]; }; then
        printf '%s\n' '::'
    elif [ "$has_v4" = 1 ]; then
        printf '%s\n' '0.0.0.0'
    else
        return 1
    fi
}

load_install_settings() {
    local settings_file="${1:-${INSTALL_ENV_FILE:-/etc/sing-box/install.env}}"
    local key value

    [ -r "$settings_file" ] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
            PORT|REALITY_PORT|NGINX_PORT|TUIC_PORT|HY2_PORT|ARGO_PORT) ;;
            ''|'#'*) continue ;;
            *) continue ;;
        esac
        validate_port_value "$value" "$key" || return 1
        if [ -z "${!key:-}" ]; then
            printf -v "$key" '%s' "$value"
            export "$key"
        fi
    done < "$settings_file"
}

# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
combined_client_dir="${work_dir}/all-url.txt"
install_env_file="${INSTALL_ENV_FILE:-${work_dir}/install.env}"
load_install_settings "$install_env_file" || {
    red "install.env 中存在无效端口设置，请修正后重试。"
    exit 1
}
export PORT=${PORT:-$(shuf -i 1000-65000 -n 1)}
export vless_port=${REALITY_PORT:-$PORT}
if [ -n "${CFIP:-}" ]; then
    export CFIP_EXPLICIT=1
else
    export CFIP_EXPLICIT=0
fi
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export ARGO_PORT=${ARGO_PORT:-'8001'}
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}
export ARGO_AUTH=${ARGO_AUTH:-''}
export CFPORT=${CFPORT:-'443'}
export INCLUDE_UDP_LINKS=${INCLUDE_UDP_LINKS:-'0'}
export NODE_NAME=${NODE_NAME:-''}
export PROMPT_NODE_NAME=${PROMPT_NODE_NAME:-'0'}
export SUB_HOST=${SUB_HOST:-''}
export SUB_ADDR_FAMILY=${SUB_ADDR_FAMILY:-'ipv4'}
export PURGE_NGINX=${PURGE_NGINX:-'0'}
ARGO_FIXED_READY=0
subscription_state_file="${work_dir}/subscription.conf"
subscription_token_alphabet='0123456789abcdefghjkmnpqrstvwxyz'

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本，可输入 sudo -i 回车切换到root用户" && exit 1

# 检查命令是否存在函数
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

port_is_listening() {
    local port="${1:-}"
    local proto="${2:-}"

    validate_port_value "$port" port || return 1
    case "$proto" in
        tcp|udp) ;;
        *) return 1 ;;
    esac

    if command_exists ss; then
        if [ "$proto" = tcp ]; then
            ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
        else
            ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
        fi
    elif command_exists lsof; then
        if [ "$proto" = tcp ]; then
            lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q .
        else
            lsof -nP -iUDP:"$port" 2>/dev/null | grep -q .
        fi
    else
        return 1
    fi
}

check_service_ports_available() {
    local rule port proto

    for rule in \
        "$vless_port/tcp" \
        "$nginx_port/tcp" \
        "$tuic_port/udp" \
        "$hy2_port/udp" \
        "$argo_port/tcp"; do
        port="${rule%/*}"
        proto="${rule#*/}"
        if port_is_listening "$port" "$proto"; then
            echo "端口已被占用: ${port}/${proto}" >&2
            return 1
        fi
    done
}

ipv4_stack_available() {
    if command_exists ip; then
        {
            ip -4 route show default 2>/dev/null || true
            ip -4 addr show scope global 2>/dev/null || true
        } | grep -q .
        return $?
    fi
    [ -r /proc/net/route ] && awk 'NR > 1 && ($2 == "00000000" || $8 != "FFFFFFFF") { found=1 } END { exit !found }' /proc/net/route
}

ipv6_socket_available() {
    if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && \
        [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = 1 ]; then
        return 1
    fi
    [ -s /proc/net/if_inet6 ] && return 0
    command_exists ip && ip -6 addr show 2>/dev/null | grep -q 'inet6'
}

ipv6_stack_available() {
    ipv6_socket_available || return 1
    if command_exists ip; then
        {
            ip -6 route show default 2>/dev/null || true
            ip -6 addr show scope global 2>/dev/null || true
        } | grep -q .
        return $?
    fi
    [ -s /proc/net/if_inet6 ]
}

get_bindv6only() {
    local value=0

    if [ -r /proc/sys/net/ipv6/bindv6only ]; then
        value=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || printf '0')
    fi
    [ "$value" = 1 ] && printf '1\n' || printf '0\n'
}

atomic_write_file() {
    local target_file="$1"
    local mode="${2:-644}"
    local target_dir target_name tmp_file

    target_dir=$(dirname "$target_file")
    target_name=$(basename "$target_file")
    mkdir -p "$target_dir" || return 1
    tmp_file=$(mktemp "${target_dir}/.tmp.${target_name}.XXXXXX") || return 1

    if ! cat > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    chmod "$mode" "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$target_file"
}

atomic_write_secret_file() {
    local target_file="$1"

    (
        umask 077
        local target_dir target_name tmp_file
        target_dir=$(dirname "$target_file") || exit 1
        target_name=$(basename "$target_file") || exit 1
        mkdir -p "$target_dir" || exit 1
        tmp_file=$(mktemp "${target_dir}/.tmp.${target_name}.XXXXXX") || exit 1
        if ! cat > "$tmp_file"; then
            rm -f "$tmp_file"
            exit 1
        fi
        if ! chmod 600 "$tmp_file" || ! mv -f "$tmp_file" "$target_file"; then
            rm -f "$tmp_file"
            exit 1
        fi
    )
}

harden_runtime_secret_permissions() {
    local install_root="${1:-}"
    local singbox_dir="${install_root}/etc/sing-box"
    local secret_file

    for secret_file in \
        "${singbox_dir}/conf/inbounds.json" \
        "${singbox_dir}/conf/outbounds.json" \
        "${singbox_dir}/tunnel.json" \
        "${singbox_dir}/tunnel.yml" \
        "${singbox_dir}/argo.env"; do
        [ -e "$secret_file" ] || [ -L "$secret_file" ] || continue
        [ -f "$secret_file" ] && [ ! -L "$secret_file" ] || return 1
        chmod 600 "$secret_file" || return 1
    done
}

write_fixed_argo_credentials() {
    local credential_type="${1:-}"
    local credential_value="${2:-}"
    local install_root="${3:-}"
    local singbox_dir="${install_root}/etc/sing-box"

    case "$credential_type" in
        token)
            [[ "$credential_value" =~ ^[A-Za-z0-9._=-]+$ ]] || return 1
            printf 'TUNNEL_TOKEN=%s\n' "$credential_value" | \
                atomic_write_secret_file "${singbox_dir}/argo.env" || return 1
            ;;
        json)
            [ -n "$credential_value" ] || return 1
            printf '%s\n' "$credential_value" | \
                atomic_write_secret_file "${singbox_dir}/tunnel.json" || return 1
            ;;
        *) return 1 ;;
    esac
}

write_argo_systemd_service() {
    local tunnel_mode="${1:-quick}"
    local install_root="${2:-}"
    local unit_file="${install_root}/etc/systemd/system/argo.service"
    local environment_file=""
    local exec_start

    case "$tunnel_mode" in
        token)
            environment_file='EnvironmentFile=-/etc/sing-box/argo.env'
            exec_start='/etc/sing-box/argo tunnel --no-autoupdate run'
            ;;
        local)
            exec_start='/etc/sing-box/argo tunnel --config /etc/sing-box/tunnel.yml --no-autoupdate run'
            ;;
        quick)
            exec_start="/bin/sh -c '/etc/sing-box/argo tunnel --url http://127.0.0.1:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1'"
            ;;
        *) return 1 ;;
    esac

    {
        printf '%s\n' \
            '[Unit]' \
            'Description=Cloudflare Tunnel' \
            'After=network.target' \
            '' \
            '[Service]' \
            'Type=simple' \
            'NoNewPrivileges=yes' \
            'TimeoutStartSec=0'
        [ -z "$environment_file" ] || printf '%s\n' "$environment_file"
        printf 'ExecStart=%s\n' "$exec_start"
        printf '%s\n' \
            'Restart=on-failure' \
            'RestartSec=5s' \
            '' \
            '[Install]' \
            'WantedBy=multi-user.target'
    } | atomic_write_secret_file "$unit_file" || return 1
    chmod 644 "$unit_file"
}

write_argo_openrc_service() {
    local tunnel_mode="${1:-quick}"
    local install_root="${2:-}"
    local init_file="${install_root}/etc/init.d/argo"
    local command_args

    case "$tunnel_mode" in
        token) command_args='tunnel --no-autoupdate run' ;;
        local) command_args='tunnel --config /etc/sing-box/tunnel.yml --no-autoupdate run' ;;
        quick) command_args="tunnel --url http://127.0.0.1:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2" ;;
        *) return 1 ;;
    esac

    {
        printf '%s\n' \
            '#!/sbin/openrc-run' \
            'description="Cloudflare Tunnel"' \
            'command="/etc/sing-box/argo"' \
            "command_args=\"${command_args}\"" \
            'command_background=true' \
            'pidfile="/var/run/argo.pid"' \
            'output_log="/etc/sing-box/argo.log"' \
            'error_log="/etc/sing-box/argo.log"'
        if [ "$tunnel_mode" = token ]; then
            printf '%s\n' \
                'start_pre() {' \
                '    [ -r /etc/sing-box/argo.env ] || return 1' \
                '    . /etc/sing-box/argo.env' \
                '    export TUNNEL_TOKEN' \
                '}'
        fi
    } | atomic_write_secret_file "$init_file" || return 1
    chmod 700 "$init_file"
}

persist_install_settings() {
    local settings_file="${1:-${install_env_file:-/etc/sing-box/install.env}}"

    resolve_service_ports || return 1
    {
        printf 'PORT=%s\n' "$PORT"
        printf 'REALITY_PORT=%s\n' "$vless_port"
        printf 'NGINX_PORT=%s\n' "$nginx_port"
        printf 'TUIC_PORT=%s\n' "$tuic_port"
        printf 'HY2_PORT=%s\n' "$hy2_port"
        printf 'ARGO_PORT=%s\n' "$argo_port"
    } | atomic_write_file "$settings_file" 600 || return 1
    chmod 600 "$settings_file"
}

is_install_complete() {
    local marker_file="${INSTALL_COMPLETE_MARKER:-${work_dir}/.install-complete}"

    [ -f "$marker_file" ] && [ "$(cat "$marker_file" 2>/dev/null)" = complete ]
}

mark_install_complete() {
    local marker_file="${INSTALL_COMPLETE_MARKER:-${work_dir}/.install-complete}"

    printf '%s\n' complete | atomic_write_file "$marker_file" 600 || return 1
    chmod 600 "$marker_file"
}

clear_install_complete_marker() {
    local marker_file="${INSTALL_COMPLETE_MARKER:-${work_dir}/.install-complete}"

    rm -f "$marker_file"
}

legacy_services_are_active() {
    local service_name service_definition

    if command_exists systemctl; then
        for service_definition in sing-box.service argo.service; do
            [ -s "${LEGACY_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${service_definition}" ] || return 1
        done
        for service_name in sing-box argo nginx; do
            systemctl is-active --quiet "$service_name" >/dev/null 2>&1 || return 1
        done
    elif command_exists rc-service; then
        for service_definition in sing-box argo; do
            [ -s "${LEGACY_OPENRC_INIT_DIR:-/etc/init.d}/${service_definition}" ] && \
                [ -x "${LEGACY_OPENRC_INIT_DIR:-/etc/init.d}/${service_definition}" ] || return 1
        done
        for service_name in sing-box argo nginx; do
            rc-service "$service_name" status >/dev/null 2>&1 || return 1
        done
    else
        return 1
    fi
}

legacy_install_is_complete() {
    local singbox_binary="${work_dir}/${server_name:-sing-box}"
    local legacy_conf_dir="${conf_dir:-${work_dir}/conf}"
    local nginx_subscription_conf="${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}"
    local config_name subscription_file

    [ -x "$singbox_binary" ] || return 1
    for config_name in log ntp dns inbounds outbounds endpoints route; do
        [ -s "${legacy_conf_dir}/${config_name}.json" ] || return 1
    done
    "$singbox_binary" check -C "$legacy_conf_dir" >/dev/null 2>&1 || return 1
    [ -s "$nginx_subscription_conf" ] || return 1
    legacy_services_are_active || return 1
    for subscription_file in \
        "${client_dir:-${work_dir}/url.txt}" \
        "${work_dir}/base-sub.txt" \
        "${combined_client_dir:-${work_dir}/all-url.txt}" \
        "${work_dir}/all-sub.txt" \
        "${work_dir}/sub.txt"; do
        [ -s "$subscription_file" ] || return 1
    done
}

prepare_existing_install() {
    local marker_file="${INSTALL_COMPLETE_MARKER:-${work_dir}/.install-complete}"

    if check_singbox &>/dev/null && is_install_complete; then
        return 0
    fi
    [ ! -e "$marker_file" ] || return 1
    legacy_install_is_complete || return 1
    mark_install_complete || return 2
}

is_valid_subscription_token() {
    [[ "${1:-}" =~ ^[0123456789abcdefghjkmnpqrstvwxyz]{32}$ ]]
}

generate_random_alphanumeric() {
    local length="${1:-24}"
    local value

    [[ "$length" =~ ^[1-9][0-9]*$ ]] || return 1
    value=$(LC_ALL=C od -An -N "$length" -tu1 /dev/urandom | awk \
        -v alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789' '
        {
            for (i = 1; i <= NF; i++) {
                printf "%s", substr(alphabet, ($i % 62) + 1, 1)
            }
        }
        END { print "" }
    ') || return 1
    [[ ${#value} -eq $length && "$value" =~ ^[A-Za-z0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

generate_subscription_token() {
    od -An -N32 -tu1 /dev/urandom | awk \
        -v alphabet='0123456789abcdefghjkmnpqrstvwxyz' '
        {
            for (i = 1; i <= NF; i++) {
                printf "%s", substr(alphabet, ($i % 32) + 1, 1)
            }
        }
        END { print "" }
    '
}

is_valid_subscription_domain() {
    local domain label
    local -a labels

    domain=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$domain" == *.* && "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1

    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" != -* && "$label" != *- ]] || return 1
    done
}

is_valid_subscription_path() {
    [[ "${1:-}" =~ ^/(sub/)?[0123456789abcdefghjkmnpqrstvwxyz]{32}$ ]]
}

reset_subscription_state() {
    SUB_TOKEN=''
    SUB_HTTP_PATH=''
    SUB_HTTPS_ENABLED=0
    SUB_HTTPS_DOMAIN=''
    SUB_HTTPS_DOMAIN_MODE=''
    SUB_HTTPS_PATH=''
    SUB_TUNNEL_MODE=''
    SUB_HTTPS_VERIFIED_AT=''
}

load_subscription_state() {
    local key value

    reset_subscription_state
    [ -r "$subscription_state_file" ] || return 0

    while IFS='=' read -r key value; do
        case "$key" in
            SUB_TOKEN)
                is_valid_subscription_token "$value" && SUB_TOKEN="$value"
                ;;
            SUB_HTTP_PATH)
                is_valid_subscription_path "$value" && SUB_HTTP_PATH="$value"
                ;;
            SUB_HTTPS_ENABLED)
                [[ "$value" == 0 || "$value" == 1 ]] && SUB_HTTPS_ENABLED="$value"
                ;;
            SUB_HTTPS_DOMAIN)
                value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
                is_valid_subscription_domain "$value" && SUB_HTTPS_DOMAIN="$value"
                ;;
            SUB_HTTPS_DOMAIN_MODE)
                [[ "$value" == reuse || "$value" == separate ]] && SUB_HTTPS_DOMAIN_MODE="$value"
                ;;
            SUB_HTTPS_PATH)
                is_valid_subscription_path "$value" && SUB_HTTPS_PATH="$value"
                ;;
            SUB_TUNNEL_MODE)
                [[ "$value" == local || "$value" == remote ]] && SUB_TUNNEL_MODE="$value"
                ;;
            SUB_HTTPS_VERIFIED_AT)
                [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && \
                    SUB_HTTPS_VERIFIED_AT="$value"
                ;;
        esac
    done < "$subscription_state_file"

    if [ "$SUB_HTTPS_ENABLED" = 1 ]; then
        if ! is_valid_subscription_token "$SUB_TOKEN" || \
           ! is_valid_subscription_path "$SUB_HTTP_PATH" || \
           ! is_valid_subscription_domain "$SUB_HTTPS_DOMAIN" || \
           ! is_valid_subscription_path "$SUB_HTTPS_PATH" || \
           [[ "$SUB_HTTPS_DOMAIN_MODE" != reuse && "$SUB_HTTPS_DOMAIN_MODE" != separate ]] || \
           [[ "$SUB_TUNNEL_MODE" != local && "$SUB_TUNNEL_MODE" != remote ]] || \
           [ -z "$SUB_HTTPS_VERIFIED_AT" ]; then
            SUB_HTTPS_ENABLED=0
            SUB_HTTPS_VERIFIED_AT=''
        fi
    fi
}

save_subscription_state() {
    if [ -n "${SUB_TOKEN:-}" ] && ! is_valid_subscription_token "$SUB_TOKEN"; then
        return 1
    fi
    if [ -n "${SUB_HTTP_PATH:-}" ] && ! is_valid_subscription_path "$SUB_HTTP_PATH"; then
        return 1
    fi
    if [ "${SUB_HTTPS_ENABLED:-0}" = 1 ]; then
        is_valid_subscription_token "${SUB_TOKEN:-}" || return 1
        is_valid_subscription_path "${SUB_HTTP_PATH:-}" || return 1
        is_valid_subscription_domain "${SUB_HTTPS_DOMAIN:-}" || return 1
        is_valid_subscription_path "${SUB_HTTPS_PATH:-}" || return 1
        [[ "${SUB_HTTPS_DOMAIN_MODE:-}" == reuse || "${SUB_HTTPS_DOMAIN_MODE:-}" == separate ]] || return 1
        [[ "${SUB_TUNNEL_MODE:-}" == local || "${SUB_TUNNEL_MODE:-}" == remote ]] || return 1
        [[ "${SUB_HTTPS_VERIFIED_AT:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    fi

    {
        printf 'SUB_TOKEN=%s\n' "${SUB_TOKEN:-}"
        printf 'SUB_HTTP_PATH=%s\n' "${SUB_HTTP_PATH:-}"
        printf 'SUB_HTTPS_ENABLED=%s\n' "${SUB_HTTPS_ENABLED:-0}"
        printf 'SUB_HTTPS_DOMAIN=%s\n' "${SUB_HTTPS_DOMAIN:-}"
        printf 'SUB_HTTPS_DOMAIN_MODE=%s\n' "${SUB_HTTPS_DOMAIN_MODE:-}"
        printf 'SUB_HTTPS_PATH=%s\n' "${SUB_HTTPS_PATH:-}"
        printf 'SUB_TUNNEL_MODE=%s\n' "${SUB_TUNNEL_MODE:-}"
        printf 'SUB_HTTPS_VERIFIED_AT=%s\n' "${SUB_HTTPS_VERIFIED_AT:-}"
    } | atomic_write_file "$subscription_state_file" 600
}

download_binary() {
    local url="$1"
    local target_file="$2"
    local target_dir tmp_dir tmp_file

    target_dir=$(dirname "$target_file")
    mkdir -p "$target_dir" || return 1
    tmp_dir=$(mktemp -d "${work_dir}/.download.XXXXXX") || return 1
    tmp_file="${tmp_dir}/$(basename "$target_file")"

    if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 -o "$tmp_file" "$url"; then
        rm -rf "$tmp_dir"
        red "download failed: $url"
        return 1
    fi
    if [ ! -s "$tmp_file" ]; then
        rm -rf "$tmp_dir"
        red "downloaded file is empty: $url"
        return 1
    fi

    chmod +x "$tmp_file"
    if command_exists install; then
        install -m 755 "$tmp_file" "$target_file"
    else
        cp "$tmp_file" "$target_file" && chmod 755 "$target_file"
    fi
    local rc=$?
    rm -rf "$tmp_dir"
    return $rc
}

# 检查服务状态通用函数
check_service() {
    local service_name=$1
    local service_file=$2

    [[ ! -f "${service_file}" ]] && { red "not installed"; return 2; }

    if command_exists apk; then
        rc-service "${service_name}" status | grep -q "started" && green "running" || yellow "not running"
    else
        systemctl is-active "${service_name}" | grep -q "^active$" && green "running" || yellow "not running"
    fi
    return $?
}

# 检查sing-box状态
check_singbox() {
    check_service "sing-box" "${work_dir}/${server_name}"
}

# 检查argo状态
check_argo() {
    check_service "argo" "${work_dir}/argo"
}

# 检查nginx状态
check_nginx() {
    command_exists nginx || { red "not installed"; return 2; }
    check_service "nginx" "$(command -v nginx)"
}

# 根据系统类型安装、卸载依赖
manage_packages() {
    local action package

    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    action=$1
    shift

    # 首次安装只刷新软件包元数据，不执行全系统升级。
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在刷新软件包元数据...\n"
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y || return 1
        elif command_exists dnf; then
            dnf makecache || return 1
        elif command_exists yum; then
            yum makecache || return 1
        elif command_exists apk; then
            apk update || return 1
        else
            red "Unknown system!\n"
            return 1
        fi
        green "finished refreshing package metadata\n"
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package" || return 1
            elif command_exists dnf; then
                dnf install -y "$package" || return 1
            elif command_exists yum; then
                yum install -y "$package" || return 1
            elif command_exists apk; then
                apk add "$package" || return 1
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

# 获取ip
get_realip() {
    local ip v6

    ip=$(curl -4 -sm 2 ip.sb | tr -d '\r\n') || true
    ipv6() { curl -6 -sm 2 ip.sb | tr -d '\r\n'; }

    if [ -n "$ip" ]; then
        if curl -4 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
            v6=$(ipv6 || true)
            [ -n "$v6" ] && echo "[$v6]" && return 0
            echo "$ip"
            return 0
        fi

        if grep -qE '^\s*precedence\s+::ffff:0:0/96\s+100' "/etc/gai.conf" 2>/dev/null; then
            echo "$ip"
            return 0
        fi
    fi

    v6=$(ipv6 || true)
    [ -n "$v6" ] && echo "[$v6]" && return 0
    [ -n "$ip" ] && echo "$ip" && return 0
    return 1
}
format_url_host() {
    local host="$1"

    if [[ "$host" == \[*\] ]]; then
        echo "$host"
    elif [[ "$host" == *:* ]]; then
        echo "[$host]"
    else
        echo "$host"
    fi
}

is_valid_http_subscription_path() {
    is_valid_subscription_path "${1:-}" && return 0
    [[ "${1:-}" =~ ^/[A-Za-z0-9_-]{16,128}$ ]]
}

build_http_subscription_url() {
    local host="${1:-}"
    local port="${2:-}"
    local path="${3:-}"

    [ -n "$host" ] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
    is_valid_http_subscription_path "$path" || return 1

    if [[ "$host" == \[*\] ]]; then
        [[ "$host" =~ ^\[[0-9A-Fa-f:.]+\]$ ]] || return 1
    elif [[ "$host" == *:* ]]; then
        [[ "$host" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    else
        [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    fi

    host=$(format_url_host "$host")
    if [ "$port" = 80 ]; then
        printf 'http://%s%s\n' "$host" "$path"
    else
        printf 'http://%s:%s%s\n' "$host" "$port" "$path"
    fi
}

build_https_subscription_url() {
    local domain="${1:-}"
    local path="${2:-}"

    domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
    is_valid_subscription_domain "$domain" || return 1
    is_valid_subscription_path "$path" || return 1
    printf 'https://%s%s\n' "$domain" "$path"
}

resolve_subscription_source_url() {
    local host="${1:-}"
    local port="${2:-}"
    local path="${3:-}"
    local url

    if [ "${SUB_HTTPS_ENABLED:-0}" = 1 ] && [ -n "${SUB_HTTPS_VERIFIED_AT:-}" ]; then
        url=$(build_https_subscription_url "${SUB_HTTPS_DOMAIN:-}" "${SUB_HTTPS_PATH:-}" 2>/dev/null) && {
            printf '%s\n' "$url"
            return 0
        }
    fi

    build_http_subscription_url "$host" "$port" "$path"
}

render_terminal_qr() {
    local url="${1:-}"
    local encoder="${QR_ENCODER:-${work_dir}/qrencode}"

    [ -n "$url" ] && [ -t 1 ] && [ -x "$encoder" ] || return 0
    "$encoder" -t ANSIUTF8 -m 1 -- "$url" 2>/dev/null || true
}

show_subscription_links() {
    local source_url="${1:-}"
    local clash_url singbox_url surge_url

    if [ -z "$source_url" ]; then
        yellow "订阅未配置：未找到有效的 HTTPS 或 HTTP 订阅地址。\n"
        return 0
    fi

    clash_url="https://sublink.eooce.com/clash?config=${source_url}"
    singbox_url="https://sublink.eooce.com/singbox?config=${source_url}"
    surge_url="https://sublink.eooce.com/surge?config=${source_url}"

    green "V2rayN/Shadowrocket/Nekobox/Loon/Karing/Streisand 订阅链接：\n${purple}${source_url}${re}\n"
    render_terminal_qr "$source_url"
    yellow "\n=========================================================================================="
    green "\nClash/Mihomo 订阅链接：\n${purple}${clash_url}${re}\n"
    render_terminal_qr "$clash_url"
    yellow "\n=========================================================================================="
    green "\nSing-box 订阅链接：\n${purple}${singbox_url}${re}\n"
    render_terminal_qr "$singbox_url"
    yellow "\n=========================================================================================="
    green "\nSurge 订阅链接：\n${purple}${surge_url}${re}\n"
    render_terminal_qr "$surge_url"
    yellow "\n==========================================================================================\n"
}

verify_https_subscription() {
    local url="${1:-}"
    local expected_file="${2:-${work_dir}/sub.txt}"
    local curl_bin="${CURL_BIN:-curl}"
    local tmp_dir remote_file expected_flat remote_flat

    [[ "$url" == https://* ]] && [ -s "$expected_file" ] || return 1
    tmp_dir=$(mktemp -d "${work_dir}/.subscription-verify.XXXXXX") || return 1
    chmod 700 "$tmp_dir" 2>/dev/null || true
    remote_file="${tmp_dir}/remote-subscription.txt"

    if ! "$curl_bin" -fsS --compressed --retry 2 --connect-timeout 10 --max-time 30 \
        -o "$remote_file" "$url"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if cmp -s "$expected_file" "$remote_file"; then
        rm -rf "$tmp_dir"
        return 0
    fi

    expected_flat=$(tr -d '\r\n' < "$expected_file")
    remote_flat=$(tr -d '\r\n' < "$remote_file")
    rm -rf "$tmp_dir"
    [ -n "$expected_flat" ] && [ "$expected_flat" = "$remote_flat" ]
}

print_manual_https_route() {
    local domain="${1:-}"
    local path_regex="${2:-}"
    local port="${3:-}"

    green "\n请在 Cloudflare Tunnel 的 Published application 中添加以下路由："
    green "Hostname: ${purple}${domain}${re}"
    green "Path:     ${purple}${path_regex}${re}"
    green "Type:     ${purple}HTTP${re}"
    green "URL:      ${purple}http://localhost:${port}${re}\n"
}

show_subscription_status() {
    local config_file="/etc/nginx/conf.d/sing-box.conf"
    local port http_path source_url host tunnel_mode

    load_subscription_state
    host=$(get_subscription_host 2>/dev/null || true)
    port=$(get_nginx_subscription_port "$config_file" 2>/dev/null || true)
    http_path=$(select_nginx_http_subscription_path "$config_file" 2>/dev/null || true)
    source_url=$(resolve_installed_subscription_source_url "$host" "$config_file" 2>/dev/null || true)
    tunnel_mode=$(detect_argo_tunnel_mode 2>/dev/null || printf 'unknown')

    clear; echo ""
    green "=== 节点订阅详细状态 ===\n"
    green "Nginx 端口: ${purple}${port:-未配置}${re}"
    green "HTTP 路径: ${purple}${http_path:-未配置}${re}"
    green "Tunnel 类型: ${purple}${tunnel_mode}${re}"
    if [ "$SUB_HTTPS_ENABLED" = 1 ]; then
        green "HTTPS 状态: ${purple}已验证${re}"
        green "HTTPS 域名: ${purple}${SUB_HTTPS_DOMAIN}${re}"
        green "域名模式: ${purple}${SUB_HTTPS_DOMAIN_MODE}${re}"
        green "验证时间: ${purple}${SUB_HTTPS_VERIFIED_AT}${re}\n"
    else
        yellow "HTTPS 状态: 未启用或未通过验证\n"
    fi
    [ "$tunnel_mode" = quick ] && yellow "临时 Tunnel 不适合作为稳定 HTTPS 订阅。\n"
    [ -n "$source_url" ] && green "当前首选订阅：${purple}${source_url}${re}\n"
    show_subscription_links "$source_url"
    yellow "使用第三方转换链接时，转换服务能够看到原始订阅 URL 和其中的随机密钥。\n"
}

get_public_ipv4() {
    local ip

    ip=$(curl -4 -sm 2 ip.sb | tr -d '\r\n') || true
    [ -z "$ip" ] && ip=$(curl -4 -sm 2 https://api.ipify.org | tr -d '\r\n') || true
    [ -n "$ip" ] || return 1
    echo "$ip"
}

get_public_ipv6() {
    local ip

    ip=$(curl -6 -sm 2 ip.sb | tr -d '\r\n') || true
    [ -z "$ip" ] && ip=$(curl -6 -sm 2 https://api64.ipify.org | tr -d '\r\n') || true
    [ -n "$ip" ] || return 1
    format_url_host "$ip"
}

get_subscription_host() {
    local host=""

    if [ -n "$SUB_HOST" ]; then
        format_url_host "$SUB_HOST"
        return 0
    fi

    case "$SUB_ADDR_FAMILY" in
        ipv6|IPv6|6)
            host=$(get_public_ipv6 2>/dev/null || true)
            [ -z "$host" ] && host=$(get_public_ipv4 2>/dev/null || true)
            ;;
        auto|AUTO|Auto)
            host=$(get_public_ipv4 2>/dev/null || true)
            [ -z "$host" ] && host=$(get_public_ipv6 2>/dev/null || true)
            ;;
        *)
            host=$(get_public_ipv4 2>/dev/null || true)
            [ -z "$host" ] && host=$(get_public_ipv6 2>/dev/null || true)
            ;;
    esac

    [ -n "$host" ] && echo "$host" || get_realip
}

sanitize_node_name() {
    local name="$1"
    name=$(printf '%s' "$name" | sed -E 's/[[:space:]]+/_/g; s/[^A-Za-z0-9._-]+/_/g; s/_+/_/g; s/^_//; s/_$//')
    printf '%s\n' "$name"
}

get_country_code() {
    local code

    code=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | \
        awk -F\" '{for(x=1;x<=NF;x++){if($x=="country_code"){print $(x+2); exit}}}' 2>/dev/null || true)
    [ -z "$code" ] && code=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" | tr -d '\n' | \
        awk -F\" '{for(x=1;x<=NF;x++){if($x=="country_code"){print $(x+2); exit}}}' 2>/dev/null || true)
    code=$(printf '%s' "$code" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]//g')
    [ -n "$code" ] || code="UN"
    printf '%s\n' "$code"
}

get_default_node_name() {
    local node_name

    node_name=$(hostname 2>/dev/null || true)
    node_name=$(sanitize_node_name "$node_name")
    [ -n "$node_name" ] || node_name="VPS"
    printf '%s\n' "$node_name"
}

format_node_name_prefix() {
    local country_code="$1"
    local node_name="$2"

    country_code=$(printf '%s' "$country_code" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]//g')
    node_name=$(sanitize_node_name "$node_name")
    [ -n "$country_code" ] || country_code="UN"
    [ -n "$node_name" ] || node_name="VPS"
    printf '%s-%s\n' "$country_code" "$node_name"
}

prompt_node_name_enabled() {
    case "${PROMPT_NODE_NAME}" in
        1|true|TRUE|yes|YES|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

extract_argo_tunnel_id() {
    local auth="$1"
    local tunnel_id=""

    if command_exists jq; then
        tunnel_id=$(printf '%s' "$auth" | jq -r '.TunnelID // empty' 2>/dev/null || true)
    fi
    if [ -z "$tunnel_id" ]; then
        tunnel_id=$(printf '%s' "$auth" | sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi

    printf '%s\n' "$tunnel_id"
}

is_argo_hostname() {
    local hostname="$1"

    [[ "$hostname" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$hostname" == *.* ]] && [[ "$hostname" != .* ]] && [[ "$hostname" != *..* ]]
}

is_argo_tunnel_token() {
    local token="$1"

    [[ "$token" =~ ^[A-Za-z0-9._=-]{80,4096}$ ]]
}

select_argo_client_address() {
    local fallback_cfip="$1"
    local argo_domain="$2"
    local fixed_ready="$3"
    local cfip_explicit="${4:-0}"

    if [ "$fixed_ready" = "1" ] && [ -n "$argo_domain" ] && [ "$cfip_explicit" != "1" ]; then
        printf '%s\n' "$argo_domain"
    else
        printf '%s\n' "$fallback_cfip"
    fi
}

list_argo_client_addresses() {
    local fallback_cfip="$1"
    local argo_domain="$2"
    local fixed_ready="$3"

    if [ "$fixed_ready" = "1" ] && [ -n "$argo_domain" ]; then
        printf '%s\tstable\n' "$argo_domain"
        if [ -n "$fallback_cfip" ] && [ "$fallback_cfip" != "$argo_domain" ]; then
            printf '%s\tpreferred\n' "$fallback_cfip"
        fi
    elif [ -n "$fallback_cfip" ]; then
        printf '%s\tstable\n' "$fallback_cfip"
    fi
}

use_quick_argo_fallback() {
    ARGO_FIXED_READY=0
    ARGO_DOMAIN=""
    ARGO_AUTH=""
}

is_valid_tunnel_subscription_regex() {
    local expression="${1:-}"
    local path

    [ "${expression:0:1}" = '^' ] && [ "${expression: -1}" = '$' ] || return 1
    path="${expression:1:${#expression}-2}"
    is_valid_subscription_path "$path"
}

detect_argo_tunnel_mode() {
    local service_file="${1:-}"

    if [ -z "$service_file" ]; then
        if command_exists rc-service && [ -r /etc/init.d/argo ]; then
            service_file=/etc/init.d/argo
        elif [ -r /etc/systemd/system/argo.service ]; then
            service_file=/etc/systemd/system/argo.service
        else
            return 1
        fi
    fi
    [ -r "$service_file" ] || return 1

    if grep -Eq -- 'tunnel[^[:cntrl:]]*--url[[:space:]]+http://(127\.0\.0\.1|localhost)' "$service_file"; then
        printf 'quick\n'
    elif grep -Eq -- 'tunnel[^[:cntrl:]]*--config[[:space:]]+[^[:space:]]+' "$service_file"; then
        printf 'local\n'
    elif grep -Eq -- 'EnvironmentFile=-?/etc/sing-box/argo\.env|[.][[:space:]]+/etc/sing-box/argo\.env|tunnel[^[:cntrl:]]*(run[[:space:]]+)?--token[[:space:]]+[^[:space:]]+' "$service_file"; then
        printf 'remote\n'
    else
        return 1
    fi
}

refresh_quick_argo() {
    local service_file="${1:-}"
    local tunnel_mode

    tunnel_mode=$(detect_argo_tunnel_mode "$service_file" 2>/dev/null) || {
        red "无法识别当前 Argo Tunnel 类型，未执行刷新。"
        return 1
    }
    if [ "$tunnel_mode" != quick ]; then
        red "当前使用固定 Argo Tunnel，不能刷新临时域名。"
        return 1
    fi
    get_quick_tunnel || return 1
    change_argo_domain
}

dispatch_argo_menu_action() {
    local choice="${1:-}"
    local service_file="${2:-}"

    case "$choice" in
        6) dispatch_cli_action -r "$service_file" ;;
        *) return 2 ;;
    esac
}

strip_local_tunnel_subscription_rule() {
    local input_file="${1:-}"
    local output_file="${2:-}"
    local output_dir tmp_file last_rule

    [ -r "$input_file" ] && [ -n "$output_file" ] || return 1
    output_dir=$(dirname "$output_file")
    mkdir -p "$output_dir" || return 1
    tmp_file=$(mktemp "${output_dir}/.tunnel-strip.XXXXXX") || return 1

    if ! awk '
        BEGIN { inside = 0; starts = 0; ends = 0; error = 0 }
        index($0, "# sing-box-subscription:start") {
            if (inside) error = 1
            inside = 1
            starts++
            next
        }
        index($0, "# sing-box-subscription:end") {
            if (!inside) error = 1
            inside = 0
            ends++
            next
        }
        !inside { print }
        END {
            if (inside || starts != ends || error) exit 42
        }
    ' "$input_file" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    last_rule=$(awk 'NF { line=$0 } END { gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line }' "$tmp_file")
    if [ "$last_rule" != '- service: http_status:404' ]; then
        rm -f "$tmp_file"
        return 1
    fi

    mv -f "$tmp_file" "$output_file"
}

render_local_tunnel_with_subscription() {
    local input_file="${1:-}"
    local output_file="${2:-}"
    local domain="${3:-}"
    local path_regex="${4:-}"
    local port="${5:-}"
    local mode="${6:-}"
    local output_dir clean_file tmp_file

    is_valid_subscription_domain "$domain" || return 1
    is_valid_tunnel_subscription_regex "$path_regex" || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
    [[ "$mode" == reuse || "$mode" == separate ]] || return 1

    output_dir=$(dirname "$output_file")
    mkdir -p "$output_dir" || return 1
    clean_file=$(mktemp "${output_dir}/.tunnel-clean.XXXXXX") || return 1
    tmp_file=$(mktemp "${output_dir}/.tunnel-render.XXXXXX") || { rm -f "$clean_file"; return 1; }
    if ! strip_local_tunnel_subscription_rule "$input_file" "$clean_file"; then
        rm -f "$clean_file" "$tmp_file"
        return 1
    fi

    if ! awk -v host="$domain" -v path="$path_regex" -v port="$port" -v mode="$mode" '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        function emit_rule() {
            print "  # sing-box-subscription:start"
            print "  - hostname: " host
            print "    path: " path
            print "    service: http://127.0.0.1:" port
            print "  # sing-box-subscription:end"
        }
        BEGIN { inserted = 0 }
        {
            current = trim($0)
            if (!inserted && mode == "reuse" && current == "- hostname: " host) {
                emit_rule()
                inserted = 1
            } else if (!inserted && mode == "separate" && current == "- service: http_status:404") {
                emit_rule()
                inserted = 1
            }
            print
        }
        END { if (!inserted) exit 43 }
    ' "$clean_file" > "$tmp_file"; then
        rm -f "$clean_file" "$tmp_file"
        return 1
    fi

    rm -f "$clean_file"
    mv -f "$tmp_file" "$output_file"
}

remove_local_tunnel_subscription_rule() {
    strip_local_tunnel_subscription_rule "$1" "$2"
}

apply_local_tunnel_subscription_rule() {
    local domain="${1:-}"
    local path_regex="${2:-}"
    local port="${3:-}"
    local mode="${4:-}"
    local tunnel_config="${5:-${work_dir}/tunnel.yml}"
    local verify_url="${6:-}"
    local backup_file="${tunnel_config}.bak.subscription"
    local tmp_file public_path rollback_status=0

    [ -r "$tunnel_config" ] || return 1
    tmp_file=$(mktemp "$(dirname "$tunnel_config")/.tunnel-apply.XXXXXX") || return 1
    render_local_tunnel_with_subscription "$tunnel_config" "$tmp_file" \
        "$domain" "$path_regex" "$port" "$mode" || { rm -f "$tmp_file"; return 1; }

    cp -p "$tunnel_config" "$backup_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$backup_file" 2>/dev/null || true
    mv -f "$tmp_file" "$tunnel_config" || return 1

    public_path="${path_regex#^}"
    public_path="${public_path%$}"
    if ! "${work_dir}/argo" tunnel --config "$tunnel_config" ingress validate > /dev/null 2>&1 || \
       ! "${work_dir}/argo" tunnel --config "$tunnel_config" ingress rule \
            "https://${domain}${public_path}" > /dev/null 2>&1 || \
       ! restart_argo > /dev/null 2>&1 || \
       { [ -n "$verify_url" ] && ! verify_https_subscription "$verify_url"; }; then
        cp -p "$backup_file" "$tunnel_config" || rollback_status=1
        restart_argo > /dev/null 2>&1 || rollback_status=1
        [ "$rollback_status" -eq 0 ] && return 1
        return 2
    fi
    return 0
}

apply_local_tunnel_subscription_removal() {
    local tunnel_config="${1:-${work_dir}/tunnel.yml}"
    local backup_file="${tunnel_config}.bak.subscription-removal"
    local tmp_file rollback_status=0

    [ -r "$tunnel_config" ] || return 1
    tmp_file=$(mktemp "$(dirname "$tunnel_config")/.tunnel-remove.XXXXXX") || return 1
    remove_local_tunnel_subscription_rule "$tunnel_config" "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    cp -p "$tunnel_config" "$backup_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$backup_file" 2>/dev/null || true
    mv -f "$tmp_file" "$tunnel_config" || return 1
    if ! "${work_dir}/argo" tunnel --config "$tunnel_config" ingress validate > /dev/null 2>&1 || \
       ! restart_argo > /dev/null 2>&1; then
        cp -p "$backup_file" "$tunnel_config" || rollback_status=1
        restart_argo > /dev/null 2>&1 || rollback_status=1
        [ "$rollback_status" -eq 0 ] && return 1
        return 2
    fi
    return 0
}

build_remote_tunnel_config() {
    local current_config="${1:-}"
    local domain="${2:-}"
    local path_regex="${3:-}"
    local service="${4:-}"
    local mode="${5:-}"
    local old_domain="${6:-}"
    local old_path_regex="${7:-}"
    local jq_bin="${JQ_BIN:-jq}"

    is_valid_subscription_domain "$domain" || return 1
    is_valid_tunnel_subscription_regex "$path_regex" || return 1
    [[ "$service" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]] || return 1
    [[ "$mode" == reuse || "$mode" == separate ]] || return 1

    printf '%s' "$current_config" | "$jq_bin" -ce \
        --arg host "$domain" \
        --arg path "$path_regex" \
        --arg service "$service" \
        --arg mode "$mode" \
        --arg old_host "$old_domain" \
        --arg old_path "$old_path_regex" '
        def is_catchall:
            type == "object" and
            .service == "http_status:404" and
            (has("hostname") | not) and
            (has("path") | not);
        def without_owned($rules):
            $rules
            | map(select(
                if ($old_host != "" and $old_path != "") then
                    ((.hostname? == $old_host and .path? == $old_path) | not)
                else true end
            ))
            | map(select(
                ((.hostname? == $host and .path? == $path and .service? == $service) | not)
            ));
        if type != "object" or
           (.ingress | type) != "array" or
           (.ingress | length) == 0 or
           (.ingress | all(.[]; type == "object") | not) or
           (.ingress[-1] | is_catchall | not) then
            error("invalid remote Tunnel ingress")
        else
            .ingress = without_owned(.ingress)
            | .ingress as $rules
            | {hostname: $host, path: $path, service: $service} as $new_rule
            | if $mode == "reuse" then
                ($rules | map((.hostname? == $host) and (has("path") | not)) | index(true)) as $index
                | if $index == null then
                    error("reuse hostname rule not found")
                  else
                    .ingress = ($rules[0:$index] + [$new_rule] + $rules[$index:])
                  end
              else
                .ingress = ($rules[0:-1] + [$new_rule] + [$rules[-1]])
              end
        end
    '
}

remove_remote_tunnel_subscription_rule() {
    local current_config="${1:-}"
    local domain="${2:-}"
    local path_regex="${3:-}"
    local jq_bin="${JQ_BIN:-jq}"

    is_valid_subscription_domain "$domain" || return 1
    is_valid_tunnel_subscription_regex "$path_regex" || return 1
    printf '%s' "$current_config" | "$jq_bin" -ce \
        --arg host "$domain" --arg path "$path_regex" '
        if type != "object" or (.ingress | type) != "array" then
            error("invalid remote Tunnel config")
        else
            .ingress |= map(select((.hostname? == $host and .path? == $path) | not))
        end
    '
}

build_dns_change_plan() {
    local current_records="${1:-}"
    local tunnel_id="${2:-}"
    local domain="${3:-}"
    local jq_bin="${JQ_BIN:-jq}"
    local target="${tunnel_id}.cfargotunnel.com"

    [[ "$tunnel_id" =~ ^[A-Za-z0-9-]{16,128}$ ]] || return 1
    is_valid_subscription_domain "$domain" || return 1
    printf '%s' "$current_records" | "$jq_bin" -ce \
        --arg domain "$domain" --arg target "$target" '
        if type != "array" or length > 1 then
            error("ambiguous DNS record set")
        else
            {
                type: "CNAME",
                name: $domain,
                content: $target,
                proxied: true,
                ttl: 1
            } as $desired
            | if length == 0 then
                {action: "create", original: null, desired: $desired}
              elif .[0].type == "CNAME" and
                   .[0].content == $target and
                   .[0].proxied == true then
                {action: "noop", original: .[0], desired: $desired}
              else
                {action: "update", original: .[0], desired: $desired}
              end
        end
    '
}

cloudflare_api() {
    local method="${1:-}"
    local url="${2:-}"
    local body_file="${3:-}"

    [[ "${CF_API_TOKEN:-}" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || return 1
    if [ -n "$body_file" ]; then
        {
            printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN"
            printf 'header = "Content-Type: application/json"\n'
        } | curl -q --config - -fsS -X "$method" "$url" --data-binary "@$body_file"
    else
        {
            printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN"
            printf 'header = "Content-Type: application/json"\n'
        } | curl -q --config - -fsS -X "$method" "$url"
    fi
}

rollback_remote_tunnel_configuration() {
    local account_id="${1:-}"
    local tunnel_id="${2:-}"
    local old_config_file="${3:-}"
    local response_file="${4:-}"
    local jq_bin="${JQ_BIN:-jq}"
    local body_file

    [ -r "$old_config_file" ] && [ -n "$response_file" ] || return 1
    body_file=$(mktemp "$(dirname "$old_config_file")/.rollback-config.XXXXXX") || return 1
    "$jq_bin" -cn --slurpfile config "$old_config_file" '{config: $config[0]}' > "$body_file" || {
        rm -f "$body_file"
        return 1
    }
    cloudflare_api PUT \
        "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
        "$body_file" > "$response_file" 2>/dev/null
    local rc=$?
    rm -f "$body_file"
    [ "$rc" -eq 0 ] && "$jq_bin" -e '.success == true' "$response_file" > /dev/null 2>&1
}

rollback_cloudflare_dns_change() {
    local zone_id="${1:-}"
    local plan_file="${2:-}"
    local new_record_id="${3:-}"
    local response_file="${4:-}"
    local jq_bin="${JQ_BIN:-jq}"
    local action record_id body_file rc

    [ -r "$plan_file" ] && [ -n "$response_file" ] || return 1
    action=$("$jq_bin" -r '.action' "$plan_file") || return 1
    case "$action" in
        create)
            [ -n "$new_record_id" ] || return 1
            cloudflare_api DELETE \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${new_record_id}" \
                > "$response_file" 2>/dev/null
            rc=$?
            [ "$rc" -eq 0 ] && "$jq_bin" -e '.success == true' \
                "$response_file" > /dev/null 2>&1
            ;;
        update)
            record_id=$("$jq_bin" -r '.original.id // empty' "$plan_file")
            [ -n "$record_id" ] || return 1
            body_file=$(mktemp "$(dirname "$plan_file")/.rollback-dns.XXXXXX") || return 1
            "$jq_bin" '{type, name, content, proxied, ttl}' \
                < <("$jq_bin" '.original' "$plan_file") > "$body_file" || {
                rm -f "$body_file"
                return 1
            }
            cloudflare_api PUT \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
                "$body_file" > "$response_file" 2>/dev/null
            rc=$?
            rm -f "$body_file"
            [ "$rc" -eq 0 ] && "$jq_bin" -e '.success == true' \
                "$response_file" > /dev/null 2>&1
            return $?
            ;;
        noop) return 0 ;;
        *) return 1 ;;
    esac
}

apply_remote_tunnel_subscription_rule() {
    local domain="${1:-}"
    local path_regex="${2:-}"
    local port="${3:-}"
    local mode="${4:-}"
    local old_domain="${5:-}"
    local old_path_regex="${6:-}"
    local verify_url="${7:-}"
    local jq_bin="${JQ_BIN:-jq}"
    local account_id tunnel_id zone_id CF_API_TOKEN
    local tmp_parent tmp_dir get_response old_config new_config put_body put_response
    local dns_response dns_records dns_plan dns_body dns_apply_response dns_action
    local new_record_id='' remote_attempted=0
    local dns_attempted=0 dns_changed=0 operation_ok=0 rollback_ok=1

    is_valid_subscription_domain "$domain" || return 1
    is_valid_tunnel_subscription_regex "$path_regex" || return 1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
    [[ "$mode" == reuse || "$mode" == separate ]] || return 1

    reading "请输入 Cloudflare Account ID: " account_id
    reading "请输入 Cloudflare Tunnel ID: " tunnel_id
    [[ "$account_id" =~ ^[A-Fa-f0-9]{32}$ ]] || { red "Account ID 格式无效"; return 1; }
    [[ "$tunnel_id" =~ ^[A-Za-z0-9-]{16,128}$ ]] || { red "Tunnel ID 格式无效"; return 1; }
    if [ "$mode" = separate ]; then
        reading "请输入该域名所在的 Cloudflare Zone ID: " zone_id
        [[ "$zone_id" =~ ^[A-Fa-f0-9]{32}$ ]] || { red "Zone ID 格式无效"; return 1; }
    fi
    read -r -s -p "$(red '请输入 Cloudflare API token（输入不会显示）: ')" CF_API_TOKEN
    echo ""
    [[ "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || {
        unset CF_API_TOKEN
        red "Cloudflare API token 格式无效"
        return 1
    }

    CF_TUNNEL_RECOVERY_PATH=''
    tmp_parent="${DURABLE_TX_RECOVERY_DIR:-$work_dir}"
    [ -d "$tmp_parent" ] && [ ! -L "$tmp_parent" ] || { unset CF_API_TOKEN; return 1; }
    tmp_dir=$(mktemp -d "${tmp_parent}/.cf-subscription.XXXXXX") || { unset CF_API_TOKEN; return 1; }
    chmod 700 "$tmp_dir" 2>/dev/null || true
    get_response="${tmp_dir}/get-response.json"
    old_config="${tmp_dir}/old-config.json"
    new_config="${tmp_dir}/new-config.json"
    put_body="${tmp_dir}/put-body.json"
    put_response="${tmp_dir}/put-response.json"
    dns_response="${tmp_dir}/dns-response.json"
    dns_records="${tmp_dir}/dns-records.json"
    dns_plan="${tmp_dir}/dns-plan.json"
    dns_body="${tmp_dir}/dns-body.json"
    dns_apply_response="${tmp_dir}/dns-apply-response.json"

    while :; do
        cloudflare_api GET \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
            > "$get_response" 2>/dev/null || break
        "$jq_bin" -e '.success == true and (.result.config | type == "object")' \
            "$get_response" > /dev/null || break
        "$jq_bin" '.result.config' "$get_response" > "$old_config" || break

        build_remote_tunnel_config "$(< "$old_config")" "$domain" "$path_regex" \
            "http://127.0.0.1:${port}" "$mode" "$old_domain" "$old_path_regex" \
            > "$new_config" || break
        "$jq_bin" -cn --slurpfile config "$new_config" '{config: $config[0]}' > "$put_body" || break
        remote_attempted=1
        cloudflare_api PUT \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
            "$put_body" > "$put_response" 2>/dev/null || break
        "$jq_bin" -e '.success == true' "$put_response" > /dev/null || break
        if [ "$mode" = separate ]; then
            cloudflare_api GET \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${domain}" \
                > "$dns_response" 2>/dev/null || break
            "$jq_bin" -e '.success == true and (.result | type == "array")' "$dns_response" > /dev/null || break
            "$jq_bin" '.result' "$dns_response" > "$dns_records" || break
            build_dns_change_plan "$(< "$dns_records")" "$tunnel_id" "$domain" > "$dns_plan" || break
            dns_action=$("$jq_bin" -r '.action' "$dns_plan") || break
            "$jq_bin" '.desired' "$dns_plan" > "$dns_body" || break
            case "$dns_action" in
                create)
                    dns_attempted=1
                    cloudflare_api POST \
                        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
                        "$dns_body" > "$dns_apply_response" 2>/dev/null || break
                    "$jq_bin" -e '.success == true' "$dns_apply_response" > /dev/null || break
                    new_record_id=$("$jq_bin" -r '.result.id // empty' "$dns_apply_response")
                    [ -n "$new_record_id" ] || break
                    dns_changed=1
                    ;;
                update)
                    local existing_record_id
                    existing_record_id=$("$jq_bin" -r '.original.id // empty' "$dns_plan")
                    [ -n "$existing_record_id" ] || break
                    dns_attempted=1
                    cloudflare_api PUT \
                        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${existing_record_id}" \
                        "$dns_body" > "$dns_apply_response" 2>/dev/null || break
                    "$jq_bin" -e '.success == true' "$dns_apply_response" > /dev/null || break
                    dns_changed=1
                    ;;
                noop) ;;
                *) break ;;
            esac
        fi

        if [ -n "$verify_url" ]; then
            declare -F verify_https_subscription > /dev/null || break
            verify_https_subscription "$verify_url" || break
        fi
        operation_ok=1
        break
    done

    if [ "$operation_ok" != 1 ]; then
        if [ "$dns_attempted" = 1 ]; then
            if [ "$dns_changed" = 1 ] || \
               { [ -r "$dns_plan" ] && [ -n "$new_record_id" ]; }; then
                rollback_cloudflare_dns_change "$zone_id" "$dns_plan" "$new_record_id" \
                    "${tmp_dir}/dns-rollback-response.json" || rollback_ok=0
            else
                rollback_ok=0
            fi
        fi
        if [ "$remote_attempted" = 1 ]; then
            rollback_remote_tunnel_configuration "$account_id" "$tunnel_id" "$old_config" \
                "${tmp_dir}/tunnel-rollback-response.json" || rollback_ok=0
        fi
    fi

    unset CF_API_TOKEN
    if [ "$operation_ok" = 1 ]; then
        if [ "${DURABLE_TX_ACTIVE:-0}" -eq 1 ]; then
            CF_TUNNEL_RECOVERY_PATH="$tmp_dir"
        else
            rm -rf -- "$tmp_dir"
        fi
        return 0
    fi
    if [ "$rollback_ok" = 1 ]; then
        rm -rf -- "$tmp_dir"
        return 1
    fi
    CF_TUNNEL_RECOVERY_PATH="$tmp_dir"
    red "Cloudflare 远程配置结果未决，已保留不含 API token 的恢复证据：${tmp_dir}"
    return 2
}

remove_remote_tunnel_subscription_via_api() {
    local domain="${1:-}"
    local path_regex="${2:-}"
    local jq_bin="${JQ_BIN:-jq}"
    local account_id tunnel_id CF_API_TOKEN tmp_parent tmp_dir get_response old_config
    local new_config put_body put_response operation_ok=0 remote_attempted=0 rollback_ok=1

    is_valid_subscription_domain "$domain" || return 1
    is_valid_tunnel_subscription_regex "$path_regex" || return 1
    reading "请输入 Cloudflare Account ID: " account_id
    reading "请输入 Cloudflare Tunnel ID: " tunnel_id
    [[ "$account_id" =~ ^[A-Fa-f0-9]{32}$ ]] || { red "Account ID 格式无效"; return 1; }
    [[ "$tunnel_id" =~ ^[A-Za-z0-9-]{16,128}$ ]] || { red "Tunnel ID 格式无效"; return 1; }
    read -r -s -p "$(red '请输入 Cloudflare API token（输入不会显示）: ')" CF_API_TOKEN
    echo ""
    [[ "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || { unset CF_API_TOKEN; return 1; }

    CF_TUNNEL_RECOVERY_PATH=''
    tmp_parent="${DURABLE_TX_RECOVERY_DIR:-$work_dir}"
    [ -d "$tmp_parent" ] && [ ! -L "$tmp_parent" ] || { unset CF_API_TOKEN; return 1; }
    tmp_dir=$(mktemp -d "${tmp_parent}/.cf-subscription-remove.XXXXXX") || { unset CF_API_TOKEN; return 1; }
    chmod 700 "$tmp_dir" 2>/dev/null || true
    get_response="${tmp_dir}/get-response.json"
    old_config="${tmp_dir}/old-config.json"
    new_config="${tmp_dir}/new-config.json"
    put_body="${tmp_dir}/put-body.json"
    put_response="${tmp_dir}/put-response.json"

    while :; do
        cloudflare_api GET \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
            > "$get_response" 2>/dev/null || break
        "$jq_bin" -e '.success == true and (.result.config | type == "object")' \
            "$get_response" > /dev/null || break
        "$jq_bin" '.result.config' "$get_response" > "$old_config" || break
        remove_remote_tunnel_subscription_rule "$(< "$old_config")" "$domain" "$path_regex" \
            > "$new_config" || break
        "$jq_bin" -cn --slurpfile config "$new_config" '{config: $config[0]}' > "$put_body" || break
        remote_attempted=1
        cloudflare_api PUT \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
            "$put_body" > "$put_response" 2>/dev/null || break
        "$jq_bin" -e '.success == true' "$put_response" > /dev/null || break
        operation_ok=1
        break
    done

    if [ "$operation_ok" != 1 ] && [ "$remote_attempted" = 1 ]; then
        rollback_remote_tunnel_configuration "$account_id" "$tunnel_id" "$old_config" \
            "${tmp_dir}/rollback-response.json" || rollback_ok=0
    fi
    unset CF_API_TOKEN
    if [ "$operation_ok" = 1 ]; then
        if [ "${DURABLE_TX_ACTIVE:-0}" -eq 1 ]; then
            CF_TUNNEL_RECOVERY_PATH="$tmp_dir"
        else
            rm -rf -- "$tmp_dir"
        fi
        return 0
    fi
    if [ "$rollback_ok" = 1 ]; then
        rm -rf -- "$tmp_dir"
        return 1
    fi
    CF_TUNNEL_RECOVERY_PATH="$tmp_dir"
    red "Cloudflare 远程路由移除结果未决，已保留不含 API token 的恢复证据：${tmp_dir}"
    return 2
}

# 防火墙规则只由一个活动后端管理。本脚本仅删除记录在 firewall.state
# 中、确认由自己创建的精确规则；HY2 NAT 继续使用独立状态文件。
acquire_firewall_lock() {
    local lock_file="${FIREWALL_LOCK_FILE:-${work_dir}/.firewall.lock}"

    command_exists flock || { red "缺少 flock，拒绝在无锁状态修改防火墙。"; return 1; }
    mkdir -p -- "$(dirname "$lock_file")" || return 1
    if [ -e "$lock_file" ] || [ -L "$lock_file" ]; then
        [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
    fi
    exec {FIREWALL_LOCK_FD}>"$lock_file" || return 1
    if ! chmod 600 "$lock_file" || ! flock -x "$FIREWALL_LOCK_FD"; then
        exec {FIREWALL_LOCK_FD}>&-
        unset FIREWALL_LOCK_FD
        return 1
    fi
}

release_firewall_lock() {
    [ -n "${FIREWALL_LOCK_FD:-}" ] || return 0
    flock -u "$FIREWALL_LOCK_FD" >/dev/null 2>&1 || true
    exec {FIREWALL_LOCK_FD}>&-
    unset FIREWALL_LOCK_FD
}

select_firewall_backend() {
    local has_v4="${1:-0}"
    local has_v6="${2:-0}"
    local ufw_status firewalld_status raw_available=0 raw_missing=0

    [[ "$has_v4" =~ ^[01]$ && "$has_v6" =~ ^[01]$ ]] || return 1
    [ "$has_v4" = 1 ] || [ "$has_v6" = 1 ] || return 1

    if ufw_is_active; then ufw_status=0; else ufw_status=$?; fi
    case "$ufw_status" in 0|1) ;; *) return 1 ;; esac
    if firewalld_is_active; then firewalld_status=0; else firewalld_status=$?; fi
    case "$firewalld_status" in 0|1) ;; *) return 1 ;; esac
    [ "$ufw_status" = 0 ] && [ "$firewalld_status" = 0 ] && return 1
    if [ "$ufw_status" = 0 ]; then printf 'ufw\n'; return 0; fi
    if [ "$firewalld_status" = 0 ]; then printf 'firewalld\n'; return 0; fi
    if [ "$has_v4" = 1 ]; then
        if command_exists iptables; then raw_available=1; else raw_missing=1; fi
    fi
    if [ "$has_v6" = 1 ]; then
        if command_exists ip6tables; then raw_available=1; else raw_missing=1; fi
    fi
    if [ "$raw_available" = 0 ]; then
        if command_exists nft; then printf 'nft-unmanaged\n'; else printf 'none\n'; fi
        return 0
    fi
    if [ "$raw_missing" = 1 ]; then
        printf 'partial-raw\n'
        return 0
    fi
    printf 'raw\n'
}

read_firewall_state() {
    local state_file="${FIREWALL_STATE_FILE:-${work_dir}/firewall.state}"
    local line backend field2 field3 field4 field5 extra
    local saw_header=0
    FIREWALL_STATE_RECORDS=()

    [ -e "$state_file" ] || [ -L "$state_file" ] || return 0
    [ -f "$state_file" ] && [ ! -L "$state_file" ] && [ -r "$state_file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$saw_header" = 0 ]; then
            [ "$line" = version=1 ] || return 1
            saw_header=1
            continue
        fi
        [ -n "$line" ] || return 1
        IFS='|' read -r backend field2 field3 field4 field5 extra <<< "$line"
        [ -z "${extra:-}" ] || return 1
        case "$backend" in
            ufw)
                case "$field2" in 4|6) ;; *) return 1 ;; esac
                validate_port_value "$field3" firewall_state_port >/dev/null 2>&1 || return 1
                case "$field4" in tcp|udp) ;; *) return 1 ;; esac
                [ -z "$field5" ] || return 1
                ;;
            firewalld)
                case "$field2" in runtime|permanent) ;; *) return 1 ;; esac
                [[ "$field3" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
                validate_port_value "$field4" firewall_state_port >/dev/null 2>&1 || return 1
                case "$field5" in tcp|udp) ;; *) return 1 ;; esac
                ;;
            iptables)
                case "$field2" in 4|6) ;; *) return 1 ;; esac
                [ "$field3" = sing-box-pre ] || return 1
                validate_port_value "$field4" firewall_state_port >/dev/null 2>&1 || return 1
                case "$field5" in tcp|udp) ;; *) return 1 ;; esac
                ;;
            *) return 1 ;;
        esac
        FIREWALL_STATE_RECORDS+=("$line")
    done < "$state_file"
    [ "$saw_header" = 1 ]
}

write_firewall_state_records() {
    local state_file="${FIREWALL_STATE_FILE:-${work_dir}/firewall.state}"
    {
        printf 'version=1\n'
        [ "$#" -eq 0 ] || printf '%s\n' "$@"
    } | atomic_write_secret_file "$state_file"
}

write_firewall_recovery_records() {
    local recovery_file="${FIREWALL_RECOVERY_FILE:-${work_dir}/firewall.recovery}"
    {
        printf 'version=1\n'
        [ "$#" -eq 0 ] || printf '%s\n' "$@"
    } | atomic_write_secret_file "$recovery_file"
}

firewall_state_has_record() {
    local wanted="${1:-}"
    local record
    for record in "${FIREWALL_STATE_RECORDS[@]}"; do
        [ "$record" = "$wanted" ] && return 0
    done
    return 1
}

ufw_is_active() {
    local status_output status

    command_exists ufw || return 1
    status_output=$(LC_ALL=C ufw status 2>/dev/null)
    status=$?
    [ "$status" -eq 0 ] || return 2
    if printf '%s\n' "$status_output" | grep -Eqi '^Status:[[:space:]]*active[[:space:]]*$'; then
        return 0
    fi
    if printf '%s\n' "$status_output" | grep -Eqi '^Status:[[:space:]]*inactive[[:space:]]*$'; then
        return 1
    fi
    return 2
}

firewalld_is_active() {
    local status_output status

    command_exists firewall-cmd || return 1
    status_output=$(LC_ALL=C firewall-cmd --state 2>&1)
    status=$?
    if [ "$status" -eq 0 ] && [ "$status_output" = running ]; then
        return 0
    fi
    if [ "$status_output" = 'not running' ]; then
        return 1
    fi
    return 2
}

ufw_port_is_open() {
    local family="$1" port="$2" proto="$3" status_output active_status
    case "$family" in 4|6) ;; *) return 1 ;; esac
    if ufw_is_active; then active_status=0; else active_status=$?; fi
    [ "$active_status" -eq 0 ] || return 2
    status_output=$(LC_ALL=C ufw status numbered 2>/dev/null) || return 2
    printf '%s\n' "$status_output" | awk -v rule="${port}/${proto}" -v family="$family" '
        {
            line=$0
            sub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            field_count=split(line, fields, /[[:space:]]+/)
            if (family == 4 && field_count == 4 && fields[1] == rule &&
                toupper(fields[2]) == "ALLOW" && toupper(fields[3]) == "IN" &&
                fields[4] == "Anywhere") {
                found=1
            }
            if (family == 6 && field_count == 6 && fields[1] == rule &&
                tolower(fields[2]) == "(v6)" && toupper(fields[3]) == "ALLOW" &&
                toupper(fields[4]) == "IN" && fields[5] == "Anywhere" &&
                tolower(fields[6]) == "(v6)") {
                found=1
            }
        }
        END { exit !found }
    '
}

firewall_record_is_live() {
    local record="$1"
    local backend field2 field3 field4 field5 status
    IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
    case "$backend" in
        ufw)
            ufw_port_is_open "$field2" "$field3" "$field4"
            status=$?
            ;;
        firewalld)
            if [ "$field2" = permanent ]; then
                firewall-cmd --permanent --zone="$field3" --query-port="${field4}/${field5}" >/dev/null 2>&1
            else
                firewall-cmd --zone="$field3" --query-port="${field4}/${field5}" >/dev/null 2>&1
            fi
            status=$?
            ;;
        iptables)
            if [ "$field2" = 4 ]; then
                iptables -C INPUT -p "$field5" --dport "$field4" -m comment --comment "$field3" -j ACCEPT >/dev/null 2>&1
            else
                ip6tables -C INPUT -p "$field5" --dport "$field4" -m comment --comment "$field3" -j ACCEPT >/dev/null 2>&1
            fi
            status=$?
            ;;
        *) return 1 ;;
    esac
    case "$status" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

raw_port_is_open() {
    local family="$1" port="$2" proto="$3"
    if [ "$family" = 4 ]; then
        iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1
    else
        ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1
    fi
}

raw_input_policy_is_accept() {
    local family="$1" policy
    if [ "$family" = 4 ]; then
        policy=$(iptables -S INPUT 2>/dev/null | awk '$1 == "-P" && $2 == "INPUT" { print $3; exit }')
    else
        policy=$(ip6tables -S INPUT 2>/dev/null | awk '$1 == "-P" && $2 == "INPUT" { print $3; exit }')
    fi
    [ "$policy" = ACCEPT ]
}

raw_input_chain_is_unfiltered() {
    local family="${1:-}" rules

    case "$family" in
        4) rules=$(iptables -S INPUT 2>/dev/null) || return 2 ;;
        6) rules=$(ip6tables -S INPUT 2>/dev/null) || return 2 ;;
        *) return 2 ;;
    esac
    rules=$(printf '%s' "$rules" | tr -d '\r')
    [ "$rules" = '-P INPUT ACCEPT' ]
}

raw_command_uses_nft() {
    local family="${1:-}" version_output

    case "$family" in
        4) version_output=$(iptables -V 2>/dev/null) || return 2 ;;
        6) version_output=$(ip6tables -V 2>/dev/null) || return 2 ;;
        *) return 2 ;;
    esac
    [[ "$version_output" == *nf_tables* ]]
}

# Return 0 when an unmanaged nftables base chain actively handles INPUT,
# 1 when no such hook exists (including nft not installed), and 2 when the
# ruleset cannot be queried or parsed safely.  This helper never mutates nft.
nft_input_filter_status() {
    local ignore_v4="${1:-0}" ignore_v6="${2:-0}" ruleset status

    [[ "$ignore_v4" =~ ^[01]$ && "$ignore_v6" =~ ^[01]$ ]] || return 2
    command_exists nft || return 1
    ruleset=$(nft -j list ruleset 2>/dev/null) || return 2
    printf '%s' "$ruleset" | jq -e \
        'type == "object" and (.nftables | type == "array")' >/dev/null 2>&1 || return 2
    if printf '%s' "$ruleset" | jq -e --arg ignore_v4 "$ignore_v4" --arg ignore_v6 "$ignore_v6" \
        '[.nftables[]? | .chain? |
          select(type == "object" and .hook == "input") |
          select((((($ignore_v4 == "1") and .family == "ip" and .table == "filter" and .name == "INPUT") or
                   (($ignore_v6 == "1") and .family == "ip6" and .table == "filter" and .name == "INPUT"))) | not)] |
         length > 0' \
        >/dev/null 2>&1; then
        return 0
    else
        status=$?
    fi
    [ "$status" -eq 1 ] && return 1
    return 2
}

firewall_state_matches_backend() {
    local selected_backend="${1:-}" expected_backend record record_backend

    case "$selected_backend" in
        ufw) expected_backend=ufw ;;
        firewalld) expected_backend=firewalld ;;
        raw) expected_backend=iptables ;;
        none|nft-unmanaged|partial-raw)
            [ "${#FIREWALL_STATE_RECORDS[@]}" -eq 0 ]
            return
            ;;
        *) return 1 ;;
    esac
    for record in "${FIREWALL_STATE_RECORDS[@]}"; do
        record_backend="${record%%|*}"
        [ "$record_backend" = "$expected_backend" ] || return 1
    done
}

raw_firewall_persistence_available() {
    local family="${1:-}"

    case "$family" in 4|6) ;; *) return 1 ;; esac
    if command_exists netfilter-persistent; then
        return 0
    fi
    command_exists rc-service || return 1
    if [ "$family" = 4 ]; then
        rc-service -e iptables >/dev/null 2>&1
    else
        rc-service -e ip6tables >/dev/null 2>&1
    fi
}

add_firewall_record() {
    local record="$1"
    local backend field2 field3 field4 field5
    IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
    case "$backend" in
        ufw)
            if [ "$field2" = 4 ]; then
                ufw allow in proto "$field4" to 0.0.0.0/0 port "$field3" >/dev/null 2>&1
            else
                ufw allow in proto "$field4" to ::/0 port "$field3" >/dev/null 2>&1
            fi
            ;;
        firewalld)
            if [ "$field2" = permanent ]; then
                firewall-cmd --permanent --zone="$field3" --add-port="${field4}/${field5}" >/dev/null 2>&1
            else
                firewall-cmd --zone="$field3" --add-port="${field4}/${field5}" >/dev/null 2>&1
            fi
            ;;
        iptables)
            if [ "$field2" = 4 ]; then
                iptables -I INPUT -p "$field5" --dport "$field4" -m comment --comment "$field3" -j ACCEPT >/dev/null 2>&1
            else
                ip6tables -I INPUT -p "$field5" --dport "$field4" -m comment --comment "$field3" -j ACCEPT >/dev/null 2>&1
            fi
            ;;
        *) return 1 ;;
    esac
}

delete_firewall_record() {
    local record="$1"
    local backend field2 field3 field4 field5
    IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
    case "$backend" in
        ufw)
            if [ "$field2" = 4 ]; then
                ufw delete allow in proto "$field4" to 0.0.0.0/0 port "$field3" >/dev/null 2>&1
            else
                ufw delete allow in proto "$field4" to ::/0 port "$field3" >/dev/null 2>&1
            fi
            ;;
        firewalld)
            if [ "$field2" = permanent ]; then
                firewall-cmd --permanent --zone="$field3" --remove-port="${field4}/${field5}" >/dev/null 2>&1
            else
                firewall-cmd --zone="$field3" --remove-port="${field4}/${field5}" >/dev/null 2>&1
            fi
            ;;
        iptables)
            if [ "$field2" = 4 ]; then
                iptables -D INPUT -p "$field5" --dport "$field4" -m comment --comment "$field3" -j ACCEPT >/dev/null 2>&1
            else
                ip6tables -D INPUT -p "$field5" --dport "$field4" -m comment --comment "$field3" -j ACCEPT >/dev/null 2>&1
            fi
            ;;
        *) return 1 ;;
    esac
}

persist_raw_firewall_rules() {
    local family service_name
    local -a families=("$@")

    [ "${#families[@]}" -gt 0 ] || return 0
    if command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1
        return $?
    fi
    command_exists rc-service || return 1
    for family in "${families[@]}"; do
        case "$family" in
            4) service_name=iptables ;;
            6) service_name=ip6tables ;;
            *) return 1 ;;
        esac
        rc-service -e "$service_name" >/dev/null 2>&1 || return 1
        rc-service "$service_name" save >/dev/null 2>&1 || return 1
    done
}

rollback_added_firewall_records() {
    local status=0 index
    local -a records=("$@")
    for ((index=${#records[@]} - 1; index >= 0; index--)); do
        delete_firewall_record "${records[$index]}" || status=1
    done
    return "$status"
}

rollback_deleted_firewall_records() {
    local status=0 record
    for record in "$@"; do
        add_firewall_record "$record" || status=1
    done
    return "$status"
}

rollback_firewall_add_transaction() {
    local raw_families="${1:-}"
    shift
    local status=0
    local -a records=("$@") changed_families=()

    [ -z "$raw_families" ] || IFS=',' read -r -a changed_families <<< "$raw_families"

    rollback_added_firewall_records "${records[@]}" || status=1
    [ "${#changed_families[@]}" -eq 0 ] || \
        persist_raw_firewall_rules "${changed_families[@]}" >/dev/null 2>&1 || status=1
    if [ "$status" = 0 ]; then
        return 1
    fi
    write_firewall_recovery_records "${records[@]}" >/dev/null 2>&1 || true
    red "防火墙新规则回滚不完整，已保留 recovery 证据。"
    return 2
}

rollback_firewall_delete_transaction() {
    local raw_families="${1:-}"
    shift
    local status=0
    local -a records=("$@") changed_families=()

    [ -z "$raw_families" ] || IFS=',' read -r -a changed_families <<< "$raw_families"

    rollback_deleted_firewall_records "${records[@]}" || status=1
    [ "${#changed_families[@]}" -eq 0 ] || \
        persist_raw_firewall_rules "${changed_families[@]}" >/dev/null 2>&1 || status=1
    [ "$status" = 0 ] && return 1
    red "防火墙删除回滚不完整，已保留原 firewall.state 作为证据。"
    return 2
}

_allow_port_locked() {
    local has_v4=0 has_v6=0 backend zone port proto rule record family
    local raw_changed_csv='' state_changed=0 live_status compatibility_status persistence_missing=0
    local nft_ignore_v4=0 nft_ignore_v6=0 raw_version_status
    local recovery_file="${FIREWALL_RECOVERY_FILE:-${work_dir}/firewall.recovery}"
    local -a requested_rules=() added_records=() new_state_records=() created_ownership_records=() raw_changed_families=() raw_preflight_families=()

    FIREWALL_LAST_ADDED_RECORDS=()
    [ ! -e "$recovery_file" ] && [ ! -L "$recovery_file" ] || {
        red "存在未处理的 firewall.recovery，拒绝继续修改防火墙。"
        return 2
    }

    if [ "${1:-}" = --families ]; then
        [ "$#" -ge 4 ] || return 1
        has_v4="$2"
        has_v6="$3"
        shift 3
        [[ "$has_v4" =~ ^[01]$ && "$has_v6" =~ ^[01]$ ]] || return 1
    else
        ipv4_stack_available && has_v4=1
        ipv6_stack_available && has_v6=1
    fi
    [ "$has_v4" = 1 ] || [ "$has_v6" = 1 ] || return 1

    while [ "$#" -gt 0 ]; do
        rule="$1"
        if [[ "$rule" == */* ]]; then
            port="${rule%/*}"
            proto="${rule#*/}"
            shift
        else
            [ "$#" -ge 2 ] || { red "防火墙规则缺少协议: $rule"; return 1; }
            port="$1"
            proto="$2"
            shift 2
        fi
        validate_port_value "$port" firewall_port || return 1
        case "$proto" in tcp|udp) ;; *) red "不支持的防火墙协议: $proto"; return 1 ;; esac
        requested_rules+=("${port}|${proto}")
    done
    [ "${#requested_rules[@]}" -gt 0 ] || return 1

    read_firewall_state || { red "firewall.state 损坏或不安全，拒绝修改防火墙。"; return 1; }
    new_state_records=("${FIREWALL_STATE_RECORDS[@]}")
    backend=$(select_firewall_backend "$has_v4" "$has_v6") || { red "未找到可用的防火墙后端。"; return 1; }
    firewall_state_matches_backend "$backend" || {
        red "当前防火墙后端与 firewall.state 的所有权记录不一致，拒绝混用后端。"
        return 1
    }
    if command_exists nft; then
        if [ "$has_v4" = 1 ] && command_exists iptables; then
            if raw_command_uses_nft 4; then raw_version_status=0; else raw_version_status=$?; fi
            case "$raw_version_status" in
                0) nft_ignore_v4=1 ;;
                1) ;;
                *) red "无法确认 iptables 使用的后端，拒绝混用 nftables。"; return 2 ;;
            esac
        fi
        if [ "$has_v6" = 1 ] && command_exists ip6tables; then
            if raw_command_uses_nft 6; then raw_version_status=0; else raw_version_status=$?; fi
            case "$raw_version_status" in
                0) nft_ignore_v6=1 ;;
                1) ;;
                *) red "无法确认 ip6tables 使用的后端，拒绝混用 nftables。"; return 2 ;;
            esac
        fi
    fi
    if [ "$backend" = none ]; then
        yellow "未检测到本机防火墙后端；未修改本机规则，请确认云防火墙或安全组已放行所需端口。"
        return 0
    fi
    if [ "$backend" = nft-unmanaged ]; then
        if nft_input_filter_status 0 0; then compatibility_status=0; else compatibility_status=$?; fi
        case "$compatibility_status" in
            0)
                red "检测到 nftables INPUT 过滤链；脚本不会接管未知规则，请手动放行所需端口。"
                return 1
                ;;
            1)
                yellow "未检测到本机防火墙后端；nftables 没有 INPUT 过滤链，未修改本机规则。"
                return 0
                ;;
            *)
                red "无法安全确认 nftables INPUT 状态，拒绝跳过防火墙检查。"
                return 2
                ;;
        esac
    fi
    if [ "$backend" = partial-raw ]; then
        if nft_input_filter_status "$nft_ignore_v4" "$nft_ignore_v6"; then compatibility_status=0; else compatibility_status=$?; fi
        case "$compatibility_status" in
            0)
                red "双栈防火墙后端不完整，且检测到 nftables INPUT 过滤链；请手动放行端口。"
                return 1
                ;;
            1) ;;
            *)
                red "双栈防火墙后端不完整，且无法安全确认 nftables 状态。"
                return 2
                ;;
        esac
        for family in 4 6; do
            if [ "$family" = 4 ]; then
                [ "$has_v4" = 1 ] && command_exists iptables || continue
            else
                [ "$has_v6" = 1 ] && command_exists ip6tables || continue
            fi
            if raw_input_chain_is_unfiltered "$family"; then compatibility_status=0; else compatibility_status=$?; fi
            case "$compatibility_status" in
                0) ;;
                1)
                    red "双栈防火墙后端不完整，且现有 INPUT 链正在过滤；请手动放行端口。"
                    return 1
                    ;;
                *)
                    red "双栈防火墙后端不完整，且无法安全读取现有 INPUT 链。"
                    return 2
                    ;;
            esac
        done
        yellow "双栈防火墙后端不完整；现有 INPUT 链未启用过滤，本次未修改任何 family 的规则。"
        return 0
    fi
    if [ "$backend" = firewalld ]; then
        zone=$(firewall-cmd --get-default-zone 2>/dev/null) || return 1
        [[ "$zone" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    fi

    if [ "$backend" = raw ]; then
        if nft_input_filter_status "$nft_ignore_v4" "$nft_ignore_v6"; then
            compatibility_status=0
        else
            compatibility_status=$?
        fi
        case "$compatibility_status" in
            0)
                red "检测到不属于 iptables 兼容层的 nftables INPUT 过滤链；请手动放行端口。"
                return 1
                ;;
            1) ;;
            *)
                red "无法安全确认 raw 与 nftables 的 INPUT 链关系，拒绝修改防火墙。"
                return 2
                ;;
        esac
        for rule in "${requested_rules[@]}"; do
            port="${rule%|*}"
            proto="${rule#*|}"
            for family in 4 6; do
                [ "$family" = 4 ] && [ "$has_v4" = 0 ] && continue
                [ "$family" = 6 ] && [ "$has_v6" = 0 ] && continue
                record="iptables|${family}|sing-box-pre|${port}|${proto}"
                if firewall_record_is_live "$record"; then live_status=0; else live_status=$?; fi
                case "$live_status" in
                    0) ;;
                    1)
                        case " ${raw_preflight_families[*]} " in
                            *" ${family} "*) ;;
                            *) raw_preflight_families+=("$family") ;;
                        esac
                        ;;
                    *) return 1 ;;
                esac
            done
        done
        for family in "${raw_preflight_families[@]}"; do
            raw_firewall_persistence_available "$family" || persistence_missing=1
        done
        if [ "$persistence_missing" = 1 ]; then
            [ "${#FIREWALL_STATE_RECORDS[@]}" -eq 0 ] || {
                red "已有防火墙所有权记录，但原始规则持久化能力已丢失，拒绝静默降级。"
                return 1
            }
            for family in 4 6; do
                [ "$family" = 4 ] && [ "$has_v4" = 0 ] && continue
                [ "$family" = 6 ] && [ "$has_v6" = 0 ] && continue
                if raw_input_chain_is_unfiltered "$family"; then compatibility_status=0; else compatibility_status=$?; fi
                case "$compatibility_status" in
                    0) ;;
                    1)
                        red "原始防火墙缺少持久化能力，且现有 INPUT 链正在过滤；请手动放行端口。"
                        return 1
                        ;;
                    *)
                        red "原始防火墙缺少持久化能力，且无法安全读取 INPUT 链。"
                        return 2
                        ;;
                esac
            done
            yellow "原始防火墙缺少持久化能力，但 INPUT 链未启用过滤；未插入临时规则，请确认云安全组。"
            return 0
        fi
    fi

    for rule in "${requested_rules[@]}"; do
        port="${rule%|*}"
        proto="${rule#*|}"
        case "$backend" in
            ufw)
                for family in 4 6; do
                    [ "$family" = 4 ] && [ "$has_v4" = 0 ] && continue
                    [ "$family" = 6 ] && [ "$has_v6" = 0 ] && continue
                    record="ufw|${family}|${port}|${proto}"
                    if firewall_state_has_record "$record"; then
                        if firewall_record_is_live "$record"; then live_status=0; else live_status=$?; fi
                        case "$live_status" in
                            0) ;;
                            1)
                                add_firewall_record "$record" || {
                                    rollback_firewall_add_transaction '' "${added_records[@]}"
                                    return $?
                                }
                                added_records+=("$record")
                                ;;
                            *)
                                rollback_firewall_add_transaction '' "${added_records[@]}"
                                return $?
                                ;;
                        esac
                    else
                        if firewall_record_is_live "$record"; then live_status=0; else live_status=$?; fi
                        case "$live_status" in
                            0) ;;
                            1)
                                add_firewall_record "$record" || {
                                    rollback_firewall_add_transaction '' "${added_records[@]}"
                                    return $?
                                }
                                added_records+=("$record")
                                new_state_records+=("$record")
                                created_ownership_records+=("$record")
                                state_changed=1
                                ;;
                            *)
                                rollback_firewall_add_transaction '' "${added_records[@]}"
                                return $?
                                ;;
                        esac
                    fi
                done
                ;;
            firewalld)
                for family in runtime permanent; do
                    record="firewalld|${family}|${zone}|${port}|${proto}"
                    if firewall_state_has_record "$record"; then
                        if firewall_record_is_live "$record"; then live_status=0; else live_status=$?; fi
                        case "$live_status" in
                            0) ;;
                            1)
                                add_firewall_record "$record" || {
                                    rollback_firewall_add_transaction '' "${added_records[@]}"
                                    return $?
                                }
                                added_records+=("$record")
                                ;;
                            *)
                                rollback_firewall_add_transaction '' "${added_records[@]}"
                                return $?
                                ;;
                        esac
                    else
                        if firewall_record_is_live "$record"; then live_status=0; else live_status=$?; fi
                        case "$live_status" in
                            0) ;;
                            1)
                                add_firewall_record "$record" || {
                                    rollback_firewall_add_transaction '' "${added_records[@]}"
                                    return $?
                                }
                                added_records+=("$record")
                                new_state_records+=("$record")
                                created_ownership_records+=("$record")
                                state_changed=1
                                ;;
                            *)
                                rollback_firewall_add_transaction '' "${added_records[@]}"
                                return $?
                                ;;
                        esac
                    fi
                done
                ;;
            raw)
                for family in 4 6; do
                    [ "$family" = 4 ] && [ "$has_v4" = 0 ] && continue
                    [ "$family" = 6 ] && [ "$has_v6" = 0 ] && continue
                    record="iptables|${family}|sing-box-pre|${port}|${proto}"
                    # INPUT's default policy and unrelated ACCEPT rules do not
                    # prove reachability; only our head-inserted marker counts.
                    if firewall_record_is_live "$record"; then live_status=0; else live_status=$?; fi
                    case "$live_status" in
                        0) ;;
                        1)
                            raw_firewall_persistence_available "$family" || {
                                raw_changed_csv=$(IFS=,; printf '%s' "${raw_changed_families[*]}")
                                rollback_firewall_add_transaction "$raw_changed_csv" "${added_records[@]}"
                                return $?
                            }
                            add_firewall_record "$record" || {
                                raw_changed_csv=$(IFS=,; printf '%s' "${raw_changed_families[*]}")
                                rollback_firewall_add_transaction "$raw_changed_csv" "${added_records[@]}"
                                return $?
                            }
                            added_records+=("$record")
                            case " ${raw_changed_families[*]} " in
                                *" ${family} "*) ;;
                                *) raw_changed_families+=("$family") ;;
                            esac
                            if ! firewall_state_has_record "$record"; then
                                new_state_records+=("$record")
                                created_ownership_records+=("$record")
                                state_changed=1
                            fi
                            ;;
                        *)
                            raw_changed_csv=$(IFS=,; printf '%s' "${raw_changed_families[*]}")
                            rollback_firewall_add_transaction "$raw_changed_csv" "${added_records[@]}"
                            return $?
                            ;;
                    esac
                done
                ;;
        esac
    done

    raw_changed_csv=$(IFS=,; printf '%s' "${raw_changed_families[*]}")
    if [ "${#raw_changed_families[@]}" -gt 0 ] && \
       ! persist_raw_firewall_rules "${raw_changed_families[@]}"; then
        rollback_firewall_add_transaction "$raw_changed_csv" "${added_records[@]}"
        return $?
    fi
    if [ "$state_changed" = 1 ] && ! write_firewall_state_records "${new_state_records[@]}"; then
        rollback_firewall_add_transaction "$raw_changed_csv" "${added_records[@]}"
        return $?
    fi
    FIREWALL_LAST_ADDED_RECORDS=("${created_ownership_records[@]}")
}

allow_port() {
    local status
    acquire_firewall_lock || return 1
    _allow_port_locked "$@"
    status=$?
    release_firewall_lock
    return "$status"
}

firewall_record_backend_available() {
    local record="$1" backend field2 field3 field4 field5
    IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
    case "$backend" in
        ufw) ufw_is_active ;;
        firewalld) firewalld_is_active ;;
        iptables)
            if [ "$field2" = 4 ]; then command_exists iptables; else command_exists ip6tables; fi
            ;;
        *) return 1 ;;
    esac
}

_remove_owned_firewall_records_locked() {
    local mode="${1:-}" state_file="${FIREWALL_STATE_FILE:-${work_dir}/firewall.state}"
    shift || return 1
    local wanted="${1:-}" record candidate backend field2 field3 field4 field5 record_rule
    local raw_changed_csv='' selected=0 family live_status
    local recovery_file="${FIREWALL_RECOVERY_FILE:-${work_dir}/firewall.recovery}"
    local -a exact_records=("$@") selected_records=() remaining_records=() deleted_records=() raw_changed_families=()

    [ ! -e "$recovery_file" ] && [ ! -L "$recovery_file" ] || {
        red "存在未处理的 firewall.recovery，拒绝自动删除并保留证据。"
        return 2
    }
    read_firewall_state || { red "firewall.state 损坏或不安全，拒绝删除防火墙规则。"; return 1; }
    [ -e "$state_file" ] || return 0
    if [ "$mode" = port ]; then
        [[ "$wanted" == */* ]] || return 1
        validate_port_value "${wanted%/*}" firewall_port || return 1
        case "${wanted#*/}" in tcp|udp) ;; *) return 1 ;; esac
    elif [ "$mode" = exact ]; then
        [ "${#exact_records[@]}" -gt 0 ] || return 0
    elif [ "$mode" != all ]; then
        return 1
    fi

    for record in "${FIREWALL_STATE_RECORDS[@]}"; do
        IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
        case "$backend" in
            ufw) record_rule="${field3}/${field4}" ;;
            firewalld|iptables) record_rule="${field4}/${field5}" ;;
            *) return 1 ;;
        esac
        selected=0
        if [ "$mode" = all ] || { [ "$mode" = port ] && [ "$record_rule" = "$wanted" ]; }; then
            selected=1
        elif [ "$mode" = exact ]; then
            for candidate in "${exact_records[@]}"; do
                [ "$candidate" = "$record" ] && { selected=1; break; }
            done
        fi
        if [ "$selected" = 1 ]; then
            selected_records+=("$record")
        else
            remaining_records+=("$record")
        fi
    done
    [ "${#selected_records[@]}" -gt 0 ] || return 0

    for record in "${selected_records[@]}"; do
        firewall_record_backend_available "$record" || return 1
        IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
        if firewall_record_is_live "$record"; then live_status=0; else live_status=$?; fi
        case "$live_status" in
            0)
                if [ "$backend" = iptables ] && ! raw_firewall_persistence_available "$field2"; then
                    return 1
                fi
                ;;
            1) ;;
            *) return 1 ;;
        esac
    done
    for record in "${selected_records[@]}"; do
        IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
        if firewall_record_is_live "$record"; then live_status=0; else live_status=$?; fi
        case "$live_status" in
            0)
                if [ "$backend" = iptables ] && ! raw_firewall_persistence_available "$field2"; then
                    raw_changed_csv=$(IFS=,; printf '%s' "${raw_changed_families[*]}")
                    rollback_firewall_delete_transaction "$raw_changed_csv" "${deleted_records[@]}"
                    return $?
                fi
                if ! delete_firewall_record "$record"; then
                    raw_changed_csv=$(IFS=,; printf '%s' "${raw_changed_families[*]}")
                    rollback_firewall_delete_transaction "$raw_changed_csv" "${deleted_records[@]}"
                    return $?
                fi
                deleted_records+=("$record")
                if [[ "$record" == iptables\|* ]]; then
                    family="$field2"
                    case " ${raw_changed_families[*]} " in
                        *" ${family} "*) ;;
                        *) raw_changed_families+=("$family") ;;
                    esac
                fi
                ;;
            1) ;;
            *)
                raw_changed_csv=$(IFS=,; printf '%s' "${raw_changed_families[*]}")
                rollback_firewall_delete_transaction "$raw_changed_csv" "${deleted_records[@]}"
                return $?
                ;;
        esac
    done
    raw_changed_csv=$(IFS=,; printf '%s' "${raw_changed_families[*]}")
    if [ "${#raw_changed_families[@]}" -gt 0 ] && \
       ! persist_raw_firewall_rules "${raw_changed_families[@]}"; then
        rollback_firewall_delete_transaction "$raw_changed_csv" "${deleted_records[@]}"
        return $?
    fi

    if [ "${#remaining_records[@]}" -gt 0 ]; then
        if ! write_firewall_state_records "${remaining_records[@]}"; then
            rollback_firewall_delete_transaction "$raw_changed_csv" "${deleted_records[@]}"
            return $?
        fi
    elif ! rm -f -- "$state_file"; then
        rollback_firewall_delete_transaction "$raw_changed_csv" "${deleted_records[@]}"
        return $?
    fi
}

_remove_owned_firewall_port_locked() {
    if [ "${1:-}" = --all ]; then
        _remove_owned_firewall_records_locked all
    else
        _remove_owned_firewall_records_locked port "$1"
    fi
}

remove_owned_firewall_port() {
    local status
    acquire_firewall_lock || return 1
    _remove_owned_firewall_port_locked "$@"
    status=$?
    release_firewall_lock
    return "$status"
}

remove_owned_firewall_records_exact() {
    local status
    [ "$#" -gt 0 ] || return 0
    acquire_firewall_lock || return 1
    _remove_owned_firewall_records_locked exact "$@"
    status=$?
    release_firewall_lock
    return "$status"
}

_remove_owned_firewall_ports_locked() {
    local requested_rule record backend field2 field3 field4 field5 record_rule
    local -a requested_rules=("$@") exact_records=()

    [ "${#requested_rules[@]}" -gt 0 ] || return 0
    for requested_rule in "${requested_rules[@]}"; do
        [[ "$requested_rule" == */* ]] || return 1
        validate_port_value "${requested_rule%/*}" firewall_port || return 1
        case "${requested_rule#*/}" in tcp|udp) ;; *) return 1 ;; esac
    done
    read_firewall_state || return 1
    for record in "${FIREWALL_STATE_RECORDS[@]}"; do
        IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
        case "$backend" in
            ufw) record_rule="${field3}/${field4}" ;;
            firewalld|iptables) record_rule="${field4}/${field5}" ;;
            *) return 1 ;;
        esac
        for requested_rule in "${requested_rules[@]}"; do
            if [ "$record_rule" = "$requested_rule" ]; then
                exact_records+=("$record")
                break
            fi
        done
    done
    [ "${#exact_records[@]}" -gt 0 ] || return 0
    _remove_owned_firewall_records_locked exact "${exact_records[@]}"
}

remove_owned_firewall_ports() {
    local status

    [ "$#" -gt 0 ] || return 0
    acquire_firewall_lock || return 1
    _remove_owned_firewall_ports_locked "$@"
    status=$?
    release_firewall_lock
    return "$status"
}

configured_inbound_port_conflict_exists() {
    local inbounds_file="${1:-}"
    local port="${2:-}"
    local proto="${3:-}"
    local status

    validate_port_value "$port" configured_inbound_port >/dev/null 2>&1 || return 2
    case "$proto" in tcp|udp) ;; *) return 2 ;; esac
    [ -f "$inbounds_file" ] && [ ! -L "$inbounds_file" ] && [ -r "$inbounds_file" ] || return 2
    command_exists jq || return 2
    jq -e '
        type == "object" and
        (.inbounds | type == "array") and
        all(.inbounds[];
            type == "object" and
            ((.type // "") | type == "string") and
            ((.listen_port // 0) | type == "number")
        )
    ' "$inbounds_file" >/dev/null 2>&1 || return 2
    jq -e --argjson port "$port" --arg proto "$proto" '
        def protocol_matches:
            if (.type == "hysteria2" or .type == "tuic") then
                $proto == "udp"
            elif (.type == "socks" or .type == "shadowsocks") then
                ($proto == "tcp" or $proto == "udp")
            elif (.type == "vless" or .type == "vmess" or
                  .type == "trojan" or .type == "anytls") then
                $proto == "tcp"
            else
                true
            end;
        any(.inbounds[]; (.listen_port == $port) and protocol_matches)
    ' "$inbounds_file" >/dev/null 2>&1
    status=$?
    case "$status" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

configured_inbound_firewall_consumer_exists() {
    local inbounds_file="${1:-}"
    local port="${2:-}"
    local proto="${3:-}"
    local family="${4:-any}"
    local bindv6only=0 status

    validate_port_value "$port" firewall_consumer_port >/dev/null 2>&1 || return 2
    case "$proto" in tcp|udp) ;; *) return 2 ;; esac
    case "$family" in 4|6|any) ;; *) return 2 ;; esac
    [ -f "$inbounds_file" ] && [ ! -L "$inbounds_file" ] && [ -r "$inbounds_file" ] || return 2
    command_exists jq || return 2
    jq -e '
        type == "object" and
        (.inbounds | type == "array") and
        all(.inbounds[];
            type == "object" and
            ((.type // "") | type == "string") and
            ((.listen // "") | type == "string") and
            ((.listen_port // 0) | type == "number")
        )
    ' "$inbounds_file" >/dev/null 2>&1 || return 2
    bindv6only=$(get_bindv6only 2>/dev/null) || return 2
    case "$bindv6only" in 0|1) ;; *) return 2 ;; esac

    jq -e --argjson port "$port" --arg proto "$proto" \
        --arg family "$family" --argjson bindv6only "$bindv6only" '
        def protocol_matches:
            if (.type == "hysteria2" or .type == "tuic") then
                $proto == "udp"
            elif (.type == "socks" or .type == "shadowsocks") then
                ($proto == "tcp" or $proto == "udp")
            elif (.type == "vless" or .type == "vmess" or
                  .type == "trojan" or .type == "anytls") then
                $proto == "tcp"
            else
                true
            end;
        def is_ipv4: test("^[0-9]+(\\.[0-9]+){3}$");
        def is_ipv6: contains(":");
        def is_loopback:
            . == "localhost" or . == "::1" or test("^127\\.");
        def listener_matches:
            (.listen // "") as $listen |
            if $listen == "" then
                true
            elif ($listen | is_loopback) then
                false
            elif $family == "any" then
                true
            elif $family == "4" then
                ($listen == "0.0.0.0") or
                ($listen == "::" and $bindv6only == 0) or
                (($listen | is_ipv4) and ($listen | test("^127\\.") | not)) or
                (($listen | is_ipv4 | not) and ($listen | is_ipv6 | not))
            else
                ($listen == "::") or ($listen | is_ipv6) or
                (($listen | is_ipv4 | not) and ($listen | is_ipv6 | not))
            end;
        any(.inbounds[];
            (.listen_port == $port) and protocol_matches and listener_matches
        )
    ' "$inbounds_file" >/dev/null 2>&1
    status=$?
    case "$status" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

nginx_configured_port_conflict_exists() {
    local config_file="${1:-}"
    local port="${2:-}"
    local proto="${3:-}"

    validate_port_value "$port" nginx_configured_port >/dev/null 2>&1 || return 2
    case "$proto" in
        udp) return 1 ;;
        tcp) ;;
        *) return 2 ;;
    esac
    [ -e "$config_file" ] || [ -L "$config_file" ] || return 1
    [ -f "$config_file" ] && [ ! -L "$config_file" ] && [ -r "$config_file" ] || return 2
    awk -v wanted_port="$port" '
        {
            line=$0
            sub(/#.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line !~ /^listen[[:space:]]+/) next
            sub(/^listen[[:space:]]+/, "", line)
            target=line
            sub(/[[:space:];].*$/, "", target)
            candidate_port=""
            if (target ~ /^\[[^]]+\]:[0-9]+$/) {
                candidate_port=target
                sub(/^.*\]:/, "", candidate_port)
            } else if (target ~ /^[0-9]+$/) {
                candidate_port=target
            } else if (target ~ /:[0-9]+$/) {
                candidate_port=target
                sub(/^.*:/, "", candidate_port)
            }
            if (candidate_port == wanted_port) found=1
        }
        END { exit !found }
    ' "$config_file"
}

nginx_firewall_consumer_exists() {
    local config_file="${1:-}"
    local port="${2:-}"
    local family="${3:-any}"

    validate_port_value "$port" nginx_consumer_port >/dev/null 2>&1 || return 2
    case "$family" in 4|6|any) ;; *) return 2 ;; esac
    [ -e "$config_file" ] || [ -L "$config_file" ] || return 1
    [ -f "$config_file" ] && [ ! -L "$config_file" ] && [ -r "$config_file" ] || return 2

    awk -v wanted_port="$port" -v family="$family" '
        function is_v4(value) {
            return value ~ /^[0-9]+(\.[0-9]+){3}$/
        }
        function is_loopback(value) {
            return value == "localhost" || value == "::1" || value ~ /^127\./
        }
        function matches_family(host, options) {
            if (is_loopback(host)) return 0
            if (family == "any") return 1
            if (family == "4") {
                if (host == "" || host == "*" || host == "0.0.0.0") return 1
                if (host == "::") return options ~ /(^|[[:space:]])ipv6only=off([[:space:];]|$)/
                if (is_v4(host)) return 1
                if (index(host, ":") > 0) return 0
                return 1
            }
            if (host == "::") return 1
            if (index(host, ":") > 0) return 1
            if (is_v4(host) || host == "" || host == "*" || host == "0.0.0.0") return 0
            return 1
        }
        {
            line=$0
            sub(/#.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line !~ /^listen[[:space:]]+/) next
            sub(/^listen[[:space:]]+/, "", line)
            target=line
            sub(/[[:space:];].*$/, "", target)
            options=line
            sub(/^[^[:space:];]+[[:space:];]*/, "", options)
            host=""
            candidate_port=""
            if (target ~ /^\[[^]]+\]:[0-9]+$/) {
                host=target
                sub(/^\[/, "", host)
                sub(/\]:[0-9]+$/, "", host)
                candidate_port=target
                sub(/^.*\]:/, "", candidate_port)
            } else if (target ~ /^[0-9]+$/) {
                candidate_port=target
            } else if (target ~ /:[0-9]+$/) {
                host=target
                sub(/:[0-9]+$/, "", host)
                candidate_port=target
                sub(/^.*:/, "", candidate_port)
            } else {
                next
            }
            if (candidate_port == wanted_port && matches_family(host, options)) found=1
        }
        END { exit !found }
    ' "$config_file"
}

firewall_record_has_configured_consumer() {
    local record="${1:-}"
    local inbounds_file="${2:-}"
    local nginx_config="${3:-}"
    local backend field2 field3 field4 field5 family port proto status

    IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
    case "$backend" in
        ufw)
            family="$field2"
            port="$field3"
            proto="$field4"
            ;;
        firewalld)
            family=any
            port="$field4"
            proto="$field5"
            ;;
        iptables)
            family="$field2"
            port="$field4"
            proto="$field5"
            ;;
        *) return 2 ;;
    esac

    if configured_inbound_firewall_consumer_exists "$inbounds_file" "$port" "$proto" "$family"; then
        return 0
    else
        status=$?
    fi
    [ "$status" -eq 1 ] || return 2
    if [ "$proto" = tcp ] && [ -n "$nginx_config" ]; then
        if nginx_firewall_consumer_exists "$nginx_config" "$port" "$family"; then
            return 0
        else
            status=$?
        fi
        [ "$status" -eq 1 ] || return 2
    fi
    return 1
}

_remove_owned_firewall_ports_if_unused_locked() {
    local inbounds_file="${1:-}"
    shift || return 1
    local nginx_config='' requested_rule record backend field2 field3 field4 field5 record_rule status
    local -a requested_rules=() exact_records=()

    if [ "${1:-}" = --nginx-config ]; then
        [ "$#" -ge 3 ] || return 1
        nginx_config="$2"
        shift 2
    fi
    requested_rules=("$@")
    [ "${#requested_rules[@]}" -gt 0 ] || return 0
    for requested_rule in "${requested_rules[@]}"; do
        [[ "$requested_rule" == */* ]] || return 1
        validate_port_value "${requested_rule%/*}" firewall_port || return 1
        case "${requested_rule#*/}" in tcp|udp) ;; *) return 1 ;; esac
    done
    read_firewall_state || return 1
    for record in "${FIREWALL_STATE_RECORDS[@]}"; do
        IFS='|' read -r backend field2 field3 field4 field5 <<< "$record"
        case "$backend" in
            ufw) record_rule="${field3}/${field4}" ;;
            firewalld|iptables) record_rule="${field4}/${field5}" ;;
            *) return 1 ;;
        esac
        for requested_rule in "${requested_rules[@]}"; do
            [ "$record_rule" = "$requested_rule" ] || continue
            if firewall_record_has_configured_consumer "$record" "$inbounds_file" "$nginx_config"; then
                status=0
            else
                status=$?
            fi
            case "$status" in
                0) ;;
                1) exact_records+=("$record") ;;
                *) return 2 ;;
            esac
            break
        done
    done
    [ "${#exact_records[@]}" -gt 0 ] || return 0
    _remove_owned_firewall_records_locked exact "${exact_records[@]}"
}

remove_owned_firewall_ports_if_unused() {
    local status

    [ "$#" -gt 1 ] || return 1
    acquire_firewall_lock || return 1
    _remove_owned_firewall_ports_if_unused_locked "$@"
    status=$?
    release_firewall_lock
    return "$status"
}

remove_owned_firewall_rules() {
    remove_owned_firewall_port --all
}

configure_hy2_nat_family() {
    local firewall_cmd="${1:-}"
    local min_port="${2:-}"
    local max_port="${3:-}"
    local listen_port="${4:-}"
    local family_suffix attempt chain comment=''

    command_exists "$firewall_cmd" || return 1
    case "$firewall_cmd" in
        iptables) family_suffix=4 ;;
        ip6tables) family_suffix=6 ;;
        *) return 1 ;;
    esac

    if adopt_legacy_hy2_nat_family "$firewall_cmd" "$min_port" "$max_port" "$listen_port"; then
        return 0
    fi

    chain=''
    for attempt in $(seq 1 32); do
        # Linux limits iptables chain names to 28 characters.  Never reuse a
        # colliding name: a failed -N can mean an administrator owns it.
        printf -v chain 'SBHY2_%s_%x_%02d' "$family_suffix" "${BASHPID:-$$}" "$attempt"
        [ "${#chain}" -le 28 ] || return 1
        if "$firewall_cmd" -t nat -N "$chain" >/dev/null 2>&1; then
            break
        fi
        chain=''
    done
    [ -n "$chain" ] || return 1
    comment="sb-hy2-${chain}"

    if ! "$firewall_cmd" -t nat -A "$chain" -p udp --dport "${min_port}:${max_port}" \
        -m comment --comment "$comment" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1; then
        "$firewall_cmd" -t nat -X "$chain" >/dev/null 2>&1 || true
        return 1
    fi
    if ! "$firewall_cmd" -t nat -A PREROUTING -p udp -m comment --comment "$comment" \
        -j "$chain" >/dev/null 2>&1; then
        "$firewall_cmd" -t nat -D "$chain" -p udp --dport "${min_port}:${max_port}" \
            -m comment --comment "$comment" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1 || true
        "$firewall_cmd" -t nat -X "$chain" >/dev/null 2>&1 || true
        return 1
    fi

    HY2_NAT_CONFIGURED_RECORD="${firewall_cmd}|${chain}|${comment}|${min_port}|${max_port}|${listen_port}|created"
}

adopt_legacy_hy2_nat_family() {
    local firewall_cmd="${1:-}"
    local min_port="${2:-}"
    local max_port="${3:-}"
    local listen_port="${4:-}"
    local chain='PRENET_HY2'
    local comment='prenet-hy2'
    local expected_dnat expected_jump chain_rules prerouting_rules

    expected_dnat="-A ${chain} -p udp --dport ${min_port}:${max_port} -m comment --comment ${comment} -j DNAT --to-destination :${listen_port}"
    expected_jump="-A PREROUTING -p udp -m comment --comment ${comment} -j ${chain}"
    chain_rules=$("$firewall_cmd" -t nat -S "$chain" 2>/dev/null) || return 1
    prerouting_rules=$("$firewall_cmd" -t nat -S PREROUTING 2>/dev/null) || return 1

    [ "$(printf '%s\n' "$chain_rules" | grep -c '^-A ')" -eq 1 ] || return 1
    printf '%s\n' "$chain_rules" | grep -Fqx -- "$expected_dnat" || return 1
    [ "$(printf '%s\n' "$prerouting_rules" | grep -Fxc -- "$expected_jump")" -eq 1 ] || return 1
    HY2_NAT_CONFIGURED_RECORD="${firewall_cmd}|${chain}|${comment}|${min_port}|${max_port}|${listen_port}|adopted"
}

remove_hy2_nat_family() {
    local firewall_cmd="${1:-}"
    local chain="${2:-}"
    local comment="${3:-}"
    local min_port="${4:-}"
    local max_port="${5:-}"
    local listen_port="${6:-}"
    local state_file="${HY2_NAT_STATE_FILE:-${work_dir}/hy2-nat.state}"
    local family saved_chain saved_comment saved_min saved_max saved_listen saved_kind

    command_exists "$firewall_cmd" || return 1

    if [ -z "$chain" ]; then
        [ -r "$state_file" ] || return 0
        while IFS='|' read -r family saved_chain saved_comment saved_min saved_max saved_listen saved_kind; do
            [ "$family" = "$firewall_cmd" ] || continue
            chain="$saved_chain"
            comment="$saved_comment"
            min_port="$saved_min"
            max_port="$saved_max"
            listen_port="$saved_listen"
            break
        done < "$state_file"
    fi
    [ -n "$chain" ] && [ -n "$comment" ] && [ -n "$min_port" ] && \
        [ -n "$max_port" ] && [ -n "$listen_port" ] || return 0

    "$firewall_cmd" -t nat -C PREROUTING -p udp -m comment --comment "$comment" \
        -j "$chain" >/dev/null 2>&1 || return 1
    "$firewall_cmd" -t nat -C "$chain" -p udp --dport "${min_port}:${max_port}" \
        -m comment --comment "$comment" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1 || return 1

    "$firewall_cmd" -t nat -D PREROUTING -p udp -m comment --comment "$comment" \
        -j "$chain" >/dev/null 2>&1 || return 1
    if ! "$firewall_cmd" -t nat -D "$chain" -p udp --dport "${min_port}:${max_port}" \
        -m comment --comment "$comment" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1; then
        "$firewall_cmd" -t nat -A PREROUTING -p udp -m comment --comment "$comment" \
            -j "$chain" >/dev/null 2>&1 || true
        return 1
    fi
    if ! "$firewall_cmd" -t nat -X "$chain" >/dev/null 2>&1; then
        "$firewall_cmd" -t nat -A "$chain" -p udp --dport "${min_port}:${max_port}" \
            -m comment --comment "$comment" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1 || true
        "$firewall_cmd" -t nat -A PREROUTING -p udp -m comment --comment "$comment" \
            -j "$chain" >/dev/null 2>&1 || true
        return 1
    fi
}

restore_hy2_nat_record() {
    local record="${1:-}"
    local firewall_cmd chain comment min_port max_port listen_port record_kind

    IFS='|' read -r firewall_cmd chain comment min_port max_port listen_port record_kind <<< "$record"
    command_exists "$firewall_cmd" || return 1
    if ! "$firewall_cmd" -t nat -S "$chain" >/dev/null 2>&1; then
        "$firewall_cmd" -t nat -N "$chain" >/dev/null 2>&1 || return 1
    fi
    "$firewall_cmd" -t nat -C "$chain" -p udp --dport "${min_port}:${max_port}" \
        -m comment --comment "$comment" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1 || \
        "$firewall_cmd" -t nat -A "$chain" -p udp --dport "${min_port}:${max_port}" \
            -m comment --comment "$comment" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1 || return 1
    "$firewall_cmd" -t nat -C PREROUTING -p udp -m comment --comment "$comment" \
        -j "$chain" >/dev/null 2>&1 || \
        "$firewall_cmd" -t nat -A PREROUTING -p udp -m comment --comment "$comment" \
            -j "$chain" >/dev/null 2>&1 || return 1
}

remove_hy2_nat_records() {
    local -a records=("$@")
    local index record family chain comment min_port max_port listen_port record_kind restore_index

    for ((index = 0; index < ${#records[@]}; index++)); do
        record="${records[$index]}"
        IFS='|' read -r family chain comment min_port max_port listen_port record_kind <<< "$record"
        if ! remove_hy2_nat_family "$family" "$chain" "$comment" "$min_port" "$max_port" "$listen_port"; then
            for ((restore_index = index - 1; restore_index >= 0; restore_index--)); do
                restore_hy2_nat_record "${records[$restore_index]}" || true
            done
            return 1
        fi
    done
}

restore_hy2_nat_records() {
    local record
    for record in "$@"; do
        restore_hy2_nat_record "$record" || return 1
    done
}

rollback_new_hy2_nat_records() {
    local -a records=("$@")
    local index record family chain comment min_port max_port listen_port record_kind

    for ((index = ${#records[@]} - 1; index >= 0; index--)); do
        record="${records[$index]}"
        IFS='|' read -r family chain comment min_port max_port listen_port record_kind <<< "$record"
        [ "$record_kind" = created ] || continue
        remove_hy2_nat_family "$family" "$chain" "$comment" "$min_port" "$max_port" "$listen_port" || true
    done
}

write_hy2_nat_state_records() {
    local state_file="${HY2_NAT_STATE_FILE:-${work_dir}/hy2-nat.state}"
    local state_dir tmp_file record

    state_dir=$(dirname "$state_file") || return 1
    [ ! -L "$state_file" ] || return 1
    mkdir -p "$state_dir" || return 1
    tmp_file=$(mktemp "${state_dir}/.hy2-nat.state.XXXXXX") || return 1
    chmod 600 "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    for record in "$@"; do
        printf '%s\n' "$record" >> "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    done
    mv -f -- "$tmp_file" "$state_file" || { rm -f -- "$tmp_file"; return 1; }
    chmod 600 "$state_file"
}

persist_hy2_nat_rules() {
    local requested_family family service_name initd_dir
    local -a families=()

    for requested_family in "$@"; do
        case "$requested_family" in
            4|iptables) family=iptables ;;
            6|ip6tables) family=ip6tables ;;
            *) return 1 ;;
        esac
        case " ${families[*]} " in
            *" ${family} "*) ;;
            *) families+=("$family") ;;
        esac
    done
    [ "${#families[@]}" -gt 0 ] || return 0

    if command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1
        return $?
    fi

    if command_exists rc-service; then
        # Preflight every changed family before saving any of them, avoiding a
        # partial on-disk generation when (for example) only iptables exists.
        for service_name in "${families[@]}"; do
            rc-service -e "$service_name" >/dev/null 2>&1 || return 1
        done
        for service_name in "${families[@]}"; do
            rc-service "$service_name" save >/dev/null 2>&1 || return 1
        done
        return 0
    fi

    if command_exists service; then
        initd_dir="${HY2_INITD_DIR:-/etc/init.d}"
        for service_name in "${families[@]}"; do
            [ -x "${initd_dir}/${service_name}" ] || return 1
        done
        for service_name in "${families[@]}"; do
            service "$service_name" save >/dev/null 2>&1 || return 1
        done
        return 0
    fi

    return 1
}

read_hy2_nat_state_records() {
    local state_file="${HY2_NAT_STATE_FILE:-${work_dir}/hy2-nat.state}"
    local record delimiters family chain comment min_port max_port listen_port record_kind
    local baseline_min='' baseline_max='' baseline_listen='' count=0 seen_v4=0 seen_v6=0
    local -a records=() families=()

    HY2_NAT_STATE_RECORDS=()
    HY2_NAT_STATE_FAMILIES=()
    HY2_NAT_STATE_MIN=''
    HY2_NAT_STATE_MAX=''
    HY2_NAT_STATE_LISTEN=''
    [ -e "$state_file" ] || [ -L "$state_file" ] || return 1
    [ -s "$state_file" ] && [ -f "$state_file" ] && [ ! -L "$state_file" ] && \
        [ -r "$state_file" ] || return 2

    while IFS= read -r record || [ -n "$record" ]; do
        delimiters="${record//[!|]/}"
        [ "${#delimiters}" -eq 6 ] || return 2
        IFS='|' read -r family chain comment min_port max_port listen_port record_kind <<< "$record"
        case "$family" in
            iptables) [ "$seen_v4" -eq 0 ] || return 2; seen_v4=1 ;;
            ip6tables) [ "$seen_v6" -eq 0 ] || return 2; seen_v6=1 ;;
            *) return 2 ;;
        esac
        [ "${#chain}" -le 28 ] || return 2
        case "$record_kind" in
            created)
                if [ "$family" = iptables ]; then
                    [[ "$chain" =~ ^SBHY2_4_[0-9a-f]+_[0-9]{2}$ ]] || return 2
                else
                    [[ "$chain" =~ ^SBHY2_6_[0-9a-f]+_[0-9]{2}$ ]] || return 2
                fi
                [ "$comment" = "sb-hy2-${chain}" ] || return 2
                ;;
            adopted)
                [ "$chain" = PRENET_HY2 ] && [ "$comment" = prenet-hy2 ] || return 2
                ;;
            *) return 2 ;;
        esac
        validate_port_value "$min_port" hy2_state_min_port >/dev/null 2>&1 || return 2
        validate_port_value "$max_port" hy2_state_max_port >/dev/null 2>&1 || return 2
        validate_port_value "$listen_port" hy2_state_listen_port >/dev/null 2>&1 || return 2
        [ "$min_port" -lt "$max_port" ] || return 2
        if [ "$count" -eq 0 ]; then
            baseline_min="$min_port"
            baseline_max="$max_port"
            baseline_listen="$listen_port"
        elif [ "$min_port" != "$baseline_min" ] || [ "$max_port" != "$baseline_max" ] || \
             [ "$listen_port" != "$baseline_listen" ]; then
            return 2
        fi
        records+=("$record")
        families+=("$family")
        count=$((count + 1))
    done < "$state_file"
    [ "$count" -gt 0 ] || return 2

    HY2_NAT_STATE_RECORDS=("${records[@]}")
    HY2_NAT_STATE_FAMILIES=("${families[@]}")
    HY2_NAT_STATE_MIN="$baseline_min"
    HY2_NAT_STATE_MAX="$baseline_max"
    HY2_NAT_STATE_LISTEN="$baseline_listen"
}

hy2_nat_record_is_live() {
    local record="${1:-}"
    local firewall_cmd chain comment min_port max_port listen_port record_kind
    local chain_rules prerouting_rules command_status dnat_count jump_count chain_rule_count
    local expected_dnat expected_jump

    IFS='|' read -r firewall_cmd chain comment min_port max_port listen_port record_kind <<< "$record"
    command_exists "$firewall_cmd" || return 2
    if chain_rules=$("$firewall_cmd" -t nat -S "$chain" 2>/dev/null); then
        command_status=0
    else
        command_status=$?
    fi
    case "$command_status" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
    if prerouting_rules=$("$firewall_cmd" -t nat -S PREROUTING 2>/dev/null); then
        command_status=0
    else
        command_status=$?
    fi
    case "$command_status" in 0) ;; 1) return 1 ;; *) return 2 ;; esac

    expected_dnat="-A ${chain} -p udp --dport ${min_port}:${max_port} -m comment --comment ${comment} -j DNAT --to-destination :${listen_port}"
    expected_jump="-A PREROUTING -p udp -m comment --comment ${comment} -j ${chain}"
    chain_rule_count=$(printf '%s\n' "$chain_rules" | grep -c '^-A ' || true)
    dnat_count=$(printf '%s\n' "$chain_rules" | grep -Fxc -- "$expected_dnat" || true)
    jump_count=$(printf '%s\n' "$prerouting_rules" | grep -Fxc -- "$expected_jump" || true)
    if [ "$dnat_count" -eq 0 ] && [ "$chain_rule_count" -eq 0 ]; then
        return 1
    fi
    [ "$dnat_count" -eq 1 ] && [ "$chain_rule_count" -eq 1 ] || return 2
    case "$jump_count" in 1) return 0 ;; 0) return 1 ;; *) return 2 ;; esac
}

get_desired_hy2_nat_families() {
    HY2_DESIRED_NAT_FAMILIES=()
    ipv4_stack_available && command_exists iptables && HY2_DESIRED_NAT_FAMILIES+=(iptables)
    ipv6_stack_available && command_exists ip6tables && HY2_DESIRED_NAT_FAMILIES+=(ip6tables)
    [ "${#HY2_DESIRED_NAT_FAMILIES[@]}" -gt 0 ]
}

add_hy2_port_hopping() {
    local min_port="${1:-}"
    local max_port="${2:-}"
    local listen_port="${3:-}"
    local configured=0
    local -a configured_families=()
    local -a configured_records=()
    local -a new_records=()
    local -a old_records=()
    local -a records_to_remove=()
    local state_file="${HY2_NAT_STATE_FILE:-${work_dir}/hy2-nat.state}"
    local same_configuration=1 exact_family_set=1 record family live_status state_status
    local desired_v4=0 desired_v6=0 state_v4=0 state_v6=0

    validate_port_value "$min_port" hy2_hop_min_port || return 1
    validate_port_value "$max_port" hy2_hop_max_port || return 1
    validate_port_value "$listen_port" hy2_listen_port || return 1
    [ "$min_port" -lt "$max_port" ] || return 1

    get_desired_hy2_nat_families || return 1
    for family in "${HY2_DESIRED_NAT_FAMILIES[@]}"; do
        case "$family" in iptables) desired_v4=1 ;; ip6tables) desired_v6=1 ;; esac
    done

    if read_hy2_nat_state_records; then
        state_status=0
    else
        state_status=$?
    fi
    case "$state_status" in
        0)
            old_records=("${HY2_NAT_STATE_RECORDS[@]}")
            [ "$HY2_NAT_STATE_MIN" = "$min_port" ] && \
                [ "$HY2_NAT_STATE_MAX" = "$max_port" ] && \
                [ "$HY2_NAT_STATE_LISTEN" = "$listen_port" ] || same_configuration=0
            for family in "${HY2_NAT_STATE_FAMILIES[@]}"; do
                case "$family" in iptables) state_v4=1 ;; ip6tables) state_v6=1 ;; esac
            done
            [ "$desired_v4" -eq "$state_v4" ] && [ "$desired_v6" -eq "$state_v6" ] || \
                exact_family_set=0
            for record in "${old_records[@]}"; do
                if hy2_nat_record_is_live "$record"; then live_status=0; else live_status=$?; fi
                case "$live_status" in
                    0) ;;
                    *) return 2 ;;
                esac
            done
            if [ "$same_configuration" -eq 1 ] && [ "$exact_family_set" -eq 1 ]; then
                return 0
            fi
            if [ "$same_configuration" -eq 1 ]; then
                for record in "${old_records[@]}"; do
                    family="${record%%|*}"
                    if { [ "$family" = iptables ] && [ "$desired_v4" -eq 1 ]; } || \
                       { [ "$family" = ip6tables ] && [ "$desired_v6" -eq 1 ]; }; then
                        configured_records+=("$record")
                        configured=1
                    else
                        records_to_remove+=("$record")
                    fi
                done
            else
                records_to_remove=("${old_records[@]}")
            fi
            ;;
        1) ;;
        *) return 2 ;;
    esac

    if [ "$desired_v4" -eq 1 ] && \
       { [ "$same_configuration" -eq 0 ] || [ "$state_v4" -eq 0 ]; }; then
        if ! configure_hy2_nat_family iptables "$min_port" "$max_port" "$listen_port"; then
            return 1
        fi
        configured_records+=("$HY2_NAT_CONFIGURED_RECORD")
        new_records+=("$HY2_NAT_CONFIGURED_RECORD")
        [[ "$HY2_NAT_CONFIGURED_RECORD" != *'|created' ]] || configured_families+=(iptables)
        configured=1
    fi
    if [ "$desired_v6" -eq 1 ] && \
       { [ "$same_configuration" -eq 0 ] || [ "$state_v6" -eq 0 ]; }; then
        if ! configure_hy2_nat_family ip6tables "$min_port" "$max_port" "$listen_port"; then
            rollback_new_hy2_nat_records "${new_records[@]}"
            return 1
        fi
        configured_records+=("$HY2_NAT_CONFIGURED_RECORD")
        new_records+=("$HY2_NAT_CONFIGURED_RECORD")
        [[ "$HY2_NAT_CONFIGURED_RECORD" != *'|created' ]] || configured_families+=(ip6tables)
        configured=1
    fi
    [ "$configured" -eq 1 ] || return 1
    if ! persist_hy2_nat_rules "${configured_families[@]}"; then
        rollback_new_hy2_nat_records "${new_records[@]}"
        persist_hy2_nat_rules "${configured_families[@]}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! write_hy2_nat_state_records "${configured_records[@]}"; then
        rollback_new_hy2_nat_records "${new_records[@]}"
        persist_hy2_nat_rules "${configured_families[@]}" >/dev/null 2>&1 || true
        return 1
    fi

    if [ "${#records_to_remove[@]}" -gt 0 ]; then
        local -a old_families=()
        for record in "${records_to_remove[@]}"; do
            family="${record%%|*}"
            case " ${old_families[*]} " in
                *" ${family} "*) ;;
                *) old_families+=("$family") ;;
            esac
        done
        if ! remove_hy2_nat_records "${records_to_remove[@]}"; then
            rollback_new_hy2_nat_records "${new_records[@]}"
            write_hy2_nat_state_records "${old_records[@]}" >/dev/null 2>&1 || true
            persist_hy2_nat_rules "${old_families[@]}" "${configured_families[@]}" >/dev/null 2>&1 || true
            return 1
        fi
        if ! persist_hy2_nat_rules "${old_families[@]}"; then
            restore_hy2_nat_records "${records_to_remove[@]}" || true
            rollback_new_hy2_nat_records "${new_records[@]}"
            write_hy2_nat_state_records "${old_records[@]}" >/dev/null 2>&1 || true
            persist_hy2_nat_rules "${old_families[@]}" "${configured_families[@]}" >/dev/null 2>&1 || true
            return 1
        fi
    fi
}

read_active_hy2_port_hopping() {
    local expected_listen="${1:-}"
    local state_status

    HY2_ACTIVE_HOP_MIN=''
    HY2_ACTIVE_HOP_MAX=''
    HY2_ACTIVE_HOP_LISTEN=''
    if [ -n "$expected_listen" ]; then
        validate_port_value "$expected_listen" hy2_expected_listen >/dev/null 2>&1 || return 2
    fi
    if read_hy2_nat_state_records; then state_status=0; else state_status=$?; fi
    case "$state_status" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
    [ -z "$expected_listen" ] || [ "$HY2_NAT_STATE_LISTEN" = "$expected_listen" ] || return 2
    HY2_ACTIVE_HOP_MIN="$HY2_NAT_STATE_MIN"
    HY2_ACTIVE_HOP_MAX="$HY2_NAT_STATE_MAX"
    HY2_ACTIVE_HOP_LISTEN="$HY2_NAT_STATE_LISTEN"
}

remove_hy2_port_hopping() {
    local status=0 state_status
    local state_file="${HY2_NAT_STATE_FILE:-${work_dir}/hy2-nat.state}"
    local -a records=() changed_families=()
    local record family chain comment min_port max_port listen_port record_kind

    if read_active_hy2_port_hopping; then
        state_status=0
    else
        state_status=$?
    fi
    case "$state_status" in
        0) ;;
        1) return 0 ;;
        *) return 1 ;;
    esac
    mapfile -t records < "$state_file" || return 1
    for record in "${records[@]}"; do
        family="${record%%|*}"
        case " ${changed_families[*]} " in
            *" ${family} "*) ;;
            *) changed_families+=("$family") ;;
        esac
    done

    remove_hy2_nat_records "${records[@]}" || return 1
    if ! persist_hy2_nat_rules "${changed_families[@]}"; then
        restore_hy2_nat_records "${records[@]}" || true
        persist_hy2_nat_rules "${changed_families[@]}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! rm -f -- "$state_file"; then
        restore_hy2_nat_records "${records[@]}" || true
        persist_hy2_nat_rules "${changed_families[@]}" >/dev/null 2>&1 || true
        return 1
    fi
    return "$status"
}

get_hy2_certificate_fingerprint() {
    local fingerprint

    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" 2>/dev/null) || return 1
    fingerprint=${fingerprint#*=}
    fingerprint=${fingerprint//:/%3A}
    [[ "$fingerprint" =~ ^[0-9A-Fa-f%]+$ ]] || return 1
    printf '%s\n' "$fingerprint"
}

get_hy2_node_label() {
    local label

    label=$(curl -fsm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null | \
        tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | \
        sed 's/ /_/g') || true
    [ -n "$label" ] || label="${hostname:-sing-box}"
    label=$(printf '%s' "$label" | tr -cd 'A-Za-z0-9._~-')
    [ -n "$label" ] || return 1
    printf '%s\n' "$label"
}

stage_hy2_client_file() {
    local mode="${1:-}"
    local min_port="${2:-}"
    local max_port="${3:-}"
    local listen_port="${4:-}"
    local server_ip="${5:-}"
    local fingerprint="${6:-}"
    local node_label="${7:-}"
    local line_count uuid url_host replacement staged_file

    [ -f "$client_dir" ] || return 1
    line_count=$(grep -c '^hysteria2://' "$client_dir" 2>/dev/null || true)
    [ "$line_count" -eq 1 ] || return 1
    staged_file=$(mktemp "$(dirname "$client_dir")/.hy2-client.XXXXXX") || return 1

    case "$mode" in
        enable)
            validate_port_value "$min_port" hy2_hop_min_port >/dev/null 2>&1 || { rm -f -- "$staged_file"; return 1; }
            validate_port_value "$max_port" hy2_hop_max_port >/dev/null 2>&1 || { rm -f -- "$staged_file"; return 1; }
            validate_port_value "$listen_port" hy2_listen_port >/dev/null 2>&1 || { rm -f -- "$staged_file"; return 1; }
            [ "$min_port" -lt "$max_port" ] || { rm -f -- "$staged_file"; return 1; }
            uuid=$(sed -n 's#^hysteria2://\([^@]*\)@.*#\1#p' "$client_dir")
            [[ "$uuid" =~ ^[A-Za-z0-9-]+$ ]] || { rm -f -- "$staged_file"; return 1; }
            [[ "$fingerprint" =~ ^[0-9A-Fa-f%]+$ ]] || { rm -f -- "$staged_file"; return 1; }
            [[ "$node_label" =~ ^[A-Za-z0-9._~-]+$ ]] || { rm -f -- "$staged_file"; return 1; }
            if [[ "$server_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                url_host="$server_ip"
            elif [[ "$server_ip" =~ ^\[[0-9A-Fa-f:]+\]$ ]]; then
                url_host="$server_ip"
            elif [[ "$server_ip" =~ ^[0-9A-Fa-f:]+$ && "$server_ip" == *:* ]]; then
                url_host="[$server_ip]"
            else
                rm -f -- "$staged_file"
                return 1
            fi
            replacement="hysteria2://${uuid}@${url_host}:${listen_port}?peer=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none&mport=${listen_port},${min_port}-${max_port}#${node_label}"
            awk -v replacement="$replacement" \
                '/^hysteria2:\/\// { print replacement; next } { print }' "$client_dir" > "$staged_file" || {
                rm -f -- "$staged_file"
                return 1
            }
            ;;
        disable)
            sed '/^hysteria2:/s/&mport=[^#&]*//g' "$client_dir" > "$staged_file" || {
                rm -f -- "$staged_file"
                return 1
            }
            ;;
        *)
            rm -f -- "$staged_file"
            return 1
            ;;
    esac

    chmod 600 "$staged_file" || { rm -f -- "$staged_file"; return 1; }
    HY2_STAGED_CLIENT_FILE="$staged_file"
}

atomic_replace_hy2_client() {
    local staged_file="${1:-}"
    local target_file="${2:-}"

    [ -f "$staged_file" ] && [ -n "$target_file" ] || return 1
    mv -f -- "$staged_file" "$target_file"
}

backup_hy2_menu_transaction() {
    local backup_dir="${1:-}"
    local baseline_min="${2:-}"
    local baseline_max="${3:-}"
    local baseline_listen="${4:-}"
    local state_file="${HY2_NAT_STATE_FILE:-${work_dir}/hy2-nat.state}"
    local -a files=(
        "$client_dir"
        "${work_dir}/base-sub.txt"
        "$combined_client_dir"
        "${work_dir}/all-sub.txt"
        "${work_dir}/sub.txt"
        "${work_dir}/cfy-sub.txt"
    )
    local index path family

    [ -d "$backup_dir" ] || return 1
    if [ -f "$state_file" ]; then
        cp -p -- "$state_file" "${backup_dir}/nat.state" || return 1
        : > "${backup_dir}/nat.present" || return 1
    elif [ -n "$baseline_min" ] && [ -n "$baseline_max" ] && [ -n "$baseline_listen" ]; then
        for family in iptables ip6tables; do
            if command_exists "$family" && \
               adopt_legacy_hy2_nat_family "$family" "$baseline_min" "$baseline_max" "$baseline_listen"; then
                printf '%s\n' "$HY2_NAT_CONFIGURED_RECORD" >> "${backup_dir}/nat.baseline" || return 1
            fi
        done
    fi
    for ((index = 0; index < ${#files[@]}; index++)); do
        path="${files[$index]}"
        if [ -f "$path" ]; then
            cp -p -- "$path" "${backup_dir}/file.${index}" || return 1
            : > "${backup_dir}/present.${index}" || return 1
        fi
    done
}

restore_hy2_client_snapshot() {
    local backup_dir="${1:-}"
    local tmp_file

    if [ -e "${backup_dir}/present.0" ]; then
        tmp_file=$(mktemp "$(dirname "$client_dir")/.hy2-restore.XXXXXX") || return 1
        cp -p -- "${backup_dir}/file.0" "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
        mv -f -- "$tmp_file" "$client_dir" || { rm -f -- "$tmp_file"; return 1; }
    else
        rm -f -- "$client_dir" || return 1
    fi
}

restore_hy2_subscription_snapshot() {
    local backup_dir="${1:-}"
    local -a files=(
        "${work_dir}/base-sub.txt"
        "$combined_client_dir"
        "${work_dir}/all-sub.txt"
        "${work_dir}/sub.txt"
        "${work_dir}/cfy-sub.txt"
    )
    local index slot path tmp_file

    for ((index = 0; index < ${#files[@]}; index++)); do
        path="${files[$index]}"
        slot=$((index + 1))
        if [ -e "${backup_dir}/present.${slot}" ]; then
            tmp_file=$(mktemp "$(dirname "$path")/.hy2-restore.XXXXXX") || return 1
            cp -p -- "${backup_dir}/file.${slot}" "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
            mv -f -- "$tmp_file" "$path" || { rm -f -- "$tmp_file"; return 1; }
        else
            rm -f -- "$path" || return 1
        fi
    done
}

restore_hy2_nat_snapshot() {
    local backup_dir="${1:-}"
    local state_file="${HY2_NAT_STATE_FILE:-${work_dir}/hy2-nat.state}"
    local record family
    local -a current_records=() old_records=() changed_families=()

    if [ -s "$state_file" ]; then
        mapfile -t current_records < "$state_file" || return 1
        for record in "${current_records[@]}"; do
            family="${record%%|*}"
            case " ${changed_families[*]} " in
                *" ${family} "*) ;;
                *) changed_families+=("$family") ;;
            esac
        done
        remove_hy2_nat_records "${current_records[@]}" || return 1
    fi
    if [ -e "${backup_dir}/nat.present" ]; then
        mapfile -t old_records < "${backup_dir}/nat.state" || return 1
        for record in "${old_records[@]}"; do
            family="${record%%|*}"
            case " ${changed_families[*]} " in
                *" ${family} "*) ;;
                *) changed_families+=("$family") ;;
            esac
        done
        restore_hy2_nat_records "${old_records[@]}" || return 1
        persist_hy2_nat_rules "${changed_families[@]}" || return 1
        write_hy2_nat_state_records "${old_records[@]}" || return 1
    elif [ -s "${backup_dir}/nat.baseline" ]; then
        mapfile -t old_records < "${backup_dir}/nat.baseline" || return 1
        for record in "${old_records[@]}"; do
            family="${record%%|*}"
            case " ${changed_families[*]} " in
                *" ${family} "*) ;;
                *) changed_families+=("$family") ;;
            esac
        done
        restore_hy2_nat_records "${old_records[@]}" || return 1
        persist_hy2_nat_rules "${changed_families[@]}" || return 1
        rm -f -- "$state_file" || return 1
    else
        persist_hy2_nat_rules "${changed_families[@]}" || return 1
        rm -f -- "$state_file" || return 1
    fi
}

restore_hy2_service_state() {
    local was_active="${1:-0}"

    if [ "$was_active" -eq 1 ]; then
        singbox_service_is_active && return 0
        restart_singbox || return 1
        singbox_service_is_active
    else
        if singbox_service_is_active; then
            stop_singbox || return 1
        fi
        ! singbox_service_is_active
    fi
}

rollback_hy2_menu_transaction() {
    local backup_dir="${1:-}"
    local was_active="${2:-0}"
    local status=0

    restore_hy2_nat_snapshot "$backup_dir" || status=1
    restore_hy2_client_snapshot "$backup_dir" || status=1
    restore_hy2_subscription_snapshot "$backup_dir" || status=1
    restore_hy2_service_state "$was_active" || status=1
    return "$status"
}

handle_hy2_menu_transaction_failure() {
    local backup_dir="${1:-}"
    local was_active="${2:-0}"
    local staged_file="${3:-}"

    if rollback_hy2_menu_transaction "$backup_dir" "$was_active"; then
        rm -f -- "$staged_file"
        rm -rf -- "$backup_dir"
        return 1
    fi

    rm -f -- "$staged_file"
    red "Hysteria2 事务回滚不完整。人工恢复路径: ${backup_dir}"
    return 2
}

_enable_hy2_port_hopping_transaction_locked() {
    local min_port="${1:-}"
    local max_port="${2:-}"
    local listen_port server_ip fingerprint node_label backup_dir staged_file was_active=0

    validate_port_value "$min_port" hy2_hop_min_port || return 1
    validate_port_value "$max_port" hy2_hop_max_port || return 1
    [ "$min_port" -lt "$max_port" ] || return 1
    listen_port=$(get_uniform_inbound_port "${conf_dir}/inbounds.json" hysteria2) || return 1
    validate_port_value "$listen_port" hy2_listen_port || return 1
    server_ip=$(get_realip) || return 1
    [ -n "$server_ip" ] || return 1
    fingerprint=$(get_hy2_certificate_fingerprint) || return 1
    node_label=$(get_hy2_node_label) || return 1
    stage_hy2_client_file enable "$min_port" "$max_port" "$listen_port" \
        "$server_ip" "$fingerprint" "$node_label" || return 1
    staged_file="$HY2_STAGED_CLIENT_FILE"

    backup_dir=$(mktemp -d "$(dirname "$client_dir")/.hy2-menu.XXXXXX") || {
        rm -f -- "$staged_file"
        return 1
    }
    chmod 700 "$backup_dir" || { rm -f -- "$staged_file"; rm -rf -- "$backup_dir"; return 1; }
    backup_hy2_menu_transaction "$backup_dir" "$min_port" "$max_port" "$listen_port" || {
        rm -f -- "$staged_file"
        rm -rf -- "$backup_dir"
        return 1
    }
    singbox_service_is_active && was_active=1

    if ! add_hy2_port_hopping "$min_port" "$max_port" "$listen_port" ||
       ! atomic_replace_hy2_client "$staged_file" "$client_dir" ||
       { [ "$was_active" -eq 1 ] && ! restart_singbox; } ||
       ! update_sub; then
        handle_hy2_menu_transaction_failure "$backup_dir" "$was_active" "$staged_file"
        return $?
    fi

    rm -rf -- "$backup_dir"
}

enable_hy2_port_hopping_transaction() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "Hysteria2 端口跳跃操作"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _enable_hy2_port_hopping_transaction_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

_disable_hy2_port_hopping_transaction_locked() {
    local backup_dir staged_file was_active=0

    stage_hy2_client_file disable || return 1
    staged_file="$HY2_STAGED_CLIENT_FILE"
    backup_dir=$(mktemp -d "$(dirname "$client_dir")/.hy2-menu.XXXXXX") || {
        rm -f -- "$staged_file"
        return 1
    }
    chmod 700 "$backup_dir" || { rm -f -- "$staged_file"; rm -rf -- "$backup_dir"; return 1; }
    backup_hy2_menu_transaction "$backup_dir" || {
        rm -f -- "$staged_file"
        rm -rf -- "$backup_dir"
        return 1
    }
    singbox_service_is_active && was_active=1

    if ! remove_hy2_port_hopping ||
       ! atomic_replace_hy2_client "$staged_file" "$client_dir" ||
       { [ "$was_active" -eq 1 ] && ! restart_singbox; } ||
       ! update_sub; then
        handle_hy2_menu_transaction_failure "$backup_dir" "$was_active" "$staged_file"
        return $?
    fi

    rm -rf -- "$backup_dir"
}

disable_hy2_port_hopping_transaction() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "Hysteria2 端口跳跃操作"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _disable_hy2_port_hopping_transaction_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

render_vless_reality_inbound() {
    local tag="${1:-}"
    local listen_address="${2:-}"

    [ -n "$tag" ] && [ -n "$listen_address" ] || return 1
    cat << EOF
    {
      "type": "vless",
      "tag": "$tag",
      "listen": "$listen_address",
      "listen_port": $vless_port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [""]
        }
      }
    }
EOF
}

render_argo_inbound() {
    cat << EOF
    {
      "type": "vless",
      "tag": "vless-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": $argo_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless-argo"
      }
    }
EOF
}

render_hysteria2_inbound() {
    local tag="${1:-}"
    local listen_address="${2:-}"

    [ -n "$tag" ] && [ -n "$listen_address" ] || return 1
    cat << EOF
    {
      "type": "hysteria2",
      "tag": "$tag",
      "listen": "$listen_address",
      "listen_port": $hy2_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "ignore_client_bandwidth": false,
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
      }
    }
EOF
}

render_tuic_inbound() {
    local tag="${1:-}"
    local listen_address="${2:-}"

    [ -n "$tag" ] && [ -n "$listen_address" ] || return 1
    cat << EOF
    {
      "type": "tuic",
      "tag": "$tag",
      "listen": "$listen_address",
      "listen_port": $tuic_port,
      "users": [
        {
          "uuid": "$uuid",
          "password": "$uuid"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
      }
    }
EOF
}

render_inbounds_config() {
    local has_v4="${1:-0}"
    local has_v6="${2:-0}"
    local bindv6only="${3:-0}"
    local listener suffix separator=''
    local -a listeners suffixes

    [[ "$has_v4" =~ ^[01]$ && "$has_v6" =~ ^[01]$ && "$bindv6only" =~ ^[01]$ ]] || return 1
    [ "$has_v4" = 1 ] || [ "$has_v6" = 1 ] || return 1

    if [ "$has_v4" = 1 ] && [ "$has_v6" = 1 ] && [ "$bindv6only" = 0 ]; then
        listeners=('::')
        suffixes=('')
    else
        if [ "$has_v4" = 1 ]; then
            listeners+=('0.0.0.0')
            suffixes+=('')
        fi
        if [ "$has_v6" = 1 ]; then
            listeners+=('::')
            if [ "$has_v4" = 1 ]; then
                suffixes+=('-ipv6')
            else
                suffixes+=('')
            fi
        fi
    fi

    printf '%s\n' '{' '  "inbounds": ['
    local index
    for index in "${!listeners[@]}"; do
        [ -z "$separator" ] || printf ',\n'
        listener="${listeners[$index]}"
        suffix="${suffixes[$index]}"
        render_vless_reality_inbound "vless-reality${suffix}" "$listener" || return 1
        separator=1
    done
    printf ',\n'
    render_argo_inbound || return 1
    for index in "${!listeners[@]}"; do
        printf ',\n'
        listener="${listeners[$index]}"
        suffix="${suffixes[$index]}"
        render_hysteria2_inbound "hysteria2${suffix}" "$listener" || return 1
    done
    for index in "${!listeners[@]}"; do
        printf ',\n'
        listener="${listeners[$index]}"
        suffix="${suffixes[$index]}"
        render_tuic_inbound "tuic${suffix}" "$listener" || return 1
    done
    printf '%s\n' '  ]' '}'
}

# Preserve allow_port's tri-state result: 0=committed/no local mutation needed,
# 1=safe failure, 2=firewall state unknown or recovery required.
open_install_firewall_ports() {
    local has_v4="${1:-0}" has_v6="${2:-0}" status

    if allow_port --families "$has_v4" "$has_v6" \
        "$vless_port/tcp" "$nginx_port/tcp" "$tuic_port/udp" "$hy2_port/udp"; then
        return 0
    else
        status=$?
    fi
    return "$status"
}

# 下载并安装 sing-box,cloudflared
install_singbox() {
    local has_v4=0
    local has_v6=0
    local bindv6only=0
    local dns_strategy
    local inbounds_json
    local firewall_status

    clear
    purple "正在安装sing-box中，请稍后..."
    if ! resolve_service_ports; then
        red "端口设置无效，安装中止。"
        return 1
    fi
    if ! check_service_ports_available; then
        red "检测到服务端口冲突，安装中止。"
        return 1
    fi
    ipv4_stack_available && has_v4=1
    ipv6_stack_available && has_v6=1
    if [ "$has_v4" = 0 ] && [ "$has_v6" = 0 ]; then
        red "未检测到可用的 IPv4 或 IPv6 网络栈，安装中止。"
        return 1
    fi
    bindv6only=$(get_bindv6only)
    if [ "$has_v4" = 1 ]; then
        dns_strategy="prefer_ipv4"
    else
        dns_strategy="prefer_ipv6"
    fi

    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64')  ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l')  ARCH='armv7' ;;
        's390x')   ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; return 1 ;;
    esac

    mkdir -p "${work_dir}" "${conf_dir}" || return 1
    chmod 755 "${work_dir}"
    # latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[] | select(.prerelease==false)][0].tag_name | sub("^v"; "")')
    # curl -sLo "${work_dir}/${server_name}.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${ARCH}.tar.gz"
    # curl -sLo "${work_dir}/qrencode" "https://github.com/eooce/test/releases/download/${ARCH}/qrencode-linux-${ARCH}"
    download_binary "https://$ARCH.ssss.nyc.mn/qrencode" "${work_dir}/qrencode" || return 1
    download_binary "https://$ARCH.ssss.nyc.mn/sbx-1.13.13" "${work_dir}/sing-box" || return 1
    download_binary "https://$ARCH.ssss.nyc.mn/bot" "${work_dir}/argo" || return 1
    # tar -xzvf "${work_dir}/${server_name}.tar.gz" -C "${work_dir}/" && \
    # mv "${work_dir}/sing-box-${latest_version}-linux-${ARCH}/sing-box" "${work_dir}/" && \
    # rm -rf "${work_dir}/${server_name}.tar.gz" "${work_dir}/sing-box-${latest_version}-linux-${ARCH}"
    chown root:root "${work_dir}" || return 1

    uuid=$(cat /proc/sys/kernel/random/uuid) || return 1
    password=$(generate_random_alphanumeric 24) || return 1
    output=$(/etc/sing-box/sing-box generate reality-keypair) || return 1
    private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')
    [ -n "$uuid" ] && [ -n "$password" ] && [ -n "$private_key" ] && [ -n "$public_key" ] || return 1

    if open_install_firewall_ports "$has_v4" "$has_v6"; then
        firewall_status=0
    else
        firewall_status=$?
    fi
    [ "$firewall_status" -eq 0 ] || return "$firewall_status"

    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key" || return 1
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com" || return 1
    chmod 600 "${work_dir}/private.key" 2>/dev/null || true

    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g') || return 1

    cat > "${conf_dir}/log.json" << EOF || return 1
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  }
}
EOF

    cat > ${conf_dir}/ntp.json << EOF || return 1
{
    "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
    }
}
EOF

    cat > "${conf_dir}/dns.json" << EOF || return 1
{
  "dns": {
    "servers": [
      {
        "tag": "local",
        "type": "local"
      }
    ],
    "strategy": "$dns_strategy"
  }
}
EOF

    inbounds_json=$(render_inbounds_config "$has_v4" "$has_v6" "$bindv6only") || return 1
    printf '%s\n' "$inbounds_json" | \
        atomic_write_secret_file "${conf_dir}/inbounds.json" || return 1

    atomic_write_secret_file "${conf_dir}/outbounds.json" << EOF || return 1
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    cat > "${conf_dir}/endpoints.json" << EOF || return 1
{
  "endpoints": []
}
EOF

    cat > "${conf_dir}/route.json" << EOF || return 1
{
  "route": {
    "rule_set": [
      {"tag":"gemini","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/gemini.srs","download_detour":"direct"},
      {"tag":"claude","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/claude.srs","download_detour":"direct"},
      {"tag":"openai","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs","download_detour":"direct"},
      {"tag":"tiktok","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/tiktok.srs","download_detour":"direct"},
      {"tag":"twitter","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/twitter.srs","download_detour":"direct"},
      {"tag":"google","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs","download_detour":"direct"},
      {"tag":"telegram","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs","download_detour":"direct"},
      {"tag":"youtube","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs","download_detour":"direct"},
      {"tag":"netflix","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs","download_detour":"direct"},
      {"tag":"streaming","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/proxymedia.srs","download_detour":"direct"}
    ],
    "rules": [],
    "final": "direct"
  }
}
EOF
    persist_install_settings "$install_env_file" || return 1
}

# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF || return 1
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    local argo_mode=""
    local tunnel_id=""
    local fixed_argo_requested=0
    ARGO_FIXED_READY=0
    if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
        fixed_argo_requested=1
        if ! is_argo_hostname "$ARGO_DOMAIN"; then
            yellow "ARGO_DOMAIN 格式不匹配，改用临时 Argo 隧道"
        elif [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
            tunnel_id=$(extract_argo_tunnel_id "$ARGO_AUTH")
            if [ -n "$tunnel_id" ]; then
                write_fixed_argo_credentials json "$ARGO_AUTH" || return 1
                atomic_write_secret_file "${work_dir}/tunnel.yml" << EOF || return 1
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://127.0.0.1:${ARGO_PORT}
  - service: http_status:404
EOF
                argo_mode=local
                ARGO_FIXED_READY=1
            else
                yellow "ARGO_AUTH 未解析到 TunnelID，改用临时 Argo 隧道"
            fi
        elif is_argo_tunnel_token "$ARGO_AUTH"; then
            write_fixed_argo_credentials token "$ARGO_AUTH" || return 1
            argo_mode=token
            ARGO_FIXED_READY=1
        else
            yellow "ARGO_AUTH 格式不匹配，改用临时 Argo 隧道"
        fi
    fi
    if [ -z "$argo_mode" ]; then
        if [ "$fixed_argo_requested" -eq 1 ]; then
            use_quick_argo_fallback
            yellow "固定 Argo 隧道配置未生效，已改用临时 Argo 隧道"
        fi
        argo_mode=quick
    fi
    write_argo_systemd_service "$argo_mode" || return 1
    if [ -f /etc/centos-release ]; then
        yum install -y chrony || return 1
        systemctl start chronyd || return 1
        systemctl enable chronyd || return 1
        chronyc -a makestep || return 1
        yum update -y ca-certificates || return 1
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range' || return 1
    fi
    systemctl daemon-reload || return 1
    systemctl enable sing-box || return 1
    systemctl start sing-box || return 1
    systemctl enable argo || return 1
    systemctl start argo || return 1
}

# 适配alpine 守护进程
alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF' || return 1
#!/sbin/openrc-run
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    local argo_mode=""
    local tunnel_id=""
    local fixed_argo_requested=0
    ARGO_FIXED_READY=0
    if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
        fixed_argo_requested=1
        if ! is_argo_hostname "$ARGO_DOMAIN"; then
            yellow "ARGO_DOMAIN 格式不匹配，改用临时 Argo 隧道"
        elif [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
            tunnel_id=$(extract_argo_tunnel_id "$ARGO_AUTH")
            if [ -n "$tunnel_id" ]; then
                write_fixed_argo_credentials json "$ARGO_AUTH" || return 1
                atomic_write_secret_file "${work_dir}/tunnel.yml" << EOF || return 1
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://127.0.0.1:${ARGO_PORT}
  - service: http_status:404
EOF
                argo_mode=local
                ARGO_FIXED_READY=1
            else
                yellow "ARGO_AUTH 未解析到 TunnelID，改用临时 Argo 隧道"
            fi
        elif is_argo_tunnel_token "$ARGO_AUTH"; then
            write_fixed_argo_credentials token "$ARGO_AUTH" || return 1
            argo_mode=token
            ARGO_FIXED_READY=1
        else
            yellow "ARGO_AUTH 格式不匹配，改用临时 Argo 隧道"
        fi
    fi
    if [ -z "$argo_mode" ]; then
        if [ "$fixed_argo_requested" -eq 1 ]; then
            use_quick_argo_fallback
            yellow "固定 Argo 隧道配置未生效，已改用临时 Argo 隧道"
        fi
        argo_mode=quick
    fi
    write_argo_openrc_service "$argo_mode" || return 1
    chmod +x /etc/init.d/sing-box || return 1
    chmod +x /etc/init.d/argo || return 1
    rc-update add sing-box default > /dev/null 2>&1 || return 1
    rc-update add argo default     > /dev/null 2>&1 || return 1
}

# 生成节点和订阅链接
get_info() {
    local url_file tmp_url_file

    yellow "\nip检测中,请稍等...\n"
    server_ipv4=$(get_public_ipv4 2>/dev/null || true)
    server_ipv6=$(get_public_ipv6 2>/dev/null || true)
    server_ip="${server_ipv4:-$server_ipv6}"
    if [ -z "$server_ip" ]; then
        server_ip=$(get_realip 2>/dev/null || true)
        if [[ "$server_ip" == \[*\] ]]; then
            server_ipv6="$server_ip"
        else
            server_ipv4="$server_ip"
        fi
    fi
    sub_host=$(get_subscription_host)
    clear

    country_code=$(get_country_code)
    if [ -n "$NODE_NAME" ]; then
        isp=$(sanitize_node_name "$NODE_NAME")
    else
        node_name=$(get_default_node_name)
        if [ -z "$SKIP_NODE_NAME_PROMPT" ] && [ -t 0 ]; then
            local vps_name_input
            reading "\n请输入VPS名称用于节点备注（回车保留当前名称：$(format_node_name_prefix "$country_code" "$node_name")）: " vps_name_input
            vps_name_input=$(sanitize_node_name "$vps_name_input")
            [ -n "$vps_name_input" ] && node_name="$vps_name_input"
        fi
        isp=$(format_node_name_prefix "$country_code" "$node_name")
    fi

    if [ "$ARGO_FIXED_READY" = "1" ] && [ -n "$ARGO_DOMAIN" ]; then
        argodomain="$ARGO_DOMAIN"
    else
        for i in {1..8}; do
            purple "第 $i 次尝试获取ArgoDomain中..."
            argodomain=$(get_latest_argo_domain)
            [ -n "$argodomain" ] && break
            sleep 2
        done
        if [ -z "$argodomain" ]; then
            restart_argo
            sleep 6
            argodomain=$(get_latest_argo_domain)
        fi
    fi
    if [ -n "$argodomain" ]; then
        green "\nArgoDomain：${purple}$argodomain${re}\n"
    else
        yellow "\n未获取到 ArgoDomain，跳过 VLESS-WS-TLS-Argo 节点，仅输出 Reality 节点\n"
    fi

    extra_lines=""
    if [ -f "${client_dir}" ]; then
        extra_lines=$(grep -vE '^(vless://|vmess://|hysteria2://|tuic://)' "${client_dir}" || true)
    fi

    reality_v4_name="${isp}-vless-reality-ipv4"
    reality_v6_name="${isp}-vless-reality-ipv6"
    argo_name="${isp}-vless-ws-tls-argo"

    url_file="${client_dir:-${work_dir}/url.txt}"
    tmp_url_file=$(mktemp "${work_dir}/.tmp.url.txt.XXXXXX") || return 1
    if ! : > "$tmp_url_file"; then
        rm -f "$tmp_url_file"
        return 1
    fi
    if [ -n "$server_ipv4" ]; then
        if ! cat >> "$tmp_url_file" << EOF
vless://${uuid}@${server_ipv4}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&type=tcp&headerType=none#${reality_v4_name}
EOF
        then
            rm -f "$tmp_url_file"
            return 1
        fi
    fi

    if [ -n "$server_ipv6" ]; then
        if [ -s "$tmp_url_file" ] && ! printf '\n' >> "$tmp_url_file"; then
            rm -f "$tmp_url_file"
            return 1
        fi
        if ! cat >> "$tmp_url_file" << EOF
vless://${uuid}@${server_ipv6}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&type=tcp&headerType=none#${reality_v6_name}
EOF
        then
            rm -f "$tmp_url_file"
            return 1
        fi
    fi

    if [ -n "$argodomain" ]; then
        while IFS=$'\t' read -r argo_client_address argo_address_role; do
            [ -n "$argo_client_address" ] || continue
            argo_client_name="$argo_name"
            if [ "$argo_address_role" = "preferred" ]; then
                argo_client_name="${argo_name}-preferred"
            fi
            if [ -s "$tmp_url_file" ] && ! printf '\n' >> "$tmp_url_file"; then
                rm -f "$tmp_url_file"
                return 1
            fi
            if ! cat >> "$tmp_url_file" << EOF
vless://${uuid}@${argo_client_address}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo#${argo_client_name}
EOF
            then
                rm -f "$tmp_url_file"
                return 1
            fi
        done < <(list_argo_client_addresses "$CFIP" "$argodomain" "$ARGO_FIXED_READY")
    fi

    if [ "${INCLUDE_UDP_LINKS}" = "1" ]; then
        if ! cat >> "$tmp_url_file" << EOF

hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none#${isp}

tuic://${uuid}:${uuid}@${server_ip}:${tuic_port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${isp}
EOF
        then
            rm -f "$tmp_url_file"
            return 1
        fi
    fi

    if [ -n "$extra_lines" ]; then
        if ! printf '\n%s\n' "$extra_lines" >> "$tmp_url_file"; then
            rm -f "$tmp_url_file"
            return 1
        fi
    fi

    chmod 644 "$tmp_url_file" 2>/dev/null || { rm -f "$tmp_url_file"; return 1; }
    mv -f "$tmp_url_file" "$url_file" || { rm -f "$tmp_url_file"; return 1; }

    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < "$url_file"
    update_sub || return 1
    chmod 644 "${work_dir}/sub.txt" || return 1
    yellow "\n温馨提醒:"
    yellow "如果节点里的ip是ipv6的，可在 修改节点配置 菜单切换ipv4后重新订阅节点\n"
    red "如果hysteria2或tuic不通，请尝试将节点里的 "跳过证书验证" 设置为 "true" 或切换内核\n"
    local source_url
    source_url=$(resolve_installed_subscription_source_url "$sub_host" 2>/dev/null || true)
    [ -n "$source_url" ] || source_url=$(build_http_subscription_url "$sub_host" "$nginx_port" "/$password" 2>/dev/null || true)
    show_subscription_links "$source_url"
}

# nginx订阅配置
render_nginx_subscription_location() {
    local path="${1:-}"

    is_valid_http_subscription_path "$path" || return 1
    cat << EOF
    location = ${path} {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "private, no-store";
        add_header X-Content-Type-Options nosniff;
        access_log off;
        log_not_found off;
    }
EOF
}

render_nginx_subscription_server() {
    local port="${1:-}"
    local http_path="${2:-}"
    local https_path="${3:-}"
    local has_ipv6="${4:-1}"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
    is_valid_http_subscription_path "$http_path" || return 1
    if [ -n "$https_path" ]; then
        is_valid_subscription_path "$https_path" || return 1
    fi
    [[ "$has_ipv6" =~ ^[01]$ ]] || return 1

    cat << EOF
server {
    listen ${port};
EOF
    if [ "$has_ipv6" = 1 ]; then
        printf '    listen [::]:%s;\n' "$port"
    fi
    cat << EOF
    server_name _;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
EOF
    render_nginx_subscription_location "$http_path" || return 1
    if [ -n "$https_path" ] && [ "$https_path" != "$http_path" ]; then
        render_nginx_subscription_location "$https_path" || return 1
    fi
    cat << 'EOF'

    location / { return 404; }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
 }
EOF
}

get_nginx_subscription_port() {
    local config_file="${1:-${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}}"
    local port

    [ -r "$config_file" ] || return 1
    port=$(sed -n 's/^[[:space:]]*listen[[:space:]]\+\([0-9]\+\);.*/\1/p' "$config_file" | head -1)
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
    printf '%s\n' "$port"
}

get_nginx_subscription_paths() {
    local config_file="${1:-${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}}"
    local path

    [ -r "$config_file" ] || return 1
    while IFS= read -r path; do
        is_valid_http_subscription_path "$path" && printf '%s\n' "$path"
    done < <(sed -n 's/^[[:space:]]*location = \(\/[^[:space:]]*\)[[:space:]]*{.*/\1/p' "$config_file")
}

# Return 0 only for the exact Nginx server shape rendered and owned by this
# script, 1 when no config exists, and 2 for an unsafe/unmanaged config.  A
# parseable listen/location pair alone is not proof that we may overwrite it.
classify_nginx_subscription_config() {
    local config_file="${1:-${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}}"
    local port https_path=''
    local -a paths=()

    [ -e "$config_file" ] || [ -L "$config_file" ] || return 1
    [ -f "$config_file" ] && [ ! -L "$config_file" ] && [ -r "$config_file" ] || return 2
    port=$(get_nginx_subscription_port "$config_file") || return 2
    mapfile -t paths < <(get_nginx_subscription_paths "$config_file")
    [ "${#paths[@]}" -ge 1 ] && [ "${#paths[@]}" -le 2 ] || return 2
    if [ "${#paths[@]}" -eq 2 ]; then
        [ "${paths[0]}" != "${paths[1]}" ] || return 2
        https_path="${paths[1]}"
    fi

    if cmp -s -- "$config_file" <(render_nginx_subscription_server \
        "$port" "${paths[0]}" "$https_path" 0); then
        return 0
    fi
    if cmp -s -- "$config_file" <(render_nginx_subscription_server \
        "$port" "${paths[0]}" "$https_path" 1); then
        return 0
    fi
    return 2
}

# Validate the script-owned Nginx server together with its persisted state.
# One HTTP-only path may be a legacy install with no state file.  A managed
# state file must match that path exactly.  Two paths are accepted only when a
# complete enabled HTTPS state names both paths, preventing a stale origin from
# being started or rewritten after state loss.
validate_managed_subscription_runtime() {
    local config_file="${1:-${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}}"
    local expected_mode="${2:-any}"
    local config_status state_exists=0 token_from_http token_from_https
    local -a paths=()

    case "$expected_mode" in any|http|https) ;; *) return 2 ;; esac
    classify_nginx_subscription_config "$config_file"
    config_status=$?
    [ "$config_status" -eq 0 ] || return "$config_status"
    mapfile -t paths < <(get_nginx_subscription_paths "$config_file")
    [ "${#paths[@]}" -ge 1 ] && [ "${#paths[@]}" -le 2 ] || return 2

    if [ -e "$subscription_state_file" ] || [ -L "$subscription_state_file" ]; then
        [ -f "$subscription_state_file" ] && [ ! -L "$subscription_state_file" ] &&
            [ -r "$subscription_state_file" ] || return 2
        state_exists=1
    fi
    load_subscription_state

    if [ "${#paths[@]}" -eq 1 ]; then
        [ "$expected_mode" != https ] || return 2
        if [ "$state_exists" -eq 0 ]; then
            return 0
        fi
        [ "$SUB_HTTPS_ENABLED" = 0 ] || return 2
        [ "$SUB_HTTP_PATH" = "${paths[0]}" ] || return 2
        is_valid_subscription_token "$SUB_TOKEN" || return 2
        token_from_http="${paths[0]##*/}"
        [ "$SUB_TOKEN" = "$token_from_http" ] || return 2
        return 0
    fi

    [ "$expected_mode" != http ] || return 2
    [ "$state_exists" -eq 1 ] && [ "$SUB_HTTPS_ENABLED" = 1 ] || return 2
    [ "$SUB_HTTP_PATH" = "${paths[0]}" ] && [ "$SUB_HTTPS_PATH" = "${paths[1]}" ] || return 2
    token_from_http="${paths[0]##*/}"
    token_from_https="${paths[1]##*/}"
    [ "$SUB_TOKEN" = "$token_from_http" ] && [ "$SUB_TOKEN" = "$token_from_https" ] || return 2
}

select_nginx_http_subscription_path() {
    local config_file="${1:-${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}}"
    local path
    local -a paths

    mapfile -t paths < <(get_nginx_subscription_paths "$config_file")
    [ "${#paths[@]}" -gt 0 ] || return 1
    load_subscription_state
    if is_valid_http_subscription_path "${SUB_HTTP_PATH:-}"; then
        for path in "${paths[@]}"; do
            [ "$path" = "$SUB_HTTP_PATH" ] && { printf '%s\n' "$path"; return 0; }
        done
    fi
    printf '%s\n' "${paths[0]}"
}

resolve_installed_subscription_source_url() {
    local host="${1:-}"
    local config_file="${2:-${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}}"
    local port path

    port=$(get_nginx_subscription_port "$config_file") || return 1
    path=$(select_nginx_http_subscription_path "$config_file") || return 1
    load_subscription_state
    resolve_subscription_source_url "$host" "$port" "$path"
}

apply_nginx_subscription_config() {
    local port="${1:-}"
    local http_path="${2:-}"
    local https_path="${3:-}"
    local config_file="${5:-${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}}"
    local config_dir tmp_file backup_file had_config=0
    local preserve_service_state="${4:-start}"
    local has_ipv6=0

    command_exists nginx || { red "nginx未安装，无法配置订阅服务"; return 1; }
    case "$preserve_service_state" in 0|1|start) ;; *) return 1 ;; esac
    config_dir=$(dirname "$config_file")
    mkdir -p "$config_dir" || return 1
    tmp_file=$(mktemp "${config_dir}/.sing-box.conf.XXXXXX") || return 1
    backup_file="${config_file}.bak.sb"

    if declare -F ipv6_socket_available >/dev/null && ipv6_socket_available; then
        has_ipv6=1
    fi
    if ! render_nginx_subscription_server "$port" "$http_path" "$https_path" "$has_ipv6" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if [ -f "$config_file" ]; then
        cp -p "$config_file" "$backup_file" || { rm -f "$tmp_file"; return 1; }
        chmod 600 "$backup_file" 2>/dev/null || true
        had_config=1
    fi
    mv -f "$tmp_file" "$config_file" || return 1

    if ! nginx -t > /dev/null 2>&1; then
        if [ "$had_config" = 1 ]; then
            cp -p "$backup_file" "$config_file"
        else
            rm -f "$config_file"
        fi
        nginx -t > /dev/null 2>&1 || true
        return 1
    fi

    if [ "$preserve_service_state" = 0 ]; then
        return 0
    elif command_exists rc-service; then
        if ! rc-service nginx reload > /dev/null 2>&1 && ! rc-service nginx restart > /dev/null 2>&1; then
            if [ "$had_config" = 1 ]; then
                cp -p "$backup_file" "$config_file"
            else
                rm -f "$config_file"
            fi
            rc-service nginx restart > /dev/null 2>&1 || true
            return 1
        fi
    elif ! nginx -s reload > /dev/null 2>&1 && \
         { [ "$preserve_service_state" = 1 ] && ! restart_nginx > /dev/null 2>&1 ||
           [ "$preserve_service_state" = start ] && ! start_nginx > /dev/null 2>&1; }; then
        if [ "$had_config" = 1 ]; then
            cp -p "$backup_file" "$config_file"
        else
            rm -f "$config_file"
        fi
        restart_nginx > /dev/null 2>&1 || true
        return 1
    fi

    return 0
}

# Capture every local file and service state owned by the subscription
# frontend before a multi-step mutation.  The returned directory is kept
# separate from the durable registry so it also remains useful as recovery
# evidence after an unclean process death.
backup_subscription_frontend_snapshot() {
    local config_file="${1:-}"
    local state_file="${2:-}"
    local tunnel_file="${3:-}"
    local evidence_parent="${4:-}"
    local snapshot_dir nginx_was_active=0 argo_was_active=0

    [ -n "$config_file" ] && [ -n "$state_file" ] || return 1
    [ -d "$evidence_parent" ] && [ ! -L "$evidence_parent" ] || return 1
    for target in "$config_file" "$state_file"; do
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ -f "$target" ] && [ ! -L "$target" ] && [ -r "$target" ] || return 1
        fi
    done
    if [ -n "$tunnel_file" ] && { [ -e "$tunnel_file" ] || [ -L "$tunnel_file" ]; }; then
        [ -f "$tunnel_file" ] && [ ! -L "$tunnel_file" ] && [ -r "$tunnel_file" ] || return 1
    fi

    snapshot_dir=$(mktemp -d "${evidence_parent}/.subscription-frontend.XXXXXX") || return 1
    chmod 700 "$snapshot_dir" || { rm -rf -- "$snapshot_dir"; return 1; }
    if [ -e "$config_file" ]; then
        cp -p -- "$config_file" "$snapshot_dir/nginx.conf" || {
            rm -rf -- "$snapshot_dir"
            return 1
        }
        chmod 600 "$snapshot_dir/nginx.conf" || { rm -rf -- "$snapshot_dir"; return 1; }
        : > "$snapshot_dir/nginx.present"
    fi
    if [ -e "$state_file" ]; then
        cp -p -- "$state_file" "$snapshot_dir/subscription.state" || {
            rm -rf -- "$snapshot_dir"
            return 1
        }
        chmod 600 "$snapshot_dir/subscription.state" || { rm -rf -- "$snapshot_dir"; return 1; }
        : > "$snapshot_dir/state.present"
    fi
    nginx_service_is_active && nginx_was_active=1
    printf '%s\n' "$nginx_was_active" > "$snapshot_dir/nginx.active" || {
        rm -rf -- "$snapshot_dir"
        return 1
    }

    if [ -n "$tunnel_file" ]; then
        : > "$snapshot_dir/tunnel.enabled"
        if [ -e "$tunnel_file" ]; then
            cp -p -- "$tunnel_file" "$snapshot_dir/tunnel.yml" || {
                rm -rf -- "$snapshot_dir"
                return 1
            }
            chmod 600 "$snapshot_dir/tunnel.yml" || { rm -rf -- "$snapshot_dir"; return 1; }
            : > "$snapshot_dir/tunnel.present"
        fi
        if declare -F check_argo >/dev/null 2>&1 && check_argo >/dev/null 2>&1; then
            argo_was_active=1
        fi
        printf '%s\n' "$argo_was_active" > "$snapshot_dir/argo.active" || {
            rm -rf -- "$snapshot_dir"
            return 1
        }
    fi
    printf '%s\n' "$snapshot_dir"
}

subscription_frontend_snapshot_file_digest() {
    local target="${1:-}"

    [ -n "$target" ] || return 1
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        printf 'absent\n'
        return 0
    fi
    [ -f "$target" ] && [ ! -L "$target" ] && [ -r "$target" ] || return 1
    sha256sum "$target" | awk '{print $1}'
}

# Detect a valid-but-different managed frontend swapped in while an interactive
# prompt was open.  Both the live files and the just-created snapshot must
# still match the baseline captured before that prompt.
verify_subscription_frontend_snapshot_baseline() {
    local snapshot_dir="${1:-}"
    local config_file="${2:-}"
    local state_file="${3:-}"
    local tunnel_file="${4:-}"
    local baseline_config="${5:-}"
    local baseline_state="${6:-}"
    local baseline_tunnel="${7:-}"
    local current snapshot

    [ -d "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ] || return 1
    current=$(subscription_frontend_snapshot_file_digest "$config_file") || return 1
    [ "$current" = "$baseline_config" ] || return 1
    if [ -e "$snapshot_dir/nginx.present" ]; then
        snapshot=$(subscription_frontend_snapshot_file_digest "$snapshot_dir/nginx.conf") || return 1
    else
        snapshot=absent
    fi
    [ "$snapshot" = "$baseline_config" ] || return 1

    current=$(subscription_frontend_snapshot_file_digest "$state_file") || return 1
    [ "$current" = "$baseline_state" ] || return 1
    if [ -e "$snapshot_dir/state.present" ]; then
        snapshot=$(subscription_frontend_snapshot_file_digest \
            "$snapshot_dir/subscription.state") || return 1
    else
        snapshot=absent
    fi
    [ "$snapshot" = "$baseline_state" ] || return 1

    if [ -n "$tunnel_file" ]; then
        current=$(subscription_frontend_snapshot_file_digest "$tunnel_file") || return 1
        [ "$current" = "$baseline_tunnel" ] || return 1
        if [ -e "$snapshot_dir/tunnel.present" ]; then
            snapshot=$(subscription_frontend_snapshot_file_digest "$snapshot_dir/tunnel.yml") || return 1
        else
            snapshot=absent
        fi
        [ "$snapshot" = "$baseline_tunnel" ] || return 1
    fi
}

cleanup_subscription_frontend_snapshot() {
    local snapshot_dir="${1:-}"

    [ -d "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ] || return 1
    case "$(basename "$snapshot_dir")" in
        .subscription-frontend.*) ;;
        *) return 1 ;;
    esac
    rm -f -- \
        "$snapshot_dir/nginx.conf" "$snapshot_dir/nginx.present" \
        "$snapshot_dir/subscription.state" "$snapshot_dir/state.present" \
        "$snapshot_dir/tunnel.yml" "$snapshot_dir/tunnel.present" \
        "$snapshot_dir/tunnel.enabled" "$snapshot_dir/nginx.active" \
        "$snapshot_dir/argo.active" || return 1
    rmdir -- "$snapshot_dir"
}

restore_subscription_frontend_snapshot() {
    local snapshot_dir="${1:-}"
    local config_file="${2:-}"
    local state_file="${3:-}"
    local tunnel_file="${4:-}"
    local nginx_was_active argo_was_active=0 status=0

    [ -d "$snapshot_dir" ] && [ ! -L "$snapshot_dir" ] || return 1
    [ -n "$config_file" ] && [ -n "$state_file" ] || return 1
    [ ! -L "$config_file" ] && [ ! -L "$state_file" ] || return 1
    [ -f "$snapshot_dir/nginx.active" ] && [ ! -L "$snapshot_dir/nginx.active" ] || return 1
    nginx_was_active=$(cat "$snapshot_dir/nginx.active") || return 1
    case "$nginx_was_active" in 0|1) ;; *) return 1 ;; esac

    if [ -e "$snapshot_dir/nginx.present" ]; then
        [ -f "$snapshot_dir/nginx.conf" ] && [ ! -L "$snapshot_dir/nginx.conf" ] || return 1
        cp -p -- "$snapshot_dir/nginx.conf" "$config_file" || status=1
    else
        rm -f -- "$config_file" || status=1
    fi
    if [ -e "$snapshot_dir/state.present" ]; then
        [ -f "$snapshot_dir/subscription.state" ] && \
            [ ! -L "$snapshot_dir/subscription.state" ] || return 1
        cp -p -- "$snapshot_dir/subscription.state" "$state_file" || status=1
    else
        rm -f -- "$state_file" || status=1
    fi

    if [ -e "$snapshot_dir/tunnel.enabled" ]; then
        [ -n "$tunnel_file" ] && [ ! -L "$tunnel_file" ] || return 1
        if [ -e "$snapshot_dir/tunnel.present" ]; then
            [ -f "$snapshot_dir/tunnel.yml" ] && [ ! -L "$snapshot_dir/tunnel.yml" ] || return 1
            cp -p -- "$snapshot_dir/tunnel.yml" "$tunnel_file" || status=1
        else
            rm -f -- "$tunnel_file" || status=1
        fi
        [ -f "$snapshot_dir/argo.active" ] && [ ! -L "$snapshot_dir/argo.active" ] || return 1
        argo_was_active=$(cat "$snapshot_dir/argo.active") || return 1
        case "$argo_was_active" in 0|1) ;; *) return 1 ;; esac
        if [ "$argo_was_active" -eq 1 ]; then
            restart_argo >/dev/null 2>&1 || status=1
        elif declare -F check_argo >/dev/null 2>&1 && check_argo >/dev/null 2>&1; then
            stop_argo >/dev/null 2>&1 || status=1
        fi
    fi

    if command_exists nginx; then
        nginx -t >/dev/null 2>&1 || status=1
        if [ "$nginx_was_active" -eq 1 ]; then
            nginx -s reload >/dev/null 2>&1 || restart_nginx >/dev/null 2>&1 || status=1
        elif nginx_service_is_active; then
            stop_nginx_checked >/dev/null 2>&1 || status=1
        fi
    fi
    [ "$status" -eq 0 ]
}

rollback_subscription_frontend_signal_transaction() {
    local snapshot_dir="${1:-}"
    local config_file="${2:-}"
    local state_file="${3:-}"
    local tunnel_file="${4:-}"
    local pending_state="${5:-}"
    local status=0

    restore_subscription_frontend_snapshot "$snapshot_dir" "$config_file" \
        "$state_file" "$tunnel_file" || status=1
    if [ "${#DURABLE_TX_OWNED_RECORDS[@]}" -gt 0 ]; then
        remove_owned_firewall_records_exact "${DURABLE_TX_OWNED_RECORDS[@]}" || status=1
    fi
    if [ -n "$pending_state" ]; then
        rm -f -- "$pending_state" || status=1
    fi
    if [ "$status" -eq 0 ]; then
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || status=1
    fi
    [ "$status" -eq 0 ]
}

prepare_subscription_frontend_state_transaction() {
    local state_target="${1:-}"
    local pending_parent="${2:-}"
    local state_dir pending_state original_state_file

    [ -n "$state_target" ] && [ ! -L "$state_target" ] || return 1
    state_dir=$(dirname "$state_target")
    [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
    [ -n "$pending_parent" ] || pending_parent="$state_dir"
    [ -d "$pending_parent" ] && [ ! -L "$pending_parent" ] || return 1
    pending_state=$(mktemp "${pending_parent}/.subscription-state-pending.XXXXXX") || return 1
    rm -f -- "$pending_state" || return 1
    original_state_file="$subscription_state_file"
    subscription_state_file="$pending_state"
    if ! save_subscription_state; then
        subscription_state_file="$original_state_file"
        rm -f -- "$pending_state"
        return 1
    fi
    subscription_state_file="$original_state_file"
    chmod 600 "$pending_state" || { rm -f -- "$pending_state"; return 1; }
    printf '%s\n' "$pending_state"
}

commit_subscription_frontend_state_transaction() {
    local pending_state="${1:-}"
    local state_target="${2:-}"

    [ -f "$pending_state" ] && [ ! -L "$pending_state" ] || return 1
    [ -n "$state_target" ] && [ ! -L "$state_target" ] || return 1
    mv -f -- "$pending_state" "$state_target" || return 1
    chmod 600 "$state_target"
}

add_nginx_conf() {
    local http_end_line
    local main_conf="${NGINX_MAIN_CONF:-/etc/nginx/nginx.conf}"
    local nginx_conf_dir="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
    local backup_file="${main_conf}.bak.sb"

    command_exists nginx || { red "nginx未安装，无法配置订阅服务"; return 1; }
    mkdir -p "$nginx_conf_dir" || return 1

    if [ -f "$main_conf" ]; then
        cp "$main_conf" "$backup_file" > /dev/null 2>&1 || return 1
        chmod 600 "$backup_file" 2>/dev/null || return 1
        sed -i -e '15{/include \/etc\/nginx\/modules\/\*\.conf/d;}' \
               -e '18{/include \/etc\/nginx\/conf\.d\/\*\.conf/d;}' "$main_conf" > /dev/null 2>&1 || return 1
        if ! grep -q "include.*conf.d" "$main_conf"; then
            http_end_line=$(grep -n "^}" "$main_conf" | tail -1 | cut -d: -f1)
            [ -n "$http_end_line" ] || return 1
            sed -i "${http_end_line}i \    include ${nginx_conf_dir}/*.conf;" "$main_conf" > /dev/null 2>&1 || return 1
        fi
    else
        cat > "$main_conf" << EOF || return 1
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events { worker_connections 1024; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    include ${nginx_conf_dir}/*.conf;
}
EOF
    fi

    if apply_nginx_subscription_config "$nginx_port" "/$password" ""; then
        green "nginx订阅配置已加载"
    else
        red "nginx订阅配置测试失败，已保留或恢复原配置"
        return 1
    fi
}

# 从已安装配置中获取UUID
get_current_uuid() {
    local inbounds_file="${conf_dir}/inbounds.json"
    if [ -f "$inbounds_file" ]; then
        local uuid
        uuid=$(jq -r '.inbounds[] | select(.type == "vless") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
        [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "vmess") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
        [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "hysteria2") | .users[0].password // empty' "$inbounds_file" 2>/dev/null | head -1)
        echo "$uuid"
    fi
}

# 通用服务管理函数
manage_service() {
    local service_name="$1"
    local action="$2"
    local service_file='' status='' check_status=0 action_status=1

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"; return 1
    fi

    case "$service_name" in
        sing-box) service_file="${work_dir}/${server_name:-sing-box}" ;;
        argo) service_file="${work_dir}/argo" ;;
        nginx) service_file=$(command -v nginx 2>/dev/null || true) ;;
    esac
    status=$(check_service "$service_name" "$service_file" 2>/dev/null) || check_status=$?

    case "$action" in
        "start")
            [ "$check_status" -eq 2 ] && { yellow "${service_name} 尚未安装!\n"; return 1; }
            case "$status" in
                *"not running"*) ;;
                *"running"*) yellow "${service_name} 正在运行\n"; return 0 ;;
            esac
            yellow "正在启动 ${service_name} 服务\n"
            if command_exists rc-service; then
                rc-service "$service_name" start
                action_status=$?
            elif command_exists systemctl; then
                if systemctl daemon-reload; then
                    systemctl start "$service_name"
                    action_status=$?
                fi
            fi
            ;;
        "stop")
            [ "$check_status" -eq 2 ] && { yellow "${service_name} 尚未安装！\n"; return 2; }
            case "$status" in
                *"not running"*) yellow "${service_name} 未运行\n"; return 1 ;;
            esac
            yellow "正在停止 ${service_name} 服务\n"
            if command_exists rc-service; then
                rc-service "$service_name" stop
                action_status=$?
            elif command_exists systemctl; then
                systemctl stop "$service_name"
                action_status=$?
            fi
            ;;
        "restart")
            [ "$check_status" -eq 2 ] && { yellow "${service_name} 尚未安装！\n"; return 1; }
            yellow "正在重启 ${service_name} 服务\n"
            if command_exists rc-service; then
                rc-service "$service_name" restart
                action_status=$?
            elif command_exists systemctl; then
                if systemctl daemon-reload; then
                    systemctl restart "$service_name"
                    action_status=$?
                fi
            fi
            ;;
        *)
            red "无效的操作: $action\n"; return 1 ;;
    esac

    if [ "$action_status" -eq 0 ]; then
        green "${service_name} 服务已成功${action}\n"
        return 0
    fi
    red "${service_name} 服务${action}失败\n"
    return "$action_status"
}
start_singbox()  { manage_service "sing-box" "start"; }
stop_singbox()   { manage_service "sing-box" "stop"; }
restart_singbox(){ manage_service "sing-box" "restart"; }
start_argo()     { manage_service "argo" "start"; }
stop_argo()      { manage_service "argo" "stop"; }
restart_argo()   { manage_service "argo" "restart"; }
start_nginx()    { manage_service "nginx" "start"; }
restart_nginx()  { manage_service "nginx" "restart"; }

nginx_service_is_active() {
    if command_exists rc-service; then
        rc-service nginx status >/dev/null 2>&1
    elif command_exists systemctl; then
        systemctl is-active --quiet nginx
    else
        return 1
    fi
}

stop_nginx_checked() {
    if command_exists rc-service; then
        rc-service nginx stop >/dev/null 2>&1
    elif command_exists systemctl; then
        systemctl stop nginx >/dev/null 2>&1
    else
        return 1
    fi
}

validate_singbox_config() {
    [ -x "${work_dir}/${server_name}" ] || return 0
    [ -d "${conf_dir}" ] || return 0
    "${work_dir}/${server_name}" check -C "${conf_dir}" >/dev/null 2>&1
}

validate_installed_singbox_config_strict() {
    [ -x "${work_dir}/${server_name}" ] || return 1
    [ -d "${conf_dir}" ] && [ ! -L "${conf_dir}" ] || return 1
    "${work_dir}/${server_name}" check -C "${conf_dir}" >/dev/null 2>&1
}

apply_jq_config() {
    local target_file="$1"
    shift
    local target_dir target_name tmp_file backup_file

    target_dir=$(dirname "$target_file")
    target_name=$(basename "$target_file")
    tmp_file=$(mktemp "${target_dir}/.tmp.${target_name}.XXXXXX") || return 1
    backup_file=$(mktemp "${target_dir}/.bak.${target_name}.XXXXXX") || { rm -f "$tmp_file"; return 1; }

    if ! jq "$@" "$target_file" > "$tmp_file"; then
        rm -f "$tmp_file" "$backup_file"
        red "failed to generate updated config: $target_file"
        return 1
    fi
    if ! jq empty "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file" "$backup_file"
        red "generated config is not valid JSON: $target_file"
        return 1
    fi

    cp -p "$target_file" "$backup_file" 2>/dev/null || cp "$target_file" "$backup_file" || { rm -f "$tmp_file" "$backup_file"; return 1; }
    if ! mv -f "$tmp_file" "$target_file"; then
        rm -f "$tmp_file" "$backup_file"
        return 1
    fi
    if ! validate_singbox_config; then
        mv -f "$backup_file" "$target_file" >/dev/null 2>&1 || true
        red "sing-box config check failed; rolled back $target_file"
        return 1
    fi

    rm -f "$backup_file"
}

update_public_inbound_port() {
    local target_file="$1"
    local protocol="$2"
    local port="$3"

    validate_port_value "$port" "${protocol}_port" || return 1
    case "$protocol" in
        reality)
            apply_jq_config "$target_file" --arg port "$port" \
                '(.inbounds[] |
                    select(.type == "vless" and ((.tag? // "") | startswith("vless-reality"))) |
                    .listen_port) = ($port | tonumber)'
            ;;
        hysteria2|tuic)
            apply_jq_config "$target_file" --arg protocol "$protocol" --arg port "$port" \
                '(.inbounds[] | select(.type == $protocol).listen_port) = ($port | tonumber)'
            ;;
        *) return 1 ;;
    esac || return 1
    validate_installed_singbox_config_strict
}

get_uniform_inbound_port() {
    local target_file="$1"
    local protocol="$2"
    local port

    port=$(jq -er --arg protocol "$protocol" '
        [.inbounds[] |
            select(
                if $protocol == "reality" then
                    (.type == "vless" and ((.tag? // "") | startswith("vless-reality")))
                else
                    .type == $protocol
                end
            ) |
            .listen_port] as $ports |
        if (($ports | length) > 0 and ($ports | unique | length) == 1)
        then $ports[0]
        else empty
        end
    ' "$target_file") || return 1
    validate_port_value "$port" "${protocol}_port" || return 1
    printf '%s\n' "$port"
}

rewrite_public_client_port() {
    local protocol="${1:-}"
    local port="${2:-}"
    local target_file="${3:-${client_dir}}"
    local target_dir tmp_file pattern

    validate_port_value "$port" "${protocol}_port" || return 1
    [ -f "$target_file" ] && [ ! -L "$target_file" ] || return 1
    case "$protocol" in
        reality) pattern='/flow=xtls-rprx-vision/' ;;
        hysteria2) pattern='/^hysteria2:\/\//' ;;
        tuic) pattern='/^tuic:\/\//' ;;
        *) return 1 ;;
    esac
    sed -n "${pattern}p" "$target_file" | grep -q . || return 1
    target_dir=$(dirname "$target_file") || return 1
    tmp_file=$(mktemp "${target_dir}/.port-client.XXXXXX") || return 1
    case "$protocol" in
        reality)
            sed -E '/flow=xtls-rprx-vision/ s#(vless://[^@]*@)(\[[^]]+\]|[^:/?#]+):[0-9]{1,5}#\1\2:'"$port"'#' \
                "$target_file" > "$tmp_file"
            ;;
        hysteria2)
            sed -E '/^hysteria2:\/\// {
                s#(hysteria2://[^@]*@)(\[[^]]+\]|[^:/?#]+):[0-9]{1,5}#\1\2:'"$port"'#
                s#([?&]mport=)[0-9]{1,5}(,)#\1'"$port"'\2#
            }' \
                "$target_file" > "$tmp_file"
            ;;
        tuic)
            sed -E '/^tuic:\/\// s#(tuic://[^@]*@)(\[[^]]+\]|[^:/?#]+):[0-9]{1,5}#\1\2:'"$port"'#' \
                "$target_file" > "$tmp_file"
            ;;
    esac
    if [ "$?" -ne 0 ] || ! chmod --reference="$target_file" "$tmp_file" 2>/dev/null || \
       ! mv -f -- "$tmp_file" "$target_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
}

public_port_conflicts() {
    local inbounds_file="${1:-}"
    local protocol="${2:-}"
    local port="${3:-}"
    local transport="${4:-}"
    local subscription_port jq_status

    validate_port_value "$port" conflict_port || return 2
    case "$protocol" in reality|hysteria2|tuic) ;; *) return 2 ;; esac
    case "$transport" in tcp|udp) ;; *) return 2 ;; esac
    [ -f "$inbounds_file" ] && [ ! -L "$inbounds_file" ] || return 2

    subscription_port=$(get_nginx_subscription_port \
        "${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}" 2>/dev/null || true)
    if [ "$transport" = tcp ] && [ -n "$subscription_port" ] && [ "$subscription_port" = "$port" ]; then
        return 0
    fi
    port_is_listening "$port" "$transport" && return 0

    jq -e --arg protocol "$protocol" --arg transport "$transport" --argjson port "$port" '
        def transport_matches:
            if (.type == "hysteria2" or .type == "tuic") then
                $transport == "udp"
            elif (.type == "socks" or .type == "shadowsocks") then
                ($transport == "tcp" or $transport == "udp")
            elif (.type == "vless" or .type == "vmess" or
                  .type == "trojan" or .type == "anytls") then
                $transport == "tcp"
            else
                true
            end;
        [.inbounds[] |
            select(
                if $protocol == "reality" then
                    (.type != "vless" or (((.tag? // "") | startswith("vless-reality")) | not))
                else
                    .type != $protocol
                end
            ) |
            select(transport_matches) |
            .listen_port
        ] | any(. == $port)
    ' "$inbounds_file" >/dev/null 2>&1
    jq_status=$?
    case "$jq_status" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

acquire_public_port_change_lock() {
    acquire_proxy_transaction_lock_checked "${conf_dir}" "公共入站端口修改"
}

release_public_port_change_lock() {
    release_proxy_transaction_lock
}

cleanup_public_port_backup() {
    local backup_file="${1:-}"

    [ -n "$backup_file" ] && [ -f "$backup_file" ] && [ ! -L "$backup_file" ] || return 1
    rm -f -- "$backup_file"
}

apply_public_port_service_state() {
    local was_active="${1:-}"

    validate_installed_singbox_config_strict || return 1
    case "$was_active" in
        1)
            restart_singbox >/dev/null 2>&1 || return 1
            singbox_service_is_active
            ;;
        0) ! singbox_service_is_active ;;
        *) return 1 ;;
    esac
}

restore_public_port_service_state() {
    local was_active="${1:-}"

    validate_installed_singbox_config_strict || return 1
    case "$was_active" in
        1)
            restart_singbox >/dev/null 2>&1 || return 1
            singbox_service_is_active
            ;;
        0)
            if singbox_service_is_active; then
                stop_singbox_checked >/dev/null 2>&1 || return 1
            fi
            ! singbox_service_is_active
            ;;
        *) return 1 ;;
    esac
}

rollback_public_port_signal_transaction() {
    local backup_file="${1:-}"
    local inbounds_file="${2:-}"
    local protocol="${3:-}"
    local old_port="${4:-}"
    local hy2_min="${5:-}"
    local hy2_max="${6:-}"
    local was_active="${7:-0}"
    local status=0

    if [ "${PUBLIC_TX_CONFIG_MUTATED:-0}" = 1 ]; then
        cp -p -- "$backup_file" "$client_dir" || status=1
        update_public_inbound_port "$inbounds_file" "$protocol" "$old_port" || status=1
        if [ "${PUBLIC_TX_HY2_NAT_MIGRATED:-0}" = 1 ]; then
            add_hy2_port_hopping "$hy2_min" "$hy2_max" "$old_port" || status=1
        fi
        restore_public_port_service_state "$was_active" || status=1
        update_sub || status=1
    fi
    if [ "${#DURABLE_TX_OWNED_RECORDS[@]}" -gt 0 ]; then
        remove_owned_firewall_records_exact "${DURABLE_TX_OWNED_RECORDS[@]}" || status=1
    fi
    cleanup_public_port_backup "$backup_file" || status=1
    return "$status"
}

_change_public_inbound_port_transaction_locked() {
    local inbounds_file="${1:-}"
    local protocol="${2:-}"
    local new_port="${3:-}"
    local transport="${4:-}"
    local old_port backup_file rollback_status=0 conflict_status firewall_status current_port
    local hy2_status=1 hy2_hopping_active=0 hy2_nat_migrated=0 transaction_ok=1
    local failure_status=1 operation_status=0
    local hy2_min='' hy2_max=''
    local was_active=0
    local -a new_firewall_records=()

    PUBLIC_PORT_RECOVERY_PATH=''
    validate_port_value "$new_port" "${protocol}_port" || return 1
    case "$transport" in tcp|udp) ;; *) return 1 ;; esac
    old_port=$(get_uniform_inbound_port "$inbounds_file" "$protocol") || return 1
    [ "$old_port" != "$new_port" ] || return 0
    if [ "$protocol" = hysteria2 ]; then
        if read_active_hy2_port_hopping "$old_port"; then
            hy2_status=0
        else
            hy2_status=$?
        fi
        case "$hy2_status" in
            0)
                hy2_hopping_active=1
                hy2_min="$HY2_ACTIVE_HOP_MIN"
                hy2_max="$HY2_ACTIVE_HOP_MAX"
                ;;
            1) ;;
            *) red "Hysteria2 端口跳跃状态损坏或与当前入站不一致。"; return 1 ;;
        esac
    fi
    public_port_conflicts "$inbounds_file" "$protocol" "$new_port" "$transport"
    conflict_status=$?
    if [ "$conflict_status" = 0 ]; then
        red "新端口 ${new_port} 已被其他入站、订阅或系统服务使用。"
        return 1
    fi
    [ "$conflict_status" = 1 ] || return 1
    backup_file=$(mktemp "$(dirname "$client_dir")/.port-client-backup.XXXXXX") || return 1
    if ! cp -p -- "$client_dir" "$backup_file"; then
        rm -f -- "$backup_file"
        return 1
    fi
    if ! chmod 600 "$backup_file"; then
        rm -f -- "$backup_file"
        return 1
    fi
    singbox_service_is_active && was_active=1
    PUBLIC_TX_CONFIG_MUTATED=0
    PUBLIC_TX_HY2_NAT_MIGRATED=0
    if ! arm_durable_transaction public-port "$(dirname "$backup_file")" "$backup_file" \
        PUBLIC_PORT_RECOVERY_PATH rollback_public_port_signal_transaction \
        "$was_active" "$old_port" "$new_port" \
        "$backup_file" "$inbounds_file" "$protocol" "$old_port" \
        "$hy2_min" "$hy2_max" "$was_active"; then
        cleanup_public_port_backup "$backup_file" || {
            PUBLIC_PORT_RECOVERY_PATH="$backup_file"
            return 2
        }
        return 1
    fi

    if ! durable_transaction_checkpoint firewall-mutating; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    allow_port "${new_port}/${transport}"
    firewall_status=$?
    if [ "$firewall_status" -ne 0 ]; then
        if [ "$firewall_status" -eq 2 ]; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            red "防火墙事务状态未决，已保留公共端口恢复证据。"
            return 2
        fi
        if ! cleanup_public_port_backup "$backup_file"; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            red "端口防火墙预检失败且客户端备份未能清理：${backup_file}"
            return 2
        fi
        if ! disarm_durable_transaction cleanup; then
            return 2
        fi
        return "$firewall_status"
    fi
    new_firewall_records=("${FIREWALL_LAST_ADDED_RECORDS[@]}")
    if ! durable_transaction_set_owned_records "${new_firewall_records[@]}" || \
       ! durable_transaction_checkpoint precommit; then
        rollback_public_port_signal_transaction "$backup_file" "$inbounds_file" "$protocol" \
            "$old_port" "$hy2_min" "$hy2_max" "$was_active" || {
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        }
        disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
        return 1
    fi
    # Mark before entering a helper that can mutate successfully and then fail
    # validation.  Signal rollback is intentionally idempotent.
    PUBLIC_TX_CONFIG_MUTATED=1
    update_public_inbound_port "$inbounds_file" "$protocol" "$new_port" || {
        failure_status=$?
        transaction_ok=0
    }
    if [ "$transaction_ok" = 1 ]; then
        durable_transaction_checkpoint config-mutated || {
            failure_status=2
            transaction_ok=0
        }
    fi
    if [ "$transaction_ok" = 1 ] && [ "$hy2_hopping_active" = 1 ]; then
        # add_hy2_port_hopping may change live NAT before a later persistence
        # step fails, so rollback ownership begins before the call.
        PUBLIC_TX_HY2_NAT_MIGRATED=1
        if add_hy2_port_hopping "$hy2_min" "$hy2_max" "$new_port"; then
            hy2_nat_migrated=1
        else
            failure_status=$?
            transaction_ok=0
        fi
    fi
    if [ "$transaction_ok" = 1 ]; then
        apply_public_port_service_state "$was_active" || {
            failure_status=$?
            transaction_ok=0
        }
    fi
    if [ "$transaction_ok" = 1 ]; then
        rewrite_public_client_port "$protocol" "$new_port" || {
            failure_status=$?
            transaction_ok=0
        }
    fi
    if [ "$transaction_ok" = 1 ]; then
        durable_transaction_checkpoint publishing || {
            failure_status=2
            transaction_ok=0
        }
    fi
    if [ "$transaction_ok" = 1 ]; then
        update_sub
        operation_status=$?
        if [ "$operation_status" -ne 0 ]; then
            failure_status="$operation_status"
            transaction_ok=0
        fi
    fi
    if [ "$transaction_ok" = 1 ]; then
        current_port=$(get_uniform_inbound_port "$inbounds_file" "$protocol") || current_port=''
        if [ "$current_port" != "$new_port" ]; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            red "端口事务完成前配置发生并发变化，已保留证据且未删除旧规则。"
            return 2
        fi
        public_port_conflicts "$inbounds_file" "$protocol" "$old_port" "$transport"
        conflict_status=$?
        if [ "$conflict_status" = 0 ]; then
            durable_transaction_checkpoint committed || {
                PUBLIC_PORT_RECOVERY_PATH="$backup_file"
                disarm_durable_transaction keep >/dev/null 2>&1 || true
                return 2
            }
            if ! cleanup_public_port_backup "$backup_file"; then
                disarm_durable_transaction keep >/dev/null 2>&1 || true
                red "新端口已提交，但客户端备份未能清理：${backup_file}"
                return 3
            fi
            if ! disarm_durable_transaction cleanup; then
                return 3
            fi
            yellow "旧端口 ${old_port} 仍被其他服务使用，已保留其防火墙规则。"
            return 0
        fi
        if [ "$conflict_status" = 1 ] && remove_owned_firewall_port "${old_port}/${transport}"; then
            durable_transaction_checkpoint committed || {
                PUBLIC_PORT_RECOVERY_PATH="$backup_file"
                disarm_durable_transaction keep >/dev/null 2>&1 || true
                return 2
            }
            if ! cleanup_public_port_backup "$backup_file"; then
                disarm_durable_transaction keep >/dev/null 2>&1 || true
                red "新端口已提交，但客户端备份未能清理：${backup_file}"
                return 3
            fi
            if ! disarm_durable_transaction cleanup; then
                return 3
            fi
            return 0
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        red "新端口已生效，但旧端口的脚本所有规则未能安全删除；已保留客户端备份：${backup_file}"
        return 2
    fi

    rollback_public_port_signal_transaction "$backup_file" "$inbounds_file" "$protocol" \
        "$old_port" "$hy2_min" "$hy2_max" "$was_active" || rollback_status=1
    if [ "$rollback_status" = 0 ]; then
        if ! disarm_durable_transaction cleanup; then
            red "端口修改已回滚，但事务证据未能清理。"
            return 2
        fi
        [ "$failure_status" -ge 1 ] 2>/dev/null || failure_status=1
        [ "$failure_status" -ne 2 ] || failure_status=1
        return "$failure_status"
    fi
    disarm_durable_transaction keep >/dev/null 2>&1 || true
    red "端口修改失败且回滚不完整，已保留客户端备份：${backup_file}"
    return 2
}

change_public_inbound_port_transaction() {
    local status

    acquire_public_port_change_lock
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _change_public_inbound_port_transaction_locked "$@"
    status=$?
    release_public_port_change_lock
    return "$status"
}

purge_nginx_package() {
    local package="nginx"
    manage_packages uninstall "$package"
}

remove_managed_singbox_link() {
    local install_root="${1:-}"
    local managed_link link_target

    for managed_link in \
        "${install_root}/usr/local/bin/sing-box" \
        "${install_root}/usr/local/bin/sb" \
        "${install_root}/usr/bin/sb"; do
        [ -L "$managed_link" ] || continue
        link_target=$(readlink "$managed_link" 2>/dev/null) || continue
        case "$link_target" in
            /etc/sing-box/sb.sh|/etc/sing-box/sing-box)
                rm -f "$managed_link"
                ;;
        esac
    done
}

# 卸载 sing-box（交互式）
uninstall_singbox() {
    local uninstall_root="${1:-}"

    reading "确定要卸载 sing-box 吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载 sing-box"
            if ! remove_hy2_port_hopping; then
                red "Hysteria2 端口跳跃状态无法安全清理，卸载已中止。"
                return 1
            fi
            if ! remove_owned_firewall_rules; then
                red "防火墙所有权状态无法安全清理，卸载已中止。"
                return 1
            fi
            if command_exists rc-service; then
                rc-service sing-box stop; rc-service argo stop
                rm -f "${uninstall_root}/etc/init.d/sing-box" \
                      "${uninstall_root}/etc/init.d/argo"
                rc-update del sing-box default; rc-update del argo default
            else
                systemctl stop "${server_name}"; systemctl stop argo
                systemctl disable "${server_name}"; systemctl disable argo
                systemctl daemon-reload || true
            fi
            rm -rf "${work_dir}" || true
            remove_managed_singbox_link "$uninstall_root"
            rm -f "${uninstall_root}/etc/systemd/system/sing-box.service" \
                  "${uninstall_root}/etc/systemd/system/argo.service"
            rm -f "${uninstall_root}/etc/nginx/conf.d/sing-box.conf"

            reading "\n是否卸载 Nginx？${green}(卸载请输入 ${yellow}y${re} ${green}回车将跳过卸载Nginx) (y/n): ${re}" choice
            case "${choice}" in
                y|Y) purge_nginx_package ;;
                *)   yellow "取消卸载Nginx\n\n" ;;
            esac
            green "\nsing-box 卸载成功\n\n" && exit 0
            ;;
        *) purple "已取消卸载操作\n\n" ;;
    esac
}

# Write a local-only wrapper. An isolated install root uses rooted paths so the
# installed command can be exercised without chroot; production keeps canonical
# absolute paths.
write_local_manager_wrapper() {
    local wrapper_file="$1"
    local manager_target="$2"

    {
        printf '%s\n' '#!/bin/bash' 'set -e'
        printf 'exec %q "$@"\n' "$manager_target"
    } | atomic_write_secret_file "$wrapper_file" || return 1
    chmod 700 "$wrapper_file"
}

is_legacy_raw_manager_wrapper() {
    local wrapper_file="$1"

    [ -f "$wrapper_file" ] && [ ! -L "$wrapper_file" ] || return 1
    grep -Eq 'curl[^[:cntrl:]]+raw\.githubusercontent\.com/[^[:space:]]+/sing-box\.sh' \
        "$wrapper_file"
}

migrate_legacy_manager_shortcuts() {
    local install_root="${1:-}"
    local wrapper_file="${install_root}/etc/sing-box/sb.sh"
    local manager_target='/usr/local/lib/sing-box-pre/sing-box.sh'
    local wrapper_target='/etc/sing-box/sb.sh'
    local singbox_target='/etc/sing-box/sing-box'
    local wrapper_tmp wrapper_backup link_path link_target desired_target link_tmp
    local wrapper_committed=0 committed_links=0 rollback_ok=1 index
    local -a link_paths=() old_targets=() staged_links=()

    is_legacy_raw_manager_wrapper "$wrapper_file" || return 0
    if [ -n "$install_root" ]; then
        manager_target="${install_root}/usr/local/lib/sing-box-pre/sing-box.sh"
        wrapper_target="$wrapper_file"
        singbox_target="${install_root}/etc/sing-box/sing-box"
    fi

    wrapper_tmp=$(mktemp "$(dirname "$wrapper_file")/.sb.sh.migrate.XXXXXX") || return 1
    wrapper_backup=$(mktemp "$(dirname "$wrapper_file")/.sb.sh.rollback.XXXXXX") || {
        rm -f "$wrapper_tmp"
        return 1
    }
    if ! write_local_manager_wrapper "$wrapper_tmp" "$manager_target" || \
       ! cp -p "$wrapper_file" "$wrapper_backup" || ! chmod 700 "$wrapper_backup"; then
        rm -f "$wrapper_tmp" "$wrapper_backup"
        return 1
    fi

    for link_path in \
        "${install_root}/usr/local/bin/sb" \
        "${install_root}/usr/bin/sb" \
        "${install_root}/usr/local/bin/sing-box"; do
        [ -L "$link_path" ] || continue
        link_target=$(readlink "$link_path" 2>/dev/null) || continue
        case "$link_target" in
            /etc/sing-box/sb.sh|"$wrapper_file") ;;
            *) continue ;;
        esac
        desired_target="$wrapper_target"
        [ "$link_path" = "${install_root}/usr/local/bin/sing-box" ] && \
            desired_target="$singbox_target"
        link_tmp=$(mktemp "$(dirname "$link_path")/.shortcut.migrate.XXXXXX") || {
            rm -f "$wrapper_tmp" "$wrapper_backup" "${staged_links[@]}"
            return 1
        }
        rm -f "$link_tmp"
        if ! ln -s "$desired_target" "$link_tmp"; then
            rm -f "$wrapper_tmp" "$wrapper_backup" "$link_tmp" "${staged_links[@]}"
            return 1
        fi
        link_paths+=("$link_path")
        old_targets+=("$link_target")
        staged_links+=("$link_tmp")
    done

    if ! mv -f "$wrapper_tmp" "$wrapper_file"; then
        rm -f "$wrapper_tmp" "$wrapper_backup" "${staged_links[@]}"
        return 1
    fi
    wrapper_committed=1
    for index in "${!link_paths[@]}"; do
        if ! mv -f "${staged_links[$index]}" "${link_paths[$index]}"; then
            break
        fi
        committed_links=$((committed_links + 1))
    done
    if [ "$committed_links" -ne "${#link_paths[@]}" ]; then
        for ((index = committed_links - 1; index >= 0; index--)); do
            link_tmp=$(mktemp "$(dirname "${link_paths[$index]}")/.shortcut.rollback.XXXXXX") || {
                rollback_ok=0
                continue
            }
            rm -f "$link_tmp"
            if ! ln -s "${old_targets[$index]}" "$link_tmp" || \
               ! mv -f "$link_tmp" "${link_paths[$index]}"; then
                rollback_ok=0
                rm -f "$link_tmp"
            fi
        done
        if [ "$wrapper_committed" -eq 1 ] && \
           ! mv -f "$wrapper_backup" "$wrapper_file"; then
            rollback_ok=0
        fi
        rm -f "$wrapper_tmp" "$wrapper_backup" "${staged_links[@]}"
        [ "$rollback_ok" -eq 1 ] || red "旧版 sb 快捷方式回滚失败。"
        return 1
    fi
    rm -f "$wrapper_backup"
}

# 创建快捷指令
create_shortcut() {
    local shortcut_root="${1:-${SHORTCUT_ROOT:-}}"
    local local_bin_dir="${shortcut_root}/usr/local/bin"
    local usr_bin_dir="${shortcut_root}/usr/bin"
    local wrapper_dir="${shortcut_root}/etc/sing-box"
    local wrapper_file="${wrapper_dir}/sb.sh"
    local manager_dir="${shortcut_root}/usr/local/lib/sing-box-pre"
    local manager_file="${manager_dir}/sing-box.sh"
    local manager_source="${MANAGER_SOURCE_SCRIPT:-${BASH_SOURCE[0]}}"
    local wrapper_target='/etc/sing-box/sb.sh'
    local manager_target='/usr/local/lib/sing-box-pre/sing-box.sh'
    local singbox_target='/etc/sing-box/sing-box'
    local local_sb="${local_bin_dir}/sb"
    local usr_sb="${usr_bin_dir}/sb"
    local singbox_link="${local_bin_dir}/sing-box"

    [ -r "$manager_source" ] || return 1
    bash -n "$manager_source" || return 1
    mkdir -p "$wrapper_dir" "$manager_dir" "$local_bin_dir" "$usr_bin_dir" || return 1
    install -m 700 "$manager_source" "$manager_file" || return 1
    if [ -n "$shortcut_root" ]; then
        manager_target="$manager_file"
        wrapper_target="$wrapper_file"
        singbox_target="${shortcut_root}/etc/sing-box/sing-box"
    fi
    write_local_manager_wrapper "$wrapper_file" "$manager_target" || return 1
    ln -sfn "$wrapper_target" "$local_sb" || return 1
    ln -sfn "$wrapper_target" "$usr_sb" || return 1
    ln -sfn "$singbox_target" "$singbox_link" || return 1
    if [ -x "$manager_file" ] && [ -x "$wrapper_file" ] && \
       [ "$(readlink "$local_sb" 2>/dev/null)" = "$wrapper_target" ] && \
       [ "$(readlink "$usr_sb" 2>/dev/null)" = "$wrapper_target" ] && \
       [ "$(readlink "$singbox_link" 2>/dev/null)" = "$singbox_target" ]; then
        green "\n快捷指令 sb 创建成功\n"
        return 0
    else
        red "\n快捷指令创建失败\n"
        return 1
    fi
}

update_local_manager() {
    local install_root="${1:-}"
    local update_url="${2:-https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh}"
    local manager_dir="${install_root}/usr/local/lib/sing-box-pre"
    local manager_file="${manager_dir}/sing-box.sh"
    local previous_file="${manager_file}.previous"
    local tmp_file previous_tmp='' previous_rollback=''
    local previous_existed=0 previous_replaced=0 rollback_ok=1

    mkdir -p "$manager_dir" || return 1
    tmp_file=$(mktemp "${manager_dir}/.sing-box.sh.new.XXXXXX") || return 1
    if ! curl -fsSL --connect-timeout 10 --max-time 60 "$update_url" -o "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    if ! bash -n "$tmp_file" || ! chmod 700 "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    if [ -e "$manager_file" ]; then
        previous_tmp=$(mktemp "${manager_dir}/.sing-box.sh.previous.XXXXXX") || {
            rm -f "$tmp_file"
            return 1
        }
        if ! cp -p "$manager_file" "$previous_tmp" || ! chmod 700 "$previous_tmp"; then
            rm -f "$tmp_file" "$previous_tmp"
            return 1
        fi
        if [ -e "$previous_file" ]; then
            previous_existed=1
            previous_rollback=$(mktemp "${manager_dir}/.sing-box.sh.previous-rollback.XXXXXX") || {
                rm -f "$tmp_file" "$previous_tmp"
                return 1
            }
            if ! cp -p "$previous_file" "$previous_rollback"; then
                rm -f "$tmp_file" "$previous_tmp" "$previous_rollback"
                return 1
            fi
        fi
        if ! mv -f "$previous_tmp" "$previous_file"; then
            rm -f "$tmp_file" "$previous_tmp" "$previous_rollback"
            return 1
        fi
        previous_replaced=1
    fi
    if ! mv -f "$tmp_file" "$manager_file"; then
        if [ "$previous_replaced" -eq 1 ]; then
            if [ "$previous_existed" -eq 1 ]; then
                mv -f "$previous_rollback" "$previous_file" || rollback_ok=0
            else
                rm -f "$previous_file" || rollback_ok=0
            fi
        fi
        rm -f "$tmp_file" "$previous_tmp" "$previous_rollback"
        [ "$rollback_ok" -eq 1 ] || red "旧版 sb 管理脚本备份回滚失败。"
        return 1
    fi
    rm -f "$previous_tmp" "$previous_rollback"
}

update_shortcut() {
    local install_root="${1:-}"
    local update_url="${2:-https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh}"
    local manager_dir="${install_root}/usr/local/lib/sing-box-pre"
    local manager_file="${manager_dir}/sing-box.sh"
    local previous_file="${manager_file}.previous"
    local manager_backup='' previous_backup=''
    local manager_existed=0 previous_existed=0 rollback_ok=1

    mkdir -p "$manager_dir" || return 1
    if [ -e "$manager_file" ]; then
        manager_existed=1
        manager_backup=$(mktemp "${manager_dir}/.sing-box.sh.update-rollback.XXXXXX") || return 1
        cp -p "$manager_file" "$manager_backup" || { rm -f "$manager_backup"; return 1; }
    fi
    if [ -e "$previous_file" ]; then
        previous_existed=1
        previous_backup=$(mktemp "${manager_dir}/.sing-box.sh.previous-rollback.XXXXXX") || {
            rm -f "$manager_backup"
            return 1
        }
        cp -p "$previous_file" "$previous_backup" || {
            rm -f "$manager_backup" "$previous_backup"
            return 1
        }
    fi

    if ! update_local_manager "$install_root" "$update_url"; then
        rm -f "$manager_backup" "$previous_backup"
        red "sb 本地管理脚本更新失败，已保留当前版本。"
        return 1
    fi
    if ! migrate_legacy_manager_shortcuts "$install_root"; then
        if [ "$manager_existed" -eq 1 ]; then
            mv -f "$manager_backup" "$manager_file" || rollback_ok=0
        else
            rm -f "$manager_file" || rollback_ok=0
        fi
        if [ "$previous_existed" -eq 1 ]; then
            mv -f "$previous_backup" "$previous_file" || rollback_ok=0
        else
            rm -f "$previous_file" || rollback_ok=0
        fi
        rm -f "$manager_backup" "$previous_backup"
        [ "$rollback_ok" -eq 1 ] || red "sb 本地管理脚本回滚失败。"
        red "旧版 sb 快捷方式迁移失败。"
        return 1
    fi
    rm -f "$manager_backup" "$previous_backup"
    green "已更新 sb 本地管理脚本；不会修改已有节点、订阅、端口或服务配置。\n"
}

# 适配alpine
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

rollback_failed_install_firewall_records() {
    local -a records=("$@")

    [ "${#records[@]}" -gt 0 ] || return 0
    if remove_owned_firewall_records_exact "${records[@]}"; then
        return 0
    fi
    red "安装失败后的防火墙回滚未能确认完成；firewall.state 已保留恢复证据。"
    return 2
}

handle_failed_install_stage() {
    local failure_status="${1:-1}"
    local message="${2:-安装失败，安装中止。}"
    shift 2 || return 2

    red "$message"
    rollback_failed_install_firewall_records "$@" || return 2
    return "$failure_status"
}

# Fail-fast install orchestration shared by interactive and non-interactive paths.
run_install_flow() {
    local stage_status
    local -a install_firewall_records=()

    FIREWALL_LAST_ADDED_RECORDS=()
    clear_install_complete_marker || {
        red "无法清除旧的安装完成标记，安装中止。"
        return 1
    }
    manage_packages install nginx jq tar openssl lsof coreutils util-linux || {
        red "依赖安装失败，安装中止。"
        return 1
    }
    if install_singbox; then stage_status=0; else stage_status=$?; fi
    install_firewall_records=("${FIREWALL_LAST_ADDED_RECORDS[@]}")
    if [ "$stage_status" -ne 0 ]; then
        handle_failed_install_stage "$stage_status" \
            "sing-box 配置安装失败，安装中止。" "${install_firewall_records[@]}"
        return $?
    fi
    validate_singbox_config || {
        handle_failed_install_stage 1 "sing-box 配置检查失败，安装中止。" \
            "${install_firewall_records[@]}"
        return $?
    }

    if command_exists systemctl; then
        main_systemd_services || {
            red "systemd 服务安装或启动失败，安装中止。"
            yellow "服务可能已部分启动；保留已登记的防火墙规则，避免现有连接被误断。"
            return 1
        }
        systemctl is-active --quiet sing-box && systemctl is-active --quiet argo || {
            red "sing-box 或 Argo 服务未处于 active 状态，安装中止。"
            yellow "服务已进入启动阶段；保留已登记的防火墙规则供重试或卸载清理。"
            return 1
        }
    elif command_exists rc-update; then
        alpine_openrc_services || {
            red "OpenRC 服务安装失败，安装中止。"
            yellow "服务可能已部分注册；保留已登记的防火墙规则供重试或卸载清理。"
            return 1
        }
        change_hosts || {
            red "OpenRC 主机初始化失败，安装中止。"
            yellow "服务已进入配置阶段；保留已登记的防火墙规则供重试或卸载清理。"
            return 1
        }
        rc-service sing-box restart || {
            red "sing-box OpenRC 服务启动失败，安装中止。"
            yellow "服务已进入启动阶段；保留已登记的防火墙规则供重试或卸载清理。"
            return 1
        }
        rc-service argo restart || {
            red "Argo OpenRC 服务启动失败，安装中止。"
            yellow "服务已进入启动阶段；保留已登记的防火墙规则供重试或卸载清理。"
            return 1
        }
        rc-service sing-box status >/dev/null 2>&1 && rc-service argo status >/dev/null 2>&1 || {
            red "sing-box 或 Argo 服务未启动，安装中止。"
            yellow "服务已进入启动阶段；保留已登记的防火墙规则供重试或卸载清理。"
            return 1
        }
    else
        handle_failed_install_stage 1 "不支持的 init 系统，安装中止。" \
            "${install_firewall_records[@]}"
        return $?
    fi

    sleep 5
    add_nginx_conf || {
        red "Nginx 订阅配置失败，安装中止。"
        yellow "核心服务已经启动；保留已登记的防火墙规则，避免现有连接被误断。"
        return 1
    }
    get_info || {
        red "节点信息生成失败，安装中止。"
        yellow "核心服务已经启动；保留已登记的防火墙规则，避免现有连接被误断。"
        return 1
    }
    create_shortcut || {
        red "快捷指令创建失败，安装中止。"
        yellow "核心服务已经启动；保留已登记的防火墙规则，避免现有连接被误断。"
        return 1
    }
    mark_install_complete || {
        red "安装完成标记写入失败，安装中止。"
        yellow "核心服务已经启动；保留已登记的防火墙规则，避免现有连接被误断。"
        return 1
    }
    green "\nsing-box 安装完成\n"
}

# 非交互静默安装（-i 参数）
auto_install() {
    local existing_install_status

    if prepare_existing_install; then
        yellow "sing-box 已经安装，跳过安装流程。"
        return 0
    else
        existing_install_status=$?
    fi
    if [ "$existing_install_status" -eq 2 ]; then
        red "旧安装验证通过，但安装完成标记写入失败，安装中止。"
        return 1
    fi

    green "Starting non-interactive sing-box install..."
    run_install_flow
}

interactive_install() {
    local existing_install_status

    if prepare_existing_install; then
        yellow "sing-box 已经安装！\n"
        return 0
    else
        existing_install_status=$?
    fi
    if [ "$existing_install_status" -eq 2 ]; then
        red "旧安装验证通过，但安装完成标记写入失败，安装中止。"
        return 1
    fi

    run_install_flow
}

# Non-interactive uninstall (-u); keeps nginx unless PURGE_NGINX=1 or --purge-nginx is used.
auto_uninstall() {
    local uninstall_root="${1:-}"

    green "Starting non-interactive sing-box uninstall..."

    if ! remove_hy2_port_hopping; then
        red "Unable to safely clean Hysteria2 port-hopping rules; uninstall aborted."
        return 1
    fi
    if ! remove_owned_firewall_rules; then
        red "Unable to safely clean owned firewall rules; uninstall aborted."
        return 1
    fi

    if command_exists rc-service; then
        rc-service sing-box stop  > /dev/null 2>&1
        rc-service argo stop      > /dev/null 2>&1
        rc-update del sing-box default > /dev/null 2>&1
        rc-update del argo default     > /dev/null 2>&1
        rm -f "${uninstall_root}/etc/init.d/sing-box" "${uninstall_root}/etc/init.d/argo"
    elif command_exists systemctl; then
        systemctl stop    sing-box > /dev/null 2>&1
        systemctl stop    argo     > /dev/null 2>&1
        systemctl disable sing-box > /dev/null 2>&1
        systemctl disable argo     > /dev/null 2>&1
        systemctl daemon-reload    > /dev/null 2>&1
        rm -f "${uninstall_root}/etc/systemd/system/sing-box.service" \
              "${uninstall_root}/etc/systemd/system/argo.service"
    fi

    rm -rf "${work_dir}"
    remove_managed_singbox_link "$uninstall_root"

    rm -f "${uninstall_root}/etc/nginx/conf.d/sing-box.conf"
    [ -f "${uninstall_root}/etc/nginx/nginx.conf.bak.sb" ] && \
        mv "${uninstall_root}/etc/nginx/nginx.conf.bak.sb" \
           "${uninstall_root}/etc/nginx/nginx.conf" > /dev/null 2>&1

    if [ "${PURGE_NGINX}" = "1" ]; then
        if command_exists nginx; then
            if command_exists rc-service; then
                rc-service nginx stop   > /dev/null 2>&1
                rc-update del nginx default > /dev/null 2>&1
            elif command_exists systemctl; then
                systemctl stop    nginx > /dev/null 2>&1
                systemctl disable nginx > /dev/null 2>&1
            fi
            purge_nginx_package
        else
            yellow "nginx is not installed; skipping nginx purge."
        fi
        green "\nsing-box and nginx have been purged.\n"
    else
        command_exists nginx && restart_nginx > /dev/null 2>&1 || true
        green "\nsing-box uninstalled; nginx retained. Use --purge-nginx to remove nginx too.\n"
    fi
}
change_config() {
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?
    local port_change_status

    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
    fi

    clear; echo ""
    green "=== 修改节点配置 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 修改端口"
    skyblue "------------"
    green "2. 修改UUID"
    skyblue "------------"
    green "3. 修改Reality伪装域名"
    skyblue "------------"
    green "4. 添加hysteria2端口跳跃"
    skyblue "------------"
    green "5. 删除hysteria2端口跳跃"
    skyblue "------------"
    green "6. 修改vless-ws-tls-argo优选域名"
    skyblue "------------"
    green "7. 修改节点ip为ipv4"
    skyblue "------------"
    green "8. 修改节点ip为ipv6"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            echo ""
            green "1. 修改vless-reality端口"
            skyblue "------------"
            green "2. 修改hysteria2端口"
            skyblue "------------"
            green "3. 修改tuic端口"
            skyblue "------------"
            green "4. 修改vless-ws-tls-argo端口"
            skyblue "------------"
            purple "0. 返回上一级菜单"
            skyblue "------------"
            reading "请输入选择: " choice
            local inbounds_file="${conf_dir}/inbounds.json"
            case "${choice}" in
                1)
                    reading "\n请输入vless-reality端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    change_public_inbound_port_transaction "$inbounds_file" reality "$new_port" tcp
                    port_change_status=$?
                    [ "$port_change_status" -eq 0 ] || return "$port_change_status"
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nvless-reality端口已修改成：${purple}$new_port${re}\n"
                    ;;
                2)
                    reading "\n请输入hysteria2端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    change_public_inbound_port_transaction "$inbounds_file" hysteria2 "$new_port" udp
                    port_change_status=$?
                    [ "$port_change_status" -eq 0 ] || return "$port_change_status"
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nhysteria2端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                3)
                    reading "\n请输入tuic端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    change_public_inbound_port_transaction "$inbounds_file" tuic "$new_port" udp
                    port_change_status=$?
                    [ "$port_change_status" -eq 0 ] || return "$port_change_status"
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\ntuic端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                4)
                    reading "\n请输入vless-ws-tls-argo端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    apply_jq_config "$inbounds_file" --arg port "$new_port" \
                       '(.inbounds[] | select(.tag == "vless-ws-argo").listen_port) = ($port | tonumber)' || return
                    if command_exists rc-service; then
                        grep -Eq "127\.0\.0\.1:|localhost:" /etc/init.d/argo && \
                            sed -i -E 's#(127\.0\.0\.1|localhost):[0-9]+#127.0.0.1:'"$new_port"'#g' /etc/init.d/argo && \
                            get_quick_tunnel && change_argo_domain
                    else
                        grep -Eq "127\.0\.0\.1:|localhost:" /etc/systemd/system/argo.service && \
                            sed -i -E 's#(127\.0\.0\.1|localhost):[0-9]+#127.0.0.1:'"$new_port"'#g' /etc/systemd/system/argo.service && \
                            get_quick_tunnel && change_argo_domain
                    fi
                    [ -f "${work_dir}/tunnel.yml" ] && sed -i -E 's#service: http://(127\.0\.0\.1|localhost):[0-9]+#service: http://127.0.0.1:'"$new_port"'#g' "${work_dir}/tunnel.yml"
                    restart_singbox
                    green "\nvless-ws-tls-argo端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                0) change_config ;;
                *) red "无效的选项，请输入 1 到 4" ;;
            esac
            ;;
        2)
            reading "\n请输入新的UUID(直接回车随机生成UUID): " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            apply_jq_config "${conf_dir}/inbounds.json" --arg uuid "$new_uuid" \
               '(.inbounds[] | select(.users != null) | .users[] | select(.uuid != null).uuid) = $uuid |
                (.inbounds[] | select(.users != null) | .users[] | select(.password != null).password) = $uuid' || return
            restart_singbox
            sed -i -E 's/(vless:\/\/|hysteria2:\/\/|anytls:\/\/)[^@]*(@.*)/\1'"$new_uuid"'\2/' $client_dir
            sed -i -E "s#tuic://[0-9a-f-]{36}:[0-9a-f-]{36}@#tuic://$new_uuid:$new_uuid@#g" $client_dir
            update_uuid_file "${work_dir}/cfy-url.txt" "$new_uuid"
            update_sub
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nUUID已修改为：${purple}${new_uuid}${re}\n"
            ;;
        3)
            clear
            green "\n1. www.joom.com\n\n2. www.stengg.com\n\n3. www.wedgehr.com\n\n4. www.cerebrium.ai\n\n5. www.nazhumi.com\n"
            reading "\n请输入新的Reality伪装域名(可自定义输入,回车留空将使用默认1): " new_sni
            case "$new_sni" in
                ""|"1") new_sni="www.joom.com" ;;
                "2") new_sni="www.stengg.com" ;;
                "3") new_sni="www.wedgehr.com" ;;
                "4") new_sni="www.cerebrium.ai" ;;
                "5") new_sni="www.nazhumi.com" ;;
            esac
            apply_jq_config "${conf_dir}/inbounds.json" --arg sni "$new_sni" \
               '(.inbounds[] | select(.type == "vless") | .tls.server_name) = $sni |
                (.inbounds[] | select(.type == "vless") | .tls.reality.handshake.server) = $sni' || return
            restart_singbox
            sed -i "s/\(vless:\/\/[^\?]*\?\([^\&]*\&\)*sni=\)[^&]*/\1$new_sni/" $client_dir
            update_sub
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nReality sni已修改为：${purple}${new_sni}${re}\n"
            ;;
        4)
            purple "端口跳跃需确保跳跃区间的端口没有被占用\n"
            reading "请输入跳跃起始端口 (回车跳过将使用随机端口): " min_port
            [ -z "$min_port" ] && min_port=$(shuf -i 50000-65000 -n 1)
            yellow "你的起始端口为：$min_port"
            reading "\n请输入跳跃结束端口 (需大于起始端口): " max_port
            [ -z "$max_port" ] && max_port=$(($min_port + 100))
            yellow "你的结束端口为：$max_port\n"
            enable_hy2_port_hopping_transaction "$min_port" "$max_port"
            hy2_transaction_status=$?
            if [ "$hy2_transaction_status" -ne 0 ]; then
                [ "$hy2_transaction_status" -eq 2 ] && return 2
                red "Hysteria2 端口跳跃启用失败，原配置已保留或恢复。"
                return 1
            fi
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nhysteria2端口跳跃已开启：${purple}$min_port-$max_port${re}\n"
            ;;
        5)
            disable_hy2_port_hopping_transaction
            hy2_transaction_status=$?
            if [ "$hy2_transaction_status" -ne 0 ]; then
                [ "$hy2_transaction_status" -eq 2 ] && return 2
                red "Hysteria2 端口跳跃删除失败，原配置已保留或恢复。"
                return 1
            fi
            green "\n端口跳跃已删除\n"
            ;;
        6) change_cfip ;;
        7)
            local new_ipv4
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            new_ipv4=$(curl -4 -sm 2 ip.sb)
            if ! printf '%s' "$new_ipv4" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                red "\n错误: 获取 IPv4 失败: $new_ipv4\n"
                return 1
            fi
            if curl -4 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
                red "\n当前服务器的ipv4: $new_ipv4 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@\[[0-9a-fA-F:]+\]' "$client_dir"; then
                sed -i -E "/path=%2Fvless-argo/! s#@\[[0-9a-fA-F:]+\]#@${new_ipv4}#g" "$client_dir"
                green "\n已将 IPv6 修改为 IPv4: $new_ipv4 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv4, 无需切换\n" && return 0
            fi
            update_sub
           ;;
        8)
            local new_ipv6
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            new_ipv6=$(curl -6 -sm 3 ip.sb)
            if ! printf '%s' "$new_ipv6" | grep -Eq '^[0-9a-fA-F:]+$'; then
                red "\n当前服务器没有可用的ipv6\n"
                return 1
            fi
            if curl -6 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
                red "\n当前服务器的ipv6 $new_ipv6 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@([0-9]{1,3}\.){3}[0-9]{1,3}' "$client_dir"; then
                sed -i -E "/path=%2Fvless-argo/! s#@(([0-9]{1,3}\.){3}[0-9]{1,3})#@[${new_ipv6}]#g" "$client_dir"
                green "\n已将 IPv4 修改为 IPv6: [${new_ipv6}] 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv6, 无需切换\n" && return 0
            fi
            update_sub
           ;;
        0) menu ;;
        *) red "无效的选项！\n" ;;
    esac
}

_configure_cf_https_subscription_locked() {
    local force_rotate="${1:-0}"
    local tunnel_mode domain_mode domain choice token port http_path https_path path_regex https_url
    local old_domain old_https_path old_path_regex config_file pending_state snapshot_dir tunnel_file=''
    local old_http_path tunnel_id dns_choice confirm apply_method manual_confirm
    local config_status nginx_was_active=0 operation_status=0 rollback_status=0 dns_mutated=0
    local baseline_config_digest baseline_state_digest baseline_tunnel_digest=''
    local current_tunnel_mode

    FRONTEND_RECOVERY_PATH=''
    load_subscription_state
    tunnel_mode=$(detect_argo_tunnel_mode 2>/dev/null || true)
    if [ "$tunnel_mode" = quick ] || [ -z "$tunnel_mode" ]; then
        yellow "当前不是可识别的固定 Tunnel；请先在 Argo 隧道管理中添加固定 Tunnel。"
        return 1
    fi

    old_domain="${SUB_HTTPS_DOMAIN:-}"
    old_https_path="${SUB_HTTPS_PATH:-}"
    old_path_regex=""
    is_valid_subscription_path "$old_https_path" && old_path_regex="^${old_https_path}$"

    if [ "$force_rotate" = 1 ]; then
        domain_mode=''
        domain=''
    else
        green "\nHTTPS 订阅域名模式："
        green "1. 复用现有固定 Argo 域名（推荐，无需新增域名）"
        green "2. 使用独立订阅域名"
        reading "请选择 [1-2，默认1]: " choice
        case "$choice" in
            ""|1) domain_mode=reuse ;;
            2) domain_mode=separate ;;
            *) red "无效的域名模式"; return 1 ;;
        esac

        if [ "$domain_mode" = reuse ] && [ "$tunnel_mode" = local ]; then
            domain=$(sed -n 's/^[[:space:]]*- hostname:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
                "${work_dir}/tunnel.yml" | head -1)
            if ! is_valid_subscription_domain "$domain"; then
                reading "未能读取固定 Argo 域名，请输入现有 Argo 域名: " domain
            else
                green "将复用固定 Argo 域名：${purple}${domain}${re}"
            fi
        elif [ "$domain_mode" = reuse ]; then
            reading "请输入 Cloudflare 中现有的固定 Argo 域名: " domain
        else
            reading "请输入你自己的独立订阅域名（例如 sub.example.com）: " domain
        fi
        domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
        is_valid_subscription_domain "$domain" || { red "订阅域名格式无效"; return 1; }
    fi

    config_file="${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}"
    validate_managed_subscription_runtime "$config_file" any
    config_status=$?
    case "$config_status" in
        0) ;;
        1) red "未找到 Nginx HTTP 订阅配置，请先开启节点订阅。"; return 1 ;;
        *) red "现有 Nginx 配置不是脚本可确认拥有的完整订阅配置，已拒绝覆盖。"; return 1 ;;
    esac
    port=$(get_nginx_subscription_port "$config_file" 2>/dev/null || true)
    old_http_path=$(get_nginx_subscription_paths "$config_file" 2>/dev/null | head -1)
    [ -n "$port" ] && is_valid_http_subscription_path "$old_http_path" || {
        red "未找到有效的 Nginx HTTP 订阅配置，请先开启节点订阅。"
        return 1
    }
    if ! nginx_service_is_active; then
        yellow "HTTPS 公网验证要求订阅服务正在运行；当前未修改任何配置。"
        return 1
    fi
    nginx_was_active=1
    if [ "$force_rotate" = 1 ]; then
        [ "$SUB_HTTPS_ENABLED" = 1 ] || {
            red "HTTPS 订阅状态已变化，已拒绝继续轮换。"
            return 2
        }
        domain_mode="$SUB_HTTPS_DOMAIN_MODE"
        domain="$SUB_HTTPS_DOMAIN"
    fi
    old_domain="${SUB_HTTPS_DOMAIN:-}"
    old_https_path="${SUB_HTTPS_PATH:-}"
    old_path_regex=''
    is_valid_subscription_path "$old_https_path" && old_path_regex="^${old_https_path}$"
    [ "$tunnel_mode" = local ] && tunnel_file="${work_dir}/tunnel.yml"
    baseline_config_digest=$(subscription_frontend_snapshot_file_digest "$config_file") || return 2
    baseline_state_digest=$(subscription_frontend_snapshot_file_digest \
        "$subscription_state_file") || return 2
    if [ -n "$tunnel_file" ]; then
        baseline_tunnel_digest=$(subscription_frontend_snapshot_file_digest "$tunnel_file") || return 2
    fi

    token="${SUB_TOKEN:-}"
    if [ "$force_rotate" = 1 ] || ! is_valid_subscription_token "$token"; then
        yellow "启用或轮换 32 字符密钥后，旧订阅 URL 将失效，需要更新客户端。"
        reading "确认继续？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
        token=$(generate_subscription_token) || { red "订阅密钥生成失败"; return 1; }
    fi

    http_path="/${token}"
    [ "$domain_mode" = reuse ] && https_path="/sub/${token}" || https_path="/${token}"
    path_regex="^${https_path}$"
    https_url=$(build_https_subscription_url "$domain" "$https_path") || return 1

    if [ "$tunnel_mode" = local ] && [ "$domain_mode" = separate ]; then
        tunnel_id=$(sed -n 's/^[[:space:]]*tunnel:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
            "${work_dir}/tunnel.yml" | head -1)
        green "\n独立域名需要 CNAME：${purple}${domain}${re} -> ${purple}${tunnel_id}.cfargotunnel.com${re}（已代理）"
        reading "是否尝试由 cloudflared 自动创建 DNS？[y/N]: " dns_choice
        if [[ ! "$dns_choice" =~ ^[Yy]$ ]]; then
            reading "确认 DNS 已配置后输入 y 继续: " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || return 1
        fi
    fi

    snapshot_dir=$(backup_subscription_frontend_snapshot "$config_file" \
        "$subscription_state_file" "$tunnel_file" "$conf_dir") || return 1
    current_tunnel_mode=$(detect_argo_tunnel_mode 2>/dev/null || true)
    if [ "$current_tunnel_mode" != "$tunnel_mode" ] || \
       ! verify_subscription_frontend_snapshot_baseline "$snapshot_dir" "$config_file" \
            "$subscription_state_file" "$tunnel_file" "$baseline_config_digest" \
            "$baseline_state_digest" "$baseline_tunnel_digest" || \
       ! validate_managed_subscription_runtime "$config_file" any; then
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
            FRONTEND_RECOVERY_PATH="$snapshot_dir"
        red "订阅配置在确认期间发生变化，已拒绝覆盖。"
        return 2
    fi
    SUB_TOKEN="$token"
    SUB_HTTP_PATH="$http_path"
    SUB_HTTPS_ENABLED=1
    SUB_HTTPS_DOMAIN="$domain"
    SUB_HTTPS_DOMAIN_MODE="$domain_mode"
    SUB_HTTPS_PATH="$https_path"
    SUB_TUNNEL_MODE="$tunnel_mode"
    SUB_HTTPS_VERIFIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    pending_state=$(prepare_subscription_frontend_state_transaction \
        "$subscription_state_file" "$snapshot_dir") || {
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
            FRONTEND_RECOVERY_PATH="$snapshot_dir"
        red "无法预写订阅状态，配置未改变。"
        return 1
    }
    if ! arm_durable_transaction subscription-https "$conf_dir" "$snapshot_dir" \
        FRONTEND_RECOVERY_PATH rollback_subscription_frontend_signal_transaction \
        "$nginx_was_active" "$port" "$port" \
        "$snapshot_dir" "$config_file" "$subscription_state_file" \
        "$tunnel_file" "$pending_state"; then
        rm -f -- "$pending_state"
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
            FRONTEND_RECOVERY_PATH="$snapshot_dir"
        return 1
    fi
    apply_nginx_subscription_config "$port" "$http_path" "$https_path" \
        "$nginx_was_active" "$config_file" || operation_status=$?
    if [ "$operation_status" -eq 0 ]; then
        durable_transaction_checkpoint config-mutated || operation_status=2
    fi
    if [ "$operation_status" -eq 0 ]; then
        durable_transaction_checkpoint publishing || operation_status=2
    fi
    if [ "$operation_status" -ne 0 ]; then
        rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
            "$subscription_state_file" "$tunnel_file" "$pending_state"
        rollback_status=$?
        load_subscription_state
        if [ "$rollback_status" -eq 0 ]; then
            disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
            return 1
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi

    if [ "$tunnel_mode" = local ] && [ "$domain_mode" = separate ] && \
       [[ "$dns_choice" =~ ^[Yy]$ ]]; then
        dns_mutated=1
        if ! "${work_dir}/argo" tunnel route dns "$tunnel_id" "$domain"; then
            yellow "自动创建 DNS 失败或结果未知，请在 Cloudflare Dashboard 核对 CNAME。"
            reading "确认 DNS 已正确配置后输入 y 继续: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                disarm_durable_transaction keep >/dev/null 2>&1 || true
                return 2
            fi
        fi
    fi
    case "$tunnel_mode" in
        local)
            apply_local_tunnel_subscription_rule "$domain" "$path_regex" "$port" \
                "$domain_mode" "${work_dir}/tunnel.yml" "$https_url"
            operation_status=$?
            ;;
        remote)
            green "\n远程管理 Tunnel 配置方式："
            green "1. 使用 Cloudflare API token 自动配置"
            green "2. 在 Cloudflare Dashboard 手动配置"
            reading "请选择 [1-2，默认2]: " apply_method
            if [ "$apply_method" = 1 ]; then
                apply_remote_tunnel_subscription_rule "$domain" "$path_regex" "$port" \
                    "$domain_mode" "$old_domain" "$old_path_regex" "$https_url"
                operation_status=$?
            else
                print_manual_https_route "$domain" "$path_regex" "$port"
                if [ -n "$old_domain" ] && [ -n "$old_path_regex" ] && \
                   { [ "$old_domain" != "$domain" ] || [ "$old_path_regex" != "$path_regex" ]; }; then
                    yellow "轮换完成后，请删除旧路由：Hostname=${old_domain}, Path=${old_path_regex}"
                fi
                reading "完成 Dashboard 配置后输入 y 进行公网验证: " manual_confirm
                if [[ "$manual_confirm" =~ ^[Yy]$ ]]; then
                    verify_https_subscription "$https_url" || operation_status=2
                else
                    operation_status=1
                fi
            fi
            ;;
    esac

    if [ "$operation_status" -ne 0 ]; then
        if [ "$operation_status" -eq 1 ] && [ "$dns_mutated" -eq 0 ] && \
           { [ "$tunnel_mode" = local ] || \
             { [ "$tunnel_mode" = remote ] && [ "$apply_method" = 1 ]; }; }; then
            rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
                "$subscription_state_file" "$tunnel_file" "$pending_state"
            rollback_status=$?
            load_subscription_state
            if [ "$rollback_status" -eq 0 ]; then
                disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
                red "HTTPS 订阅配置或验证失败，原订阅前端已恢复。"
                return 1
            fi
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        red "HTTPS 发布结果未决，已保留恢复证据并阻止后续配置事务。"
        return 2
    fi
    if ! commit_subscription_frontend_state_transaction "$pending_state" \
        "$subscription_state_file"; then
        if [ "$tunnel_mode" = local ] && [ "$dns_mutated" -eq 0 ]; then
            rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
                "$subscription_state_file" "$tunnel_file" "$pending_state"
            rollback_status=$?
            load_subscription_state
            if [ "$rollback_status" -eq 0 ]; then
                disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
                return 1
            fi
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        red "HTTPS 已发布但本地状态提交失败，已保留恢复证据。"
        return 2
    fi
    if ! validate_managed_subscription_runtime "$config_file" https; then
        if [ "$tunnel_mode" = local ] && [ "$dns_mutated" -eq 0 ]; then
            rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
                "$subscription_state_file" "$tunnel_file" ""
            rollback_status=$?
            load_subscription_state
            if [ "$rollback_status" -eq 0 ]; then
                disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
                return 1
            fi
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! durable_transaction_checkpoint committed; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! disarm_durable_transaction cleanup; then
        return 3
    fi
    if ! cleanup_subscription_frontend_snapshot "$snapshot_dir"; then
        FRONTEND_RECOVERY_PATH="$snapshot_dir"
        return 3
    fi
    green "\nCloudflare HTTPS 订阅已启用并通过内容验证：\n${purple}${https_url}${re}\n"
}

configure_cf_https_subscription() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "HTTPS 订阅操作"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _configure_cf_https_subscription_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

_disable_cf_https_subscription_locked() {
    local tunnel_mode path_regex method confirm port http_path config_file config_status
    local old_domain old_https_path snapshot_dir pending_state tunnel_file=''
    local nginx_was_active=0 operation_status=0 rollback_status=0
    local baseline_config_digest baseline_state_digest baseline_tunnel_digest=''
    local current_tunnel_mode

    FRONTEND_RECOVERY_PATH=''
    load_subscription_state
    config_file="${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}"
    if [ "$SUB_HTTPS_ENABLED" != 1 ]; then
        validate_managed_subscription_runtime "$config_file" any
        config_status=$?
        case "$config_status" in
            0|1) yellow "Cloudflare HTTPS 订阅尚未启用。"; return 0 ;;
            *) red "Nginx 配置与订阅状态不一致，已拒绝修改。"; return 2 ;;
        esac
    fi
    validate_managed_subscription_runtime "$config_file" https
    config_status=$?
    case "$config_status" in
        0) ;;
        1) red "Nginx 订阅配置缺失，已拒绝修改 Tunnel 路由或状态。"; return 1 ;;
        *) red "现有 Nginx 配置不是脚本可确认拥有的完整订阅配置，已拒绝修改。"; return 1 ;;
    esac
    tunnel_mode="${SUB_TUNNEL_MODE:-$(detect_argo_tunnel_mode 2>/dev/null || true)}"
    old_domain="$SUB_HTTPS_DOMAIN"
    old_https_path="$SUB_HTTPS_PATH"
    path_regex="^${old_https_path}$"
    port=$(get_nginx_subscription_port "$config_file" 2>/dev/null || true)
    http_path="$SUB_HTTP_PATH"
    [ -n "$port" ] && is_valid_http_subscription_path "$http_path" || return 2
    nginx_service_is_active && nginx_was_active=1
    [ "$tunnel_mode" = local ] && tunnel_file="${work_dir}/tunnel.yml"
    baseline_config_digest=$(subscription_frontend_snapshot_file_digest "$config_file") || return 2
    baseline_state_digest=$(subscription_frontend_snapshot_file_digest \
        "$subscription_state_file") || return 2
    if [ -n "$tunnel_file" ]; then
        baseline_tunnel_digest=$(subscription_frontend_snapshot_file_digest "$tunnel_file") || return 2
    fi

    case "$tunnel_mode" in
        local) ;;
        remote)
            green "1. 使用 Cloudflare API token 自动移除路由"
            green "2. 在 Dashboard 手动移除路由"
            reading "请选择 [1-2，默认2]: " method
            ;;
        *) red "无法识别原固定 Tunnel 类型，未修改状态。"; return 1 ;;
    esac

    snapshot_dir=$(backup_subscription_frontend_snapshot "$config_file" \
        "$subscription_state_file" "$tunnel_file" "$conf_dir") || return 1
    current_tunnel_mode=$(detect_argo_tunnel_mode 2>/dev/null || true)
    if [ "$current_tunnel_mode" != "$tunnel_mode" ] || \
       ! verify_subscription_frontend_snapshot_baseline "$snapshot_dir" "$config_file" \
            "$subscription_state_file" "$tunnel_file" "$baseline_config_digest" \
            "$baseline_state_digest" "$baseline_tunnel_digest" || \
       ! validate_managed_subscription_runtime "$config_file" https; then
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
            FRONTEND_RECOVERY_PATH="$snapshot_dir"
        red "订阅配置在确认期间发生变化，已拒绝覆盖。"
        return 2
    fi
    SUB_HTTPS_ENABLED=0
    SUB_HTTPS_DOMAIN=''
    SUB_HTTPS_DOMAIN_MODE=''
    SUB_HTTPS_PATH=''
    SUB_TUNNEL_MODE=''
    SUB_HTTPS_VERIFIED_AT=''
    pending_state=$(prepare_subscription_frontend_state_transaction \
        "$subscription_state_file" "$snapshot_dir") || {
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
            FRONTEND_RECOVERY_PATH="$snapshot_dir"
        return 1
    }
    if ! arm_durable_transaction subscription-https-disable "$conf_dir" "$snapshot_dir" \
        FRONTEND_RECOVERY_PATH rollback_subscription_frontend_signal_transaction \
        "$nginx_was_active" "$port" "$port" \
        "$snapshot_dir" "$config_file" "$subscription_state_file" \
        "$tunnel_file" "$pending_state"; then
        rm -f -- "$pending_state"
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
            FRONTEND_RECOVERY_PATH="$snapshot_dir"
        return 1
    fi
    apply_nginx_subscription_config "$port" "$http_path" "" \
        "$nginx_was_active" "$config_file" || operation_status=$?
    if [ "$operation_status" -eq 0 ]; then
        durable_transaction_checkpoint config-mutated || operation_status=2
    fi
    if [ "$operation_status" -eq 0 ]; then
        durable_transaction_checkpoint publishing || operation_status=2
    fi
    if [ "$operation_status" -ne 0 ]; then
        rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
            "$subscription_state_file" "$tunnel_file" "$pending_state"
        rollback_status=$?
        load_subscription_state
        if [ "$rollback_status" -eq 0 ]; then
            disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
            return 1
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi

    case "$tunnel_mode" in
        local)
            apply_local_tunnel_subscription_removal "$tunnel_file"
            operation_status=$?
            ;;
        remote)
            if [ "$method" = 1 ]; then
                remove_remote_tunnel_subscription_via_api "$old_domain" "$path_regex"
                operation_status=$?
            else
                yellow "请删除路由：Hostname=${old_domain}, Path=${path_regex}"
                reading "确认已删除后输入 y: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || operation_status=1
            fi
            ;;
    esac
    if [ "$operation_status" -ne 0 ]; then
        if [ "$operation_status" -eq 1 ] && \
           { [ "$tunnel_mode" = local ] || \
             { [ "$tunnel_mode" = remote ] && [ "$method" = 1 ]; }; }; then
            rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
                "$subscription_state_file" "$tunnel_file" "$pending_state"
            rollback_status=$?
            load_subscription_state
            if [ "$rollback_status" -eq 0 ]; then
                disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
                return 1
            fi
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! commit_subscription_frontend_state_transaction "$pending_state" \
        "$subscription_state_file"; then
        if [ "$tunnel_mode" = local ]; then
            rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
                "$subscription_state_file" "$tunnel_file" "$pending_state"
            rollback_status=$?
            load_subscription_state
            if [ "$rollback_status" -eq 0 ]; then
                disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
                return 1
            fi
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! validate_managed_subscription_runtime "$config_file" http; then
        if [ "$tunnel_mode" = local ]; then
            rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
                "$subscription_state_file" "$tunnel_file" ""
            rollback_status=$?
            load_subscription_state
            if [ "$rollback_status" -eq 0 ]; then
                disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
                return 1
            fi
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! durable_transaction_checkpoint committed; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! disarm_durable_transaction cleanup; then
        return 3
    fi
    if ! cleanup_subscription_frontend_snapshot "$snapshot_dir"; then
        FRONTEND_RECOVERY_PATH="$snapshot_dir"
        return 3
    fi
    green "Cloudflare HTTPS 订阅已关闭；HTTP 订阅仍保留。"
}

disable_cf_https_subscription() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "HTTPS 订阅操作"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _disable_cf_https_subscription_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

update_cf_https_subscription_origin() {
    local port="${1:-}"
    local verify_mode="${2:-1}"
    local tunnel_mode path_regex https_url verify_url method confirm operation_status=0

    load_subscription_state
    [ "$SUB_HTTPS_ENABLED" = 1 ] || return 0
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
    case "$verify_mode" in 0|1) ;; *) return 1 ;; esac
    tunnel_mode="${SUB_TUNNEL_MODE:-$(detect_argo_tunnel_mode 2>/dev/null || true)}"
    path_regex="^${SUB_HTTPS_PATH}$"
    https_url=$(build_https_subscription_url "$SUB_HTTPS_DOMAIN" "$SUB_HTTPS_PATH") || return 1
    [ "$verify_mode" = 1 ] && verify_url="$https_url" || verify_url=''

    case "$tunnel_mode" in
        local)
            apply_local_tunnel_subscription_rule "$SUB_HTTPS_DOMAIN" "$path_regex" "$port" \
                "$SUB_HTTPS_DOMAIN_MODE" "${work_dir}/tunnel.yml" "$verify_url"
            operation_status=$?
            ;;
        remote)
            green "HTTPS 订阅已启用，端口变化还需要更新远程 Tunnel origin。"
            green "1. 使用 Cloudflare API token 自动更新"
            green "2. 在 Dashboard 手动更新"
            reading "请选择 [1-2，默认2]: " method
            if [ "$method" = 1 ]; then
                apply_remote_tunnel_subscription_rule "$SUB_HTTPS_DOMAIN" "$path_regex" "$port" \
                    "$SUB_HTTPS_DOMAIN_MODE" "$SUB_HTTPS_DOMAIN" "$path_regex" "$verify_url"
                operation_status=$?
            else
                print_manual_https_route "$SUB_HTTPS_DOMAIN" "$path_regex" "$port"
                if [ "$verify_mode" = 1 ]; then
                    reading "更新完成后输入 y 进行公网验证: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        verify_https_subscription "$https_url" || operation_status=2
                    else
                        operation_status=1
                    fi
                else
                    reading "确认 Dashboard origin 已更新后输入 y: " confirm
                    [[ "$confirm" =~ ^[Yy]$ ]] || operation_status=1
                fi
            fi
            ;;
        *) return 1 ;;
    esac

    [ "$operation_status" -eq 0 ] || return "$operation_status"
    if [ "$verify_mode" = 1 ]; then
        SUB_HTTPS_VERIFIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    else
        SUB_HTTPS_VERIFIED_AT=''
    fi
    save_subscription_state || return 2
}

restore_subscription_port_snapshot() {
    local backup_file="${1:-}"
    local config_file="${2:-}"
    local was_active="${3:-1}"

    [ -f "$backup_file" ] && [ ! -L "$backup_file" ] || return 1
    [ -n "$config_file" ] && [ ! -L "$config_file" ] || return 1
    cp -p -- "$backup_file" "$config_file" || return 1
    nginx -t >/dev/null 2>&1 || return 1
    case "$was_active" in
        1)
            nginx -s reload >/dev/null 2>&1 || restart_nginx >/dev/null 2>&1 || return 1
            nginx_service_is_active
            ;;
        0)
            if nginx_service_is_active; then
                stop_nginx_checked || return 1
            fi
            ! nginx_service_is_active
            ;;
        *) return 1 ;;
    esac
}

rollback_subscription_port_transaction() {
    local backup_file="${1:-}"
    local config_file="${2:-}"
    local old_port="${3:-}"
    local was_active="${4:-1}"
    local origin_attempted="${5:-0}"
    shift 5 || return 2
    local status=0
    local -a firewall_records=("$@")

    restore_subscription_port_snapshot "$backup_file" "$config_file" "$was_active" || status=1
    if [ "$origin_attempted" = 1 ]; then
        update_cf_https_subscription_origin "$old_port" "$was_active" || status=1
    fi
    if [ "${#firewall_records[@]}" -gt 0 ]; then
        remove_owned_firewall_records_exact "${firewall_records[@]}" || status=1
    fi
    if [ "$status" -eq 0 ]; then
        if rm -f -- "$backup_file"; then
            return 1
        fi
        SUBSCRIPTION_PORT_RECOVERY_PATH="$backup_file"
        red "订阅端口已恢复，但 Nginx 备份未能清理：${backup_file}"
        return 2
    fi

    SUBSCRIPTION_PORT_RECOVERY_PATH="$backup_file"
    red "订阅端口事务回滚不完整，已保留 Nginx 备份：${backup_file}"
    return 2
}

rollback_subscription_port_signal_transaction() {
    local backup_file="${1:-}"
    local config_file="${2:-}"
    local old_port="${3:-}"
    local was_active="${4:-0}"
    local rollback_status=0

    if [ "${SUBSCRIPTION_TX_CONFIG_MUTATED:-0}" = 1 ]; then
        rollback_subscription_port_transaction "$backup_file" "$config_file" "$old_port" \
            "$was_active" "${SUBSCRIPTION_TX_ORIGIN_ATTEMPTED:-0}" \
            "${DURABLE_TX_OWNED_RECORDS[@]}"
        rollback_status=$?
        [ "$rollback_status" -eq 1 ] && return 0
        return 1
    fi
    if [ "${#DURABLE_TX_OWNED_RECORDS[@]}" -gt 0 ]; then
        remove_owned_firewall_records_exact "${DURABLE_TX_OWNED_RECORDS[@]}" || return 1
    fi
    rm -f -- "$backup_file"
}

_change_subscription_port_transaction_locked() {
    local config_file="${1:-${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}}"
    local new_port="${2:-}"
    local http_path="${3:-}"
    local https_path="${4:-}"
    local old_port backup_file operation_status origin_attempted=0 nginx_was_active=0 config_status
    local inbounds_file="${conf_dir}/inbounds.json" conflict_status
    local -a new_firewall_records=() current_paths=()

    SUBSCRIPTION_PORT_RECOVERY_PATH=''
    validate_port_value "$new_port" subscription_port || return 1
    validate_managed_subscription_runtime "$config_file" any
    config_status=$?
    [ "$config_status" -eq 0 ] || {
        red "现有 Nginx 配置不是脚本可确认拥有的完整订阅配置，已拒绝修改端口。"
        return 1
    }
    mapfile -t current_paths < <(get_nginx_subscription_paths "$config_file")
    [ "${#current_paths[@]}" -ge 1 ] && [ "${#current_paths[@]}" -le 2 ] || return 2
    http_path="${current_paths[0]}"
    https_path=''
    [ "${#current_paths[@]}" -eq 1 ] || https_path="${current_paths[1]}"
    is_valid_http_subscription_path "$http_path" || return 2
    [ -z "$https_path" ] || is_valid_http_subscription_path "$https_path" || return 2
    old_port=$(get_nginx_subscription_port "$config_file") || return 1
    [ "$old_port" != "$new_port" ] || return 0
    nginx_service_is_active && nginx_was_active=1

    if configured_inbound_port_conflict_exists "$inbounds_file" "$new_port" tcp; then
        red "端口 ${new_port}/tcp 已被 sing-box 配置占用。"
        return 1
    else
        conflict_status=$?
    fi
    [ "$conflict_status" -eq 1 ] || return 2
    if port_is_listening "$new_port" tcp; then
        red "端口 ${new_port}/tcp 已被其他进程监听。"
        return 1
    fi

    backup_file=$(mktemp "$(dirname "$config_file")/.subscription-port-backup.XXXXXX") || return 1
    if ! cp -p -- "$config_file" "$backup_file"; then
        rm -f -- "$backup_file"
        return 1
    fi
    if ! chmod 600 "$backup_file"; then
        rm -f -- "$backup_file"
        return 1
    fi
    SUBSCRIPTION_TX_CONFIG_MUTATED=0
    SUBSCRIPTION_TX_ORIGIN_ATTEMPTED=0
    if ! arm_durable_transaction subscription-port "$(dirname "$backup_file")" "$backup_file" \
        SUBSCRIPTION_PORT_RECOVERY_PATH rollback_subscription_port_signal_transaction \
        "$nginx_was_active" "$old_port" "$new_port" \
        "$backup_file" "$config_file" "$old_port" "$nginx_was_active"; then
        if ! rm -f -- "$backup_file"; then
            SUBSCRIPTION_PORT_RECOVERY_PATH="$backup_file"
            return 2
        fi
        return 1
    fi

    if ! durable_transaction_checkpoint firewall-mutating; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    allow_port "${new_port}/tcp"
    operation_status=$?
    if [ "$operation_status" -ne 0 ]; then
        if [ "$operation_status" -eq 2 ]; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            red "防火墙事务状态未决，已保留订阅端口恢复证据。"
            return 2
        fi
        if ! rm -f -- "$backup_file"; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        fi
        if ! disarm_durable_transaction cleanup; then
            return 2
        fi
        return "$operation_status"
    fi
    new_firewall_records=("${FIREWALL_LAST_ADDED_RECORDS[@]}")
    if ! durable_transaction_set_owned_records "${new_firewall_records[@]}" || \
       ! durable_transaction_checkpoint precommit; then
        rollback_subscription_port_signal_transaction "$backup_file" "$config_file" \
            "$old_port" "$nginx_was_active" || {
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        }
        disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
        return 1
    fi

    SUBSCRIPTION_TX_CONFIG_MUTATED=1
    apply_nginx_subscription_config "$new_port" "$http_path" "$https_path" \
        "$nginx_was_active" "$config_file"
    operation_status=$?
    if [ "$operation_status" -ne 0 ]; then
        rollback_subscription_port_transaction "$backup_file" "$config_file" "$old_port" \
            "$nginx_was_active" 0 \
            "${new_firewall_records[@]}"
        operation_status=$?
        if [ "$operation_status" -eq 1 ]; then
            disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
        else
            disarm_durable_transaction keep >/dev/null 2>&1 || true
        fi
        return "$operation_status"
    fi
    if ! durable_transaction_checkpoint config-mutated; then
        rollback_subscription_port_signal_transaction "$backup_file" "$config_file" \
            "$old_port" "$nginx_was_active" || {
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        }
        disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
        return 1
    fi

    if ! durable_transaction_checkpoint publishing; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    origin_attempted=1
    SUBSCRIPTION_TX_ORIGIN_ATTEMPTED=1
    update_cf_https_subscription_origin "$new_port" "$nginx_was_active"
    operation_status=$?
    if [ "$operation_status" -ne 0 ]; then
        if [ "$operation_status" -eq 2 ]; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            red "远程 HTTPS origin 状态未决，已保留订阅端口恢复证据。"
            return 2
        fi
        rollback_subscription_port_transaction "$backup_file" "$config_file" "$old_port" \
            "$nginx_was_active" "$origin_attempted" "${new_firewall_records[@]}"
        operation_status=$?
        if [ "$operation_status" -eq 1 ]; then
            disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
        else
            disarm_durable_transaction keep >/dev/null 2>&1 || true
        fi
        return "$operation_status"
    fi

    remove_owned_firewall_ports_if_unused "$inbounds_file" --nginx-config "$config_file" \
        "${old_port}/tcp"
    operation_status=$?
    if [ "$operation_status" -ne 0 ]; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        red "新订阅端口已生效，但旧端口规则未能安全清理；已保留 Nginx 备份：${backup_file}"
        return 2
    fi
    if ! durable_transaction_checkpoint committed; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! rm -f -- "$backup_file"; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        red "订阅端口已健康提交，但事务备份未能清理：${backup_file}"
        return 3
    fi
    if ! disarm_durable_transaction cleanup; then
        return 3
    fi
}

change_subscription_port_transaction() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅端口修改"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _change_subscription_port_transaction_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

_rotate_subscription_token_locked() {
    local port old_path token new_path host link confirm config_file config_status
    local snapshot_dir pending_state nginx_was_active=0 operation_status rollback_status
    local baseline_config_digest baseline_state_digest

    FRONTEND_RECOVERY_PATH=''
    load_subscription_state
    if [ "$SUB_HTTPS_ENABLED" = 1 ]; then
        _configure_cf_https_subscription_locked 1
        return $?
    fi

    config_file="${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}"
    validate_managed_subscription_runtime "$config_file" http
    config_status=$?
    case "$config_status" in
        0) ;;
        1) red "未找到有效的 HTTP 订阅，无法轮换密钥。"; return 1 ;;
        *) red "现有 Nginx 配置不是脚本可确认拥有的完整订阅配置，已拒绝轮换。"; return 1 ;;
    esac
    port=$(get_nginx_subscription_port "$config_file" 2>/dev/null || true)
    old_path=$(get_nginx_subscription_paths "$config_file" 2>/dev/null | head -1)
    [ -n "$port" ] && is_valid_http_subscription_path "$old_path" || {
        red "未找到有效的 HTTP 订阅，无法轮换密钥。"
        return 1
    }
    baseline_config_digest=$(subscription_frontend_snapshot_file_digest "$config_file") || return 2
    baseline_state_digest=$(subscription_frontend_snapshot_file_digest \
        "$subscription_state_file") || return 2
    yellow "轮换后旧 HTTP 订阅 URL 将立即失效。"
    reading "确认继续？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    token=$(generate_subscription_token) || return 1
    new_path="/${token}"
    nginx_service_is_active && nginx_was_active=1
    snapshot_dir=$(backup_subscription_frontend_snapshot "$config_file" \
        "$subscription_state_file" "" "$conf_dir") || return 1
    if ! verify_subscription_frontend_snapshot_baseline "$snapshot_dir" "$config_file" \
        "$subscription_state_file" "" "$baseline_config_digest" \
        "$baseline_state_digest" "" || \
       ! validate_managed_subscription_runtime "$config_file" http; then
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
            FRONTEND_RECOVERY_PATH="$snapshot_dir"
        red "订阅配置在确认期间发生变化，已拒绝轮换。"
        return 2
    fi
    SUB_TOKEN="$token"
    SUB_HTTP_PATH="$new_path"
    SUB_HTTPS_ENABLED=0
    SUB_HTTPS_DOMAIN=''
    SUB_HTTPS_DOMAIN_MODE=''
    SUB_HTTPS_PATH=''
    SUB_TUNNEL_MODE=''
    SUB_HTTPS_VERIFIED_AT=''
    pending_state=$(prepare_subscription_frontend_state_transaction \
        "$subscription_state_file" "$snapshot_dir") || {
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
            FRONTEND_RECOVERY_PATH="$snapshot_dir"
        return 1
    }
    if ! arm_durable_transaction subscription-token "$conf_dir" "$snapshot_dir" \
        FRONTEND_RECOVERY_PATH rollback_subscription_frontend_signal_transaction \
        "$nginx_was_active" "$port" "$port" \
        "$snapshot_dir" "$config_file" "$subscription_state_file" "" "$pending_state"; then
        rm -f -- "$pending_state"
        cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
            FRONTEND_RECOVERY_PATH="$snapshot_dir"
        return 1
    fi

    apply_nginx_subscription_config "$port" "$new_path" "" \
        "$nginx_was_active" "$config_file"
    operation_status=$?
    if [ "$operation_status" -eq 0 ]; then
        durable_transaction_checkpoint config-mutated || operation_status=2
    fi
    if [ "$operation_status" -eq 0 ]; then
        durable_transaction_checkpoint publishing || operation_status=2
    fi
    if [ "$operation_status" -eq 0 ]; then
        commit_subscription_frontend_state_transaction "$pending_state" \
            "$subscription_state_file" || operation_status=1
    fi
    if [ "$operation_status" -ne 0 ]; then
        rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
            "$subscription_state_file" "" "$pending_state"
        rollback_status=$?
        load_subscription_state
        if [ "$rollback_status" -eq 0 ]; then
            disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
            return 1
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! validate_managed_subscription_runtime "$config_file" http; then
        rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
            "$subscription_state_file" "" ""
        rollback_status=$?
        load_subscription_state
        if [ "$rollback_status" -eq 0 ]; then
            disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
            return 1
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! durable_transaction_checkpoint committed; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! disarm_durable_transaction cleanup; then
        return 3
    fi
    if ! cleanup_subscription_frontend_snapshot "$snapshot_dir"; then
        FRONTEND_RECOVERY_PATH="$snapshot_dir"
        return 3
    fi
    host=$(get_subscription_host 2>/dev/null || true)
    link=$(build_http_subscription_url "$host" "$port" "$new_path" 2>/dev/null || true)
    green "订阅密钥已轮换，新 HTTP 订阅：${purple}${link}${re}"
}

rotate_subscription_token() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅密钥轮换"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _rotate_subscription_token_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

_stop_subscription_service_locked() {
    local status

    if command_exists nginx; then
        if command_exists rc-service 2>/dev/null; then
            if rc-service nginx status 2>/dev/null | grep -q "started"; then
                rc-service nginx stop || return 1
                if rc-service nginx status 2>/dev/null | grep -q "started"; then
                    return 1
                fi
            else
                red "nginx not running"
            fi
        else
            systemctl is-active --quiet nginx
            status=$?
            case "$status" in
                0)
                    systemctl stop nginx || return 1
                    systemctl is-active --quiet nginx && return 1
                    ;;
                3) red "nginx not running" ;;
                *) return 1 ;;
            esac
        fi
    else
        yellow "nginx未安装，节点订阅本来就未运行。"
    fi
}

stop_subscription_service_transaction() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅服务停止"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _stop_subscription_service_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

_start_subscription_service_locked() {
    local config_file="${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}"
    local http_path link token server_ip sub_port input_port conflict_status config_status
    local snapshot_dir pending_state nginx_was_active=0 operation_status=0 rollback_status=0
    local baseline_config_digest baseline_state_digest current_config_digest current_state_digest
    local -a new_firewall_records=()

    baseline_config_digest=$(subscription_frontend_snapshot_file_digest "$config_file") || return 2
    baseline_state_digest=$(subscription_frontend_snapshot_file_digest \
        "$subscription_state_file") || return 2
    classify_nginx_subscription_config "$config_file"
    config_status=$?
    case "$config_status" in
        0)
            validate_managed_subscription_runtime "$config_file" any || {
                red "Nginx 订阅配置与订阅状态不一致，已拒绝启动。"
                return 2
            }
            sub_port=$(get_nginx_subscription_port "$config_file") || return 2
            http_path=$(get_nginx_subscription_paths "$config_file" | head -1)
            is_valid_http_subscription_path "$http_path" || return 2
            ;;
        1)
            if [ -e "$subscription_state_file" ] || [ -L "$subscription_state_file" ]; then
                red "订阅状态文件存在但 Nginx 配置缺失；为避免覆盖残留状态，已拒绝自动重建。"
                return 1
            fi
            ;;
        *)
            red "现有 Nginx 配置不是脚本可确认拥有的完整订阅配置，已拒绝覆盖。"
            return 1
            ;;
    esac
    current_config_digest=$(subscription_frontend_snapshot_file_digest "$config_file") || return 2
    current_state_digest=$(subscription_frontend_snapshot_file_digest \
        "$subscription_state_file") || return 2
    if [ "$current_config_digest" != "$baseline_config_digest" ] || \
       [ "$current_state_digest" != "$baseline_state_digest" ]; then
        red "订阅配置在启动检查期间发生变化，已拒绝继续。"
        return 2
    fi

    server_ip=$(get_subscription_host) || return 1
    [ -n "$server_ip" ] || return 1

    if [ "$config_status" -eq 0 ]; then
        current_config_digest=$(subscription_frontend_snapshot_file_digest "$config_file") || return 2
        current_state_digest=$(subscription_frontend_snapshot_file_digest \
            "$subscription_state_file") || return 2
        if [ "$current_config_digest" != "$baseline_config_digest" ] || \
           [ "$current_state_digest" != "$baseline_state_digest" ] || \
           ! validate_managed_subscription_runtime "$config_file" any; then
            red "订阅配置在主机信息获取期间发生变化，已拒绝启动。"
            return 2
        fi
        start_nginx || return 1
        nginx_service_is_active || return 1
    else
        token=$(generate_subscription_token) || { red "订阅密钥生成失败"; return 1; }
        http_path="/$token"
        while :; do
            reading "请输入订阅监听端口（NAT 机器请输入已分配端口，回车随机）: " input_port
            if [ -z "$input_port" ]; then
                input_port=$(shuf -i 2000-65000 -n 1) || return 1
            fi
            if ! validate_port_value "$input_port" subscription_port; then
                red "端口必须是 1-65535 的整数"
                continue
            fi
            if configured_inbound_port_conflict_exists "${conf_dir}/inbounds.json" "$input_port" tcp; then
                red "端口 ${input_port}/tcp 已被 sing-box 配置占用。"
                continue
            else
                conflict_status=$?
            fi
            [ "$conflict_status" -eq 1 ] || return 2
            if port_is_listening "$input_port" tcp; then
                red "端口 ${input_port}/tcp 已被其他进程监听。"
                continue
            fi
            sub_port="$input_port"
            break
        done

        SUBSCRIPTION_CREATE_RECOVERY_PATH=''
        nginx_service_is_active && nginx_was_active=1
        snapshot_dir=$(backup_subscription_frontend_snapshot "$config_file" \
            "$subscription_state_file" "" "$conf_dir") || return 1
        if ! verify_subscription_frontend_snapshot_baseline "$snapshot_dir" "$config_file" \
            "$subscription_state_file" "" "$baseline_config_digest" \
            "$baseline_state_digest" ""; then
            cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
                SUBSCRIPTION_CREATE_RECOVERY_PATH="$snapshot_dir"
            red "订阅配置在端口确认期间发生变化，已拒绝覆盖。"
            return 2
        fi
        SUB_TOKEN="$token"
        SUB_HTTP_PATH="$http_path"
        SUB_HTTPS_ENABLED=0
        SUB_HTTPS_DOMAIN=''
        SUB_HTTPS_DOMAIN_MODE=''
        SUB_HTTPS_PATH=''
        SUB_TUNNEL_MODE=''
        SUB_HTTPS_VERIFIED_AT=''
        pending_state=$(prepare_subscription_frontend_state_transaction \
            "$subscription_state_file" "$snapshot_dir") || {
            cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
                SUBSCRIPTION_CREATE_RECOVERY_PATH="$snapshot_dir"
            return 1
        }
        if ! arm_durable_transaction subscription-create "$conf_dir" "$snapshot_dir" \
            SUBSCRIPTION_CREATE_RECOVERY_PATH rollback_subscription_frontend_signal_transaction \
            "$nginx_was_active" "" "$sub_port" \
            "$snapshot_dir" "$config_file" "$subscription_state_file" "" "$pending_state"; then
            rm -f -- "$pending_state"
            cleanup_subscription_frontend_snapshot "$snapshot_dir" || \
                SUBSCRIPTION_CREATE_RECOVERY_PATH="$snapshot_dir"
            return 1
        fi
        if ! durable_transaction_checkpoint firewall-mutating; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        fi

        allow_port "${sub_port}/tcp"
        operation_status=$?
        if [ "$operation_status" -ne 0 ]; then
            if [ "$operation_status" -eq 2 ]; then
                disarm_durable_transaction keep >/dev/null 2>&1 || true
                return 2
            fi
            rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
                "$subscription_state_file" "" "$pending_state"
            rollback_status=$?
            if [ "$rollback_status" -eq 0 ]; then
                disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
                return "$operation_status"
            fi
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        fi
        new_firewall_records=("${FIREWALL_LAST_ADDED_RECORDS[@]}")
        if ! durable_transaction_set_owned_records "${new_firewall_records[@]}" || \
           ! durable_transaction_checkpoint precommit; then
            rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
                "$subscription_state_file" "" "$pending_state"
            rollback_status=$?
            if [ "$rollback_status" -eq 0 ]; then
                disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
                return 1
            fi
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        fi
        apply_nginx_subscription_config "$sub_port" "$http_path" "" start "$config_file" || \
            operation_status=$?
        if [ "$operation_status" -eq 0 ]; then
            durable_transaction_checkpoint config-mutated || operation_status=2
        fi
        if [ "$operation_status" -eq 0 ]; then
            commit_subscription_frontend_state_transaction "$pending_state" \
                "$subscription_state_file" || operation_status=1
        fi
        if [ "$operation_status" -eq 0 ]; then
            link=$(build_http_subscription_url "$server_ip" "$sub_port" "$http_path") || \
                operation_status=$?
        fi
        if [ "$operation_status" -eq 0 ]; then
            nginx_service_is_active || operation_status=1
        fi
        if [ "$operation_status" -eq 0 ]; then
            validate_managed_subscription_runtime "$config_file" http || operation_status=2
        fi
        if [ "$operation_status" -ne 0 ]; then
            rollback_subscription_frontend_signal_transaction "$snapshot_dir" "$config_file" \
                "$subscription_state_file" "" "$pending_state"
            rollback_status=$?
            load_subscription_state
            if [ "$rollback_status" -eq 0 ]; then
                disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
                return 1
            fi
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        fi
        if ! durable_transaction_checkpoint committed; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        fi
        if ! disarm_durable_transaction cleanup; then
            return 3
        fi
        if ! cleanup_subscription_frontend_snapshot "$snapshot_dir"; then
            SUBSCRIPTION_CREATE_RECOVERY_PATH="$snapshot_dir"
            return 3
        fi
    fi

    [ -n "${link:-}" ] || link=$(build_http_subscription_url "$server_ip" "$sub_port" "$http_path") || return 1
    green "\n已开启节点订阅\n节点订阅链接：${purple}${link}${re}\n"
}

start_subscription_service_transaction() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅服务启动"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _start_subscription_service_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

_restart_subscription_service_locked() {
    restart_nginx
}

restart_subscription_service_transaction() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅服务重启"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _restart_subscription_service_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

disable_open_sub() {
    local singbox_installed=$?
    check_singbox &>/dev/null; singbox_installed=$?
    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
    fi

    clear; echo ""
    green "=== 管理节点订阅 ===\n"
    skyblue "------------"
    green "1. 关闭节点订阅"
    skyblue "------------"
    green "2. 开启节点订阅"
    skyblue "------------"
    green "3. 更换订阅端口"
    skyblue "------------"
    green "4. 重启订阅服务"
    skyblue "------------"
    green "5. 查看订阅链接与详细状态"
    skyblue "--------------------------"
    green "6. 配置 Cloudflare HTTPS 订阅"
    skyblue "---------------------------"
    green "7. 关闭 Cloudflare HTTPS 订阅"
    skyblue "---------------------------"
    green "8. 重新生成订阅密钥"
    skyblue "------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            stop_subscription_service_transaction || return $?
            green "\n已关闭节点订阅；HTTP 与 Cloudflare HTTPS 订阅都会停止响应。\n"
            ;;
        2)
            start_subscription_service_transaction || return $?
            ;;
        3)
            reading "请输入新的订阅端口(1-65535,直接回车随机生成):" sub_port
            [ -z "$sub_port" ] && sub_port=$(shuf -i 2000-65000 -n 1)
            until [[ "$sub_port" =~ ^[0-9]+$ ]] && [ "$sub_port" -ge 1 ] 2>/dev/null && [ "$sub_port" -le 65535 ] 2>/dev/null; do
                red "端口必须是 1-65535 的整数"
                reading "请输入新的订阅端口(1-65535):" sub_port
            done
            until [[ -z $(lsof -iTCP:"$sub_port" -sTCP:LISTEN -t) ]]; do
                echo -e "${red}端口 $sub_port 已被占用${re}"
                reading "请输入新的订阅端口(1-65535):" sub_port
                until [[ "$sub_port" =~ ^[0-9]+$ ]] && [ "$sub_port" -ge 1 ] 2>/dev/null && [ "$sub_port" -le 65535 ] 2>/dev/null; do
                    red "端口必须是 1-65535 的整数"
                    reading "请输入新的订阅端口(1-65535):" sub_port
                done
            done
            green "新的订阅端口为：${purple}${sub_port}${re}"
            if change_subscription_port_transaction "/etc/nginx/conf.d/sing-box.conf" \
                "$sub_port"; then
                local -a final_paths
                mapfile -t final_paths < <(get_nginx_subscription_paths "/etc/nginx/conf.d/sing-box.conf")
                [ "${#final_paths[@]}" -gt 0 ] || {
                    red "端口已修改，但无法读取最终订阅路径，请检查 Nginx 配置。"
                    return 2
                }
                server_ip=$(get_subscription_host) || return 2
                [ -n "$server_ip" ] || return 2
                link=$(build_http_subscription_url "$server_ip" "$sub_port" "${final_paths[0]}" 2>/dev/null || true)
                green "\n订阅端口更换成功\n新的订阅链接为：${purple}${link}${re}\n"
            else
                local port_change_status=$?
                [ "$port_change_status" -eq 2 ] && \
                    red "订阅端口事务未能完整收尾，请按上方备份路径人工检查。"
                return "$port_change_status"
            fi
            ;;
        4) restart_subscription_service_transaction || return $? ;;
        5) show_subscription_status ;;
        6) configure_cf_https_subscription || return $? ;;
        7) disable_cf_https_subscription || return $? ;;
        8) rotate_subscription_token || return $? ;;
        0) menu ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回...\033[0m\n'
}

# singbox 管理
manage_singbox() {
    local singbox_status=$(check_singbox 2>/dev/null)
    clear; echo ""
    green "=== sing-box 管理 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 启动sing-box服务"
    skyblue "-------------------"
    green "2. 停止sing-box服务"
    skyblue "-------------------"
    green "3. 重启sing-box服务"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        0) menu ;;
        *) red "无效的选项！" && sleep 1 && manage_singbox ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回...\033[0m\n'
}

# Argo 管理
manage_argo() {
    local service_file="${1:-}"
    local argo_status=$(check_argo 2>/dev/null)
    clear; echo ""
    green "=== Argo 隧道管理 ===\n"
    green "Argo当前状态: $argo_status\n"
    green "1. 启动Argo服务"
    skyblue "------------"
    green "2. 停止Argo服务"
    skyblue "------------"
    green "3. 重启Argo服务"
    skyblue "------------"
    green "4. 添加Argo固定隧道"
    skyblue "----------------"
    green "5. 切换回Argo临时隧道"
    skyblue "------------------"
    green "6. 重新获取Argo临时域名"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "-----------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_argo ;;
        2) stop_argo ;;
        3)
            clear
            if command_exists rc-service 2>/dev/null; then
                grep -Eq -- '--url http://(127\.0\.0\.1|localhost)' /etc/init.d/argo && get_quick_tunnel && change_argo_domain || \
                    { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            else
                grep -Eq 'ExecStart=.*--url http://(127\.0\.0\.1|localhost)' /etc/systemd/system/argo.service && get_quick_tunnel && change_argo_domain || \
                    { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            fi
            ;;
        4)
            clear
            yellow "\n固定隧道可为json或token，固定隧道本地端口为${ARGO_PORT}, 使用token请在cloudflare里设置一致\njson获取地址：${purple}https://fscarmen.cloudflare.now.cc${re}\n"
            reading "\n请输入你的argo域名: " argo_domain
            if ! is_argo_hostname "$argo_domain"; then
                yellow "argo 域名格式不匹配，请重新输入"
                manage_argo; return
            fi
            ArgoDomain=$argo_domain
            ARGO_DOMAIN="$argo_domain"
            reading_secret "\n请输入你的argo密钥(token或json): " argo_auth
            if [[ $argo_auth =~ TunnelSecret ]]; then
                tunnel_id=$(extract_argo_tunnel_id "$argo_auth")
                [ -z "$tunnel_id" ] && { yellow "ARGO_AUTH 未解析到 TunnelID，请重新输入"; manage_argo; return; }
                ARGO_AUTH="$argo_auth"
                ARGO_FIXED_READY=1
                write_fixed_argo_credentials json "$argo_auth" || {
                    yellow "固定 Tunnel JSON 保存失败"
                    return 1
                }
                atomic_write_secret_file "${work_dir}/tunnel.yml" << EOF || return 1
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $ArgoDomain
    service: http://127.0.0.1:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                if command_exists rc-service 2>/dev/null; then
                    write_argo_openrc_service local || return 1
                else
                    write_argo_systemd_service local || return 1
                fi
                restart_argo; sleep 1; change_argo_domain
            elif is_argo_tunnel_token "$argo_auth"; then
                ARGO_AUTH="$argo_auth"
                ARGO_FIXED_READY=1
                write_fixed_argo_credentials token "$argo_auth" || {
                    yellow "固定 Tunnel token 保存失败"
                    return 1
                }
                if command_exists rc-service 2>/dev/null; then
                    write_argo_openrc_service token || return 1
                else
                    write_argo_systemd_service token || return 1
                fi
                restart_argo; sleep 1; change_argo_domain
            else
                yellow "输入不匹配，请重新输入"; manage_argo; return
            fi
            if [ "$ARGO_FIXED_READY" = 1 ] && [ -t 0 ]; then
                reading "是否同时配置 Cloudflare HTTPS 订阅？[y/N]: " enable_https_subscription
                if [[ "$enable_https_subscription" =~ ^[Yy]$ ]]; then
                    configure_cf_https_subscription || return $?
                fi
            fi
            ;;
        5)
            clear
            load_subscription_state
            if [ "$SUB_HTTPS_ENABLED" = 1 ]; then
                SUB_HTTPS_ENABLED=0
                SUB_HTTPS_VERIFIED_AT=''
                save_subscription_state || true
                yellow "已切换到临时 Tunnel，稳定 HTTPS 订阅状态已暂停；HTTP 订阅保留。"
            fi
            use_quick_argo_fallback
            if command_exists rc-service 2>/dev/null; then alpine_openrc_services
            else main_systemd_services; fi
            get_quick_tunnel; change_argo_domain
            ;;
        6)
            dispatch_argo_menu_action "$choice" "$service_file" || { sleep 2; return 1; }
            ;;
        0) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# 获取最新的临时 Argo 域名
get_latest_argo_domain() {
    local log_file="${1:-${work_dir}/argo.log}"
    [ -f "$log_file" ] || return 1
    sed -n 's|.*https://\([^/[:space:]]*trycloudflare\.com\).*|\1|p' "$log_file" | tail -n 1
}

# 获取argo临时隧道
get_quick_tunnel() {
    : > "${work_dir}/argo.log" 2>/dev/null || true
    restart_argo
    yellow "获取临时argo域名中，请稍等...\n"
    sleep 3
    for i in {1..8}; do
        purple "第 $i 次尝试获取ArgoDomain中..."
        get_argodomain=$(get_latest_argo_domain)
        [ -n "$get_argodomain" ] && break
        sleep 2
    done
    [ -z "$get_argodomain" ] && { red "未获取到临时Argo域名，请检查 argo 服务日志"; return 1; }
    green "ArgoDomain：${purple}$get_argodomain${re}\n"
    ArgoDomain=$get_argodomain
}

update_vless_argo_domain_file() {
    local target_file="$1"
    local new_domain="$2"
    local tmp_file

    [ -n "$new_domain" ] || return 1
    [ -s "$target_file" ] || return 0

    tmp_file=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == vless://* && "$line" == *"path=%2Fvless-argo"* ]]; then
            line=$(printf '%s\n' "$line" | sed -E "s#([?&]sni=)[^&#]*#\1${new_domain}#g; s#([?&]host=)[^&#]*#\1${new_domain}#g")
        fi
        printf '%s\n' "$line"
    done < "$target_file" > "$tmp_file" && mv "$tmp_file" "$target_file"
}
update_uuid_file() {
    local target_file="$1"
    local new_uuid="$2"
    local tmp_file line encoded_vmess decoded_vmess updated_vmess encoded_updated_vmess

    [ -n "$new_uuid" ] || return 1
    [ -s "$target_file" ] || return 0

    tmp_file=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == vless://* ]]; then
            line=$(printf '%s\n' "$line" | sed -E "s#^vless://[^@]+@#vless://${new_uuid}@#")
        elif [[ "$line" == vmess://* ]] && command_exists jq; then
            encoded_vmess="${line#vmess://}"
            decoded_vmess=$(printf '%s' "$encoded_vmess" | base64 --decode 2>/dev/null || printf '%s' "$encoded_vmess" | base64 -d 2>/dev/null || true)
            if [ -n "$decoded_vmess" ]; then
                updated_vmess=$(printf '%s' "$decoded_vmess" | jq --arg uuid "$new_uuid" '.id = $uuid' 2>/dev/null || true)
                if [ -n "$updated_vmess" ]; then
                    encoded_updated_vmess=$(printf '%s' "$updated_vmess" | base64 -w0 2>/dev/null || printf '%s' "$updated_vmess" | base64 | tr -d '\n\r')
                    line="vmess://${encoded_updated_vmess}"
                fi
            fi
        fi
        printf '%s\n' "$line"
    done < "$target_file" > "$tmp_file" && mv "$tmp_file" "$target_file"
}

# 更新VLESS Argo域名到订阅
update_vless_argo_domain() {
    update_vless_argo_domain_file "$client_dir" "$1"
}

change_argo_domain() {
    [ -z "$ArgoDomain" ] && { red "未获取到Argo域名，无法更新节点"; return 1; }

    update_vless_argo_domain "$ArgoDomain"
    update_vless_argo_domain_file "${work_dir}/cfy-url.txt" "$ArgoDomain"

    # 兼容用户手动保留的旧 VMess 模板；默认新安装不再生成 VMess。
    local vmess_url
    vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir" | head -1)
    if [ -n "$vmess_url" ]; then
        local encoded_vmess decoded_vmess updated_vmess encoded_updated_vmess new_vmess_url
        encoded_vmess="${vmess_url#vmess://}"
        decoded_vmess=$(echo "$encoded_vmess" | base64 --decode 2>/dev/null || true)
        if [ -n "$decoded_vmess" ]; then
            updated_vmess=$(echo "$decoded_vmess" | jq --arg new_domain "$ArgoDomain" '.host = $new_domain | .sni = $new_domain | del(.allowInsecure)' 2>/dev/null || true)
            if [ -n "$updated_vmess" ]; then
                encoded_updated_vmess=$(echo "$updated_vmess" | base64 | tr -d '\n')
                new_vmess_url="vmess://${encoded_updated_vmess}"
                sed -i "s|$vmess_url|$new_vmess_url|" "$client_dir"
            fi
        fi
    fi

    update_sub

    green "vless-ws-tls-argo节点已更新\n"
    grep 'path=%2Fvless-argo' "$client_dir" | while IFS= read -r line; do purple "$line\n"; done
    [ -s "${work_dir}/cfy-url.txt" ] && grep 'path=%2Fvless-argo' "${work_dir}/cfy-url.txt" | while IFS= read -r line; do purple "$line\n"; done
}
check_nodes() {
    if [ ! -f "${work_dir}/url.txt" ]; then
        red "节点信息文件不存在，请先安装 sing-box"; return 1
    fi

    local latest_argodomain
    latest_argodomain=$(get_latest_argo_domain 2>/dev/null || true)
    if [ -n "$latest_argodomain" ]; then
        ArgoDomain="$latest_argodomain"
        change_argo_domain >/dev/null 2>&1 || true
    fi

    server_ip=$(get_subscription_host)
    local base64_url cfy_result_file
    cfy_result_file="${work_dir}/cfy-url.txt"
    base64_url=$(resolve_installed_subscription_source_url "$server_ip" 2>/dev/null || true)

    clear; echo ""
    green "=== 当前节点信息 ===\n"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "${purple}${line}${re}\n"
    done < "${work_dir}/url.txt"

    if [ -s "$cfy_result_file" ]; then
        green "\n=== 最近一次 cfy 优选节点 ===\n"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo -e "${purple}${line}${re}\n"
        done < "$cfy_result_file"
    else
        yellow "\n未找到 cfy 优选结果文件：${cfy_result_file}\n"
    fi

    yellow "\n温馨提醒: 如果hysteria2或tuic不通，请尝试将节点里的 "跳过证书验证" 设置为 "true" 或切换内核\n"
    green "\n=== 订阅链接 ===\n"

    show_subscription_links "$base64_url"
}

change_cfip() {
    clear
    yellow "修改vless-ws-tls-argo优选域名\n"
    green "1: cf.090227.xyz  2: cf.877774.xyz  3: cf.877771.xyz  4: cdns.doon.eu.org  5: cf.zhetengsha.eu.org  6: time.is\n"
    reading "请输入你的优选域名或优选IP\n(请输入1至6选项,可输入域名:端口 或 IP:端口,直接回车默认使用1): " cfip_input

    case "$cfip_input" in
        ""|"1") cfip="cf.090227.xyz";          cfport="443" ;;
        "2")    cfip="cf.877774.xyz";           cfport="443" ;;
        "3")    cfip="cf.877771.xyz";           cfport="443" ;;
        "4")    cfip="cdns.doon.eu.org";        cfport="443" ;;
        "5")    cfip="cf.zhetengsha.eu.org";    cfport="443" ;;
        "6")    cfip="time.is";                 cfport="443" ;;
        *)
            if [[ "$cfip_input" =~ : ]]; then
                cfip=$(echo "$cfip_input" | cut -d':' -f1)
                cfport=$(echo "$cfip_input" | cut -d':' -f2)
            else
                cfip="$cfip_input"; cfport="443"
            fi
            ;;
    esac

    local tmp_file
    tmp_file=$(mktemp)
    while IFS= read -r line; do
        if [[ "$line" == vless://* && "$line" == *"path=%2Fvless-argo"* ]]; then
            line=$(printf '%s\n' "$line" | sed -E "s#^(vless://[^@]+@)[^?]+#\1${cfip}:${cfport}#")
        fi
        printf '%s\n' "$line"
    done < "$client_dir" > "$tmp_file" && mv "$tmp_file" "$client_dir"

    update_sub
    green "\nvless-ws-tls-argo节点优选域名已更新为：${purple}${cfip}:${cfport}${re}\n"
    grep 'path=%2Fvless-argo' "$client_dir" | while IFS= read -r line; do purple "$line\n"; done
}

# 从 endpoint 对象或 endpoints.json 中提取内置 WARP endpoint。
extract_warp_endpoint() {
    local source_file="$1"
    [ -s "$source_file" ] || return 1
    jq -c '
      if (.type? == "wireguard" and .tag? == "wireguard-out") then .
      elif ((.endpoints? | type) == "array") then
        first(.endpoints[]? | select(.type == "wireguard" and .tag == "wireguard-out"))
      else empty end
    ' "$source_file" 2>/dev/null
}

# 旧版公开脚本把同一份 WARP 身份写进所有 VPS。该 IPv6 地址只用于
# 识别并迁移那份旧配置，避免继续发生 WireGuard peer 漫游冲突。
warp_endpoint_is_legacy() {
    local endpoint_json="$1"
    jq -e '
      (.address // []) |
      index("2606:4700:110:8dfe:d141:69bb:6b80:925/128") != null
    ' >/dev/null 2>&1 <<< "$endpoint_json"
}

warp_endpoint_is_valid() {
    local endpoint_json="$1"
    jq -e '
      type == "object" and
      .type == "wireguard" and
      .tag == "wireguard-out" and
      ((.address | type) == "array" and (.address | length) > 0) and
      ((.private_key | type) == "string" and (.private_key | length) > 0) and
      ((.peers | type) == "array" and (.peers | length) > 0) and
      ((.peers[0].address | type) == "string" and (.peers[0].address | length) > 0) and
      ((.peers[0].port | type) == "number" and .peers[0].port > 0 and .peers[0].port <= 65535) and
      ((.peers[0].public_key | type) == "string" and (.peers[0].public_key | length) > 0) and
      ((.peers[0].allowed_ips | type) == "array" and (.peers[0].allowed_ips | length) > 0) and
      ((.peers[0].reserved | type) == "array" and (.peers[0].reserved | length) == 3) and
      ([.peers[0].reserved[] | type == "number" and . >= 0 and . <= 255] | all)
    ' >/dev/null 2>&1 <<< "$endpoint_json"
}

# 为当前 VPS 生成独立密钥并直接向 Cloudflare WARP API 注册。
# 私钥始终在本机生成；账户令牌和 endpoint 仅以 600 权限保存在本机。
generate_unique_warp_identity() {
    local state_dir="${1:-${conf_dir}/warp}"
    local register_dir response_file request_file endpoint_file account_file
    local singbox_bin keypair private_key public_key random_hex install_id fcm_token tos
    local http_code registered client_id reserved_bytes r1 r2 r3 extra
    local v4 v6 peer_key attempt

    command_exists curl || { red "生成独立 WARP 身份需要 curl。"; return 1; }
    command_exists jq || { red "生成独立 WARP 身份需要 jq。"; return 1; }
    command_exists base64 || { red "生成独立 WARP 身份需要 base64。"; return 1; }
    command_exists od || { red "生成独立 WARP 身份需要 od。"; return 1; }

    singbox_bin="${work_dir}/${server_name}"
    if [ ! -x "$singbox_bin" ]; then
        singbox_bin=$(command -v sing-box 2>/dev/null || true)
    fi
    [ -x "$singbox_bin" ] || { red "找不到 sing-box，无法生成 WARP 密钥。"; return 1; }

    mkdir -p "$state_dir" || return 1
    chmod 700 "$state_dir" 2>/dev/null || true
    register_dir=$(mktemp -d "${state_dir}/.register.XXXXXX") || return 1
    request_file="${register_dir}/request.json"
    response_file="${register_dir}/response.json"
    endpoint_file="${register_dir}/endpoint.json"
    account_file="${register_dir}/account.json"

    keypair=$("$singbox_bin" generate wg-keypair 2>/dev/null) || {
        rm -rf -- "$register_dir"
        red "生成 WARP WireGuard 密钥失败。"
        return 1
    }
    private_key=$(awk -F': ' '/PrivateKey/{print $2; exit}' <<< "$keypair")
    public_key=$(awk -F': ' '/PublicKey/{print $2; exit}' <<< "$keypair")
    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        rm -rf -- "$register_dir"
        red "无法解析 WARP WireGuard 密钥。"
        return 1
    fi

    random_hex=$(od -An -N96 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    if [ "${#random_hex}" -lt 160 ]; then
        rm -rf -- "$register_dir"
        red "无法生成 WARP 注册随机数。"
        return 1
    fi
    install_id="${random_hex:0:22}"
    fcm_token="${install_id}:APA91b${random_hex:22:134}"
    tos=$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')
    jq -n \
      --arg key "$public_key" \
      --arg install "$install_id" \
      --arg fcm "$fcm_token" \
      --arg tos "$tos" \
      '{key:$key,install_id:$install,fcm_token:$fcm,tos:$tos,model:"PC",serial_number:$install,locale:"en_US"}' \
      > "$request_file" || {
        rm -rf -- "$register_dir"
        return 1
      }
    chmod 600 "$request_file"

    registered=false
    for attempt in 1 2 3; do
        http_code=""
        if http_code=$(curl -sS --location --connect-timeout 10 --max-time 45 \
          -o "$response_file" -w '%{http_code}' \
          --request POST 'https://api.cloudflareclient.com/v0a2158/reg' \
          --header 'User-Agent: okhttp/3.12.1' \
          --header 'CF-Client-Version: a-6.10-2158' \
          --header 'Content-Type: application/json' \
          --data-binary "@${request_file}") && \
          [ "$http_code" = 200 ] && \
          jq -e '
            .id and .token and .config.client_id and
            .config.interface.addresses.v4 and .config.interface.addresses.v6 and
            .config.peers[0].public_key
          ' "$response_file" >/dev/null 2>&1; then
            registered=true
            break
        fi
        sleep $((attempt * 2))
    done
    if [ "$registered" != true ]; then
        rm -rf -- "$register_dir"
        red "Cloudflare WARP 注册失败，现有配置未修改。"
        return 1
    fi

    client_id=$(jq -r '.config.client_id' "$response_file")
    read -r r1 r2 r3 extra < <(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1)
    if [ -z "${r1:-}" ] || [ -z "${r2:-}" ] || [ -z "${r3:-}" ] || [ -n "${extra:-}" ]; then
        delete_warp_registration "$response_file" || true
        rm -rf -- "$register_dir"
        red "Cloudflare WARP client_id 无效，现有配置未修改。"
        return 1
    fi
    reserved_bytes=$(jq -n --argjson a "$r1" --argjson b "$r2" --argjson c "$r3" '[$a,$b,$c]')
    v4=$(jq -r '.config.interface.addresses.v4' "$response_file")
    v6=$(jq -r '.config.interface.addresses.v6' "$response_file")
    peer_key=$(jq -r '.config.peers[0].public_key' "$response_file")

    jq -n \
      --arg private "$private_key" \
      --arg v4 "$v4" \
      --arg v6 "$v6" \
      --arg peer "$peer_key" \
      --argjson reserved "$reserved_bytes" '
      {
        type:"wireguard", tag:"wireguard-out", mtu:1280,
        address:[
          (if ($v4 | contains("/")) then $v4 else ($v4 + "/32") end),
          (if ($v6 | contains("/")) then $v6 else ($v6 + "/128") end)
        ],
        private_key:$private,
        peers:[{
          address:"engage.cloudflareclient.com", port:2408,
          public_key:$peer, allowed_ips:["0.0.0.0/0","::/0"],
          persistent_keepalive_interval:25, reserved:$reserved
        }]
      }
      ' > "$endpoint_file" || {
        delete_warp_registration "$response_file" || true
        rm -rf -- "$register_dir"
        return 1
      }
    jq --arg private "$private_key" --argjson reserved "$reserved_bytes" \
      '. + {private_key:$private,reserved:$reserved}' "$response_file" > "$account_file" || {
        delete_warp_registration "$response_file" || true
        rm -rf -- "$register_dir"
        return 1
      }
    chmod 600 "$response_file" "$endpoint_file" "$account_file"

    local generated_endpoint
    generated_endpoint=$(extract_warp_endpoint "$endpoint_file")
    if ! warp_endpoint_is_valid "$generated_endpoint" || warp_endpoint_is_legacy "$generated_endpoint"; then
        delete_warp_registration "$response_file" || true
        rm -rf -- "$register_dir"
        red "生成的 WARP endpoint 校验失败，现有配置未修改。"
        return 1
    fi

    if command_exists install; then
        install -m 600 "$endpoint_file" "${state_dir}/endpoint.json" && \
        install -m 600 "$account_file" "${state_dir}/account.json"
    else
        cp "$endpoint_file" "${state_dir}/endpoint.json" && \
        cp "$account_file" "${state_dir}/account.json" && \
        chmod 600 "${state_dir}/endpoint.json" "${state_dir}/account.json"
    fi
    local install_status=$?
    [ "$install_status" -eq 0 ] || delete_warp_registration "$response_file" || true
    rm -rf -- "$register_dir"
    [ "$install_status" -eq 0 ] || return "$install_status"
    green "已为本机生成独立 WARP 身份。"
}

delete_warp_registration() {
    local account_file="$1" device_id device_token
    [ -s "$account_file" ] || return 0
    device_id=$(jq -r '.id // empty' "$account_file" 2>/dev/null)
    device_token=$(jq -r '.token // empty' "$account_file" 2>/dev/null)
    [ -n "$device_id" ] && [ -n "$device_token" ] || return 0
    curl -fsS --connect-timeout 5 --max-time 15 -X DELETE \
      "https://api.cloudflareclient.com/v0a2158/reg/${device_id}" \
      -H "Authorization: Bearer ${device_token}" \
      -H 'User-Agent: okhttp/3.12.1' >/dev/null 2>&1 || return 1
}

WARP_PROBE_PID=''
WARP_PROBE_DIR=''
WARP_PROBE_PROXY=''
WARP_PROBE_PORT=''

stop_warp_candidate_proxy() {
    local safe_dir=false attempt
    case "${WARP_PROBE_DIR:-}" in
      "${conf_dir}/warp/.probe."*) safe_dir=true ;;
    esac
    if [ "$safe_dir" = true ] && [ -n "${WARP_PROBE_PID:-}" ] && \
       [ -r "/proc/${WARP_PROBE_PID}/cmdline" ] && \
       tr '\0' ' ' < "/proc/${WARP_PROBE_PID}/cmdline" | grep -Fq "${WARP_PROBE_DIR}/config.json" && \
       kill -0 "$WARP_PROBE_PID" 2>/dev/null; then
        kill "$WARP_PROBE_PID" 2>/dev/null || true
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$WARP_PROBE_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$WARP_PROBE_PID" 2>/dev/null && kill -9 "$WARP_PROBE_PID" 2>/dev/null || true
        wait "$WARP_PROBE_PID" 2>/dev/null || true
    fi
    [ "$safe_dir" = true ] && rm -rf -- "$WARP_PROBE_DIR"
    unset WARP_PROBE_PID WARP_PROBE_DIR WARP_PROBE_PROXY WARP_PROBE_PORT
}

start_warp_candidate_proxy() {
    local endpoint_json="$1" singbox_bin port attempt
    warp_endpoint_is_valid "$endpoint_json" || return 1
    stop_warp_candidate_proxy
    mkdir -p "${conf_dir}/warp" && chmod 700 "${conf_dir}/warp"
    WARP_PROBE_DIR=$(mktemp -d "${conf_dir}/warp/.probe.XXXXXX") || return 1
    chmod 700 "$WARP_PROBE_DIR"
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        port=$((20000 + RANDOM % 30000))
        if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
            WARP_PROBE_PORT=$port
            break
        fi
    done
    [ -n "${WARP_PROBE_PORT:-}" ] || { stop_warp_candidate_proxy; return 1; }
    jq -n --argjson endpoint "$endpoint_json" --argjson port "$WARP_PROBE_PORT" '
      {
        log:{level:"error"},
        inbounds:[{type:"mixed",tag:"warp-probe",listen:"127.0.0.1",listen_port:$port}],
        endpoints:[$endpoint],
        route:{final:"wireguard-out"}
      }
    ' > "${WARP_PROBE_DIR}/config.json" || { stop_warp_candidate_proxy; return 1; }
    chmod 600 "${WARP_PROBE_DIR}/config.json"
    singbox_bin="${work_dir}/${server_name}"
    [ -x "$singbox_bin" ] || singbox_bin=$(command -v sing-box 2>/dev/null || true)
    [ -x "$singbox_bin" ] || { stop_warp_candidate_proxy; return 1; }
    "$singbox_bin" check -c "${WARP_PROBE_DIR}/config.json" >/dev/null 2>&1 || {
        stop_warp_candidate_proxy; return 1
    }
    "$singbox_bin" run -c "${WARP_PROBE_DIR}/config.json" \
      >"${WARP_PROBE_DIR}/sing-box.log" 2>&1 &
    WARP_PROBE_PID=$!
    local ready=false probe_proxy="socks5h://127.0.0.1:${WARP_PROBE_PORT}"
    for attempt in 1 2 3 4 5; do
        kill -0 "$WARP_PROBE_PID" 2>/dev/null || { stop_warp_candidate_proxy; return 1; }
        if command_exists ss; then
            ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "127\.0\.0\.1:${WARP_PROBE_PORT}$" && { ready=true; break; }
        elif command_exists lsof; then
            lsof -nP -a -p "$WARP_PROBE_PID" -iTCP:"$WARP_PROBE_PORT" -sTCP:LISTEN -t 2>/dev/null | \
              grep -qx "$WARP_PROBE_PID" && { ready=true; break; }
        else
            curl -fsS --connect-timeout 2 --max-time 4 --proxy "$probe_proxy" \
              https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^warp=' && { ready=true; break; }
        fi
        sleep 1
    done
    [ "$ready" = true ] || { stop_warp_candidate_proxy; return 1; }
    WARP_PROBE_PROXY="$probe_proxy"
}

probe_warp_trace() {
    local proxy="$1" trace
    trace=$(curl -fsS --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || return 1
    WARP_PROBE_IP=$(awk -F= '/^ip=/{print $2; exit}' <<< "$trace")
    WARP_PROBE_LOC=$(awk -F= '/^loc=/{print $2; exit}' <<< "$trace")
    WARP_PROBE_COLO=$(awk -F= '/^colo=/{print $2; exit}' <<< "$trace")
    WARP_PROBE_STATE=$(awk -F= '/^warp=/{print $2; exit}' <<< "$trace")
    [ -n "$WARP_PROBE_IP" ] && [[ "$WARP_PROBE_STATE" =~ ^(on|plus)$ ]]
}

check_unlock_netflix() {
    local proxy="$1" title body parsed_region region='' successful=0 playable=false
    for title in 81280792 70143836; do
        if body=$(curl -fsSL --connect-timeout 5 --max-time 12 --proxy "$proxy" \
          -A 'Mozilla/5.0' "https://www.netflix.com/title/${title}" 2>/dev/null); then
            successful=$((successful + 1))
            parsed_region=$(sed -n 's/.*"requestCountry"[^}]*"id"[ ]*:[ ]*"\([A-Za-z][A-Za-z]\)".*/\1/p' \
              <<< "$body" | head -1)
            [ -n "$region" ] || region="$parsed_region"
            grep -q 'og:video' <<< "$body" && playable=true
        fi
    done
    if [ "$successful" -eq 0 ] || [ -z "$region" ]; then
        WARP_UNLOCK_STATUS='检测失败'; return 2
    fi
    if [ "$playable" = true ]; then
        WARP_UNLOCK_STATUS="解锁 (${region^^})"; return 0
    fi
    WARP_UNLOCK_STATUS="仅自制剧 (${region^^})"; return 1
}

check_unlock_disney() {
    local proxy="$1" assertion token_content refresh_token graph_payload graph_result effective region supported
    assertion=$(curl -fsS --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -X POST https://disney.api.edge.bamgrid.com/devices \
      -H 'authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84' \
      -H 'content-type: application/json; charset=UTF-8' \
      -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>/dev/null || true)
    assertion=$(jq -r '.assertion // empty' <<< "$assertion" 2>/dev/null)
    [ -n "$assertion" ] || { WARP_UNLOCK_STATUS='检测失败'; return 2; }
    token_content=$(curl -fsS --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -X POST https://disney.api.edge.bamgrid.com/token \
      -H 'authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84' \
      -H 'content-type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
      --data-urlencode 'latitude=0' --data-urlencode 'longitude=0' --data-urlencode 'platform=browser' \
      --data-urlencode "subject_token=${assertion}" \
      --data-urlencode 'subject_token_type=urn:bamtech:params:oauth:token-type:device' 2>/dev/null || true)
    if grep -qiE 'forbidden-location|403 ERROR' <<< "$token_content"; then
        WARP_UNLOCK_STATUS='受限'; return 1
    fi
    refresh_token=$(jq -r '.refresh_token // empty' <<< "$token_content" 2>/dev/null)
    [ -n "$refresh_token" ] || { WARP_UNLOCK_STATUS='检测失败'; return 2; }
    graph_payload=$(jq -n --arg refresh "$refresh_token" \
      '{query:"mutation refreshToken($input: RefreshTokenInput!) { refreshToken(refreshToken: $input) { activeSession { sessionId } } }",variables:{input:{refreshToken:$refresh}}}')
    graph_result=$(curl -fsSL --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -X POST https://disney.api.edge.bamgrid.com/graph/v1/device/graphql \
      -H 'authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84' \
      -H 'content-type: application/json' -d "$graph_payload" 2>/dev/null || true)
    region=$(sed -n 's/.*"countryCode":[ ]*"\([^"]*\)".*/\1/p' <<< "$graph_result" | head -1)
    supported=$(sed -n 's/.*"inSupportedLocation":[ ]*\([^,}]*\).*/\1/p' <<< "$graph_result" | head -1)
    [ -n "$region" ] || { WARP_UNLOCK_STATUS='检测失败'; return 2; }
    effective=$(curl -fsSL -o /dev/null -w '%{url_effective}' --connect-timeout 5 --max-time 12 \
      --proxy "$proxy" -A 'Mozilla/5.0' https://www.disneyplus.com 2>/dev/null) || {
        WARP_UNLOCK_STATUS='检测失败'; return 2
    }
    if grep -qiE 'preview.*unavailable' <<< "$effective"; then
        WARP_UNLOCK_STATUS='受限'; return 1
    fi
    if [ "${region^^}" = JP ] || [ "$supported" = true ]; then
        WARP_UNLOCK_STATUS="解锁 (${region^^})"; return 0
    fi
    WARP_UNLOCK_STATUS="受限 (${region^^})"; return 1
}

check_unlock_chatgpt() {
    local proxy="$1" web_meta web_code web_url ios_file ios_meta ios_code restriction
    web_meta=$(curl -sSIL -L --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -o /dev/null -w $'%{http_code}\t%{url_effective}' \
      https://chatgpt.com 2>/dev/null) || {
        WARP_UNLOCK_STATUS='检测失败'; return 2
    }
    IFS=$'\t' read -r web_code web_url <<< "$web_meta"
    ios_file=$(mktemp) || { WARP_UNLOCK_STATUS='检测失败'; return 2; }
    if ! ios_meta=$(curl -sSL --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -o "$ios_file" -w '%{http_code}' \
      https://ios.chat.openai.com 2>/dev/null); then
        rm -f -- "$ios_file"; WARP_UNLOCK_STATUS='检测失败'; return 2
    fi
    ios_code="$ios_meta"
    restriction=$(cat "$ios_file" 2>/dev/null)
    rm -f -- "$ios_file"
    [ -n "$restriction" ] || { WARP_UNLOCK_STATUS='检测失败'; return 2; }
    if grep -qiE 'unsupported_country_region_territory|unsupported_country|blocked_why_headline|blocked_why|disallowed|request is not allowed' <<< "$restriction"; then
        WARP_UNLOCK_STATUS='受限'; return 1
    fi
    if grep -qE '\(1\)|\(2\)' <<< "$restriction"; then
        WARP_UNLOCK_STATUS='仅网页可用'; return 1
    fi
    [[ "$web_code" =~ ^2[0-9][0-9]$ ]] && \
      [[ "$web_url" =~ ^https://([^.]+\.)*chatgpt\.com(/|$) ]] && \
      [[ "$ios_code" =~ ^[234][0-9][0-9]$ ]] || {
        WARP_UNLOCK_STATUS='检测失败'; return 2
    }
    WARP_UNLOCK_STATUS='解锁'; return 0
}

check_unlock_gemini() {
    local proxy="$1" result meta code effective
    WARP_UNLOCK_STATUS='检测失败'
    result=$(mktemp) || return 2
    if ! meta=$(curl -sSL --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -H 'Accept-Language: en-US,en;q=0.9' -o "$result" \
      -w $'%{http_code}\t%{url_effective}' https://gemini.google.com/app 2>/dev/null); then
        rm -f -- "$result"; return 2
    fi
    IFS=$'\t' read -r code effective <<< "$meta"
    if grep -qiE 'not (currently )?available in your country|unsupported country|isn.t available' "$result"; then
        rm -f -- "$result"
        WARP_UNLOCK_STATUS='受限'; return 1
    fi
    if [ "$code" = 200 ] && [[ "$effective" =~ ^https://gemini\.google\.com(/|$) ]] && \
      grep -Fq '45631641,null,true' "$result"; then
        rm -f -- "$result"
        WARP_UNLOCK_STATUS='网络/地区可用'; return 0
    fi
    rm -f -- "$result"; return 2
}

run_selected_unlock_checks() {
    local proxy="$1" selection="$2" digit label rc overall=0
    WARP_UNLOCK_SUMMARY=''
    [[ "$selection" =~ ^[1-4]+$ ]] || return 1
    for digit in 1 2 3 4; do
        [[ "$selection" == *"$digit"* ]] || continue
        case "$digit" in
          1) label='Netflix'; check_unlock_netflix "$proxy" || rc=$? ;;
          2) label='Disney+'; check_unlock_disney "$proxy" || rc=$? ;;
          3) label='ChatGPT'; check_unlock_chatgpt "$proxy" || rc=$? ;;
          4) label='Gemini'; check_unlock_gemini "$proxy" || rc=$? ;;
        esac
        rc=${rc:-0}
        WARP_UNLOCK_SUMMARY+="${label}: ${WARP_UNLOCK_STATUS}"$'\n'
        [ "$rc" -eq 0 ] || overall=1
        unset rc
    done
    [ "$overall" -eq 0 ]
}

write_warp_status_cache() {
    local selection="${1:-}" summary="${2:-}" cache="${conf_dir}/warp/status.json"
    mkdir -p "${conf_dir}/warp" && chmod 700 "${conf_dir}/warp"
    jq -n --argjson checked "$(date +%s)" --arg ip "${WARP_PROBE_IP:-}" \
      --arg loc "${WARP_PROBE_LOC:-}" --arg colo "${WARP_PROBE_COLO:-}" \
      --arg warp "${WARP_PROBE_STATE:-}" --arg selection "$selection" --arg summary "$summary" \
      '{checked_at:$checked,ip:$ip,loc:$loc,colo:$colo,warp:$warp,selection:$selection,summary:$summary}' \
      > "${cache}.tmp" && chmod 600 "${cache}.tmp" && mv -f "${cache}.tmp" "$cache"
}

probe_active_warp() {
    local endpoint
    endpoint=$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)
    warp_endpoint_is_valid "$endpoint" || return 1
    start_warp_candidate_proxy "$endpoint" || return 1
    probe_warp_trace "$WARP_PROBE_PROXY"
    local rc=$?
    stop_warp_candidate_proxy
    return "$rc"
}

activate_warp_candidate() {
    local candidate_dir="$1" state_dir="${conf_dir}/warp" endpoint_file="${conf_dir}/endpoints.json"
    local expected_ip="${2:-}" strict_selection="${3:-}" endpoint_json backup_dir endpoint_tmp
    endpoint_json=$(extract_warp_endpoint "${candidate_dir}/endpoint.json" 2>/dev/null || true)
    warp_endpoint_is_valid "$endpoint_json" || return 1
    backup_dir=$(mktemp -d "${conf_dir}/.warp-activate.XXXXXX") || return 1
    chmod 700 "$backup_dir"
    cp -p "$endpoint_file" "$backup_dir/endpoints.json" || { rm -rf -- "$backup_dir"; return 1; }
    if [ -s "$state_dir/account.json" ]; then
        cp -p "$state_dir/account.json" "$backup_dir/account.json" || { rm -rf -- "$backup_dir"; return 1; }
        : > "$backup_dir/had-account"
    fi
    if [ -s "$state_dir/endpoint.json" ]; then
        cp -p "$state_dir/endpoint.json" "$backup_dir/endpoint.json" || { rm -rf -- "$backup_dir"; return 1; }
        : > "$backup_dir/had-endpoint"
    fi
    endpoint_tmp=$(mktemp "${conf_dir}/.endpoints.activate.XXXXXX") || { rm -rf -- "$backup_dir"; return 1; }
    if ! jq --argjson endpoint "$endpoint_json" '.endpoints=([.endpoints[]?|select(.tag!="wireguard-out")]+[$endpoint])' \
      "$endpoint_file" > "$endpoint_tmp" || ! install -m 600 "${candidate_dir}/account.json" "$state_dir/account.json" || \
      ! install -m 600 "${candidate_dir}/endpoint.json" "$state_dir/endpoint.json" || ! chmod 600 "$endpoint_tmp" || \
      ! mv -f "$endpoint_tmp" "$endpoint_file" || ! validate_singbox_config || ! restart_singbox_checked || \
      ! singbox_service_is_active || \
      ! verify_activated_warp "$expected_ip" "$strict_selection"; then
        local rollback_ok=true
        rm -f -- "$endpoint_tmp"
        install -m 600 "$backup_dir/endpoints.json" "$endpoint_file" || rollback_ok=false
        if [ -e "$backup_dir/had-account" ]; then install -m 600 "$backup_dir/account.json" "$state_dir/account.json" || rollback_ok=false; else rm -f -- "$state_dir/account.json" || rollback_ok=false; fi
        if [ -e "$backup_dir/had-endpoint" ]; then install -m 600 "$backup_dir/endpoint.json" "$state_dir/endpoint.json" || rollback_ok=false; else rm -f -- "$state_dir/endpoint.json" || rollback_ok=false; fi
        restart_singbox_checked >/dev/null 2>&1 || rollback_ok=false
        singbox_service_is_active || rollback_ok=false
        if [ "$rollback_ok" = true ]; then
            rm -rf -- "$backup_dir"
            return 1
        fi
        WARP_KEEP_FAILED_CANDIDATE=true
        red "严重错误：旧 WARP 配置恢复不完整，已停止后续操作。"
        red "保留恢复目录: ${backup_dir}"
        return 2
    fi
    write_warp_status_cache
    if [ -e "$backup_dir/had-account" ]; then
        delete_warp_registration "$backup_dir/account.json" || yellow "旧 WARP 云端设备未能自动清理，可稍后重试。"
    fi
    rm -rf -- "$backup_dir"
}

verify_activated_warp() {
    local expected_ip="${1:-}" selection="${2:-}" endpoint
    probe_active_warp || return 1
    [ -z "$expected_ip" ] || [ "$WARP_PROBE_IP" = "$expected_ip" ] || return 1
    [ -z "$selection" ] && return 0
    endpoint=$(extract_warp_endpoint "${conf_dir}/endpoints.json")
    start_warp_candidate_proxy "$endpoint" || return 1
    local rc
    if run_selected_unlock_checks "$WARP_PROBE_PROXY" "$selection"; then rc=0; else rc=$?; fi
    stop_warp_candidate_proxy
    return "$rc"
}

singbox_service_is_active() {
    local attempt pid_before pid_after
    if command_exists systemctl; then
        for attempt in 1 2 3 4; do
            if systemctl is-active --quiet sing-box; then
                pid_before=$(systemctl show -p MainPID --value sing-box 2>/dev/null)
                sleep 1
                pid_after=$(systemctl show -p MainPID --value sing-box 2>/dev/null)
                [ -n "$pid_before" ] && [ "$pid_before" != 0 ] && [ "$pid_before" = "$pid_after" ] && \
                  systemctl is-active --quiet sing-box && return 0
            else
                sleep 1
            fi
        done
        return 1
    elif command_exists rc-service; then
        for attempt in 1 2 3 4; do
            rc-service sing-box status >/dev/null 2>&1 && { sleep 1; rc-service sing-box status >/dev/null 2>&1 && return 0; }
            sleep 1
        done
        return 1
    else
        return 1
    fi
}

stop_singbox_checked() {
    if command_exists rc-service; then
        rc-service sing-box stop
    elif command_exists systemctl; then
        systemctl stop sing-box
    else
        return 1
    fi
}

rotate_warp_identity_once() {
    local old_ip candidate_dir candidate_endpoint new_ip activate_rc
    warp_endpoint_is_valid "$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)" || {
        red "内置 WARP 尚未初始化，请先设置一条 WARP 分流规则。"; return 1
    }
    probe_active_warp && old_ip="$WARP_PROBE_IP" || old_ip=''
    candidate_dir=$(mktemp -d "${conf_dir}/warp/.candidate.XXXXXX") || return 1
    chmod 700 "$candidate_dir"
    if ! generate_unique_warp_identity "$candidate_dir"; then rm -rf -- "$candidate_dir"; return 1; fi
    candidate_endpoint=$(extract_warp_endpoint "$candidate_dir/endpoint.json")
    if ! start_warp_candidate_proxy "$candidate_endpoint" || ! probe_warp_trace "$WARP_PROBE_PROXY"; then
        stop_warp_candidate_proxy; delete_warp_registration "$candidate_dir/account.json" || true
        rm -rf -- "$candidate_dir"; return 1
    fi
    new_ip="$WARP_PROBE_IP"; stop_warp_candidate_proxy
    WARP_KEEP_FAILED_CANDIDATE=false
    activate_warp_candidate "$candidate_dir" "$new_ip"
    activate_rc=$?
    if [ "$activate_rc" -eq 0 ]; then
        rm -rf -- "$candidate_dir"
        green "WARP 身份已更换：${old_ip:-未知} -> ${new_ip}"
        [ "$old_ip" = "$new_ip" ] && yellow "Cloudflare 分配的公网出口 IP 未变化。"
        return 0
    fi
    if [ "$activate_rc" -eq 2 ]; then
        red "候选凭据保留在: ${candidate_dir}"
        return 2
    fi
    delete_warp_registration "$candidate_dir/account.json" || true
    rm -rf -- "$candidate_dir"; return 1
}

auto_select_warp_candidate() {
    local selection="${1:-1234}" active_ip candidate_dir candidate_endpoint attempt candidate_ip activate_rc
    local WARP_MAX_CANDIDATES=5
    warp_endpoint_is_valid "$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)" || {
        red "内置 WARP 尚未初始化，请先设置一条 WARP 分流规则。"; return 1
    }
    probe_active_warp && active_ip="$WARP_PROBE_IP" || { red "无法取得当前 WARP 出口 IP，已停止优选。"; return 1; }
    for ((attempt=1; attempt<=WARP_MAX_CANDIDATES; attempt++)); do
        WARP_KEEP_FAILED_CANDIDATE=false
        yellow "正在测试候选 ${attempt}/${WARP_MAX_CANDIDATES}..."
        candidate_dir=$(mktemp -d "${conf_dir}/warp/.candidate.XXXXXX") || return 1
        chmod 700 "$candidate_dir"
        if generate_unique_warp_identity "$candidate_dir"; then
            candidate_endpoint=$(extract_warp_endpoint "$candidate_dir/endpoint.json")
            if start_warp_candidate_proxy "$candidate_endpoint" && probe_warp_trace "$WARP_PROBE_PROXY"; then
                if [ -n "$active_ip" ] && [ "$WARP_PROBE_IP" = "$active_ip" ]; then
                    yellow "候选出口仍为 ${WARP_PROBE_IP}，继续。"
                elif run_selected_unlock_checks "$WARP_PROBE_PROXY" "$selection"; then
                    printf '%s' "$WARP_UNLOCK_SUMMARY"
                    candidate_ip="$WARP_PROBE_IP"
                    stop_warp_candidate_proxy
                    activate_warp_candidate "$candidate_dir" "$candidate_ip" "$selection"
                    activate_rc=$?
                    if [ "$activate_rc" -eq 0 ]; then
                        rm -rf -- "$candidate_dir"; green "已启用新的 WARP 出口 ${candidate_ip}"; return 0
                    fi
                    if [ "$activate_rc" -eq 2 ]; then
                        red "候选凭据保留在: ${candidate_dir}"
                        red "因回滚不完整，自动优选已立即停止。"
                        return 2
                    fi
                else
                    printf '%s' "$WARP_UNLOCK_SUMMARY"
                fi
            fi
            stop_warp_candidate_proxy
            delete_warp_registration "$candidate_dir/account.json" || yellow "候选云端设备清理失败。"
        fi
        rm -rf -- "$candidate_dir"
        [ "$attempt" -lt "$WARP_MAX_CANDIDATES" ] && sleep $((attempt * 2))
    done
    red "未找到满足条件的新出口，原 WARP 身份保持不变。"
    return 1
}

show_warp_status_and_unlocks() {
    local account_file="${conf_dir}/warp/account.json" selection="${1:-1234}"
    warp_endpoint_is_valid "$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)" || {
        yellow "内置 WARP 尚未初始化。"; return 1
    }
    if ! probe_active_warp; then red "内置 WARP 运行探测失败。"; return 1; fi
    start_warp_candidate_proxy "$(extract_warp_endpoint "${conf_dir}/endpoints.json")" || return 1
    run_selected_unlock_checks "$WARP_PROBE_PROXY" "$selection" || true
    stop_warp_candidate_proxy
    write_warp_status_cache "$selection" "$WARP_UNLOCK_SUMMARY"
    green "设备 ID: $(jq -r '.id // "unknown"' "$account_file" 2>/dev/null)"
    green "出口 IP: ${WARP_PROBE_IP}  地区: ${WARP_PROBE_LOC:-未知}  机房: ${WARP_PROBE_COLO:-未知}"
    green "WARP: ${WARP_PROBE_STATE}"
    printf '%s' "$WARP_UNLOCK_SUMMARY"
}

get_warp_menu_status() {
    local endpoint cache="${conf_dir}/warp/status.json" now checked warp
    endpoint=$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)
    warp_endpoint_is_valid "$endpoint" || { echo 'not configured'; return; }
    now=$(date +%s); checked=$(jq -r '.checked_at // 0' "$cache" 2>/dev/null || echo 0)
    warp=$(jq -r '.warp // empty' "$cache" 2>/dev/null || true)
    if [ $((now - checked)) -gt 300 ]; then
        if probe_active_warp; then write_warp_status_cache; warp="$WARP_PROBE_STATE"; else warp='failed'; fi
    fi
    [[ "$warp" =~ ^(on|plus)$ ]] && echo running || echo degraded
}

# 输出 sing-box 内置 WARP endpoint。它只供 sing-box 出站使用，
# 不创建系统网卡，也不会修改宿主机默认路由。
warp_endpoint_json() {
    local current_endpoint state_endpoint endpoint_file state_file
    endpoint_file="${conf_dir}/endpoints.json"
    state_file="${conf_dir}/warp/endpoint.json"

    current_endpoint=$(extract_warp_endpoint "$endpoint_file" 2>/dev/null || true)
    if [ -n "$current_endpoint" ] && \
       warp_endpoint_is_valid "$current_endpoint" && \
       ! warp_endpoint_is_legacy "$current_endpoint"; then
        jq -c '.peers = [.peers[] | .persistent_keepalive_interval = 25]' <<< "$current_endpoint"
        return
    fi

    state_endpoint=$(extract_warp_endpoint "$state_file" 2>/dev/null || true)
    if [ -z "$state_endpoint" ] || \
       ! warp_endpoint_is_valid "$state_endpoint" || \
       warp_endpoint_is_legacy "$state_endpoint"; then
        yellow "正在为本机注册独立 WARP 身份..."
        generate_unique_warp_identity || return 1
        state_endpoint=$(extract_warp_endpoint "$state_file" 2>/dev/null || true)
    fi

    warp_endpoint_is_valid "$state_endpoint" || return 1
    warp_endpoint_is_legacy "$state_endpoint" && return 1
    jq -c '.peers = [.peers[] | .persistent_keepalive_interval = 25]' <<< "$state_endpoint"
}

warp_rule_sets_json() {
    cat <<'EOF'
[
  {"tag":"gemini","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/gemini.srs","download_detour":"direct"},
  {"tag":"claude","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/claude.srs","download_detour":"direct"},
  {"tag":"openai","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs","download_detour":"direct"},
  {"tag":"tiktok","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/tiktok.srs","download_detour":"direct"},
  {"tag":"twitter","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/twitter.srs","download_detour":"direct"},
  {"tag":"google","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs","download_detour":"direct"},
  {"tag":"telegram","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs","download_detour":"direct"},
  {"tag":"youtube","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs","download_detour":"direct"},
  {"tag":"netflix","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs","download_detour":"direct"},
  {"tag":"streaming","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/proxymedia.srs","download_detour":"direct"}
]
EOF
}

restore_warp_file_backups() {
    local backup_dir="$1"
    shift
    local target_file target_name

    for target_file in "$@"; do
        target_name=$(basename "$target_file")
        if [ -e "${backup_dir}/had-${target_name}" ]; then
            cp -p "${backup_dir}/${target_name}" "$target_file" 2>/dev/null || \
                cp "${backup_dir}/${target_name}" "$target_file" || true
        else
            rm -f -- "$target_file"
        fi
    done
}

# 补齐 direct、WARP endpoint 与分流规则集。三份配置作为一个整体校验，
# 任一候选文件无效时同时回滚，避免留下“菜单成功、endpoint 缺失”的半配置。
ensure_warp_prerequisites() {
    local endpoint_file="${conf_dir}/endpoints.json"
    local current_route_file="${conf_dir}/route.json"
    local current_outbound_file="${conf_dir}/outbounds.json"
    local endpoint_tmp route_tmp outbound_tmp backup_dir
    local warp_endpoint required_rule_sets target_file target_name
    local -a target_files

    command_exists jq || { red "WARP 分流需要 jq。"; return 1; }
    mkdir -p "$conf_dir" || return 1

    warp_endpoint=$(warp_endpoint_json) || return 1
    required_rule_sets=$(warp_rule_sets_json) || return 1
    jq -e . >/dev/null 2>&1 <<< "$warp_endpoint" || return 1
    jq -e . >/dev/null 2>&1 <<< "$required_rule_sets" || return 1

    endpoint_tmp=$(mktemp "${conf_dir}/.tmp.endpoints.XXXXXX") || return 1
    route_tmp=$(mktemp "${conf_dir}/.tmp.route.XXXXXX") || { rm -f "$endpoint_tmp"; return 1; }
    outbound_tmp=$(mktemp "${conf_dir}/.tmp.outbounds.XXXXXX") || { rm -f "$endpoint_tmp" "$route_tmp"; return 1; }
    backup_dir=$(mktemp -d "${conf_dir}/.warp-backup.XXXXXX") || {
        rm -f "$endpoint_tmp" "$route_tmp" "$outbound_tmp"
        return 1
    }

    target_files=("$endpoint_file" "$current_route_file" "$current_outbound_file")
    for target_file in "${target_files[@]}"; do
        target_name=$(basename "$target_file")
        if [ -e "$target_file" ]; then
            cp -p "$target_file" "${backup_dir}/${target_name}" 2>/dev/null || \
                cp "$target_file" "${backup_dir}/${target_name}" || {
                    rm -f "$endpoint_tmp" "$route_tmp" "$outbound_tmp"
                    rm -rf -- "$backup_dir"
                    return 1
                }
            : > "${backup_dir}/had-${target_name}"
        fi
    done

    if [ -s "$endpoint_file" ] && jq empty "$endpoint_file" >/dev/null 2>&1; then
        jq --argjson warp "$warp_endpoint" '
          .endpoints = ([.endpoints[]? | select(.tag != "wireguard-out")] + [$warp])
        ' "$endpoint_file" > "$endpoint_tmp"
    else
        jq -n --argjson warp "$warp_endpoint" '{endpoints: [$warp]}' > "$endpoint_tmp"
    fi || {
        restore_warp_file_backups "$backup_dir" "${target_files[@]}"
        rm -f "$endpoint_tmp" "$route_tmp" "$outbound_tmp"
        rm -rf -- "$backup_dir"
        return 1
    }

    if [ -s "$current_route_file" ] && jq empty "$current_route_file" >/dev/null 2>&1; then
        jq --argjson required "$required_rule_sets" '
          .route = (if (.route | type) == "object" then .route else {} end) |
          (.route.rule_set // []) as $current |
          .route.rule_set = ([
            ($current | if type == "array" then .[] else empty end) |
            select(.tag as $tag | ($required | map(.tag) | index($tag) | not))
          ] + $required) |
          .route.rules = (if (.route.rules | type) == "array" then .route.rules else [] end) |
          .route.final = (if (.route.final | type) == "string" and (.route.final | length) > 0 then .route.final else "direct" end)
        ' "$current_route_file" > "$route_tmp"
    else
        jq -n --argjson required "$required_rule_sets" \
           '{route: {rule_set: $required, rules: [], final: "direct"}}' > "$route_tmp"
    fi || {
        restore_warp_file_backups "$backup_dir" "${target_files[@]}"
        rm -f "$endpoint_tmp" "$route_tmp" "$outbound_tmp"
        rm -rf -- "$backup_dir"
        return 1
    }

    if [ -s "$current_outbound_file" ] && jq empty "$current_outbound_file" >/dev/null 2>&1; then
        jq '
          .outbounds = ([{"type":"direct","tag":"direct"}] + [
            .outbounds[]? | select(.tag != "direct")
          ])
        ' "$current_outbound_file" > "$outbound_tmp"
    else
        jq -n '{outbounds: [{type:"direct",tag:"direct"}]}' > "$outbound_tmp"
    fi || {
        restore_warp_file_backups "$backup_dir" "${target_files[@]}"
        rm -f "$endpoint_tmp" "$route_tmp" "$outbound_tmp"
        rm -rf -- "$backup_dir"
        return 1
    }

    if ! jq empty "$endpoint_tmp" >/dev/null 2>&1 || \
       ! jq empty "$route_tmp" >/dev/null 2>&1 || \
       ! jq empty "$outbound_tmp" >/dev/null 2>&1 || \
       ! mv -f "$endpoint_tmp" "$endpoint_file" || \
       ! mv -f "$route_tmp" "$current_route_file" || \
       ! mv -f "$outbound_tmp" "$current_outbound_file"; then
        restore_warp_file_backups "$backup_dir" "${target_files[@]}"
        rm -f "$endpoint_tmp" "$route_tmp" "$outbound_tmp"
        rm -rf -- "$backup_dir"
        red "WARP 前置配置生成失败，已回滚。"
        return 1
    fi

    chmod 600 "$endpoint_file" 2>/dev/null || true
    chmod 644 "$current_route_file" "$current_outbound_file" 2>/dev/null || true
    if ! validate_singbox_config; then
        restore_warp_file_backups "$backup_dir" "${target_files[@]}"
        rm -rf -- "$backup_dir"
        red "WARP 前置配置校验失败，已回滚。"
        return 1
    fi

    rm -rf -- "$backup_dir"
}

restart_singbox_checked() {
    yellow "正在重启 sing-box 服务\n"
    if command_exists rc-service; then
        rc-service sing-box restart
    elif command_exists systemctl; then
        systemctl daemon-reload && systemctl restart sing-box
    else
        red "找不到可用的服务管理器，sing-box 未重启。"
        return 1
    fi
    local restart_status=$?
    if [ "$restart_status" -eq 0 ]; then
        green "sing-box 服务已成功重启\n"
        return 0
    fi
    red "sing-box 服务重启失败\n"
    return "$restart_status"
}

singbox_check_config_dir() {
    local staged_conf_dir="${1:-}"
    local checker="${SINGBOX_CHECK_BIN:-${work_dir}/${server_name}}"

    [ -d "$staged_conf_dir" ] || return 1
    if [[ "$checker" != */* ]]; then
        checker=$(command -v "$checker" 2>/dev/null) || return 1
    fi
    [ -x "$checker" ] || return 1
    "$checker" check -C "$staged_conf_dir" >/dev/null 2>&1
}

singbox_service_is_active() {
    if command_exists rc-service; then
        rc-service sing-box status >/dev/null 2>&1
    elif command_exists systemctl; then
        systemctl is-active --quiet sing-box
    else
        return 1
    fi
}

atomic_replace_config_file() {
    local staged_file="${1:-}"
    local target_file="${2:-}"

    [ -f "$staged_file" ] && [ -n "$target_file" ] || return 1
    mv -f -- "$staged_file" "$target_file"
}

proxy_transaction_reaper_hook() {
    :
}

reap_stale_proxy_transaction_lock() {
    local lock_path="${1:-}"
    local reaper_path owner='' status=1 guard_acquired=0 guard_stale=0
    local stale_seconds="${PROXY_TX_REAPER_STALE_SECONDS:-5}"
    local main_stale_seconds="${PROXY_TX_LOCK_STALE_SECONDS:-5}"
    local now='' reaper_mtime='' lock_mtime='' tombstone_path='' entry=''
    local main_stale=0
    local attempt=0

    [ -d "$lock_path" ] && [ ! -L "$lock_path" ] || return 1
    [[ "$stale_seconds" =~ ^[1-9][0-9]*$ ]] || return 2
    [[ "$main_stale_seconds" =~ ^[1-9][0-9]*$ ]] || return 2
    reaper_path="${lock_path}.reaper"

    while [ "$attempt" -lt 4 ]; do
        attempt=$((attempt + 1))
        if (umask 077 && mkdir -- "$reaper_path" 2>/dev/null); then
            if ! chmod 700 "$reaper_path"; then
                rmdir -- "$reaper_path" 2>/dev/null || return 2
                return 2
            fi
            proxy_transaction_reaper_hook guard-created
            if ! printf '%s\n' "$BASHPID" > "$reaper_path/owner" ||
               ! chmod 600 "$reaper_path/owner"; then
                rm -f -- "$reaper_path/owner" 2>/dev/null || true
                rmdir -- "$reaper_path" 2>/dev/null || return 2
                return 2
            fi
            guard_acquired=1
            proxy_transaction_reaper_hook acquired
            break
        fi

        # A competing reaper may have removed its guard between mkdir(2) and
        # this inspection.  Retry that harmless race, but fail closed for a
        # non-directory or symlink at the guard path.
        if [ ! -e "$reaper_path" ] && [ ! -L "$reaper_path" ]; then
            continue
        fi
        [ -d "$reaper_path" ] && [ ! -L "$reaper_path" ] || return 2

        guard_stale=0
        owner=''
        if [ -e "$reaper_path/owner" ] || [ -L "$reaper_path/owner" ]; then
            [ -f "$reaper_path/owner" ] && [ ! -L "$reaper_path/owner" ] &&
                [ -r "$reaper_path/owner" ] || return 2
            owner=$(cat "$reaper_path/owner" 2>/dev/null || true)
            if [[ "$owner" =~ ^[1-9][0-9]*$ ]]; then
                kill -0 "$owner" 2>/dev/null && return 1
                guard_stale=1
            fi
        fi

        # Missing or partially written owner metadata is an initialization
        # window, not proof of a dead owner.  Reclaim it only after a short
        # grace period so a slow creator cannot have its live guard stolen.
        if [ "$guard_stale" -eq 0 ]; then
            now=$(date +%s 2>/dev/null) || return 2
            reaper_mtime=$(stat -c '%Y' -- "$reaper_path" 2>/dev/null) || return 2
            [[ "$now" =~ ^[0-9]+$ && "$reaper_mtime" =~ ^[0-9]+$ ]] || return 2
            [ "$now" -ge "$reaper_mtime" ] || return 1
            [ "$((now - reaper_mtime))" -ge "$stale_seconds" ] || return 1
            guard_stale=1
        fi

        # The guard owns only one metadata file.  Unknown contents indicate
        # damage or interference and must never be recursively deleted.
        for entry in "$reaper_path"/* "$reaper_path"/.[!.]* "$reaper_path"/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            [ "$entry" = "$reaper_path/owner" ] || return 2
        done

        # Rename is the ownership hand-off: only the process that atomically
        # moves the stale guard may clean it.  A fresh guard created at the
        # original path can therefore never be removed by an older reaper.
        tombstone_path="${reaper_path}.stale.${BASHPID}.${RANDOM}.${attempt}"
        [ ! -e "$tombstone_path" ] && [ ! -L "$tombstone_path" ] || return 2
        if mv -- "$reaper_path" "$tombstone_path" 2>/dev/null; then
            rm -f -- "$tombstone_path/owner" 2>/dev/null || return 2
            rmdir -- "$tombstone_path" 2>/dev/null || return 2
            continue
        fi
    done
    [ "$guard_acquired" -eq 1 ] || return 1

    # Re-read only after winning the independent guard.  Another reaper may
    # have removed the stale lock and a new live owner may already have
    # acquired the main path while we were waiting.
    main_stale=0
    owner=''
    if [ ! -e "$lock_path" ] && [ ! -L "$lock_path" ]; then
        status=0
    elif [ ! -d "$lock_path" ] || [ -L "$lock_path" ]; then
        status=2
    else
        if [ -e "$lock_path/owner" ] || [ -L "$lock_path/owner" ]; then
            if [ ! -f "$lock_path/owner" ] || [ -L "$lock_path/owner" ] ||
               [ ! -r "$lock_path/owner" ]; then
                status=2
            else
                owner=$(cat "$lock_path/owner" 2>/dev/null || true)
                if [[ "$owner" =~ ^[1-9][0-9]*$ ]]; then
                    if kill -0 "$owner" 2>/dev/null; then
                        main_stale=-1
                    else
                        main_stale=1
                    fi
                fi
            fi
        fi

        # As with the reaper guard, a missing or partially written main owner
        # is initially treated as live initialization.  It becomes reapable
        # only after the bounded grace period.
        if [ "$status" -ne 2 ] && [ "$main_stale" -eq 0 ]; then
            now=$(date +%s 2>/dev/null) || status=2
            if [ "$status" -ne 2 ]; then
                lock_mtime=$(stat -c '%Y' -- "$lock_path" 2>/dev/null) || status=2
            fi
            if [ "$status" -ne 2 ]; then
                if ! [[ "$now" =~ ^[0-9]+$ && "$lock_mtime" =~ ^[0-9]+$ ]]; then
                    status=2
                elif [ "$now" -ge "$lock_mtime" ] &&
                     [ "$((now - lock_mtime))" -ge "$main_stale_seconds" ]; then
                    main_stale=1
                fi
            fi
        fi

        if [ "$status" -ne 2 ] && [ "$main_stale" -eq 1 ]; then
            for entry in "$lock_path"/* "$lock_path"/.[!.]* "$lock_path"/..?*; do
                [ -e "$entry" ] || [ -L "$entry" ] || continue
                if [ "$entry" != "$lock_path/owner" ]; then
                    status=2
                    break
                fi
            done
            if [ "$status" -ne 2 ]; then
                if rm -f -- "$lock_path/owner" && rmdir -- "$lock_path"; then
                    status=0
                    proxy_transaction_reaper_hook after-delete
                else
                    status=2
                fi
            fi
        fi
    fi
    if ! rm -f -- "$reaper_path/owner" || ! rmdir -- "$reaper_path"; then
        return 2
    fi
    return "$status"
}

acquire_proxy_transaction_lock() {
    local transaction_conf_dir="${1:-}"
    local timeout_seconds="${PROXY_TX_LOCK_TIMEOUT_SECONDS:-30}"
    local lock_owner='' started_at reaper_status=0

    [ -d "$transaction_conf_dir" ] && [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
    PROXY_TX_LOCK_KIND=''
    PROXY_TX_LOCK_PATH=''
    PROXY_TX_LOCK_FD=''

    if command_exists flock; then
        PROXY_TX_LOCK_PATH="${transaction_conf_dir}/.proxy-transaction.lock"
        (
            umask 077
            : >> "$PROXY_TX_LOCK_PATH"
        ) || return 1
        chmod 600 "$PROXY_TX_LOCK_PATH" || return 1
        exec {PROXY_TX_LOCK_FD}>"$PROXY_TX_LOCK_PATH" || return 1
        if ! flock -w "$timeout_seconds" "$PROXY_TX_LOCK_FD"; then
            exec {PROXY_TX_LOCK_FD}>&-
            PROXY_TX_LOCK_FD=''
            return 1
        fi
        PROXY_TX_LOCK_KIND='flock'
        if declare -F assert_no_pending_durable_transaction >/dev/null 2>&1; then
            assert_no_pending_durable_transaction "$transaction_conf_dir"
            lock_owner=$?
            if [ "$lock_owner" -ne 0 ]; then
                release_proxy_transaction_lock
                return "$lock_owner"
            fi
        fi
        return 0
    fi

    PROXY_TX_LOCK_PATH="${transaction_conf_dir}/.proxy-transaction.lock.d"
    started_at=$SECONDS
    while :; do
        if (umask 077 && mkdir -- "$PROXY_TX_LOCK_PATH" 2>/dev/null); then
            chmod 700 "$PROXY_TX_LOCK_PATH" || {
                rmdir -- "$PROXY_TX_LOCK_PATH" 2>/dev/null || true
                return 1
            }
            if declare -F proxy_transaction_reaper_hook >/dev/null 2>&1; then
                proxy_transaction_reaper_hook main-lock-created
            fi
            printf '%s\n' "$BASHPID" > "$PROXY_TX_LOCK_PATH/owner" || {
                rm -f -- "$PROXY_TX_LOCK_PATH/owner"
                rmdir -- "$PROXY_TX_LOCK_PATH" 2>/dev/null || true
                return 1
            }
            chmod 600 "$PROXY_TX_LOCK_PATH/owner" || {
                rm -f -- "$PROXY_TX_LOCK_PATH/owner"
                rmdir -- "$PROXY_TX_LOCK_PATH" 2>/dev/null || true
                return 1
            }
            PROXY_TX_LOCK_KIND='mkdir'
            if declare -F assert_no_pending_durable_transaction >/dev/null 2>&1; then
                assert_no_pending_durable_transaction "$transaction_conf_dir"
                lock_owner=$?
                if [ "$lock_owner" -ne 0 ]; then
                    release_proxy_transaction_lock
                    return "$lock_owner"
                fi
            fi
            return 0
        fi

        reaper_status=0
        reap_stale_proxy_transaction_lock "$PROXY_TX_LOCK_PATH" || reaper_status=$?
        case "$reaper_status" in
            0) continue ;;
            1) ;;
            *) return 2 ;;
        esac
        [ "$((SECONDS - started_at))" -lt "$timeout_seconds" ] || return 1
        sleep 0.1
    done
}

acquire_proxy_transaction_lock_checked() {
    local transaction_conf_dir="${1:-}"
    local operation_name="${2:-配置事务}"
    local lock_status

    acquire_proxy_transaction_lock "$transaction_conf_dir"
    lock_status=$?
    case "$lock_status" in
        0)
            return 0
            ;;
        1)
            red "另一个配置事务仍在运行，${operation_name}已安全中止。"
            return 1
            ;;
        2)
            red "检测到未决或损坏的事务恢复材料，${operation_name}已停止；请先按上方路径完成恢复。"
            return 2
            ;;
        *)
            red "无法安全确认配置事务锁状态，${operation_name}已停止。"
            return 2
            ;;
    esac
}

release_proxy_transaction_lock() {
    case "${PROXY_TX_LOCK_KIND:-}" in
        flock)
            flock -u "$PROXY_TX_LOCK_FD" 2>/dev/null || true
            exec {PROXY_TX_LOCK_FD}>&-
            ;;
        mkdir)
            if [ -d "${PROXY_TX_LOCK_PATH:-}" ] && [ ! -L "$PROXY_TX_LOCK_PATH" ]; then
                rm -f -- "$PROXY_TX_LOCK_PATH/owner" 2>/dev/null || true
                rmdir -- "$PROXY_TX_LOCK_PATH" 2>/dev/null || true
            fi
            ;;
    esac
    PROXY_TX_LOCK_KIND=''
    PROXY_TX_LOCK_PATH=''
    PROXY_TX_LOCK_FD=''
}

# Durable evidence for public-port, subscription and extra-protocol
# transactions.  The common config lock must already be held when this is
# armed.  Callers only mark a stage rollback-safe after the firewall helper
# has returned, so a signal can never re-enter the firewall lock.
durable_transaction_hook() {
    :
}

assert_no_pending_durable_transaction() {
    local registry_dir="${1:-}"
    local registry_file pending_path extra_line

    [ -d "$registry_dir" ] && [ ! -L "$registry_dir" ] || return 2
    registry_file="${registry_dir}/.durable-transaction.pending"
    DURABLE_TX_PENDING_PATH=''
    [ -e "$registry_file" ] || [ -L "$registry_file" ] || return 0
    DURABLE_TX_PENDING_PATH="$registry_file"
    [ -f "$registry_file" ] && [ ! -L "$registry_file" ] && [ -r "$registry_file" ] || {
        red "发现不可信的未决事务登记文件，已拒绝新的配置事务：${registry_file}"
        return 2
    }
    IFS= read -r pending_path < "$registry_file" || pending_path=''
    IFS= read -r extra_line < <(sed -n '2p' "$registry_file") || extra_line=''
    if [ -z "$pending_path" ] || [ -n "$extra_line" ] || \
       [ ! -d "$pending_path" ] || [ -L "$pending_path" ] || \
       [ ! -f "$pending_path/manifest" ] || [ -L "$pending_path/manifest" ] || \
       [ ! -r "$pending_path/manifest" ]; then
        red "未决事务登记已损坏，已拒绝新的配置事务：${registry_file}"
        return 2
    fi
    DURABLE_TX_PENDING_PATH="$pending_path"
    red "发现上次未完成的配置事务，恢复前不会继续修改：${pending_path}"
    return 2
}

write_durable_transaction_registry() {
    local registry_dir="${1:-}"
    local recovery_dir="${2:-}"
    local registry_file tmp_registry

    [ -d "$registry_dir" ] && [ ! -L "$registry_dir" ] || return 1
    [ -d "$recovery_dir" ] && [ ! -L "$recovery_dir" ] || return 1
    [[ "$recovery_dir" != *$'\n'* && "$recovery_dir" != *$'\r'* ]] || return 1
    registry_file="${registry_dir}/.durable-transaction.pending"
    [ ! -e "$registry_file" ] && [ ! -L "$registry_file" ] || return 1
    tmp_registry=$(mktemp "${registry_dir}/.durable-pending.XXXXXX") || return 1
    if ! printf '%s\n' "$recovery_dir" > "$tmp_registry" || \
       ! chmod 600 "$tmp_registry" || \
       ! ln -- "$tmp_registry" "$registry_file"; then
        rm -f -- "$tmp_registry"
        return 1
    fi
    rm -f -- "$tmp_registry" || {
        rm -f -- "$registry_file"
        return 1
    }
    DURABLE_TX_REGISTRY="$registry_file"
}

cleanup_durable_transaction_registry() {
    local registry_file="${DURABLE_TX_REGISTRY:-}"
    local recovery_dir="${DURABLE_TX_RECOVERY_DIR:-}"
    local registered_path

    [ -n "$registry_file" ] && [ -f "$registry_file" ] && [ ! -L "$registry_file" ] || return 1
    IFS= read -r registered_path < "$registry_file" || return 1
    [ "$registered_path" = "$recovery_dir" ] || return 1
    rm -f -- "$registry_file"
}

reset_durable_transaction_state() {
    DURABLE_TX_ACTIVE=0
    DURABLE_TX_HANDLING=0
    DURABLE_TX_KIND=''
    DURABLE_TX_STAGE=''
    DURABLE_TX_RECOVERY_DIR=''
    DURABLE_TX_MANIFEST=''
    DURABLE_TX_REGISTRY=''
    DURABLE_TX_BACKUP_PATH=''
    DURABLE_TX_RECOVERY_VAR=''
    DURABLE_TX_ROLLBACK_CALLBACK=''
    DURABLE_TX_SERVICE_WAS_ACTIVE=''
    DURABLE_TX_OLD_PORT=''
    DURABLE_TX_NEW_PORT=''
    DURABLE_TX_PREVIOUS_HUP_TRAP=''
    DURABLE_TX_PREVIOUS_INT_TRAP=''
    DURABLE_TX_PREVIOUS_TERM_TRAP=''
    DURABLE_TX_PREVIOUS_EXIT_TRAP=''
    DURABLE_TX_ROLLBACK_ARGS=()
    DURABLE_TX_OWNED_RECORDS=()
}

write_durable_transaction_manifest() {
    local tmp_manifest record value

    [ "${DURABLE_TX_ACTIVE:-0}" -eq 1 ] && \
        [ -d "${DURABLE_TX_RECOVERY_DIR:-}" ] && \
        [ ! -L "${DURABLE_TX_RECOVERY_DIR:-}" ] || return 1
    for value in \
        "${DURABLE_TX_KIND:-}" "${DURABLE_TX_STAGE:-}" \
        "${DURABLE_TX_BACKUP_PATH:-}" "${DURABLE_TX_SERVICE_WAS_ACTIVE:-}" \
        "${DURABLE_TX_OLD_PORT:-}" "${DURABLE_TX_NEW_PORT:-}"; do
        [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    done
    tmp_manifest=$(mktemp "${DURABLE_TX_RECOVERY_DIR}/.manifest.XXXXXX") || return 1
    if ! {
        printf 'kind=%s\n' "$DURABLE_TX_KIND"
        printf 'stage=%s\n' "$DURABLE_TX_STAGE"
        printf 'backup_path=%s\n' "$DURABLE_TX_BACKUP_PATH"
        printf 'service_was_active=%s\n' "$DURABLE_TX_SERVICE_WAS_ACTIVE"
        printf 'old_port=%s\n' "$DURABLE_TX_OLD_PORT"
        printf 'new_port=%s\n' "$DURABLE_TX_NEW_PORT"
        for record in "${DURABLE_TX_OWNED_RECORDS[@]}"; do
            [[ "$record" != *$'\n'* && "$record" != *$'\r'* ]] || return 1
            printf 'owned_record=%s\n' "$record"
        done
    } > "$tmp_manifest"; then
        rm -f -- "$tmp_manifest"
        return 1
    fi
    chmod 600 "$tmp_manifest" || { rm -f -- "$tmp_manifest"; return 1; }
    mv -f -- "$tmp_manifest" "$DURABLE_TX_MANIFEST"
}

restore_durable_transaction_traps() {
    trap - HUP INT TERM EXIT
    [ -z "${DURABLE_TX_PREVIOUS_HUP_TRAP:-}" ] || eval "$DURABLE_TX_PREVIOUS_HUP_TRAP"
    [ -z "${DURABLE_TX_PREVIOUS_INT_TRAP:-}" ] || eval "$DURABLE_TX_PREVIOUS_INT_TRAP"
    [ -z "${DURABLE_TX_PREVIOUS_TERM_TRAP:-}" ] || eval "$DURABLE_TX_PREVIOUS_TERM_TRAP"
    [ -z "${DURABLE_TX_PREVIOUS_EXIT_TRAP:-}" ] || eval "$DURABLE_TX_PREVIOUS_EXIT_TRAP"
}

arm_durable_transaction() {
    local kind="${1:-}"
    local evidence_parent="${2:-}"
    local backup_path="${3:-}"
    local recovery_var="${4:-}"
    local rollback_callback="${5:-}"
    local service_was_active="${6:-}"
    local old_port="${7:-}"
    local new_port="${8:-}"
    shift 8 || return 1

    [ "${DURABLE_TX_ACTIVE:-0}" -eq 0 ] || return 1
    [ -n "$kind" ] && [[ "$kind" != *$'\n'* && "$kind" != *$'\r'* ]] || return 1
    [ -d "$evidence_parent" ] && [ ! -L "$evidence_parent" ] || return 1
    [ -n "$backup_path" ] && [[ "$backup_path" != *$'\n'* && "$backup_path" != *$'\r'* ]] || return 1
    [[ "$recovery_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    declare -F "$rollback_callback" >/dev/null 2>&1 || return 1
    case "$service_was_active" in 0|1) ;; *) return 1 ;; esac

    DURABLE_TX_RECOVERY_DIR=$(mktemp -d "${evidence_parent}/.durable-transaction.XXXXXX") || return 1
    chmod 700 "$DURABLE_TX_RECOVERY_DIR" || {
        rm -rf -- "$DURABLE_TX_RECOVERY_DIR"
        DURABLE_TX_RECOVERY_DIR=''
        return 1
    }
    DURABLE_TX_MANIFEST="${DURABLE_TX_RECOVERY_DIR}/manifest"
    DURABLE_TX_REGISTRY=''
    DURABLE_TX_ACTIVE=1
    DURABLE_TX_HANDLING=0
    DURABLE_TX_KIND="$kind"
    DURABLE_TX_STAGE='precommit'
    DURABLE_TX_BACKUP_PATH="$backup_path"
    DURABLE_TX_RECOVERY_VAR="$recovery_var"
    DURABLE_TX_ROLLBACK_CALLBACK="$rollback_callback"
    DURABLE_TX_SERVICE_WAS_ACTIVE="$service_was_active"
    DURABLE_TX_OLD_PORT="$old_port"
    DURABLE_TX_NEW_PORT="$new_port"
    DURABLE_TX_ROLLBACK_ARGS=("$@")
    DURABLE_TX_OWNED_RECORDS=()
    if ! write_durable_transaction_registry \
        "${DURABLE_TX_REGISTRY_DIR:-${conf_dir:-$evidence_parent}}" \
        "$DURABLE_TX_RECOVERY_DIR" || \
       ! write_durable_transaction_manifest; then
        [ -z "${DURABLE_TX_REGISTRY:-}" ] || rm -f -- "$DURABLE_TX_REGISTRY"
        rm -rf -- "$DURABLE_TX_RECOVERY_DIR"
        reset_durable_transaction_state
        return 1
    fi

    DURABLE_TX_PREVIOUS_HUP_TRAP=$(trap -p HUP || true)
    DURABLE_TX_PREVIOUS_INT_TRAP=$(trap -p INT || true)
    DURABLE_TX_PREVIOUS_TERM_TRAP=$(trap -p TERM || true)
    DURABLE_TX_PREVIOUS_EXIT_TRAP=$(trap -p EXIT || true)
    trap 'durable_transaction_trap_handler HUP 129' HUP
    trap 'durable_transaction_trap_handler INT 130' INT
    trap 'durable_transaction_trap_handler TERM 143' TERM
    trap 'durable_transaction_trap_handler EXIT $?' EXIT
}

durable_transaction_checkpoint() {
    local stage="${1:-}"

    [ "${DURABLE_TX_ACTIVE:-0}" -eq 1 ] || return 1
    case "$stage" in
        precommit|firewall-mutating|config-mutated|publishing|committed|unknown) ;;
        *) return 1 ;;
    esac
    DURABLE_TX_STAGE="$stage"
    write_durable_transaction_manifest || return 1
    durable_transaction_hook "$stage"
}

durable_transaction_set_owned_records() {
    [ "${DURABLE_TX_ACTIVE:-0}" -eq 1 ] || return 1
    DURABLE_TX_OWNED_RECORDS=("$@")
    write_durable_transaction_manifest
}

disarm_durable_transaction() {
    local disposition="${1:-cleanup}"
    local recovery_dir="${DURABLE_TX_RECOVERY_DIR:-}"
    local recovery_var="${DURABLE_TX_RECOVERY_VAR:-}"
    local cleanup_status=0

    [ "${DURABLE_TX_ACTIVE:-0}" -eq 1 ] || return 0
    trap - HUP INT TERM EXIT
    restore_durable_transaction_traps
    case "$disposition" in
        cleanup)
            if ! cleanup_durable_transaction_registry; then
                printf -v "$recovery_var" '%s' "$recovery_dir"
                cleanup_status=1
            elif [ -n "$recovery_dir" ] && ! rm -rf -- "$recovery_dir"; then
                printf -v "$recovery_var" '%s' "$recovery_dir"
                cleanup_status=1
            fi
            ;;
        keep)
            printf -v "$recovery_var" '%s' "$recovery_dir"
            ;;
        *) cleanup_status=1 ;;
    esac
    reset_durable_transaction_state
    return "$cleanup_status"
}

durable_transaction_trap_handler() {
    local event="${1:-EXIT}"
    local original_status="${2:-1}"
    local final_status="$original_status"
    local preserve=0 rollback_status=0 recovery_dir recovery_var
    local rollback_callback
    local -a rollback_args=()

    trap - HUP INT TERM EXIT
    [ "${DURABLE_TX_ACTIVE:-0}" -eq 1 ] || exit "$original_status"
    [ "${DURABLE_TX_HANDLING:-0}" -eq 0 ] || exit 2
    DURABLE_TX_HANDLING=1
    recovery_dir="$DURABLE_TX_RECOVERY_DIR"
    recovery_var="$DURABLE_TX_RECOVERY_VAR"
    rollback_callback="$DURABLE_TX_ROLLBACK_CALLBACK"
    rollback_args=("${DURABLE_TX_ROLLBACK_ARGS[@]}")

    case "${DURABLE_TX_STAGE:-unknown}" in
        precommit|config-mutated)
            "$rollback_callback" "${rollback_args[@]}" || rollback_status=1
            if [ "$rollback_status" -eq 0 ]; then
                if ! cleanup_durable_transaction_registry || ! rm -rf -- "$recovery_dir"; then
                    preserve=1
                    final_status=2
                fi
            else
                preserve=1
                final_status=2
            fi
            ;;
        committed)
            preserve=1
            final_status=3
            ;;
        firewall-mutating|publishing|unknown|*)
            preserve=1
            final_status=2
            ;;
    esac
    if [ "$preserve" -eq 1 ]; then
        printf -v "$recovery_var" '%s' "$recovery_dir"
        write_durable_transaction_manifest >/dev/null 2>&1 || true
        red "事务被 ${event} 中断，已保留恢复证据：${recovery_dir}"
    fi
    if declare -F stop_warp_candidate_proxy >/dev/null 2>&1; then
        stop_warp_candidate_proxy >/dev/null 2>&1 || true
    fi
    release_proxy_transaction_lock
    restore_durable_transaction_traps
    reset_durable_transaction_state
    exit "$final_status"
}

proxy_transaction_hook() {
    :
}

reset_proxy_transaction_state() {
    PROXY_TX_STAGE='locked'
    PROXY_TX_STAGE_DIR=''
    PROXY_TX_ROUTE_BACKUP=''
    PROXY_TX_OUTBOUND_BACKUP=''
    PROXY_TX_CURRENT_ROUTE_FILE=''
    PROXY_TX_CURRENT_OUTBOUND_FILE=''
    PROXY_TX_INITIAL_SERVICE_ACTIVE=1
}

cleanup_proxy_transaction_artifacts() {
    local backup_name backup_path preserved_path

    if [ -n "${PROXY_TX_STAGE_DIR:-}" ] && [ -d "$PROXY_TX_STAGE_DIR" ]; then
        for backup_name in ROUTE OUTBOUND; do
            eval "backup_path=\${PROXY_TX_${backup_name}_BACKUP:-}"
            [ -n "$backup_path" ] && [ -f "$backup_path" ] || continue
            case "$backup_path" in
                "${PROXY_TX_STAGE_DIR}/"*) continue ;;
            esac
            preserved_path="${PROXY_TX_STAGE_DIR}/$(basename "$backup_path")"
            mv -f -- "$backup_path" "$preserved_path" || return 1
            printf -v "PROXY_TX_${backup_name}_BACKUP" '%s' "$preserved_path"
        done
        rm -rf -- "$PROXY_TX_STAGE_DIR" || return 1
        return 0
    fi

    [ -z "${PROXY_TX_ROUTE_BACKUP:-}" ] || rm -f -- "$PROXY_TX_ROUTE_BACKUP" || return 1
    [ -z "${PROXY_TX_OUTBOUND_BACKUP:-}" ] || rm -f -- "$PROXY_TX_OUTBOUND_BACKUP" || return 1
}

restore_proxy_transaction_traps() {
    trap - INT TERM EXIT
    [ -z "${PROXY_TX_PREVIOUS_INT_TRAP:-}" ] || eval "$PROXY_TX_PREVIOUS_INT_TRAP"
    [ -z "${PROXY_TX_PREVIOUS_TERM_TRAP:-}" ] || eval "$PROXY_TX_PREVIOUS_TERM_TRAP"
    [ -z "${PROXY_TX_PREVIOUS_EXIT_TRAP:-}" ] || eval "$PROXY_TX_PREVIOUS_EXIT_TRAP"
}

proxy_transaction_trap_handler() {
    local event="${1:-EXIT}"
    local original_status="${2:-1}"
    local final_status="$original_status"

    trap - INT TERM EXIT
    case "${PROXY_TX_STAGE:-}" in
        commit-in-progress|route-committed|outbounds-committed|restarting)
            if restore_proxy_config_transaction \
                "${PROXY_TX_ROUTE_BACKUP:-}" "${PROXY_TX_OUTBOUND_BACKUP:-}" \
                "${PROXY_TX_CURRENT_ROUTE_FILE:-}" "${PROXY_TX_CURRENT_OUTBOUND_FILE:-}"; then
                if ! cleanup_proxy_transaction_artifacts; then
                    final_status=2
                    report_proxy_transaction_fatal
                fi
            else
                final_status=2
                report_proxy_transaction_fatal
            fi
            ;;
        *)
            if ! cleanup_proxy_transaction_artifacts; then
                final_status=2
                report_proxy_transaction_fatal
            fi
            ;;
    esac
    release_proxy_transaction_lock
    reset_proxy_transaction_state
    restore_proxy_transaction_traps
    [ "$event" = EXIT ] || red "代理配置事务被 ${event} 中断。"
    exit "$final_status"
}

install_proxy_transaction_traps() {
    PROXY_TX_PREVIOUS_INT_TRAP=$(trap -p INT || true)
    PROXY_TX_PREVIOUS_TERM_TRAP=$(trap -p TERM || true)
    PROXY_TX_PREVIOUS_EXIT_TRAP=$(trap -p EXIT || true)
    trap 'proxy_transaction_trap_handler INT 130' INT
    trap 'proxy_transaction_trap_handler TERM 143' TERM
    trap 'proxy_transaction_trap_handler EXIT $?' EXIT
}

restore_proxy_config_transaction() {
    local route_backup="${1:-}"
    local outbound_backup="${2:-}"
    local current_route_file="${3:-}"
    local current_outbound_file="${4:-}"
    local restore_status=0

    [ -f "$route_backup" ] && [ -f "$outbound_backup" ] && \
        [ -n "$current_route_file" ] && [ -n "$current_outbound_file" ] || return 1
    restore_proxy_config_file "$route_backup" "$current_route_file" || restore_status=1
    restore_proxy_config_file "$outbound_backup" "$current_outbound_file" || restore_status=1
    [ "$restore_status" -eq 0 ] || return 1
    cmp -s -- "$route_backup" "$current_route_file" || return 1
    cmp -s -- "$outbound_backup" "$current_outbound_file" || return 1
    if [ "${PROXY_TX_INITIAL_SERVICE_ACTIVE:-1}" = 1 ]; then
        restart_singbox_checked >/dev/null 2>&1 || return 1
        singbox_service_is_active || return 1
    else
        if singbox_service_is_active; then
            stop_singbox_checked >/dev/null 2>&1 || return 1
        fi
        ! singbox_service_is_active
    fi
}

restore_proxy_config_file() {
    local backup_file="${1:-}"
    local target_file="${2:-}"
    local target_dir target_name restore_candidate

    [ -f "$backup_file" ] && [ -n "$target_file" ] || return 1
    target_dir=$(dirname "$target_file") || return 1
    target_name=$(basename "$target_file") || return 1
    restore_candidate=$(mktemp "${target_dir}/.restore.${target_name}.XXXXXX") || return 1
    if ! cp -p -- "$backup_file" "$restore_candidate" ||
       ! mv -f -- "$restore_candidate" "$target_file"; then
        rm -f -- "$restore_candidate"
        return 1
    fi
    cmp -s -- "$backup_file" "$target_file"
}

report_proxy_transaction_fatal() {
    red "代理配置事务收尾或回滚不完整，事务以 fatal 状态退出。"
    red "stage: ${PROXY_TX_STAGE_DIR:-未知}"
    red "route backup: ${PROXY_TX_ROUTE_BACKUP:-未知}"
    red "outbounds backup: ${PROXY_TX_OUTBOUND_BACKUP:-未知}"
}

rollback_proxy_config_transaction() {
    if restore_proxy_config_transaction \
        "${PROXY_TX_ROUTE_BACKUP:-}" "${PROXY_TX_OUTBOUND_BACKUP:-}" \
        "${PROXY_TX_CURRENT_ROUTE_FILE:-}" "${PROXY_TX_CURRENT_OUTBOUND_FILE:-}"; then
        if cleanup_proxy_transaction_artifacts; then
            return 0
        fi
        report_proxy_transaction_fatal
        return 2
    fi
    report_proxy_transaction_fatal
    return 2
}

apply_proxy_config_transaction() {
    local current_route_file="${route_file:-${conf_dir}/route.json}"
    local current_outbound_file="${outbound_file:-${conf_dir}/outbounds.json}"
    local transaction_conf_dir transaction_status

    transaction_conf_dir=$(dirname "$current_route_file") || return 1
    [ "$(dirname "$current_outbound_file")" = "$transaction_conf_dir" ] || return 1
    acquire_proxy_transaction_lock_checked "$transaction_conf_dir" "代理配置事务"
    transaction_status=$?
    [ "$transaction_status" -eq 0 ] || return "$transaction_status"
    reset_proxy_transaction_state
    PROXY_TX_CURRENT_ROUTE_FILE="$current_route_file"
    PROXY_TX_CURRENT_OUTBOUND_FILE="$current_outbound_file"
    install_proxy_transaction_traps
    if singbox_service_is_active; then
        PROXY_TX_INITIAL_SERVICE_ACTIVE=1
    else
        PROXY_TX_INITIAL_SERVICE_ACTIVE=0
    fi
    _apply_proxy_config_transaction_locked "$@"
    transaction_status=$?
    trap - INT TERM EXIT
    restore_proxy_transaction_traps
    release_proxy_transaction_lock
    reset_proxy_transaction_state
    return "$transaction_status"
}

_apply_proxy_config_transaction_locked() {
    local route_filter="${1:-}"
    local outbound_filter="${2:-}"
    shift 2 || return 1
    local current_route_file="${route_file:-${conf_dir}/route.json}"
    local current_outbound_file="${outbound_file:-${conf_dir}/outbounds.json}"
    local transaction_conf_dir conf_parent conf_name stage_dir
    local staged_route_tmp staged_outbound_tmp route_mode outbound_mode
    local route_backup='' outbound_backup='' backup_candidate

    [ -n "$route_filter" ] && [ -n "$outbound_filter" ] || return 1
    transaction_conf_dir=$(dirname "$current_route_file") || return 1
    [ "$(dirname "$current_outbound_file")" = "$transaction_conf_dir" ] || return 1
    [ -s "$current_route_file" ] && [ -s "$current_outbound_file" ] || return 1
    jq empty "$current_route_file" >/dev/null 2>&1 || return 1
    jq empty "$current_outbound_file" >/dev/null 2>&1 || return 1

    conf_parent=$(dirname "$transaction_conf_dir") || return 1
    conf_name=$(basename "$transaction_conf_dir") || return 1
    stage_dir=$(mktemp -d "${conf_parent}/.${conf_name}.proxy-stage.XXXXXX") || return 1
    PROXY_TX_STAGE_DIR="$stage_dir"
    PROXY_TX_STAGE='staging'
    if ! cp -a -- "${transaction_conf_dir}/." "$stage_dir/"; then
        cleanup_proxy_transaction_artifacts || { report_proxy_transaction_fatal; return 2; }
        return 1
    fi

    staged_route_tmp=$(mktemp "${stage_dir}/.tmp.route.XXXXXX") || {
        cleanup_proxy_transaction_artifacts || { report_proxy_transaction_fatal; return 2; }
        return 1
    }
    staged_outbound_tmp=$(mktemp "${stage_dir}/.tmp.outbounds.XXXXXX") || {
        rm -f -- "$staged_route_tmp"
        cleanup_proxy_transaction_artifacts || { report_proxy_transaction_fatal; return 2; }
        return 1
    }
    route_mode=$(stat -c '%a' "$current_route_file" 2>/dev/null || printf '%s' 600)
    outbound_mode=$(stat -c '%a' "$current_outbound_file" 2>/dev/null || printf '%s' 600)

    if ! jq "$@" "$route_filter" "$current_route_file" > "$staged_route_tmp" 2>/dev/null ||
       ! jq "$@" "$outbound_filter" "$current_outbound_file" > "$staged_outbound_tmp" 2>/dev/null ||
       ! jq empty "$staged_route_tmp" >/dev/null 2>&1 ||
       ! jq empty "$staged_outbound_tmp" >/dev/null 2>&1 ||
       ! chmod "$route_mode" "$staged_route_tmp" ||
       ! chmod "$outbound_mode" "$staged_outbound_tmp" ||
       ! mv -f -- "$staged_route_tmp" "$stage_dir/$(basename "$current_route_file")" ||
       ! mv -f -- "$staged_outbound_tmp" "$stage_dir/$(basename "$current_outbound_file")" ||
       ! singbox_check_config_dir "$stage_dir"; then
        cleanup_proxy_transaction_artifacts || { report_proxy_transaction_fatal; return 2; }
        red "sing-box 代理配置检查失败，生产配置未改变。"
        return 1
    fi

    backup_candidate=$(mktemp "${transaction_conf_dir}/.bak.route.XXXXXX") || {
        cleanup_proxy_transaction_artifacts || { report_proxy_transaction_fatal; return 2; }
        return 1
    }
    if ! cp -p -- "$current_route_file" "$backup_candidate"; then
        rm -f -- "$backup_candidate"
        cleanup_proxy_transaction_artifacts || { report_proxy_transaction_fatal; return 2; }
        return 1
    fi
    route_backup="$backup_candidate"
    PROXY_TX_ROUTE_BACKUP="$route_backup"

    backup_candidate=$(mktemp "${transaction_conf_dir}/.bak.outbounds.XXXXXX") || {
        cleanup_proxy_transaction_artifacts || { report_proxy_transaction_fatal; return 2; }
        return 1
    }
    if ! cp -p -- "$current_outbound_file" "$backup_candidate"; then
        rm -f -- "$backup_candidate"
        cleanup_proxy_transaction_artifacts || { report_proxy_transaction_fatal; return 2; }
        return 1
    fi
    outbound_backup="$backup_candidate"
    PROXY_TX_OUTBOUND_BACKUP="$outbound_backup"
    PROXY_TX_STAGE='backups-ready'

    PROXY_TX_STAGE='commit-in-progress'
    if ! atomic_replace_config_file "$stage_dir/$(basename "$current_route_file")" "$current_route_file"; then
        if rollback_proxy_config_transaction; then
            red "代理配置提交失败，已恢复 route.json 与 outbounds.json。"
            return 1
        fi
        return 2
    fi
    PROXY_TX_STAGE='route-committed'
    proxy_transaction_hook after-route-commit
    if ! atomic_replace_config_file "$stage_dir/$(basename "$current_outbound_file")" "$current_outbound_file"; then
        if rollback_proxy_config_transaction; then
            red "代理配置提交失败，已恢复 route.json 与 outbounds.json。"
            return 1
        fi
        return 2
    fi
    PROXY_TX_STAGE='outbounds-committed'

    PROXY_TX_STAGE='restarting'
    if ! restart_singbox_checked || ! singbox_service_is_active; then
        if rollback_proxy_config_transaction; then
            red "sing-box 服务未能恢复 active，已回滚代理与路由配置。"
            return 1
        fi
        return 2
    fi

    if ! cleanup_proxy_transaction_artifacts; then
        report_proxy_transaction_fatal
        return 2
    fi
    PROXY_TX_STAGE='complete'
}

mutate_proxy_transaction() {
    local tag="${1:-}"
    local replacement="${2:-direct}"

    [ -n "$tag" ] && [ -n "$replacement" ] || return 1
    [ "$tag" != direct ] && [ "$tag" != wireguard-out ] && [ "$tag" != "$replacement" ] || return 1

    apply_proxy_config_transaction '
      if .route.final? == $tag then .route.final = $replacement else . end |
      if ((.route.rules? | type) == "array") then
        .route.rules = [
          .route.rules[] |
          if .outbound? == $tag then
            if $replacement == "direct" then empty else .outbound = $replacement end
          else . end
        ]
      else . end
    ' '
      if ([.outbounds[]? | select(.tag == $tag)] | length) == 1 and
         ([.outbounds[]? | select(.tag == $replacement)] | length) == 1 then
        .outbounds = [.outbounds[]? | select(.tag != $tag)]
      else
        error("proxy mutation validation failed")
      end
    ' --arg tag "$tag" --arg replacement "$replacement"
}

add_proxy_outbound_transaction() {
    local outbound_json="${1:-}"
    local switch_existing_rules="${2:-false}"
    local tag

    case "$switch_existing_rules" in true|false) ;; *) return 1 ;; esac
    tag=$(jq -er 'select(type == "object") | .tag | select(type == "string" and length > 0)' \
        <<< "$outbound_json") || return 1

    apply_proxy_config_transaction '
      if $switch then
        .route.rules = [
          .route.rules[]? |
          if ((.rule_set? | type) == "array") then
            .action = "route" | .outbound = $tag
          else . end
        ]
      else . end
    ' '
      if any(.outbounds[]?; .tag == $tag) then
        error("proxy outbound tag already exists")
      else
        .outbounds += [$outbound]
      end
    ' --arg tag "$tag" --argjson outbound "$outbound_json" --argjson switch "$switch_existing_rules"
}

# 对 route.json 做单文件事务：生成、全配置校验、重启；失败时恢复并重启旧配置。
apply_warp_route_update() {
    local jq_filter="$1"
    shift
    local current_route_file="${route_file:-${conf_dir}/route.json}"
    local route_tmp route_backup

    [ -s "$current_route_file" ] && jq empty "$current_route_file" >/dev/null 2>&1 || return 1
    route_tmp=$(mktemp "${conf_dir}/.tmp.route.XXXXXX") || return 1
    route_backup=$(mktemp "${conf_dir}/.bak.route.XXXXXX") || { rm -f "$route_tmp"; return 1; }
    cp -p "$current_route_file" "$route_backup" 2>/dev/null || cp "$current_route_file" "$route_backup" || {
        rm -f "$route_tmp" "$route_backup"
        return 1
    }

    if ! jq "$@" "$jq_filter" "$current_route_file" > "$route_tmp" || \
       ! jq empty "$route_tmp" >/dev/null 2>&1 || \
       ! mv -f "$route_tmp" "$current_route_file" || \
       ! validate_singbox_config; then
        mv -f "$route_backup" "$current_route_file" >/dev/null 2>&1 || true
        rm -f "$route_tmp"
        red "sing-box 路由配置校验失败，已回滚。"
        return 1
    fi

    if ! restart_singbox_checked; then
        mv -f "$route_backup" "$current_route_file" >/dev/null 2>&1 || true
        restart_singbox_checked >/dev/null 2>&1 || true
        red "sing-box 重启失败，已恢复原路由配置。"
        return 1
    fi

    rm -f "$route_backup"
}

add_service_route() {
    local rule_tag="$1"
    local selected_out="$2"
    local ipv6_direct_fallback="${3:-false}"

    apply_warp_route_update '
      def managed_sniff:
        (.action? == "sniff" and .port? == [80, 443] and (keys | length) == 2);
      .route.rules = [
        .route.rules[]? |
        if ((.rule_set? | type) == "array") then .rule_set -= [$tag] else . end |
        select(((.rule_set? | type) != "array") or ((.rule_set | length) > 0)) |
        select(managed_sniff | not)
      ] |
      .route.rules = [{"port":[80,443],"action":"sniff"}] + .route.rules |
      if ($fallback and $out == "wireguard-out") then
        .route.rules += [
          {"rule_set":[$tag],"ip_version":6,"action":"route","outbound":"direct"},
          {"rule_set":[$tag],"action":"route","outbound":$out}
        ]
      else
        .route.rules += [{"rule_set":[$tag],"action":"route","outbound":$out}]
      end
    ' --arg tag "$rule_tag" --arg out "$selected_out" --argjson fallback "$ipv6_direct_fallback"
}

delete_service_route() {
    local rule_tag="$1"
    apply_warp_route_update '
      .route.rules = [
        .route.rules[]? |
        if ((.rule_set? | type) == "array") then .rule_set -= [$tag] else . end |
        select(((.rule_set? | type) != "array") or ((.rule_set | length) > 0))
      ]
    ' --arg tag "$rule_tag"
}

set_global_route() {
    local selected_out="$1"
    apply_warp_route_update '.route.rules = [] | .route.final = $out' --arg out "$selected_out"
}

restore_direct_route() {
    apply_warp_route_update '.route.rules = [] | .route.final = "direct"'
}

native_ipv6_available() {
    local native_ipv6
    native_ipv6=$(get_public_ipv6 2>/dev/null || true)
    [ -n "$native_ipv6" ]
}

# WARP 分流管理
warp_manage() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
    fi

    clear
    route_file="${conf_dir}/route.json"
    outbound_file="${conf_dir}/outbounds.json"

    echo ""
    green "=== WARP 分流管理 ===\n"
    local current_warp_endpoint
    current_warp_endpoint=$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)
    if [ -n "$current_warp_endpoint" ] && \
       warp_endpoint_is_valid "$current_warp_endpoint" && \
       ! warp_endpoint_is_legacy "$current_warp_endpoint"; then
        green "内置 WARP 出站: ready（本机独立身份，不修改系统默认路由）"
    elif [ -n "$current_warp_endpoint" ] && warp_endpoint_is_legacy "$current_warp_endpoint"; then
        yellow "内置 WARP 出站: 旧共享身份（下次设置分流时自动迁移）"
    else
        yellow "内置 WARP 出站: 未初始化（首次设置分流时自动注册独立身份）"
    fi
    green "当前已启用的分流规则集:"
    jq -r '.route.rules[] | select(.rule_set != null) | "\(.rule_set[]?) -> \(.outbound // "unknown")\(if .ip_version == 6 then " (IPv6)" else "" end)"' \
        "$route_file" 2>/dev/null | sort -u | while read -r mapping; do
        echo -e " - ${skyblue}${mapping}${re}"
    done || echo "  无"
    green "\n已添加的socks/http代理出站:"
    jq -r '.outbounds[] | select(.tag != "direct") | " - \(.tag) [\(.type)]"' "$outbound_file" 2>/dev/null || echo "  无"

    echo ""
    green "1. 设置分流服务 (内置WARP或已添加的socks/http)"
    skyblue "----------------------"
    red "2. 删除分流服务"
    skyblue "--------------"
    green "3. 添加 Socks5/HTTP 出站"
    skyblue "----------------------"
    red "4. 删除 Socks5/HTTP 出站"
    skyblue "----------------------"
    green "5. 查看内置 WARP 状态及解锁情况"
    skyblue "----------------------------"
    green "6. 更换内置 WARP 身份/IP"
    skyblue "----------------------"
    green "7. 自动优选 WARP IP（多平台解锁）"
    skyblue "----------------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    purple "00. 退出脚本"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)  add_rule_menu ;;
        2)  delete_rule_menu ;;
        3)  add_socks5_proxy ;;
        4)  delete_socks5_proxy ;;
        5)  clear; show_warp_status_and_unlocks; read -n 1 -s -r -p $'\n按任意键返回...'; warp_manage ;;
        6)  clear; rotate_warp_identity_once || red "WARP 身份更换失败，原配置未改变。"; read -n 1 -s -r -p $'\n按任意键返回...'; warp_manage ;;
        7)
            clear
            green "选择需要严格解锁的平台（可多选，如 134，回车默认 1234）:"
            green "1. Netflix  2. Disney+  3. ChatGPT  4. Gemini"
            reading "请输入: " warp_unlock_selection
            warp_unlock_selection=${warp_unlock_selection:-1234}
            if [[ "$warp_unlock_selection" =~ ^[1-4]+$ ]]; then
                auto_select_warp_candidate "$warp_unlock_selection" || true
            else
                red "输入无效，只能使用数字 1-4。"
            fi
            read -n 1 -s -r -p $'\n按任意键返回...'; warp_manage
            ;;
        0)  menu ;;
        00) exit 0 ;;
        *)  red "无效选项"; sleep 1; warp_manage ;;
    esac
}

add_rule_menu() {
    clear
    green "选择要分流的服务:\n"
    green "1.  OpenAI"
    green "2.  Claude"
    green "3.  Gemini"
    green "4.  Google"
    green "5.  Tiktok"
    green "6.  Twitter"
    green "7.  YouTube"
    green "8.  Netflix"
    green "9.  Telegram"
    green "10. 常见流媒体（聚合规则）"
    skyblue "-----------------------------"
    green "11. 设置全局代理出站 (所有流量走指定代理)"
    green "12. 恢复服务器原IP出站 (所有流量走服务器ip)"
    skyblue "-----------------------------"
    purple "0.  返回上级菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " add_choice
    case "$add_choice" in
        1)  rule_tag="openai"   ;;
        2)  rule_tag="claude"   ;;
        3)  rule_tag="gemini"   ;;
        4)  rule_tag="google"   ;;
        5)  rule_tag="tiktok"   ;;
        6)  rule_tag="twitter"  ;;
        7)  rule_tag="youtube"  ;;
        8)  rule_tag="netflix"  ;;
        9)  rule_tag="telegram" ;;
        10) rule_tag="streaming" ;;
        11) set_global_outbound; return ;;
        12) restore_direct_outbound; return ;;
        0)  warp_manage; return ;;
        *)  red "无效选项"; sleep 1; add_rule_menu; return ;;
    esac

    if ! ensure_warp_prerequisites; then
        red "无法初始化 WARP endpoint 或分流规则集。"
        sleep 2; warp_manage; return
    fi

    if jq -e --arg tag "$rule_tag" \
        '.route.rules[] | select(.rule_set != null) | .rule_set[]? | select(. == $tag)' \
        "$route_file" > /dev/null 2>&1; then
        yellow "规则集 '${rule_tag}' 已启用。"; sleep 1; warp_manage; return
    fi

    local -a proxy_tags out_tags
    mapfile -t proxy_tags < <(jq -r '.outbounds[]? | select(.tag != "direct") | .tag' "$outbound_file" 2>/dev/null)
    if [ ${#proxy_tags[@]} -eq 0 ]; then
        selected_out="wireguard-out"
        yellow "未找到其他出站，将自动使用 wireguard-out。"
    else
        out_tags=("wireguard-out" "${proxy_tags[@]}")
        echo ""
        green "请选择分流流量要走的出站:"
        for i in "${!out_tags[@]}"; do
            if [ "${out_tags[$i]}" = "wireguard-out" ]; then
                echo -e "  ${green}$((i+1)). ${skyblue}wireguard-out [内置WARP]${re}"
            else
                echo -e "  ${green}$((i+1)). ${skyblue}${out_tags[$i]}${re}"
            fi
        done
        reading "请输入编号: " out_choice
        if [[ ! "$out_choice" =~ ^[0-9]+$ ]] || \
           [ "$out_choice" -lt 1 ] || \
           [ "$out_choice" -gt "${#out_tags[@]}" ]; then
            red "无效选择"; sleep 1; warp_manage; return
        fi
        selected_out="${out_tags[$((out_choice-1))]}"
    fi

    local ipv6_direct_fallback=false
    if [ "$selected_out" = "wireguard-out" ] && native_ipv6_available; then
        ipv6_direct_fallback=true
        yellow "检测到原生 IPv6：该服务 IPv6 直连，IPv4 使用 WARP，避免 WARP IPv6 不可用。"
    fi

    if add_service_route "$rule_tag" "$selected_out" "$ipv6_direct_fallback"; then
        green "'${rule_tag}' 已分流至出站 '${selected_out}'"
    else
        red "'${rule_tag}' 分流设置失败，原配置已保留。"
    fi
    sleep 1; warp_manage
}
# 设置全局代理出站
set_global_outbound() {
    if ! ensure_warp_prerequisites; then
        red "无法校验分流前置配置。"
        sleep 2; add_rule_menu; return
    fi

    # 检查是否存在 socks5/http 代理出站（排除 direct 和 wireguard-out）
    local proxy_tags
    proxy_tags=($(jq -r '.outbounds[] | select(.tag != "direct" and .tag != "wireguard-out") | .tag' \
        "$outbound_file" 2>/dev/null))

    if [ ${#proxy_tags[@]} -eq 0 ]; then
        yellow "\n当前没有可用的 socks5/http 代理出站。"
        yellow "请先返回 → 添加 Socks5/HTTP 出站，再设置全局代理。\n"
        sleep 3; add_rule_menu; return
    fi

    echo ""
    green "请选择全局代理出站:"
    for i in "${!proxy_tags[@]}"; do
        echo -e "  ${green}$((i+1)). ${skyblue}${proxy_tags[$i]}${re}"
    done
    echo ""
    reading "请输入编号: " out_choice
    if [[ ! "$out_choice" =~ ^[0-9]+$ ]] || \
       [ "$out_choice" -lt 1 ] || \
       [ "$out_choice" -gt "${#proxy_tags[@]}" ]; then
        red "无效选择"; sleep 1; add_rule_menu; return
    fi
    local selected_out="${proxy_tags[$((out_choice-1))]}"

    if set_global_route "$selected_out"; then
        green "\n已设置全局代理出站：${purple}${selected_out}${re}"
        yellow "所有流量将通过 ${selected_out} 转发，如需恢复请选择「恢复服务器原IP出站」\n"
    else
        red "全局代理设置失败，原配置已保留。"
    fi
    sleep 2; warp_manage
}
# 恢复服务器原IP出站
restore_direct_outbound() {
    yellow "\n正在恢复默认路由配置...\n"

    if ensure_warp_prerequisites && restore_direct_route; then
        green "\n已恢复服务器原IP出站，所有流量走 direct。\n"
    else
        red "恢复 direct 失败，原配置已保留。"
    fi
    sleep 2; warp_manage
}
delete_rule_menu() {
    clear
    green "当前已启用的分流规则集:"
    jq -r '.route.rules[] | select(.rule_set != null) | .rule_set[]?' "$route_file" | nl -w2 -s'. '
    reading "\n输入要删除的规则名称或序号: " del_input
    if [[ "$del_input" =~ ^[0-9]+$ ]]; then
        tag=$(jq -r --arg idx "$del_input" '[.route.rules[] | select(.rule_set != null) | .rule_set[]] | .[(($idx | tonumber) - 1)]' "$route_file")
    else
        tag="$del_input"
    fi
    if [ -z "$tag" ] || [ "$tag" == "null" ]; then
        red "无效的选择"; sleep 1; warp_manage; return
    fi
    if delete_service_route "$tag"; then
        green "规则集 '${tag}' 已禁用。"
    else
        red "规则集 '${tag}' 删除失败，原配置已保留。"
    fi
    sleep 1; warp_manage
}

probe_proxy_url() {
    (
        local proxy_url="${1:-}"
        local config_dir="${PROXY_CURL_CONFIG_DIR:-${TMPDIR:-/tmp}}"
        local config_file='' escaped_proxy curl_status

        [ -n "$proxy_url" ] || exit 1
        case "$proxy_url" in
            *$'\r'*|*$'\n'*) exit 1 ;;
        esac
        config_file=$(mktemp "${config_dir%/}/.sing-box-proxy-curl.XXXXXX") || exit 1
        trap 'rm -f -- "$config_file"' EXIT
        trap 'exit 1' HUP INT TERM
        chmod 600 "$config_file" || exit 1

        escaped_proxy=${proxy_url//\\/\\\\}
        escaped_proxy=${escaped_proxy//\"/\\\"}
        {
            printf '%s\n' \
                'fail' \
                'silent' \
                'show-error' \
                'connect-timeout = 5' \
                'max-time = 10' \
                'output = "/dev/null"'
            printf 'proxy = "%s"\n' "$escaped_proxy"
        } > "$config_file" || exit 1

        curl --config "$config_file" \
            https://www.cloudflare.com/cdn-cgi/trace
        curl_status=$?
        exit "$curl_status"
    )
}

add_socks5_proxy() {
    clear
    reading "请输入代理URL (支持socks://,socks5://,http:// 支持v2rayN导出的节点链接): " proxy_url
    [ -z "$proxy_url" ] && { red "输入为空！"; sleep 1; return; }

    proto=$(echo "$proxy_url" | grep -oP '^[a-zA-Z0-9]+(?=://)')
    [[ ! "$proto" =~ ^(socks5|socks|http)$ ]] && { red "不支持的协议"; sleep 2; return; }
    case "$proto" in
        socks|socks5) outbound_type="socks" ;;
        http)         outbound_type="http" ;;
    esac

    after_proto="${proxy_url#*://}"
    if [[ "$after_proto" == *"#"* ]]; then
        tag_from_url="${after_proto##*#}"; after_proto="${after_proto%%#*}"
    else
        tag_from_url=""
    fi

    if [[ "$after_proto" == *"@"* ]]; then
        user_pass="${after_proto%%@*}"; host_port="${after_proto##*@}"
    else
        user_pass=""; host_port="$after_proto"
    fi

    user=""; password=""
    if [ -n "$user_pass" ]; then
        decoded=$(echo "$user_pass" | base64 -d 2>/dev/null)
        if [ -n "$decoded" ] && [[ "$decoded" != "$user_pass" ]] && [[ "$decoded" == *":"* ]]; then
            user="${decoded%%:*}"; password="${decoded#*:}"
        elif [[ "$user_pass" == *":"* ]]; then
            user="${user_pass%%:*}"; password="${user_pass#*:}"
        else
            user="$user_pass"
        fi
    fi

    server="${host_port%%:*}"; port="${host_port##*:}"
    [ -z "$server" ] || [ -z "$port" ] && { red "格式错误：缺少ip或端口"; sleep 2; return; }

    [[ "$proto" == "socks" || "$proto" == "socks5" ]] && check_proto="socks5" || check_proto="$proto"

    # 判断是否为本地地址，本地地址跳过外部 API 检测，直接用 curl 测试
    local is_local=false
    if [[ "$server" == "127.0.0.1" || "$server" == "::1" || "$server" == "localhost" ]]; then
        is_local=true
    fi

    local proxy_auth=""
    [ -n "$user" ] && [ -n "$password" ] && proxy_auth="${user}:${password}@" || \
        { [ -n "$user" ] && proxy_auth="${user}@"; }

    local curl_proxy_url="${check_proto}://${proxy_auth}${server}:${port}"
    if [ "$is_local" = true ]; then
        yellow "检测到本地代理 ${check_proto}://${server}:${port}，正在测试连通性..."
        if ! probe_proxy_url "$curl_proxy_url" 2>/dev/null; then
            yellow "警告：通过本地代理访问外网失败，请确认代理服务正在运行。"
            reading "是否仍然添加此代理？(y/n): " force_add
            [[ ! "$force_add" =~ ^[yY]$ ]] && { yellow "已取消"; sleep 1; return; }
        else
            green "本地代理可用"
        fi
    else
        yellow "正在测试代理 ${check_proto}://${server}:${port} ..."
        if ! probe_proxy_url "$curl_proxy_url" 2>/dev/null; then
            red "代理不可用或健康检查失败"
            sleep 2
            return
        fi
        green "代理可用"
    fi

    [ -n "$tag_from_url" ] && tag="$tag_from_url" || tag="${outbound_type}-${server}-${port}"
    jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" >/dev/null 2>&1 \
        && { red "出站标签 '${tag}' 已存在"; sleep 2; return; }

    local outbound_json switch_existing_rules=false
    # 根据是否有账号密码，决定写入字段，避免空字符串导致 sing-box 报错
    if [ -n "$user" ] && [ -n "$password" ]; then
        outbound_json=$(jq -cn \
            --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
            --arg port "$port" --arg user "$user" --arg password "$password" \
            '{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber),"username":$user,"password":$password}') || return
    else
        outbound_json=$(jq -cn \
            --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
            --arg port "$port" \
            '{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber)}') || return
    fi

    if jq -e '.route.rules | length > 0' "$route_file" >/dev/null 2>&1; then
        switch_existing_rules=true
    fi
    local proxy_transaction_status=0
    add_proxy_outbound_transaction "$outbound_json" "$switch_existing_rules" || \
        proxy_transaction_status=$?
    if [ "$proxy_transaction_status" -ne 0 ]; then
        if [ "$proxy_transaction_status" -eq 2 ]; then
            red "代理出站添加事务 fatal 中止；请勿继续操作，并按上方路径人工恢复。"
        else
            red "代理出站添加失败，操作已中止。"
        fi
        sleep 2
        return "$proxy_transaction_status"
    fi
    if [ "$switch_existing_rules" = true ]; then
        yellow "已将现有分流规则出站切换为 '${tag}'。"
    fi

    green "\n${tag} 代理出站已添加\n"
    sleep 2; warp_manage
}

delete_socks5_proxy() {
    clear
    green "当前可用出站列表:"
    local out_list=$(jq -r '[.outbounds[] | select(.tag != "direct")] | to_entries | .[] | "\(.key+1). \(.value.tag) [\(.value.type)]"' "$outbound_file" 2>/dev/null)
    [ -z "$out_list" ] && { yellow "没有可删除的出站。"; sleep 2; return; }
    echo "$out_list"

    reading "输入要删除的出站编号或标签: " del_input
    if [[ "$del_input" =~ ^[0-9]+$ ]]; then
        tag=$(jq -r --arg idx "$del_input" '.outbounds | map(select(.tag != "direct")) | .[($idx | tonumber)-1].tag // empty' "$outbound_file")
        [ -z "$tag" ] && { red "编号无效！"; sleep 1; return; }
    else
        tag="$del_input"
        jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" > /dev/null 2>&1 || { red "标签 '${tag}' 不存在！"; sleep 1; return; }
    fi
    [ "$tag" == "wireguard-out" ] && { red "wireguard-out 为系统内置，不可删除！"; sleep 2; return; }

    local proxy_transaction_status=0
    mutate_proxy_transaction "$tag" direct || proxy_transaction_status=$?
    if [ "$proxy_transaction_status" -eq 0 ]; then
        green "${tag} 代理出站已删除。"
    else
        if [ "$proxy_transaction_status" -eq 2 ]; then
            red "${tag} 代理出站删除事务 fatal 中止；请勿继续操作，并按上方路径人工恢复。"
        else
            red "${tag} 代理出站删除失败，操作已中止。"
        fi
        sleep 1
        return "$proxy_transaction_status"
    fi
    sleep 1
}

# ============================================================
# 协议管理模块 - 增加/删除 socks5 / anytls / shadowsocks-2022
# ============================================================

# 检查指定 tag 是否已在 inbounds 中存在
proto_exists() {
    local tag="$1"
    jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "${conf_dir}/inbounds.json" > /dev/null 2>&1
}

# Transaction-safe tag lookup.  Return 0 when the base tag (or its generated
# IPv6 twin) exists, 1 when neither exists, and 2 when the configuration cannot
# be trusted.  Callers which mutate inbounds must run this after acquiring the
# shared configuration lock.
extra_protocol_tag_exists() {
    local inbounds_file="${1:-}"
    local tag="${2:-}"
    local status

    [ -n "$tag" ] || return 2
    [ -f "$inbounds_file" ] && [ ! -L "$inbounds_file" ] && [ -r "$inbounds_file" ] || return 2
    jq -e '
        (type == "object") and
        (.inbounds | type == "array") and
        all(.inbounds[]; type == "object" and ((.tag // "") | type == "string"))
    ' "$inbounds_file" >/dev/null 2>&1 || return 2
    jq -e --arg tag "$tag" '
        any(.inbounds[]; .tag == $tag or .tag == ($tag + "-ipv6"))
    ' "$inbounds_file" >/dev/null 2>&1
    status=$?
    case "$status" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# Read the authoritative listen port for a base tag and its optional IPv6
# twin.  The pair must use one valid port; otherwise fail closed with rc 2.
# A missing pair is a normal rc 1.
get_extra_protocol_uniform_port() {
    local inbounds_file="${1:-}"
    local tag="${2:-}"
    local result

    [ -n "$tag" ] || return 2
    [ -f "$inbounds_file" ] && [ ! -L "$inbounds_file" ] && [ -r "$inbounds_file" ] || return 2
    result=$(jq -er --arg tag "$tag" '
        if (type != "object") or (.inbounds | type != "array") then
            "__INVALID__"
        else
            [.inbounds[] | select(.tag == $tag or .tag == ($tag + "-ipv6"))] as $matches |
            if ($matches | length) == 0 then
                "__ABSENT__"
            elif (($matches | map(.tag) | unique | length) != ($matches | length)) then
                "__INVALID__"
            else
                [$matches[].listen_port] as $ports |
                if (all($ports[];
                        (type == "number") and (. == floor) and (. >= 1) and (. <= 65535))) and
                   (($ports | unique | length) == 1) then
                    ($ports[0] | tostring)
                else
                    "__INVALID__"
                end
            end
        end
    ' "$inbounds_file" 2>/dev/null) || return 2
    case "$result" in
        __ABSENT__) return 1 ;;
        __INVALID__) return 2 ;;
    esac
    validate_port_value "$result" extra_protocol_port >/dev/null 2>&1 || return 2
    printf '%s\n' "$result"
}

# 更新订阅文件
remove_url_by_tag() {
    local scheme="${1:-}"
    local parent name tmp_file

    [[ "$scheme" =~ ^[A-Za-z][A-Za-z0-9+.-]*$ ]] || return 1
    [ -f "$client_dir" ] && [ ! -L "$client_dir" ] || return 1
    parent=$(dirname "$client_dir") || return 1
    name=$(basename "$client_dir") || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    tmp_file=$(mktemp "${parent}/.remove-url.${name}.XXXXXX") || return 1
    if ! awk -v prefix="${scheme}://" '
            NF && index($0, prefix) != 1 { print }
        ' "$client_dir" > "$tmp_file" ||
       ! chmod --reference="$client_dir" "$tmp_file" 2>/dev/null ||
       ! mv -f -- "$tmp_file" "$client_dir"; then
        rm -f -- "$tmp_file"
        return 1
    fi
}

write_base64_subscription() {
    local source_file="$1"
    local sub_file="$2"
    local sub_dir sub_name tmp_file

    sub_dir=$(dirname "$sub_file")
    sub_name=$(basename "$sub_file")
    mkdir -p "$sub_dir" || return 1
    tmp_file=$(mktemp "${sub_dir}/.tmp.${sub_name}.XXXXXX") || return 1

    if [ ! -s "$source_file" ]; then
        if ! : > "$tmp_file"; then
            rm -f "$tmp_file"
            return 1
        fi
    elif ! base64 -w0 "$source_file" > "$tmp_file" 2>/dev/null; then
        if ! (set -o pipefail; base64 "$source_file" | tr -d '\n\r' > "$tmp_file"); then
            rm -f "$tmp_file"
            return 1
        fi
    fi

    chmod 644 "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
    mv -f "$tmp_file" "$sub_file" || { rm -f "$tmp_file"; return 1; }
}
sync_combined_subscription() {
    local tmp_file cfy_file cfy_sub_file combined_sub_file
    local tmp_cfy_sub_file='' tmp_combined_sub_file='' tmp_sub_file=''
    cfy_file="${work_dir}/cfy-url.txt"
    cfy_sub_file="${work_dir}/cfy-sub.txt"
    combined_sub_file="${work_dir}/all-sub.txt"

    mkdir -p "${work_dir}" || return 1
    tmp_file=$(mktemp "${work_dir}/.tmp.all-url.XXXXXX") || return 1

    if [ -s "$client_dir" ] && ! sed '/^[[:space:]]*$/d' "$client_dir" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    if [ -s "$cfy_file" ]; then
        if [ -s "$tmp_file" ] && ! printf '\n' >> "$tmp_file"; then
            rm -f "$tmp_file"
            return 1
        fi
        if ! sed '/^[[:space:]]*$/d' "$cfy_file" >> "$tmp_file"; then
            rm -f "$tmp_file"
            return 1
        fi
        tmp_cfy_sub_file=$(mktemp "${work_dir}/.tmp.cfy-sub.txt.XXXXXX") || { rm -f "$tmp_file"; return 1; }
        write_base64_subscription "$cfy_file" "$tmp_cfy_sub_file" || {
            rm -f "$tmp_file" "$tmp_cfy_sub_file"
            return 1
        }
    fi

    if [ -s "$tmp_file" ]; then
        chmod 644 "$tmp_file" 2>/dev/null || {
            rm -f "$tmp_file" "$tmp_cfy_sub_file"
            return 1
        }
        tmp_combined_sub_file=$(mktemp "${work_dir}/.tmp.all-sub.txt.XXXXXX") || {
            rm -f "$tmp_file" "$tmp_cfy_sub_file"
            return 1
        }
        tmp_sub_file=$(mktemp "${work_dir}/.tmp.sub.txt.XXXXXX") || {
            rm -f "$tmp_file" "$tmp_cfy_sub_file" "$tmp_combined_sub_file"
            return 1
        }
        write_base64_subscription "$tmp_file" "$tmp_combined_sub_file" || {
            rm -f "$tmp_file" "$tmp_cfy_sub_file" "$tmp_combined_sub_file" "$tmp_sub_file"
            return 1
        }
        write_base64_subscription "$tmp_file" "$tmp_sub_file" || {
            rm -f "$tmp_file" "$tmp_cfy_sub_file" "$tmp_combined_sub_file" "$tmp_sub_file"
            return 1
        }
        mv -f "$tmp_file" "$combined_client_dir" || {
            rm -f "$tmp_file" "$tmp_cfy_sub_file" "$tmp_combined_sub_file" "$tmp_sub_file"
            return 1
        }
        mv -f "$tmp_combined_sub_file" "$combined_sub_file" || {
            rm -f "$tmp_cfy_sub_file" "$tmp_combined_sub_file" "$tmp_sub_file"
            return 1
        }
        mv -f "$tmp_sub_file" "${work_dir}/sub.txt" || {
            rm -f "$tmp_cfy_sub_file" "$tmp_sub_file"
            return 1
        }
        if [ -n "$tmp_cfy_sub_file" ]; then
            mv -f "$tmp_cfy_sub_file" "$cfy_sub_file" || { rm -f "$tmp_cfy_sub_file"; return 1; }
        fi
    else
        rm -f "$tmp_file" "$tmp_cfy_sub_file"
        printf '' | atomic_write_file "$combined_client_dir" 644 || return 1
        printf '' | atomic_write_file "$combined_sub_file" 644 || return 1
        printf '' | atomic_write_file "${work_dir}/sub.txt" 644 || return 1
    fi
}
update_sub() {
    write_base64_subscription "$client_dir" "${work_dir}/base-sub.txt" || return 1
    sync_combined_subscription || return 1
}

resolve_extra_protocol_listeners() {
    local bindv6only=0

    EXTRA_PROTOCOL_HAS_IPV4=0
    EXTRA_PROTOCOL_HAS_IPV6=0
    EXTRA_PROTOCOL_LISTENERS=()
    ipv4_stack_available && EXTRA_PROTOCOL_HAS_IPV4=1
    ipv6_stack_available && EXTRA_PROTOCOL_HAS_IPV6=1
    [ "$EXTRA_PROTOCOL_HAS_IPV4" -eq 1 ] || [ "$EXTRA_PROTOCOL_HAS_IPV6" -eq 1 ] || return 1
    bindv6only=$(get_bindv6only) || return 1
    [[ "$bindv6only" =~ ^[01]$ ]] || return 1
    mapfile -t EXTRA_PROTOCOL_LISTENERS < <(
        get_listener_address "$EXTRA_PROTOCOL_HAS_IPV4" "$EXTRA_PROTOCOL_HAS_IPV6" "$bindv6only"
    )
    [ "${#EXTRA_PROTOCOL_LISTENERS[@]}" -gt 0 ] || return 1
    case "${EXTRA_PROTOCOL_LISTENERS[*]}" in
        '0.0.0.0'|'::'|'0.0.0.0 ::') ;;
        *) return 1 ;;
    esac
}

resolve_extra_protocol_server_host() {
    local raw_host octet
    local -a octets=()

    EXTRA_PROTOCOL_SERVER_HOST=''
    raw_host=$(get_realip) || return 1
    [ -n "$raw_host" ] && [[ "$raw_host" != *[[:space:]]* ]] || return 1
    if [[ "$raw_host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$raw_host"
        [ "${#octets[@]}" -eq 4 ] || return 1
        for octet in "${octets[@]}"; do
            [ "$octet" -le 255 ] 2>/dev/null || return 1
        done
    elif [[ "$raw_host" =~ ^\[[0-9A-Fa-f:]+\]$ ]] || \
         [[ "$raw_host" =~ ^[0-9A-Fa-f:]+$ && "$raw_host" == *:* ]]; then
        :
    else
        return 1
    fi
    EXTRA_PROTOCOL_SERVER_HOST=$(format_url_host "$raw_host") || return 1
    [ -n "$EXTRA_PROTOCOL_SERVER_HOST" ]
}

# Read the local listener and externally mapped port independently.  The
# default remains one-port operation for ordinary VPSes; NAT users can publish
# the provider-assigned public port while sing-box/firewall keep using the
# allocated local listener port.
read_extra_protocol_ports() {
    local protocol_name="${1:-额外协议}"
    local listen_input public_input

    EXTRA_PROTOCOL_LISTEN_PORT=''
    EXTRA_PROTOCOL_PUBLIC_PORT=''
    while :; do
        reading "请输入 ${protocol_name} 监听端口 (回车随机生成): " listen_input
        if [ -z "$listen_input" ]; then
            listen_input=$(shuf -i 10000-65000 -n 1) || return 1
            yellow "随机监听端口适用于普通 VPS；NAT 机器请使用服务商分配的监听端口。"
        fi
        if validate_port_value "$listen_input" extra_protocol_listen_port; then
            break
        fi
        yellow "错误：监听端口必须是1-65535之间的数字！"
    done

    while :; do
        reading "请输入公网映射端口 (回车=${listen_input}): " public_input
        [ -n "$public_input" ] || public_input="$listen_input"
        if validate_port_value "$public_input" extra_protocol_public_port; then
            break
        fi
        yellow "错误：公网映射端口必须是1-65535之间的数字！"
    done

    EXTRA_PROTOCOL_LISTEN_PORT="$listen_input"
    EXTRA_PROTOCOL_PUBLIC_PORT="$public_input"
    green "${protocol_name}监听端口：${purple}${EXTRA_PROTOCOL_LISTEN_PORT}${re}"
    if [ "$EXTRA_PROTOCOL_PUBLIC_PORT" != "$EXTRA_PROTOCOL_LISTEN_PORT" ]; then
        green "${protocol_name}公网映射端口：${purple}${EXTRA_PROTOCOL_PUBLIC_PORT}${re}"
    fi
}

backup_extra_protocol_transaction() {
    local inbounds_file="${1:-}"
    local combined_path="${combined_client_dir:-${work_dir}/all-url.txt}"
    local backup_parent backup_dir path index
    local -a files=(
        "$inbounds_file"
        "$client_dir"
        "${work_dir}/base-sub.txt"
        "$combined_path"
        "${work_dir}/all-sub.txt"
        "${work_dir}/sub.txt"
        "${work_dir}/cfy-sub.txt"
    )

    EXTRA_PROTOCOL_BACKUP_DIR=''
    [ -n "$inbounds_file" ] && [ -f "$inbounds_file" ] && [ ! -L "$inbounds_file" ] || return 1
    [ -n "${client_dir:-}" ] && [ ! -L "$client_dir" ] || return 1
    backup_parent=$(dirname "$inbounds_file") || return 1
    [ -d "$backup_parent" ] && [ ! -L "$backup_parent" ] || return 1
    backup_dir=$(mktemp -d "${backup_parent}/.extra-protocol.XXXXXX") || return 1
    chmod 700 "$backup_dir" || { rm -rf -- "$backup_dir"; return 1; }

    for ((index = 0; index < ${#files[@]}; index++)); do
        path="${files[$index]}"
        [ -n "$path" ] || { rm -rf -- "$backup_dir"; return 1; }
        [ ! -L "$path" ] || { rm -rf -- "$backup_dir"; return 1; }
        if [ -e "$path" ]; then
            [ -f "$path" ] || { rm -rf -- "$backup_dir"; return 1; }
            cp -p -- "$path" "${backup_dir}/file.${index}" || {
                rm -rf -- "$backup_dir"
                return 1
            }
            : > "${backup_dir}/present.${index}" || {
                rm -rf -- "$backup_dir"
                return 1
            }
        fi
    done
    EXTRA_PROTOCOL_BACKUP_DIR="$backup_dir"
}

restore_extra_protocol_files() {
    local backup_dir="${1:-}"
    local inbounds_file="${2:-}"
    local combined_path="${combined_client_dir:-${work_dir}/all-url.txt}"
    local path parent name tmp_file index
    local -a files=(
        "$inbounds_file"
        "$client_dir"
        "${work_dir}/base-sub.txt"
        "$combined_path"
        "${work_dir}/all-sub.txt"
        "${work_dir}/sub.txt"
        "${work_dir}/cfy-sub.txt"
    )

    [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || return 1
    [ -n "$inbounds_file" ] && [ ! -L "$inbounds_file" ] || return 1
    for ((index = 0; index < ${#files[@]}; index++)); do
        path="${files[$index]}"
        [ -n "$path" ] && [ ! -L "$path" ] || return 1
        if [ -e "${backup_dir}/present.${index}" ]; then
            [ -f "${backup_dir}/file.${index}" ] && [ ! -L "${backup_dir}/file.${index}" ] || return 1
            parent=$(dirname "$path") || return 1
            name=$(basename "$path") || return 1
            [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
            tmp_file=$(mktemp "${parent}/.restore.${name}.XXXXXX") || return 1
            if ! cp -p -- "${backup_dir}/file.${index}" "$tmp_file" ||
               ! mv -f -- "$tmp_file" "$path" ||
               ! cmp -s -- "${backup_dir}/file.${index}" "$path"; then
                rm -f -- "$tmp_file"
                return 1
            fi
        elif ! rm -f -- "$path"; then
            return 1
        fi
    done
}

restore_extra_protocol_service_state() {
    local was_active="${1:-0}"

    case "$was_active" in
        1)
            restart_singbox >/dev/null 2>&1 || return 1
            singbox_service_is_active
            ;;
        0)
            if singbox_service_is_active; then
                stop_singbox_checked >/dev/null 2>&1 || return 1
            fi
            ! singbox_service_is_active
            ;;
        *) return 1 ;;
    esac
}

commit_extra_protocol_service_state() {
    local was_active="${1:-}"

    EXTRA_PROTOCOL_SERVICE_TOUCHED=0
    case "$was_active" in
        1)
            validate_installed_singbox_config_strict || return 1
            EXTRA_PROTOCOL_SERVICE_TOUCHED=1
            restart_singbox >/dev/null 2>&1 || return 1
            singbox_service_is_active
            ;;
        0)
            validate_installed_singbox_config_strict || return 1
            ! singbox_service_is_active
            ;;
        *) return 1 ;;
    esac
}

cleanup_extra_protocol_backup() {
    local backup_dir="${1:-}"

    [ -n "$backup_dir" ] && [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || return 1
    rm -rf -- "$backup_dir"
}

rollback_extra_protocol_signal_transaction() {
    local backup_dir="${1:-}"
    local inbounds_file="${2:-}"
    local was_active="${3:-0}"
    local status=0

    restore_extra_protocol_files "$backup_dir" "$inbounds_file" || status=1
    if [ "${EXTRA_PROTOCOL_SERVICE_TOUCHED:-0}" = 1 ]; then
        restore_extra_protocol_service_state "$was_active" || status=1
    elif [ "${EXTRA_PROTOCOL_SERVICE_TOUCHED:-0}" != 0 ]; then
        status=1
    fi
    if [ "${#DURABLE_TX_OWNED_RECORDS[@]}" -gt 0 ]; then
        remove_owned_firewall_records_exact "${DURABLE_TX_OWNED_RECORDS[@]}" || status=1
    fi
    cleanup_extra_protocol_backup "$backup_dir" || status=1
    return "$status"
}

handle_extra_protocol_transaction_failure() {
    local backup_dir="${1:-}"
    local inbounds_file="${2:-}"
    local was_active="${3:-0}"
    local failure_status="${4:-1}"
    local fatal_hint="${5:-0}"
    local service_touched="${6:-0}"
    shift 6 || return 2
    local status=0
    local -a new_firewall_records=("$@")

    restore_extra_protocol_files "$backup_dir" "$inbounds_file" || status=1
    if [ "$service_touched" = 1 ]; then
        restore_extra_protocol_service_state "$was_active" || status=1
    elif [ "$service_touched" != 0 ]; then
        status=1
    fi
    if [ "${#new_firewall_records[@]}" -gt 0 ]; then
        remove_owned_firewall_records_exact "${new_firewall_records[@]}" || status=1
    fi
    [ "$failure_status" -ge 1 ] 2>/dev/null || failure_status=1
    if [ "$status" -eq 0 ] && [ "$fatal_hint" -eq 0 ]; then
        if cleanup_extra_protocol_backup "$backup_dir"; then
            EXTRA_PROTOCOL_RECOVERY_PATH=''
            [ "$failure_status" -ne 2 ] || failure_status=1
            return "$failure_status"
        fi
        status=1
    fi

    EXTRA_PROTOCOL_RECOVERY_PATH="$backup_dir"
    red "额外协议事务回滚不完整。人工恢复路径: ${backup_dir}"
    return 2
}

_add_extra_protocol_transaction_locked() {
    local inbounds_file="${1:-}"
    local client_line="${2:-}"
    local mutation_callback="${3:-}"
    shift 3 || return 1
    local delimiter_seen=0 backup_dir was_active=0 transaction_status=0 has_v4 has_v6
    local firewall_rule rule_port rule_proto conflict_status nginx_conflict_status tag_status
    local expected_tag
    local -a firewall_rules=() callback_args=() new_firewall_records=()

    [ "${1:-}" = --families ] && [ "$#" -ge 4 ] || return 1
    has_v4="$2"
    has_v6="$3"
    shift 3
    [[ "$has_v4" =~ ^[01]$ && "$has_v6" =~ ^[01]$ ]] || return 1
    [ "$has_v4" -eq 1 ] || [ "$has_v6" -eq 1 ] || return 1
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -- ]; then
            delimiter_seen=1
            shift
            callback_args=("$@")
            break
        fi
        firewall_rules+=("$1")
        shift
    done
    [ "$delimiter_seen" -eq 1 ] && [ "${#firewall_rules[@]}" -gt 0 ] || return 1
    [ -n "$inbounds_file" ] && [ -n "$client_line" ] || return 1
    declare -F "$mutation_callback" >/dev/null 2>&1 || return 1
    expected_tag="${callback_args[0]:-}"
    [ -n "$expected_tag" ] || return 1

    if extra_protocol_tag_exists "$inbounds_file" "$expected_tag"; then
        red "协议标签 ${expected_tag} 已存在，未重复添加。"
        return 1
    else
        tag_status=$?
    fi
    [ "$tag_status" -eq 1 ] || return 2

    for firewall_rule in "${firewall_rules[@]}"; do
        [[ "$firewall_rule" == */* ]] || return 1
        rule_port="${firewall_rule%/*}"
        rule_proto="${firewall_rule#*/}"
        validate_port_value "$rule_port" extra_protocol_port || return 1
        case "$rule_proto" in tcp|udp) ;; *) return 1 ;; esac
        if configured_inbound_port_conflict_exists "$inbounds_file" "$rule_port" "$rule_proto"; then
            red "端口 ${rule_port}/${rule_proto} 已被 sing-box 配置占用。"
            return 1
        else
            conflict_status=$?
        fi
        [ "$conflict_status" -eq 1 ] || return 2
        if [ "$rule_proto" = tcp ]; then
            if nginx_configured_port_conflict_exists \
                "${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}" \
                "$rule_port" "$rule_proto"; then
                red "端口 ${rule_port}/${rule_proto} 已被 Nginx 配置占用。"
                return 1
            else
                nginx_conflict_status=$?
            fi
            [ "$nginx_conflict_status" -eq 1 ] || return 2
        fi
        if port_is_listening "$rule_port" "$rule_proto"; then
            red "端口 ${rule_port}/${rule_proto} 已被其他进程监听。"
            return 1
        fi
    done

    EXTRA_PROTOCOL_RECOVERY_PATH=''
    EXTRA_PROTOCOL_SERVICE_TOUCHED=0
    backup_extra_protocol_transaction "$inbounds_file" || return 1
    backup_dir="$EXTRA_PROTOCOL_BACKUP_DIR"
    singbox_service_is_active && was_active=1
    if ! arm_durable_transaction extra-protocol-add "$(dirname "$backup_dir")" "$backup_dir" \
        EXTRA_PROTOCOL_RECOVERY_PATH rollback_extra_protocol_signal_transaction \
        "$was_active" '' '' "$backup_dir" "$inbounds_file" "$was_active"; then
        cleanup_extra_protocol_backup "$backup_dir" || {
            EXTRA_PROTOCOL_RECOVERY_PATH="$backup_dir"
            return 2
        }
        return 1
    fi

    if ! durable_transaction_checkpoint firewall-mutating; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        EXTRA_PROTOCOL_RECOVERY_PATH="${DURABLE_TX_RECOVERY_DIR:-$backup_dir}"
        return 2
    fi
    allow_port --families "$has_v4" "$has_v6" "${firewall_rules[@]}" || transaction_status=$?
    if [ "$transaction_status" -ne 0 ]; then
        if [ "$transaction_status" -eq 2 ]; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            red "防火墙事务状态未决，已保留额外协议恢复备份：${backup_dir}"
            return 2
        fi
        if cleanup_extra_protocol_backup "$backup_dir"; then
            if ! disarm_durable_transaction cleanup; then
                return 2
            fi
            return "$transaction_status"
        fi
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        red "额外协议添加失败且事务备份未能清理：${backup_dir}"
        return 2
    fi
    new_firewall_records=("${FIREWALL_LAST_ADDED_RECORDS[@]}")
    if ! durable_transaction_set_owned_records "${new_firewall_records[@]}" || \
       ! durable_transaction_checkpoint precommit; then
        rollback_extra_protocol_signal_transaction "$backup_dir" "$inbounds_file" "$was_active" || {
            disarm_durable_transaction keep >/dev/null 2>&1 || true
            return 2
        }
        disarm_durable_transaction cleanup >/dev/null 2>&1 || return 2
        return 1
    fi

    transaction_status=0
    "$mutation_callback" "$inbounds_file" "${callback_args[@]}" || transaction_status=$?
    [ "$transaction_status" -ne 0 ] || \
        printf '\n%s\n' "$client_line" >> "$client_dir" || transaction_status=$?
    if [ "$transaction_status" -eq 0 ]; then
        durable_transaction_checkpoint config-mutated || transaction_status=2
    fi
    [ "$transaction_status" -ne 0 ] || \
        commit_extra_protocol_service_state "$was_active" || transaction_status=$?
    if [ "$transaction_status" -eq 0 ]; then
        durable_transaction_checkpoint publishing || transaction_status=2
    fi
    [ "$transaction_status" -ne 0 ] || update_sub || transaction_status=$?
    if [ "$transaction_status" -ne 0 ]; then
        handle_extra_protocol_transaction_failure "$backup_dir" "$inbounds_file" "$was_active" \
            "$transaction_status" 0 \
            "$EXTRA_PROTOCOL_SERVICE_TOUCHED" \
            "${new_firewall_records[@]}"
        transaction_status=$?
        if [ -n "${EXTRA_PROTOCOL_RECOVERY_PATH:-}" ]; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
        elif ! disarm_durable_transaction cleanup; then
            return 2
        fi
        return "$transaction_status"
    fi

    if ! durable_transaction_checkpoint committed; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! cleanup_extra_protocol_backup "$backup_dir"; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        red "额外协议已生效，但事务备份未能清理: ${backup_dir}"
        return 3
    fi
    if ! disarm_durable_transaction cleanup; then
        return 3
    fi
}

add_extra_protocol_transaction() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "额外协议添加"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _add_extra_protocol_transaction_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

_remove_extra_protocol_transaction_locked() {
    local inbounds_file="${1:-}"
    local url_scheme="${2:-}"
    local mutation_callback="${3:-}"
    shift 3 || return 1
    local delimiter_seen=0 backup_dir was_active=0 cleanup_status=0 transaction_status=0
    local firewall_rule rule_proto current_port port_status expected_tag
    local -a firewall_rules=() callback_args=() firewall_protocols=()

    while [ "$#" -gt 0 ]; do
        if [ "$1" = -- ]; then
            delimiter_seen=1
            shift
            callback_args=("$@")
            break
        fi
        firewall_rules+=("$1")
        shift
    done
    [ "$delimiter_seen" -eq 1 ] && [ "${#firewall_rules[@]}" -gt 0 ] || return 1
    [ -n "$inbounds_file" ] && [[ "$url_scheme" =~ ^[A-Za-z0-9+.-]+$ ]] || return 1
    declare -F "$mutation_callback" >/dev/null 2>&1 || return 1
    expected_tag="${callback_args[0]:-}"
    [ -n "$expected_tag" ] || return 1

    # The wrapper may have waited on the shared lock after reading a port.
    # Re-read the tag and its port now, then rebuild cleanup rules from the
    # authoritative locked configuration rather than stale caller data.
    for firewall_rule in "${firewall_rules[@]}"; do
        [[ "$firewall_rule" == */* ]] || return 1
        rule_proto="${firewall_rule#*/}"
        case "$rule_proto" in tcp|udp) ;; *) return 1 ;; esac
        firewall_protocols+=("$rule_proto")
    done
    if current_port=$(get_extra_protocol_uniform_port "$inbounds_file" "$expected_tag"); then
        :
    else
        port_status=$?
        [ "$port_status" -eq 1 ] && return 1
        return 2
    fi
    firewall_rules=()
    for rule_proto in "${firewall_protocols[@]}"; do
        firewall_rules+=("${current_port}/${rule_proto}")
    done

    EXTRA_PROTOCOL_RECOVERY_PATH=''
    EXTRA_PROTOCOL_SERVICE_TOUCHED=0
    backup_extra_protocol_transaction "$inbounds_file" || return 1
    backup_dir="$EXTRA_PROTOCOL_BACKUP_DIR"
    singbox_service_is_active && was_active=1
    if ! arm_durable_transaction extra-protocol-remove "$(dirname "$backup_dir")" "$backup_dir" \
        EXTRA_PROTOCOL_RECOVERY_PATH rollback_extra_protocol_signal_transaction \
        "$was_active" "$current_port" '' "$backup_dir" "$inbounds_file" "$was_active"; then
        cleanup_extra_protocol_backup "$backup_dir" || {
            EXTRA_PROTOCOL_RECOVERY_PATH="$backup_dir"
            return 2
        }
        return 1
    fi

    "$mutation_callback" "$inbounds_file" "${callback_args[@]}" || transaction_status=$?
    [ "$transaction_status" -ne 0 ] || remove_url_by_tag "$url_scheme" || transaction_status=$?
    if [ "$transaction_status" -eq 0 ]; then
        durable_transaction_checkpoint config-mutated || transaction_status=2
    fi
    [ "$transaction_status" -ne 0 ] || \
        commit_extra_protocol_service_state "$was_active" || transaction_status=$?
    if [ "$transaction_status" -eq 0 ]; then
        durable_transaction_checkpoint publishing || transaction_status=2
    fi
    [ "$transaction_status" -ne 0 ] || update_sub || transaction_status=$?
    if [ "$transaction_status" -ne 0 ]; then
        handle_extra_protocol_transaction_failure "$backup_dir" "$inbounds_file" "$was_active" \
            "$transaction_status" 0 \
            "$EXTRA_PROTOCOL_SERVICE_TOUCHED"
        transaction_status=$?
        if [ -n "${EXTRA_PROTOCOL_RECOVERY_PATH:-}" ]; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
        elif ! disarm_durable_transaction cleanup; then
            return 2
        fi
        return "$transaction_status"
    fi

    if ! durable_transaction_checkpoint firewall-mutating; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    remove_owned_firewall_ports_if_unused "$inbounds_file" "${firewall_rules[@]}" || cleanup_status=$?
    if [ "$cleanup_status" -ne 0 ]; then
        if [ "$cleanup_status" -eq 2 ]; then
            handle_extra_protocol_transaction_failure "$backup_dir" "$inbounds_file" "$was_active" \
                "$cleanup_status" 1 "$EXTRA_PROTOCOL_SERVICE_TOUCHED"
        else
            handle_extra_protocol_transaction_failure "$backup_dir" "$inbounds_file" "$was_active" \
                "$cleanup_status" 0 "$EXTRA_PROTOCOL_SERVICE_TOUCHED"
        fi
        transaction_status=$?
        if [ -n "${EXTRA_PROTOCOL_RECOVERY_PATH:-}" ]; then
            disarm_durable_transaction keep >/dev/null 2>&1 || true
        elif ! disarm_durable_transaction cleanup; then
            return 2
        fi
        return "$transaction_status"
    fi

    if ! durable_transaction_checkpoint committed; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        return 2
    fi
    if ! cleanup_extra_protocol_backup "$backup_dir"; then
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        red "额外协议已删除，但事务备份未能清理: ${backup_dir}"
        return 3
    fi
    if ! disarm_durable_transaction cleanup; then
        return 3
    fi
}

remove_extra_protocol_transaction() {
    local status

    acquire_proxy_transaction_lock_checked "${conf_dir}" "额外协议删除"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _remove_extra_protocol_transaction_locked "$@"
    status=$?
    release_proxy_transaction_lock
    return "$status"
}

mutate_socks5_inbound_add() {
    local inbounds_file="$1" tag="$2" port="$3" user="$4" pass="$5"
    local listener_v4_or_dual="${6:-}" listener_v6="${7:-}"
    apply_jq_config "$inbounds_file" \
       --arg tag "$tag" --argjson port "$port" --arg user "$user" --arg pass "$pass" \
       --arg listener1 "$listener_v4_or_dual" --arg listener2 "$listener_v6" \
       'def inbound($inbound_tag; $listener): {
           "type": "socks",
           "tag": $inbound_tag,
           "listen": $listener,
           "listen_port": $port,
           "users": [{"username": $user, "password": $pass}]
       };
       .inbounds += ([inbound($tag; $listener1)] +
           (if $listener2 == "" then [] else [inbound($tag + "-ipv6"; $listener2)] end))'
}

mutate_anytls_inbound_add() {
    local inbounds_file="$1" tag="$2" port="$3" pass="$4" cert="$5" key="$6"
    local listener_v4_or_dual="${7:-}" listener_v6="${8:-}"
    apply_jq_config "$inbounds_file" \
       --arg tag "$tag" --argjson port "$port" --arg pass "$pass" \
       --arg cert "$cert" --arg key "$key" \
       --arg listener1 "$listener_v4_or_dual" --arg listener2 "$listener_v6" \
       'def inbound($inbound_tag; $listener): {
           "type": "anytls",
           "tag": $inbound_tag,
           "listen": $listener,
           "listen_port": $port,
           "users": [{"password": $pass}],
           "tls": {
               "enabled": true,
               "certificate_path": $cert,
               "key_path": $key
           }
       };
       .inbounds += ([inbound($tag; $listener1)] +
           (if $listener2 == "" then [] else [inbound($tag + "-ipv6"; $listener2)] end))'
}

mutate_ss2022_inbound_add() {
    local inbounds_file="$1" tag="$2" port="$3" method="$4" key="$5"
    local listener_v4_or_dual="${6:-}" listener_v6="${7:-}"
    apply_jq_config "$inbounds_file" \
       --arg tag "$tag" --argjson port "$port" --arg method "$method" --arg key "$key" \
       --arg listener1 "$listener_v4_or_dual" --arg listener2 "$listener_v6" \
       'def inbound($inbound_tag; $listener): {
           "type": "shadowsocks",
           "tag": $inbound_tag,
           "listen": $listener,
           "listen_port": $port,
           "method": $method,
           "password": $key,
           "multiplex": {"enabled": true}
       };
       .inbounds += ([inbound($tag; $listener1)] +
           (if $listener2 == "" then [] else [inbound($tag + "-ipv6"; $listener2)] end))'
}

mutate_extra_protocol_inbound_remove() {
    local inbounds_file="$1" tag="$2"
    apply_jq_config "$inbounds_file" --arg tag "$tag" \
        'del(.inbounds[] | select(.tag == $tag or .tag == ($tag + "-ipv6")))'
}

# ---- Socks5 入站 ----
add_socks5_inbound() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="socks5-in"
    local listener1 listener2=''

    if proto_exists "$tag"; then
        yellow "Socks5 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 获取当前UUID用于自动填充
    local current_uuid
    current_uuid=$(get_current_uuid | tr -d '\n\r')

    local sk_port sk_public_port
    read_extra_protocol_ports Socks5 || return 1
    sk_port="$EXTRA_PROTOCOL_LISTEN_PORT"
    sk_public_port="$EXTRA_PROTOCOL_PUBLIC_PORT"

    reading "请输入 Socks5 用户名 (回车自动使用UUID前8位): " sk_user
    if [ -n "$sk_user" ]; then
        green "socks5用户名：${purple}${sk_user}${re}"
    else
        if [ -n "$current_uuid" ]; then
            sk_user=$(printf '%s' "${current_uuid:0:8}" | tr -d '\n\r')
            green "自动设置用户名: ${purple}${sk_user}${re}"
        else
            red "无法获取UUID，请手动输入用户名"
            reading "请输入 Socks5 用户名: " sk_user
            [ -z "$sk_user" ] && { red "用户名不能为空"; sleep 1; return; }
        fi
    fi

    reading "请输入 Socks5 密码 (回车自动使用UUID后12位): " sk_pass
    if [ -n "$sk_pass" ]; then
        green "socks5密码：${purple}${sk_pass}${re}"
    else
        if [ -n "$current_uuid" ]; then
            sk_pass=$(printf '%s' "${current_uuid: -12}" | tr -d '\n\r')
            green "自动设置密码: ${purple}${sk_pass}${re}"
        else
            red "无法获取UUID，请手动输入密码"
            reading "请输入 Socks5 密码: " sk_pass
            [ -z "$sk_pass" ] && { red "密码不能为空"; sleep 1; return; }
        fi
    fi

    resolve_extra_protocol_listeners || { red "未检测到可用的公网地址族，未修改配置。"; return 1; }
    listener1="${EXTRA_PROTOCOL_LISTENERS[0]}"
    [ "${#EXTRA_PROTOCOL_LISTENERS[@]}" -lt 2 ] || listener2="${EXTRA_PROTOCOL_LISTENERS[1]}"
    resolve_extra_protocol_server_host || { red "无法获取有效公网地址，未发布 Socks5 节点。"; return 1; }
    local server_ip="$EXTRA_PROTOCOL_SERVER_HOST"
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' \
        | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' \
        | sed 's/ /_/g' || echo "Socks5")

    local url_line="socks://$(printf '%s' "${sk_user}:${sk_pass}" | base64 -w0)@${server_ip}:${sk_public_port}#${isp}"
    local transaction_status=0

    add_extra_protocol_transaction "$inbounds_file" "$url_line" mutate_socks5_inbound_add \
        --families "$EXTRA_PROTOCOL_HAS_IPV4" "$EXTRA_PROTOCOL_HAS_IPV6" \
        "${sk_port}/tcp" "${sk_port}/udp" -- \
        "$tag" "$sk_port" "$sk_user" "$sk_pass" "$listener1" "$listener2" || \
        transaction_status=$?
    if [ "$transaction_status" -ne 0 ]; then
        [ "$transaction_status" -eq 2 ] && \
            red "Socks5 添加事务 fatal 中止；请按上方恢复路径人工处理。"
        return "$transaction_status"
    fi

    green "\nSocks5 协议已添加！"
    green "监听端口: ${purple}${sk_port}${re}  公网端口: ${purple}${sk_public_port}${re}"
    green "用户名: ${purple}${sk_user}${re}  ${green}密码:${re} ${purple}${sk_pass}${re}"
    green "节点链接: ${purple}${url_line}${re}\n"
    render_terminal_qr "$url_line"
}

remove_socks5_inbound() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="socks5-in"
    local sk_port transaction_status=0

    if ! proto_exists "$tag"; then
        yellow "Socks5 协议未添加，无需删除。"; sleep 1; return
    fi

    sk_port=$(jq -er --arg tag "$tag" '
        [.inbounds[] | select(.tag == $tag or .tag == ($tag + "-ipv6")) | .listen_port] |
        unique | if length == 1 then .[0] else error("inconsistent socks ports") end
    ' "$inbounds_file") || return 1
    validate_port_value "$sk_port" socks5_port || return 1
    remove_extra_protocol_transaction "$inbounds_file" socks mutate_extra_protocol_inbound_remove \
        "${sk_port}/tcp" "${sk_port}/udp" -- "$tag" || transaction_status=$?
    if [ "$transaction_status" -ne 0 ]; then
        [ "$transaction_status" -eq 2 ] && \
            red "Socks5 删除事务 fatal 中止；请按上方恢复路径人工处理。"
        return "$transaction_status"
    fi
    green "\nSocks5 协议已删除\n"
}

# ---- AnyTLS ----
add_anytls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="anytls"
    local listener1 listener2=''

    if proto_exists "$tag"; then
        yellow "AnyTLS 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 使用已安装协议的UUID作为密码
    local current_uuid
    current_uuid=$(get_current_uuid)
    if [ -z "$current_uuid" ]; then
        red "无法获取当前UUID，请确认 sing-box 已正确安装并配置。"; sleep 2; return
    fi

    local at_port at_public_port
    read_extra_protocol_ports AnyTLS || return 1
    at_port="$EXTRA_PROTOCOL_LISTEN_PORT"
    at_public_port="$EXTRA_PROTOCOL_PUBLIC_PORT"

    resolve_extra_protocol_listeners || { red "未检测到可用的公网地址族，未修改配置。"; return 1; }
    listener1="${EXTRA_PROTOCOL_LISTENERS[0]}"
    [ "${#EXTRA_PROTOCOL_LISTENERS[@]}" -lt 2 ] || listener2="${EXTRA_PROTOCOL_LISTENERS[1]}"
    resolve_extra_protocol_server_host || { red "无法获取有效公网地址，未发布 AnyTLS 节点。"; return 1; }
    local server_ip="$EXTRA_PROTOCOL_SERVER_HOST"
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' \
        | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' \
        | sed 's/ /_/g' || echo "AnyTLS")

    local url_line="anytls://${current_uuid}@${server_ip}:${at_public_port}?insecure=1&sni=bing.com#${isp}"
    local transaction_status=0

    add_extra_protocol_transaction "$inbounds_file" "$url_line" mutate_anytls_inbound_add \
        --families "$EXTRA_PROTOCOL_HAS_IPV4" "$EXTRA_PROTOCOL_HAS_IPV6" \
        "${at_port}/tcp" -- \
        "$tag" "$at_port" "$current_uuid" "${work_dir}/cert.pem" "${work_dir}/private.key" \
        "$listener1" "$listener2" || \
        transaction_status=$?
    if [ "$transaction_status" -ne 0 ]; then
        [ "$transaction_status" -eq 2 ] && \
            red "AnyTLS 添加事务 fatal 中止；请按上方恢复路径人工处理。"
        return "$transaction_status"
    fi

    green "\nAnyTLS 协议已添加！"
    green "密码(UUID): ${purple}${current_uuid}${re}"
    green "监听端口: ${purple}${at_port}${re}  公网端口: ${purple}${at_public_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
    render_terminal_qr "$url_line"
}

remove_anytls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="anytls"
    local at_port transaction_status=0

    if ! proto_exists "$tag"; then
        yellow "AnyTLS 协议未添加，无需删除。"; sleep 1; return
    fi

    at_port=$(jq -er --arg tag "$tag" '
        [.inbounds[] | select(.tag == $tag or .tag == ($tag + "-ipv6")) | .listen_port] |
        unique | if length == 1 then .[0] else error("inconsistent anytls ports") end
    ' "$inbounds_file") || return 1
    validate_port_value "$at_port" anytls_port || return 1
    remove_extra_protocol_transaction "$inbounds_file" anytls mutate_extra_protocol_inbound_remove \
        "${at_port}/tcp" -- "$tag" || transaction_status=$?
    if [ "$transaction_status" -ne 0 ]; then
        [ "$transaction_status" -eq 2 ] && \
            red "AnyTLS 删除事务 fatal 中止；请按上方恢复路径人工处理。"
        return "$transaction_status"
    fi
    green "\nAnyTLS 协议已删除\n"
}

# ---- Shadowsocks-2022 ----
add_ss2022() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="shadowsocks-2022"
    local listener1 listener2=''

    if proto_exists "$tag"; then
        yellow "Shadowsocks-2022 协议已存在，无需重复添加。"; sleep 1; return
    fi

    local ss_port ss_public_port
    read_extra_protocol_ports Shadowsocks-2022 || return 1
    ss_port="$EXTRA_PROTOCOL_LISTEN_PORT"
    ss_public_port="$EXTRA_PROTOCOL_PUBLIC_PORT"

    echo ""
    green "请选择加密方式:"
    green "1. 2022-blake3-aes-128-gcm       (推荐，密钥16字节)"
    green "2. 2022-blake3-aes-256-gcm       (密钥32字节)"
    green "3. 2022-blake3-chacha20-poly1305 (密钥32字节)"
    reading "请输入选择 (默认1): " ss_method_choice
    local ss_method key_len
    case "${ss_method_choice}" in
        2) ss_method="2022-blake3-aes-256-gcm";        key_len=32 ;;
        3) ss_method="2022-blake3-chacha20-poly1305";   key_len=32 ;;
        *) ss_method="2022-blake3-aes-128-gcm";         key_len=16 ;;
    esac
    green "加密方式为：${purple}${ss_method}${re}"
    local ss_key
    ss_key=$(dd if=/dev/urandom bs=1 count=${key_len} 2>/dev/null | base64 -w0)

    resolve_extra_protocol_listeners || { red "未检测到可用的公网地址族，未修改配置。"; return 1; }
    listener1="${EXTRA_PROTOCOL_LISTENERS[0]}"
    [ "${#EXTRA_PROTOCOL_LISTENERS[@]}" -lt 2 ] || listener2="${EXTRA_PROTOCOL_LISTENERS[1]}"
    resolve_extra_protocol_server_host || { red "无法获取有效公网地址，未发布 Shadowsocks-2022 节点。"; return 1; }
    local server_ip="$EXTRA_PROTOCOL_SERVER_HOST"
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' \
        | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' \
        | sed 's/ /_/g' || echo "SS2022")

    local ss_userinfo
    ss_userinfo=$(printf '%s:%s' "${ss_method}" "${ss_key}" | base64 -w0)
    local url_line="ss://${ss_userinfo}@${server_ip}:${ss_public_port}#${isp}"
    local transaction_status=0

    add_extra_protocol_transaction "$inbounds_file" "$url_line" mutate_ss2022_inbound_add \
        --families "$EXTRA_PROTOCOL_HAS_IPV4" "$EXTRA_PROTOCOL_HAS_IPV6" \
        "${ss_port}/tcp" "${ss_port}/udp" -- \
        "$tag" "$ss_port" "$ss_method" "$ss_key" "$listener1" "$listener2" || \
        transaction_status=$?
    if [ "$transaction_status" -ne 0 ]; then
        [ "$transaction_status" -eq 2 ] && \
            red "Shadowsocks-2022 添加事务 fatal 中止；请按上方恢复路径人工处理。"
        return "$transaction_status"
    fi

    green "\nShadowsocks-2022 协议已添加！"
    green "加密方式: ${purple}${ss_method}${re}"
    green "密钥(base64): ${purple}${ss_key}${re}"
    green "监听端口: ${purple}${ss_port}${re}  公网端口: ${purple}${ss_public_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
    render_terminal_qr "$url_line"
}

remove_ss2022() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="shadowsocks-2022"
    local ss_port transaction_status=0

    if ! proto_exists "$tag"; then
        yellow "Shadowsocks-2022 协议未添加，无需删除。"; sleep 1; return
    fi

    ss_port=$(jq -er --arg tag "$tag" '
        [.inbounds[] | select(.tag == $tag or .tag == ($tag + "-ipv6")) | .listen_port] |
        unique | if length == 1 then .[0] else error("inconsistent shadowsocks ports") end
    ' "$inbounds_file") || return 1
    validate_port_value "$ss_port" ss2022_port || return 1
    remove_extra_protocol_transaction "$inbounds_file" ss mutate_extra_protocol_inbound_remove \
        "${ss_port}/tcp" "${ss_port}/udp" -- "$tag" || transaction_status=$?
    if [ "$transaction_status" -ne 0 ]; then
        [ "$transaction_status" -eq 2 ] && \
            red "Shadowsocks-2022 删除事务 fatal 中止；请按上方恢复路径人工处理。"
        return "$transaction_status"
    fi
    green "\nShadowsocks-2022 协议已删除\n"
}

# 显示当前已启用的额外协议状态
show_extra_proto_status() {
    local inbounds_file="${conf_dir}/inbounds.json"
    echo ""
    green "--- 额外协议状态 ---"

    # Socks5
    if jq -e '.inbounds[] | select(.tag == "socks5-in")' "$inbounds_file" > /dev/null 2>&1; then
        local sk_port sk_user
        sk_port=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .listen_port' "$inbounds_file")
        sk_user=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].username // "N/A"' "$inbounds_file")
        sk_pass=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].password // "N/A"' "$inbounds_file")
        echo -e " Socks5:           ${green}已启用${re} (端口: ${skyblue}${sk_port}${re}, 用户名: ${skyblue}${sk_user}${re}，密码：${skyblue}${sk_pass}${re})"
    else
        echo -e " Socks5:           ${yellow}未启用${re}"
    fi

    # AnyTLS
    if jq -e '.inbounds[] | select(.tag == "anytls")' "$inbounds_file" > /dev/null 2>&1; then
        local at_port at_pass
        at_port=$(jq -r '.inbounds[] | select(.tag == "anytls") | .listen_port' "$inbounds_file")
        at_pass=$(jq -r '.inbounds[] | select(.tag == "anytls") | .users[0].password // "N/A"' "$inbounds_file")
        echo -e " AnyTLS:           ${green}已启用${re} (端口: ${skyblue}${at_port}${re}, 密码: ${skyblue}${at_pass}${re})"
    else
        echo -e " AnyTLS:           ${yellow}未启用${re}"
    fi

    # Shadowsocks-2022
    if jq -e '.inbounds[] | select(.tag == "shadowsocks-2022")' "$inbounds_file" > /dev/null 2>&1; then
        local ss_port ss_method
        ss_port=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .listen_port' "$inbounds_file")
        ss_method=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .method' "$inbounds_file")
        echo -e " Shadowsocks-2022: ${green}已启用${re} (端口: ${skyblue}${ss_port}${re}, 加密: ${skyblue}${ss_method}${re})"
    else
        echo -e " Shadowsocks-2022: ${yellow}未启用${re}"
    fi
    echo ""
}

# 协议管理主菜单
manage_protocols() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; menu; return
    fi

    clear; echo ""
    green "=== 协议管理 (增加/删除) ===\n"
    show_extra_proto_status

    green "--- Socks5 协议 ---"
    green "1. 添加 Socks5 协议"
    red   "2. 删除 Socks5 协议"
    skyblue "-----------------------------"
    green "--- AnyTLS 协议 ---"
    green "3. 添加 AnyTLS 协议"
    red   "4. 删除 AnyTLS 协议"
    skyblue "-----------------------------"
    green "--- Shadowsocks-2022 协议 ---"
    green "5. 添加 Shadowsocks-2022 协议"
    red   "6. 删除 Shadowsocks-2022 协议"
    skyblue "-----------------------------"
    purple "0. 返回主菜单"
    skyblue "-----------------------------"
    reading "请输入选择: " proto_choice
    echo ""
    case "${proto_choice}" in
        1) add_socks5_inbound ;;
        2) remove_socks5_inbound ;;
        3) add_anytls ;;
        4) remove_anytls ;;
        5) add_ss2022 ;;
        6) remove_ss2022 ;;
        0) menu; return ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回协议管理菜单...\033[0m\n'
    manage_protocols
}

# 可测试的命令行参数分发
dispatch_cli_action() {
    local action="${1:-}"
    local service_file="${2:-}"

    case "$action" in
        -i|--install) auto_install ;;
        --update|--upgrade) update_shortcut ;;
        -u|--uninstall)
            auto_uninstall
            ;;
        --purge-nginx)
            PURGE_NGINX=1
            auto_uninstall
            ;;
        -c|--check)
            check_nodes
            ;;
        -r|--restart) refresh_quick_argo "$service_file" ;;
        -h|--help)
            echo ""
            green "用法: [sb或脚本] [参数], 示例: sb -c(查看节点信息)"
            echo ""
            green "  -i, --install     无交互安装sing-box"
            green "      --update      显式更新本地 sb 管理脚本，不修改已有节点"
            green "  -c, --check       查看节点信息和订阅链接"
            green "  -r, --restart     重新获取argo临时隧道并更新到订阅"
            green "  -u, --uninstall   uninstall sing-box and keep nginx"
            green "      --purge-nginx  uninstall sing-box and remove nginx"
            green "  -h, --help        显示此帮助信息"
            echo ""
            green "  不带参数          进入交互式主菜单"
            echo ""
            ;;
        *)
            red "未知参数: $action"
            echo ""
            green "用法: sb [参数],相关参数:[-i|-u|-c|-r|-h], 首次安装：bash脚本 -i(前面可带环境变量)"
            return 1
            ;;
    esac
}

# 主菜单
menu() {
    singbox_status=$(check_singbox 2>/dev/null)
    nginx_status=$(check_nginx 2>/dev/null)
    argo_status=$(check_argo 2>/dev/null)
    warp_status=$(get_warp_menu_status 2>/dev/null || echo degraded)

    clear; echo ""
    green "Telegram群组: ${purple}https://t.me/eooceu${re}"
    green "YouTube频道: ${purple}https://youtube.com/@eooce${re}"
    green "Github地址: ${purple}https://github.com/eooce/sing-box${re}\n"
    purple "=== 老王sing-box四合一安装脚本 ===\n"
    purple "---Argo 状态: ${argo_status}"
    purple "---WARP 状态: ${warp_status}"
    purple "--Nginx 状态: ${nginx_status}"
    purple "singbox 状态: ${singbox_status}\n"
    green "1. 安装sing-box"
    red   "2. 卸载sing-box"
    echo "==============="
    green "3. sing-box管理"
    green "4. Argo隧道管理"
    echo "==============="
    green "5. 查看节点信息"
    green "6. 修改节点配置"
    green "7. 管理节点订阅"
    green "8. WARP分流管理"
    echo "==============="
    green "9. 增加/删除协议"
    echo "==============="
    purple "10. ssh综合工具箱"
    echo "==============="
    red "0. 退出脚本"
    echo "==========="
    # ← 去掉 reading，只负责显示
}

# Harden legacy installations before any management action can expose or
# rewrite credential-bearing configuration.
harden_runtime_secret_permissions || {
    red "无法收紧 sing-box 凭据文件权限，操作中止。"
    exit 1
}

# 捕获 Ctrl+C
trap 'stop_warp_candidate_proxy 2>/dev/null || true; red "\n强制退出"; exit' INT TERM

# ---- 参数解析入口 ----
if [ -n "${1:-}" ]; then
    dispatch_cli_action "$1"
    exit $?
else
    # 无参数：进入交互式主菜单
    while true; do
            menu
            reading "请输入选择(0-10): " choice
            echo ""
            need_pause=true
            case "${choice}" in
                1)
                    interactive_install
                    ;;
                2)  uninstall_singbox;  need_pause=false ;;
                3)  manage_singbox;     need_pause=false ;;
                4)  manage_argo;        need_pause=true ;;
                5)  check_nodes;        need_pause=true ;;
                6)  change_config;      need_pause=true ;;
                7)  disable_open_sub;   need_pause=true ;;
                8)  warp_manage;        need_pause=false ;;
                9)  manage_protocols;   need_pause=false ;;
                10)
                    clear
                    bash <(curl -Ls ssh_tool.eooce.com)
                    need_pause=false
                    ;;
                0)  exit 0 ;;
                *)
                    red "无效的选项，请输入 0-10"
                    need_pause=true
                    ;;
            esac
            [ "$need_pause" = true ] && read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
    done
fi
