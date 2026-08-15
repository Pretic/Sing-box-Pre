#!/bin/bash

# =========================
# 老王sing-box四合一安装脚本
# vless-version-reality|vless-ws-tls(tunnel)|hysteria2|tuic5|[可额外添加Anytls，socks5，ss2022等协议]
# 最后更新时间: 2026.8.15[修复WARP共享身份冲突与空闲失活]
# =========================

export LANG=en_US.UTF-8
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

# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
combined_client_dir="${work_dir}/all-url.txt"
export vless_port=${PORT:-$(shuf -i 1000-65000 -n 1)}
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

is_valid_subscription_token() {
    [[ "${1:-}" =~ ^[0123456789abcdefghjkmnpqrstvwxyz]{32}$ ]]
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
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    action=$1
    shift

    # 首次安装更新系统
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在更新系统软件包...\n"
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y && DEBIAN_FRONTEND=noninteractive apt upgrade -y
        elif command_exists dnf; then
            dnf update -y
        elif command_exists yum; then
            yum update -y
        elif command_exists apk; then
            apk update && apk upgrade
        else
            yellow "Unknown system!\n"
        fi
        green "finished updated system\n"
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk add "$package"
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
    elif grep -Eq -- 'tunnel[^[:cntrl:]]*(run[[:space:]]+)?--token[[:space:]]+[^[:space:]]+' "$service_file"; then
        printf 'remote\n'
    else
        return 1
    fi
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
    local tmp_file public_path

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
        cp -p "$backup_file" "$tunnel_config"
        restart_argo > /dev/null 2>&1 || true
        return 1
    fi
}

apply_local_tunnel_subscription_removal() {
    local tunnel_config="${1:-${work_dir}/tunnel.yml}"
    local backup_file="${tunnel_config}.bak.subscription-removal"
    local tmp_file

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
        cp -p "$backup_file" "$tunnel_config"
        restart_argo > /dev/null 2>&1 || true
        return 1
    fi
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
    local action record_id body_file

    [ -r "$plan_file" ] && [ -n "$response_file" ] || return 1
    action=$("$jq_bin" -r '.action' "$plan_file") || return 1
    case "$action" in
        create)
            [ -n "$new_record_id" ] || return 1
            cloudflare_api DELETE \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${new_record_id}" \
                > "$response_file" 2>/dev/null
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
            local rc=$?
            rm -f "$body_file"
            return "$rc"
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
    local tmp_dir get_response old_config new_config put_body put_response
    local dns_response dns_records dns_plan dns_body dns_apply_response dns_action
    local new_record_id='' remote_updated=0 dns_changed=0 operation_ok=0

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

    tmp_dir=$(mktemp -d "${work_dir}/.cf-subscription.XXXXXX") || { unset CF_API_TOKEN; return 1; }
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
        cloudflare_api PUT \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
            "$put_body" > "$put_response" 2>/dev/null || break
        "$jq_bin" -e '.success == true' "$put_response" > /dev/null || break
        remote_updated=1

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
        if [ "$dns_changed" = 1 ]; then
            rollback_cloudflare_dns_change "$zone_id" "$dns_plan" "$new_record_id" \
                "${tmp_dir}/dns-rollback-response.json" || true
        fi
        if [ "$remote_updated" = 1 ]; then
            rollback_remote_tunnel_configuration "$account_id" "$tunnel_id" "$old_config" \
                "${tmp_dir}/tunnel-rollback-response.json" || true
        fi
    fi

    unset CF_API_TOKEN
    rm -rf "$tmp_dir"
    [ "$operation_ok" = 1 ]
}

remove_remote_tunnel_subscription_via_api() {
    local domain="${1:-}"
    local path_regex="${2:-}"
    local jq_bin="${JQ_BIN:-jq}"
    local account_id tunnel_id CF_API_TOKEN tmp_dir get_response old_config
    local new_config put_body put_response operation_ok=0 remote_updated=0

    is_valid_subscription_domain "$domain" || return 1
    is_valid_tunnel_subscription_regex "$path_regex" || return 1
    reading "请输入 Cloudflare Account ID: " account_id
    reading "请输入 Cloudflare Tunnel ID: " tunnel_id
    [[ "$account_id" =~ ^[A-Fa-f0-9]{32}$ ]] || { red "Account ID 格式无效"; return 1; }
    [[ "$tunnel_id" =~ ^[A-Za-z0-9-]{16,128}$ ]] || { red "Tunnel ID 格式无效"; return 1; }
    read -r -s -p "$(red '请输入 Cloudflare API token（输入不会显示）: ')" CF_API_TOKEN
    echo ""
    [[ "$CF_API_TOKEN" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || { unset CF_API_TOKEN; return 1; }

    tmp_dir=$(mktemp -d "${work_dir}/.cf-subscription-remove.XXXXXX") || { unset CF_API_TOKEN; return 1; }
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
        cloudflare_api PUT \
            "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
            "$put_body" > "$put_response" 2>/dev/null || break
        "$jq_bin" -e '.success == true' "$put_response" > /dev/null || break
        remote_updated=1
        operation_ok=1
        break
    done

    if [ "$operation_ok" != 1 ] && [ "$remote_updated" = 1 ]; then
        rollback_remote_tunnel_configuration "$account_id" "$tunnel_id" "$old_config" \
            "${tmp_dir}/rollback-response.json" || true
    fi
    unset CF_API_TOKEN
    rm -rf "$tmp_dir"
    [ "$operation_ok" = 1 ]
}

# 处理防火墙
allow_port() {
    has_ufw=0
    has_firewalld=0
    has_iptables=0
    has_ip6tables=0

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --zone=public --set-target=ACCEPT >/dev/null 2>&1
    [ "$has_iptables" -eq 1 ] && {
        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i lo -j ACCEPT
        iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p icmp -j ACCEPT
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    }
    [ "$has_ip6tables" -eq 1 ] && {
        ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT 3 -i lo -j ACCEPT
        ip6tables -C INPUT -p icmp -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p icmp -j ACCEPT
        ip6tables -P FORWARD DROP 2>/dev/null || true
        ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    }

    for rule in "$@"; do
        port=${rule%/*}
        proto=${rule#*/}
        [ "$has_ufw" -eq 1 ] && ufw allow in ${port}/${proto} >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        [ "$has_iptables" -eq 1 ] && (iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT)
        [ "$has_ip6tables" -eq 1 ] && (ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT)
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1

    if command_exists rc-service 2>/dev/null; then
        [ "$has_iptables" -eq 1 ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null
        [ "$has_ip6tables" -eq 1 ] && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    else
        if ! command_exists netfilter-persistent; then
            manage_packages install iptables-persistent || yellow "请手动安装netfilter-persistent或保存iptables规则"
            netfilter-persistent save >/dev/null 2>&1
        elif command_exists service; then
            service iptables save 2>/dev/null
            service ip6tables save 2>/dev/null
        fi
    fi
}

# 下载并安装 sing-box,cloudflared
install_singbox() {
    clear
    purple "正在安装sing-box中，请稍后..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64')  ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l')  ARCH='armv7' ;;
        's390x')   ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    mkdir -p "${work_dir}" "${conf_dir}"
    chmod 755 "${work_dir}"
    # latest_version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | jq -r '[.[] | select(.prerelease==false)][0].tag_name | sub("^v"; "")')
    # curl -sLo "${work_dir}/${server_name}.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/sing-box-${latest_version}-linux-${ARCH}.tar.gz"
    # curl -sLo "${work_dir}/qrencode" "https://github.com/eooce/test/releases/download/${ARCH}/qrencode-linux-${ARCH}"
    download_binary "https://$ARCH.ssss.nyc.mn/qrencode" "${work_dir}/qrencode" || exit 1
    download_binary "https://$ARCH.ssss.nyc.mn/sbx-1.13.13" "${work_dir}/sing-box" || exit 1
    download_binary "https://$ARCH.ssss.nyc.mn/bot" "${work_dir}/argo" || exit 1
    # tar -xzvf "${work_dir}/${server_name}.tar.gz" -C "${work_dir}/" && \
    # mv "${work_dir}/sing-box-${latest_version}-linux-${ARCH}/sing-box" "${work_dir}/" && \
    # rm -rf "${work_dir}/${server_name}.tar.gz" "${work_dir}/sing-box-${latest_version}-linux-${ARCH}"
    chown root:root "${work_dir}"

    nginx_port=$(($vless_port + 1))
    tuic_port=$(($vless_port + 2))
    hy2_port=$(($vless_port + 3))
    uuid=$(cat /proc/sys/kernel/random/uuid)
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
    output=$(/etc/sing-box/sing-box generate reality-keypair)
    private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')

    allow_port $vless_port/tcp $nginx_port/tcp $tuic_port/udp $hy2_port/udp > /dev/null 2>&1

    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"
    chmod 600 "${work_dir}/private.key" 2>/dev/null || true

    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')

    dns_strategy=$(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || \
        (ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))

    cat > "${conf_dir}/log.json" << EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  }
}
EOF

    cat > ${conf_dir}/ntp.json << EOF
{
    "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
    }
}
EOF

    cat > "${conf_dir}/dns.json" << EOF
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

    cat > "${conf_dir}/inbounds.json" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
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
    },
    {
      "type": "vless",
      "tag": "vless-ws-argo",
      "listen": "127.0.0.1",
      "listen_port": ${ARGO_PORT},
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless-argo"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
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
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
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
  ]
}
EOF

    cat > "${conf_dir}/outbounds.json" << EOF
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    cat > "${conf_dir}/endpoints.json" << EOF
{
  "endpoints": []
}
EOF

    cat > "${conf_dir}/route.json" << EOF
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
}

# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
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

    local argo_exec=""
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
                echo "$ARGO_AUTH" > "${work_dir}/tunnel.json"
                cat > "${work_dir}/tunnel.yml" << EOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://127.0.0.1:${ARGO_PORT}
  - service: http_status:404
EOF
                argo_exec="ExecStart=/bin/sh -c \"/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run > /etc/sing-box/argo.log 2>&1\""
                ARGO_FIXED_READY=1
            else
                yellow "ARGO_AUTH 未解析到 TunnelID，改用临时 Argo 隧道"
            fi
        elif is_argo_tunnel_token "$ARGO_AUTH"; then
            argo_exec="ExecStart=/bin/sh -c \"/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH} > /etc/sing-box/argo.log 2>&1\""
            ARGO_FIXED_READY=1
        else
            yellow "ARGO_AUTH 格式不匹配，改用临时 Argo 隧道"
        fi
    fi
    if [ -z "$argo_exec" ]; then
        if [ "$fixed_argo_requested" -eq 1 ]; then
            use_quick_argo_fallback
            yellow "固定 Argo 隧道配置未生效，已改用临时 Argo 隧道"
        fi
        argo_exec="ExecStart=/bin/sh -c \"/etc/sing-box/argo tunnel --url http://127.0.0.1:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1\""
    fi

    cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
${argo_exec}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl enable argo
    systemctl start argo
}

# 适配alpine 守护进程
alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    local argo_command_args=""
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
                echo "$ARGO_AUTH" > "${work_dir}/tunnel.json"
                cat > "${work_dir}/tunnel.yml" << EOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://127.0.0.1:${ARGO_PORT}
  - service: http_status:404
EOF
                argo_command_args="-c '/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run > /etc/sing-box/argo.log 2>&1'"
                ARGO_FIXED_READY=1
            else
                yellow "ARGO_AUTH 未解析到 TunnelID，改用临时 Argo 隧道"
            fi
        elif is_argo_tunnel_token "$ARGO_AUTH"; then
            argo_command_args="-c '/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH} > /etc/sing-box/argo.log 2>&1'"
            ARGO_FIXED_READY=1
        else
            yellow "ARGO_AUTH 格式不匹配，改用临时 Argo 隧道"
        fi
    fi
    if [ -z "$argo_command_args" ]; then
        if [ "$fixed_argo_requested" -eq 1 ]; then
            use_quick_argo_fallback
            yellow "固定 Argo 隧道配置未生效，已改用临时 Argo 隧道"
        fi
        argo_command_args="-c '/etc/sing-box/argo tunnel --url http://127.0.0.1:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1'"
    fi

    cat > /etc/init.d/argo << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="${argo_command_args}"
command_background=true
pidfile="/var/run/argo.pid"
EOF
    chmod +x /etc/init.d/sing-box
    chmod +x /etc/init.d/argo
    rc-update add sing-box default > /dev/null 2>&1
    rc-update add argo default     > /dev/null 2>&1
}

# 生成节点和订阅链接
get_info() {
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

    : > ${work_dir}/url.txt
    if [ -n "$server_ipv4" ]; then
        cat >> ${work_dir}/url.txt << EOF
vless://${uuid}@${server_ipv4}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&type=tcp&headerType=none#${reality_v4_name}
EOF
    fi

    if [ -n "$server_ipv6" ]; then
        [ -s "${work_dir}/url.txt" ] && echo "" >> "${work_dir}/url.txt"
        cat >> ${work_dir}/url.txt << EOF
vless://${uuid}@${server_ipv6}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.iij.ad.jp&fp=firefox&pbk=${public_key}&type=tcp&headerType=none#${reality_v6_name}
EOF
    fi

    if [ -n "$argodomain" ]; then
        while IFS=$'\t' read -r argo_client_address argo_address_role; do
            [ -n "$argo_client_address" ] || continue
            argo_client_name="$argo_name"
            if [ "$argo_address_role" = "preferred" ]; then
                argo_client_name="${argo_name}-preferred"
            fi
            [ -s "${work_dir}/url.txt" ] && echo "" >> "${work_dir}/url.txt"
            cat >> ${work_dir}/url.txt << EOF
vless://${uuid}@${argo_client_address}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo#${argo_client_name}
EOF
        done < <(list_argo_client_addresses "$CFIP" "$argodomain" "$ARGO_FIXED_READY")
    fi

    if [ "${INCLUDE_UDP_LINKS}" = "1" ]; then
        cat >> ${work_dir}/url.txt << EOF

hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none#${isp}

tuic://${uuid}:${uuid}@${server_ip}:${tuic_port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${isp}
EOF
    fi

    if [ -n "$extra_lines" ]; then
        echo "" >> "${work_dir}/url.txt"
        echo "$extra_lines" >> "${work_dir}/url.txt"
    fi

    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt
    update_sub
    chmod 644 ${work_dir}/sub.txt
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

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
    is_valid_http_subscription_path "$http_path" || return 1
    if [ -n "$https_path" ]; then
        is_valid_subscription_path "$https_path" || return 1
    fi

    cat << EOF
server {
    listen ${port};
    listen [::]:${port};
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
    local config_file="${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}"
    local config_dir tmp_file backup_file had_config=0

    command_exists nginx || { red "nginx未安装，无法配置订阅服务"; return 1; }
    config_dir=$(dirname "$config_file")
    mkdir -p "$config_dir" || return 1
    tmp_file=$(mktemp "${config_dir}/.sing-box.conf.XXXXXX") || return 1
    backup_file="${config_file}.bak.sb"

    if ! render_nginx_subscription_server "$port" "$http_path" "$https_path" > "$tmp_file"; then
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

    if command_exists rc-service; then
        if ! rc-service nginx reload > /dev/null 2>&1 && ! rc-service nginx restart > /dev/null 2>&1; then
            if [ "$had_config" = 1 ]; then
                cp -p "$backup_file" "$config_file"
            else
                rm -f "$config_file"
            fi
            rc-service nginx restart > /dev/null 2>&1 || true
            return 1
        fi
    elif ! nginx -s reload > /dev/null 2>&1 && ! start_nginx > /dev/null 2>&1; then
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

add_nginx_conf() {
    local http_end_line

    command_exists nginx || { red "nginx未安装，无法配置订阅服务"; return 1; }
    mkdir -p /etc/nginx/conf.d

    if [ -f "/etc/nginx/nginx.conf" ]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.sb > /dev/null 2>&1
        chmod 600 /etc/nginx/nginx.conf.bak.sb 2>/dev/null || true
        sed -i -e '15{/include \/etc\/nginx\/modules\/\*\.conf/d;}' \
               -e '18{/include \/etc\/nginx\/conf\.d\/\*\.conf/d;}' /etc/nginx/nginx.conf > /dev/null 2>&1
        if ! grep -q "include.*conf.d" /etc/nginx/nginx.conf; then
            http_end_line=$(grep -n "^}" /etc/nginx/nginx.conf | tail -1 | cut -d: -f1)
            [ -n "$http_end_line" ] && sed -i "${http_end_line}i \    include /etc/nginx/conf.d/*.conf;" /etc/nginx/nginx.conf > /dev/null 2>&1
        fi
    else
        cat > /etc/nginx/nginx.conf << 'EOF'
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
    include /etc/nginx/conf.d/*.conf;
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

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"; return 1
    fi

    local status=$(check_service "$service_name" 2>/dev/null)

    case "$action" in
        "start")
            [ "$status" == "running" ] && { yellow "${service_name} 正在运行\n"; return 0; }
            [ "$status" == "not installed" ] && { yellow "${service_name} 尚未安装!\n"; return 1; }
            yellow "正在启动 ${service_name} 服务\n"
            if command_exists rc-service; then rc-service "$service_name" start
            elif command_exists systemctl; then systemctl daemon-reload && systemctl start "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 服务已成功启动\n" || red "${service_name} 服务启动失败\n"
            ;;
        "stop")
            [ "$status" == "not installed" ] && { yellow "${service_name} 尚未安装！\n"; return 2; }
            [ "$status" == "not running" ]   && { yellow "${service_name} 未运行\n"; return 1; }
            yellow "正在停止 ${service_name} 服务\n"
            if command_exists rc-service; then rc-service "$service_name" stop
            elif command_exists systemctl; then systemctl stop "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 服务已成功停止\n" || red "${service_name} 服务停止失败\n"
            ;;
        "restart")
            [ "$status" == "not installed" ] && { yellow "${service_name} 尚未安装！\n"; return 1; }
            yellow "正在重启 ${service_name} 服务\n"
            if command_exists rc-service; then rc-service "$service_name" restart
            elif command_exists systemctl; then systemctl daemon-reload && systemctl restart "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 服务已成功重启\n" || red "${service_name} 服务重启失败\n"
            ;;
        *)
            red "无效的操作: $action\n"; return 1 ;;
    esac
}
start_singbox()  { manage_service "sing-box" "start"; }
stop_singbox()   { manage_service "sing-box" "stop"; }
restart_singbox(){ manage_service "sing-box" "restart"; }
start_argo()     { manage_service "argo" "start"; }
stop_argo()      { manage_service "argo" "stop"; }
restart_argo()   { manage_service "argo" "restart"; }
start_nginx()    { manage_service "nginx" "start"; }
restart_nginx()  { manage_service "nginx" "restart"; }

validate_singbox_config() {
    [ -x "${work_dir}/${server_name}" ] || return 0
    [ -d "${conf_dir}" ] || return 0
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

purge_nginx_package() {
    local package="nginx"
    manage_packages uninstall "$package"
}

# 卸载 sing-box（交互式）
uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载 sing-box"
            if command_exists rc-service; then
                rc-service sing-box stop; rc-service argo stop
                rm -f /etc/init.d/sing-box /etc/init.d/argo
                rc-update del sing-box default; rc-update del argo default
            else
                systemctl stop "${server_name}"; systemctl stop argo
                systemctl disable "${server_name}"; systemctl disable argo
                systemctl daemon-reload || true
            fi
            rm -rf "${work_dir}" || true
            rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
            rm -f /etc/nginx/conf.d/sing-box.conf

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

# 创建快捷指令
create_shortcut() {
    [ ! -d "$work_dir" ] && mkdir -p "$work_dir"
    cat > "$work_dir/sb.sh" << 'EOF'
#!/usr/bin/env bash
exec bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) "$@"
EOF
    chmod +x "$work_dir/sb.sh"
    mkdir -p /usr/local/bin /usr/bin
    ln -sf "$work_dir/sb.sh" /usr/local/bin/sb
    ln -sf "$work_dir/sb.sh" /usr/bin/sb
    [ ! -e /usr/local/bin/sing-box ] && ln -sf "$work_dir/sb.sh" /usr/local/bin/sing-box
    if [ -s /usr/local/bin/sb ] || [ -s /usr/bin/sb ]; then
        green "\n快捷指令 sb 创建成功\n"
    else
        red "\n快捷指令创建失败\n"
    fi
}

update_shortcut() {
    create_shortcut
    green "已更新 sb 快捷命令；不会修改已有节点、订阅、端口或服务配置。\n"
}

# 适配alpine
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# 非交互静默安装（-i 参数）
auto_install() {
    check_singbox &>/dev/null
    if [ $? -eq 0 ]; then
        yellow "sing-box 已经安装，跳过安装流程。"
        exit 0
    fi

    green "Starting non-interactive sing-box install..."
    manage_packages install nginx jq tar openssl lsof coreutils
    install_singbox

    if command_exists systemctl; then
        main_systemd_services
    elif command_exists rc-update; then
        alpine_openrc_services
        change_hosts
        rc-service sing-box restart
        rc-service argo restart
    else
        red "不支持的 init 系统，安装中止。"
        exit 1
    fi

    sleep 5
    add_nginx_conf
    get_info
    create_shortcut
    green "\nsing-box 安装完成\n"
}

# Non-interactive uninstall (-u); keeps nginx unless PURGE_NGINX=1 or --purge-nginx is used.
auto_uninstall() {
    green "Starting non-interactive sing-box uninstall..."

    if command_exists rc-service; then
        rc-service sing-box stop  > /dev/null 2>&1
        rc-service argo stop      > /dev/null 2>&1
        rc-update del sing-box default > /dev/null 2>&1
        rc-update del argo default     > /dev/null 2>&1
        rm -f /etc/init.d/sing-box /etc/init.d/argo
    elif command_exists systemctl; then
        systemctl stop    sing-box > /dev/null 2>&1
        systemctl stop    argo     > /dev/null 2>&1
        systemctl disable sing-box > /dev/null 2>&1
        systemctl disable argo     > /dev/null 2>&1
        systemctl daemon-reload    > /dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service \
              /etc/systemd/system/argo.service
    fi

    rm -rf "${work_dir}"
    rm -f /usr/bin/sb /usr/local/bin/sb
    if [ -L /usr/local/bin/sing-box ] && [ "$(readlink /usr/local/bin/sing-box 2>/dev/null)" = "${work_dir}/sb.sh" ]; then
        rm -f /usr/local/bin/sing-box
    fi

    rm -f /etc/nginx/conf.d/sing-box.conf
    [ -f /etc/nginx/nginx.conf.bak.sb ] && \
        mv /etc/nginx/nginx.conf.bak.sb /etc/nginx/nginx.conf > /dev/null 2>&1

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
                    apply_jq_config "$inbounds_file" --arg port "$new_port" \
                       '(.inbounds[] | select(.tag == "vless-reality").listen_port) = ($port | tonumber)' || return
                    restart_singbox
                    allow_port $new_port/tcp > /dev/null 2>&1
                    sed -i '/flow=xtls-rprx-vision/ s/\(vless:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    update_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nvless-reality端口已修改成：${purple}$new_port${re}\n"
                    ;;
                2)
                    reading "\n请输入hysteria2端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    apply_jq_config "$inbounds_file" --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "hysteria2").listen_port) = ($port | tonumber)' || return
                    restart_singbox
                    allow_port $new_port/udp > /dev/null 2>&1
                    sed -i 's/\(hysteria2:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    update_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nhysteria2端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                3)
                    reading "\n请输入tuic端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    apply_jq_config "$inbounds_file" --arg port "$new_port" \
                       '(.inbounds[] | select(.type == "tuic").listen_port) = ($port | tonumber)' || return
                    restart_singbox
                    allow_port $new_port/udp > /dev/null 2>&1
                    sed -i 's/\(tuic:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
                    update_sub
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
            listen_port=$(jq -r '.inbounds[] | select(.type == "hysteria2").listen_port' "${conf_dir}/inbounds.json")
            iptables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            command -v ip6tables &> /dev/null && ip6tables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            if command_exists rc-service 2>/dev/null; then
                iptables-save > /etc/iptables/rules.v4
                command -v ip6tables &> /dev/null && ip6tables-save > /etc/iptables/rules.v6
                cat << 'IEOF' > /etc/init.d/iptables
#!/sbin/openrc-run
depend() { need net; }
start() {
    [ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
    command -v ip6tables &> /dev/null && [ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6
}
IEOF
                chmod +x /etc/init.d/iptables && rc-update add iptables default && /etc/init.d/iptables start
            elif [ -f /etc/debian_version ]; then
                DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent > /dev/null 2>&1 && netfilter-persistent save > /dev/null 2>&1
                systemctl enable netfilter-persistent > /dev/null 2>&1 && systemctl start netfilter-persistent > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                manage_packages install iptables-services > /dev/null 2>&1 && service iptables save > /dev/null 2>&1
                systemctl enable iptables > /dev/null 2>&1 && systemctl start iptables > /dev/null 2>&1
                command -v ip6tables &> /dev/null && service ip6tables save > /dev/null 2>&1
                systemctl enable ip6tables > /dev/null 2>&1 && systemctl start ip6tables > /dev/null 2>&1
            fi
            restart_singbox
            ip=$(get_realip)
            fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')
            uuid=$(sed -n 's/.*hysteria2:\/\/\([^@]*\)@.*/\1/p' $client_dir)
            line_number=$(grep -n 'hysteria2://' $client_dir | cut -d':' -f1)
            isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | \
                awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || echo "$hostname")
            sed -i.bak "/hysteria2:/d" $client_dir
            sed -i "${line_number}i hysteria2://$uuid@$ip:$listen_port?peer=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none&mport=$listen_port,$min_port-$max_port#$isp" $client_dir
            update_sub
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nhysteria2端口跳跃已开启：${purple}$min_port-$max_port${re}\n"
            ;;
        5)
            iptables -t nat -F PREROUTING > /dev/null 2>&1
            command -v ip6tables &> /dev/null && ip6tables -t nat -F PREROUTING > /dev/null 2>&1
            if command_exists rc-service 2>/dev/null; then
                rc-update del iptables default && rm -rf /etc/init.d/iptables
            elif [ -f /etc/debian_version ]; then
                netfilter-persistent save > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                service iptables save > /dev/null 2>&1
                command -v ip6tables &> /dev/null && service ip6tables save > /dev/null 2>&1
            fi
            sed -i '/hysteria2/s/&mport=[^#&]*//g' /etc/sing-box/url.txt
            update_sub
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

configure_cf_https_subscription() {
    local force_rotate="${1:-0}"
    local tunnel_mode domain_mode domain choice token port http_path https_path path_regex https_url
    local old_domain old_https_path old_path_regex config_file nginx_backup pending_state state_target
    local old_http_path tunnel_id dns_choice confirm apply_method manual_confirm operation_ok=0

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

    if [ "$force_rotate" = 1 ] && [ "$SUB_HTTPS_ENABLED" = 1 ]; then
        domain_mode="$SUB_HTTPS_DOMAIN_MODE"
        domain="$SUB_HTTPS_DOMAIN"
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

    config_file="/etc/nginx/conf.d/sing-box.conf"
    port=$(get_nginx_subscription_port "$config_file" 2>/dev/null || true)
    old_http_path=$(get_nginx_subscription_paths "$config_file" 2>/dev/null | head -1)
    [ -n "$port" ] && is_valid_http_subscription_path "$old_http_path" || {
        red "未找到有效的 Nginx HTTP 订阅配置，请先开启节点订阅。"
        return 1
    }

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
        if [[ "$dns_choice" =~ ^[Yy]$ ]] && \
           ! "${work_dir}/argo" tunnel route dns "$tunnel_id" "$domain"; then
            yellow "自动创建 DNS 失败，请在 Cloudflare Dashboard 手动创建上述 CNAME。"
        fi
        reading "确认 DNS 已配置后输入 y 继续: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    fi

    nginx_backup=$(mktemp "/etc/nginx/conf.d/.sing-box-https-backup.XXXXXX") || return 1
    cp -p "$config_file" "$nginx_backup" || { rm -f "$nginx_backup"; return 1; }
    chmod 600 "$nginx_backup" 2>/dev/null || true
    pending_state=$(mktemp "${work_dir}/.subscription-state-pending.XXXXXX") || {
        rm -f "$nginx_backup"
        return 1
    }
    rm -f "$pending_state"

    SUB_TOKEN="$token"
    SUB_HTTP_PATH="$http_path"
    SUB_HTTPS_ENABLED=1
    SUB_HTTPS_DOMAIN="$domain"
    SUB_HTTPS_DOMAIN_MODE="$domain_mode"
    SUB_HTTPS_PATH="$https_path"
    SUB_TUNNEL_MODE="$tunnel_mode"
    SUB_HTTPS_VERIFIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    state_target="$subscription_state_file"
    subscription_state_file="$pending_state"
    if ! save_subscription_state; then
        subscription_state_file="$state_target"
        rm -f "$nginx_backup" "$pending_state"
        red "无法预写订阅状态，配置未改变。"
        return 1
    fi
    subscription_state_file="$state_target"

    if ! apply_nginx_subscription_config "$port" "$http_path" "$https_path"; then
        rm -f "$nginx_backup" "$pending_state"
        load_subscription_state
        return 1
    fi

    case "$tunnel_mode" in
        local)
            apply_local_tunnel_subscription_rule "$domain" "$path_regex" "$port" \
                "$domain_mode" "${work_dir}/tunnel.yml" "$https_url" && operation_ok=1
            ;;
        remote)
            green "\n远程管理 Tunnel 配置方式："
            green "1. 使用 Cloudflare API token 自动配置"
            green "2. 在 Cloudflare Dashboard 手动配置"
            reading "请选择 [1-2，默认2]: " apply_method
            if [ "$apply_method" = 1 ]; then
                apply_remote_tunnel_subscription_rule "$domain" "$path_regex" "$port" \
                    "$domain_mode" "$old_domain" "$old_path_regex" "$https_url" && operation_ok=1
            else
                print_manual_https_route "$domain" "$path_regex" "$port"
                if [ -n "$old_domain" ] && [ -n "$old_path_regex" ] && \
                   { [ "$old_domain" != "$domain" ] || [ "$old_path_regex" != "$path_regex" ]; }; then
                    yellow "轮换完成后，请删除旧路由：Hostname=${old_domain}, Path=${old_path_regex}"
                fi
                reading "完成 Dashboard 配置后输入 y 进行公网验证: " manual_confirm
                [[ "$manual_confirm" =~ ^[Yy]$ ]] && \
                    verify_https_subscription "$https_url" && operation_ok=1
            fi
            ;;
    esac

    if [ "$operation_ok" != 1 ]; then
        cp -p "$nginx_backup" "$config_file"
        nginx -t > /dev/null 2>&1 && { nginx -s reload > /dev/null 2>&1 || restart_nginx > /dev/null 2>&1; }
        rm -f "$nginx_backup" "$pending_state"
        load_subscription_state
        red "HTTPS 订阅配置或验证失败，Nginx 已恢复，原 HTTP 订阅保持可用。"
        return 1
    fi

    if ! mv -f "$pending_state" "$subscription_state_file"; then
        cp -p "$nginx_backup" "$config_file"
        nginx -t > /dev/null 2>&1 && { nginx -s reload > /dev/null 2>&1 || restart_nginx > /dev/null 2>&1; }
        [ "$tunnel_mode" = local ] && [ -r "${work_dir}/tunnel.yml.bak.subscription" ] && {
            cp -p "${work_dir}/tunnel.yml.bak.subscription" "${work_dir}/tunnel.yml"
            restart_argo > /dev/null 2>&1 || true
        }
        rm -f "$nginx_backup" "$pending_state"
        load_subscription_state
        red "状态文件提交失败，已尽力恢复原配置。"
        return 1
    fi
    chmod 600 "$subscription_state_file" 2>/dev/null || true
    rm -f "$nginx_backup"
    green "\nCloudflare HTTPS 订阅已启用并通过内容验证：\n${purple}${https_url}${re}\n"
}

disable_cf_https_subscription() {
    local tunnel_mode path_regex method confirm port http_path

    load_subscription_state
    if [ "$SUB_HTTPS_ENABLED" != 1 ]; then
        yellow "Cloudflare HTTPS 订阅尚未启用。"
        return 0
    fi
    tunnel_mode="${SUB_TUNNEL_MODE:-$(detect_argo_tunnel_mode 2>/dev/null || true)}"
    path_regex="^${SUB_HTTPS_PATH}$"

    case "$tunnel_mode" in
        local)
            apply_local_tunnel_subscription_removal "${work_dir}/tunnel.yml" || {
                red "本地 Tunnel 订阅路由移除失败，状态未改变。"
                return 1
            }
            ;;
        remote)
            green "1. 使用 Cloudflare API token 自动移除路由"
            green "2. 在 Dashboard 手动移除路由"
            reading "请选择 [1-2，默认2]: " method
            if [ "$method" = 1 ]; then
                remove_remote_tunnel_subscription_via_api "$SUB_HTTPS_DOMAIN" "$path_regex" || return 1
            else
                yellow "请删除路由：Hostname=${SUB_HTTPS_DOMAIN}, Path=${path_regex}"
                reading "确认已删除后输入 y: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || return 1
            fi
            ;;
        *) red "无法识别原固定 Tunnel 类型，未修改状态。"; return 1 ;;
    esac

    port=$(get_nginx_subscription_port 2>/dev/null || true)
    http_path="${SUB_HTTP_PATH:-$(get_nginx_subscription_paths 2>/dev/null | head -1)}"
    if [ -n "$port" ] && is_valid_http_subscription_path "$http_path"; then
        apply_nginx_subscription_config "$port" "$http_path" "" || \
            yellow "HTTPS 路由已关闭，但 Nginx 未能移除额外 HTTPS origin 路径。"
    fi

    SUB_HTTPS_ENABLED=0
    SUB_HTTPS_DOMAIN=''
    SUB_HTTPS_DOMAIN_MODE=''
    SUB_HTTPS_PATH=''
    SUB_TUNNEL_MODE=''
    SUB_HTTPS_VERIFIED_AT=''
    save_subscription_state || return 1
    green "Cloudflare HTTPS 订阅已关闭；HTTP 订阅仍保留。"
}

update_cf_https_subscription_origin() {
    local port="${1:-}"
    local tunnel_mode path_regex https_url method confirm operation_ok=0

    load_subscription_state
    [ "$SUB_HTTPS_ENABLED" = 1 ] || return 0
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 1
    tunnel_mode="${SUB_TUNNEL_MODE:-$(detect_argo_tunnel_mode 2>/dev/null || true)}"
    path_regex="^${SUB_HTTPS_PATH}$"
    https_url=$(build_https_subscription_url "$SUB_HTTPS_DOMAIN" "$SUB_HTTPS_PATH") || return 1

    case "$tunnel_mode" in
        local)
            apply_local_tunnel_subscription_rule "$SUB_HTTPS_DOMAIN" "$path_regex" "$port" \
                "$SUB_HTTPS_DOMAIN_MODE" "${work_dir}/tunnel.yml" "$https_url" && operation_ok=1
            ;;
        remote)
            green "HTTPS 订阅已启用，端口变化还需要更新远程 Tunnel origin。"
            green "1. 使用 Cloudflare API token 自动更新"
            green "2. 在 Dashboard 手动更新"
            reading "请选择 [1-2，默认2]: " method
            if [ "$method" = 1 ]; then
                apply_remote_tunnel_subscription_rule "$SUB_HTTPS_DOMAIN" "$path_regex" "$port" \
                    "$SUB_HTTPS_DOMAIN_MODE" "$SUB_HTTPS_DOMAIN" "$path_regex" "$https_url" && operation_ok=1
            else
                print_manual_https_route "$SUB_HTTPS_DOMAIN" "$path_regex" "$port"
                reading "更新完成后输入 y 进行公网验证: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] && verify_https_subscription "$https_url" && operation_ok=1
            fi
            ;;
        *) return 1 ;;
    esac

    [ "$operation_ok" = 1 ] || return 1
    SUB_HTTPS_VERIFIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    save_subscription_state
}

rotate_subscription_token() {
    local port old_path token new_path host link confirm

    load_subscription_state
    if [ "$SUB_HTTPS_ENABLED" = 1 ]; then
        configure_cf_https_subscription 1
        return $?
    fi

    port=$(get_nginx_subscription_port 2>/dev/null || true)
    old_path=$(get_nginx_subscription_paths 2>/dev/null | head -1)
    [ -n "$port" ] && is_valid_http_subscription_path "$old_path" || {
        red "未找到有效的 HTTP 订阅，无法轮换密钥。"
        return 1
    }
    yellow "轮换后旧 HTTP 订阅 URL 将立即失效。"
    reading "确认继续？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    token=$(generate_subscription_token) || return 1
    new_path="/${token}"
    apply_nginx_subscription_config "$port" "$new_path" "" || return 1

    SUB_TOKEN="$token"
    SUB_HTTP_PATH="$new_path"
    SUB_HTTPS_ENABLED=0
    SUB_HTTPS_DOMAIN=''
    SUB_HTTPS_DOMAIN_MODE=''
    SUB_HTTPS_PATH=''
    SUB_TUNNEL_MODE=''
    SUB_HTTPS_VERIFIED_AT=''
    save_subscription_state || return 1
    host=$(get_subscription_host 2>/dev/null || true)
    link=$(build_http_subscription_url "$host" "$port" "$new_path" 2>/dev/null || true)
    green "订阅密钥已轮换，新 HTTP 订阅：${purple}${link}${re}"
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
            if command_exists nginx; then
                if command_exists rc-service 2>/dev/null; then
                    rc-service nginx status | grep -q "started" && rc-service nginx stop || red "nginx not running"
                else
                    [ "$(systemctl is-active nginx)" = "active" ] && systemctl stop nginx || red "nginx not running"
                fi
            else
                yellow "nginx未安装，节点订阅本来就未运行。"
            fi
            green "\n已关闭节点订阅；HTTP 与 Cloudflare HTTPS 订阅都会停止响应。\n"
            ;;
        2)
            local config_file="/etc/nginx/conf.d/sing-box.conf"
            local http_path link token
            server_ip=$(get_subscription_host)
            sub_port=$(get_nginx_subscription_port "$config_file" 2>/dev/null || true)
            http_path=$(get_nginx_subscription_paths "$config_file" 2>/dev/null | head -1)

            if [ -n "$sub_port" ] && [ -n "$http_path" ]; then
                start_nginx
            else
                token=$(generate_subscription_token) || { red "订阅密钥生成失败"; return 1; }
                http_path="/$token"
                sub_port=$(shuf -i 2000-65000 -n 1)
                apply_nginx_subscription_config "$sub_port" "$http_path" "" || {
                    red "节点订阅开启失败，原配置未改变"
                    return 1
                }
                load_subscription_state
                SUB_TOKEN="$token"
                SUB_HTTP_PATH="$http_path"
                save_subscription_state || true
            fi

            link=$(build_http_subscription_url "$server_ip" "$sub_port" "$http_path" 2>/dev/null || true)
            green "\n已开启节点订阅\n节点订阅链接：${purple}${link}${re}\n"
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
            local -a current_paths
            mapfile -t current_paths < <(get_nginx_subscription_paths "/etc/nginx/conf.d/sing-box.conf")
            [ "${#current_paths[@]}" -gt 0 ] || { red "未找到有效的 Nginx 订阅路径"; return 1; }
            local current_http_path="${current_paths[0]}"
            local current_https_path=""
            [ "${#current_paths[@]}" -gt 1 ] && current_https_path="${current_paths[1]}"
            server_ip=$(get_subscription_host)
            allow_port $sub_port/tcp > /dev/null 2>&1
            if apply_nginx_subscription_config "$sub_port" "$current_http_path" "$current_https_path"; then
                if ! update_cf_https_subscription_origin "$sub_port"; then
                    [ -r "/etc/nginx/conf.d/sing-box.conf.bak.sb" ] && \
                        cp -p "/etc/nginx/conf.d/sing-box.conf.bak.sb" "/etc/nginx/conf.d/sing-box.conf"
                    nginx -t > /dev/null 2>&1 && { nginx -s reload > /dev/null 2>&1 || restart_nginx > /dev/null 2>&1; }
                    red "Tunnel origin 更新失败，订阅端口已恢复。"
                    return 1
                fi
                link=$(build_http_subscription_url "$server_ip" "$sub_port" "$current_http_path" 2>/dev/null || true)
                green "\n订阅端口更换成功\n新的订阅链接为：${purple}${link}${re}\n"
            else
                red "nginx配置测试失败，已恢复原配置"
                return 1
            fi
            ;;
        4) restart_nginx ;;
        5) show_subscription_status ;;
        6) configure_cf_https_subscription ;;
        7) disable_cf_https_subscription ;;
        8) rotate_subscription_token ;;
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
            reading "\n请输入你的argo密钥(token或json): " argo_auth
            if [[ $argo_auth =~ TunnelSecret ]]; then
                tunnel_id=$(extract_argo_tunnel_id "$argo_auth")
                [ -z "$tunnel_id" ] && { yellow "ARGO_AUTH 未解析到 TunnelID，请重新输入"; manage_argo; return; }
                ARGO_AUTH="$argo_auth"
                ARGO_FIXED_READY=1
                echo "$argo_auth" > "${work_dir}/tunnel.json"
                cat > ${work_dir}/tunnel.yml << EOF
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
                    sed -i '/^command_args=/c\command_args="-c '\''/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run > /etc/sing-box/argo.log 2>&1'\''"' /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run > /etc/sing-box/argo.log 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo; sleep 1; change_argo_domain
            elif is_argo_tunnel_token "$argo_auth"; then
                ARGO_AUTH="$argo_auth"
                ARGO_FIXED_READY=1
                if command_exists rc-service 2>/dev/null; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argo_auth > /etc/sing-box/argo.log 2>&1'\"" /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '$argo_auth' > /etc/sing-box/argo.log 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo; sleep 1; change_argo_domain
            else
                yellow "输入不匹配，请重新输入"; manage_argo; return
            fi
            if [ "$ARGO_FIXED_READY" = 1 ] && [ -t 0 ]; then
                reading "是否同时配置 Cloudflare HTTPS 订阅？[y/N]: " enable_https_subscription
                [[ "$enable_https_subscription" =~ ^[Yy]$ ]] && configure_cf_https_subscription
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
            if command_exists rc-service 2>/dev/null; then
                grep -Eq -- '--url http://(127\.0\.0\.1|localhost)' "/etc/init.d/argo" && get_quick_tunnel && change_argo_domain || \
                    { yellow "当前使用固定隧道，无法获取临时隧道"; sleep 2; menu; }
            else
                grep -Eq 'ExecStart=.*--url http://(127\.0\.0\.1|localhost)' "/etc/systemd/system/argo.service" && get_quick_tunnel && change_argo_domain || \
                    { yellow "当前使用固定隧道，无法获取临时隧道"; sleep 2; menu; }
            fi
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

    if [ "$is_local" = true ]; then
        # 本地代理：直接用 curl 通过代理访问外网测试连通性
        yellow "检测到本地代理 ${check_proto}://${server}:${port}，跳过外部API检测，正在用curl测试连通性..."
        local curl_proxy_url="${check_proto}://${proxy_auth}${server}:${port}"
        local test_result
        test_result=$(curl -s --max-time 8 --proxy "$curl_proxy_url" "https://api.ip.sb/ip" 2>/dev/null)
        if [ -z "$test_result" ]; then
            yellow "警告：通过本地代理访问外网失败，请确认代理服务正在运行。"
            reading "是否仍然添加此代理？(y/n): " force_add
            [[ ! "$force_add" =~ ^[yY]$ ]] && { yellow "已取消"; sleep 1; return; }
        else
            green "本地代理可用，出口IP: $test_result"
        fi
    else
        # 远程代理：调用外部 API 检测
        yellow "正在测试代理 ${check_proto}://${server}:${port} ..."
        local api_response
        api_response=$(curl -s --max-time 8 -G \
            --data-urlencode "proxy=${check_proto}://${proxy_auth}${server}:${port}" \
            "https://check.socks5.cmliussss.net/check" 2>/dev/null)
        [ -z "$api_response" ] && { red "API 请求失败"; sleep 2; return; }

        success=$(echo "$api_response" | jq -r '.success')
        if [ "$success" != "true" ]; then
            error_msg=$(echo "$api_response" | jq -r '.error // "未知错误"')
            red "代理不可用: $error_msg"; sleep 2; return
        fi
        exit_ip=$(echo "$api_response" | jq -r '.exit.ip // empty')
        green "代理可用"
        [ -n "$exit_ip" ] && green "出口 IP: $exit_ip"
    fi

    [ -n "$tag_from_url" ] && tag="$tag_from_url" || tag="${outbound_type}-${server}-${port}"
    jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" >/dev/null 2>&1 \
        && { red "出站标签 '${tag}' 已存在"; sleep 2; return; }

    # 根据是否有账号密码，决定写入字段，避免空字符串导致 sing-box 报错
    if [ -n "$user" ] && [ -n "$password" ]; then
        if ! apply_jq_config "$outbound_file" \
            --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
            --arg port "$port" --arg user "$user" --arg password "$password" \
            '.outbounds += [{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber),"username":$user,"password":$password}]'; then
            red "代理出站配置校验失败，未添加 '${tag}'。"
            sleep 2; return
        fi
    else
        # 无账号密码：不写 username/password 字段
        if ! apply_jq_config "$outbound_file" \
            --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
            --arg port "$port" \
            '.outbounds += [{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber)}]'; then
            red "代理出站配置校验失败，未添加 '${tag}'。"
            sleep 2; return
        fi
    fi

    if jq -e '.route.rules | length > 0' "$route_file" >/dev/null 2>&1; then
        if apply_warp_route_update '
          .route.rules = [
            .route.rules[] |
            if ((.rule_set? | type) == "array") then
              .outbound = $tag | .action = "route"
            else
              .
            end
          ]
        ' --arg tag "$tag"; then
            yellow "已将现有分流规则出站切换为 '${tag}'。"
        else
            red "代理已添加，但现有分流规则切换失败。"
            sleep 2; return
        fi
    elif ! restart_singbox_checked; then
        red "代理已写入配置，但 sing-box 重启失败。"
        sleep 2; return
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

    jq --arg tag "$tag" 'del(.outbounds[] | select(.tag == $tag))' "$outbound_file" > "${outbound_file}.tmp" && mv "${outbound_file}.tmp" "$outbound_file"
    jq --arg tag "$tag" '.route.rules = [.route.rules[] | select(.outbound != $tag)]' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"

    restart_singbox
    green "${tag} 代理出站已删除。"
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

# 更新订阅文件
remove_url_by_tag() {
    local tag="$1"
    sed -i '/'^${tag}':\/\//d' "$client_dir"
    sed -i '/^$/{N; /\n$/D}' "$client_dir"
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
        : > "$tmp_file"
    elif ! base64 -w0 "$source_file" > "$tmp_file" 2>/dev/null; then
        if ! base64 "$source_file" | tr -d '\n\r' > "$tmp_file"; then
            rm -f "$tmp_file"
            return 1
        fi
    fi

    chmod 644 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$sub_file"
}
sync_combined_subscription() {
    local tmp_file cfy_file cfy_sub_file combined_sub_file
    cfy_file="${work_dir}/cfy-url.txt"
    cfy_sub_file="${work_dir}/cfy-sub.txt"
    combined_sub_file="${work_dir}/all-sub.txt"

    mkdir -p "${work_dir}" || return 1
    tmp_file=$(mktemp "${work_dir}/.tmp.all-url.XXXXXX") || return 1

    [ -s "$client_dir" ] && sed '/^[[:space:]]*$/d' "$client_dir" > "$tmp_file"
    if [ -s "$cfy_file" ]; then
        [ -s "$tmp_file" ] && printf '\n' >> "$tmp_file"
        sed '/^[[:space:]]*$/d' "$cfy_file" >> "$tmp_file"
        write_base64_subscription "$cfy_file" "$cfy_sub_file" || { rm -f "$tmp_file"; return 1; }
    fi

    if [ -s "$tmp_file" ]; then
        chmod 644 "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$combined_client_dir" || { rm -f "$tmp_file"; return 1; }
        write_base64_subscription "$combined_client_dir" "$combined_sub_file" || return 1
        write_base64_subscription "$combined_client_dir" "${work_dir}/sub.txt" || return 1
    else
        rm -f "$tmp_file"
        printf '' | atomic_write_file "$combined_client_dir" 644
        printf '' | atomic_write_file "$combined_sub_file" 644
        printf '' | atomic_write_file "${work_dir}/sub.txt" 644
    fi
}
update_sub() {
    write_base64_subscription "$client_dir" "${work_dir}/base-sub.txt"
    sync_combined_subscription
}

# ---- Socks5 入站 ----
add_socks5_inbound() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="socks5-in"

    if proto_exists "$tag"; then
        yellow "Socks5 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 获取当前UUID用于自动填充
    local current_uuid
    current_uuid=$(get_current_uuid | tr -d '\n\r')

    # 端口输入验证循环
    while true; do
        reading "请输入 Socks5 监听端口 (回车随机生成): " sk_port
        if [ -z "$sk_port" ]; then
            sk_port=$(shuf -i 10000-65000 -n 1)
            green "socks5监听端口：${purple}${sk_port}${re}"
            break
        fi

        # 统一验证端口格式和范围
        if [[ ! "$sk_port" =~ ^[0-9]+$ ]] || [ "$sk_port" -gt 65535 ] || [ "$sk_port" -lt 1 ]; then
            yellow "错误：端口必须是1-65535之间的数字！"
            continue
        fi

        green "socks5监听端口：${purple}${sk_port}${re}"
        break
    done

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

    apply_jq_config "$inbounds_file" \
       --arg tag "$tag" \
       --argjson port "$sk_port" \
       --arg user "$sk_user" \
       --arg pass "$sk_pass" \
       '.inbounds += [{
           "type": "socks",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{"username": $user, "password": $pass}]
       }]' || return

    allow_port ${sk_port}/tcp ${sk_port}/udp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' \
        | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' \
        | sed 's/ /_/g' || echo "Socks5")

    local url_line="socks://$(printf '%s' "${sk_user}:${sk_pass}" | base64 -w0)@${server_ip}:${sk_port}#${isp}"

    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub

    restart_singbox

    green "\nSocks5 协议已添加！"
    green "端口: ${purple}${sk_port}${re}"
    green "用户名: ${purple}${sk_user}${re}  ${green}密码:${re} ${purple}${sk_pass}${re}"
    green "节点链接: ${purple}${url_line}${re}\n"
    render_terminal_qr "$url_line"
}

remove_socks5_inbound() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="socks5-in"

    if ! proto_exists "$tag"; then
        yellow "Socks5 协议未添加，无需删除。"; sleep 1; return
    fi

    apply_jq_config "$inbounds_file" --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' || return

    remove_url_by_tag "socks"
    update_sub
    restart_singbox
    green "\nSocks5 协议已删除\n"
}

# ---- AnyTLS ----
add_anytls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="anytls"

    if proto_exists "$tag"; then
        yellow "AnyTLS 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 使用已安装协议的UUID作为密码
    local current_uuid
    current_uuid=$(get_current_uuid)
    if [ -z "$current_uuid" ]; then
        red "无法获取当前UUID，请确认 sing-box 已正确安装并配置。"; sleep 2; return
    fi

    # 端口输入验证循环
    while true; do
        reading "请输入 AnyTLS 监听端口 (回车随机生成): " at_port

        if [ -z "$at_port" ]; then
            at_port=$(shuf -i 10000-65000 -n 1)
            green "Anytls监听端口：${purple}${at_port}${re}"
            break
        fi

        if [[ ! "$at_port" =~ ^[0-9]+$ ]] || [ "$at_port" -gt 65535 ] || [ "$at_port" -lt 1 ]; then
            yellow "错误：端口必须是1-65535之间的数字！"
            continue
        fi

        green "Anytls监听端口：${purple}${at_port}${re}"
        break
    done

    apply_jq_config "$inbounds_file" \
       --arg tag "$tag" \
       --argjson port "$at_port" \
       --arg pass "$current_uuid" \
       --arg cert "${work_dir}/cert.pem" \
       --arg key "${work_dir}/private.key" \
       '.inbounds += [{
           "type": "anytls",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{"password": $pass}],
           "tls": {
               "enabled": true,
               "certificate_path": $cert,
               "key_path": $key
           }
       }]' || return

    allow_port ${at_port}/tcp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' \
        | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' \
        | sed 's/ /_/g' || echo "AnyTLS")

    local url_line="anytls://${current_uuid}@${server_ip}:${at_port}?insecure=1&sni=bing.com#${isp}"

    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub

    restart_singbox

    green "\nAnyTLS 协议已添加！"
    green "密码(UUID): ${purple}${current_uuid}${re}"
    green "端口: ${purple}${at_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
    render_terminal_qr "$url_line"
}

remove_anytls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="anytls"

    if ! proto_exists "$tag"; then
        yellow "AnyTLS 协议未添加，无需删除。"; sleep 1; return
    fi

    apply_jq_config "$inbounds_file" --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' || return

    remove_url_by_tag "anytls"
    update_sub
    restart_singbox
    green "\nAnyTLS 协议已删除\n"
}

# ---- Shadowsocks-2022 ----
add_ss2022() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="shadowsocks-2022"

    if proto_exists "$tag"; then
        yellow "Shadowsocks-2022 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 端口输入验证循环
    while true; do
        reading "请输入 Shadowsocks-2022 监听端口 (回车随机生成): " ss_port

        if [ -z "$ss_port" ]; then
            ss_port=$(shuf -i 10000-65000 -n 1)
            green "Shadowsocks-2022监听端口：${purple}${ss_port}${re}"
            break
        fi

        if [[ ! "$ss_port" =~ ^[0-9]+$ ]] || [ "$ss_port" -gt 65535 ] || [ "$ss_port" -lt 1 ]; then
            yellow "错误：端口必须是1-65535之间的数字！"
            continue
        fi

        green "Shadowsocks-2022监听端口：${purple}${ss_port}${re}"
        break
    done

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

    apply_jq_config "$inbounds_file" \
       --arg tag "$tag" \
       --argjson port "$ss_port" \
       --arg method "$ss_method" \
       --arg key "$ss_key" \
       '.inbounds += [{
           "type": "shadowsocks",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "method": $method,
           "password": $key,
           "multiplex": {"enabled": true}
       }]' || return

    allow_port ${ss_port}/tcp ${ss_port}/udp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' \
        | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' \
        | sed 's/ /_/g' || echo "SS2022")

    local ss_userinfo
    ss_userinfo=$(printf '%s:%s' "${ss_method}" "${ss_key}" | base64 -w0)
    local url_line="ss://${ss_userinfo}@${server_ip}:${ss_port}#${isp}"

    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub

    restart_singbox

    green "\nShadowsocks-2022 协议已添加！"
    green "加密方式: ${purple}${ss_method}${re}"
    green "密钥(base64): ${purple}${ss_key}${re}"
    green "端口: ${purple}${ss_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
    render_terminal_qr "$url_line"
}

remove_ss2022() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="shadowsocks-2022"

    if ! proto_exists "$tag"; then
        yellow "Shadowsocks-2022 协议未添加，无需删除。"; sleep 1; return
    fi

    apply_jq_config "$inbounds_file" --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' || return

    remove_url_by_tag "ss"
    update_sub
    restart_singbox
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

# 捕获 Ctrl+C
trap 'stop_warp_candidate_proxy 2>/dev/null || true; red "\n强制退出"; exit' INT TERM

# ---- 参数解析入口 ----
case "$1" in
    -i | --install)
        auto_install
        exit 0
        ;;
    --update | --upgrade)
        update_shortcut
        exit 0
        ;;
    -u | --uninstall)
        auto_uninstall
        exit 0
        ;;
    --purge-nginx)
        PURGE_NGINX=1
        auto_uninstall
        exit 0
        ;;
    -c | --check)
        check_nodes
        exit 0
        ;;
    -r | --restart)
        get_quick_tunnel
        change_argo_domain
        exit 0
        ;;
    -h | --help)
        echo ""
        green "用法: [sb或脚本] [参数], 示例: sb -c(查看节点信息)"
        echo ""
        green "  -i, --install     无交互安装sing-box"
        green "      --update      仅更新 sb 快捷命令，不修改已有节点"
        green "  -c, --check       查看节点信息和订阅链接"
        green "  -r, --restart     重新获取argo临时隧道并更新到订阅"
        green "  -u, --uninstall   uninstall sing-box and keep nginx"
        green "      --purge-nginx  uninstall sing-box and remove nginx"
        green "  -h, --help        显示此帮助信息"
        echo ""
        green "  不带参数          进入交互式主菜单"
        echo ""
        exit 0
        ;;
    "")
        # 无参数：进入交互式主菜单
        while true; do
            menu
            reading "请输入选择(0-10): " choice
            echo ""
            need_pause=true
            case "${choice}" in
                1)
                    check_singbox &>/dev/null; singbox_check=$?
                    if [ ${singbox_check} -eq 0 ]; then
                        yellow "sing-box 已经安装！\n"
                    else
                        manage_packages install nginx jq tar openssl lsof coreutils
                        install_singbox
                        if command_exists systemctl; then
                            main_systemd_services
                        elif command_exists rc-update; then
                            alpine_openrc_services
                            change_hosts
                            rc-service sing-box restart
                            rc-service argo restart
                        else
                            echo "Unsupported init system"; exit 1
                        fi
                        sleep 5
                        add_nginx_conf
                        get_info
                        create_shortcut
                    fi
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
        ;;
    *)
        red "未知参数: $1"
        echo ""
        green "用法: sb [参数],相关参数:[-i|-u|-c|-r|-h], 首次安装：bash脚本 -i(前面可带环境变量)"
        exit 1
        ;;
esac
