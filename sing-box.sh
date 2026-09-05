#!/bin/bash

# =========================
# 老王sing-box四合一安装脚本
# vless-version-reality|vless-ws-tls(tunnel)|hysteria2|tuic5|[可额外添加Anytls，socks5，ss2022等协议]
# 最后更新时间: 2026.8.15[修复WARP共享身份冲突与空闲失活]
# =========================

export LANG=en_US.UTF-8
umask 077

clear_inherited_transaction_lock_state() {
    unset \
        SUBSCRIPTION_LOCK_HELD \
        STABLE_TX_MUTATION_DEPTH STABLE_TX_MUTATION_FD \
        STABLE_TX_SUBSCRIPTION_DEPTH STABLE_TX_SUBSCRIPTION_FD \
        STABLE_TX_FIREWALL_DEPTH STABLE_TX_FIREWALL_FD \
        LEGACY_TX_MUTATION_DEPTH LEGACY_TX_MUTATION_FD LEGACY_TX_MUTATION_PATH \
        LEGACY_TX_SUBSCRIPTION_DEPTH LEGACY_TX_SUBSCRIPTION_FD LEGACY_TX_SUBSCRIPTION_PATH \
        LEGACY_TX_FIREWALL_DEPTH LEGACY_TX_FIREWALL_FD LEGACY_TX_FIREWALL_PATH
}

clear_inherited_transaction_lock_state || exit 2
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
CFY_SOURCE_GENERATION_FILE="${CFY_SOURCE_GENERATION_FILE:-${work_dir}/cfy-source.generation}"
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

# Shared, versioned control-plane transaction namespace.  Lock files are
# permanent inode anchors: callers may flock them, but must never truncate,
# rename, or unlink them.  SING_BOX_TRANSACTION_ROOT exists for tests/chroots;
# production uses the root-owned default below.
transaction_root_path() {
    local root="${SING_BOX_TRANSACTION_ROOT:-/var/lib/sing-box-transactions}"

    [ -n "$root" ] && [ "$root" != / ] && [[ "$root" = /* ]] || return 1
    [[ "$root" != *$'\n'* && "$root" != *$'\r'* ]] || return 1
    case "$root" in
        *//*|*/./*|*/../*|*/.|*/..) return 1 ;;
    esac
    root="${root%/}"
    [ -n "$root" ] && [ "$root" != / ] || return 1
    printf '%s\n' "$root"
}

transaction_expected_dir_mode() {
    if [ -n "${SING_BOX_TRANSACTION_GROUP:-}" ]; then
        printf '750\n'
    else
        printf '700\n'
    fi
}

transaction_expected_file_mode() {
    if [ -n "${SING_BOX_TRANSACTION_GROUP:-}" ]; then
        printf '640\n'
    else
        printf '600\n'
    fi
}

transaction_expected_gid() {
    local requested_group="${SING_BOX_TRANSACTION_GROUP:-}" group_entry gid

    if [ -z "$requested_group" ]; then
        id -g
        return
    fi
    [[ "$requested_group" != *$'\n'* && "$requested_group" != *$'\r'* ]] || return 1
    if command -v getent >/dev/null 2>&1; then
        group_entry=$(getent group "$requested_group" 2>/dev/null) || return 1
        gid=$(printf '%s\n' "$group_entry" | awk -F: 'NR == 1 { print $3 }') || return 1
    elif [[ "$requested_group" =~ ^[0-9]+$ ]]; then
        gid="$requested_group"
        if [ "$gid" != "$(id -g)" ] && \
           ! awk -F: -v wanted="$gid" '$3 == wanted { found=1 } END { exit !found }' /etc/group 2>/dev/null; then
            return 1
        fi
    else
        gid=$(awk -F: -v wanted="$requested_group" \
            '$1 == wanted { print $3; found=1; exit } END { exit !found }' \
            /etc/group 2>/dev/null) || return 1
    fi
    [[ "$gid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$gid"
}

validate_transaction_path_components() {
    local path="${1:-}" component current=''
    local -a components=()

    [ -n "$path" ] && [ "$path" != / ] && [[ "$path" = /* ]] || return 1
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    case "$path" in
        *//*|*/./*|*/../*|*/.|*/..) return 1 ;;
    esac
    IFS='/' read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [ -n "$component" ] || return 1
        current="${current}/${component}"
        if [ -e "$current" ] || [ -L "$current" ]; then
            [ -d "$current" ] && [ ! -L "$current" ] || return 1
        else
            break
        fi
    done
}

validate_transaction_directory() {
    local path="${1:-}" expected_mode="${2:-}" expected_gid="${3:-}"
    local actual_uid actual_gid actual_mode

    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    actual_uid=$(stat -c '%u' -- "$path" 2>/dev/null) || return 1
    actual_gid=$(stat -c '%g' -- "$path" 2>/dev/null) || return 1
    actual_mode=$(stat -c '%a' -- "$path" 2>/dev/null) || return 1
    [ "$actual_uid" = "$(id -u)" ] && [ "$actual_gid" = "$expected_gid" ] && \
        [ "$actual_mode" = "$expected_mode" ]
}

ensure_transaction_directory() {
    local path="${1:-}" expected_mode="${2:-}" expected_gid="${3:-}"
    local actual_uid

    [ -n "$path" ] && [[ "$expected_mode" =~ ^7[05]0$ ]] && \
        [[ "$expected_gid" =~ ^[0-9]+$ ]] || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ -d "$path" ] && [ ! -L "$path" ] || return 2
    elif ! (umask 077 && mkdir -- "$path"); then
        [ -d "$path" ] && [ ! -L "$path" ] || return 1
    fi
    actual_uid=$(stat -c '%u' -- "$path" 2>/dev/null) || return 2
    [ "$actual_uid" = "$(id -u)" ] || return 2
    chgrp "$expected_gid" -- "$path" 2>/dev/null || return 1
    chmod "$expected_mode" -- "$path" || return 1
    validate_transaction_directory "$path" "$expected_mode" "$expected_gid" || return 2
}

validate_transaction_regular_file() {
    local path="${1:-}" expected_mode="${2:-}" expected_gid="${3:-}"
    local actual_uid actual_gid actual_mode link_count

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    actual_uid=$(stat -c '%u' -- "$path" 2>/dev/null) || return 1
    actual_gid=$(stat -c '%g' -- "$path" 2>/dev/null) || return 1
    actual_mode=$(stat -c '%a' -- "$path" 2>/dev/null) || return 1
    link_count=$(stat -c '%h' -- "$path" 2>/dev/null) || return 1
    [ "$actual_uid" = "$(id -u)" ] && [ "$actual_gid" = "$expected_gid" ] && \
        [ "$actual_mode" = "$expected_mode" ] && [ "$link_count" = 1 ]
}

ensure_transaction_regular_file() {
    local path="${1:-}" expected_mode="${2:-}" expected_gid="${3:-}"
    local file_dir file_name tmp_file actual_uid link_count

    [ -n "$path" ] && [[ "$expected_mode" =~ ^6[04]0$ ]] && \
        [[ "$expected_gid" =~ ^[0-9]+$ ]] || return 1
    file_dir=$(dirname "$path") || return 1
    file_name=$(basename "$path") || return 1
    [ -d "$file_dir" ] && [ ! -L "$file_dir" ] || return 2
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        tmp_file=$(mktemp "${file_dir}/.transaction-${file_name}.XXXXXX") || return 1
        if ! chgrp "$expected_gid" -- "$tmp_file" 2>/dev/null || \
           ! chmod "$expected_mode" -- "$tmp_file" || \
           ! ln -- "$tmp_file" "$path" 2>/dev/null; then
            rm -f -- "$tmp_file"
            [ -e "$path" ] || [ -L "$path" ] || return 1
        else
            rm -f -- "$tmp_file" || return 1
        fi
    fi
    [ -f "$path" ] && [ ! -L "$path" ] || return 2
    actual_uid=$(stat -c '%u' -- "$path" 2>/dev/null) || return 2
    link_count=$(stat -c '%h' -- "$path" 2>/dev/null) || return 2
    [ "$actual_uid" = "$(id -u)" ] && [ "$link_count" = 1 ] || return 2
    chgrp "$expected_gid" -- "$path" 2>/dev/null || return 1
    chmod "$expected_mode" -- "$path" || return 1
    validate_transaction_regular_file "$path" "$expected_mode" "$expected_gid" || return 2
}

write_transaction_schema_file() {
    local schema_file="${1:-}" expected_mode="${2:-}" expected_gid="${3:-}"
    local schema_dir schema_name tmp_file schema_value schema_size

    [ -n "$schema_file" ] || return 1
    schema_dir=$(dirname "$schema_file") || return 1
    schema_name=$(basename "$schema_file") || return 1
    if [ ! -e "$schema_file" ] && [ ! -L "$schema_file" ]; then
        tmp_file=$(mktemp "${schema_dir}/.transaction-${schema_name}.XXXXXX") || return 1
        if ! printf '1\n' > "$tmp_file" || \
           ! chgrp "$expected_gid" -- "$tmp_file" 2>/dev/null || \
           ! chmod "$expected_mode" -- "$tmp_file" || \
           ! ln -- "$tmp_file" "$schema_file" 2>/dev/null; then
            rm -f -- "$tmp_file"
            [ -e "$schema_file" ] || [ -L "$schema_file" ] || return 1
        else
            rm -f -- "$tmp_file" || return 1
        fi
    fi
    ensure_transaction_regular_file "$schema_file" "$expected_mode" "$expected_gid" || return $?
    schema_size=$(LC_ALL=C wc -c < "$schema_file" 2>/dev/null | tr -d '[:space:]') || return 2
    IFS= read -r schema_value < "$schema_file" || return 2
    [ "$schema_size" = 2 ] && [ "$schema_value" = 1 ] || return 2
}

ensure_stable_transaction_root() {
    local root dir_mode file_mode expected_gid lock_kind lock_path

    root=$(transaction_root_path) || return 2
    validate_transaction_path_components "$root" || return 2
    dir_mode=$(transaction_expected_dir_mode) || return 2
    file_mode=$(transaction_expected_file_mode) || return 2
    expected_gid=$(transaction_expected_gid) || return 2

    ensure_transaction_directory "$root" "$dir_mode" "$expected_gid" || return $?
    ensure_transaction_directory "$root/pending" "$dir_mode" "$expected_gid" || return $?
    ensure_transaction_directory "$root/recoveries" "$dir_mode" "$expected_gid" || return $?
    write_transaction_schema_file "$root/schema-version" "$file_mode" "$expected_gid" || return $?
    for lock_kind in mutation subscription firewall; do
        lock_path="$root/${lock_kind}.lock"
        ensure_transaction_regular_file "$lock_path" "$file_mode" "$expected_gid" || return $?
        [ ! -s "$lock_path" ] || return 2
    done
}

stable_transaction_lock_path() {
    local kind="${1:-}" root

    case "$kind" in mutation|subscription|firewall) ;; *) return 1 ;; esac
    root=$(transaction_root_path) || return 1
    printf '%s/%s.lock\n' "$root" "$kind"
}

stable_transaction_lock_rank() {
    case "${1:-}" in
        mutation) printf '1\n' ;;
        subscription) printf '2\n' ;;
        firewall) printf '3\n' ;;
        *) return 1 ;;
    esac
}

stable_transaction_lock_is_held() {
    case "${1:-}" in
        mutation) [ "${STABLE_TX_MUTATION_DEPTH:-0}" -gt 0 ] 2>/dev/null ;;
        subscription) [ "${STABLE_TX_SUBSCRIPTION_DEPTH:-0}" -gt 0 ] 2>/dev/null ;;
        firewall) [ "${STABLE_TX_FIREWALL_DEPTH:-0}" -gt 0 ] 2>/dev/null ;;
        *) return 1 ;;
    esac
}

stable_transaction_highest_rank() {
    if stable_transaction_lock_is_held firewall; then
        printf '3\n'
    elif stable_transaction_lock_is_held subscription; then
        printf '2\n'
    elif stable_transaction_lock_is_held mutation; then
        printf '1\n'
    else
        printf '0\n'
    fi
}

stable_transaction_lock_hook() {
    :
}

legacy_transaction_lock_hook() {
    :
}

reset_stable_transaction_lock_state() {
    local depth fd saved_path

    [ "$(stable_transaction_highest_rank)" -eq 0 ] || return 2
    for depth in \
        "${STABLE_TX_MUTATION_DEPTH:-0}" \
        "${STABLE_TX_SUBSCRIPTION_DEPTH:-0}" \
        "${STABLE_TX_FIREWALL_DEPTH:-0}" \
        "${LEGACY_TX_MUTATION_DEPTH:-0}" \
        "${LEGACY_TX_SUBSCRIPTION_DEPTH:-0}" \
        "${LEGACY_TX_FIREWALL_DEPTH:-0}"; do
        [ "$depth" = 0 ] || return 2
    done
    for fd in \
        "${STABLE_TX_MUTATION_FD:-}" \
        "${STABLE_TX_SUBSCRIPTION_FD:-}" \
        "${STABLE_TX_FIREWALL_FD:-}" \
        "${LEGACY_TX_MUTATION_FD:-}" \
        "${LEGACY_TX_SUBSCRIPTION_FD:-}" \
        "${LEGACY_TX_FIREWALL_FD:-}"; do
        [ -z "$fd" ] || return 2
    done
    for saved_path in \
        "${LEGACY_TX_MUTATION_PATH:-}" \
        "${LEGACY_TX_SUBSCRIPTION_PATH:-}" \
        "${LEGACY_TX_FIREWALL_PATH:-}"; do
        [ -z "$saved_path" ] || return 2
    done
    STABLE_TX_MUTATION_DEPTH=0
    STABLE_TX_MUTATION_FD=''
    STABLE_TX_SUBSCRIPTION_DEPTH=0
    STABLE_TX_SUBSCRIPTION_FD=''
    STABLE_TX_FIREWALL_DEPTH=0
    STABLE_TX_FIREWALL_FD=''
    LEGACY_TX_MUTATION_DEPTH=0
    LEGACY_TX_MUTATION_FD=''
    LEGACY_TX_MUTATION_PATH=''
    LEGACY_TX_SUBSCRIPTION_DEPTH=0
    LEGACY_TX_SUBSCRIPTION_FD=''
    LEGACY_TX_SUBSCRIPTION_PATH=''
    LEGACY_TX_FIREWALL_DEPTH=0
    LEGACY_TX_FIREWALL_FD=''
    LEGACY_TX_FIREWALL_PATH=''
}

acquire_stable_transaction_lock() {
    local kind="${1:-}" timeout_seconds="${2:-${STABLE_TRANSACTION_LOCK_TIMEOUT_SECONDS:-30}}"
    local rank highest_rank depth_var fd_var depth lock_path lock_fd
    local path_identity fd_identity file_mode expected_gid

    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || return 1
    rank=$(stable_transaction_lock_rank "$kind") || return 1
    case "$kind" in
        mutation) depth_var=STABLE_TX_MUTATION_DEPTH; fd_var=STABLE_TX_MUTATION_FD ;;
        subscription) depth_var=STABLE_TX_SUBSCRIPTION_DEPTH; fd_var=STABLE_TX_SUBSCRIPTION_FD ;;
        firewall) depth_var=STABLE_TX_FIREWALL_DEPTH; fd_var=STABLE_TX_FIREWALL_FD ;;
        *) return 1 ;;
    esac
    depth="${!depth_var:-0}"
    [[ "$depth" =~ ^[0-9]+$ ]] || return 2
    highest_rank=$(stable_transaction_highest_rank) || return 2
    [ "$highest_rank" -le "$rank" ] || return 2
    if [ "$depth" -gt 0 ]; then
        printf -v "$depth_var" '%s' "$((depth + 1))"
        return 0
    fi

    command_exists flock || return 1
    ensure_stable_transaction_root || return $?
    lock_path=$(stable_transaction_lock_path "$kind") || return 2
    file_mode=$(transaction_expected_file_mode) || return 2
    expected_gid=$(transaction_expected_gid) || return 2
    path_identity=$(stat -c '%d:%i' -- "$lock_path" 2>/dev/null) || return 2
    exec {lock_fd}>>"$lock_path" || return 1
    fd_identity=$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/${lock_fd}" 2>/dev/null) || {
        exec {lock_fd}>&-
        return 2
    }
    if [ "$fd_identity" != "$path_identity" ]; then
        exec {lock_fd}>&-
        return 2
    fi
    if ! flock -x -w "$timeout_seconds" "$lock_fd"; then
        exec {lock_fd}>&-
        return 1
    fi
    if ! validate_transaction_regular_file "$lock_path" "$file_mode" "$expected_gid" || \
       [ "$(stat -c '%d:%i' -- "$lock_path" 2>/dev/null)" != "$path_identity" ]; then
        exec {lock_fd}>&-
        return 2
    fi
    printf -v "$fd_var" '%s' "$lock_fd"
    printf -v "$depth_var" '1'
    if ! stable_transaction_lock_hook acquired "$kind" "$lock_path"; then
        release_stable_transaction_lock "$kind" >/dev/null 2>&1 || true
        return 2
    fi
}

release_stable_transaction_lock() {
    local kind="${1:-}" rank highest_rank depth_var fd_var depth lock_fd

    rank=$(stable_transaction_lock_rank "$kind") || return 1
    case "$kind" in
        mutation) depth_var=STABLE_TX_MUTATION_DEPTH; fd_var=STABLE_TX_MUTATION_FD ;;
        subscription) depth_var=STABLE_TX_SUBSCRIPTION_DEPTH; fd_var=STABLE_TX_SUBSCRIPTION_FD ;;
        firewall) depth_var=STABLE_TX_FIREWALL_DEPTH; fd_var=STABLE_TX_FIREWALL_FD ;;
        *) return 1 ;;
    esac
    depth="${!depth_var:-0}"
    [[ "$depth" =~ ^[1-9][0-9]*$ ]] || return 2
    highest_rank=$(stable_transaction_highest_rank) || return 2
    [ "$highest_rank" -le "$rank" ] || return 2
    if [ "$depth" -gt 1 ]; then
        printf -v "$depth_var" '%s' "$((depth - 1))"
        return 0
    fi
    lock_fd="${!fd_var:-}"
    [[ "$lock_fd" =~ ^[0-9]+$ ]] || return 2
    flock -u "$lock_fd" >/dev/null 2>&1 || true
    exec {lock_fd}>&-
    printf -v "$fd_var" ''
    printf -v "$depth_var" '0'
    stable_transaction_lock_hook released "$kind" '' || return 2
}

with_stable_transaction_lock() {
    local kind="${1:-}" callback="${2:-}" callback_status=0 release_status=0
    shift 2 || return 1

    declare -F "$callback" >/dev/null 2>&1 || return 1
    acquire_stable_transaction_lock "$kind" || return $?
    "$callback" "$@" || callback_status=$?
    release_stable_transaction_lock "$kind" || release_status=$?
    [ "$release_status" -eq 0 ] || return 2
    return "$callback_status"
}

validate_safe_legacy_lock() {
    local lock_path="${1:-}" expected_gid file_mode actual_uid actual_gid actual_mode
    local link_count lock_dir

    [ -n "$lock_path" ] && [[ "$lock_path" = /* ]] || return 1
    [[ "$lock_path" != *$'\n'* && "$lock_path" != *$'\r'* ]] || return 1
    lock_dir=$(dirname "$lock_path") || return 1
    validate_transaction_path_components "$lock_dir" || return 1
    [ -f "$lock_path" ] && [ ! -L "$lock_path" ] || return 1
    actual_uid=$(stat -c '%u' -- "$lock_path" 2>/dev/null) || return 1
    actual_gid=$(stat -c '%g' -- "$lock_path" 2>/dev/null) || return 1
    actual_mode=$(stat -c '%a' -- "$lock_path" 2>/dev/null) || return 1
    link_count=$(stat -c '%h' -- "$lock_path" 2>/dev/null) || return 1
    expected_gid=$(transaction_expected_gid) || return 1
    file_mode=$(transaction_expected_file_mode) || return 1
    [ "$actual_uid" = "$(id -u)" ] && [ "$link_count" = 1 ] || return 1
    if [ "$actual_mode" = 600 ]; then
        return 0
    fi
    [ "$actual_mode" = "$file_mode" ] && [ "$actual_gid" = "$expected_gid" ]
}

acquire_safe_legacy_lock() {
    local kind="${1:-}" lock_path="${2:-}" timeout_seconds="${3:-${STABLE_TRANSACTION_LOCK_TIMEOUT_SECONDS:-30}}"
    local depth_var fd_var path_var depth saved_path lock_fd path_identity fd_identity

    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || return 1
    case "$kind" in
        mutation) depth_var=LEGACY_TX_MUTATION_DEPTH; fd_var=LEGACY_TX_MUTATION_FD; path_var=LEGACY_TX_MUTATION_PATH ;;
        subscription) depth_var=LEGACY_TX_SUBSCRIPTION_DEPTH; fd_var=LEGACY_TX_SUBSCRIPTION_FD; path_var=LEGACY_TX_SUBSCRIPTION_PATH ;;
        firewall) depth_var=LEGACY_TX_FIREWALL_DEPTH; fd_var=LEGACY_TX_FIREWALL_FD; path_var=LEGACY_TX_FIREWALL_PATH ;;
        *) return 1 ;;
    esac
    depth="${!depth_var:-0}"
    saved_path="${!path_var:-}"
    [[ "$depth" =~ ^[0-9]+$ ]] || return 2
    if [ "$depth" -gt 0 ]; then
        [ "$saved_path" = "$lock_path" ] || return 2
        printf -v "$depth_var" '%s' "$((depth + 1))"
        return 0
    fi
    [[ "$lock_path" != *$'\n'* && "$lock_path" != *$'\r'* ]] || return 2
    if [ -z "$lock_path" ] || { [ ! -e "$lock_path" ] && [ ! -L "$lock_path" ]; }; then
        printf -v "$path_var" '%s' "$lock_path"
        printf -v "$fd_var" ''
        printf -v "$depth_var" '1'
        if ! legacy_transaction_lock_hook skipped "$kind" "$lock_path"; then
            printf -v "$path_var" ''
            printf -v "$fd_var" ''
            printf -v "$depth_var" '0'
            return 2
        fi
        return 0
    fi
    command_exists flock || return 1
    validate_safe_legacy_lock "$lock_path" || return 2
    path_identity=$(stat -c '%d:%i' -- "$lock_path" 2>/dev/null) || return 2
    exec {lock_fd}<"$lock_path" || return 2
    fd_identity=$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/${lock_fd}" 2>/dev/null) || {
        exec {lock_fd}>&-
        return 2
    }
    if [ "$fd_identity" != "$path_identity" ]; then
        exec {lock_fd}>&-
        return 2
    fi
    if ! flock -x -w "$timeout_seconds" "$lock_fd"; then
        exec {lock_fd}>&-
        return 1
    fi
    if ! validate_safe_legacy_lock "$lock_path" || \
       [ "$(stat -c '%d:%i' -- "$lock_path" 2>/dev/null)" != "$path_identity" ]; then
        exec {lock_fd}>&-
        return 2
    fi
    printf -v "$path_var" '%s' "$lock_path"
    printf -v "$fd_var" '%s' "$lock_fd"
    printf -v "$depth_var" '1'
    if ! legacy_transaction_lock_hook acquired "$kind" "$lock_path"; then
        release_safe_legacy_lock "$kind" >/dev/null 2>&1 || true
        return 2
    fi
}

release_safe_legacy_lock() {
    local kind="${1:-}" depth_var fd_var path_var depth lock_fd

    case "$kind" in
        mutation) depth_var=LEGACY_TX_MUTATION_DEPTH; fd_var=LEGACY_TX_MUTATION_FD; path_var=LEGACY_TX_MUTATION_PATH ;;
        subscription) depth_var=LEGACY_TX_SUBSCRIPTION_DEPTH; fd_var=LEGACY_TX_SUBSCRIPTION_FD; path_var=LEGACY_TX_SUBSCRIPTION_PATH ;;
        firewall) depth_var=LEGACY_TX_FIREWALL_DEPTH; fd_var=LEGACY_TX_FIREWALL_FD; path_var=LEGACY_TX_FIREWALL_PATH ;;
        *) return 1 ;;
    esac
    depth="${!depth_var:-0}"
    [[ "$depth" =~ ^[1-9][0-9]*$ ]] || return 2
    if [ "$depth" -gt 1 ]; then
        printf -v "$depth_var" '%s' "$((depth - 1))"
        return 0
    fi
    lock_fd="${!fd_var:-}"
    if [ -n "$lock_fd" ]; then
        [[ "$lock_fd" =~ ^[0-9]+$ ]] || return 2
        flock -u "$lock_fd" >/dev/null 2>&1 || true
        exec {lock_fd}>&-
    fi
    printf -v "$fd_var" ''
    printf -v "$path_var" ''
    printf -v "$depth_var" '0'
    legacy_transaction_lock_hook released "$kind" '' || return 2
}

acquire_transaction_lock_with_legacy() {
    local kind="${1:-}" legacy_path="${2:-}" timeout_seconds="${3:-${STABLE_TRANSACTION_LOCK_TIMEOUT_SECONDS:-30}}"
    local status stable_release_status=0

    acquire_stable_transaction_lock "$kind" "$timeout_seconds" || return $?
    acquire_safe_legacy_lock "$kind" "$legacy_path" "$timeout_seconds"
    status=$?
    if [ "$status" -ne 0 ]; then
        release_stable_transaction_lock "$kind" >/dev/null 2>&1 || stable_release_status=$?
        [ "$stable_release_status" -eq 0 ] || return 2
        return "$status"
    fi
}

release_transaction_lock_with_legacy() {
    local kind="${1:-}" legacy_status=0 stable_status=0

    release_safe_legacy_lock "$kind" || legacy_status=$?
    release_stable_transaction_lock "$kind" || stable_status=$?
    [ "$legacy_status" -eq 0 ] && [ "$stable_status" -eq 0 ] || return 2
}

with_transaction_lock_with_legacy() {
    local kind="${1:-}" legacy_path="${2:-}" callback="${3:-}"
    local callback_status=0 release_status=0
    shift 3 || return 1

    declare -F "$callback" >/dev/null 2>&1 || return 1
    acquire_transaction_lock_with_legacy "$kind" "$legacy_path" || return $?
    "$callback" "$@" || callback_status=$?
    release_transaction_lock_with_legacy "$kind" || release_status=$?
    [ "$release_status" -eq 0 ] || return 2
    return "$callback_status"
}

finish_transaction_release() {
    local operation_status="${1:-}" release_callback="${2:-}" release_status=0

    [[ "$operation_status" =~ ^[0-9]+$ ]] && [ "$operation_status" -le 255 ] || return 2
    [[ "$release_callback" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && \
        declare -F "$release_callback" >/dev/null 2>&1 || return 2
    "$release_callback" || release_status=$?
    [ "$release_status" -eq 0 ] || return 2
    return "$operation_status"
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
        "${singbox_dir}/argo.env" \
        "${singbox_dir}/url.txt" \
        "${singbox_dir}/base-sub.txt" \
        "${singbox_dir}/cfy-url.txt" \
        "${singbox_dir}/cfy-sub.txt" \
        "${singbox_dir}/all-url.txt" \
        "${singbox_dir}/all-sub.txt"; do
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

render_singbox_systemd_service() {
    cat <<'EOF'
# sing-box-pre:managed-service-v1
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
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

render_singbox_openrc_service() {
    cat <<'EOF'
#!/sbin/openrc-run
# sing-box-pre:managed-service-v1
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF
}

render_argo_systemd_service() {
    local tunnel_mode="${1:-quick}"
    local environment_file=""
    local exec_start argo_listen_port="${ARGO_PORT:-${argo_port:-}}"

    case "$tunnel_mode" in
        token)
            environment_file='EnvironmentFile=-/etc/sing-box/argo.env'
            exec_start='/etc/sing-box/argo tunnel --no-autoupdate run'
            ;;
        local)
            exec_start='/etc/sing-box/argo tunnel --config /etc/sing-box/tunnel.yml --no-autoupdate run'
            ;;
        quick)
            [ -n "$argo_listen_port" ] || return 1
            exec_start="/bin/sh -c '/etc/sing-box/argo tunnel --url http://127.0.0.1:${argo_listen_port} --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1'"
            ;;
        *) return 1 ;;
    esac

    printf '%s\n' \
        '# sing-box-pre:managed-service-v1' \
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
}

render_argo_openrc_service() {
    local tunnel_mode="${1:-quick}"
    local command_args argo_listen_port="${ARGO_PORT:-${argo_port:-}}"

    case "$tunnel_mode" in
        token) command_args='tunnel --no-autoupdate run' ;;
        local) command_args='tunnel --config /etc/sing-box/tunnel.yml --no-autoupdate run' ;;
        quick)
            [ -n "$argo_listen_port" ] || return 1
            command_args="tunnel --url http://127.0.0.1:${argo_listen_port} --no-autoupdate --edge-ip-version auto --protocol http2"
            ;;
        *) return 1 ;;
    esac

    printf '%s\n' \
        '#!/sbin/openrc-run' \
        '# sing-box-pre:managed-service-v1' \
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
}

managed_service_definition_is_canonical() {
    local target_file="${1:-}"
    local definition_kind="${2:-}"
    local target_dir target_name candidate_file variant status=1 cleanup_status=0

    [ -f "$target_file" ] && [ ! -L "$target_file" ] && [ -r "$target_file" ] || return 1
    target_dir=$(dirname "$target_file") || return 1
    target_name=$(basename "$target_file") || return 1
    candidate_file=$(mktemp "${target_dir}/.managed-service-validate.${target_name}.XXXXXX") || return 1
    chmod 600 "$candidate_file" || { rm -f -- "$candidate_file"; return 1; }

    case "$definition_kind" in
        systemd-singbox)
            if render_singbox_systemd_service > "$candidate_file" && \
               cmp -s -- "$target_file" "$candidate_file"; then
                status=0
            fi
            ;;
        openrc-singbox)
            if render_singbox_openrc_service > "$candidate_file" && \
               cmp -s -- "$target_file" "$candidate_file"; then
                status=0
            fi
            ;;
        systemd-argo)
            for variant in quick token local; do
                if render_argo_systemd_service "$variant" > "$candidate_file" && \
                   cmp -s -- "$target_file" "$candidate_file"; then
                    status=0
                    break
                fi
            done
            ;;
        openrc-argo)
            for variant in quick token local; do
                if render_argo_openrc_service "$variant" > "$candidate_file" && \
                   cmp -s -- "$target_file" "$candidate_file"; then
                    status=0
                    break
                fi
            done
            ;;
        *) status=1 ;;
    esac

    rm -f -- "$candidate_file" || cleanup_status=1
    [ "$cleanup_status" -eq 0 ] || return 1
    return "$status"
}

managed_service_target_fingerprint() {
    local target_file="${1:-}"
    local before_identity after_identity digest_output digest

    [ -n "$target_file" ] || return 1
    if [ ! -e "$target_file" ] && [ ! -L "$target_file" ]; then
        printf 'absent\n'
        return 0
    fi
    [ -f "$target_file" ] && [ ! -L "$target_file" ] && [ -r "$target_file" ] || return 1
    before_identity=$(stat -c '%d:%i:%s:%a:%u:%g:%h' -- "$target_file" 2>/dev/null) || return 2
    digest_output=$(LC_ALL=C sha256sum "$target_file" 2>/dev/null) || return 2
    digest="${digest_output%%[[:space:]]*}"
    [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 2
    after_identity=$(stat -c '%d:%i:%s:%a:%u:%g:%h' -- "$target_file" 2>/dev/null) || return 2
    [ "$before_identity" = "$after_identity" ] || return 2
    printf 'present:%s:%s\n' "$before_identity" "$digest"
}

managed_service_writer_hook() {
    :
}

write_guarded_managed_service_definition_locked() {
    local target_file="${1:-}"
    local final_mode="${2:-}"
    local definition_kind="${3:-}"
    local renderer="${4:-}"
    local target_dir target_name tmp_file
    local initial_fingerprint validation_fingerprint final_fingerprint fingerprint_status=0
    local canonical_status=0
    shift 4 || return 1

    stable_transaction_lock_is_held mutation || return 2
    [ -n "$target_file" ] && [ -n "$renderer" ] || return 1
    case "$final_mode" in 644|700) ;; *) return 1 ;; esac
    case "$definition_kind" in
        systemd-singbox|openrc-singbox|systemd-argo|openrc-argo) ;;
        *) return 1 ;;
    esac
    declare -F "$renderer" >/dev/null || return 1

    initial_fingerprint=$(managed_service_target_fingerprint "$target_file") || fingerprint_status=$?
    case "$fingerprint_status" in
        0) ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
    if [ "$initial_fingerprint" != absent ]; then
        managed_service_definition_is_canonical "$target_file" "$definition_kind" || \
            canonical_status=$?
    fi
    validation_fingerprint=$(managed_service_target_fingerprint "$target_file") || return 2
    [ "$validation_fingerprint" = "$initial_fingerprint" ] || return 2
    [ "$canonical_status" -eq 0 ] || return 1

    target_dir=$(dirname "$target_file") || return 1
    target_name=$(basename "$target_file") || return 1
    mkdir -p "$target_dir" || return 1
    tmp_file=$(mktemp "${target_dir}/.managed-service.${target_name}.XXXXXX") || return 1
    chmod 600 "$tmp_file" || {
        rm -f -- "$tmp_file" || return 2
        return 1
    }
    if ! "$renderer" "$@" > "$tmp_file"; then
        rm -f -- "$tmp_file" || return 2
        return 1
    fi
    if ! managed_service_definition_is_canonical "$tmp_file" "$definition_kind"; then
        rm -f -- "$tmp_file" || return 2
        return 1
    fi
    chmod "$final_mode" "$tmp_file" || {
        rm -f -- "$tmp_file" || return 2
        return 1
    }
    if ! managed_service_writer_hook before-final-cas "$target_file" "$tmp_file" \
        "$initial_fingerprint"; then
        rm -f -- "$tmp_file" || true
        return 2
    fi
    # Keep the F2 check and mv adjacent: never insert a hook or other executable
    # logic here. POSIX shell has no atomic conditional rename, so the tiny
    # F2-to-mv window is unavoidable.
    final_fingerprint=$(managed_service_target_fingerprint "$target_file") || {
        rm -f -- "$tmp_file" || true
        return 2
    }
    if [ "$final_fingerprint" != "$initial_fingerprint" ]; then
        rm -f -- "$tmp_file" || true
        return 2
    fi
    mv -f -- "$tmp_file" "$target_file" || {
        rm -f -- "$tmp_file" || return 2
        return 1
    }
}

write_guarded_managed_service_definition() {
    with_stable_transaction_lock mutation write_guarded_managed_service_definition_locked "$@"
}

write_singbox_systemd_service() {
    local install_root="${1:-}"
    local unit_file="${install_root}/etc/systemd/system/sing-box.service"

    write_guarded_managed_service_definition "$unit_file" 644 \
        systemd-singbox render_singbox_systemd_service
}

write_singbox_openrc_service() {
    local install_root="${1:-}"
    local init_file="${install_root}/etc/init.d/sing-box"

    write_guarded_managed_service_definition "$init_file" 700 \
        openrc-singbox render_singbox_openrc_service
}

write_argo_systemd_service() {
    local tunnel_mode="${1:-quick}"
    local install_root="${2:-}"
    local unit_file="${install_root}/etc/systemd/system/argo.service"

    write_guarded_managed_service_definition "$unit_file" 644 \
        systemd-argo render_argo_systemd_service "$tunnel_mode"
}

write_argo_openrc_service() {
    local tunnel_mode="${1:-quick}"
    local install_root="${2:-}"
    local init_file="${install_root}/etc/init.d/argo"

    write_guarded_managed_service_definition "$init_file" 700 \
        openrc-argo render_argo_openrc_service "$tunnel_mode"
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

partial_install_state_path() {
    printf '%s\n' "${PARTIAL_INSTALL_STATE_FILE:-${work_dir}/install-resume.state}"
}

# Persist only the values that cannot be reconstructed without changing the
# published node identity. The file is written after managed definitions exist
# and before enable/start, so its presence is durable evidence that a partial
# install may be resumed without running install_singbox again.
persist_partial_install_resume_state() {
    local state_file

    state_file=$(partial_install_state_path) || return 1
    [[ "${uuid:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || return 1
    [[ "${password:-}" =~ ^[A-Za-z0-9]{24}$ ]] || return 1
    [[ "${private_key:-}" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || return 1
    [[ "${public_key:-}" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || return 1
    [[ "${ARGO_FIXED_READY:-0}" =~ ^[01]$ ]] || return 1
    if [ "${ARGO_FIXED_READY:-0}" = 1 ]; then
        is_argo_hostname "${ARGO_DOMAIN:-}" || return 1
    else
        [ -z "${ARGO_DOMAIN:-}" ] || return 1
    fi
    [ -n "$state_file" ] && [ ! -L "$state_file" ] || return 1

    {
        printf 'RESUME_VERSION=2\n'
        printf 'UUID=%s\n' "$uuid"
        printf 'PASSWORD=%s\n' "$password"
        printf 'PRIVATE_KEY=%s\n' "$private_key"
        printf 'PUBLIC_KEY=%s\n' "$public_key"
        printf 'ARGO_FIXED_READY=%s\n' "${ARGO_FIXED_READY:-0}"
        printf 'ARGO_DOMAIN=%s\n' "${ARGO_DOMAIN:-}"
    } | atomic_write_secret_file "$state_file" || return 1
    chmod 600 "$state_file"
}

load_partial_install_resume_state() {
    local state_file key value mode
    local resume_version='' resume_uuid='' resume_password=''
    local resume_private_key='' resume_public_key='' resume_argo_fixed=''
    local resume_argo_domain=''
    local version_count=0 uuid_count=0 password_count=0 private_count=0
    local public_count=0 argo_count=0 domain_count=0

    state_file=$(partial_install_state_path) || return 1
    [ -f "$state_file" ] && [ ! -L "$state_file" ] && [ -r "$state_file" ] || return 1
    mode=$(stat -c '%a' "$state_file" 2>/dev/null) || return 1
    [ "$mode" = 600 ] || return 1

    while IFS='=' read -r key value; do
        case "$key" in
            RESUME_VERSION) resume_version="$value"; version_count=$((version_count + 1)) ;;
            UUID) resume_uuid="$value"; uuid_count=$((uuid_count + 1)) ;;
            PASSWORD) resume_password="$value"; password_count=$((password_count + 1)) ;;
            PRIVATE_KEY) resume_private_key="$value"; private_count=$((private_count + 1)) ;;
            PUBLIC_KEY) resume_public_key="$value"; public_count=$((public_count + 1)) ;;
            ARGO_FIXED_READY) resume_argo_fixed="$value"; argo_count=$((argo_count + 1)) ;;
            ARGO_DOMAIN) resume_argo_domain="$value"; domain_count=$((domain_count + 1)) ;;
            *) return 1 ;;
        esac
    done < "$state_file"

    [ "$version_count" -eq 1 ] && [ "$uuid_count" -eq 1 ] && \
        [ "$password_count" -eq 1 ] && [ "$private_count" -eq 1 ] && \
        [ "$public_count" -eq 1 ] && [ "$argo_count" -eq 1 ] || return 1
    [[ "$resume_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || return 1
    [[ "$resume_password" =~ ^[A-Za-z0-9]{24}$ ]] || return 1
    [[ "$resume_private_key" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || return 1
    [[ "$resume_public_key" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || return 1
    [[ "$resume_argo_fixed" =~ ^[01]$ ]] || return 1
    case "$resume_version" in
        1)
            [ "$domain_count" -eq 0 ] && [ "$resume_argo_fixed" = 0 ] || return 1
            resume_argo_domain=''
            ;;
        2)
            [ "$domain_count" -eq 1 ] || return 1
            if [ "$resume_argo_fixed" = 1 ]; then
                is_argo_hostname "$resume_argo_domain" || return 1
            else
                [ -z "$resume_argo_domain" ] || return 1
            fi
            ;;
        *) return 1 ;;
    esac

    uuid="$resume_uuid"
    password="$resume_password"
    private_key="$resume_private_key"
    public_key="$resume_public_key"
    ARGO_FIXED_READY="$resume_argo_fixed"
    ARGO_DOMAIN="$resume_argo_domain"
}

validate_partial_install_config_credentials() {
    local inbounds_file="${conf_dir}/inbounds.json"

    [ -f "$inbounds_file" ] && [ ! -L "$inbounds_file" ] || return 1
    jq -e --arg uuid "$uuid" --arg private_key "$private_key" '
        ([.inbounds[] | select(.type == "vless") | .users[]?.uuid] as $vless |
            ($vless | length) > 0 and all($vless[]; . == $uuid)) and
        ([.inbounds[] | select(.type == "hysteria2") | .users[]?.password] as $hy2 |
            ($hy2 | length) > 0 and all($hy2[]; . == $uuid)) and
        ([.inbounds[] | select(.type == "tuic") | .users[]?] as $tuic |
            ($tuic | length) > 0 and
            all($tuic[]; .uuid == $uuid and .password == $uuid)) and
        ([.inbounds[] | select(.type == "vless" and
            ((.tag? // "") | startswith("vless-reality"))) |
            .tls.reality.private_key] as $reality |
            ($reality | length) > 0 and all($reality[]; . == $private_key))
    ' "$inbounds_file" >/dev/null 2>&1
}

validate_partial_install_config_ports() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local protocol expected actual

    [ -f "$inbounds_file" ] && [ ! -L "$inbounds_file" ] || return 1
    for protocol in reality hysteria2 tuic argo; do
        case "$protocol" in
            reality) expected="$vless_port" ;;
            hysteria2) expected="$hy2_port" ;;
            tuic) expected="$tuic_port" ;;
            argo) expected="$argo_port" ;;
            *) return 1 ;;
        esac
        actual=$(get_uniform_inbound_port "$inbounds_file" "$protocol") || return 1
        [ "$actual" = "$expected" ] || return 1
    done
}

partial_install_service_definition_is_managed() {
    local init_system="${1:-}" service_name="${2:-}"
    local definition tunnel_mode

    case "$init_system:$service_name" in
        systemd:sing-box|systemd:argo)
            definition="${INSTALL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${service_name}.service"
            [ -f "$definition" ] && [ ! -L "$definition" ] && [ -r "$definition" ] || return 1
            if [ "$service_name" = sing-box ]; then
                cmp -s -- "$definition" <(render_singbox_systemd_service)
                return $?
            fi
            for tunnel_mode in quick token local; do
                cmp -s -- "$definition" <(render_argo_systemd_service "$tunnel_mode") && return 0
            done
            return 1
            ;;
        openrc:sing-box|openrc:argo)
            definition="${INSTALL_OPENRC_INIT_DIR:-/etc/init.d}/${service_name}"
            [ -f "$definition" ] && [ ! -L "$definition" ] && [ -r "$definition" ] && \
                [ -x "$definition" ] || return 1
            if [ "$service_name" = sing-box ]; then
                cmp -s -- "$definition" <(render_singbox_openrc_service)
                return $?
            fi
            for tunnel_mode in quick token local; do
                cmp -s -- "$definition" <(render_argo_openrc_service "$tunnel_mode") && return 0
            done
            return 1
            ;;
        *) return 1 ;;
    esac
}

partial_install_argo_service_mode() {
    local init_system="${1:-}" definition renderer tunnel_mode

    case "$init_system" in
        systemd)
            definition="${INSTALL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/argo.service"
            renderer=render_argo_systemd_service
            ;;
        openrc)
            definition="${INSTALL_OPENRC_INIT_DIR:-/etc/init.d}/argo"
            renderer=render_argo_openrc_service
            ;;
        *) return 1 ;;
    esac
    [ -f "$definition" ] && [ ! -L "$definition" ] && [ -r "$definition" ] || return 1

    for tunnel_mode in quick token local; do
        if cmp -s -- "$definition" <("$renderer" "$tunnel_mode"); then
            printf '%s\n' "$tunnel_mode"
            return 0
        fi
    done
    return 1
}

validate_partial_install_argo_resume() {
    local init_system="${1:-}" tunnel_mode tunnel_config hostname
    local -a tunnel_hostnames=()

    tunnel_mode=$(partial_install_argo_service_mode "$init_system") || return 1
    case "${ARGO_FIXED_READY:-}" in
        0)
            [ -z "${ARGO_DOMAIN:-}" ] && [ "$tunnel_mode" = quick ]
            ;;
        1)
            is_argo_hostname "${ARGO_DOMAIN:-}" || return 1
            case "$tunnel_mode" in
                token) return 0 ;;
                local)
                    tunnel_config="${work_dir}/tunnel.yml"
                    [ -f "$tunnel_config" ] && [ ! -L "$tunnel_config" ] && \
                        [ -r "$tunnel_config" ] || return 1
                    while IFS= read -r hostname; do
                        tunnel_hostnames+=("$hostname")
                    done < <(awk '
                        match($0, /^[[:space:]]*-[[:space:]]+hostname:[[:space:]]*/) {
                            hostname = substr($0, RLENGTH + 1)
                            sub(/[[:space:]]+$/, "", hostname)
                            print hostname
                        }
                    ' "$tunnel_config")
                    [ "${#tunnel_hostnames[@]}" -eq 1 ] || return 1
                    is_argo_hostname "${tunnel_hostnames[0]}" || return 1
                    [ "${tunnel_hostnames[0],,}" = "${ARGO_DOMAIN,,}" ]
                    ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

partial_install_service_is_active() {
    local init_system="${1:-}" service_name="${2:-}"

    case "$init_system" in
        systemd) systemctl is-active --quiet "$service_name" >/dev/null 2>&1 ;;
        openrc) rc-service "$service_name" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

enable_install_services() {
    local init_system="${1:-}"

    case "$init_system" in
        systemd)
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            systemctl enable sing-box >/dev/null 2>&1 || return 1
            systemctl enable argo >/dev/null 2>&1 || return 1
            ;;
        openrc)
            rc-update add sing-box default >/dev/null 2>&1 || return 1
            rc-update add argo default >/dev/null 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac
}

partial_install_singbox_runtime_is_ready() {
    local init_system="${1:-}" rule port proto

    partial_install_service_is_active "$init_system" sing-box || return 1
    for rule in \
        "$vless_port/tcp" \
        "$tuic_port/udp" \
        "$hy2_port/udp" \
        "$argo_port/tcp"; do
        port="${rule%/*}"
        proto="${rule#*/}"
        port_is_listening "$port" "$proto" || return 1
    done
}

wait_for_partial_install_singbox_ready() {
    local init_system="${1:-}"
    local attempts="${PARTIAL_INSTALL_READY_ATTEMPTS:-12}"
    local interval="${PARTIAL_INSTALL_READY_INTERVAL:-1}"
    local attempt

    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        partial_install_singbox_runtime_is_ready "$init_system" && return 0
        [ "$attempt" -eq "$attempts" ] || sleep "$interval" || return 1
    done
    return 1
}

wait_for_partial_install_argo_stably_active() {
    local init_system="${1:-}"
    local attempts="${PARTIAL_INSTALL_READY_ATTEMPTS:-12}"
    local interval="${PARTIAL_INSTALL_READY_INTERVAL:-1}"
    local attempt stable_checks=0

    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if partial_install_service_is_active "$init_system" argo; then
            stable_checks=$((stable_checks + 1))
            [ "$stable_checks" -ge 2 ] && return 0
        else
            stable_checks=0
        fi
        [ "$attempt" -eq "$attempts" ] || sleep "$interval" || return 1
    done
    return 1
}

start_pending_install_services() {
    local init_system="${1:-}" service_name runtime_status service_was_active

    case "$init_system" in systemd|openrc) ;; *) return 1 ;; esac
    for service_name in sing-box argo; do
        service_was_active=0
        partial_install_service_is_active "$init_system" "$service_name" && service_was_active=1
        if [ "$service_name" = sing-box ]; then
            if validate_partial_install_resume_runtime "$init_system"; then
                runtime_status=0
            else
                runtime_status=$?
            fi
            [ "$runtime_status" -eq 0 ] || return "$runtime_status"
            service_was_active=0
            partial_install_service_is_active "$init_system" sing-box && service_was_active=1
        fi
        if [ "$service_was_active" -eq 0 ]; then
            case "$init_system" in
                systemd) systemctl start "$service_name" >/dev/null 2>&1 || return 1 ;;
                openrc) rc-service "$service_name" start >/dev/null 2>&1 || return 1 ;;
            esac
        fi
        if [ "$service_name" = sing-box ]; then
            wait_for_partial_install_singbox_ready "$init_system" || return 1
        else
            wait_for_partial_install_argo_stably_active "$init_system" || return 1
        fi
    done
}

partial_install_nginx_listener_is_managed() {
    local init_system="${1:-}" config_port

    if ! classify_nginx_subscription_config \
        "${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}"; then
        return 1
    fi
    config_port=$(get_nginx_subscription_port \
        "${NGINX_SUBSCRIPTION_CONF:-/etc/nginx/conf.d/sing-box.conf}") || return 1
    [ "$config_port" = "$nginx_port" ] || return 1
    partial_install_service_is_active "$init_system" nginx
}

validate_partial_install_resume_runtime() {
    local init_system="${1:-}" rule port proto singbox_active=0

    partial_install_service_definition_is_managed "$init_system" sing-box || return 2
    partial_install_service_definition_is_managed "$init_system" argo || return 2
    partial_install_service_is_active "$init_system" sing-box && singbox_active=1

    for rule in \
        "$vless_port/tcp" \
        "$tuic_port/udp" \
        "$hy2_port/udp" \
        "$argo_port/tcp"; do
        port="${rule%/*}"
        proto="${rule#*/}"
        if [ "$singbox_active" -eq 1 ]; then
            port_is_listening "$port" "$proto" || return 2
        elif port_is_listening "$port" "$proto"; then
            return 2
        fi
    done
    if port_is_listening "$nginx_port" tcp; then
        partial_install_nginx_listener_is_managed "$init_system" || return 2
    fi
}

# Return 0 for a safe resumable late-stage install, 1 when no resume evidence
# exists, and 2 when evidence exists but cannot be proven safe.  Callers must
# never fall back to a credential-regenerating install after status 2.
prepare_partial_install_resume() {
    local init_system="${1:-}" state_file

    state_file=$(partial_install_state_path) || return 2
    [ -e "$state_file" ] || [ -L "$state_file" ] || return 1
    load_partial_install_resume_state || return 2
    validate_partial_install_argo_resume "$init_system" || return 2
    validate_installed_singbox_config_strict || return 2
    validate_partial_install_config_credentials || return 2
    validate_partial_install_config_ports || return 2
    fingerprint=$(get_hy2_certificate_fingerprint) || return 2
    validate_partial_install_resume_runtime "$init_system" || return 2
}

clear_partial_install_resume_state() {
    local state_file

    state_file=$(partial_install_state_path) || return 1
    [ -n "$state_file" ] || return 1
    rm -f -- "$state_file"
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
    local service_name service_definition init_system

    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        systemd)
            for service_definition in sing-box.service argo.service; do
                [ -s "${LEGACY_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${service_definition}" ] || return 1
            done
            for service_name in sing-box argo nginx; do
                systemctl is-active --quiet "$service_name" >/dev/null 2>&1 || return 1
            done
            ;;
        openrc)
            for service_definition in sing-box argo; do
                [ -s "${LEGACY_OPENRC_INIT_DIR:-/etc/init.d}/${service_definition}" ] && \
                    [ -x "${LEGACY_OPENRC_INIT_DIR:-/etc/init.d}/${service_definition}" ] || return 1
            done
            for service_name in sing-box argo nginx; do
                rc-service "$service_name" status >/dev/null 2>&1 || return 1
            done
            ;;
        *) return 1 ;;
    esac
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
    local resume_file=''

    if check_singbox &>/dev/null && is_install_complete; then
        if declare -F partial_install_state_path >/dev/null 2>&1; then
            resume_file=$(partial_install_state_path 2>/dev/null || true)
            if [ -n "$resume_file" ] && { [ -e "$resume_file" ] || [ -L "$resume_file" ]; }; then
                clear_partial_install_resume_state || return 2
            fi
        fi
        return 0
    fi
    if declare -F partial_install_state_path >/dev/null 2>&1; then
        resume_file=$(partial_install_state_path 2>/dev/null || true)
        if [ -n "$resume_file" ] && { [ -e "$resume_file" ] || [ -L "$resume_file" ]; }; then
            return 1
        fi
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
    local init_system

    [[ ! -f "${service_file}" ]] && { red "not installed"; return 2; }

    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        openrc)
            rc-service "${service_name}" status | grep -q "started" && green "running" || yellow "not running"
            ;;
        systemd)
            systemctl is-active "${service_name}" | grep -q "^active$" && green "running" || yellow "not running"
            ;;
        *) return 1 ;;
    esac
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

# Query package ownership independently from executable discovery.  Return 0
# for installed, 1 for definitely absent, and 2 when the package database
# cannot be queried safely.
package_is_installed() {
    local package="${1:-}"
    local query_output='' query_status=0

    [ -n "$package" ] || return 2
    if command_exists apt; then
        command_exists dpkg-query || return 2
        query_output=$(dpkg-query -W -f='${Status}\n' -- "$package" 2>/dev/null) || query_status=$?
        case "$query_status" in
            0) [ "$query_output" = 'install ok installed' ] && return 0; return 2 ;;
            1) return 1 ;;
            *) return 2 ;;
        esac
    elif command_exists dnf || command_exists yum; then
        command_exists rpm || return 2
        rpm -q -- "$package" >/dev/null 2>&1 || query_status=$?
        case "$query_status" in
            0) return 0 ;;
            1) return 1 ;;
            *) return 2 ;;
        esac
    elif command_exists apk; then
        apk info -e "$package" >/dev/null 2>&1 || query_status=$?
        case "$query_status" in
            0) return 0 ;;
            1) return 1 ;;
            *) return 2 ;;
        esac
    fi
    return 2
}

# 根据系统类型安装、卸载依赖
manage_packages() {
    local action package package_status

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
            if package_is_installed "$package"; then
                package_status=0
            else
                package_status=$?
            fi
            case "$package_status" in
                0) ;;
                1)
                    yellow "${package} is not installed"
                    continue
                    ;;
                *)
                    red "无法可靠查询 ${package} 的安装状态；已中止卸载。"
                    return 1
                    ;;
            esac
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" || return 1
            elif command_exists dnf; then
                dnf remove -y "$package" || return 1
            elif command_exists yum; then
                yum remove -y "$package" || return 1
            elif command_exists apk; then
                apk del "$package" || return 1
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

    [[ ! "$hostname" =~ ^[0-9.]+$ ]] && is_valid_subscription_domain "$hostname"
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
    local init_system

    if [ -z "$service_file" ]; then
        init_system=$(detect_usable_init_system) || return 1
        case "$init_system" in
            systemd) service_file="${ARGO_SYSTEMD_SERVICE_FILE:-/etc/systemd/system/argo.service}" ;;
            openrc) service_file="${ARGO_OPENRC_SERVICE_FILE:-/etc/init.d/argo}" ;;
            *) return 1 ;;
        esac
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
    local timeout_seconds="${FIREWALL_LOCK_TIMEOUT_SECONDS:-30}"

    command_exists flock || { red "缺少 flock，拒绝在无锁状态修改防火墙。"; return 1; }
    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || return 1
    acquire_transaction_lock_with_legacy firewall "$lock_file" "$timeout_seconds" || return $?
    FIREWALL_LOCK_FD="${STABLE_TX_FIREWALL_FD:-}"
}

release_firewall_lock() {
    stable_transaction_lock_is_held firewall || return 0
    release_transaction_lock_with_legacy firewall || return $?
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

# Return 0 when an unmanaged nftables INPUT base chain can filter traffic
# (non-accept policy or any rule), 1 when no effective unmanaged filtering
# exists (including an empty accept-policy chain or nft not installed), and 2
# when the ruleset cannot be queried or parsed safely.  This helper never
# mutates nft.
nft_input_filter_status() {
    local ignore_v4="${1:-0}" ignore_v6="${2:-0}" ruleset status

    [[ "$ignore_v4" =~ ^[01]$ && "$ignore_v6" =~ ^[01]$ ]] || return 2
    command_exists nft || return 1
    ruleset=$(nft -j list ruleset 2>/dev/null) || return 2
    printf '%s' "$ruleset" | jq -e \
        'type == "object" and (.nftables | type == "array")' >/dev/null 2>&1 || return 2
    if printf '%s' "$ruleset" | jq -e --arg ignore_v4 "$ignore_v4" --arg ignore_v6 "$ignore_v6" \
        '. as $root |
         [$root.nftables[]? | .chain? |
          select(type == "object" and .hook == "input") |
          select((((($ignore_v4 == "1") and .family == "ip" and .table == "filter" and .name == "INPUT") or
                   (($ignore_v6 == "1") and .family == "ip6" and .table == "filter" and .name == "INPUT"))) | not)] as $chains |
         any($chains[];
             . as $chain |
             (($chain.policy // "") != "accept") or
             any($root.nftables[]? | .rule?;
                 type == "object" and
                 .family == $chain.family and
                 .table == $chain.table and
                 .chain == $chain.name))' \
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
                FIREWALL_LAST_RESULT_REASON=manual-firewall
                return 1
                ;;
            1)
                yellow "未检测到本机防火墙后端；nftables 未启用有效 INPUT 过滤，未修改本机规则。"
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
                FIREWALL_LAST_RESULT_REASON=manual-firewall
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
                    FIREWALL_LAST_RESULT_REASON=manual-firewall
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
                FIREWALL_LAST_RESULT_REASON=manual-firewall
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
                        FIREWALL_LAST_RESULT_REASON=manual-firewall
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
    local status=0 release_status=0

    FIREWALL_LAST_RESULT_REASON=''
    acquire_firewall_lock || return $?
    _allow_port_locked "$@" || status=$?
    release_firewall_lock || release_status=$?
    [ "$release_status" -eq 0 ] || return 2
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
    local status=0 release_status=0

    acquire_firewall_lock || return $?
    _remove_owned_firewall_port_locked "$@" || status=$?
    release_firewall_lock || release_status=$?
    [ "$release_status" -eq 0 ] || return 2
    return "$status"
}

remove_owned_firewall_records_exact() {
    local status=0 release_status=0

    [ "$#" -gt 0 ] || return 0
    acquire_firewall_lock || return $?
    _remove_owned_firewall_records_locked exact "$@" || status=$?
    release_firewall_lock || release_status=$?
    [ "$release_status" -eq 0 ] || return 2
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
    local status=0 release_status=0

    [ "$#" -gt 0 ] || return 0
    acquire_firewall_lock || return $?
    _remove_owned_firewall_ports_locked "$@" || status=$?
    release_firewall_lock || release_status=$?
    [ "$release_status" -eq 0 ] || return 2
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
    local status=0 release_status=0

    [ "$#" -gt 1 ] || return 1
    acquire_firewall_lock || return $?
    _remove_owned_firewall_ports_if_unused_locked "$@" || status=$?
    release_firewall_lock || release_status=$?
    [ "$release_status" -eq 0 ] || return 2
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

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
    [ -f "$client_dir" ] && [ ! -L "$client_dir" ] || return 1
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

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
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
    local tmp_file publish_status

    tmp_file=$(mktemp "$(dirname "$client_dir")/.tmp.$(basename "$client_dir").hy2-restore.XXXXXX") || return 1
    if [ -e "${backup_dir}/present.0" ]; then
        cp -p -- "${backup_dir}/file.0" "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    else
        : > "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    fi
    chmod 600 "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    update_sub "$tmp_file" || {
        publish_status=$?
        rm -f -- "$tmp_file"
        return "$publish_status"
    }
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

cleanup_hy2_committed_transaction() {
    local backup_dir="${1:-}"

    [ -d "$backup_dir" ] || return 0
    if rm -rf -- "$backup_dir"; then
        return 0
    fi
    red "Hysteria2 提交已完成，但事务备份清理失败。保留路径: ${backup_dir}"
    return 3
}

_enable_hy2_port_hopping_transaction_locked() {
    local min_port="${1:-}"
    local max_port="${2:-}"
    local listen_port server_ip fingerprint node_label

    validate_port_value "$min_port" hy2_hop_min_port || return 1
    validate_port_value "$max_port" hy2_hop_max_port || return 1
    [ "$min_port" -lt "$max_port" ] || return 1
    listen_port=$(get_uniform_inbound_port "${conf_dir}/inbounds.json" hysteria2) || return 1
    validate_port_value "$listen_port" hy2_listen_port || return 1
    server_ip=$(get_realip) || return 1
    [ -n "$server_ip" ] || return 1
    fingerprint=$(get_hy2_certificate_fingerprint) || return 1
    node_label=$(get_hy2_node_label) || return 1
    with_subscription_lock enable_hy2_port_hopping_transaction_locked \
        "$min_port" "$max_port" "$listen_port" "$server_ip" "$fingerprint" "$node_label"
}

enable_hy2_port_hopping_transaction_locked() {
    local min_port="$1"
    local max_port="$2"
    local listen_port="$3"
    local server_ip="$4"
    local fingerprint="$5"
    local node_label="$6"
    local backup_dir staged_file was_active=0

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
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
       ! update_sub "$staged_file" ||
       { [ "$was_active" -eq 1 ] && ! restart_singbox; }; then
        handle_hy2_menu_transaction_failure "$backup_dir" "$was_active" "$staged_file"
        return $?
    fi

    cleanup_hy2_committed_transaction "$backup_dir"
}

enable_hy2_port_hopping_transaction() {
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "Hysteria2 端口跳跃操作"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _enable_hy2_port_hopping_transaction_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
}

_disable_hy2_port_hopping_transaction_locked() {
    with_subscription_lock disable_hy2_port_hopping_transaction_locked
}

disable_hy2_port_hopping_transaction_locked() {
    local backup_dir staged_file was_active=0

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
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
       ! update_sub "$staged_file" ||
       { [ "$was_active" -eq 1 ] && ! restart_singbox; }; then
        handle_hy2_menu_transaction_failure "$backup_dir" "$was_active" "$staged_file"
        return $?
    fi

    cleanup_hy2_committed_transaction "$backup_dir"
}

disable_hy2_port_hopping_transaction() {
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "Hysteria2 端口跳跃操作"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _disable_hy2_port_hopping_transaction_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
}

public_route_dns_strategy() {
    local route4=0 route6=0

    # Listener/address availability does not imply a usable public route.
    # These lookups do not send packets or depend on working DNS.
    if command -v ip >/dev/null 2>&1; then
        ip -4 route get 1.1.1.1 >/dev/null 2>&1 && route4=1
        ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1 && route6=1
    fi
    case "${route4}:${route6}" in
        1:0) printf '%s\n' ipv4_only ;;
        0:1) printf '%s\n' ipv6_only ;;
        *) printf '%s\n' prefer_ipv4 ;;
    esac
}

render_vless_reality_inbound() {
    local tag="${1:-}"
    local listen_address="${2:-}"
    local dns_strategy="${3:-prefer_ipv4}"

    [ -n "$tag" ] && [ -n "$listen_address" ] || return 1
    case "$dns_strategy" in ipv4_only|ipv6_only|prefer_ipv4) ;; *) return 1 ;; esac
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
            "server_port": 443,
            "domain_resolver": {"server": "local", "strategy": "$dns_strategy"}
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
    local listener suffix dns_strategy separator=''
    local -a listeners suffixes

    [[ "$has_v4" =~ ^[01]$ && "$has_v6" =~ ^[01]$ && "$bindv6only" =~ ^[01]$ ]] || return 1
    [ "$has_v4" = 1 ] || [ "$has_v6" = 1 ] || return 1
    dns_strategy=$(public_route_dns_strategy) || return 1

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
        render_vless_reality_inbound "vless-reality${suffix}" "$listener" "$dns_strategy" || return 1
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

# Preserve allow_port's tri-state result.  A known, non-mutating firewall
# ownership conflict may continue only after an explicit install-time
# confirmation that the operator will manage the required ports manually.
open_install_firewall_ports() {
    local has_v4="${1:-0}" has_v6="${2:-0}" status confirm=''

    if allow_port --families "$has_v4" "$has_v6" \
        "$vless_port/tcp" "$nginx_port/tcp" "$tuic_port/udp" "$hy2_port/udp"; then
        return 0
    else
        status=$?
    fi
    if [ "$status" -eq 1 ] && [ "${FIREWALL_LAST_RESULT_REASON:-}" = manual-firewall ]; then
        if declare -p FIREWALL_LAST_ADDED_RECORDS >/dev/null 2>&1 &&
           [ "${#FIREWALL_LAST_ADDED_RECORDS[@]}" -ne 0 ]; then
            red "防火墙操作已产生所有权记录，拒绝切换为手动管理模式。"
            return 2
        fi
        yellow "脚本未修改现有 nftables/iptables 规则。"
        yellow "请手动放行 TCP 端口 ${vless_port}、${nginx_port}，以及 UDP 端口 ${tuic_port}、${hy2_port}。"
        reading "确认由您负责放行以上端口并继续安装？[y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            yellow "已选择手动管理防火墙；继续安装 sing-box。"
            return 0
        fi
        red "未确认手动管理防火墙，安装中止。"
        return 1
    fi
    return "$status"
}

# 下载并安装 sing-box,cloudflared
install_singbox() {
    local has_v4=0
    local has_v6=0
    local bindv6only=0
    local dns_strategy direct_dns_strategy
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
    direct_dns_strategy=$(public_route_dns_strategy) || return 1
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
      "tag": "direct",
      "domain_resolver": {"server": "local", "strategy": "$direct_dns_strategy"}
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
  "experimental": {
    "cache_file": {"enabled": true, "path": "${work_dir}/cache.db"}
  },
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
      {"tag":"streaming","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-entertainment.srs","download_detour":"direct"}
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
    local argo_mode=""
    local tunnel_id=""
    local fixed_argo_requested=0
    local writer_status=0

    write_singbox_systemd_service || {
        writer_status=$?
        return "$writer_status"
    }
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
    write_argo_systemd_service "$argo_mode" || {
        writer_status=$?
        return "$writer_status"
    }
    if [ -f /etc/centos-release ]; then
        yum install -y chrony || return 1
        systemctl start chronyd || return 1
        systemctl enable chronyd || return 1
        chronyc -a makestep || return 1
        yum update -y ca-certificates || return 1
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range' || return 1
    fi
}

# 适配alpine 守护进程
alpine_openrc_services() {
    local argo_mode=""
    local tunnel_id=""
    local fixed_argo_requested=0
    local writer_status=0

    write_singbox_openrc_service || {
        writer_status=$?
        return "$writer_status"
    }
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
    write_argo_openrc_service "$argo_mode" || {
        writer_status=$?
        return "$writer_status"
    }
}

# 生成节点和订阅链接
get_info() {
    local url_file tmp_url_file base_source_generation

    url_file="${client_dir:-${work_dir}/url.txt}"
    base_source_generation=$(get_base_subscription_generation "$url_file") || {
        red "无法记录当前订阅源代际，拒绝生成节点。"
        return 1
    }

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

    reality_v4_name="${isp}-vless-reality-ipv4"
    reality_v6_name="${isp}-vless-reality-ipv6"
    argo_name="${isp}-vless-ws-tls-argo"

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

    chmod 600 "$tmp_url_file" 2>/dev/null || { rm -f "$tmp_url_file"; return 1; }
    publish_generated_base "$tmp_url_file" "$base_source_generation" || {
        local publish_status=$?
        rm -f "$tmp_url_file"
        return "$publish_status"
    }
    rm -f "$tmp_url_file"

    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < "$url_file"
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
    local has_ipv6=0 init_system

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

    [ "$preserve_service_state" = 0 ] && return 0
    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        openrc)
            if ! rc-service nginx reload > /dev/null 2>&1 && \
               ! rc-service nginx restart > /dev/null 2>&1; then
                if [ "$had_config" = 1 ]; then
                    cp -p "$backup_file" "$config_file"
                else
                    rm -f "$config_file"
                fi
                rc-service nginx restart > /dev/null 2>&1 || true
                return 1
            fi
            ;;
        systemd)
            if ! systemctl reload nginx > /dev/null 2>&1 && \
               { [ "$preserve_service_state" = 1 ] && ! systemctl restart nginx > /dev/null 2>&1 ||
                 [ "$preserve_service_state" = start ] && ! systemctl start nginx > /dev/null 2>&1; }; then
                if [ "$had_config" = 1 ]; then
                    cp -p "$backup_file" "$config_file"
                else
                    rm -f "$config_file"
                fi
                systemctl restart nginx > /dev/null 2>&1 || true
                return 1
            fi
            ;;
        *) return 1 ;;
    esac

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

ensure_nginx_conf_d_include() {
    local main_conf="${1:-}"
    local nginx_conf_dir="${2:-}"
    local tmp_file mode

    [ -f "$main_conf" ] && [ ! -L "$main_conf" ] && [ -n "$nginx_conf_dir" ] || return 1
    if awk -v wanted="${nginx_conf_dir}/*.conf;" '
        {
            line=$0
            sub(/[[:space:]]*#.*/, "", line)
            if ($1 == "include" && $2 == wanted) found=1
        }
        END { exit !found }
    ' "$main_conf"; then
        return 0
    fi

    tmp_file=$(mktemp "$(dirname "$main_conf")/.nginx-main.XXXXXX") || return 1
    if ! awk -v include_path="$nginx_conf_dir" '
        BEGIN { in_http=0; depth=0; inserted=0 }
        {
            code=$0
            sub(/[[:space:]]*#.*/, "", code)
            open_copy=code
            close_copy=code
            opens=gsub(/\{/, "", open_copy)
            closes=gsub(/\}/, "", close_copy)
            if (!in_http && code ~ /^[[:space:]]*http[[:space:]]*\{/) {
                in_http=1
                depth=opens-closes
                print
                next
            }
            if (in_http) {
                next_depth=depth+opens-closes
                if (next_depth == 0 && closes > 0) {
                    print "    # sing-box-pre:conf.d:start"
                    print "    include " include_path "/*.conf;"
                    print "    # sing-box-pre:conf.d:end"
                    inserted=1
                    in_http=0
                }
                depth=next_depth
            }
            print
        }
        END { if (!inserted) exit 42 }
    ' "$main_conf" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    mode=$(stat -c '%a' "$main_conf" 2>/dev/null) || {
        rm -f "$tmp_file"
        return 1
    }
    chmod "$mode" "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv -f "$tmp_file" "$main_conf"
}

remove_managed_nginx_include() {
    local main_conf="${1:-}"
    local nginx_conf_dir="${2:-${NGINX_CONF_DIR:-/etc/nginx/conf.d}}"
    local candidate tmp_file mode keep_owned_block=0

    [ -e "$main_conf" ] || return 0
    [ -f "$main_conf" ] && [ ! -L "$main_conf" ] || return 1
    if [ -d "$nginx_conf_dir" ]; then
        for candidate in "$nginx_conf_dir"/*.conf; do
            [ -e "$candidate" ] || continue
            [ "$(basename "$candidate")" = sing-box.conf ] || keep_owned_block=1
        done
    fi

    tmp_file=$(mktemp "$(dirname "$main_conf")/.nginx-main-clean.XXXXXX") || return 1
    if ! awk -v include_path="$nginx_conf_dir" -v keep="$keep_owned_block" '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        { lines[++count]=$0 }
        END {
            start_count=0
            end_count=0
            block_start=0
            expected="include " include_path "/*.conf;"
            for (i=1; i<=count; i++) {
                if (lines[i] ~ /^[[:space:]]*# sing-box-pre:conf[.]d:start[[:space:]]*$/) {
                    start_count++
                    if (i+2 <= count && trim(lines[i+1]) == expected &&
                        lines[i+2] ~ /^[[:space:]]*# sing-box-pre:conf[.]d:end[[:space:]]*$/) {
                        block_start=i
                    }
                }
                if (lines[i] ~ /^[[:space:]]*# sing-box-pre:conf[.]d:end[[:space:]]*$/) {
                    end_count++
                }
            }
            if (start_count == 0 && end_count == 0) {
                for (i=1; i<=count; i++) print lines[i]
                exit 0
            }
            if (start_count != 1 || end_count != 1 || block_start == 0) exit 42
            for (i=1; i<=count; i++) {
                if (!keep && i >= block_start && i <= block_start+2) continue
                print lines[i]
            }
        }
    ' "$main_conf" > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    mode=$(stat -c '%a' "$main_conf" 2>/dev/null) || {
        rm -f "$tmp_file"
        return 1
    }
    chmod "$mode" "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv -f "$tmp_file" "$main_conf"
}

add_nginx_conf() {
    local main_conf="${NGINX_MAIN_CONF:-/etc/nginx/nginx.conf}"
    local nginx_conf_dir="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
    local backup_file init_system

    command_exists nginx || { red "nginx未安装，无法配置订阅服务"; return 1; }
    mkdir -p "$nginx_conf_dir" || return 1
    [ -f "$main_conf" ] && [ ! -L "$main_conf" ] || {
        red "Nginx 主配置不存在或不安全，拒绝自动创建/覆盖。"
        return 1
    }
    backup_file=$(mktemp "$(dirname "$main_conf")/.nginx-main-backup.XXXXXX") || return 1
    cp -p "$main_conf" "$backup_file" || { rm -f "$backup_file"; return 1; }
    ensure_nginx_conf_d_include "$main_conf" "$nginx_conf_dir" || {
        rm -f "$backup_file"
        red "无法安全接入 Nginx conf.d，主配置保持不变。"
        return 1
    }

    if apply_nginx_subscription_config "$nginx_port" "/$password" ""; then
        init_system=$(detect_usable_init_system) || {
            rm -f "$backup_file"
            red "无法确认 Nginx 所属 init backend，安装中止。"
            return 1
        }
        case "$init_system" in
            systemd) systemctl enable nginx >/dev/null 2>&1 ;;
            openrc) rc-update add nginx default >/dev/null 2>&1 ;;
            *) return 1 ;;
        esac || {
            rm -f "$backup_file"
            red "Nginx 配置已加载，但服务 enable 失败；安装重试状态已保留。"
            return 1
        }
        rm -f "$backup_file"
        green "nginx订阅配置已加载"
    else
        mv -f "$backup_file" "$main_conf" || \
            red "Nginx 主配置回滚失败，备份保留在：$backup_file"
        red "nginx订阅配置测试失败，已恢复原配置"
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
    local service_file='' status='' check_status=0 action_status=1 init_system

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"; return 1
    fi

    case "$service_name" in
        sing-box) service_file="${work_dir}/${server_name:-sing-box}" ;;
        argo) service_file="${work_dir}/argo" ;;
        nginx) service_file=$(command -v nginx 2>/dev/null || true) ;;
    esac
    init_system=$(detect_usable_init_system) || {
        red "找不到可用的服务管理器。\n"
        return 1
    }
    status=$(check_service "$service_name" "$service_file" 2>/dev/null) || check_status=$?

    case "$action" in
        "start")
            [ "$check_status" -eq 2 ] && { yellow "${service_name} 尚未安装!\n"; return 1; }
            case "$status" in
                *"not running"*) ;;
                *"running"*) yellow "${service_name} 正在运行\n"; return 0 ;;
            esac
            yellow "正在启动 ${service_name} 服务\n"
            case "$init_system" in
                openrc) rc-service "$service_name" start; action_status=$? ;;
                systemd)
                    if systemctl daemon-reload; then
                        systemctl start "$service_name"
                        action_status=$?
                    fi
                    ;;
                *) return 1 ;;
            esac
            ;;
        "stop")
            [ "$check_status" -eq 2 ] && { yellow "${service_name} 尚未安装！\n"; return 2; }
            case "$status" in
                *"not running"*) yellow "${service_name} 未运行\n"; return 1 ;;
            esac
            yellow "正在停止 ${service_name} 服务\n"
            case "$init_system" in
                openrc) rc-service "$service_name" stop; action_status=$? ;;
                systemd) systemctl stop "$service_name"; action_status=$? ;;
                *) return 1 ;;
            esac
            ;;
        "restart")
            [ "$check_status" -eq 2 ] && { yellow "${service_name} 尚未安装！\n"; return 1; }
            yellow "正在重启 ${service_name} 服务\n"
            case "$init_system" in
                openrc) rc-service "$service_name" restart; action_status=$? ;;
                systemd)
                    if systemctl daemon-reload; then
                        systemctl restart "$service_name"
                        action_status=$?
                    fi
                    ;;
                *) return 1 ;;
            esac
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

query_nginx_service_state() {
    local init_system raw_status

    if ! init_system=$(detect_usable_init_system); then
        printf 'error\n'
        return 0
    fi
    case "$init_system" in
        systemd)
            if systemctl is-active --quiet nginx >/dev/null 2>&1; then
                raw_status=0
            else
                raw_status=$?
            fi
            ;;
        openrc)
            if rc-service nginx status >/dev/null 2>&1; then
                raw_status=0
            else
                raw_status=$?
            fi
            ;;
        *) raw_status=1 ;;
    esac
    case "$raw_status" in
        0) printf 'active\n' ;;
        3) printf 'inactive\n' ;;
        *) printf 'error\n' ;;
    esac
}

nginx_service_is_active() {
    local init_system

    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        openrc) rc-service nginx status >/dev/null 2>&1 ;;
        systemd) systemctl is-active --quiet nginx ;;
        *) return 1 ;;
    esac
}

stop_nginx_checked() {
    local init_system

    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        openrc) rc-service nginx stop >/dev/null 2>&1 ;;
        systemd) systemctl stop nginx >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
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
                elif $protocol == "argo" then
                    (.type == "vless" and
                     ((.tag? // "") == "vless-ws-argo" or
                      (.tag? // "") == "vless-ws-argo-ipv6"))
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

validate_uuid_value() {
    local value="${1:-}"

    [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

node_change_snapshot_path() {
    local source_path="${1:-}"
    local transaction_dir="${2:-}"
    local source_key="${3:-}"
    local snapshot_path marker_path

    [ -n "$source_path" ] && [ -d "$transaction_dir" ] && [ ! -L "$transaction_dir" ] || return 1
    [[ "$source_key" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    snapshot_path="${transaction_dir}/${source_key}.data"
    marker_path="${transaction_dir}/${source_key}"
    [ ! -e "$snapshot_path" ] && [ ! -L "$snapshot_path" ] || return 1
    [ ! -e "${marker_path}.present" ] && [ ! -e "${marker_path}.absent" ] || return 1

    if [ -e "$source_path" ] || [ -L "$source_path" ]; then
        cp -a -- "$source_path" "$snapshot_path" || return 1
        : > "${marker_path}.present" || return 1
        chmod 600 "${marker_path}.present" || return 1
    else
        : > "${marker_path}.absent" || return 1
        chmod 600 "${marker_path}.absent" || return 1
    fi
}

node_change_restore_path() {
    local destination_path="${1:-}"
    local transaction_dir="${2:-}"
    local source_key="${3:-}"
    local snapshot_path marker_path destination_parent

    [ -n "$destination_path" ] && [ "$destination_path" != / ] || return 1
    [ -d "$transaction_dir" ] && [ ! -L "$transaction_dir" ] || return 1
    [[ "$source_key" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    snapshot_path="${transaction_dir}/${source_key}.data"
    marker_path="${transaction_dir}/${source_key}"

    if [ -f "${marker_path}.present" ] && [ ! -e "${marker_path}.absent" ]; then
        [ -e "$snapshot_path" ] || [ -L "$snapshot_path" ] || return 1
        destination_parent=$(dirname "$destination_path") || return 1
        mkdir -p -- "$destination_parent" || return 1
        if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
            rm -rf -- "$destination_path" || return 1
        fi
        cp -a -- "$snapshot_path" "$destination_path" || return 1
        if [ -L "$snapshot_path" ]; then
            [ -L "$destination_path" ] && \
                [ "$(readlink -- "$snapshot_path")" = "$(readlink -- "$destination_path")" ]
        elif [ -f "$snapshot_path" ]; then
            cmp -s -- "$snapshot_path" "$destination_path"
        elif [ -d "$snapshot_path" ]; then
            diff -qr -- "$snapshot_path" "$destination_path" >/dev/null 2>&1
        else
            [ -e "$destination_path" ]
        fi
    elif [ -f "${marker_path}.absent" ] && [ ! -e "${marker_path}.present" ]; then
        if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
            rm -rf -- "$destination_path" || return 1
        fi
        [ ! -e "$destination_path" ] && [ ! -L "$destination_path" ]
    else
        return 1
    fi
}

acquire_node_subscription_lock() {
    local lock_root="${1:-}"
    local timeout_seconds="${NODE_SUB_LOCK_TIMEOUT_SECONDS:-30}"
    local started_at lock_owner

    [ -d "$lock_root" ] && [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
    NODE_SUB_LOCK_PATH="${lock_root}/.subscription-publish.lock.d"
    started_at=$SECONDS
    while :; do
        if (umask 077 && mkdir -- "$NODE_SUB_LOCK_PATH" 2>/dev/null); then
            chmod 700 "$NODE_SUB_LOCK_PATH" || {
                rmdir -- "$NODE_SUB_LOCK_PATH" 2>/dev/null || true
                return 1
            }
            printf '%s\n' "$BASHPID" > "${NODE_SUB_LOCK_PATH}/owner" || {
                rm -f -- "${NODE_SUB_LOCK_PATH}/owner"
                rmdir -- "$NODE_SUB_LOCK_PATH" 2>/dev/null || true
                return 1
            }
            chmod 600 "${NODE_SUB_LOCK_PATH}/owner" || {
                rm -f -- "${NODE_SUB_LOCK_PATH}/owner"
                rmdir -- "$NODE_SUB_LOCK_PATH" 2>/dev/null || true
                return 1
            }
            return 0
        fi
        if [ -d "$NODE_SUB_LOCK_PATH" ] && [ ! -L "$NODE_SUB_LOCK_PATH" ] && \
           [ -r "${NODE_SUB_LOCK_PATH}/owner" ]; then
            lock_owner=$(cat "${NODE_SUB_LOCK_PATH}/owner" 2>/dev/null || true)
            if [[ "$lock_owner" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$lock_owner" 2>/dev/null; then
                rm -f -- "${NODE_SUB_LOCK_PATH}/owner" 2>/dev/null || true
                rmdir -- "$NODE_SUB_LOCK_PATH" 2>/dev/null || true
                continue
            fi
        fi
        [ "$((SECONDS - started_at))" -lt "$timeout_seconds" ] || return 1
        sleep 0.1
    done
}

release_node_subscription_lock() {
    local lock_path="${NODE_SUB_LOCK_PATH:-}"

    if [ -n "$lock_path" ] && [ -d "$lock_path" ] && [ ! -L "$lock_path" ]; then
        rm -f -- "${lock_path}/owner" 2>/dev/null || true
        rmdir -- "$lock_path" 2>/dev/null || true
    fi
    NODE_SUB_LOCK_PATH=''
}

# Temporary compatibility adapter for the lifecycle branch.  The outer config
# lock is already held, so this takes the subscription lock second and commits
# a staged base client exactly once.  The subscription-audit merge replaces
# this body with mutate_base_subscription/publish_subscriptions_locked.  It
# must never write or restore cfy-url.txt/cfy-sub.txt.
publish_node_change_subscription() {
    local staged_client="${1:-}"
    local subscription_dir='' publish_status=0 rollback_ok=1 recovery_dir=''
    local index subscription_committed=0 subscription_traps_installed=0
    local subscription_previous_hup='' subscription_previous_int=''
    local subscription_previous_term='' subscription_previous_exit=''
    local -a owned_paths owned_keys

    _restore_node_subscription_traps() {
        [ "$subscription_traps_installed" -eq 1 ] || return 0
        trap - HUP INT TERM EXIT
        [ -z "$subscription_previous_hup" ] || eval "$subscription_previous_hup"
        [ -z "$subscription_previous_int" ] || eval "$subscription_previous_int"
        [ -z "$subscription_previous_term" ] || eval "$subscription_previous_term"
        [ -z "$subscription_previous_exit" ] || eval "$subscription_previous_exit"
        subscription_traps_installed=0
    }

    _retain_node_subscription_recovery() {
        local reason="${1:-interrupted}"

        recovery_dir="${work_dir}/.node-subscription-recovery.${subscription_dir##*.node-subscription.}"
        if [ "$subscription_dir" != "$recovery_dir" ]; then
            mv -- "$subscription_dir" "$recovery_dir" 2>/dev/null || recovery_dir="$subscription_dir"
        fi
        {
            printf 'reason=%s\n' "$reason"
            printf 'committed=%s\n' "$subscription_committed"
            printf 'rollback_complete=%s\n' "$rollback_ok"
        } > "${recovery_dir}/transaction.conf" 2>/dev/null || true
        chmod 700 "$recovery_dir" 2>/dev/null || true
        chmod 600 "${recovery_dir}/transaction.conf" 2>/dev/null || true
    }

    _node_subscription_interrupt_handler() {
        local event="${1:-EXIT}"
        local original_status="${2:-2}"
        local final_status="$original_status"

        trap - HUP INT TERM EXIT
        rollback_ok=1
        if [ "$subscription_committed" -eq 0 ] && [ -d "$subscription_dir" ]; then
            for ((index=${#owned_paths[@]} - 1; index >= 0; index--)); do
                node_change_restore_path "${owned_paths[$index]}" "$subscription_dir" \
                    "${owned_keys[$index]}" || rollback_ok=0
            done
        fi
        [ "$final_status" -ne 0 ] || final_status=2
        _retain_node_subscription_recovery "${event}:${final_status}"
        release_node_subscription_lock
        _restore_node_subscription_traps
        red "订阅发布被 ${event} 中断；恢复材料已保留：${recovery_dir}" >&2
        exit "$final_status"
    }

    [ -f "$staged_client" ] && [ ! -L "$staged_client" ] || return 1
    acquire_node_subscription_lock "$work_dir" || return 1
    subscription_dir=$(umask 077; mktemp -d "${work_dir}/.node-subscription.XXXXXX") || {
        release_node_subscription_lock
        return 1
    }
    chmod 700 "$subscription_dir" || {
        rm -rf -- "$subscription_dir" >/dev/null 2>&1 || true
        release_node_subscription_lock
        return 1
    }
    owned_paths=(
        "$client_dir"
        "${work_dir}/base-sub.txt"
        "$combined_client_dir"
        "${work_dir}/all-sub.txt"
        "${work_dir}/sub.txt"
    )
    owned_keys=(client base-sub combined-client all-sub sub)
    for index in "${!owned_paths[@]}"; do
        if ! node_change_snapshot_path "${owned_paths[$index]}" "$subscription_dir" \
            "${owned_keys[$index]}"; then
            rm -rf -- "$subscription_dir" >/dev/null 2>&1 || true
            release_node_subscription_lock
            return 1
        fi
    done
    subscription_previous_hup=$(trap -p HUP || true)
    subscription_previous_int=$(trap -p INT || true)
    subscription_previous_term=$(trap -p TERM || true)
    subscription_previous_exit=$(trap -p EXIT || true)
    trap '_node_subscription_interrupt_handler HUP 129' HUP
    trap '_node_subscription_interrupt_handler INT 130' INT
    trap '_node_subscription_interrupt_handler TERM 143' TERM
    trap '_node_subscription_interrupt_handler EXIT $?' EXIT
    subscription_traps_installed=1

    if update_sub "$staged_client"; then
        publish_status=0
    else
        publish_status=$?
    fi
    case "$publish_status" in
        0|3) ;;
        *)
            rollback_ok=1
            for ((index=${#owned_paths[@]} - 1; index >= 0; index--)); do
                node_change_restore_path "${owned_paths[$index]}" "$subscription_dir" \
                    "${owned_keys[$index]}" || rollback_ok=0
            done
            if [ "$rollback_ok" -eq 1 ] && [ "$publish_status" -eq 1 ] && \
               rm -rf -- "$subscription_dir"; then
                _restore_node_subscription_traps
                release_node_subscription_lock
                return 1
            fi
            recovery_dir="${work_dir}/.node-subscription-recovery.${subscription_dir##*.node-subscription.}"
            mv -- "$subscription_dir" "$recovery_dir" 2>/dev/null || recovery_dir="$subscription_dir"
            {
                printf 'publish_status=%s\n' "$publish_status"
                printf 'rollback_complete=%s\n' "$rollback_ok"
            } > "${recovery_dir}/transaction.conf" 2>/dev/null || true
            chmod 700 "$recovery_dir" 2>/dev/null || true
            chmod 600 "${recovery_dir}/transaction.conf" 2>/dev/null || true
            _restore_node_subscription_traps
            release_node_subscription_lock
            red "订阅发布状态不确定或回滚不完整；恢复材料已保留：${recovery_dir}"
            return 2
            ;;
    esac

    subscription_committed=1
    if ! rm -rf -- "$subscription_dir"; then
        _restore_node_subscription_traps
        release_node_subscription_lock
        yellow "订阅已提交，但安全临时目录未能清理：${subscription_dir}"
        return 3
    fi
    _restore_node_subscription_traps
    release_node_subscription_lock
    return "$publish_status"
}

apply_node_change_transaction() {
    local mutation_function="${1:-}"
    local restart_required="${2:-1}"
    local old_firewall_spec="${3:-}"
    local new_firewall_rule="${4:-}"
    shift 4 || return 1
    local transaction_dir='' recovery_dir='' staged_client='' original_client=''
    local transaction_status=0 failure_status=0
    local failure_reason='' rollback_ok=1 publish_status=0
    local service_was_active=0 argo_was_active=0 argo_restart_attempted=0
    local conflict_status=0 open_status=0 lock_status=0 old_firewall_rule=''
    local old_protocol='' old_port='' transport='' new_port='' new_transport=''
    local old_runtime_PORT="${PORT-}" old_runtime_REALITY_PORT="${REALITY_PORT-}"
    local old_runtime_NGINX_PORT="${NGINX_PORT-}" old_runtime_TUIC_PORT="${TUIC_PORT-}"
    local old_runtime_HY2_PORT="${HY2_PORT-}" old_runtime_ARGO_PORT="${ARGO_PORT-}"
    local old_runtime_vless_port="${vless_port-}" old_runtime_nginx_port="${nginx_port-}"
    local old_runtime_tuic_port="${tuic_port-}" old_runtime_hy2_port="${hy2_port-}"
    local old_runtime_argo_port="${argo_port-}"
    local old_set_PORT="${PORT+x}" old_set_REALITY_PORT="${REALITY_PORT+x}"
    local old_set_NGINX_PORT="${NGINX_PORT+x}" old_set_TUIC_PORT="${TUIC_PORT+x}"
    local old_set_HY2_PORT="${HY2_PORT+x}" old_set_ARGO_PORT="${ARGO_PORT+x}"
    local old_set_vless_port="${vless_port+x}" old_set_nginx_port="${nginx_port+x}"
    local old_set_tuic_port="${tuic_port+x}" old_set_hy2_port="${hy2_port+x}"
    local old_set_argo_port="${argo_port+x}"
    local -a snapshot_paths snapshot_keys new_firewall_records=()
    local index node_change_committed=0 node_change_traps_installed=0 NODE_CHANGE_STAGE='preparing'
    local NODE_CHANGE_REQUIRE_ARGO_RESTART=0 NODE_CHANGE_NOOP=0
    local NODE_CHANGE_ARGO_MODE='' quick_previous_domain='' quick_current_domain=''
    local node_change_previous_hup='' node_change_previous_int=''
    local node_change_previous_term='' node_change_previous_exit=''

    _restore_node_change_traps() {
        [ "$node_change_traps_installed" -eq 1 ] || return 0
        trap - HUP INT TERM EXIT
        [ -z "$node_change_previous_hup" ] || eval "$node_change_previous_hup"
        [ -z "$node_change_previous_int" ] || eval "$node_change_previous_int"
        [ -z "$node_change_previous_term" ] || eval "$node_change_previous_term"
        [ -z "$node_change_previous_exit" ] || eval "$node_change_previous_exit"
        node_change_traps_installed=0
    }

    _restore_node_change_runtime_values() {
        if [ -n "$old_set_PORT" ]; then PORT="$old_runtime_PORT"; export PORT; else unset PORT; fi
        if [ -n "$old_set_REALITY_PORT" ]; then REALITY_PORT="$old_runtime_REALITY_PORT"; export REALITY_PORT; else unset REALITY_PORT; fi
        if [ -n "$old_set_NGINX_PORT" ]; then NGINX_PORT="$old_runtime_NGINX_PORT"; export NGINX_PORT; else unset NGINX_PORT; fi
        if [ -n "$old_set_TUIC_PORT" ]; then TUIC_PORT="$old_runtime_TUIC_PORT"; export TUIC_PORT; else unset TUIC_PORT; fi
        if [ -n "$old_set_HY2_PORT" ]; then HY2_PORT="$old_runtime_HY2_PORT"; export HY2_PORT; else unset HY2_PORT; fi
        if [ -n "$old_set_ARGO_PORT" ]; then ARGO_PORT="$old_runtime_ARGO_PORT"; export ARGO_PORT; else unset ARGO_PORT; fi
        if [ -n "$old_set_vless_port" ]; then vless_port="$old_runtime_vless_port"; export vless_port; else unset vless_port; fi
        if [ -n "$old_set_nginx_port" ]; then nginx_port="$old_runtime_nginx_port"; export nginx_port; else unset nginx_port; fi
        if [ -n "$old_set_tuic_port" ]; then tuic_port="$old_runtime_tuic_port"; export tuic_port; else unset tuic_port; fi
        if [ -n "$old_set_hy2_port" ]; then hy2_port="$old_runtime_hy2_port"; export hy2_port; else unset hy2_port; fi
        if [ -n "$old_set_argo_port" ]; then argo_port="$old_runtime_argo_port"; export argo_port; else unset argo_port; fi
    }

    _restore_node_change_argo_runtime() {
        local recovery_previous_domain recovery_domain recovery_publish_status

        [ "$NODE_CHANGE_REQUIRE_ARGO_RESTART" -eq 1 ] || return 0
        if [ "$argo_was_active" -eq 1 ]; then
            [ "$argo_restart_attempted" -eq 1 ] || return 0
            if [ "$NODE_CHANGE_ARGO_MODE" = quick ]; then
                [ -f "$original_client" ] && [ ! -L "$original_client" ] || return 1
                cp -p -- "$original_client" "$staged_client" && chmod 600 "$staged_client" || return 1
                recovery_previous_domain=$(extract_staged_argo_domain "$staged_client") || return 1
                prepare_quick_argo_domain_capture || return 1
            fi
            NODE_CHANGE_STAGE='argo-rollback-restarting'
            restart_argo_checked >/dev/null 2>&1 && argo_service_is_active || return 1
            if [ "$NODE_CHANGE_ARGO_MODE" = quick ]; then
                NODE_CHANGE_STAGE='argo-rollback-domain'
                recovery_domain=$(wait_for_new_quick_argo_domain "$recovery_previous_domain") || return 1
                update_staged_argo_domain_file "$staged_client" "$recovery_domain" || return 1
                NODE_CHANGE_STAGE='argo-rollback-publishing'
                if publish_node_change_subscription "$staged_client"; then
                    recovery_publish_status=0
                else
                    recovery_publish_status=$?
                fi
                [ "$recovery_publish_status" -eq 0 ] || return 1
                quick_current_domain="$recovery_domain"
            fi
        elif argo_service_is_active; then
            stop_argo_checked >/dev/null 2>&1 && ! argo_service_is_active || return 1
        fi
    }

    _retain_node_change_recovery() {
        local reason="${1:-interrupted}"

        recovery_dir="${work_dir}/.node-change-recovery.${transaction_dir##*.node-change.}"
        if [ "$transaction_dir" != "$recovery_dir" ]; then
            mv -- "$transaction_dir" "$recovery_dir" 2>/dev/null || recovery_dir="$transaction_dir"
        fi
        {
            printf '\nreason=%s\n' "$reason"
            printf 'stage=%s\n' "$NODE_CHANGE_STAGE"
            printf 'committed=%s\n' "$node_change_committed"
            printf 'rollback_complete=%s\n' "$rollback_ok"
        } >> "${recovery_dir}/transaction.conf" 2>/dev/null || true
        chmod 700 "$recovery_dir" 2>/dev/null || true
        chmod 600 "${recovery_dir}/transaction.conf" 2>/dev/null || true
    }

    _finish_node_change_transaction() {
        local operation_status="${1:-2}"

        if finish_transaction_release "$operation_status" release_proxy_transaction_lock; then
            lock_status=0
        else
            lock_status=$?
        fi
    }

    _node_change_interrupt_handler() {
        local event="${1:-EXIT}"
        local original_status="${2:-2}"
        local final_status="$original_status"

        trap - HUP INT TERM EXIT
        rollback_ok=1
        if [ "$node_change_committed" -eq 0 ] && [ -d "$transaction_dir" ]; then
            for ((index=${#snapshot_paths[@]} - 1; index >= 0; index--)); do
                node_change_restore_path "${snapshot_paths[$index]}" "$transaction_dir" \
                    "${snapshot_keys[$index]}" || rollback_ok=0
            done
            _restore_node_change_runtime_values
            if [ "$restart_required" -eq 1 ]; then
                if [ "$service_was_active" -eq 1 ]; then
                    restart_singbox_checked >/dev/null 2>&1 && singbox_service_is_active || rollback_ok=0
                elif singbox_service_is_active; then
                    stop_singbox_checked >/dev/null 2>&1 && ! singbox_service_is_active || rollback_ok=0
                fi
            fi
            _restore_node_change_argo_runtime || rollback_ok=0
            if [ "${#new_firewall_records[@]}" -gt 0 ]; then
                remove_owned_firewall_records_exact "${new_firewall_records[@]}" || rollback_ok=0
            fi
            [ "$NODE_CHANGE_STAGE" != publishing ] || rollback_ok=0
        fi
        [ "$final_status" -ne 0 ] || final_status=2
        _retain_node_change_recovery "${event}:${final_status}"
        _finish_node_change_transaction "$final_status"
        final_status="$lock_status"
        _restore_node_change_traps
        red "配置事务被 ${event} 中断；恢复材料已保留：${recovery_dir}" >&2
        exit "$final_status"
    }

    [[ "$mutation_function" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && declare -F "$mutation_function" >/dev/null || return 1
    case "$restart_required" in 0|1) ;; *) return 1 ;; esac
    [ -d "$conf_dir" ] && [ -d "$work_dir" ] || return 1

    if acquire_proxy_transaction_lock "$conf_dir"; then
        lock_status=0
    else
        lock_status=$?
    fi
    case "$lock_status" in
        0) ;;
        1)
            red "另一个配置事务仍在运行，本次修改已中止。"
            return 1
            ;;
        2)
            red "检测到未决配置事务，无法确认当前状态；本次修改已安全中止。"
            return 2
            ;;
        *)
            red "配置事务锁返回未知状态；本次修改已安全中止。"
            return 2
            ;;
    esac

    transaction_dir=$(umask 077; mktemp -d "${work_dir}/.node-change.XXXXXX") || {
        _finish_node_change_transaction 1
        return "$lock_status"
    }
    chmod 700 "$transaction_dir" || {
        rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
        _finish_node_change_transaction 1
        return "$lock_status"
    }

    if [ -n "$new_firewall_rule" ]; then
        for index in allow_port remove_owned_firewall_records_exact \
            remove_owned_firewall_ports_if_unused configured_inbound_port_conflict_exists; do
            if ! declare -F "$index" >/dev/null; then
                rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
                _finish_node_change_transaction 2
                red "防火墙事务接口不完整，端口修改已安全中止。"
                return "$lock_status"
            fi
        done
        new_port="${new_firewall_rule%/*}"
        new_transport="${new_firewall_rule#*/}"
        validate_port_value "$new_port" port || {
            rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
            _finish_node_change_transaction 1
            return "$lock_status"
        }
        case "$new_transport" in tcp|udp) ;; *)
            rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
            _finish_node_change_transaction 1
            return "$lock_status"
        esac

        case "$old_firewall_spec" in
            auto:*)
                old_protocol="${old_firewall_spec#auto:}"
                old_port=$(get_uniform_inbound_port "${conf_dir}/inbounds.json" "$old_protocol") || {
                    rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
                    _finish_node_change_transaction 1
                    return "$lock_status"
                }
                case "$old_protocol" in
                    reality) transport=tcp ;;
                    hysteria2|tuic) transport=udp ;;
                    *)
                        rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
                        _finish_node_change_transaction 1
                        return "$lock_status"
                        ;;
                esac
                old_firewall_rule="${old_port}/${transport}"
                ;;
            '') old_firewall_rule='' ;;
            *) old_firewall_rule="$old_firewall_spec" ;;
        esac

        if [ "$old_firewall_rule" = "$new_firewall_rule" ]; then
            rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
            _finish_node_change_transaction 0
            return "$lock_status"
        fi

        configured_inbound_port_conflict_exists "${conf_dir}/inbounds.json" "$new_port" "$new_transport"
        conflict_status=$?
        case "$conflict_status" in
            0)
                rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
                _finish_node_change_transaction 1
                red "目标端口已被现有入站占用。"
                return "$lock_status"
                ;;
            1) ;;
            *)
                rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
                _finish_node_change_transaction 2
                red "无法安全确认目标端口是否冲突。"
                return "$lock_status"
                ;;
        esac
    fi

    snapshot_paths=(
        "${conf_dir}/inbounds.json"
        "$install_env_file"
        "${work_dir}/tunnel.yml"
        "${ARGO_SYSTEMD_SERVICE_FILE:-/etc/systemd/system/argo.service}"
        "${ARGO_OPENRC_SERVICE_FILE:-/etc/init.d/argo}"
    )
    snapshot_keys=(
        inbounds install-env tunnel-yml argo-systemd argo-openrc
    )
    for index in "${!snapshot_paths[@]}"; do
        if ! node_change_snapshot_path "${snapshot_paths[$index]}" "$transaction_dir" "${snapshot_keys[$index]}"; then
            rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
            _finish_node_change_transaction 1
            return "$lock_status"
        fi
    done
    {
        printf 'operation=%s\n' "$mutation_function"
        printf 'old_firewall_rule=%s\n' "$old_firewall_rule"
        printf 'new_firewall_rule=%s\n' "$new_firewall_rule"
        printf 'restart_required=%s\n' "$restart_required"
    } > "${transaction_dir}/transaction.conf" || {
        rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
        _finish_node_change_transaction 1
        return "$lock_status"
    }
    chmod 600 "${transaction_dir}/transaction.conf" || {
        rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
        _finish_node_change_transaction 1
        return "$lock_status"
    }
    staged_client="${transaction_dir}/staged-client"
    original_client="${transaction_dir}/original-client"
    [ -f "$client_dir" ] && [ ! -L "$client_dir" ] && \
        cp -p -- "$client_dir" "$staged_client" && chmod 600 "$staged_client" && \
        cp -p -- "$staged_client" "$original_client" && chmod 600 "$original_client" || {
        rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
        _finish_node_change_transaction 1
        return "$lock_status"
    }
    NODE_CHANGE_STAGE='staged'

    if singbox_service_is_active; then
        service_was_active=1
    fi
    if declare -F argo_service_is_active >/dev/null && argo_service_is_active; then
        argo_was_active=1
    fi
    node_change_previous_hup=$(trap -p HUP || true)
    node_change_previous_int=$(trap -p INT || true)
    node_change_previous_term=$(trap -p TERM || true)
    node_change_previous_exit=$(trap -p EXIT || true)
    trap '_node_change_interrupt_handler HUP 129' HUP
    trap '_node_change_interrupt_handler INT 130' INT
    trap '_node_change_interrupt_handler TERM 143' TERM
    trap '_node_change_interrupt_handler EXIT $?' EXIT
    node_change_traps_installed=1

    if [ -n "$new_firewall_rule" ]; then
        allow_port "$new_firewall_rule"
        open_status=$?
        case "$open_status" in
            0)
                if declare -p FIREWALL_LAST_ADDED_RECORDS >/dev/null 2>&1; then
                    new_firewall_records=("${FIREWALL_LAST_ADDED_RECORDS[@]}")
                fi
                ;;
            1)
                rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
                _finish_node_change_transaction 1
                _restore_node_change_traps
                return "$lock_status"
                ;;
            *)
                rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
                _finish_node_change_transaction 2
                _restore_node_change_traps
                return "$lock_status"
                ;;
        esac
    fi

    NODE_CHANGE_STAGE='mutating'
    if "$mutation_function" "$staged_client" "$@"; then
        transaction_status=0
    else
        transaction_status=$?
        failure_status=1
        [ "$transaction_status" -eq 2 ] && failure_status=2
        failure_reason="配置文件修改失败"
    fi
    if [ "$NODE_CHANGE_NOOP" -eq 1 ]; then
        NODE_CHANGE_STAGE='no-op'
        if ! rm -rf -- "$transaction_dir"; then
            if [ "$failure_status" -eq 0 ]; then
                yellow "配置已是目标状态，但安全临时目录未能清理：${transaction_dir}"
                transaction_status=3
            else
                yellow "配置未变更，但安全临时目录未能清理：${transaction_dir}"
                transaction_status="$failure_status"
            fi
            _finish_node_change_transaction "$transaction_status"
            _restore_node_change_traps
            return "$lock_status"
        fi
        _finish_node_change_transaction "$failure_status"
        _restore_node_change_traps
        return "$lock_status"
    fi
    if [ "$failure_status" -eq 0 ] && ! validate_singbox_config; then
        failure_status=1
        failure_reason="sing-box 配置校验失败"
    elif [ "$failure_status" -eq 0 ] && [ "$restart_required" -eq 1 ] && [ "$service_was_active" -eq 1 ] && \
         { NODE_CHANGE_STAGE='restarting'; ! restart_singbox_checked || ! singbox_service_is_active; }; then
        failure_status=1
        failure_reason="sing-box 运行状态提交失败"
    elif [ "$failure_status" -eq 0 ] && [ "$NODE_CHANGE_REQUIRE_ARGO_RESTART" -eq 1 ]; then
        for index in argo_service_is_active restart_argo_checked stop_argo_checked; do
            if ! declare -F "$index" >/dev/null; then
                failure_status=2
                failure_reason="Argo 服务事务接口不完整"
                break
            fi
        done
        if [ "$failure_status" -eq 0 ] && [ "$argo_was_active" -eq 1 ] && \
           [ "$NODE_CHANGE_ARGO_MODE" = quick ]; then
            quick_previous_domain=$(extract_staged_argo_domain "$staged_client") || {
                failure_status=1
                failure_reason="无法确认原临时 Argo 域名"
            }
            if [ "$failure_status" -eq 0 ] && ! prepare_quick_argo_domain_capture; then
                failure_status=1
                failure_reason="无法安全准备临时 Argo 域名捕获"
            fi
        fi
        if [ "$failure_status" -eq 0 ] && [ "$argo_was_active" -eq 1 ]; then
            NODE_CHANGE_STAGE='argo-restarting'
            argo_restart_attempted=1
            if ! restart_argo_checked || ! argo_service_is_active; then
                failure_status=1
                failure_reason="Argo 运行状态提交失败"
            fi
        fi
        if [ "$failure_status" -eq 0 ] && [ "$argo_was_active" -eq 1 ] && \
           [ "$NODE_CHANGE_ARGO_MODE" = quick ]; then
            NODE_CHANGE_STAGE='argo-domain'
            quick_current_domain=$(wait_for_new_quick_argo_domain "$quick_previous_domain") || {
                failure_status=1
                failure_reason="未能取得新的临时 Argo 域名"
            }
            if [ "$failure_status" -eq 0 ] && \
               ! update_staged_argo_domain_file "$staged_client" "$quick_current_domain"; then
                failure_status=1
                failure_reason="新的临时 Argo 域名未能写入待发布订阅"
            fi
        fi
    fi
    if [ "$failure_status" -eq 0 ]; then
        NODE_CHANGE_STAGE='publishing'
        if publish_node_change_subscription "$staged_client"; then
            publish_status=0
        else
            publish_status=$?
        fi
        case "$publish_status" in
            0) node_change_committed=1; NODE_CHANGE_STAGE='committed' ;;
            1)
                failure_status=1
                failure_reason="订阅发布失败"
                ;;
            2)
                failure_status=2
                failure_reason="订阅发布状态不确定"
                ;;
            3) transaction_status=3; node_change_committed=1; NODE_CHANGE_STAGE='committed' ;;
            *)
                failure_status=2
                failure_reason="订阅发布返回未知状态"
                ;;
        esac
    fi

    if [ "$failure_status" -ne 0 ]; then
        rollback_ok=1
        for ((index=${#snapshot_paths[@]} - 1; index >= 0; index--)); do
            node_change_restore_path "${snapshot_paths[$index]}" "$transaction_dir" \
                "${snapshot_keys[$index]}" || rollback_ok=0
        done

        _restore_node_change_runtime_values

        if [ "$restart_required" -eq 1 ]; then
            if [ "$service_was_active" -eq 1 ]; then
                restart_singbox_checked >/dev/null 2>&1 && singbox_service_is_active || rollback_ok=0
            elif singbox_service_is_active; then
                stop_singbox_checked >/dev/null 2>&1 && ! singbox_service_is_active || rollback_ok=0
            fi
        fi
        _restore_node_change_argo_runtime || rollback_ok=0
        if [ "${#new_firewall_records[@]}" -gt 0 ]; then
            remove_owned_firewall_records_exact "${new_firewall_records[@]}" || rollback_ok=0
        fi

        if [ "$rollback_ok" -eq 1 ] && [ "$failure_status" -eq 1 ]; then
            if rm -rf -- "$transaction_dir"; then
                _finish_node_change_transaction 1
                _restore_node_change_traps
                red "${failure_reason}，已完整恢复原状态。"
                return "$lock_status"
            fi
            rollback_ok=0
        fi

        _retain_node_change_recovery "$failure_reason"
        {
            printf '\nfailure_status=%s\n' "$failure_status"
            printf 'failure_reason=%s\n' "$failure_reason"
            printf 'rollback_complete=%s\n' "$rollback_ok"
        } >> "${recovery_dir}/transaction.conf" 2>/dev/null || true
        chmod 700 "$recovery_dir" 2>/dev/null || true
        chmod 600 "${recovery_dir}/transaction.conf" 2>/dev/null || true
        _finish_node_change_transaction 2
        _restore_node_change_traps
        red "${failure_reason}且自动回滚不完整；恢复材料已保留：${recovery_dir}"
        return "$lock_status"
    fi

    if ! rm -rf -- "$transaction_dir"; then
        transaction_status=3
        yellow "配置已成功提交，但安全临时目录未能清理：${transaction_dir}"
    fi
    if [ -n "$old_firewall_rule" ]; then
        if ! remove_owned_firewall_ports_if_unused "${conf_dir}/inbounds.json" "$old_firewall_rule"; then
            transaction_status=3
            yellow "新端口已成功提交，但旧防火墙记录未能安全清理。"
        fi
    fi
    _finish_node_change_transaction "$transaction_status"
    _restore_node_change_traps
    return "$lock_status"
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
    local status=0

    acquire_public_port_change_lock
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _change_public_inbound_port_transaction_locked "$@" || status=$?
    finish_transaction_release "$status" release_public_port_change_lock
}

resolve_argo_service_definition() {
    local systemd_file="${ARGO_SYSTEMD_SERVICE_FILE:-/etc/systemd/system/argo.service}"
    local openrc_file="${ARGO_OPENRC_SERVICE_FILE:-/etc/init.d/argo}"
    local init_system service_file

    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        systemd) service_file="$systemd_file" ;;
        openrc) service_file="$openrc_file" ;;
        *) return 1 ;;
    esac
    [ -f "$service_file" ] && [ ! -L "$service_file" ] && [ -r "$service_file" ] || return 1
    printf '%s\n' "$service_file"
}

replace_local_argo_origin_port_file() {
    local target_file="${1:-}"
    local old_port="${2:-}"
    local new_port="${3:-}"
    local file_kind="${4:-yaml}"
    local target_dir target_name tmp_file file_mode

    validate_port_value "$old_port" old_argo_port || return 1
    validate_port_value "$new_port" new_argo_port || return 1
    case "$file_kind" in yaml|quick) ;; *) return 1 ;; esac
    [ -f "$target_file" ] && [ ! -L "$target_file" ] && [ -r "$target_file" ] || return 1
    target_dir=$(dirname "$target_file") || return 1
    target_name=$(basename "$target_file") || return 1
    tmp_file=$(mktemp "${target_dir}/.tmp.${target_name}.argo-port.XXXXXX") || return 1
    file_mode=$(stat -c '%a' "$target_file" 2>/dev/null) || file_mode=600

    if ! awk -v old="$old_port" -v new="$new_port" -v kind="$file_kind" '
        BEGIN {
            origin = "http://(127[.]0[.]0[.]1|localhost):" old
            replacement = "http://127.0.0.1:" new
            matches = 0
            invalid = 0
        }
        {
            if (kind == "yaml") {
                if ($0 ~ "^[[:space:]]*service:[[:space:]]*" origin "[[:space:]]*(#.*)?$") {
                    matches += gsub(origin, replacement)
                } else if ($0 ~ origin) {
                    invalid = 1
                }
            } else {
                if ($0 ~ "--url[[:space:]]+" origin) {
                    matches += gsub(origin, replacement)
                } else if ($0 ~ origin) {
                    invalid = 1
                }
            }
            print
        }
        END { if (invalid || matches != 1) exit 42 }
    ' "$target_file" > "$tmp_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    chmod "$file_mode" "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    mv -f -- "$tmp_file" "$target_file" || { rm -f -- "$tmp_file"; return 1; }
}

is_quick_argo_hostname() {
    local hostname="${1:-}"

    [ "${#hostname}" -le 253 ] && \
        [[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?([.][a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*[.]trycloudflare[.]com$ ]]
}

extract_staged_argo_domain() {
    local target_file="${1:-}"
    local domains

    [ -f "$target_file" ] && [ ! -L "$target_file" ] && [ -r "$target_file" ] || return 1
    domains=$(sed -n '/^vless:\/\/.*path=%2Fvless-argo/ {
        s/.*[?&]sni=\([^&#]*\).*/\1/p
    }' "$target_file" | sort -u) || return 1
    [ "$(printf '%s\n' "$domains" | sed '/^$/d' | wc -l)" -eq 1 ] || return 1
    is_quick_argo_hostname "$domains" || return 1
    printf '%s\n' "$domains"
}

prepare_quick_argo_domain_capture() {
    local log_file="${ARGO_LOG_FILE:-${work_dir}/argo.log}"

    [ -d "$work_dir" ] && [ ! -L "$work_dir" ] || return 1
    if [ -e "$log_file" ] || [ -L "$log_file" ]; then
        [ -f "$log_file" ] && [ ! -L "$log_file" ] || return 1
    fi
    : > "$log_file" || return 1
    chmod 600 "$log_file"
}

wait_for_new_quick_argo_domain() {
    local previous_domain="${1:-}"
    local attempts="${ARGO_DOMAIN_WAIT_ATTEMPTS:-8}"
    local interval="${ARGO_DOMAIN_WAIT_INTERVAL:-2}"
    local attempt candidate

    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$interval" =~ ^[0-9]+$ ]] || return 1
    for ((attempt=1; attempt<=attempts; attempt++)); do
        candidate=$(get_latest_argo_domain 2>/dev/null || true)
        candidate=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')
        if is_quick_argo_hostname "$candidate" && [ "$candidate" != "$previous_domain" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        [ "$attempt" -ge "$attempts" ] || sleep "$interval"
    done
    return 1
}

update_staged_argo_domain_file() {
    local target_file="${1:-}"
    local new_domain="${2:-}"
    local target_dir target_name tmp_file file_mode line updated_count=0

    is_quick_argo_hostname "$new_domain" || return 1
    [ -f "$target_file" ] && [ ! -L "$target_file" ] && [ -r "$target_file" ] || return 1
    target_dir=$(dirname "$target_file") || return 1
    target_name=$(basename "$target_file") || return 1
    tmp_file=$(mktemp "${target_dir}/.tmp.${target_name}.argo-domain.XXXXXX") || return 1
    file_mode=$(stat -c '%a' "$target_file" 2>/dev/null) || file_mode=600

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == vless://* && "$line" == *'path=%2Fvless-argo'* ]]; then
            if [[ ! "$line" =~ [\?\&]sni=[^\&\#]+ ]] || [[ ! "$line" =~ [\?\&]host=[^\&\#]+ ]]; then
                rm -f -- "$tmp_file"
                return 1
            fi
            line=$(printf '%s\n' "$line" | sed -E \
                "s#([?&]sni=)[^&#]*#\\1${new_domain}#g; s#([?&]host=)[^&#]*#\\1${new_domain}#g") || {
                rm -f -- "$tmp_file"
                return 1
            }
            updated_count=$((updated_count + 1))
        fi
        printf '%s\n' "$line" >> "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    done < "$target_file"
    [ "$updated_count" -gt 0 ] || { rm -f -- "$tmp_file"; return 1; }
    chmod "$file_mode" "$tmp_file" || { rm -f -- "$tmp_file"; return 1; }
    mv -f -- "$tmp_file" "$target_file" || { rm -f -- "$tmp_file"; return 1; }
    [ "$(extract_staged_argo_domain "$target_file")" = "$new_domain" ]
}

argo_origin_port_conflict_exists() {
    local target_file="${1:-}"
    local target_port="${2:-}"
    local configured_result listener_output listener_status

    validate_port_value "$target_port" argo_port || return 2
    [ -f "$target_file" ] && [ ! -L "$target_file" ] && [ -r "$target_file" ] || return 2
    configured_result=$(jq -r --argjson port "$target_port" '
        if (.inbounds | type) != "array" then
            error("invalid inbounds")
        else
            any(.inbounds[]; ((.listen_port? // null) | tostring | tonumber?) == $port)
        end
    ' "$target_file" 2>/dev/null) || return 2
    case "$configured_result" in
        true) return 0 ;;
        false) ;;
        *) return 2 ;;
    esac

    if command_exists ss; then
        if listener_output=$(ss -H -ltn "sport = :${target_port}" 2>/dev/null); then
            [ -z "$listener_output" ] && return 1
            return 0
        fi
        command_exists lsof || return 2
    fi
    if command_exists lsof; then
        lsof -nP -iTCP:"$target_port" -sTCP:LISTEN >/dev/null 2>&1
        listener_status=$?
        case "$listener_status" in
            0) return 0 ;;
            1) return 1 ;;
            *) return 2 ;;
        esac
    fi
    return 2
}

mutate_argo_port_files() {
    local staged_client="${1:-}"
    local new_port="${2:-}"
    local old_port service_file tunnel_mode conflict_status

    validate_port_value "$new_port" argo_port || return 1
    [ -f "$staged_client" ] && [ ! -L "$staged_client" ] || return 1
    old_port=$(get_uniform_inbound_port "${conf_dir}/inbounds.json" argo) || return 1
    if [ "$old_port" = "$new_port" ]; then
        NODE_CHANGE_NOOP=1
        return 0
    fi
    argo_origin_port_conflict_exists "${conf_dir}/inbounds.json" "$new_port"
    conflict_status=$?
    case "$conflict_status" in
        0)
            NODE_CHANGE_NOOP=1
            red "目标 Argo 源站端口已被其他入站或进程占用，本次操作未做任何变更。"
            return 1
            ;;
        1) ;;
        *)
            NODE_CHANGE_NOOP=1
            red "无法安全确认目标 Argo 源站端口是否可用，本次操作未做任何变更。"
            return 2
            ;;
    esac
    service_file=$(resolve_argo_service_definition) || {
        red "无法安全定位 Argo 服务定义，端口修改已中止。"
        return 1
    }
    tunnel_mode=$(detect_argo_tunnel_mode "$service_file" 2>/dev/null) || {
        red "无法识别当前 Argo Tunnel 类型，端口修改已中止。"
        return 1
    }
    NODE_CHANGE_ARGO_MODE="$tunnel_mode"

    case "$tunnel_mode" in
        quick)
            replace_local_argo_origin_port_file "$service_file" "$old_port" "$new_port" quick || return 1
            ;;
        local)
            replace_local_argo_origin_port_file "${work_dir}/tunnel.yml" "$old_port" "$new_port" yaml || return 1
            ;;
        remote)
            NODE_CHANGE_NOOP=1
            red "远程托管 Token 隧道的入口规则不在本机；请先在 Cloudflare 端修改源站端口。"
            return 1
            ;;
        *) return 1 ;;
    esac

    apply_jq_config "${conf_dir}/inbounds.json" --arg port "$new_port" '
      (.inbounds[] |
        select(.tag == "vless-ws-argo" or .tag == "vless-ws-argo-ipv6") |
        .listen_port) = ($port | tonumber)
    ' || return 1
    ARGO_PORT="$new_port"
    argo_port="$new_port"
    export ARGO_PORT argo_port
    persist_install_settings "$install_env_file" || return 1
    NODE_CHANGE_REQUIRE_ARGO_RESTART=1
}

change_argo_port_transaction() {
    local new_port="${1:-}"
    local helper_name

    validate_port_value "$new_port" argo_port || return 1
    for helper_name in argo_service_is_active restart_argo_checked stop_argo_checked; do
        declare -F "$helper_name" >/dev/null || {
            red "Argo 服务事务接口不完整，端口修改已安全中止。"
            return 2
        }
    done
    apply_node_change_transaction mutate_argo_port_files 1 '' '' "$new_port"
}

mutate_uuid_node_files() {
    local staged_client="${1:-}"
    local new_uuid="${2:-}"
    local old_uuid tmp_client

    validate_uuid_value "$new_uuid" || return 1
    old_uuid=$(jq -er '
        [.inbounds[] |
          select(.type == "vless" and
                 (.tag == "vless-ws-argo" or (.tag | startswith("vless-reality")))) |
          .users[]?.uuid] | unique |
        if length == 1 then .[0] else empty end
    ' "${conf_dir}/inbounds.json") || return 1
    validate_uuid_value "$old_uuid" || return 1

    apply_jq_config "${conf_dir}/inbounds.json" --arg old "$old_uuid" --arg new "$new_uuid" '
      (.inbounds[] |
        select(.type == "vless" and
               (.tag == "vless-ws-argo" or (.tag | startswith("vless-reality")))) |
        .users[]? | select(.uuid == $old) | .uuid) = $new |
      (.inbounds[] | select(.type == "hysteria2") |
        .users[]? | select(.password == $old) | .password) = $new |
      (.inbounds[] | select(.type == "tuic") |
        .users[]? | select(.uuid == $old) | .uuid) = $new |
      (.inbounds[] | select(.type == "tuic") |
        .users[]? | select(.password == $old) | .password) = $new |
      (.inbounds[] | select(.type == "anytls" and .tag == "anytls") |
        .users[]? | select(.password == $old) | .password) = $new
    ' || return 1

    tmp_client=$(mktemp "${work_dir}/.tmp.node-client.XXXXXX") || return 1
    sed -E \
        -e "s#^(vless|hysteria2|anytls)://${old_uuid}@#\\1://${new_uuid}@#" \
        -e "s#^tuic://${old_uuid}:${old_uuid}@#tuic://${new_uuid}:${new_uuid}@#" \
        "$staged_client" > "$tmp_client" || { rm -f -- "$tmp_client"; return 1; }
    chmod "$(stat -c '%a' "$staged_client" 2>/dev/null || printf '%s' 600)" "$tmp_client" || {
        rm -f -- "$tmp_client"
        return 1
    }
    mv -f -- "$tmp_client" "$staged_client" || { rm -f -- "$tmp_client"; return 1; }
}

change_uuid_transaction() {
    local new_uuid="${1:-}"

    validate_uuid_value "$new_uuid" || return 1
    apply_node_change_transaction mutate_uuid_node_files 1 '' '' "$new_uuid"
}

mutate_reality_sni_files() {
    local staged_client="${1:-}"
    local new_sni="${2:-}"
    local tmp_client dns_strategy use_local_resolver=false

    is_valid_subscription_domain "$new_sni" || return 1
    dns_strategy=$(public_route_dns_strategy) || return 1
    if jq -e 'any(.dns.servers[]?; .tag == "local")' "${conf_dir}/dns.json" >/dev/null 2>&1; then
        use_local_resolver=true
    fi
    apply_jq_config "${conf_dir}/inbounds.json" --arg sni "$new_sni" --arg strategy "$dns_strategy" \
        --argjson use_local_resolver "$use_local_resolver" '
      (.inbounds[] |
        select(.type == "vless" and (.tag | startswith("vless-reality")) and
               (.tls.reality? != null)) | .tls.server_name) = $sni |
      (.inbounds[] |
        select(.type == "vless" and (.tag | startswith("vless-reality")) and
               (.tls.reality? != null)) | .tls.reality.handshake) |=
        (.server = $sni |
         if $use_local_resolver and .domain_resolver == null and .domain_strategy == null and .detour == null then
           .domain_resolver = {server:"local",strategy:$strategy}
         else . end)
    ' || return 1
    tmp_client=$(mktemp "${work_dir}/.tmp.node-client.XXXXXX") || return 1
    sed -E "/^vless:\/\// { /security=reality/ s#(sni=)[^&]*#\\1${new_sni}#; }" \
        "$staged_client" > "$tmp_client" || { rm -f -- "$tmp_client"; return 1; }
    chmod "$(stat -c '%a' "$staged_client" 2>/dev/null || printf '%s' 600)" "$tmp_client" || {
        rm -f -- "$tmp_client"
        return 1
    }
    mv -f -- "$tmp_client" "$staged_client" || { rm -f -- "$tmp_client"; return 1; }
}

change_reality_sni_transaction() {
    local new_sni="${1:-}"

    is_valid_subscription_domain "$new_sni" || return 1
    apply_node_change_transaction mutate_reality_sni_files 1 '' '' "$new_sni"
}

mutate_client_ip_files() {
    local staged_client="${1:-}"
    local family="${2:-}"
    local address="${3:-}"
    local replacement tmp_client

    case "$family" in
        ipv4) is_valid_ipv4_address "$address" || return 1; replacement="$address" ;;
        ipv6) is_valid_ipv6_address "$address" || return 1; replacement="[${address}]" ;;
        *) return 1 ;;
    esac
    tmp_client=$(mktemp "${work_dir}/.tmp.node-client.XXXXXX") || return 1
    sed -E \
        "/path=%2Fvless-argo/! { /^(vless|hysteria2|tuic|anytls|socks|ss):\/\// s#@(\\[[0-9A-Fa-f:]+\\]|([0-9]{1,3}\\.){3}[0-9]{1,3}):#@${replacement}:#; }" \
        "$staged_client" > "$tmp_client" || { rm -f -- "$tmp_client"; return 1; }
    chmod "$(stat -c '%a' "$staged_client" 2>/dev/null || printf '%s' 600)" "$tmp_client" || {
        rm -f -- "$tmp_client"
        return 1
    }
    mv -f -- "$tmp_client" "$staged_client" || { rm -f -- "$tmp_client"; return 1; }
}

change_client_ip_transaction() {
    local family="${1:-}"
    local address="${2:-}"

    case "$family" in
        ipv4) is_valid_ipv4_address "$address" || return 1 ;;
        ipv6) is_valid_ipv6_address "$address" || return 1 ;;
        *) return 1 ;;
    esac
    apply_node_change_transaction mutate_client_ip_files 0 '' '' "$family" "$address"
}


purge_nginx_package() {
    local package="nginx"
    manage_packages uninstall "$package"
}

# Return success only when an exact executable owned by this installation is
# still running.  Process names alone are intentionally insufficient: another
# user's "sing-box" or "nginx" process must never influence our lifecycle.
managed_service_process_is_running() {
    local service_name="$1"
    local target_work_dir="${2:-$work_dir}"
    local install_root="${3:-}"
    local expected_executable='' process_executable

    case "$service_name" in
        sing-box) expected_executable="${target_work_dir}/sing-box" ;;
        argo)     expected_executable="${target_work_dir}/argo" ;;
        nginx)
            if [ -n "$install_root" ]; then
                for expected_executable in \
                    "${install_root}/usr/sbin/nginx" \
                    "${install_root}/usr/local/sbin/nginx" \
                    "${install_root}/usr/bin/nginx"; do
                    [ -x "$expected_executable" ] && break
                    expected_executable=''
                done
            else
                expected_executable=$(command -v nginx 2>/dev/null) || return 1
            fi
            ;;
        *) return 1 ;;
    esac

    [ -n "$expected_executable" ] || return 1
    expected_executable=$(readlink -f -- "$expected_executable" 2>/dev/null) || return 1
    for process_executable in /proc/[0-9]*/exe; do
        [ -e "$process_executable" ] || continue
        [ "$(readlink -f -- "$process_executable" 2>/dev/null)" = "$expected_executable" ] && return 0
    done
    return 1
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
                rm -f "$managed_link" || return 1
                ;;
        esac
    done
}

perform_singbox_uninstall() {
    local uninstall_root="${1:-}"
    local purge_nginx="${2:-0}"
    local target_work_dir init_system='' service_name definition
    local systemd_dir="${uninstall_root}/etc/systemd/system"
    local openrc_dir="${uninstall_root}/etc/init.d"
    local nginx_main="${uninstall_root}/etc/nginx/nginx.conf"
    local nginx_conf_dir="${uninstall_root}/etc/nginx/conf.d"
    local nginx_conf="${nginx_conf_dir}/sing-box.conf"
    local nginx_conf_existed=0 nginx_changed=0 nginx_package_present=0
    local definitions_present=0
    local sing_definition_present=0 argo_definition_present=0 nginx_definition_present=0
    local selected_sing_definition=0 selected_argo_definition=0 selected_nginx_definition=0
    local quiesce_failed=0 rollback_incomplete=0 service_active_now=0 service_enabled_now=0
    local recovery_dir='' recovery_parent='' recovery_state_file='' i
    local transaction_dir='' transaction_parent='' transaction_parent_created=0
    local transaction_failed=0 transaction_uncertain=0 rollback_ok=1
    local recovery_base='' recovery_reason='' snapshot_path='' snapshot_key='' old_nat_state=''
    local -a quiesce_services=() service_was_active=() service_was_enabled=()
    local -a service_was_stopped=() service_was_disabled=()
    local -a snapshot_paths=() snapshot_keys=()

    [[ "$purge_nginx" == 0 || "$purge_nginx" == 1 ]] || return 1
    if [ -n "$uninstall_root" ]; then
        case "$work_dir" in
            "$uninstall_root"/*) target_work_dir="$work_dir" ;;
            /*) target_work_dir="${uninstall_root}${work_dir}" ;;
            *) target_work_dir="${uninstall_root}/${work_dir}" ;;
        esac
    else
        target_work_dir="$work_dir"
    fi
    [ -n "$target_work_dir" ] && [ "$target_work_dir" != / ] || return 1
    local HY2_NAT_STATE_FILE="${target_work_dir}/hy2-nat.state"
    local FIREWALL_STATE_FILE="${target_work_dir}/firewall.state"
    local FIREWALL_LOCK_FILE="${target_work_dir}/.firewall.lock"
    if [ "$purge_nginx" -eq 1 ]; then
        if declare -F package_is_installed >/dev/null 2>&1; then
            if package_is_installed nginx; then
                nginx_package_present=1
            else
                case "$?" in
                    1) nginx_package_present=0 ;;
                    *)
                        red "无法可靠查询 Nginx 软件包状态；卸载尚未开始。"
                        return 1
                        ;;
                esac
            fi
        elif command_exists nginx; then
            # Isolated function tests may source this function without the
            # package helper; production always uses the native query above.
            nginx_package_present=1
        fi
    fi

    for definition in "${systemd_dir}/sing-box.service" "${openrc_dir}/sing-box"; do
        [ -e "$definition" ] && sing_definition_present=1
    done
    for definition in "${systemd_dir}/argo.service" "${openrc_dir}/argo"; do
        [ -e "$definition" ] && argo_definition_present=1
    done
    for definition in \
        "${systemd_dir}/nginx.service" \
        "${uninstall_root}/lib/systemd/system/nginx.service" \
        "${uninstall_root}/usr/lib/systemd/system/nginx.service" \
        "${openrc_dir}/nginx"; do
        [ -e "$definition" ] && nginx_definition_present=1
    done
    [ "$sing_definition_present" -eq 1 ] && definitions_present=1
    [ "$argo_definition_present" -eq 1 ] && definitions_present=1

    # Unit-less exact managed processes are an unsafe, unknowable state.  This
    # inventory is deliberately completed before init calls or file mutation.
    if [ "$sing_definition_present" -eq 0 ] && \
       declare -F managed_service_process_is_running >/dev/null 2>&1 && \
       managed_service_process_is_running sing-box "$target_work_dir" "$uninstall_root"; then
        red "检测到无服务单元的 sing-box 受管进程；卸载已中止。"
        return 1
    fi
    if [ "$argo_definition_present" -eq 0 ] && \
       declare -F managed_service_process_is_running >/dev/null 2>&1 && \
       managed_service_process_is_running argo "$target_work_dir" "$uninstall_root"; then
        red "检测到无服务单元的 Argo 受管进程；卸载已中止。"
        return 1
    fi
    if [ "$purge_nginx" -eq 1 ] && [ "$nginx_definition_present" -eq 0 ] && \
       declare -F managed_service_process_is_running >/dev/null 2>&1 && \
       managed_service_process_is_running nginx "$target_work_dir" "$uninstall_root"; then
        red "检测到无服务单元的 Nginx 进程；拒绝卸载 Nginx。"
        return 1
    fi

    if [ "$definitions_present" -eq 1 ] || \
       { [ "$purge_nginx" -eq 1 ] && [ "$nginx_definition_present" -eq 1 ]; }; then
        init_system=$(detect_usable_init_system 2>/dev/null) || {
            red "仍有受管服务需要停止，但当前 init 系统不可用；卸载已中止。"
            return 1
        }
    fi

    case "$init_system" in
        systemd)
            [ -e "${systemd_dir}/sing-box.service" ] && selected_sing_definition=1
            [ -e "${systemd_dir}/argo.service" ] && selected_argo_definition=1
            for definition in \
                "${systemd_dir}/nginx.service" \
                "${uninstall_root}/lib/systemd/system/nginx.service" \
                "${uninstall_root}/usr/lib/systemd/system/nginx.service"; do
                [ -e "$definition" ] && selected_nginx_definition=1
            done
            ;;
        openrc)
            [ -e "${openrc_dir}/sing-box" ] && selected_sing_definition=1
            [ -e "${openrc_dir}/argo" ] && selected_argo_definition=1
            [ -e "${openrc_dir}/nginx" ] && selected_nginx_definition=1
            ;;
    esac

    # A definition for a different init implementation does not prove the
    # process is controlled by the usable init.  Re-check that edge before any
    # stop/disable operation.
    if [ "$selected_sing_definition" -eq 0 ] && \
       declare -F managed_service_process_is_running >/dev/null 2>&1 && \
       managed_service_process_is_running sing-box "$target_work_dir" "$uninstall_root"; then
        red "sing-box 进程不受当前 init 系统管理；卸载已中止。"
        return 1
    fi
    if [ "$selected_argo_definition" -eq 0 ] && \
       declare -F managed_service_process_is_running >/dev/null 2>&1 && \
       managed_service_process_is_running argo "$target_work_dir" "$uninstall_root"; then
        red "Argo 进程不受当前 init 系统管理；卸载已中止。"
        return 1
    fi
    if [ "$purge_nginx" -eq 1 ] && [ "$selected_nginx_definition" -eq 0 ] && \
       declare -F managed_service_process_is_running >/dev/null 2>&1 && \
       managed_service_process_is_running nginx "$target_work_dir" "$uninstall_root"; then
        red "Nginx 进程不受当前 init 系统管理；拒绝卸载 Nginx。"
        return 1
    fi

    [ "$selected_sing_definition" -eq 1 ] && quiesce_services+=(sing-box)
    [ "$selected_argo_definition" -eq 1 ] && quiesce_services+=(argo)
    if [ "$purge_nginx" -eq 1 ] && [ "$selected_nginx_definition" -eq 1 ]; then
        quiesce_services+=(nginx)
    fi

    for service_name in "${quiesce_services[@]}"; do
        service_active_now=0
        service_enabled_now=0
        case "$init_system" in
            systemd)
                systemctl is-active --quiet "$service_name" >/dev/null 2>&1 && service_active_now=1
                systemctl is-enabled --quiet "$service_name" >/dev/null 2>&1 && service_enabled_now=1
                service_was_active+=("$service_active_now")
                service_was_enabled+=("$service_enabled_now")
                service_was_stopped+=(0)
                service_was_disabled+=(0)
                i=$((${#service_was_active[@]} - 1))
                if [ "$service_active_now" -eq 1 ]; then
                    if ! systemctl stop "$service_name" >/dev/null 2>&1; then
                        systemctl is-active --quiet "$service_name" >/dev/null 2>&1 || service_was_stopped[$i]=1
                        quiesce_failed=1
                        break
                    fi
                    if systemctl is-active --quiet "$service_name" >/dev/null 2>&1; then
                        quiesce_failed=1
                        break
                    fi
                    service_was_stopped[$i]=1
                fi
                if [ "$service_enabled_now" -eq 1 ]; then
                    if ! systemctl disable "$service_name" >/dev/null 2>&1; then
                        systemctl is-enabled --quiet "$service_name" >/dev/null 2>&1 || service_was_disabled[$i]=1
                        quiesce_failed=1
                        break
                    fi
                    if systemctl is-enabled --quiet "$service_name" >/dev/null 2>&1; then
                        quiesce_failed=1
                        break
                    fi
                    service_was_disabled[$i]=1
                fi
                ;;
            openrc)
                rc-service "$service_name" status >/dev/null 2>&1 && service_active_now=1
                rc-update show default 2>/dev/null | \
                    grep -Eq "(^|[[:space:]])${service_name}([[:space:]]|$)" && service_enabled_now=1
                service_was_active+=("$service_active_now")
                service_was_enabled+=("$service_enabled_now")
                service_was_stopped+=(0)
                service_was_disabled+=(0)
                i=$((${#service_was_active[@]} - 1))
                if [ "$service_active_now" -eq 1 ]; then
                    if ! rc-service "$service_name" stop >/dev/null 2>&1; then
                        rc-service "$service_name" status >/dev/null 2>&1 || service_was_stopped[$i]=1
                        quiesce_failed=1
                        break
                    fi
                    if rc-service "$service_name" status >/dev/null 2>&1; then
                        quiesce_failed=1
                        break
                    fi
                    service_was_stopped[$i]=1
                fi
                if [ "$service_enabled_now" -eq 1 ]; then
                    if ! rc-update del "$service_name" default >/dev/null 2>&1; then
                        quiesce_failed=1
                        break
                    fi
                    service_was_disabled[$i]=1
                fi
                ;;
        esac
    done

    _restore_uninstall_services() {
        local restore_index restore_service
        local restore_status=0

        for ((restore_index=${#service_was_active[@]} - 1; restore_index >= 0; restore_index--)); do
            restore_service="${quiesce_services[$restore_index]}"
            case "$init_system" in
                systemd)
                    if [ "${service_was_disabled[$restore_index]}" -eq 1 ]; then
                        systemctl enable "$restore_service" >/dev/null 2>&1 || restore_status=1
                        systemctl is-enabled --quiet "$restore_service" >/dev/null 2>&1 || restore_status=1
                    fi
                    if [ "${service_was_stopped[$restore_index]}" -eq 1 ]; then
                        systemctl start "$restore_service" >/dev/null 2>&1 || restore_status=1
                        systemctl is-active --quiet "$restore_service" >/dev/null 2>&1 || restore_status=1
                    fi
                    ;;
                openrc)
                    if [ "${service_was_disabled[$restore_index]}" -eq 1 ]; then
                        rc-update add "$restore_service" default >/dev/null 2>&1 || restore_status=1
                    fi
                    if [ "${service_was_stopped[$restore_index]}" -eq 1 ]; then
                        rc-service "$restore_service" start >/dev/null 2>&1 || restore_status=1
                        rc-service "$restore_service" status >/dev/null 2>&1 || restore_status=1
                    fi
                    ;;
            esac
        done
        return "$restore_status"
    }

    _write_uninstall_service_state_file() {
        local state_target="$1"

        {
            printf 'INIT_SYSTEM=%q\n' "$init_system"
            for ((i=0; i<${#service_was_active[@]}; i++)); do
                printf 'SERVICE_%d=%q\n' "$i" "${quiesce_services[$i]}"
                printf 'WAS_ACTIVE_%d=%q\n' "$i" "${service_was_active[$i]}"
                printf 'WAS_ENABLED_%d=%q\n' "$i" "${service_was_enabled[$i]}"
                printf 'STOPPED_%d=%q\n' "$i" "${service_was_stopped[$i]}"
                printf 'DISABLED_%d=%q\n' "$i" "${service_was_disabled[$i]}"
            done
        } > "$state_target" || return 1
        chmod 600 "$state_target"
    }

    _write_uninstall_service_recovery() {
        recovery_parent="$target_work_dir"
        if [ ! -d "$recovery_parent" ] || [ -L "$recovery_parent" ]; then
            recovery_parent="${TMPDIR:-/tmp}"
        fi
        recovery_dir=$(umask 077; mktemp -d "${recovery_parent}/.uninstall-recovery.XXXXXX") || return 1
        chmod 700 "$recovery_dir" || return 1
        recovery_state_file="${recovery_dir}/service-state.conf"
        _write_uninstall_service_state_file "$recovery_state_file"
    }

    if [ "$quiesce_failed" -eq 1 ]; then
        _restore_uninstall_services || rollback_incomplete=1
        if [ "$rollback_incomplete" -eq 0 ]; then
            red "服务停止失败；原服务状态已恢复，卸载未开始。"
            return 1
        fi

        if ! _write_uninstall_service_recovery; then
            red "服务停止失败且自动回滚不完整；恢复材料创建失败，请立即检查服务状态。"
            return 2
        fi
        red "服务停止失败且自动回滚不完整；恢复材料已保留：${recovery_dir}"
        return 2
    fi

    _snapshot_uninstall_path() {
        local source_path="$1"
        local source_key="$2"

        if [ -e "$source_path" ] || [ -L "$source_path" ]; then
            cp -a -- "$source_path" "${transaction_dir}/${source_key}" || return 1
            : > "${transaction_dir}/${source_key}.present" || return 1
            chmod 600 "${transaction_dir}/${source_key}.present" || return 1
        else
            : > "${transaction_dir}/${source_key}.absent" || return 1
            chmod 600 "${transaction_dir}/${source_key}.absent" || return 1
        fi
    }

    _restore_uninstall_path() {
        local destination_path="$1"
        local source_key="$2"

        if [ -e "${transaction_dir}/${source_key}.present" ]; then
            if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
                rm -rf -- "$destination_path" || return 1
            fi
            mkdir -p -- "$(dirname "$destination_path")" || return 1
            cp -a -- "${transaction_dir}/${source_key}" "$destination_path" || return 1
        elif [ -e "${transaction_dir}/${source_key}.absent" ]; then
            if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
                rm -rf -- "$destination_path" || return 1
            fi
        else
            return 1
        fi
    }

    _cleanup_uninstall_transaction() {
        local cleanup_status=0

        if [ -n "$transaction_dir" ] && { [ -e "$transaction_dir" ] || [ -L "$transaction_dir" ]; }; then
            rm -rf -- "$transaction_dir" || cleanup_status=1
        fi
        if [ "$transaction_parent_created" -eq 1 ] && [ -d "$transaction_parent" ]; then
            rmdir -- "$transaction_parent" 2>/dev/null || cleanup_status=1
        fi
        return "$cleanup_status"
    }

    _retain_uninstall_transaction() {
        local reason="$1"
        local retained_ok=1

        recovery_base="${uninstall_root}/var/lib/sing-box-uninstall"
        [ -n "$uninstall_root" ] || recovery_base='/var/lib/sing-box-uninstall'
        if ! mkdir -p -- "$recovery_base" || ! chmod 700 "$recovery_base"; then
            recovery_dir="$transaction_dir"
        else
            recovery_dir=$(umask 077; mktemp -d "${recovery_base}/.uninstall-recovery.XXXXXX") || \
                recovery_dir="$transaction_dir"
        fi
        if [ "$recovery_dir" != "$transaction_dir" ]; then
            chmod 700 "$recovery_dir" || retained_ok=0
            cp -a -- "${transaction_dir}/." "$recovery_dir/" || retained_ok=0
            if [ "$retained_ok" -eq 1 ]; then
                rm -rf -- "$transaction_dir" >/dev/null 2>&1 || true
                transaction_dir="$recovery_dir"
            else
                recovery_dir="$transaction_dir"
            fi
        fi
        printf 'REASON=%q\n' "$reason" > "${recovery_dir}/recovery.conf" 2>/dev/null || true
        chmod 600 "${recovery_dir}/recovery.conf" 2>/dev/null || true
    }

    _restore_uninstall_firewall_state() {
        local snapshot_state="${transaction_dir}/workdir/firewall.state"
        local record backend family live_status restore_status=0 release_status=0
        local FIREWALL_STATE_FILE="$snapshot_state"
        local -a restore_records=() raw_families=()

        [ -s "$snapshot_state" ] || return 0
        declare -F read_firewall_state >/dev/null 2>&1 && \
            declare -F firewall_record_is_live >/dev/null 2>&1 && \
            declare -F add_firewall_record >/dev/null 2>&1 && \
            declare -F persist_raw_firewall_rules >/dev/null 2>&1 && \
            declare -F acquire_firewall_lock >/dev/null 2>&1 && \
            declare -F release_firewall_lock >/dev/null 2>&1 || return 1
        read_firewall_state || return 1
        restore_records=("${FIREWALL_STATE_RECORDS[@]}")
        acquire_firewall_lock || return $?
        for record in "${restore_records[@]}"; do
            backend="${record%%|*}"
            if [ "$backend" = iptables ]; then
                IFS='|' read -r _ family _ _ _ <<< "$record"
                case " ${raw_families[*]} " in
                    *" ${family} "*) ;;
                    *) raw_families+=("$family") ;;
                esac
            fi
            if firewall_record_is_live "$record"; then
                live_status=0
            else
                live_status=$?
            fi
            case "$live_status" in
                0) continue ;;
                1) add_firewall_record "$record" || { restore_status=1; break; } ;;
                *) restore_status=1; break ;;
            esac
        done
        if [ "$restore_status" -eq 0 ] && [ "${#raw_families[@]}" -gt 0 ]; then
            persist_raw_firewall_rules "${raw_families[@]}" || restore_status=1
        fi
        release_firewall_lock || release_status=$?
        [ "$release_status" -eq 0 ] || return 2
        return "$restore_status"
    }

    _rollback_uninstall_transaction() {
        local rollback_uncertain="${1:-0}"
        local rollback_reason="$2"
        local rollback_index record family
        local -a rollback_nat_records=() rollback_nat_families=()

        rollback_ok=1
        for ((rollback_index=0; rollback_index<${#snapshot_paths[@]}; rollback_index++)); do
            _restore_uninstall_path \
                "${snapshot_paths[$rollback_index]}" \
                "${snapshot_keys[$rollback_index]}" || rollback_ok=0
        done

        old_nat_state="${transaction_dir}/workdir/hy2-nat.state"
        if [ -s "$old_nat_state" ]; then
            if declare -F restore_hy2_nat_records >/dev/null 2>&1 && \
               declare -F persist_hy2_nat_rules >/dev/null 2>&1 && \
               mapfile -t rollback_nat_records < "$old_nat_state"; then
                for record in "${rollback_nat_records[@]}"; do
                    family="${record%%|*}"
                    case " ${rollback_nat_families[*]} " in
                        *" ${family} "*) ;;
                        *) rollback_nat_families+=("$family") ;;
                    esac
                done
                restore_hy2_nat_records "${rollback_nat_records[@]}" || rollback_ok=0
                persist_hy2_nat_rules "${rollback_nat_families[@]}" || rollback_ok=0
            else
                rollback_ok=0
            fi
        fi

        _restore_uninstall_firewall_state || rollback_ok=0

        if [ "$definitions_present" -eq 1 ] && [ "$init_system" = systemd ]; then
            systemctl daemon-reload >/dev/null 2>&1 || rollback_ok=0
        fi
        if [ "$nginx_changed" -eq 1 ] && [ "$purge_nginx" -eq 0 ] && command_exists nginx; then
            if ! nginx -t >/dev/null 2>&1 || \
               { ! nginx -s reload >/dev/null 2>&1 && ! restart_nginx >/dev/null 2>&1; }; then
                rollback_ok=0
            fi
        fi
        if [ "$rollback_ok" -eq 1 ] && [ "$rollback_uncertain" -eq 0 ]; then
            _restore_uninstall_services || rollback_ok=0
        fi
        if [ "$rollback_ok" -eq 1 ] && [ "$rollback_uncertain" -eq 0 ]; then
            _cleanup_uninstall_transaction >/dev/null 2>&1 || true
            red "${rollback_reason}；原安装与服务状态已恢复。"
            return 1
        fi

        _retain_uninstall_transaction "$rollback_reason"
        red "${rollback_reason}且自动回滚不完整；恢复材料已保留：${recovery_dir}"
        return 2
    }

    # Validate unsafe filesystem shapes before taking the first snapshot.
    if { [ -e "$target_work_dir" ] || [ -L "$target_work_dir" ]; } && \
       { [ ! -d "$target_work_dir" ] || [ -L "$target_work_dir" ]; }; then
        _restore_uninstall_services >/dev/null 2>&1 || rollback_incomplete=1
        [ "$rollback_incomplete" -eq 0 ] && return 1
        _write_uninstall_service_recovery >/dev/null 2>&1 || true
        red "安装目录形态不安全且服务恢复不完整；恢复材料已保留：${recovery_dir}"
        return 2
    fi
    for snapshot_path in "$nginx_main" "$nginx_conf"; do
        if { [ -e "$snapshot_path" ] || [ -L "$snapshot_path" ]; } && \
           { [ ! -f "$snapshot_path" ] || [ -L "$snapshot_path" ]; }; then
            _restore_uninstall_services >/dev/null 2>&1 || rollback_incomplete=1
            [ "$rollback_incomplete" -eq 0 ] && return 1
            _write_uninstall_service_recovery >/dev/null 2>&1 || true
            red "Nginx 配置形态不安全且服务恢复不完整；恢复材料已保留：${recovery_dir}"
            return 2
        fi
    done

    if [ -n "$uninstall_root" ]; then
        transaction_parent="${uninstall_root}/var/lib/sing-box-uninstall"
        if [ ! -d "$transaction_parent" ]; then
            mkdir -p -- "$transaction_parent" || {
                _restore_uninstall_services >/dev/null 2>&1 && return 1
                _write_uninstall_service_recovery >/dev/null 2>&1 || true
                return 2
            }
            transaction_parent_created=1
        fi
        chmod 700 "$transaction_parent" || {
            _restore_uninstall_services >/dev/null 2>&1 && return 1
            _write_uninstall_service_recovery >/dev/null 2>&1 || true
            return 2
        }
    else
        transaction_parent="${TMPDIR:-/tmp}"
    fi
    transaction_dir=$(umask 077; mktemp -d "${transaction_parent}/.uninstall-transaction.XXXXXX") || {
        _restore_uninstall_services >/dev/null 2>&1 && return 1
        _write_uninstall_service_recovery >/dev/null 2>&1 || true
        red "卸载快照创建失败且服务恢复不完整；恢复材料已保留：${recovery_dir}"
        return 2
    }
    chmod 700 "$transaction_dir" || {
        _restore_uninstall_services >/dev/null 2>&1 && { _cleanup_uninstall_transaction; return 1; }
        _write_uninstall_service_recovery >/dev/null 2>&1 || true
        return 2
    }

    snapshot_paths=(
        "$target_work_dir"
        "$nginx_main"
        "$nginx_conf"
        "${systemd_dir}/sing-box.service"
        "${systemd_dir}/argo.service"
        "${openrc_dir}/sing-box"
        "${openrc_dir}/argo"
        "${uninstall_root}/usr/local/bin/sing-box"
        "${uninstall_root}/usr/local/bin/sb"
        "${uninstall_root}/usr/bin/sb"
    )
    snapshot_keys=(
        workdir nginx-main nginx-conf
        systemd-sing systemd-argo openrc-sing openrc-argo
        link-sing link-local-sb link-usr-sb
    )
    for ((i=0; i<${#snapshot_paths[@]}; i++)); do
        if ! _snapshot_uninstall_path "${snapshot_paths[$i]}" "${snapshot_keys[$i]}"; then
            if _restore_uninstall_services; then
                _cleanup_uninstall_transaction >/dev/null 2>&1 || true
                red "卸载快照创建失败；服务状态已恢复，卸载未开始。"
                return 1
            fi
            _cleanup_uninstall_transaction >/dev/null 2>&1 || true
            _write_uninstall_service_recovery >/dev/null 2>&1 || true
            red "卸载快照创建失败且服务恢复不完整；恢复材料已保留：${recovery_dir}"
            return 2
        fi
    done
    if ! _write_uninstall_service_state_file "${transaction_dir}/service-state.conf"; then
        if _restore_uninstall_services; then
            _cleanup_uninstall_transaction >/dev/null 2>&1 || true
            red "服务状态快照创建失败；服务状态已恢复，卸载未开始。"
            return 1
        fi
        _cleanup_uninstall_transaction >/dev/null 2>&1 || true
        _write_uninstall_service_recovery >/dev/null 2>&1 || true
        red "服务状态快照创建失败且服务恢复不完整；恢复材料已保留：${recovery_dir}"
        return 2
    fi

    # From here until the base commit every failure uses the same rollback.
    transaction_failed=0
    remove_hy2_port_hopping || transaction_failed=$?
    if [ "$transaction_failed" -ne 0 ]; then
        [ "$transaction_failed" -eq 2 ] && transaction_uncertain=1
        _rollback_uninstall_transaction "$transaction_uncertain" "HY2 端口跳跃规则清理失败"
        return $?
    fi
    transaction_failed=0
    remove_owned_firewall_rules || transaction_failed=$?
    if [ "$transaction_failed" -ne 0 ]; then
        [ "$transaction_failed" -eq 2 ] && transaction_uncertain=1
        _rollback_uninstall_transaction "$transaction_uncertain" "防火墙所有权规则清理失败"
        return $?
    fi

    [ -e "$nginx_conf" ] && nginx_conf_existed=1
    if ! remove_managed_nginx_include "$nginx_main" "$nginx_conf_dir"; then
        _rollback_uninstall_transaction 0 "Nginx 受管配置清理失败"
        return $?
    fi
    if [ "$nginx_conf_existed" -eq 1 ]; then
        if ! rm -f -- "$nginx_conf"; then
            _rollback_uninstall_transaction 0 "Nginx 订阅配置删除失败"
            return $?
        fi
        nginx_changed=1
    fi
    [ -e "${transaction_dir}/nginx-main.present" ] && nginx_changed=1

    if [ "$purge_nginx" -eq 0 ] && [ "$nginx_changed" -eq 1 ] && command_exists nginx; then
        if ! nginx -t >/dev/null 2>&1 || \
           { ! nginx -s reload >/dev/null 2>&1 && ! restart_nginx >/dev/null 2>&1; }; then
            _rollback_uninstall_transaction 0 "Nginx 重载失败"
            return $?
        fi
    fi

    if [ "$definitions_present" -eq 1 ]; then
        for definition in \
            "${systemd_dir}/sing-box.service" "${systemd_dir}/argo.service" \
            "${openrc_dir}/sing-box" "${openrc_dir}/argo"; do
            [ -e "$definition" ] || continue
            if ! rm -f -- "$definition"; then
                _rollback_uninstall_transaction 0 "服务定义删除失败"
                return $?
            fi
        done
        if [ "$init_system" = systemd ] && ! systemctl daemon-reload >/dev/null 2>&1; then
            _rollback_uninstall_transaction 0 "systemd 重载失败"
            return $?
        fi
    fi

    if ! remove_managed_singbox_link "$uninstall_root"; then
        _rollback_uninstall_transaction 0 "快捷方式清理失败"
        return $?
    fi
    if [ -e "$target_work_dir" ] && ! rm -rf -- "$target_work_dir"; then
        _rollback_uninstall_transaction 0 "安装目录删除失败"
        return $?
    fi

    # The base uninstall is now committed.  Package removal is deliberately a
    # separate, non-rollbackable step and never invokes autoremove.
    if [ "$purge_nginx" -eq 1 ] && [ "$nginx_package_present" -eq 1 ]; then
        if ! purge_nginx_package; then
            {
                printf 'BASE_UNINSTALL_COMMITTED=1\n'
                printf 'PACKAGE=%q\n' nginx
                printf 'PURGE_COMPLETE=0\n'
            } > "${transaction_dir}/package-purge.conf" 2>/dev/null || true
            chmod 600 "${transaction_dir}/package-purge.conf" 2>/dev/null || true
            _retain_uninstall_transaction 'Nginx package purge incomplete after base commit'
            red "基础卸载已完成，但 Nginx 软件包卸载不完整；恢复材料已保留：${recovery_dir}"
            return 2
        fi
    fi

    if ! _cleanup_uninstall_transaction; then
        red "基础卸载已完成，但临时快照清理失败：${transaction_dir}"
        return 3
    fi
    return 0
}

# 卸载 sing-box（交互式）
uninstall_singbox() {
    local uninstall_root="${1:-}"
    local purge_choice=0 uninstall_status

    reading "确定要卸载 sing-box 吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载 sing-box"
            reading "\n是否卸载 Nginx？${green}(卸载请输入 ${yellow}y${re} ${green}回车将跳过卸载Nginx) (y/n): ${re}" choice
            case "${choice}" in
                y|Y) purge_choice=1 ;;
                *)   yellow "取消卸载Nginx\n\n" ;;
            esac
            if perform_singbox_uninstall "$uninstall_root" "$purge_choice"; then
                uninstall_status=0
            else
                uninstall_status=$?
            fi
            [ "$uninstall_status" -eq 0 ] && green "\nsing-box 卸载成功\n\n"
            return "$uninstall_status"
            ;;
        *) purple "已取消卸载操作\n\n"; return 0 ;;
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

# Older installations sometimes added an `sb` alias that launches the core
# binary directly. Bash aliases take precedence over PATH, so that one legacy
# line prevents the local manager wrapper from ever being reached. Match only
# the known historical target and leave custom aliases untouched.
is_legacy_sb_binary_alias_line() {
    local line="${1:-}"
    local normalized

    line="${line%%#*}"
    normalized=$(printf '%s' "$line" | tr -d '[:space:]')
    case "$normalized" in
        'aliassb=/usr/local/bin/sing-box'|\
        "aliassb='/usr/local/bin/sing-box'"|\
        'aliassb="/usr/local/bin/sing-box"') return 0 ;;
        *) return 1 ;;
    esac
}

remove_legacy_sb_binary_aliases() {
    local install_root="${1:-}"
    local root_home="${install_root}/root"
    local startup_file tmp_file line
    local changed

    for startup_file in \
        "${root_home}/.bashrc" \
        "${root_home}/.bash_profile" \
        "${root_home}/.bash_aliases" \
        "${root_home}/.profile"; do
        [ -e "$startup_file" ] || continue
        if [ -L "$startup_file" ] || [ ! -f "$startup_file" ]; then
            yellow "跳过非普通 shell 配置文件：${startup_file}\n"
            return 1
        fi

        tmp_file=$(mktemp "$(dirname "$startup_file")/.sb-alias.XXXXXX") || return 1
        if ! cp -p "$startup_file" "$tmp_file" || ! : > "$tmp_file"; then
            rm -f "$tmp_file"
            return 1
        fi
        changed=0
        while IFS= read -r line || [ -n "$line" ]; do
            if is_legacy_sb_binary_alias_line "$line"; then
                changed=1
                continue
            fi
            if ! printf '%s\n' "$line" >> "$tmp_file"; then
                rm -f "$tmp_file"
                return 1
            fi
        done < "$startup_file"

        if [ "$changed" -eq 1 ]; then
            if ! mv -f "$tmp_file" "$startup_file"; then
                rm -f "$tmp_file"
                return 1
            fi
        else
            rm -f "$tmp_file"
        fi
    done
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
    if ! remove_legacy_sb_binary_aliases "$shortcut_root"; then
        yellow "未能安全清理旧版 sb 核心程序别名，请检查 root 的 shell 配置。\n"
    fi
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
    if ! remove_legacy_sb_binary_aliases "$install_root"; then
        yellow "未能安全清理旧版 sb 核心程序别名，请检查 root 的 shell 配置。\n"
    fi
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
detect_usable_init_system() {
    local systemd_runtime_dir="${SYSTEMD_RUNTIME_DIR:-/run/systemd/system}"
    local openrc_softlevel_file="${OPENRC_SOFTLEVEL_FILE:-/run/openrc/softlevel}"

    if command_exists systemctl && [ -d "$systemd_runtime_dir" ] && \
       systemctl show-environment >/dev/null 2>&1; then
        printf 'systemd\n'
        return 0
    fi
    if command_exists rc-update && command_exists rc-service && \
       [ -f "$openrc_softlevel_file" ]; then
        printf 'openrc\n'
        return 0
    fi
    return 1
}

# Fail-fast install orchestration shared by interactive and non-interactive paths.

run_install_flow() {
    local init_system='' stage_status resume_status=1 resuming_partial_install=0
    local -a install_firewall_records=()

    init_system=$(detect_usable_init_system) || {
        red "不支持或未运行的 init 系统，安装中止。"
        return 1
    }

    FIREWALL_LAST_ADDED_RECORDS=()
    clear_install_complete_marker || {
        red "无法清除旧的安装完成标记，安装中止。"
        return 1
    }
    manage_packages install nginx jq tar openssl lsof coreutils util-linux || {
        red "依赖安装失败，安装中止。"
        return 1
    }
    if prepare_partial_install_resume "$init_system"; then
        resuming_partial_install=1
        yellow "检测到由本脚本管理的未完成安装，继续生成订阅与收尾配置。"
    else
        resume_status=$?
        if [ "$resume_status" -eq 2 ]; then
            red "检测到未完成安装，但无法确认服务和监听器均由本脚本管理；拒绝覆盖凭据。"
            return 2
        fi

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

        if [ "$init_system" = systemd ]; then
            main_systemd_services || {
                stage_status=$?
                red "systemd 服务定义安装失败，安装中止。"
                yellow "保留已登记的防火墙规则供重试或卸载清理。"
                [ "$stage_status" -eq 2 ] && return 2
                return 1
            }
        elif [ "$init_system" = openrc ]; then
            alpine_openrc_services || {
                stage_status=$?
                red "OpenRC 服务定义安装失败，安装中止。"
                yellow "保留已登记的防火墙规则供重试或卸载清理。"
                [ "$stage_status" -eq 2 ] && return 2
                return 1
            }
        else
            handle_failed_install_stage 1 "不支持的 init 系统，安装中止。" \
                "${install_firewall_records[@]}"
            return $?
        fi

        persist_partial_install_resume_state || {
            red "无法保存安装重试状态；为避免覆盖已生成凭据，安装中止。"
            return 2
        }
    fi

    if [ "$init_system" = openrc ]; then
        change_hosts || {
            red "OpenRC 主机初始化失败，安装中止。"
            yellow "安装重试状态已保留；重试不会重新生成凭据。"
            return 1
        }
    fi
    enable_install_services "$init_system" || {
        red "核心服务启用失败，安装中止。"
        yellow "安装重试状态已保留；重试不会重新生成凭据。"
        return 1
    }
    start_pending_install_services "$init_system" || {
        stage_status=$?
        red "sing-box 或 Argo 服务启动复核失败，安装中止。"
        yellow "安装重试状态已保留；重试仅补启未运行的服务。"
        [ "$stage_status" -eq 2 ] && return 2
        return 1
    }

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
    if [ "$resuming_partial_install" -eq 1 ] || [ -e "$(partial_install_state_path)" ]; then
        clear_partial_install_resume_state || \
            yellow "安装已完成，但未能清理受限权限的安装重试状态文件。"
    fi
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
# shellcheck disable=SC2120  # Isolated-root tests pass $1; production CLI does not.
auto_uninstall() {
    local uninstall_root="${1:-}" uninstall_status

    green "Starting non-interactive sing-box uninstall..."
    if perform_singbox_uninstall "$uninstall_root" "${PURGE_NGINX:-0}"; then
        uninstall_status=0
    else
        uninstall_status=$?
    fi
    if [ "$uninstall_status" -eq 0 ]; then
        if [ "${PURGE_NGINX:-0}" = 1 ]; then
            green "\nsing-box and nginx have been purged.\n"
        else
            green "\nsing-box uninstalled; nginx retained. Use --purge-nginx to remove nginx too.\n"
        fi
    fi
    return "$uninstall_status"
}
report_node_change_transaction_result() {
    local transaction_status="${1:-2}"
    local success_message="${2:-配置修改已生效}"
    local show_client="${3:-1}"
    local line

    case "$show_client" in 0|1) ;; *) return 2 ;; esac
    case "$transaction_status" in
        0)
            if [ "$show_client" -eq 1 ] && [ -r "$client_dir" ]; then
                while IFS= read -r line; do yellow "$line"; done < "$client_dir"
            fi
            green "\n${success_message}\n"
            return 0
            ;;
        1)
            red "本次修改未提交，原配置已保留或完整恢复。"
            return 1
            ;;
        2)
            red "修改状态不确定或回滚不完整；请按上方恢复目录提示处理。"
            return 2
            ;;
        3)
            if [ "$show_client" -eq 1 ] && [ -r "$client_dir" ]; then
                while IFS= read -r line; do yellow "$line"; done < "$client_dir"
            fi
            yellow "${success_message}（已生效，但有清理待办；请保留上方提示信息）。"
            return 3
            ;;
        *)
            red "配置事务返回未知状态，已按不确定状态停止后续操作。"
            return 2
            ;;
    esac
}

change_config() {
    local singbox_status='' singbox_installed
    local inbounds_file="${conf_dir}/inbounds.json"
    local port_change_status transaction_status hy2_transaction_status

    if singbox_status=$(check_singbox 2>/dev/null); then
        singbox_installed=0
    else
        singbox_installed=$?
    fi

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
            case "${choice}" in
                1)
                    reading "\n请输入vless-reality端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    if change_public_inbound_port_transaction "$inbounds_file" reality "$new_port" tcp; then
                        port_change_status=0
                    else
                        port_change_status=$?
                    fi
                    [ "$port_change_status" -eq 0 ] || return "$port_change_status"
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nvless-reality端口已修改成：${purple}$new_port${re}\n"
                    ;;
                2)
                    reading "\n请输入hysteria2端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    if change_public_inbound_port_transaction "$inbounds_file" hysteria2 "$new_port" udp; then
                        port_change_status=0
                    else
                        port_change_status=$?
                    fi
                    [ "$port_change_status" -eq 0 ] || return "$port_change_status"
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nhysteria2端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                3)
                    reading "\n请输入tuic端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    if change_public_inbound_port_transaction "$inbounds_file" tuic "$new_port" udp; then
                        port_change_status=0
                    else
                        port_change_status=$?
                    fi
                    [ "$port_change_status" -eq 0 ] || return "$port_change_status"
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\ntuic端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                4)
                    reading "\n请输入vless-ws-tls-argo端口 (回车跳过将使用随机端口): " new_port
                    [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    if change_argo_port_transaction "$new_port"; then
                        transaction_status=0
                    else
                        transaction_status=$?
                    fi
                    report_node_change_transaction_result "$transaction_status" \
                        "vless-ws-tls-argo端口已修改为：${purple}${new_port}${re}"
                    return $?
                    ;;
                0) change_config ;;
                *) red "无效的选项，请输入 1 到 4" ;;
            esac
            ;;
        2)
            reading "\n请输入新的UUID(直接回车随机生成UUID): " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            if change_uuid_transaction "$new_uuid"; then
                transaction_status=0
            else
                transaction_status=$?
            fi
            report_node_change_transaction_result "$transaction_status" \
                "UUID已修改为：${purple}${new_uuid}${re}"
            return $?
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
            if change_reality_sni_transaction "$new_sni"; then
                transaction_status=0
            else
                transaction_status=$?
            fi
            report_node_change_transaction_result "$transaction_status" \
                "Reality sni已修改为：${purple}${new_sni}${re}"
            return $?
            ;;
        4)
            purple "端口跳跃需确保跳跃区间的端口没有被占用\n"
            reading "请输入跳跃起始端口 (回车跳过将使用随机端口): " min_port
            [ -z "$min_port" ] && min_port=$(shuf -i 50000-65000 -n 1)
            yellow "你的起始端口为：$min_port"
            reading "\n请输入跳跃结束端口 (需大于起始端口): " max_port
            [ -z "$max_port" ] && max_port=$(($min_port + 100))
            yellow "你的结束端口为：$max_port\n"
            if enable_hy2_port_hopping_transaction "$min_port" "$max_port"; then
                hy2_transaction_status=0
            else
                hy2_transaction_status=$?
            fi
            if [ "$hy2_transaction_status" -eq 3 ]; then
                yellow "Hysteria2 端口跳跃已启用，但旧事务备份未能清理；请按上方保留路径处理。"
            elif [ "$hy2_transaction_status" -ne 0 ]; then
                [ "$hy2_transaction_status" -eq 2 ] && return 2
                red "Hysteria2 端口跳跃启用失败，原配置已保留或恢复。"
                return 1
            fi
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nhysteria2端口跳跃已开启：${purple}$min_port-$max_port${re}\n"
            ;;
        5)
            if disable_hy2_port_hopping_transaction; then
                hy2_transaction_status=0
            else
                hy2_transaction_status=$?
            fi
            if [ "$hy2_transaction_status" -eq 3 ]; then
                yellow "Hysteria2 端口跳跃已删除，但旧事务备份未能清理；请按上方保留路径处理。"
            elif [ "$hy2_transaction_status" -ne 0 ]; then
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
                if change_client_ip_transaction ipv4 "$new_ipv4"; then
                    transaction_status=0
                else
                    transaction_status=$?
                fi
                report_node_change_transaction_result "$transaction_status" \
                    "已将直连节点地址修改为 IPv4：${new_ipv4}"
                return $?
            else
                yellow "\n当前已是ipv4, 无需切换\n" && return 0
            fi
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
                if change_client_ip_transaction ipv6 "$new_ipv6"; then
                    transaction_status=0
                else
                    transaction_status=$?
                fi
                report_node_change_transaction_result "$transaction_status" \
                    "已将直连节点地址修改为 IPv6：[${new_ipv6}]"
                return $?
            else
                yellow "\n当前已是ipv6, 无需切换\n" && return 0
            fi
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
    old_domain_mode="${SUB_HTTPS_DOMAIN_MODE:-}"
    old_https_path="${SUB_HTTPS_PATH:-}"
    old_path_regex=""
    is_valid_subscription_path "$old_https_path" && old_path_regex="^${old_https_path}$"
    if [ -n "$old_domain" ] && [ -n "$old_https_path" ]; then
        old_https_url=$(build_https_subscription_url "$old_domain" "$old_https_path" 2>/dev/null || true)
    fi

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
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "HTTPS 订阅操作"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _configure_cf_https_subscription_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
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
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "HTTPS 订阅操作"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _disable_cf_https_subscription_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
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
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅端口修改"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _change_subscription_port_transaction_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
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
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅密钥轮换"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _rotate_subscription_token_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
}

_stop_subscription_service_locked() {
    local nginx_state

    if command_exists nginx; then
        detect_usable_init_system >/dev/null || return 1
        nginx_state=$(query_nginx_service_state) || return 1
        case "$nginx_state" in
            inactive)
                red "nginx not running"
                ;;
            active)
                stop_nginx_checked || return 1
                nginx_state=$(query_nginx_service_state) || return 1
                [ "$nginx_state" = inactive ] || return 1
                ;;
            error|*) return 1 ;;
        esac
    else
        yellow "nginx未安装，节点订阅本来就未运行。"
    fi
    return 0
}

stop_subscription_service_transaction() {
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅服务停止"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _stop_subscription_service_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
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
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅服务启动"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _start_subscription_service_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
}

_restart_subscription_service_locked() {
    restart_nginx
}

restart_subscription_service_transaction() {
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "订阅服务重启"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _restart_subscription_service_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
}

disable_open_sub() {
    local singbox_installed=$?
    local action_rc=0
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
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回...\033[0m\n' || true
    return "$action_rc"
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
    local transition_rc argo_mode
    clear; echo ""
    green "=== Argo 隧道管理 ===\n"
    green "Argo当前状态: $argo_status\n"
    green "1. 启动Argo服务"
    skyblue "------------"
    green "2. 停止Argo服务"
    skyblue "------------"
    green "3. 重启Argo服务（临时隧道会同步更新域名）"
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
            if [ -z "$service_file" ]; then
                service_file=$(resolve_argo_service_definition) || {
                    red "无法解析当前 Argo 服务定义。"
                    return 1
                }
            fi
            argo_mode=$(detect_argo_tunnel_mode "$service_file" 2>/dev/null) || {
                red "无法识别当前 Argo Tunnel 类型。"
                return 1
            }
            if [ "$argo_mode" = quick ]; then
                refresh_quick_argo "$service_file" || return $?
            else
                if restart_argo; then
                    green "\n固定 Argo 隧道服务已重启，域名保持不变。"
                else
                    red "固定 Argo 隧道服务重启失败，请检查服务日志。"
                    return 1
                fi
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
                transition_to_fixed_argo "$argo_domain" json "$argo_auth" || {
                    transition_rc=$?
                    if [ "$transition_rc" -eq 2 ]; then
                        red "固定 Tunnel 切换失败且自动回滚不完整；请按上方恢复快照提示手动处理。"
                        return 2
                    fi
                    if [ "$transition_rc" -eq 3 ]; then
                        yellow "固定 Tunnel 已成功切换；仅旧快照清理未完成，请按上方路径手动清理。"
                        return 3
                    fi
                    red "固定 Tunnel 切换失败，原服务、凭据与订阅已恢复。"
                    return "$transition_rc"
                }
            elif is_argo_tunnel_token "$argo_auth"; then
                transition_to_fixed_argo "$argo_domain" token "$argo_auth" || {
                    transition_rc=$?
                    if [ "$transition_rc" -eq 2 ]; then
                        red "固定 Tunnel 切换失败且自动回滚不完整；请按上方恢复快照提示手动处理。"
                        return 2
                    fi
                    if [ "$transition_rc" -eq 3 ]; then
                        yellow "固定 Tunnel 已成功切换；仅旧快照清理未完成，请按上方路径手动清理。"
                        return 3
                    fi
                    red "固定 Tunnel 切换失败，原服务、凭据与订阅已恢复。"
                    return "$transition_rc"
                }
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
            transition_to_quick_argo || {
                transition_rc=$?
                if [ "$transition_rc" -eq 2 ]; then
                    red "临时 Tunnel 切换失败且自动回滚不完整；请按上方恢复快照提示手动处理。"
                    return 2
                fi
                if [ "$transition_rc" -eq 3 ]; then
                    yellow "临时 Tunnel 已成功切换；仅旧快照清理未完成，请按上方路径手动清理。"
                    return 3
                fi
                red "临时 Tunnel 切换失败，原服务、凭据、订阅与 HTTPS 状态已恢复。"
                return "$transition_rc"
            }
            yellow "已切换临时 Tunnel；固定凭据已清理，HTTP 订阅保留。"
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

    tmp_file=$(mktemp "$(dirname "$target_file")/.tmp.$(basename "$target_file").argo.XXXXXX") || return 1
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

    tmp_file=$(mktemp "$(dirname "$target_file")/.tmp.$(basename "$target_file").uuid.XXXXXX") || return 1
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
    mutate_base_subscription update_vless_argo_domain_file "$1"
}

update_argo_subscription_file() {
    local staged_base_file="$1"
    local new_domain="$2"
    local vmess_url encoded_vmess decoded_vmess updated_vmess encoded_updated_vmess new_vmess_url

    update_vless_argo_domain_file "$staged_base_file" "$new_domain" || return 1
    vmess_url=$(grep -o 'vmess://[^ ]*' "$staged_base_file" | head -1)
    [ -n "$vmess_url" ] || return 0
    encoded_vmess="${vmess_url#vmess://}"
    decoded_vmess=$(printf '%s' "$encoded_vmess" | base64 --decode 2>/dev/null || true)
    [ -n "$decoded_vmess" ] || return 0
    updated_vmess=$(printf '%s' "$decoded_vmess" | jq --arg new_domain "$new_domain" \
        '.host = $new_domain | .sni = $new_domain | del(.allowInsecure)' 2>/dev/null || true)
    [ -n "$updated_vmess" ] || return 0
    encoded_updated_vmess=$(printf '%s' "$updated_vmess" | base64 | tr -d '\n\r')
    new_vmess_url="vmess://${encoded_updated_vmess}"
    sed -i "s|$vmess_url|$new_vmess_url|" "$staged_base_file"
}

change_argo_domain() {
    [ -z "$ArgoDomain" ] && { red "未获取到Argo域名，无法更新节点"; return 1; }

    # 兼容用户手动保留的旧 VMess 模板；默认新安装不再生成 VMess。
    mutate_base_subscription update_argo_subscription_file "$ArgoDomain" || return $?

    green "vless-ws-tls-argo节点已更新\n"
    grep 'path=%2Fvless-argo' "$client_dir" | while IFS= read -r line; do purple "$line\n"; done
    show_current_cfy_results argo || yellow "无法读取优选结果，请稍后运行 sb -c 查看。"
    return 0
}
show_current_cfy_results() {
    with_subscription_lock show_current_cfy_results_locked "${1:-all}"
}

show_current_cfy_results_locked() {
    local mode="${1:-all}" cfy_file="${work_dir}/cfy-url.txt" selected_source line

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
    if [ ! -s "$cfy_file" ]; then
        if [ "$mode" = all ]; then
            yellow "\n尚未找到优选结果，请运行 cfy 生成优选节点。\n"
        fi
        return 0
    fi
    selected_source=$(select_cfy_subscription_source_locked) || return 1
    if [ "$selected_source" = /dev/null ]; then
        yellow "\n优选结果已过期或无法核对：基础节点可能已变化，请重新运行 cfy。旧结果不会加入当前订阅。\n"
        return 0
    fi
    [ "$mode" != all ] || green "\n=== 当前 cfy 优选节点 ===\n"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line//$'\r'/}"
        [ -n "$line" ] || continue
        if [ "$mode" = argo ] && [[ "$line" != *'path=%2Fvless-argo'* ]]; then
            continue
        fi
        purple "$line\n"
    done < "$selected_source"
    return 0
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
    local base64_url
    base64_url=$(resolve_installed_subscription_source_url "$server_ip" 2>/dev/null || true)

    clear; echo ""
    green "=== 当前节点信息 ===\n"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "${purple}${line}${re}\n"
    done < "${work_dir}/url.txt"

    show_current_cfy_results || yellow "无法读取优选结果，请稍后重试。"

    yellow "\n温馨提醒: 如果hysteria2或tuic不通，请尝试将节点里的 "跳过证书验证" 设置为 "true" 或切换内核\n"
    green "\n=== 订阅链接 ===\n"

    show_subscription_links "$base64_url"
}

is_valid_ipv4_address() {
    local value="${1:-}" part
    local -a parts

    [[ "$value" =~ ^[0-9]+([.][0-9]+){3}$ ]] || return 1
    IFS='.' read -r -a parts <<< "$value"
    [ "${#parts[@]}" -eq 4 ] || return 1
    for part in "${parts[@]}"; do
        [ "${#part}" -eq 1 ] || [[ "$part" != 0* ]] || return 1
        [ "$part" -ge 0 ] 2>/dev/null && [ "$part" -le 255 ] 2>/dev/null || return 1
    done
}

is_valid_ipv6_address() {
    local value="${1:-}" left right part without_double
    local -a left_parts=() right_parts=() all_parts=()
    local compressed=0

    [ -n "$value" ] && [[ "$value" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$value" != *:::* ]] || return 1
    without_double="${value//::/}"
    [ $(( (${#value} - ${#without_double}) / 2 )) -le 1 ] || return 1

    if [[ "$value" == *::* ]]; then
        compressed=1
        left="${value%%::*}"
        right="${value#*::}"
        [ -z "$left" ] || IFS=':' read -r -a left_parts <<< "$left"
        [ -z "$right" ] || IFS=':' read -r -a right_parts <<< "$right"
        all_parts=("${left_parts[@]}" "${right_parts[@]}")
        [ "${#all_parts[@]}" -lt 8 ] || return 1
    else
        [[ "$value" != :* && "$value" != *: ]] || return 1
        IFS=':' read -r -a all_parts <<< "$value"
        [ "${#all_parts[@]}" -eq 8 ] || return 1
    fi

    for part in "${all_parts[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
    [ "$compressed" -eq 1 ] || [ "${#all_parts[@]}" -eq 8 ]
}

is_valid_endpoint_hostname() {
    local value="${1:-}" label
    local -a labels

    [ -n "$value" ] && [ "${#value}" -le 253 ] || return 1
    [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
    IFS='.' read -r -a labels <<< "$value"
    for label in "${labels[@]}"; do
        [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

parse_cfip_endpoint() {
    local input="${1:-}"
    local host port colon_chars

    case "$input" in
        ""|1) host='cf.090227.xyz';       port=443 ;;
        2)    host='cf.877774.xyz';        port=443 ;;
        3)    host='cf.877771.xyz';        port=443 ;;
        4)    host='cdns.doon.eu.org';     port=443 ;;
        5)    host='cf.zhetengsha.eu.org'; port=443 ;;
        6)    host='time.is';              port=443 ;;
        \[*\]:*)
            host="${input%%]*}"
            host="${host#[}"
            port="${input##*]:}"
            ;;
        \[*\])
            host="${input#[}"
            host="${host%]}"
            port=443
            ;;
        *)
            colon_chars="${input//[^:]/}"
            if [ "${#colon_chars}" -eq 1 ]; then
                host="${input%:*}"
                port="${input##*:}"
            else
                host="$input"
                port=443
            fi
            ;;
    esac

    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] 2>/dev/null && \
        [ "$port" -le 65535 ] 2>/dev/null || return 1
    if [[ "$host" == *:* ]]; then
        is_valid_ipv6_address "$host" || return 1
    elif [[ "$host" =~ ^[0-9.]+$ ]]; then
        is_valid_ipv4_address "$host" || return 1
    else
        is_valid_endpoint_hostname "$host" || return 1
    fi
    printf '%s\t%s\n' "$host" "$port"
}

format_vless_endpoint() {
    local host="${1:-}"
    local port="${2:-}"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    if [[ "$host" == *:* ]]; then
        printf '[%s]:%s\n' "$host" "$port"
    else
        printf '%s:%s\n' "$host" "$port"
    fi
}

update_argo_preferred_address_file() {
    local target_file="${1:-}"
    local host="${2:-}"
    local port="${3:-}"
    local mode="${4:-}"
    local endpoint tmp_file line fragment query
    local has_preferred=0 has_stable=0 updated=0 emitted_preferred=0

    [ -s "$target_file" ] || return 0
    [[ "$mode" == fixed || "$mode" == quick ]] || return 1
    endpoint=$(format_vless_endpoint "$host" "$port") || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == vless://* && "$line" == *"path=%2Fvless-argo"* && "$line" == *'#'* ]]; then
            fragment="${line#*#}"
            if [[ "$fragment" == *-preferred ]]; then
                has_preferred=1
            else
                has_stable=1
            fi
        fi
    done < "$target_file"
    [ "$has_stable" -eq 1 ] || return 1

    tmp_file=$(mktemp "$(dirname "$target_file")/.argo-address.XXXXXX") || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == vless://* && "$line" == *"path=%2Fvless-argo"* && "$line" == *'?'* ]]; then
            fragment="${line#*#}"
            if [ "$mode" = quick ] && [[ "$fragment" != *-preferred ]]; then
                line="${line%%@*}@${endpoint}?${line#*\?}"
                updated=1
            elif [ "$mode" = fixed ] && [[ "$fragment" == *-preferred ]]; then
                line="${line%%@*}@${endpoint}?${line#*\?}"
                updated=1
                emitted_preferred=1
            fi
        fi
        printf '%s\n' "$line"
        if [ "$mode" = fixed ] && [ "$has_preferred" -eq 0 ] && \
           [ "$emitted_preferred" -eq 0 ] && [[ "$fragment" != *-preferred ]] && \
           [[ "$line" == vless://* && "$line" == *"path=%2Fvless-argo"* && "$line" == *'?'* ]]; then
            query="${line#*\?}"
            query="${query%%#*}"
            printf '%s@%s?%s#%s-preferred\n' \
                "${line%%@*}" "$endpoint" "$query" "$fragment"
            emitted_preferred=1
            updated=1
        fi
    done < "$target_file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    if [ "$updated" -ne 1 ]; then
        rm -f "$tmp_file"
        return 1
    fi
    chmod 600 "$tmp_file" 2>/dev/null || {
        rm -f "$tmp_file"
        return 1
    }
    mv -f "$tmp_file" "$target_file"
}

rebuild_argo_client_address_set_file() {
    local target_file="${1:-}"
    local mode="${2:-}"
    local stable_domain="${3:-}"
    local fallback_host="${4:-}"
    local fallback_port="${5:-}"
    local line fragment template='' template_fragment base_fragment query userinfo
    local stable_endpoint fallback_endpoint tmp_file emitted=0 file_mode

    [ -s "$target_file" ] || return 1
    [[ "$mode" == fixed || "$mode" == quick ]] || return 1
    fallback_endpoint=$(format_vless_endpoint "$fallback_host" "$fallback_port") || return 1
    if [ "$mode" = fixed ]; then
        stable_endpoint=$(format_vless_endpoint "$stable_domain" "$fallback_port") || return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == vless://* && "$line" == *"path=%2Fvless-argo"* && "$line" == *'?'* && "$line" == *'#'* ]] || continue
        fragment="${line#*#}"
        if [ -z "$template" ] || [[ "$fragment" != *-preferred ]]; then
            template="$line"
        fi
        [[ "$fragment" != *-preferred ]] && break
    done < "$target_file"
    [ -n "$template" ] || return 1

    template_fragment="${template#*#}"
    base_fragment="${template_fragment%-preferred}"
    query="${template#*\?}"
    query="${query%%#*}"
    userinfo="${template%%@*}"

    tmp_file=$(mktemp "$(dirname "$target_file")/.argo-address-set.XXXXXX") || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == vless://* && "$line" == *"path=%2Fvless-argo"* ]]; then
            if [ "$emitted" -eq 0 ]; then
                if [ "$mode" = fixed ]; then
                    printf '%s@%s?%s#%s\n' "$userinfo" "$stable_endpoint" "$query" "$base_fragment"
                    if [ "$fallback_endpoint" != "$stable_endpoint" ]; then
                        printf '%s@%s?%s#%s-preferred\n' \
                            "$userinfo" "$fallback_endpoint" "$query" "$base_fragment"
                    fi
                else
                    printf '%s@%s?%s#%s\n' "$userinfo" "$fallback_endpoint" "$query" "$base_fragment"
                fi
                emitted=1
            fi
            continue
        fi
        printf '%s\n' "$line"
    done < "$target_file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    [ "$emitted" -eq 1 ] || { rm -f "$tmp_file"; return 1; }
    file_mode=$(stat -c '%a' "$target_file" 2>/dev/null) || {
        rm -f "$tmp_file"
        return 1
    }
    chmod "$file_mode" "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv -f "$tmp_file" "$target_file"
}

rebuild_argo_transition_subscription_file() {
    local staged_base_file="${1:-}"
    local mode="${2:-}"
    local stable_domain="${3:-}"
    local fallback_host="${4:-}"
    local fallback_port="${5:-}"
    local new_domain="${6:-}"

    rebuild_argo_client_address_set_file "$staged_base_file" \
        "$mode" "$stable_domain" "$fallback_host" "$fallback_port" || return 1
    update_argo_subscription_file "$staged_base_file" "$new_domain"
}

publish_tracked_argo_transition_subscription_locked() {
    local mode="${1:-}"
    local stable_domain="${2:-}"
    local fallback_host="${3:-}"
    local fallback_port="${4:-}"
    local rollback_file old_generation new_generation publish_status=0

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
    [ -f "$client_dir" ] && [ ! -L "$client_dir" ] || return 1
    rollback_file=$(mktemp "${work_dir}/.argo-subscription-rollback.XXXXXX") || return 1
    cp -p -- "$client_dir" "$rollback_file" || { rm -f "$rollback_file"; return 1; }
    chmod 600 "$rollback_file" || { rm -f "$rollback_file"; return 1; }
    old_generation=$(get_base_subscription_generation_locked "$client_dir") || {
        rm -f "$rollback_file"
        return 1
    }

    if grep -Fq 'path=%2Fvless-argo' "$client_dir"; then
        mutate_base_subscription_locked rebuild_argo_transition_subscription_file \
            "$mode" "$stable_domain" "$fallback_host" "$fallback_port" "$ArgoDomain" || \
            publish_status=$?
    else
        mutate_base_subscription_locked update_argo_subscription_file "$ArgoDomain" || \
            publish_status=$?
    fi
    if [ "$publish_status" -ne 0 ]; then
        if [ "$publish_status" -eq 1 ] && rm -f "$rollback_file"; then
            return 1
        fi
        ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE="$rollback_file"
        ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION="$old_generation"
        ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION=''
        [ "$publish_status" -ne 1 ] || publish_status=2
        return "$publish_status"
    fi
    new_generation=$(get_base_subscription_generation_locked "$client_dir") || {
        ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE="$rollback_file"
        ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION="$old_generation"
        ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION=''
        return 2
    }
    ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE="$rollback_file"
    ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION="$old_generation"
    ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION="$new_generation"
}

restore_argo_transition_subscription_locked() {
    local rollback_file="${1:-}"
    local old_generation="${2:-}"
    local expected_generation="${3:-}"
    local current_generation rollback_generation staged_file publish_status=0

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 2
    [ -f "$rollback_file" ] && [ ! -L "$rollback_file" ] || return 2
    current_generation=$(get_base_subscription_generation_locked "$client_dir") || return 2
    [ "$current_generation" = "$expected_generation" ] || return 2
    rollback_generation=$(get_base_subscription_generation_locked "$rollback_file") || return 2
    [ "$rollback_generation" = "$old_generation" ] || return 2
    staged_file=$(mktemp "${work_dir}/.tmp.$(basename "$client_dir").argo-rollback.XXXXXX") || return 2
    cp -p -- "$rollback_file" "$staged_file" || { rm -f "$staged_file"; return 2; }
    chmod 600 "$staged_file" || { rm -f "$staged_file"; return 2; }
    publish_subscriptions_locked "$staged_file" || publish_status=$?
    if [ "$publish_status" -ne 0 ]; then
        rm -f "$staged_file"
        return 2
    fi
    current_generation=$(get_base_subscription_generation_locked "$client_dir") || return 2
    [ "$current_generation" = "$old_generation" ] || return 2
    rm -f -- "$rollback_file" || return 2
}

restore_argo_transition_subscription() {
    with_subscription_lock restore_argo_transition_subscription_locked "$@"
}

change_argo_transition_subscription() {
    local mode="${1:-}"
    local stable_domain="${2:-}"
    local fallback_host="${3:-}"
    local fallback_port="${4:-}"
    local track_rollback="${5:-0}"

    [ -n "${ArgoDomain:-}" ] || { red "未获取到Argo域名，无法更新节点"; return 1; }
    [[ "$mode" == fixed || "$mode" == quick ]] || return 1
    [[ "$track_rollback" == 0 || "$track_rollback" == 1 ]] || return 1
    ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE=''
    ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION=''
    ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION=''
    if [ "$track_rollback" = 1 ]; then
        with_subscription_lock publish_tracked_argo_transition_subscription_locked \
            "$mode" "$stable_domain" "$fallback_host" "$fallback_port" || return $?
    elif [ ! -s "$client_dir" ] || ! grep -Fq 'path=%2Fvless-argo' "$client_dir"; then
        change_argo_domain
        return $?
    else
        mutate_base_subscription rebuild_argo_transition_subscription_file \
            "$mode" "$stable_domain" "$fallback_host" "$fallback_port" "$ArgoDomain" || return $?
    fi

    green "vless-ws-tls-argo节点已更新\n"
    grep 'path=%2Fvless-argo' "$client_dir" | while IFS= read -r line; do purple "$line\n"; done
    show_current_cfy_results argo || yellow "无法读取优选结果，请稍后运行 sb -c 查看。"
    return 0
}

get_current_argo_preferred_endpoint() {
    local target_file="${1:-}"
    local allow_stable="${2:-0}"
    local line fragment stable_line=''

    [ -s "$target_file" ] || return 1
    [[ "$allow_stable" == 0 || "$allow_stable" == 1 ]] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == vless://* && "$line" == *"path=%2Fvless-argo"* && "$line" == *'?'* ]] || continue
        fragment="${line#*#}"
        if [[ "$fragment" == *-preferred ]]; then
            line="${line#*@}"
            parse_cfip_endpoint "${line%%\?*}"
            return
        fi
        [ -n "$stable_line" ] || stable_line="$line"
    done < "$target_file"
    [ "$allow_stable" -eq 1 ] && [ -n "$stable_line" ] || return 1
    stable_line="${stable_line#*@}"
    parse_cfip_endpoint "${stable_line%%\?*}"
}

create_argo_transition_snapshot() {
    local init_system="${1:-}"
    local install_root="${2:-${ARGO_TRANSITION_ROOT:-}}"
    local snapshot_dir service_file name source_file

    [[ "$init_system" == systemd || "$init_system" == openrc ]] || return 1
    snapshot_dir=$(mktemp -d "${work_dir}/.argo-transition.XXXXXX") || return 1
    chmod 700 "$snapshot_dir" || { rm -rf -- "$snapshot_dir"; return 1; }
    if [ "$init_system" = systemd ]; then
        service_file="${install_root}/etc/systemd/system/argo.service"
    else
        service_file="${install_root}/etc/init.d/argo"
    fi
    for name in service tunnel.json tunnel.yml argo.env; do
        case "$name" in
            service) source_file="$service_file" ;;
            *) source_file="${work_dir}/${name}" ;;
        esac
        if [ -e "$source_file" ]; then
            [ -f "$source_file" ] && [ ! -L "$source_file" ] || {
                rm -rf -- "$snapshot_dir"
                return 1
            }
            cp -p "$source_file" "${snapshot_dir}/${name}" || {
                rm -rf -- "$snapshot_dir"
                return 1
            }
            chmod 600 "${snapshot_dir}/${name}" || {
                rm -rf -- "$snapshot_dir"
                return 1
            }
        else
            : > "${snapshot_dir}/${name}.absent" || {
                rm -rf -- "$snapshot_dir"
                return 1
            }
            chmod 600 "${snapshot_dir}/${name}.absent" || {
                rm -rf -- "$snapshot_dir"
                return 1
            }
        fi
    done
    printf '%s\n' "$snapshot_dir"
}

restore_argo_transition_snapshot() {
    local snapshot_dir="${1:-}"
    local init_system="${2:-}"
    local install_root="${3:-${ARGO_TRANSITION_ROOT:-}}"
    local service_file name target_file rollback_ok=1

    [ -d "$snapshot_dir" ] || return 1
    if [ "$init_system" = systemd ]; then
        service_file="${install_root}/etc/systemd/system/argo.service"
    elif [ "$init_system" = openrc ]; then
        service_file="${install_root}/etc/init.d/argo"
    else
        return 1
    fi
    for name in service tunnel.json tunnel.yml argo.env; do
        case "$name" in
            service) target_file="$service_file" ;;
            *) target_file="${work_dir}/${name}" ;;
        esac
        if [ -f "${snapshot_dir}/${name}" ]; then
            mkdir -p "$(dirname "$target_file")" && \
                cp -p "${snapshot_dir}/${name}" "$target_file" || rollback_ok=0
        elif [ -f "${snapshot_dir}/${name}.absent" ]; then
            rm -f "$target_file" || rollback_ok=0
        else
            rollback_ok=0
        fi
    done
    if [ "$init_system" = systemd ]; then
        systemctl daemon-reload >/dev/null 2>&1 || rollback_ok=0
    fi
    [ "$rollback_ok" -eq 1 ]
}

activate_argo_service_mode() {
    local mode="${1:-}"
    local init_system="${2:-}"
    local install_root="${3:-${ARGO_TRANSITION_ROOT:-}}"
    local writer_status=0

    [[ "$mode" == quick || "$mode" == local || "$mode" == token ]] || return 1
    case "$init_system" in
        systemd)
            write_argo_systemd_service "$mode" "$install_root" || {
                writer_status=$?
                return "$writer_status"
            }
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            systemctl enable argo >/dev/null 2>&1 || return 1
            ;;
        openrc)
            write_argo_openrc_service "$mode" "$install_root" || {
                writer_status=$?
                return "$writer_status"
            }
            chmod +x "${install_root}/etc/init.d/argo" || return 1
            rc-update add argo default >/dev/null 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac
    restart_argo
}

_transition_to_quick_argo_locked() {
    local init_system old_mode snapshot_dir preferred_host preferred_port
    local old_argo_domain="${ARGO_DOMAIN:-}" old_argo_auth="${ARGO_AUTH:-}"
    local old_fixed_ready="${ARGO_FIXED_READY:-0}" old_runtime_domain="${ArgoDomain:-}"
    local rollback_ok=1 https_disable_rc=0 https_disable_committed=0 committed_warning=0
    local activation_status=0 subscription_status=0 subscription_published=0
    local subscription_rollback_file='' subscription_old_generation='' subscription_new_generation=''

    init_system=$(detect_usable_init_system) || return 1
    old_mode=$(detect_argo_tunnel_mode 2>/dev/null || printf 'unknown')
    read -r preferred_host preferred_port < <(
        get_current_argo_preferred_endpoint "$client_dir" "$([ "$old_mode" = quick ] && printf 1 || printf 0)"
    ) || {
        preferred_host="$CFIP"
        preferred_port="$CFPORT"
    }
    snapshot_dir=$(create_argo_transition_snapshot "$init_system") || return 1

    use_quick_argo_fallback
    activate_argo_service_mode quick "$init_system" || activation_status=$?
    if [ "$activation_status" -eq 2 ]; then
        ARGO_DOMAIN="$old_argo_domain"
        ARGO_AUTH="$old_argo_auth"
        ARGO_FIXED_READY="$old_fixed_ready"
        ArgoDomain="$old_runtime_domain"
        red "Argo 服务定义或事务锁状态不确定；为避免覆盖外部修改，未执行自动回滚；恢复快照已保留：${snapshot_dir}"
        return 2
    fi
    if [ "$activation_status" -eq 0 ] && get_quick_tunnel; then
        change_argo_transition_subscription quick "$ArgoDomain" \
            "$preferred_host" "$preferred_port" 1 || subscription_status=$?
        if [ "$subscription_status" -eq 0 ]; then
            subscription_published=1
            subscription_rollback_file="${ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE:-}"
            subscription_old_generation="${ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION:-}"
            subscription_new_generation="${ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION:-}"
            load_subscription_state
            if [ "${SUB_HTTPS_ENABLED:-0}" = 1 ]; then
                if _disable_cf_https_subscription_locked; then
                    https_disable_rc=0
                    https_disable_committed=1
                else
                    https_disable_rc=$?
                    if [ "$https_disable_rc" -eq 3 ]; then
                        https_disable_committed=1
                        committed_warning=1
                    fi
                fi
            fi
            if { [ "$https_disable_rc" -eq 0 ] || [ "$https_disable_rc" -eq 3 ]; } && \
               rm -f "${work_dir}/tunnel.json" "${work_dir}/tunnel.yml" "${work_dir}/argo.env"; then
                if [ -n "$subscription_rollback_file" ] && \
                   ! rm -f -- "$subscription_rollback_file"; then
                    yellow "Argo 临时 Tunnel 已成功切换，但订阅回滚凭据未能清理：${subscription_rollback_file}"
                    return 3
                fi
                ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE=''
                ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION=''
                ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION=''
                if ! rm -rf -- "$snapshot_dir"; then
                    yellow "Argo 临时 Tunnel 已成功切换，但旧快照未能清理，请手动删除：${snapshot_dir}"
                    return 3
                fi
                [ "$committed_warning" -eq 0 ] || return 3
                return 0
            fi
        elif [ -n "${ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE:-}" ]; then
            subscription_rollback_file="$ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE"
            rollback_ok=0
        fi
    fi

    restore_argo_transition_snapshot "$snapshot_dir" "$init_system" || rollback_ok=0
    ARGO_DOMAIN="$old_argo_domain"
    ARGO_AUTH="$old_argo_auth"
    ARGO_FIXED_READY="$old_fixed_ready"
    ArgoDomain="$old_runtime_domain"
    restart_argo >/dev/null 2>&1 || rollback_ok=0
    if [ "$subscription_published" -eq 1 ]; then
        if [ -n "$subscription_rollback_file" ] && \
           [ -n "$subscription_old_generation" ] && \
           [ -n "$subscription_new_generation" ]; then
            restore_argo_transition_subscription "$subscription_rollback_file" \
                "$subscription_old_generation" "$subscription_new_generation" || rollback_ok=0
        else
            rollback_ok=0
        fi
    fi
    [ "$https_disable_rc" -ne 2 ] || rollback_ok=0
    [ "$https_disable_committed" -ne 1 ] || rollback_ok=0
    if [ "$rollback_ok" -eq 1 ]; then
        rm -rf -- "$snapshot_dir" || {
            red "Argo 模式切换失败；运行状态已恢复，但临时快照无法清理：${snapshot_dir}"
            return 2
        }
        return 1
    fi
    if [ -n "$subscription_rollback_file" ]; then
        red "Argo 模式切换失败且自动回滚不完整；恢复快照已保留：${snapshot_dir}；订阅回滚凭据已保留：${subscription_rollback_file}"
    else
        red "Argo 模式切换失败且自动回滚不完整；恢复快照已保留：${snapshot_dir}"
    fi
    return 2
}

_transition_to_fixed_argo_locked() {
    local new_domain="${1:-}" auth_type="${2:-}" auth_value="${3:-}"
    local init_system old_mode snapshot_dir preferred_host preferred_port tunnel_id
    local old_argo_domain="${ARGO_DOMAIN:-}" old_argo_auth="${ARGO_AUTH:-}"
    local old_fixed_ready="${ARGO_FIXED_READY:-0}" old_runtime_domain="${ArgoDomain:-}"
    local rollback_ok=1 activation_status=0 subscription_status=0 subscription_rollback_file=''

    [ -n "$new_domain" ] && [ -n "$auth_value" ] || return 1
    [[ "$auth_type" == json || "$auth_type" == token ]] || return 1
    init_system=$(detect_usable_init_system) || return 1
    old_mode=$(detect_argo_tunnel_mode 2>/dev/null || printf 'unknown')
    load_subscription_state
    if [ "${SUB_HTTPS_ENABLED:-0}" = 1 ]; then
        red "当前固定 Argo 隧道仍启用了 HTTPS 订阅。请先关闭 HTTPS 订阅，再切换固定隧道。"
        return 1
    fi
    if ! read -r preferred_host preferred_port < <(
        get_current_argo_preferred_endpoint "$client_dir" "$([ "$old_mode" = quick ] && printf 1 || printf 0)"
    ); then
        preferred_host="$CFIP"
        preferred_port="$CFPORT"
    fi
    snapshot_dir=$(create_argo_transition_snapshot "$init_system") || return 1

    ARGO_DOMAIN="$new_domain"
    ARGO_AUTH="$auth_value"
    ARGO_FIXED_READY=1
    ArgoDomain="$new_domain"
    if [ "$auth_type" = json ]; then
        tunnel_id=$(extract_argo_tunnel_id "$auth_value" 2>/dev/null || true)
        [ -n "$tunnel_id" ] || rollback_ok=0
        if [ "$rollback_ok" -eq 1 ]; then
            write_fixed_argo_credentials json "$auth_value" "${ARGO_TRANSITION_ROOT:-}" || rollback_ok=0
            rm -f "${work_dir}/argo.env" || rollback_ok=0
            if [ "$rollback_ok" -eq 1 ]; then
                atomic_write_secret_file "${work_dir}/tunnel.yml" <<EOF || rollback_ok=0
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: ${new_domain}
    service: http://127.0.0.1:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
            fi
        fi
    else
        write_fixed_argo_credentials token "$auth_value" "${ARGO_TRANSITION_ROOT:-}" || rollback_ok=0
        rm -f "${work_dir}/tunnel.json" "${work_dir}/tunnel.yml" || rollback_ok=0
    fi

    if [ "$rollback_ok" -eq 1 ]; then
        activate_argo_service_mode "$([ "$auth_type" = json ] && printf local || printf token)" \
            "$init_system" || activation_status=$?
        if [ "$activation_status" -eq 2 ]; then
            ARGO_DOMAIN="$old_argo_domain"
            ARGO_AUTH="$old_argo_auth"
            ARGO_FIXED_READY="$old_fixed_ready"
            ArgoDomain="$old_runtime_domain"
            red "Argo 服务定义或事务锁状态不确定；为避免覆盖外部修改，未执行自动回滚；恢复快照已保留：${snapshot_dir}"
            return 2
        fi
        if [ "$activation_status" -eq 0 ]; then
            change_argo_transition_subscription fixed "$new_domain" \
                "$preferred_host" "$preferred_port" 1 || subscription_status=$?
            subscription_rollback_file="${ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE:-}"
            if [ "$subscription_status" -eq 0 ]; then
                if [ -n "$subscription_rollback_file" ] && \
                   ! rm -f -- "$subscription_rollback_file"; then
                    yellow "Argo 固定 Tunnel 已成功切换，但订阅回滚凭据未能清理：${subscription_rollback_file}"
                    return 3
                fi
                ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE=''
                ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION=''
                ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION=''
                if ! rm -rf -- "$snapshot_dir"; then
                    yellow "Argo 固定 Tunnel 已成功切换，但旧快照未能清理，请手动删除：${snapshot_dir}"
                    return 3
                fi
                return 0
            fi
            [ "$subscription_status" -eq 1 ] || rollback_ok=0
        fi
    fi

    restore_argo_transition_snapshot "$snapshot_dir" "$init_system" || rollback_ok=0
    ARGO_DOMAIN="$old_argo_domain"
    ARGO_AUTH="$old_argo_auth"
    ARGO_FIXED_READY="$old_fixed_ready"
    ArgoDomain="$old_runtime_domain"
    restart_argo >/dev/null 2>&1 || rollback_ok=0
    if [ "$rollback_ok" -eq 1 ]; then
        rm -rf -- "$snapshot_dir" || {
            red "Argo 模式切换失败；运行状态已恢复，但临时快照无法清理：${snapshot_dir}"
            return 2
        }
        return 1
    fi
    if [ -n "$subscription_rollback_file" ]; then
        red "Argo 模式切换失败且自动回滚不完整；恢复快照已保留：${snapshot_dir}；订阅回滚凭据已保留：${subscription_rollback_file}"
    else
        red "Argo 模式切换失败且自动回滚不完整；恢复快照已保留：${snapshot_dir}"
    fi
    return 2
}

transition_to_quick_argo() {
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "Argo 临时 Tunnel 切换"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _transition_to_quick_argo_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
}

transition_to_fixed_argo() {
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "Argo 固定 Tunnel 切换"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _transition_to_fixed_argo_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
}

change_cfip() {
    local detected_mode address_mode
    clear
    yellow "修改vless-ws-tls-argo优选域名\n"
    green "1: cf.090227.xyz  2: cf.877774.xyz  3: cf.877771.xyz  4: cdns.doon.eu.org  5: cf.zhetengsha.eu.org  6: time.is\n"
    reading "请输入你的优选域名或优选IP\n(请输入1至6选项,可输入域名:端口 或 IP:端口,直接回车默认使用1): " cfip_input

    read -r cfip cfport < <(parse_cfip_endpoint "$cfip_input") || {
        red "优选域名/IP 或端口格式无效。IPv6 请使用 [IPv6]:端口，省略端口时默认 443。"
        return 1
    }
    detected_mode=$(detect_argo_tunnel_mode 2>/dev/null) || {
        red "无法识别当前 Argo Tunnel 类型，未修改优选入口。"
        return 1
    }
    case "$detected_mode" in
        quick) address_mode=quick ;;
        local|remote) address_mode=fixed ;;
        *) return 1 ;;
    esac

    mutate_base_subscription update_cfip_subscription_file \
        "$cfip" "$cfport" "$address_mode" || {
        red "未找到可安全更新的 Argo 节点，原订阅保持不变。"
        return 1
    }
    green "\nvless-ws-tls-argo节点优选域名已更新为：${purple}${cfip}:${cfport}${re}\n"
    grep 'path=%2Fvless-argo' "$client_dir" | while IFS= read -r line; do purple "$line\n"; done
}

update_cfip_subscription_file() {
    local staged_base_file="$1"
    local cfip="$2"
    local cfport="$3"
    local address_mode="$4"

    update_argo_preferred_address_file "$staged_base_file" \
        "$cfip" "$cfport" "$address_mode"
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

fail_warp_generation_after_registration() {
    local response_file="$1" register_dir="$2"
    chmod 700 "$register_dir" 2>/dev/null || true
    [ ! -e "$response_file" ] || chmod 600 "$response_file" 2>/dev/null || true
    if delete_warp_registration "$response_file"; then
        if rm -rf -- "$register_dir"; then
            return 1
        fi
        red "WARP 云端设备已清理，但本地注册临时目录删除失败。"
    else
        red "WARP 云端设备清理失败，已停止后续注册尝试。"
    fi
    red "注册恢复凭据保留在: ${register_dir}"
    return 2
}

install_warp_identity_file() {
    local source_file="$1" target_file="$2"
    if command_exists install; then
        install -m 600 "$source_file" "$target_file"
    else
        cp "$source_file" "$target_file" && chmod 600 "$target_file"
    fi
}

move_warp_identity_file() {
    mv -f "$1" "$2"
}

remove_warp_identity_file() {
    rm -f -- "$1"
}

remove_warp_identity_transaction() {
    rm -rf -- "$1"
}

commit_warp_identity_pair() {
    local endpoint_source="$1" account_source="$2" state_dir="$3"
    local endpoint_target="${state_dir}/endpoint.json" account_target="${state_dir}/account.json"
    local transaction_dir rollback_ok=true

    transaction_dir=$(mktemp -d "${state_dir}/.identity-commit.XXXXXX") || return 1
    chmod 700 "$transaction_dir"
    if ! install_warp_identity_file "$endpoint_source" "$transaction_dir/new-endpoint.json" || \
       ! install_warp_identity_file "$account_source" "$transaction_dir/new-account.json"; then
        remove_warp_identity_transaction "$transaction_dir" || \
          yellow "WARP 身份暂存目录清理失败，已保留: ${transaction_dir}"
        return 1
    fi
    if [ -e "$endpoint_target" ]; then
        install_warp_identity_file "$endpoint_target" "$transaction_dir/old-endpoint.json" || {
            remove_warp_identity_transaction "$transaction_dir" || true
            return 1
        }
        : > "$transaction_dir/had-endpoint"
    fi
    if [ -e "$account_target" ]; then
        install_warp_identity_file "$account_target" "$transaction_dir/old-account.json" || {
            remove_warp_identity_transaction "$transaction_dir" || true
            return 1
        }
        : > "$transaction_dir/had-account"
    fi

    if move_warp_identity_file "$transaction_dir/new-endpoint.json" "$endpoint_target" && \
       move_warp_identity_file "$transaction_dir/new-account.json" "$account_target"; then
        if remove_warp_identity_transaction "$transaction_dir"; then
            return 0
        fi
        red "WARP 身份已成对提交，但事务目录清理失败。"
        red "事务恢复材料保留在: ${transaction_dir}"
        return 2
    fi

    if [ -e "$transaction_dir/had-endpoint" ]; then
        install_warp_identity_file "$transaction_dir/old-endpoint.json" "$transaction_dir/restore-endpoint.json" && \
          move_warp_identity_file "$transaction_dir/restore-endpoint.json" "$endpoint_target" || rollback_ok=false
    else
        remove_warp_identity_file "$endpoint_target" || rollback_ok=false
    fi
    if [ -e "$transaction_dir/had-account" ]; then
        install_warp_identity_file "$transaction_dir/old-account.json" "$transaction_dir/restore-account.json" && \
          move_warp_identity_file "$transaction_dir/restore-account.json" "$account_target" || rollback_ok=false
    else
        remove_warp_identity_file "$account_target" || rollback_ok=false
    fi
    if [ "$rollback_ok" = true ]; then
        remove_warp_identity_transaction "$transaction_dir" || \
          yellow "WARP 身份回滚完成，但事务目录清理失败，已保留: ${transaction_dir}"
        return 1
    fi
    red "WARP 身份成对提交失败，且旧身份恢复不完整。"
    red "事务恢复材料保留在: ${transaction_dir}"
    return 2
}

# 为当前 VPS 生成独立密钥并直接向 Cloudflare WARP API 注册。
# 私钥始终在本机生成；账户令牌和 endpoint 仅以 600 权限保存在本机。
# 返回 1 表示没有遗留云端注册，可由调用者重试；返回 2 表示注册状态不确定
# 或清理失败，恢复材料已尽可能保留，调用者必须停止重试。
warp_underlay_family() {
    if ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
        printf '4\n'
    elif ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
        printf '6\n'
    else
        printf '4\n'
    fi
}

warp_bootstrap_ip_valid() {
    local ip="${1:-}"
    if is_valid_ipv4_address "$ip"; then
        case "$ip" in 0.*|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;; esac
        [ "${ip%%.*}" -lt 224 ]
    else
        is_valid_ipv6_address "$ip" && [[ "$ip" == [23]*:* ]]
    fi
}

warp_forget_bootstrap_ip() {
    case "${1:-}" in api.cloudflareclient.com|engage.cloudflareclient.com) ;; *) return 1 ;; esac
    local dir="${conf_dir}/warp/dns-cache"
    [ ! -L "${conf_dir}/warp" ] && [ ! -L "$dir" ] || return 1
    rm -f -- "$dir/$1.json"
}

warp_resolve_bootstrap_ip() {
    local host="${1:-}" fresh_doh="${2:-false}" dir="${conf_dir}/warp/dns-cache" cache now ip='' expires ttl=30
    local native provider resolver bootstrap url payload answers value record_ttl tmp family query_type query_number
    case "$host" in api.cloudflareclient.com|engage.cloudflareclient.com) ;; *) return 1 ;; esac
    cache="$dir/$host.json"
    family=$(warp_underlay_family)
    case "$family" in 6) query_type=AAAA; query_number=28 ;; *) query_type=A; query_number=1 ;; esac
    [ ! -L "${conf_dir}/warp" ] && [ ! -L "$dir" ] && [ ! -L "$cache" ] || return 1
    mkdir -p "$dir" && chmod 700 "$dir" || return 1
    now=$(date +%s) || return 1
    if [ "$fresh_doh" != true ] && [ -f "$cache" ]; then
        IFS=$'\t' read -r ip expires < <(jq -r --arg host "$host" \
            'select(.host==$host) | [.ip,.expires] | @tsv' "$cache" 2>/dev/null) || true
        if [[ "$expires" =~ ^[0-9]{1,11}$ ]] && [ "$expires" -gt "$now" ] && \
           [ "$expires" -le "$((now+60))" ] && warp_bootstrap_ip_valid "$ip" && \
           is_valid_ipv"${family}"_address "$ip"; then
            printf '%s\n' "$ip"; return 0
        fi
        rm -f -- "$cache" || return 1
    fi
    ip=''
    native=''
    if [ "$fresh_doh" != true ]; then native=$(timeout 3 getent ahosts "$host" 2>/dev/null || true); fi
    while read -r value _; do
        is_valid_ipv"${family}"_address "$value" || continue
        if warp_bootstrap_ip_valid "$value"; then ip="$value"; break; fi
    done <<< "$native"
    if [ -z "$ip" ]; then
        for provider in cloudflare google; do
            if [ "$provider" = cloudflare ]; then
                resolver=cloudflare-dns.com; bootstrap='1.1.1.1,[2606:4700:4700::1111]'; url=https://cloudflare-dns.com/dns-query
            else
                resolver=dns.google; bootstrap='8.8.8.8,[2001:4860:4860::8888]'; url=https://dns.google/resolve
            fi
            payload=$(curl -q --noproxy '*' --proto '=https' --retry 0 -fsS \
                --connect-timeout 2 --max-time 4 --max-filesize 16384 \
                --resolve "${resolver}:443:${bootstrap}" --get --data-urlencode "name=$host" \
                --data-urlencode "type=$query_type" -H 'accept: application/dns-json' "$url" 2>/dev/null || true)
            answers=$(jq -r --arg host "$host" --argjson type "$query_number" '
                select(.Status==0 and any(.Question[]?; (.name|ascii_downcase|rtrimstr("."))==$host and .type==$type)) |
                .Answer[]? | select(.type==$type and (.TTL|type)=="number" and .TTL>=0) | [.data,.TTL] | @tsv
                ' <<< "$payload" 2>/dev/null || true)
            while IFS=$'\t' read -r value record_ttl; do
                is_valid_ipv"${family}"_address "$value" || continue
                if warp_bootstrap_ip_valid "$value" && [[ "$record_ttl" =~ ^[0-9]{1,9}$ ]]; then
                    ip="$value"; ttl="$record_ttl"; break
                fi
            done <<< "$answers"
            [ -z "$ip" ] || break
        done
    fi
    [ -n "$ip" ] || return 1
    [ "$ttl" -le 60 ] || ttl=60
    if [ "$ttl" -gt 0 ]; then
        tmp=$(mktemp "$dir/.dns.XXXXXX") || return 1
        if ! jq -n --arg host "$host" --arg ip "$ip" --argjson expires "$((now+ttl))" \
            '{host:$host,ip:$ip,expires:$expires}' > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$cache"; then
            rm -f -- "$tmp"; return 1
        fi
    fi
    printf '%s\n' "$ip"
}

# 0=HTTP 200; 1=explicit rejection; 2=outcome unknown (retain recovery);
# 4=confirmed pre-request network failure (clean local files and stop the action).
warp_registration_post() {
    local request="$1" response="$2" attempt ip meta rc http sent uploaded extra
    for attempt in 1 2; do
        ip=$(warp_resolve_bootstrap_ip api.cloudflareclient.com "$([ "$attempt" -eq 2 ] && echo true || echo false)") || return 4
        [[ "$ip" != *:* ]] || ip="[$ip]"
        : > "$response" || return 2
        chmod 600 "$response" || return 2
        rc=0
        meta=$(curl -q --noproxy '*' --proto '=https' --retry 0 -sS \
            --connect-timeout 10 --max-time 45 --resolve "api.cloudflareclient.com:443:$ip" \
            -o "$response" -w $'%{http_code}\t%{size_request}\t%{size_upload}' \
            --request POST 'https://api.cloudflareclient.com/v0a2158/reg' \
            --header 'User-Agent: okhttp/3.12.1' --header 'CF-Client-Version: a-6.10-2158' \
            --header 'Content-Type: application/json' --data-binary "@$request") || rc=$?
        IFS=$'\t' read -r http sent uploaded extra <<< "$meta"
        if [ "$rc" -eq 0 ] && [ "$http" = 200 ]; then return 0; fi
        if [ "$rc" -eq 0 ] && [[ "$http" =~ ^(400|401|403|404|405|422|429)$ ]] && \
           ! jq -e 'has("id") or has("token")' "$response" >/dev/null 2>&1; then
            return 1
        fi
        # No redirects, proxy, curlrc or automatic retries can hide an earlier POST.
        if [[ "$rc" =~ ^(6|7)$ ]] && [ "$http" = 000 ] && [ "$sent" = 0 ] && \
           [[ "$uploaded" =~ ^0([.]0+)?$ ]] && [ -z "$extra" ] && [ ! -s "$response" ]; then
            warp_forget_bootstrap_ip api.cloudflareclient.com || return 4
            [ "$attempt" -lt 2 ] || return 4
            sleep 1
        else
            return 2
        fi
    done
    return 4
}

generate_unique_warp_identity() {
    local state_dir="${1:-${conf_dir}/warp}"
    local register_dir response_file request_file endpoint_file account_file
    local singbox_bin keypair private_key public_key random_hex install_id fcm_token tos
    local request_rc client_id reserved_bytes r1 r2 r3 extra
    local v4 v6 peer_key failure_rc commit_rc

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

    if warp_registration_post "$request_file" "$response_file"; then request_rc=0; else request_rc=$?; fi
    if [ "$request_rc" -eq 2 ]; then
        [ ! -e "$response_file" ] || chmod 600 "$response_file" 2>/dev/null || true
        red "Cloudflare WARP 注册请求结果不确定，已停止后续注册尝试。"
        red "注册恢复材料保留在: ${register_dir}"
        return 2
    fi
    [ ! -e "$response_file" ] || chmod 600 "$response_file" 2>/dev/null || true
    if [ "$request_rc" -eq 4 ]; then
        rm -rf -- "$register_dir" || return 2
        red "WARP 注册前的 DNS/连接不可用，本轮已停止；未发送的请求不会被误记为未知注册。"
        return 4
    fi
    if [ "$request_rc" -ne 0 ]; then
        rm -rf -- "$register_dir" || return 2
        red "Cloudflare WARP 注册失败，现有配置未修改。"
        return 1
    fi
    if jq -e '
      .id and .token and .config.client_id and
      .config.interface.addresses.v4 and .config.interface.addresses.v6 and
      .config.peers[0].public_key
    ' "$response_file" >/dev/null 2>&1; then
        :
    elif jq -e '.id and .token' "$response_file" >/dev/null 2>&1; then
        if fail_warp_generation_after_registration "$response_file" "$register_dir"; then
            failure_rc=0
        else
            failure_rc=$?
        fi
        return "$failure_rc"
    else
        red "Cloudflare WARP 注册响应不完整，注册状态不确定，已停止后续注册尝试。"
        red "注册恢复材料保留在: ${register_dir}"
        return 2
    fi

    client_id=$(jq -r '.config.client_id' "$response_file")
    read -r r1 r2 r3 extra < <(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1)
    if [ -z "${r1:-}" ] || [ -z "${r2:-}" ] || [ -z "${r3:-}" ] || [ -n "${extra:-}" ]; then
        red "Cloudflare WARP client_id 无效，现有配置未修改。"
        if fail_warp_generation_after_registration "$response_file" "$register_dir"; then failure_rc=0; else failure_rc=$?; fi
        return "$failure_rc"
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
        domain_resolver:{server:"local",strategy:"prefer_ipv4"},
        peers:[{
          address:"engage.cloudflareclient.com", port:2408,
          public_key:$peer, allowed_ips:["0.0.0.0/0","::/0"],
          persistent_keepalive_interval:25, reserved:$reserved
        }]
      }
      ' > "$endpoint_file" || {
        if fail_warp_generation_after_registration "$response_file" "$register_dir"; then failure_rc=0; else failure_rc=$?; fi
        return "$failure_rc"
      }
    jq --arg private "$private_key" --argjson reserved "$reserved_bytes" \
      '. + {private_key:$private,reserved:$reserved}' "$response_file" > "$account_file" || {
        if fail_warp_generation_after_registration "$response_file" "$register_dir"; then failure_rc=0; else failure_rc=$?; fi
        return "$failure_rc"
      }
    chmod 600 "$response_file" "$endpoint_file" "$account_file"

    local generated_endpoint
    generated_endpoint=$(extract_warp_endpoint "$endpoint_file")
    if ! warp_endpoint_is_valid "$generated_endpoint" || warp_endpoint_is_legacy "$generated_endpoint"; then
        red "生成的 WARP endpoint 校验失败，现有配置未修改。"
        if fail_warp_generation_after_registration "$response_file" "$register_dir"; then failure_rc=0; else failure_rc=$?; fi
        return "$failure_rc"
    fi

    if commit_warp_identity_pair "$endpoint_file" "$account_file" "$state_dir"; then commit_rc=0; else commit_rc=$?; fi
    if [ "$commit_rc" -eq 1 ]; then
        if fail_warp_generation_after_registration "$response_file" "$register_dir"; then failure_rc=0; else failure_rc=$?; fi
        return "$failure_rc"
    fi
    if [ "$commit_rc" -eq 2 ]; then
        red "WARP 身份提交或恢复未完整完成，已停止后续注册尝试。"
        red "注册恢复材料保留在: ${register_dir}"
        return 2
    fi
    rm -rf -- "$register_dir" || {
        red "WARP 身份已生成，但注册临时目录清理失败: ${register_dir}"
        return 2
    }
    green "已为本机生成独立 WARP 身份。"
}

delete_warp_registration() {
    local account_file="$1" device_id device_token ip http
    [ -s "$account_file" ] || return 0
    device_id=$(jq -r '.id // empty' "$account_file" 2>/dev/null)
    device_token=$(jq -r '.token // empty' "$account_file" 2>/dev/null)
    [ -n "$device_id" ] && [ -n "$device_token" ] || return 0
    ip=$(warp_resolve_bootstrap_ip api.cloudflareclient.com) || return 1
    [[ "$ip" != *:* ]] || ip="[$ip]"
    http=$(curl -q --noproxy '*' --proto '=https' --retry 0 -fsS --connect-timeout 5 --max-time 15 \
      --resolve "api.cloudflareclient.com:443:$ip" -o /dev/null -w '%{http_code}' -X DELETE \
      "https://api.cloudflareclient.com/v0a2158/reg/${device_id}" \
      -H "Authorization: Bearer ${device_token}" \
      -H 'User-Agent: okhttp/3.12.1' 2>/dev/null) || return 1
    [[ "$http" == 200 || "$http" == 204 ]]
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
    unset WARP_PROBE_PID WARP_PROBE_DIR WARP_PROBE_PROXY WARP_PROBE_PORT WARP_PROBE_FAMILY WARP_PROBE_BINARY
}

render_warp_probe_config() {
    local endpoint="$1" port="$2" family="$3" mode="${4:-local}" strategy cf_dns=1.1.1.1 google_dns=8.8.8.8
    case "$family" in 4) strategy=ipv4_only ;; 6) strategy=ipv6_only ;; *) return 1 ;; esac
    case "$mode" in local|cloudflare|google) ;; *) return 1 ;; esac
    if [ "$(warp_underlay_family)" = 6 ]; then
        cf_dns=2606:4700:4700::1111; google_dns=2001:4860:4860::8888
    fi
    jq -n --argjson endpoint "$endpoint" --argjson port "$port" --arg strategy "$strategy" --arg mode "$mode" \
        --arg cf_dns "$cf_dns" --arg google_dns "$google_dns" '
        {log:{level:"error"},
         dns:{servers:[{tag:"local",type:"local"},
             {tag:"cloudflare",type:"https",server:$cf_dns,tls:{enabled:true,server_name:"cloudflare-dns.com"}},
             {tag:"google",type:"https",server:$google_dns,tls:{enabled:true,server_name:"dns.google"}}],
             strategy:$strategy,final:$mode},
         inbounds:[{type:"mixed",tag:"warp-probe",listen:"127.0.0.1",listen_port:$port}],
         endpoints:[$endpoint],route:{final:"wireguard-out"}}
    '
}

# Switch DNS only inside our temporary proxy, keeping the same identity and port.
warp_probe_dns_fallback() {
    local mode binary="${WARP_PROBE_BINARY:-${work_dir}/${server_name}}" tmp
    case "${WARP_PROBE_DIR:-}" in "${conf_dir}/warp/.probe."*) ;; *) return 1 ;; esac
    [ -f "$WARP_PROBE_DIR/config.json" ] && [ -r "/proc/${WARP_PROBE_PID:-}/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$WARP_PROBE_PID/cmdline" | grep -Fq "$WARP_PROBE_DIR/config.json" || return 1
    mode=$(jq -r '.dns.final // "local"' "$WARP_PROBE_DIR/config.json") || return 1
    case "$mode" in local) mode=cloudflare ;; cloudflare) mode=google ;; *) return 1 ;; esac
    tmp=$(mktemp "$WARP_PROBE_DIR/.dns.XXXXXX") || return 1
    jq --arg mode "$mode" '.dns.final=$mode' "$WARP_PROBE_DIR/config.json" > "$tmp" && \
        "$binary" check -c "$tmp" >/dev/null 2>&1 || { rm -f -- "$tmp"; return 1; }
    kill "$WARP_PROBE_PID" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    local stop_attempt
    for stop_attempt in {1..10}; do
        kill -0 "$WARP_PROBE_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$WARP_PROBE_PID" 2>/dev/null && kill -9 "$WARP_PROBE_PID" 2>/dev/null || true
    wait "$WARP_PROBE_PID" 2>/dev/null || true
    mv -f -- "$tmp" "$WARP_PROBE_DIR/config.json" || return 1
    "$binary" run -c "$WARP_PROBE_DIR/config.json" >> "$WARP_PROBE_DIR/sing-box.log" 2>&1 &
    WARP_PROBE_PID=$!
    sleep 1
    kill -0 "$WARP_PROBE_PID" 2>/dev/null
}

start_warp_candidate_proxy() {
    local endpoint_json="$1" family="${2:-4}" singbox_bin port attempt peer_host peer_ip
    case "$family" in
      4|6) ;;
      *) return 1 ;;
    esac
    warp_endpoint_is_valid "$endpoint_json" || return 1
    endpoint_json=$(jq -c '
      .domain_resolver = {server:"local",strategy:"prefer_ipv4"}
    ' <<< "$endpoint_json") || return 1
    # Bootstrap the WireGuard peer before starting it. The cached address is only
    # installed in this short-lived config, never pinned into the saved identity.
    peer_host=$(jq -r '.peers[0].address // empty' <<< "$endpoint_json")
    if [ "$peer_host" = engage.cloudflareclient.com ]; then
        peer_ip=$(warp_resolve_bootstrap_ip "$peer_host") || return 1
        endpoint_json=$(jq -c --arg ip "$peer_ip" '.peers[0].address=$ip' <<< "$endpoint_json") || return 1
    fi
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
    render_warp_probe_config "$endpoint_json" "$WARP_PROBE_PORT" "$family" \
        > "${WARP_PROBE_DIR}/config.json" || { stop_warp_candidate_proxy; return 1; }
    chmod 600 "${WARP_PROBE_DIR}/config.json"
    singbox_bin="${work_dir}/${server_name}"
    [ -x "$singbox_bin" ] || singbox_bin=$(command -v sing-box 2>/dev/null || true)
    [ -x "$singbox_bin" ] || { stop_warp_candidate_proxy; return 1; }
    WARP_PROBE_BINARY="$singbox_bin"
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
    WARP_PROBE_FAMILY="$family"
}

probe_warp_trace() {
    local proxy="$1" trace attempt deadline remaining request_timeout
    WARP_PROBE_IP=''; WARP_PROBE_LOC=''; WARP_PROBE_COLO=''; WARP_PROBE_STATE=''
    # A listening SOCKS port does not mean the WireGuard handshake is ready.
    # Give cold handshakes a 30-second window, even when SOCKS rejects requests
    # immediately. A definitive trace is final; transport retries stay bounded.
    deadline=$(( $(date +%s) + 30 ))
    for attempt in {1..16}; do
        remaining=$(( deadline - $(date +%s) ))
        [ "$remaining" -gt 0 ] || return 1
        request_timeout=$remaining
        [ "$request_timeout" -le 12 ] || request_timeout=12
        if trace=$(curl -fsS --connect-timeout 5 --max-time "$request_timeout" --proxy "$proxy" \
          https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null); then
            break
        fi
        # At most two DNS profile changes; both reconnect the same saved identity.
        if [ -n "${WARP_PROBE_DIR:-}" ] && [ "$attempt" -le 2 ] && \
           [ "$((deadline-$(date +%s)))" -gt 3 ]; then
            warp_probe_dns_fallback || true
        fi
        [ "$attempt" -lt 16 ] || return 1
        remaining=$(( deadline - $(date +%s) ))
        [ "$remaining" -gt 2 ] || return 1
        sleep 2
    done
    WARP_PROBE_IP=$(awk -F= '/^ip=/{print $2; exit}' <<< "$trace")
    WARP_PROBE_LOC=$(awk -F= '/^loc=/{print $2; exit}' <<< "$trace")
    WARP_PROBE_COLO=$(awk -F= '/^colo=/{print $2; exit}' <<< "$trace")
    WARP_PROBE_STATE=$(awk -F= '/^warp=/{print $2; exit}' <<< "$trace")
    [ -n "$WARP_PROBE_IP" ] && [[ "$WARP_PROBE_STATE" =~ ^(on|plus)$ ]] || return 1
    case "${WARP_PROBE_FAMILY:-}" in
        4) is_valid_ipv4_address "$WARP_PROBE_IP" || return 1 ;;
        6) is_valid_ipv6_address "$WARP_PROBE_IP" || return 1 ;;
    esac
    return 0
}

get_warp_preferred_family() {
    local family_file="${conf_dir}/warp/preferred-family" family=''

    if [ -r "$family_file" ]; then
        IFS= read -r family < "$family_file" || true
    fi
    case "$family" in
      6) printf '%s\n' 6 ;;
      *) printf '%s\n' 4 ;;
    esac
}

write_warp_preferred_family() {
    local family="${1:-}" state_dir="${conf_dir}/warp" family_file family_tmp

    case "$family" in 4|6) ;; *) return 1 ;; esac
    mkdir -p "$state_dir" && chmod 700 "$state_dir" || return 1
    family_file="${state_dir}/preferred-family"
    family_tmp=$(mktemp "${state_dir}/.preferred-family.XXXXXX") || return 1
    if ! printf '%s\n' "$family" > "$family_tmp" || ! chmod 600 "$family_tmp" || \
       ! mv -f "$family_tmp" "$family_file"; then
        rm -f -- "$family_tmp"
        return 1
    fi
}

# 为 WARP 分流规则生成一个可重复渲染的 DNS 地址族偏好。
# IPv6 模式只影响明确指向 wireguard-out 的规则集；IPv4 模式移除该托管规则。
render_warp_route_family() {
    local source_file="${1:-}" output_file="${2:-}" family="${3:-}"

    [ -s "$source_file" ] && [ -n "$output_file" ] || return 1
    case "$family" in 4|6) ;; *) return 1 ;; esac
    jq --argjson family "$family" '
      def managed_warp_resolve:
        (.action? == "resolve") and
        (.strategy? == "prefer_ipv6") and
        (.network? == ["tcp", "udp"]) and
        (((keys | sort) == ["action", "network", "rule_set", "strategy"]) or
         ((keys | sort) == ["action", "network", "strategy"]));
      def warp_route:
        (.action? == "route") and (.outbound? == "wireguard-out");
      .route = (if (.route | type) == "object" then .route else {} end) |
      (.route.rules | if type == "array" then . else [] end) as $rules |
      ([$rules[] | select(managed_warp_resolve | not)]) as $clean |
      ([$clean[] | select(.action? == "sniff")]) as $sniff |
      ([$clean[] | select(.action? != "sniff")]) as $rest |
      (reduce ($rest[] | select(warp_route and ((.rule_set? | type) == "array")) | .rule_set[]) as $tag
        ([]; if index($tag) then . else . + [$tag] end)) as $warp_tags |
      ($rest | map(warp_route) | index(true)) as $first_warp |
      if $family == 6 and ($warp_tags | length) > 0 and $first_warp != null then
        .route.rules =
          ($sniff + $rest[0:$first_warp] +
           [{rule_set:$warp_tags,network:["tcp","udp"],action:"resolve",strategy:"prefer_ipv6"}] +
           $rest[$first_warp:])
      elif $family == 6 and (.route.final? == "wireguard-out") then
        .route.rules =
          ($sniff + [{network:["tcp","udp"],action:"resolve",strategy:"prefer_ipv6"}] + $rest)
      else
        .route.rules = ($sniff + $rest)
      end
    ' "$source_file" > "$output_file"
}

warp_platform_curl() {
    local rc=0
    curl "$@" || rc=$?
    case "$rc" in
        5|6|7|28|35|52|55|56|97)
            case "${WARP_PROBE_DIR:-}" in
                "${conf_dir:-}/warp/.probe."*)
                    [ ! -d "$WARP_PROBE_DIR" ] || : > "$WARP_PROBE_DIR/transport-failure"
                    ;;
            esac
            ;;
    esac
    return "$rc"
}

check_unlock_netflix() {
    local proxy="$1" title body parsed_region region='' successful=0 playable=false
    for title in 81280792 70143836; do
        if body=$(warp_platform_curl -fsSL --connect-timeout 5 --max-time 12 --proxy "$proxy" \
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
    assertion=$(warp_platform_curl -fsS --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -X POST https://disney.api.edge.bamgrid.com/devices \
      -H 'authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84' \
      -H 'content-type: application/json; charset=UTF-8' \
      -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>/dev/null || true)
    assertion=$(jq -r '.assertion // empty' <<< "$assertion" 2>/dev/null)
    [ -n "$assertion" ] || { WARP_UNLOCK_STATUS='检测失败'; return 2; }
    token_content=$(warp_platform_curl -fsS --connect-timeout 5 --max-time 12 --proxy "$proxy" \
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
    graph_result=$(warp_platform_curl -fsSL --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -X POST https://disney.api.edge.bamgrid.com/graph/v1/device/graphql \
      -H 'authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84' \
      -H 'content-type: application/json' -d "$graph_payload" 2>/dev/null || true)
    region=$(sed -n 's/.*"countryCode":[ ]*"\([^"]*\)".*/\1/p' <<< "$graph_result" | head -1)
    supported=$(sed -n 's/.*"inSupportedLocation":[ ]*\([^,}]*\).*/\1/p' <<< "$graph_result" | head -1)
    [ -n "$region" ] || { WARP_UNLOCK_STATUS='检测失败'; return 2; }
    effective=$(warp_platform_curl -fsSL -o /dev/null -w '%{url_effective}' --connect-timeout 5 --max-time 12 \
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
    web_meta=$(warp_platform_curl -sSIL -L --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -o /dev/null -w $'%{http_code}\t%{url_effective}' \
      https://chatgpt.com 2>/dev/null) || web_meta=''
    IFS=$'\t' read -r web_code web_url <<< "$web_meta"
    ios_file=$(mktemp) || { WARP_UNLOCK_STATUS='检测失败'; return 2; }
    if ! ios_meta=$(warp_platform_curl -sSL --connect-timeout 5 --max-time 12 --proxy "$proxy" \
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
    web_url=${web_url,,}
    [[ "$web_code" =~ ^2[0-9][0-9]$ ]] && \
      [[ "$web_url" =~ ^https://([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*chatgpt\.com(:443)?([/?#]|$) ]] && \
      [[ "$ios_code" =~ ^[234][0-9][0-9]$ ]] || {
        WARP_UNLOCK_STATUS='检测失败'; return 2
    }
    WARP_UNLOCK_STATUS='解锁'; return 0
}

extract_html_visible_text() {
    local input="$1"
    awk '
      function find_tag_end(s, start, n, i, c, quote) {
          n=length(s)
          quote=""
          for (i=start + 1; i<=n; i++) {
              c=substr(s, i, 1)
              if (quote != "") {
                  if (c == quote) quote=""
              } else if (c == "\"" || c == apostrophe) {
                  quote=c
              } else if (c == ">") {
                  return i
              }
          }
          return 0
      }

      function has_hidden_attr(tag, pos, n, i, c, start, name, quote) {
          n=length(tag)
          i=pos
          while (i <= n) {
              while (i <= n && substr(tag, i, 1) ~ /[[:space:]\/]/) i++
              if (i > n) break
              start=i
              while (i <= n && substr(tag, i, 1) !~ /[[:space:]=\/]/) i++
              name=tolower(substr(tag, start, i - start))
              if (name == "hidden") return 1
              while (i <= n && substr(tag, i, 1) ~ /[[:space:]]/) i++
              if (substr(tag, i, 1) != "=") continue
              i++
              while (i <= n && substr(tag, i, 1) ~ /[[:space:]]/) i++
              c=substr(tag, i, 1)
              if (c == "\"" || c == apostrophe) {
                  quote=c
                  i++
                  while (i <= n && substr(tag, i, 1) != quote) i++
                  if (i <= n) i++
              } else {
                  while (i <= n && substr(tag, i, 1) !~ /[[:space:]]/) i++
              }
          }
          return 0
      }

      function is_void_tag(name) {
          return name ~ /^(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/
      }

      function pop_from_depth(match_depth, j) {
          for (j=depth; j>=match_depth; j--) {
              if (hidden_stack[j]) hidden_count--
              tag_stack[j]=""
              hidden_stack[j]=0
          }
          depth=match_depth - 1
      }

      function pop_to_tag(name, match_depth, j) {
          match_depth=0
          for (j=depth; j>=1; j--) {
              if (tag_stack[j] == name) {
                  match_depth=j
                  break
              }
          }
          if (match_depth) pop_from_depth(match_depth)
      }

      function is_scope_boundary(name, scope) {
          if (scope == "table") return name ~ /^(html|table|template)$/
          if (name ~ /^(applet|caption|html|marquee|object|table|td|template|th)$/) return 1
          if (scope == "list" && name ~ /^(menu|ol|ul)$/) return 1
          if (scope == "button" && name == "button") return 1
          return 0
      }

      function pop_to_tag_in_scope(name, scope, j, open_name) {
          for (j=depth; j>=1; j--) {
              open_name=tag_stack[j]
              if (open_name == name) {
                  pop_from_depth(j)
                  return 1
              }
              if (is_scope_boundary(open_name, scope)) return 0
          }
          return 0
      }

      function pop_either_tag_in_scope(first, second, scope, j, open_name) {
          for (j=depth; j>=1; j--) {
              open_name=tag_stack[j]
              if (open_name == first || open_name == second) {
                  pop_from_depth(j)
                  return 1
              }
              if (is_scope_boundary(open_name, scope)) return 0
          }
          return 0
      }

      function closes_p_on_start(name) {
          return name ~ /^(address|article|aside|blockquote|center|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hgroup|hr|li|listing|main|menu|nav|ol|p|plaintext|pre|search|section|summary|table|ul|xmp)$/
      }

      function apply_implicit_start_rules(name) {
          if (name ~ /^h[1-6]$/ && depth && tag_stack[depth] ~ /^h[1-6]$/) pop_from_depth(depth)
          if (name == "dd" || name == "dt") pop_either_tag_in_scope("dd", "dt", "")
          if (name == "td" || name == "th") pop_either_tag_in_scope("td", "th", "table")
          if (name == "li") pop_to_tag_in_scope("li", "list")
          if (name == "button") pop_to_tag_in_scope("button", "")
          if (closes_p_on_start(name)) pop_to_tag_in_scope("p", "button")
      }

      function visible_html(s, n, pos, rel, start, tag_end, raw, token, closing, name_len, name, self_closing, hide, lower_tail, close_rel) {
          n=length(s)
          pos=1
          while (pos <= n) {
              rel=index(substr(s, pos), "<")
              if (!rel) {
                  if (!hidden_count) output=output substr(s, pos)
                  break
              }
              start=pos + rel - 1
              if (!hidden_count) output=output substr(s, pos, start - pos)

              if (substr(s, start, 4) == "<!--") {
                  close_rel=index(substr(s, start + 4), "-->")
                  if (!close_rel) break
                  if (!hidden_count) output=output " "
                  pos=start + close_rel + 6
                  continue
              }

              tag_end=find_tag_end(s, start)
              if (!tag_end) break
              raw=substr(s, start + 1, tag_end - start - 1)
              token=raw
              sub(/^[[:space:]]+/, "", token)
              closing=(substr(token, 1, 1) == "/")
              if (closing) sub(/^\/[[:space:]]*/, "", token)
              if (!match(token, /^[[:alnum:]_:-]+/)) {
                  if (!hidden_count) output=output " "
                  pos=tag_end + 1
                  continue
              }
              name_len=RLENGTH
              name=tolower(substr(token, 1, name_len))

              if (!closing && (name == "plaintext" || name == "xmp")) {
                  apply_implicit_start_rules(name)
                  if (!hidden_count) output=output " "
                  hide=has_hidden_attr(token, name_len + 1)
                  depth++
                  tag_stack[depth]=name
                  hidden_stack[depth]=hide
                  if (hide) hidden_count++

                  if (name == "plaintext") {
                      if (!hidden_count) output=output substr(s, tag_end + 1)
                      break
                  }

                  lower_tail=tolower(substr(s, tag_end + 1))
                  if (!match(lower_tail, "</xmp[[:space:]]*>")) {
                      if (!hidden_count) output=output substr(s, tag_end + 1)
                      break
                  }
                  if (!hidden_count) output=output substr(s, tag_end + 1, RSTART - 1)
                  pop_from_depth(depth)
                  if (!hidden_count) output=output " "
                  pos=tag_end + RSTART + RLENGTH
                  continue
              }

              if (!closing && (name == "script" || name == "style")) {
                  if (!hidden_count) output=output " "
                  lower_tail=tolower(substr(s, tag_end + 1))
                  if (!match(lower_tail, "</" name "[[:space:]]*>")) break
                  pos=tag_end + RSTART + RLENGTH
                  continue
              }

              if (closing) {
                  if (name == "li") pop_to_tag_in_scope("li", "list")
                  else if (name == "p") pop_to_tag_in_scope("p", "button")
                  else if (name == "button") pop_to_tag_in_scope("button", "")
                  else pop_to_tag_in_scope(name, "")
                  if (!hidden_count) output=output " "
                  pos=tag_end + 1
                  continue
              }

              apply_implicit_start_rules(name)
              if (!hidden_count) output=output " "
              self_closing=is_void_tag(name)
              hide=(name == "template" || name == "noscript" || has_hidden_attr(token, name_len + 1))
              if (!self_closing) {
                  depth++
                  tag_stack[depth]=name
                  hidden_stack[depth]=hide
                  if (hide) hidden_count++
              }
              pos=tag_end + 1
          }
          return output
      }

      BEGIN { apostrophe=sprintf("%c", 39) }
      { html=html $0 "\n" }
      END {
          html=visible_html(html)
          gsub(/&([nN][bB][sS][pP]|[tT][aA][bB]|[nN][eE][wW][lL][iI][nN][eE]);/, " ", html)
          gsub(/&#(9|10|13|32|160);|&#[xX](9|[aA]|[dD]|20|[aA]0);/, " ", html)
          gsub(/[[:space:]]+/, " ", html)
          sub(/^[[:space:]]+/, "", html)
          sub(/[[:space:]]+$/, "", html)
          print html
      }
    ' "$input"
}

check_unlock_gemini() {
    local proxy="$1" result meta code effective visible curl_rc
    WARP_UNLOCK_STATUS='检测失败'
    result=$(mktemp) || return 2
    if meta=$(warp_platform_curl -sSL --connect-timeout 5 --max-time 12 --proxy "$proxy" \
      -A 'Mozilla/5.0' -H 'Accept-Language: en-US,en;q=0.9' -o "$result" \
      -w $'%{http_code}\t%{url_effective}' https://gemini.google.com/app 2>/dev/null); then
        :
    else
        curl_rc=$?
        if [ "$curl_rc" -eq 28 ]; then
            WARP_UNLOCK_STATUS='检测超时（未确认解锁）'
        else
            WARP_UNLOCK_STATUS="检测失败（curl ${curl_rc}）"
        fi
        rm -f -- "$result"; return 2
    fi
    IFS=$'\t' read -r code effective <<< "$meta"
    visible=$(extract_html_visible_text "$result") || { rm -f -- "$result"; return 2; }
    if grep -qiE 'not[[:space:]]+(currently[[:space:]]+)?(available|supported)[[:space:]]+in[[:space:]]+your[[:space:]]+(country|region|location)|unsupported[[:space:]]+(country|region|location)|isn[^[:space:]]*[[:space:]]+(currently[[:space:]]+)?(available|supported)|(is[[:space:]]+)?unavailable[[:space:]]+in[[:space:]]+(this|your)[[:space:]]+(country|region|location)' <<< "$visible"; then
        rm -f -- "$result"
        WARP_UNLOCK_STATUS='受限'; return 1
    fi
    if grep -qiE 'temporarily[[:space:]]+unavailable|service[[:space:]]+unavailable|internal[[:space:]]+server[[:space:]]+error|something[[:space:]]+went[[:space:]]+wrong|try[[:space:]]+again[[:space:]]+later|maintenance' <<< "$visible"; then
        rm -f -- "$result"; return 2
    fi
    if [ "$code" = 200 ] && [[ "$effective" =~ ^https://gemini\.google\.com(/|$) ]] && \
      grep -Fq '45631641,null,true' "$result"; then
        rm -f -- "$result"
        WARP_UNLOCK_STATUS='网络/地区可用'; return 0
    fi
    if [ "$code" = 200 ] && [[ "$effective" =~ ^https://gemini\.google\.com(/|$) ]] && \
      grep -Eqi '<title[^>]*>[^<]*Gemini[^<]*</title>' "$result" && \
      grep -Fq '/_/BardChatUi/' "$result" && \
      grep -Eq 'AF_initDataCallback\(\{[^}]*data:[[:space:]]*\[[[:space:]]*[^][:space:]]' "$result"; then
        rm -f -- "$result"
        WARP_UNLOCK_STATUS='网络/地区可用'; return 0
    fi
    rm -f -- "$result"; return 2
}

run_selected_unlock_checks() {
    local proxy="$1" selection="$2" progress="${3:-false}" digit label checker rc overall=0 marker=''
    WARP_UNLOCK_SUMMARY=''
    WARP_UNLOCK_TRANSPORT_FAILED=0
    case "${WARP_PROBE_DIR:-}" in
        "${conf_dir:-}/warp/.probe."*) marker="$WARP_PROBE_DIR/transport-failure" ;;
    esac
    [[ "$selection" =~ ^[1-4]+$ ]] || return 1
    for digit in 1 2 3 4; do
        [[ "$selection" == *"$digit"* ]] || continue
        case "$digit" in
          1) label='Netflix'; checker=check_unlock_netflix ;;
          2) label='Disney+'; checker=check_unlock_disney ;;
          3) label='ChatGPT'; checker=check_unlock_chatgpt ;;
          4) label='Gemini'; checker=check_unlock_gemini ;;
        esac
        [ "$progress" != true ] || printf '正在检测 %s...\n' "$label"
        [ -z "$marker" ] || rm -f -- "$marker"
        rc=0
        "$checker" "$proxy" || rc=$?
        if [ "$rc" -eq 2 ] && [ -n "$marker" ] && [ -f "$marker" ]; then
            [ "$progress" != true ] || printf '%s 连接失败，正在复核同一 WARP 连接...\n' "$label"
            if probe_warp_trace "$proxy"; then
                rm -f -- "$marker"
                rc=0
                "$checker" "$proxy" || rc=$?
                if [ "$rc" -eq 2 ] && [ -f "$marker" ]; then WARP_UNLOCK_TRANSPORT_FAILED=1; fi
            else
                WARP_UNLOCK_TRANSPORT_FAILED=1
                WARP_UNLOCK_STATUS='WARP 连接暂不可用'
            fi
        fi
        WARP_UNLOCK_SUMMARY+="${label}: ${WARP_UNLOCK_STATUS}"$'\n'
        [ "$progress" != true ] || printf '%s: %s\n' "$label" "$WARP_UNLOCK_STATUS"
        [ "$rc" -eq 0 ] || overall=1
        unset rc
    done
    [ "$overall" -eq 0 ]
}

write_warp_status_cache() {
    local selection="${1:-}" summary="${2:-}" family="${3:-${WARP_PROBE_FAMILY:-}}"
    local cache="${conf_dir}/warp/status.json"
    [ -n "$family" ] || family=$(get_warp_preferred_family)
    mkdir -p "${conf_dir}/warp" && chmod 700 "${conf_dir}/warp"
    jq -n --argjson checked "$(date +%s)" --arg ip "${WARP_PROBE_IP:-}" \
      --arg loc "${WARP_PROBE_LOC:-}" --arg colo "${WARP_PROBE_COLO:-}" \
      --arg warp "${WARP_PROBE_STATE:-}" --arg family "$family" \
      --arg selection "$selection" --arg summary "$summary" \
      '{checked_at:$checked,ip:$ip,loc:$loc,colo:$colo,warp:$warp,family:$family,selection:$selection,summary:$summary}' \
      > "${cache}.tmp" && chmod 600 "${cache}.tmp" && mv -f "${cache}.tmp" "$cache"
}

probe_active_warp() {
    local family="${1:-}" endpoint
    [ -n "$family" ] || family=$(get_warp_preferred_family)
    case "$family" in 4|6) ;; *) return 1 ;; esac
    endpoint=$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)
    warp_endpoint_is_valid "$endpoint" || return 1
    start_warp_candidate_proxy "$endpoint" "$family" || return 1
    probe_warp_trace "$WARP_PROBE_PROXY"
    local rc=$?
    stop_warp_candidate_proxy
    return "$rc"
}

remove_warp_activation_backup() {
    rm -rf -- "$1"
}

activate_warp_candidate() {
    local candidate_dir="$1" state_dir="${conf_dir}/warp" endpoint_file="${conf_dir}/endpoints.json"
    local expected_ip="${2:-}" strict_selection="${3:-}" family="${4:-4}"
    local route_file="${conf_dir}/route.json" family_file="${state_dir}/preferred-family"
    local endpoint_json backup_dir endpoint_tmp route_tmp family_tmp
    local cleanup_incomplete=false
    case "$family" in 4|6) ;; *) return 1 ;; esac
    endpoint_json=$(extract_warp_endpoint "${candidate_dir}/endpoint.json" 2>/dev/null || true)
    warp_endpoint_is_valid "$endpoint_json" || return 1
    [ -s "$route_file" ] && jq empty "$route_file" >/dev/null 2>&1 || return 1
    mkdir -p "$state_dir" && chmod 700 "$state_dir" || return 1
    backup_dir=$(mktemp -d "${conf_dir}/.warp-activate.XXXXXX") || return 1
    chmod 700 "$backup_dir"
    cp -p "$endpoint_file" "$backup_dir/endpoints.json" && \
      cp -p "$route_file" "$backup_dir/route.json" || {
        remove_warp_activation_backup "$backup_dir" || yellow "激活备份目录清理失败，已保留: ${backup_dir}"
        return 1
    }
    if [ -s "$state_dir/account.json" ]; then
        cp -p "$state_dir/account.json" "$backup_dir/account.json" || {
            remove_warp_activation_backup "$backup_dir" || yellow "激活备份目录清理失败，已保留: ${backup_dir}"
            return 1
        }
        : > "$backup_dir/had-account"
    fi
    if [ -s "$state_dir/endpoint.json" ]; then
        cp -p "$state_dir/endpoint.json" "$backup_dir/endpoint.json" || {
            remove_warp_activation_backup "$backup_dir" || yellow "激活备份目录清理失败，已保留: ${backup_dir}"
            return 1
        }
        : > "$backup_dir/had-endpoint"
    fi
    if [ -s "$family_file" ]; then
        cp -p "$family_file" "$backup_dir/preferred-family" || {
            remove_warp_activation_backup "$backup_dir" || yellow "激活备份目录清理失败，已保留: ${backup_dir}"
            return 1
        }
        : > "$backup_dir/had-family"
    fi
    endpoint_tmp=$(mktemp "${conf_dir}/.endpoints.activate.XXXXXX") || {
        remove_warp_activation_backup "$backup_dir" || yellow "激活备份目录清理失败，已保留: ${backup_dir}"
        return 1
    }
    route_tmp=$(mktemp "${conf_dir}/.route.activate.XXXXXX") || {
        rm -f -- "$endpoint_tmp"
        remove_warp_activation_backup "$backup_dir" || yellow "激活备份目录清理失败，已保留: ${backup_dir}"
        return 1
    }
    family_tmp=$(mktemp "${state_dir}/.preferred-family.XXXXXX") || {
        rm -f -- "$endpoint_tmp" "$route_tmp"
        remove_warp_activation_backup "$backup_dir" || yellow "激活备份目录清理失败，已保留: ${backup_dir}"
        return 1
    }
    if ! jq --argjson endpoint "$endpoint_json" '.endpoints=([.endpoints[]?|select(.tag!="wireguard-out")]+[$endpoint])' \
      "$endpoint_file" > "$endpoint_tmp" || ! render_warp_route_family "$route_file" "$route_tmp" "$family" || \
      ! printf '%s\n' "$family" > "$family_tmp" || ! chmod 600 "$endpoint_tmp" "$family_tmp" || \
      ! chmod 644 "$route_tmp" || ! install -m 600 "${candidate_dir}/account.json" "$state_dir/account.json" || \
      ! install -m 600 "${candidate_dir}/endpoint.json" "$state_dir/endpoint.json" || ! chmod 600 "$endpoint_tmp" || \
      ! mv -f "$endpoint_tmp" "$endpoint_file" || ! mv -f "$route_tmp" "$route_file" || \
      ! mv -f "$family_tmp" "$family_file" || ! validate_singbox_config || ! restart_singbox_checked || \
      ! singbox_service_is_stably_active || \
      ! verify_activated_warp "$expected_ip" "$strict_selection" "$family"; then
        local rollback_ok=true
        rm -f -- "$endpoint_tmp" "$route_tmp" "$family_tmp"
        install -m 600 "$backup_dir/endpoints.json" "$endpoint_file" || rollback_ok=false
        install -m 644 "$backup_dir/route.json" "$route_file" || rollback_ok=false
        if [ -e "$backup_dir/had-account" ]; then install -m 600 "$backup_dir/account.json" "$state_dir/account.json" || rollback_ok=false; else rm -f -- "$state_dir/account.json" || rollback_ok=false; fi
        if [ -e "$backup_dir/had-endpoint" ]; then install -m 600 "$backup_dir/endpoint.json" "$state_dir/endpoint.json" || rollback_ok=false; else rm -f -- "$state_dir/endpoint.json" || rollback_ok=false; fi
        if [ -e "$backup_dir/had-family" ]; then install -m 600 "$backup_dir/preferred-family" "$family_file" || rollback_ok=false; else rm -f -- "$family_file" || rollback_ok=false; fi
        restart_singbox_checked >/dev/null 2>&1 || rollback_ok=false
        singbox_service_is_stably_active || rollback_ok=false
        if [ "$rollback_ok" = true ]; then
            remove_warp_activation_backup "$backup_dir" || yellow "回滚已完成，但激活备份目录清理失败，已保留: ${backup_dir}"
            return 1
        fi
        red "严重错误：旧 WARP 配置恢复不完整，已停止后续操作。"
        red "保留恢复目录: ${backup_dir}"
        return 2
    fi
    write_warp_status_cache "$strict_selection" "${WARP_UNLOCK_SUMMARY:-}" "$family" || \
      yellow "WARP 状态缓存写入失败，不影响已提交的新身份。"
    if [ -e "$backup_dir/had-account" ]; then
        if ! delete_warp_registration "$backup_dir/account.json"; then
            cleanup_incomplete=true
            yellow "旧 WARP 云端设备未能自动清理，恢复凭据已保留。"
        fi
    fi
    if [ "$cleanup_incomplete" = true ]; then
        red "新 WARP 身份已提交，但旧设备清理未完成。"
        red "保留恢复目录: ${backup_dir}"
        return 3
    fi
    if ! remove_warp_activation_backup "$backup_dir"; then
        red "新 WARP 身份已提交，但激活备份目录清理失败。"
        red "保留恢复目录: ${backup_dir}"
        return 3
    fi
    return 0
}

verify_activated_warp() {
    local expected_ip="${1:-}" selection="${2:-}" family="${3:-4}" endpoint rc=1
    case "$family" in 4|6) ;; *) return 1 ;; esac
    endpoint=$(extract_warp_endpoint "${conf_dir}/endpoints.json")
    start_warp_candidate_proxy "$endpoint" "$family" || return 1
    if probe_warp_trace "$WARP_PROBE_PROXY"; then
        if [ "$family" = 4 ]; then
            if [[ "$WARP_PROBE_IP" != *:* ]] && \
               { [ -z "$expected_ip" ] || [ "$WARP_PROBE_IP" = "$expected_ip" ]; }; then rc=0; fi
        elif [[ "$WARP_PROBE_IP" == *:* ]]; then
            # Cloudflare public IPv6 can change between connections of one identity.
            rc=0
        fi
        if [ "$rc" -eq 0 ] && [ -n "$selection" ]; then
            if run_selected_unlock_checks "$WARP_PROBE_PROXY" "$selection"; then rc=0; else rc=$?; fi
            # A transport recovery may reconnect the probe and update its exit IP.
            if [ "$rc" -eq 0 ]; then
                if [ "$family" = 4 ]; then
                    [[ "$WARP_PROBE_IP" != *:* ]] && \
                      { [ -z "$expected_ip" ] || [ "$WARP_PROBE_IP" = "$expected_ip" ]; } || rc=1
                else
                    [[ "$WARP_PROBE_IP" == *:* ]] || rc=1
                fi
            fi
        fi
    fi
    stop_warp_candidate_proxy
    return "$rc"
}

singbox_service_is_stably_active() {
    local attempt pid_before pid_after init_system
    local max_attempts="${SINGBOX_STABLE_MAX_ATTEMPTS:-15}"

    case "$max_attempts" in ''|*[!0-9]*) max_attempts=15 ;; esac
    [ "$max_attempts" -lt 4 ] && max_attempts=4
    [ "$max_attempts" -gt 60 ] && max_attempts=60

    init_system=$(detect_usable_init_system) || return 1
    if [ "$init_system" = systemd ]; then
        for ((attempt=1; attempt<=max_attempts; attempt++)); do
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
    elif [ "$init_system" = openrc ]; then
        for ((attempt=1; attempt<=max_attempts; attempt++)); do
            rc-service sing-box status >/dev/null 2>&1 && { sleep 1; rc-service sing-box status >/dev/null 2>&1 && return 0; }
            sleep 1
        done
        return 1
    else
        return 1
    fi
}

stop_singbox_checked() {
    local init_system

    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        openrc) rc-service sing-box stop ;;
        systemd) systemctl stop sing-box ;;
        *) return 1 ;;
    esac
}

remove_warp_candidate_dir() {
    rm -rf -- "$1"
}

rotate_warp_identity_once() {
    local old_ipv4='' old_ipv6='' candidate_dir candidate_endpoint new_ip activate_rc generate_rc attempt
    local candidate_ipv4='' candidate_ipv6='' selected_family=4 proxy_started probe_ok
    local failed_candidates=0 same_ip_candidates=0
    local WARP_MAX_CANDIDATES=5
    warp_endpoint_is_valid "$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)" || {
        red "内置 WARP 尚未初始化，请先设置一条 WARP 分流规则。"; return 1
    }
    if probe_active_warp 4 && [[ "$WARP_PROBE_IP" != *:* ]]; then
        old_ipv4="$WARP_PROBE_IP"
    fi
    if probe_active_warp 6 && [[ "$WARP_PROBE_IP" == *:* ]]; then
        old_ipv6="$WARP_PROBE_IP"
    fi
    if [ -z "$old_ipv4" ] && [ -z "$old_ipv6" ]; then
        red "无法取得当前 WARP 出口 IP，已停止更换。"
        return 1
    fi
    for ((attempt=1; attempt<=WARP_MAX_CANDIDATES; attempt++)); do
        candidate_dir=$(mktemp -d "${conf_dir}/warp/.candidate.XXXXXX") || return 1
        chmod 700 "$candidate_dir"
        if generate_unique_warp_identity "$candidate_dir"; then generate_rc=0; else generate_rc=$?; fi
        if [ "$generate_rc" -ne 0 ]; then
            if [ "$generate_rc" -eq 4 ]; then
                remove_warp_candidate_dir "$candidate_dir" || return 2
                red "WARP 注册前网络不可用，已停止本轮更换，原身份保持不变。"
                return 4
            fi
            if [ "$generate_rc" -eq 2 ]; then
                red "候选 WARP 注册状态不确定或云端清理失败，已停止更换。"
                red "候选凭据保留在: ${candidate_dir}"
                return 2
            fi
            failed_candidates=$((failed_candidates + 1))
            if ! remove_warp_candidate_dir "$candidate_dir"; then
                red "候选本地文件清理失败，已停止更换。"
                red "候选凭据保留在: ${candidate_dir}"
                return 2
            fi
            [ "$attempt" -lt "$WARP_MAX_CANDIDATES" ] && sleep $((attempt * 2))
            continue
        fi
        candidate_endpoint=$(extract_warp_endpoint "$candidate_dir/endpoint.json")
        proxy_started=false
        probe_ok=false
        candidate_ipv4=''
        candidate_ipv6=''
        selected_family=4
        new_ip=''
        if start_warp_candidate_proxy "$candidate_endpoint" 4; then
            proxy_started=true
            if probe_warp_trace "$WARP_PROBE_PROXY" && [[ "$WARP_PROBE_IP" != *:* ]]; then
                candidate_ipv4="$WARP_PROBE_IP"
                probe_ok=true
            fi
            stop_warp_candidate_proxy
            proxy_started=false
        fi
        if [ -n "$candidate_ipv4" ] && [ -n "$old_ipv4" ] && [ "$candidate_ipv4" != "$old_ipv4" ]; then
            selected_family=4
            new_ip="$candidate_ipv4"
        else
            if start_warp_candidate_proxy "$candidate_endpoint" 6; then
                proxy_started=true
                if probe_warp_trace "$WARP_PROBE_PROXY" && [[ "$WARP_PROBE_IP" == *:* ]]; then
                    candidate_ipv6="$WARP_PROBE_IP"
                    probe_ok=true
                fi
                stop_warp_candidate_proxy
                proxy_started=false
            fi
            if [ -n "$candidate_ipv6" ]; then
                selected_family=6
                new_ip="$candidate_ipv6"
                yellow "候选没有取得不同的 IPv4 出口（当前 ${old_ipv4:-不可用}）；已探测到可用 IPv6，验证通过后将优先使用 IPv6。"
                yellow "提示：Cloudflare 的公网 IPv6 可能随连接变化，不作为固定身份标识。"
            fi
        fi
        if [ "$probe_ok" != true ]; then
            [ "$proxy_started" = true ] && stop_warp_candidate_proxy
            if ! delete_warp_registration "$candidate_dir/account.json"; then
                red "候选 WARP 云端设备清理失败，已停止更换。"
                red "候选凭据保留在: ${candidate_dir}"
                return 2
            fi
            if ! remove_warp_candidate_dir "$candidate_dir"; then
                red "候选本地文件清理失败，已停止更换。"
                red "候选凭据保留在: ${candidate_dir}"
                return 2
            fi
            red "候选 WARP 连接复核失败，已停止后续注册，原身份保持不变。"
            return 4
        fi
        if [ -z "$new_ip" ]; then
            same_ip_candidates=$((same_ip_candidates + 1))
            yellow "候选 ${attempt}/${WARP_MAX_CANDIDATES} 的 Cloudflare WARP IPv4/IPv6 出口均未变化，继续尝试。"
            if ! delete_warp_registration "$candidate_dir/account.json"; then
                red "候选 WARP 云端设备清理失败，已停止更换。"
                red "候选凭据保留在: ${candidate_dir}"
                return 2
            fi
            if ! remove_warp_candidate_dir "$candidate_dir"; then
                red "候选本地文件清理失败，已停止更换。"
                red "候选凭据保留在: ${candidate_dir}"
                return 2
            fi
            [ "$attempt" -lt "$WARP_MAX_CANDIDATES" ] && sleep $((attempt * 2))
            continue
        fi
        if activate_warp_candidate "$candidate_dir" "$new_ip" '' "$selected_family"; then activate_rc=0; else activate_rc=$?; fi
        if [ "$activate_rc" -eq 0 ] || [ "$activate_rc" -eq 3 ]; then
            if ! remove_warp_candidate_dir "$candidate_dir"; then
                yellow "新 WARP 身份已提交，但候选本地副本清理失败。"
                red "候选凭据保留在: ${candidate_dir}"
            fi
            [ "$activate_rc" -eq 3 ] && yellow "新 WARP 身份已提交，但旧凭据或临时文件清理未完成。"
            if [ "$selected_family" = 6 ]; then
                green "WARP 身份已更换（所选分流规则优先 IPv6；公网 IPv6 可能随连接变化）"
            else
                green "WARP 身份已更换：${old_ipv4} -> ${new_ip}"
            fi
            return 0
        fi
        if [ "$activate_rc" -eq 2 ]; then
            red "候选凭据保留在: ${candidate_dir}"
            return 2
        fi
        if ! delete_warp_registration "$candidate_dir/account.json"; then
            red "候选 WARP 云端设备清理失败，已停止更换。"
            red "候选凭据保留在: ${candidate_dir}"
            return 2
        fi
        if ! remove_warp_candidate_dir "$candidate_dir"; then
            red "候选本地文件清理失败，已停止更换。"
            red "候选凭据保留在: ${candidate_dir}"
            return 2
        fi
        return 1
    done
    if [ "$same_ip_candidates" -gt 0 ]; then
        red "未获得不同的 Cloudflare WARP 出口 IP，原 WARP 身份保持不变。"
    else
        red "候选均在生成或探测阶段失败，原 WARP 身份保持不变。"
    fi
    return 1
}

warp_rotation_now() {
    date +%s
}

rotate_warp_identity_until_new() {
    local max_batches="${WARP_ROTATION_MAX_BATCHES:-4}"
    local max_seconds="${WARP_ROTATION_MAX_SECONDS:-600}"
    local started_at now batch rotate_rc elapsed

    case "$max_batches" in ''|*[!0-9]*) max_batches=4 ;; esac
    case "$max_seconds" in ''|*[!0-9]*) max_seconds=600 ;; esac
    [ "$max_batches" -lt 1 ] && max_batches=1
    [ "$max_batches" -gt 12 ] && max_batches=12
    [ "$max_seconds" -lt 60 ] && max_seconds=60
    [ "$max_seconds" -gt 3600 ] && max_seconds=3600

    started_at=$(warp_rotation_now) || return 1
    for ((batch=1; batch<=max_batches; batch++)); do
        if [ "$batch" -gt 1 ]; then
            now=$(warp_rotation_now) || return 1
            elapsed=$((now - started_at))
            if [ "$elapsed" -ge "$max_seconds" ]; then
                red "WARP 身份更换达到 ${max_seconds} 秒时间上限，未获得不同出口。"
                return 1
            fi
        fi
        yellow "正在执行 WARP 更换批次 ${batch}/${max_batches}（每批最多 5 个候选）..."
        if rotate_warp_identity_once; then
            return 0
        else
            rotate_rc=$?
        fi
        case "$rotate_rc" in
          1) ;;
          2) return 2 ;;
          *) return "$rotate_rc" ;;
        esac
        [ "$batch" -lt "$max_batches" ] && sleep 10
    done
    red "WARP 身份更换已达到 ${max_batches} 批上限，未获得不同出口。"
    return 1
}

auto_select_warp_candidate() {
    local selection="${1:-1234}" active_ipv4='' active_ipv6='' candidate_dir candidate_endpoint
    local attempt candidate_ip activate_rc generate_rc selected_family=4
    local candidate_ipv4='' candidate_ipv6='' proxy_started probe_ok
    local WARP_MAX_CANDIDATES=5
    WARP_UNLOCK_TRANSPORT_FAILED=0
    warp_endpoint_is_valid "$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)" || {
        red "内置 WARP 尚未初始化，请先设置一条 WARP 分流规则。"; return 1
    }
    if probe_active_warp 4 && [[ "$WARP_PROBE_IP" != *:* ]]; then
        active_ipv4="$WARP_PROBE_IP"
    fi
    if probe_active_warp 6 && [[ "$WARP_PROBE_IP" == *:* ]]; then
        active_ipv6="$WARP_PROBE_IP"
    fi
    if [ -z "$active_ipv4" ] && [ -z "$active_ipv6" ]; then
        red "无法取得当前 WARP 出口 IP，已停止优选。"
        return 1
    fi
    for ((attempt=1; attempt<=WARP_MAX_CANDIDATES; attempt++)); do
        yellow "正在测试候选 ${attempt}/${WARP_MAX_CANDIDATES}..."
        candidate_dir=$(mktemp -d "${conf_dir}/warp/.candidate.XXXXXX") || return 1
        chmod 700 "$candidate_dir"
        if generate_unique_warp_identity "$candidate_dir"; then generate_rc=0; else generate_rc=$?; fi
        if [ "$generate_rc" -eq 4 ]; then
            remove_warp_candidate_dir "$candidate_dir" || return 2
            red "WARP 注册前网络不可用，已停止本轮优选，原身份保持不变。"
            return 4
        fi
        if [ "$generate_rc" -eq 2 ]; then
            red "候选 WARP 注册状态不确定或云端清理失败，自动优选已立即停止。"
            red "候选凭据保留在: ${candidate_dir}"
            return 2
        fi
        if [ "$generate_rc" -ne 0 ]; then
            if ! remove_warp_candidate_dir "$candidate_dir"; then
                red "候选本地文件清理失败，自动优选已立即停止。"
                red "候选凭据保留在: ${candidate_dir}"
                return 2
            fi
            [ "$attempt" -lt "$WARP_MAX_CANDIDATES" ] && sleep $((attempt * 2))
            continue
        fi

        candidate_endpoint=$(extract_warp_endpoint "$candidate_dir/endpoint.json")
        proxy_started=false
        probe_ok=false
        candidate_ipv4=''
        candidate_ipv6=''
        candidate_ip=''
        selected_family=4
        if start_warp_candidate_proxy "$candidate_endpoint" 4; then
            proxy_started=true
            if probe_warp_trace "$WARP_PROBE_PROXY" && [[ "$WARP_PROBE_IP" != *:* ]]; then
                candidate_ipv4="$WARP_PROBE_IP"
                probe_ok=true
            fi
        fi
        if [ -n "$candidate_ipv4" ] && [ -n "$active_ipv4" ] && [ "$candidate_ipv4" != "$active_ipv4" ]; then
            candidate_ip="$candidate_ipv4"
            selected_family=4
        else
            [ "$proxy_started" = true ] && stop_warp_candidate_proxy
            proxy_started=false
            if start_warp_candidate_proxy "$candidate_endpoint" 6; then
                proxy_started=true
                if probe_warp_trace "$WARP_PROBE_PROXY" && [[ "$WARP_PROBE_IP" == *:* ]]; then
                    candidate_ipv6="$WARP_PROBE_IP"
                    probe_ok=true
                fi
                if [ -n "$candidate_ipv6" ]; then
                    candidate_ip="$candidate_ipv6"
                    selected_family=6
                    yellow "候选没有取得不同的 IPv4 出口（当前 ${active_ipv4:-不可用}）；正在测试 IPv6，全部所选平台通过后才会切换。"
                    yellow "提示：Cloudflare 的公网 IPv6 可能随连接变化，不作为固定身份标识。"
                fi
            fi
        fi
        if [ "$probe_ok" = true ]; then
            if [ -z "$candidate_ip" ]; then
                yellow "候选 IPv4/IPv6 出口均未变化，继续。"
            elif run_selected_unlock_checks "$WARP_PROBE_PROXY" "$selection" true; then
                stop_warp_candidate_proxy
                proxy_started=false
                if activate_warp_candidate "$candidate_dir" "$candidate_ip" "$selection" "$selected_family"; then activate_rc=0; else activate_rc=$?; fi
                if [ "$activate_rc" -eq 0 ] || [ "$activate_rc" -eq 3 ]; then
                    if ! remove_warp_candidate_dir "$candidate_dir"; then
                        yellow "新 WARP 身份已提交，但候选本地副本清理失败。"
                        red "候选凭据保留在: ${candidate_dir}"
                    fi
                    [ "$activate_rc" -eq 3 ] && yellow "新 WARP 身份已提交，但旧凭据或临时文件清理未完成。"
                    if [ "$selected_family" = 6 ]; then
                        green "已启用新的 WARP 身份（所选分流规则优先 IPv6；公网 IPv6 可能随连接变化）"
                    else
                        green "已启用新的 WARP IPv4 出口 ${candidate_ip}"
                    fi
                    return 0
                fi
                if [ "$activate_rc" -eq 2 ]; then
                    red "候选凭据保留在: ${candidate_dir}"
                    red "因回滚不完整，自动优选已立即停止。"
                    return 2
                fi
            fi
        fi
        [ "$proxy_started" = true ] && stop_warp_candidate_proxy
        if ! delete_warp_registration "$candidate_dir/account.json"; then
            red "候选 WARP 云端设备清理失败，自动优选已立即停止。"
            red "候选凭据保留在: ${candidate_dir}"
            return 2
        fi
        if ! remove_warp_candidate_dir "$candidate_dir"; then
            red "候选本地文件清理失败，自动优选已立即停止。"
            red "候选凭据保留在: ${candidate_dir}"
            return 2
        fi
        if [ "$probe_ok" != true ] || [ "${WARP_UNLOCK_TRANSPORT_FAILED:-0}" -eq 1 ]; then
            red "网络复核仍失败，已停止后续注册；原 WARP 身份保持不变。"
            return 4
        fi
        [ "$attempt" -lt "$WARP_MAX_CANDIDATES" ] && sleep $((attempt * 2))
    done
    red "未找到满足条件的新出口，原 WARP 身份保持不变。"
    return 1
}

show_warp_status_and_unlocks() {
    local account_file="${conf_dir}/warp/account.json" selection="${1:-1234}" family endpoint
    endpoint=$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)
    warp_endpoint_is_valid "$endpoint" || {
        yellow "内置 WARP 尚未初始化。"; return 1
    }
    family=$(get_warp_preferred_family)
    yellow "正在检测内置 WARP 连通性（握手最多等待 30 秒）..."
    if ! start_warp_candidate_proxy "$endpoint" "$family"; then
        red "无法启动内置 WARP 临时探测代理。"; return 1
    fi
    if ! probe_warp_trace "$WARP_PROBE_PROXY"; then
        stop_warp_candidate_proxy
        red "内置 WARP 运行探测失败。"; return 1
    fi
    green "设备 ID: $(jq -r '.id // "unknown"' "$account_file" 2>/dev/null)"
    green "出口 IP: ${WARP_PROBE_IP}（IPv${family}）  地区: ${WARP_PROBE_LOC:-未知}  机房: ${WARP_PROBE_COLO:-未知}"
    green "WARP: ${WARP_PROBE_STATE}"
    run_selected_unlock_checks "$WARP_PROBE_PROXY" "$selection" true || true
    stop_warp_candidate_proxy
    write_warp_status_cache "$selection" "$WARP_UNLOCK_SUMMARY" "$family" || \
        yellow "状态已显示，但缓存写入失败。"
}

get_warp_menu_status() {
    local endpoint cache="${conf_dir}/warp/status.json" now checked warp
    endpoint=$(extract_warp_endpoint "${conf_dir}/endpoints.json" 2>/dev/null || true)
    warp_endpoint_is_valid "$endpoint" || { echo 'not configured'; return; }
    now=$(date +%s); checked=$(jq -r '.checked_at // 0' "$cache" 2>/dev/null || echo 0)
    warp=$(jq -r '.warp // empty' "$cache" 2>/dev/null || true)
    if [ $((now - checked)) -gt 300 ]; then
        if probe_active_warp; then
            warp="$WARP_PROBE_STATE"
        else
            warp='failed'
            WARP_PROBE_STATE=failed
            WARP_PROBE_IP=''; WARP_PROBE_LOC=''; WARP_PROBE_COLO=''
        fi
        write_warp_status_cache || true
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
        yellow "正在为本机注册独立 WARP 身份..." >&2
        generate_unique_warp_identity >&2 || return 1
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
  {"tag":"streaming","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-entertainment.srs","download_detour":"direct"}
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
    local separate_cache=false cache_config
    local -a target_files

    command_exists jq || { red "WARP 分流需要 jq。"; return 1; }
    mkdir -p "$conf_dir" || return 1

    # Directory configurations may keep experimental settings in a separate file.
    for cache_config in "${conf_dir}"/*.json; do
        [ "$cache_config" != "$current_route_file" ] || continue
        if jq -e '.experimental.cache_file != null' "$cache_config" >/dev/null 2>&1; then
            separate_cache=true
            break
        fi
    done

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
        jq --argjson required "$required_rule_sets" --arg cache_path "${work_dir}/cache.db" --argjson separate_cache "$separate_cache" '
          (if $separate_cache then . else
            .experimental.cache_file = ({enabled: true, path: $cache_path} + (.experimental.cache_file // {}))
          end) |
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
        jq -n --argjson required "$required_rule_sets" --arg cache_path "${work_dir}/cache.db" --argjson separate_cache "$separate_cache" \
           '{route: {rule_set: $required, rules: [], final: "direct"}} |
            if $separate_cache then . else
              .experimental.cache_file = {enabled: true, path: $cache_path}
            end' > "$route_tmp"
    fi || {
        restore_warp_file_backups "$backup_dir" "${target_files[@]}"
        rm -f "$endpoint_tmp" "$route_tmp" "$outbound_tmp"
        rm -rf -- "$backup_dir"
        return 1
    }

    if [ -s "$current_outbound_file" ] && jq empty "$current_outbound_file" >/dev/null 2>&1; then
        jq '
          ([.outbounds[]? | select(.tag == "direct" and .type == "direct")] | first) as $direct |
          .outbounds = ([($direct // {"type":"direct","tag":"direct"})] + [
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
    local init_system restart_status

    yellow "正在重启 sing-box 服务\n"
    init_system=$(detect_usable_init_system) || {
        red "找不到可用的服务管理器，sing-box 未重启。"
        return 1
    }
    case "$init_system" in
        openrc) rc-service sing-box restart ;;
        systemd) systemctl daemon-reload && systemctl restart sing-box ;;
        *) return 1 ;;
    esac
    restart_status=$?
    if [ "$restart_status" -eq 0 ]; then
        green "sing-box 服务已成功重启\n"
        return 0
    fi
    red "sing-box 服务重启失败\n"
    return "$restart_status"
}

argo_service_is_active() {
    local init_system

    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        openrc) rc-service argo status >/dev/null 2>&1 ;;
        systemd) systemctl is-active --quiet argo ;;
        *) return 1 ;;
    esac
}

restart_argo_checked() {
    local init_system restart_status

    yellow "正在重启 Argo 服务\n"
    init_system=$(detect_usable_init_system) || {
        red "找不到可用的服务管理器，Argo 未重启。"
        return 1
    }
    case "$init_system" in
        openrc) rc-service argo restart ;;
        systemd) systemctl daemon-reload && systemctl restart argo ;;
        *) return 1 ;;
    esac
    restart_status=$?
    if [ "$restart_status" -eq 0 ]; then
        green "Argo 服务已成功重启\n"
        return 0
    fi
    red "Argo 服务重启失败\n"
    return "$restart_status"
}

stop_argo_checked() {
    local init_system

    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        openrc) rc-service argo stop ;;
        systemd) systemctl stop argo ;;
        *) return 1 ;;
    esac
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
    local init_system

    init_system=$(detect_usable_init_system) || return 1
    case "$init_system" in
        openrc) rc-service sing-box status >/dev/null 2>&1 ;;
        systemd) systemctl is-active --quiet sing-box ;;
        *) return 1 ;;
    esac
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
    local lock_owner='' lock_status=0

    [ -d "$transaction_conf_dir" ] && [ ! -L "$transaction_conf_dir" ] && \
        [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || return 1
    PROXY_TX_LOCK_KIND=''
    PROXY_TX_LOCK_PATH="${transaction_conf_dir}/.proxy-transaction.lock"
    PROXY_TX_LOCK_FD=''

    acquire_transaction_lock_with_legacy mutation "$PROXY_TX_LOCK_PATH" "$timeout_seconds" || \
        lock_status=$?
    [ "$lock_status" -eq 0 ] || return "$lock_status"
    PROXY_TX_LOCK_KIND='stable'
    PROXY_TX_LOCK_FD="${STABLE_TX_MUTATION_FD:-}"
    if declare -F assert_no_pending_durable_transaction >/dev/null 2>&1; then
        assert_no_pending_durable_transaction "$transaction_conf_dir"
        lock_owner=$?
        if [ "$lock_owner" -ne 0 ]; then
            release_proxy_transaction_lock >/dev/null 2>&1 || true
            return "$lock_owner"
        fi
    fi
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
    local release_status=0

    if [ "${PROXY_TX_LOCK_KIND:-}" = stable ]; then
        release_transaction_lock_with_legacy mutation || release_status=$?
    fi
    PROXY_TX_LOCK_KIND=''
    PROXY_TX_LOCK_PATH=''
    PROXY_TX_LOCK_FD=''
    [ "$release_status" -eq 0 ] || return 2
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
    finish_transaction_release "$final_status" release_proxy_transaction_lock || final_status=$?
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
    finish_transaction_release "$final_status" release_proxy_transaction_lock || final_status=$?
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
    _apply_proxy_config_transaction_locked "$@" || transaction_status=$?
    trap - INT TERM EXIT
    restore_proxy_transaction_traps
    finish_transaction_release "$transaction_status" release_proxy_transaction_lock || \
        transaction_status=$?
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
    local route_tmp route_rendered route_backup family

    [ -s "$current_route_file" ] && jq empty "$current_route_file" >/dev/null 2>&1 || return 1
    route_tmp=$(mktemp "${conf_dir}/.tmp.route.XXXXXX") || return 1
    route_rendered=$(mktemp "${conf_dir}/.tmp.route-family.XXXXXX") || { rm -f "$route_tmp"; return 1; }
    route_backup=$(mktemp "${conf_dir}/.bak.route.XXXXXX") || { rm -f "$route_tmp" "$route_rendered"; return 1; }
    cp -p "$current_route_file" "$route_backup" 2>/dev/null || cp "$current_route_file" "$route_backup" || {
        rm -f "$route_tmp" "$route_rendered" "$route_backup"
        return 1
    }
    family=$(get_warp_preferred_family)

    if ! jq "$@" "$jq_filter" "$current_route_file" > "$route_tmp" || \
       ! render_warp_route_family "$route_tmp" "$route_rendered" "$family" || \
       ! jq empty "$route_rendered" >/dev/null 2>&1 || \
       ! chmod 644 "$route_rendered" || ! mv -f "$route_rendered" "$current_route_file" || \
       ! validate_singbox_config; then
        mv -f "$route_backup" "$current_route_file" >/dev/null 2>&1 || true
        rm -f "$route_tmp" "$route_rendered"
        red "sing-box 路由配置校验失败，已回滚。"
        return 1
    fi

    if ! restart_singbox_checked; then
        mv -f "$route_backup" "$current_route_file" >/dev/null 2>&1 || true
        restart_singbox_checked >/dev/null 2>&1 || true
        red "sing-box 重启失败，已恢复原路由配置。"
        return 1
    fi

    rm -f "$route_tmp" "$route_rendered" "$route_backup"
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

dispatch_warp_rotation_menu_action() {
    local rotate_rc
    if rotate_warp_identity_until_new; then
        return 0
    else
        rotate_rc=$?
    fi
    case "$rotate_rc" in
      1)
        red "WARP 身份更换失败，原配置保持不变。"
        ;;
      2)
        red "WARP 身份更换未安全完成：回滚或状态不完整。"
        red "请停止使用自动结论，并按上方提示的恢复目录处理。"
        ;;
      4)
        red "WARP 网络暂不可用，已停止后续注册；原身份和分流配置保持不变。"
        ;;
      *)
        red "WARP 身份更换返回未知状态 ${rotate_rc}，请检查上方日志后再处理。"
        ;;
    esac
    return "$rotate_rc"
}

list_enabled_warp_route_mappings() {
    local route_file="${1:-}"
    [ -s "$route_file" ] || return 1
    jq -r '
      .route.rules[]? |
      select(.action? == "route" and (.rule_set? | type) == "array") |
      "\(.rule_set[]?) -> \(.outbound // "unknown")\(if .ip_version == 6 then " (IPv6)" else "" end)"
    ' "$route_file" | sort -u
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
    list_enabled_warp_route_mappings "$route_file" 2>/dev/null | while read -r mapping; do
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
        5)  clear; show_warp_status_and_unlocks || true; read -n 1 -s -r -p $'\n按任意键返回...'; warp_manage ;;
        6)  clear; dispatch_warp_rotation_menu_action || true; read -n 1 -s -r -p $'\n按任意键返回...'; warp_manage ;;
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

    if add_service_route "$rule_tag" "$selected_out"; then
        green "'${rule_tag}' 的 IPv4/IPv6 已分流至出站 '${selected_out}'"
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

    # 内置 WireGuard 位于 endpoints 中，也应作为全局出站候选。
    local -a proxy_tags
    mapfile -t proxy_tags < <(
        printf '%s\n' wireguard-out
        jq -r '.outbounds[]? | select(.tag != "direct" and .tag != "wireguard-out") | .tag' "$outbound_file"
    )

    echo ""
    green "请选择全局代理出站:"
    for i in "${!proxy_tags[@]}"; do
        if [ "${proxy_tags[$i]}" = wireguard-out ]; then
            echo -e "  ${green}$((i+1)). ${skyblue}wireguard-out [内置WARP]${re}"
        else
            echo -e "  ${green}$((i+1)). ${skyblue}${proxy_tags[$i]}${re}"
        fi
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

    [[ "$scheme" =~ ^[A-Za-z][A-Za-z0-9+.-]*$ ]] || return 1
    mutate_base_subscription remove_url_by_tag_file "$scheme"
}

with_subscription_lock() {
    local lock_file="${SUBSCRIPTION_LOCK_FILE:-${work_dir}/.subscription.lock}"
    local timeout_seconds="${SUBSCRIPTION_LOCK_TIMEOUT_SECONDS:-30}"
    local lock_status=0 release_status=0

    if [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ]; then
        "$@"
        return $?
    fi
    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || return 1
    command -v flock >/dev/null 2>&1 || return 1
    acquire_transaction_lock_with_legacy subscription "$lock_file" "$timeout_seconds" || return $?

    local SUBSCRIPTION_LOCK_HELD=1
    "$@" || lock_status=$?
    release_transaction_lock_with_legacy subscription || release_status=$?
    [ "$release_status" -eq 0 ] || return 2
    return "$lock_status"
}

encode_subscription_source() {
    local source_file="$1"
    local output_file="$2"

    if [ ! -s "$source_file" ]; then
        : > "$output_file"
    elif base64 -w0 "$source_file" > "$output_file" 2>/dev/null; then
        return 0
    else
        (set -o pipefail; base64 "$source_file" | tr -d '\n\r' > "$output_file")
    fi
}

write_base64_subscription() {
    local source_file="$1"
    local sub_file="$2"
    local output_mode="${3:-600}"
    local sub_dir sub_name tmp_file

    case "$output_mode" in 600|644) ;; *) return 1 ;; esac
    sub_dir=$(dirname "$sub_file")
    sub_name=$(basename "$sub_file")
    mkdir -p "$sub_dir" || return 1
    if [ -e "$sub_file" ] || [ -L "$sub_file" ]; then
        [ -f "$sub_file" ] && [ ! -L "$sub_file" ] || return 1
    fi
    tmp_file=$(mktemp "${sub_dir}/.tmp.${sub_name}.XXXXXX") || return 1
    encode_subscription_source "$source_file" "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod "$output_mode" "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv -f "$tmp_file" "$sub_file" || { rm -f "$tmp_file"; return 1; }
}

read_strict_subscription_generation_file() {
    local generation_file="${1:-}"
    local generation file_mode

    [ -n "$generation_file" ] || return 1
    [ -f "$generation_file" ] && [ ! -L "$generation_file" ] || return 1
    file_mode=$(stat -c '%a' -- "$generation_file" 2>/dev/null) || return 1
    [ "$file_mode" = 600 ] || return 1
    generation=$(awk '
        NR == 1 { value = $0; next }
        { invalid = 1 }
        END {
            if (NR != 1 || invalid) exit 1
            printf "%s", value
        }
    ' "$generation_file") || return 1
    [[ "$generation" =~ ^[0-9a-f]{64}:[0-9]+$ ]] || return 1
    printf '%s\n' "$generation"
}

select_cfy_subscription_source_locked() {
    local base_source_file="${1:-$client_dir}"
    local cfy_file="${work_dir}/cfy-url.txt"
    local generation_file="${CFY_SOURCE_GENERATION_FILE:-${work_dir}/cfy-source.generation}"
    local current_generation cfy_generation

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
    current_generation=$(get_base_subscription_generation_locked "$base_source_file") || return 1
    if [ -f "$cfy_file" ] && [ ! -L "$cfy_file" ] &&
       cfy_generation=$(read_strict_subscription_generation_file "$generation_file") &&
       [ "$cfy_generation" = "$current_generation" ]; then
        printf '%s\n' "$cfy_file"
    else
        printf '/dev/null\n'
    fi
}

publish_subscriptions_locked() {
    local staged_base_file="${1:-}"
    local base_source_file="$client_dir"
    local cfy_source_file=/dev/null
    local base_sub_file="${work_dir}/base-sub.txt"
    local cfy_sub_file="${work_dir}/cfy-sub.txt"
    local combined_sub_file="${work_dir}/all-sub.txt"
    local served_sub_file="${work_dir}/sub.txt"
    local tmp_base_sub tmp_cfy_sub tmp_all_url tmp_all_sub tmp_sub target_file
    local backup_file commit_failed=0 rollback_failed=0 index restore_index
    local -a commit_sources=() commit_targets=() backup_files=() target_existed=()

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
    mkdir -p "$work_dir" || return 1
    for target_file in "$client_dir" "$base_sub_file" "$cfy_sub_file" \
        "$combined_client_dir" "$combined_sub_file" "$served_sub_file"; do
        if [ -e "$target_file" ] || [ -L "$target_file" ]; then
            [ -f "$target_file" ] && [ ! -L "$target_file" ] || return 1
        fi
    done

    if [ -n "$staged_base_file" ]; then
        [ -f "$staged_base_file" ] && [ ! -L "$staged_base_file" ] || return 1
        chmod 600 "$staged_base_file" || return 1
        base_source_file="$staged_base_file"
    else
        [ -f "$client_dir" ] || return 1
        chmod 600 "$client_dir" || return 1
    fi
    cfy_source_file=$(select_cfy_subscription_source_locked "$base_source_file") || return 1

    tmp_base_sub=$(mktemp "${work_dir}/.tmp.base-sub.txt.XXXXXX") || return 1
    tmp_cfy_sub=$(mktemp "${work_dir}/.tmp.cfy-sub.txt.XXXXXX") || { rm -f "$tmp_base_sub"; return 1; }
    tmp_all_url=$(mktemp "${work_dir}/.tmp.all-url.txt.XXXXXX") || { rm -f "$tmp_base_sub" "$tmp_cfy_sub"; return 1; }
    tmp_all_sub=$(mktemp "${work_dir}/.tmp.all-sub.txt.XXXXXX") || { rm -f "$tmp_base_sub" "$tmp_cfy_sub" "$tmp_all_url"; return 1; }
    tmp_sub=$(mktemp "${work_dir}/.tmp.sub.txt.XXXXXX") || { rm -f "$tmp_base_sub" "$tmp_cfy_sub" "$tmp_all_url" "$tmp_all_sub"; return 1; }

    if ! awk '{ sub(/\r$/, ""); if ($0 ~ /^[[:space:]]*$/) next; if (!seen[$0]++) print }' \
        "$base_source_file" "$cfy_source_file" 2>/dev/null > "$tmp_all_url" ||
       ! encode_subscription_source "$base_source_file" "$tmp_base_sub" ||
       ! encode_subscription_source "$cfy_source_file" "$tmp_cfy_sub" ||
       ! encode_subscription_source "$tmp_all_url" "$tmp_all_sub" ||
       ! encode_subscription_source "$tmp_all_url" "$tmp_sub" ||
       ! chmod 600 "$tmp_base_sub" "$tmp_cfy_sub" "$tmp_all_url" "$tmp_all_sub" ||
       ! chmod 644 "$tmp_sub"; then
        rm -f "$tmp_base_sub" "$tmp_cfy_sub" "$tmp_all_url" "$tmp_all_sub" "$tmp_sub"
        return 1
    fi

    if [ -n "$staged_base_file" ]; then
        commit_sources+=("$staged_base_file")
        commit_targets+=("$client_dir")
    fi
    commit_sources+=("$tmp_base_sub" "$tmp_cfy_sub" "$tmp_all_url" "$tmp_all_sub" "$tmp_sub")
    commit_targets+=("$base_sub_file" "$cfy_sub_file" "$combined_client_dir" "$combined_sub_file" "$served_sub_file")

    for ((index = 0; index < ${#commit_targets[@]}; index++)); do
        target_file="${commit_targets[$index]}"
        backup_file=$(mktemp "${work_dir}/.tmp.$(basename "$target_file").rollback.XXXXXX") || {
            rm -f "${commit_sources[@]}" "${backup_files[@]}"
            return 1
        }
        if [ -f "$target_file" ]; then
            cp -p -- "$target_file" "$backup_file" || {
                rm -f "$backup_file" "${commit_sources[@]}" "${backup_files[@]}"
                return 1
            }
            target_existed+=(1)
        else
            rm -f "$backup_file"
            target_existed+=(0)
        fi
        backup_files+=("$backup_file")
    done

    for ((index = 0; index < ${#commit_targets[@]}; index++)); do
        if ! mv -f -- "${commit_sources[$index]}" "${commit_targets[$index]}"; then
            commit_failed=1
            for ((restore_index = index - 1; restore_index >= 0; restore_index--)); do
                if [ "${target_existed[$restore_index]}" = 1 ]; then
                    if ! mv -f -- "${backup_files[$restore_index]}" "${commit_targets[$restore_index]}"; then
                        rollback_failed=1
                        printf 'FATAL: subscription rollback failed; preserved backup %s for %s\n' \
                            "${backup_files[$restore_index]}" "${commit_targets[$restore_index]}" >&2
                    fi
                else
                    if ! rm -f -- "${commit_targets[$restore_index]}"; then
                        rollback_failed=1
                        printf 'FATAL: subscription rollback failed; remove manually: %s\n' \
                            "${commit_targets[$restore_index]}" >&2
                    fi
                fi
            done
            break
        fi
    done
    rm -f "${commit_sources[@]}"
    if [ "$commit_failed" -eq 0 ]; then
        rm -f "${backup_files[@]}"
        return 0
    fi
    if [ "$rollback_failed" -ne 0 ]; then
        printf 'FATAL: subscription rollback was incomplete; recovery files remain in %s\n' "$work_dir" >&2
        return 2
    fi
    rm -f "${backup_files[@]}"
    return 1
}

sync_combined_subscription() {
    with_subscription_lock publish_subscriptions_locked
}

update_sub() {
    with_subscription_lock publish_subscriptions_locked "${1:-}"
}

get_base_subscription_generation_locked() {
    local source_file="${1:-$client_dir}"
    local digest byte_count

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
    if [ -e "$source_file" ] || [ -L "$source_file" ]; then
        [ -f "$source_file" ] && [ ! -L "$source_file" ] || return 1
    else
        printf 'absent\n'
        return 0
    fi
    command -v sha256sum >/dev/null 2>&1 || return 1
    digest=$(sha256sum "$source_file" 2>/dev/null) || return 1
    digest=${digest%%[[:space:]]*}
    [[ "$digest" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    byte_count=$(wc -c < "$source_file") || return 1
    byte_count=${byte_count//[[:space:]]/}
    [[ "$byte_count" =~ ^[0-9]+$ ]] || return 1
    printf '%s:%s\n' "${digest,,}" "$byte_count"
}

get_base_subscription_generation() {
    with_subscription_lock get_base_subscription_generation_locked "${1:-$client_dir}"
}

verify_base_subscription_generation_locked() {
    local expected_generation="${1:-}"
    local source_file="${2:-$client_dir}"
    local current_generation

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
    [ -n "$expected_generation" ] || return 1
    current_generation=$(get_base_subscription_generation_locked "$source_file") || return 1
    if [ "$current_generation" != "$expected_generation" ]; then
        printf 'ERROR: base subscription generation changed; refusing stale get_info publication\n' >&2
        return 1
    fi
}

publish_generated_base_locked() {
    local generated_base_file="${1:-}"
    local expected_generation="${2:-}"
    local staged_base_file extra_file publish_status

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
    verify_base_subscription_generation_locked "$expected_generation" "$client_dir" || return 1
    [ -f "$generated_base_file" ] && [ ! -L "$generated_base_file" ] || return 1
    if [ -e "$client_dir" ] || [ -L "$client_dir" ]; then
        [ -f "$client_dir" ] && [ ! -L "$client_dir" ] || return 1
    fi
    staged_base_file=$(mktemp "$(dirname "$client_dir")/.tmp.$(basename "$client_dir").generated.XXXXXX") || return 1
    extra_file=$(mktemp "$(dirname "$client_dir")/.tmp.$(basename "$client_dir").extras.XXXXXX") || {
        rm -f "$staged_base_file"
        return 1
    }
    cp -- "$generated_base_file" "$staged_base_file" || {
        rm -f "$staged_base_file" "$extra_file"
        return 1
    }
    if [ -f "$client_dir" ]; then
        awk '$0 !~ /^(vless:\/\/|vmess:\/\/|hysteria2:\/\/|tuic:\/\/)/ { print }' \
            "$client_dir" > "$extra_file" || {
            rm -f "$staged_base_file" "$extra_file"
            return 1
        }
    fi
    if [ -s "$extra_file" ]; then
        if [ -s "$staged_base_file" ]; then
            printf '\n' >> "$staged_base_file" || {
                rm -f "$staged_base_file" "$extra_file"
                return 1
            }
        fi
        cat "$extra_file" >> "$staged_base_file" || {
            rm -f "$staged_base_file" "$extra_file"
            return 1
        }
    fi
    rm -f "$extra_file"
    chmod 600 "$staged_base_file" || { rm -f "$staged_base_file"; return 1; }
    publish_subscriptions_locked "$staged_base_file" || {
        publish_status=$?
        rm -f "$staged_base_file"
        return "$publish_status"
    }
}

publish_generated_base() {
    with_subscription_lock publish_generated_base_locked "$@"
}

mutate_base_subscription_locked() {
    local mutation_callback="${1:-}"
    local staged_base_file mutation_status=0
    shift || return 1

    [ "${SUBSCRIPTION_LOCK_HELD:-0}" = 1 ] || return 1
    [ -n "$mutation_callback" ] || return 1
    [ -f "$client_dir" ] && [ ! -L "$client_dir" ] || return 1
    staged_base_file=$(mktemp "$(dirname "$client_dir")/.tmp.$(basename "$client_dir").mutation.XXXXXX") || return 1
    cp -p -- "$client_dir" "$staged_base_file" || { rm -f "$staged_base_file"; return 1; }
    chmod 600 "$staged_base_file" || { rm -f "$staged_base_file"; return 1; }

    "$mutation_callback" "$staged_base_file" "$@" || mutation_status=$?
    if [ "$mutation_status" -ne 0 ] || [ ! -f "$staged_base_file" ] || [ -L "$staged_base_file" ]; then
        rm -f "$staged_base_file"
        [ "$mutation_status" -ne 0 ] && return "$mutation_status"
        return 1
    fi
    chmod 600 "$staged_base_file" || { rm -f "$staged_base_file"; return 1; }
    publish_subscriptions_locked "$staged_base_file" || {
        mutation_status=$?
        rm -f "$staged_base_file"
        return "$mutation_status"
    }
}

mutate_base_subscription() {
    with_subscription_lock mutate_base_subscription_locked "$@"
}

sed_base_subscription_file() {
    local staged_base_file="$1"
    shift
    sed "$@" "$staged_base_file"
}

update_subscription_uuid_file() {
    local staged_base_file="$1"
    local new_uuid="$2"

    sed -i -E 's/(vless:\/\/|hysteria2:\/\/|anytls:\/\/)[^@]*(@.*)/\1'"$new_uuid"'\2/' "$staged_base_file" &&
        sed -i -E "s#tuic://[0-9a-f-]{36}:[0-9a-f-]{36}@#tuic://$new_uuid:$new_uuid@#g" "$staged_base_file"
}

append_base_subscription_url_file() {
    local staged_base_file="$1"
    local url_line="$2"

    printf '\n%s\n' "$url_line" >> "$staged_base_file"
}

append_base_subscription_url() {
    mutate_base_subscription append_base_subscription_url_file "$1"
}

remove_url_by_tag_file() {
    local staged_base_file="$1"
    local tag="$2"
    local tmp_file

    [[ "$tag" =~ ^[A-Za-z][A-Za-z0-9+.-]*$ ]] || return 1
    [ -f "$staged_base_file" ] && [ ! -L "$staged_base_file" ] || return 1
    tmp_file=$(mktemp "$(dirname "$staged_base_file")/.tmp.$(basename "$staged_base_file").remove-url.XXXXXX") || return 1
    if ! awk -v prefix="${tag}://" '
            NF && index($0, prefix) != 1 { print }
        ' "$staged_base_file" > "$tmp_file" ||
       ! chmod 600 "$tmp_file" ||
       ! mv -f -- "$tmp_file" "$staged_base_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi
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
    local backup_parent backup_dir path index
    local -a files=("$inbounds_file")

    EXTRA_PROTOCOL_BACKUP_DIR=''
    [ -n "$inbounds_file" ] && [ -f "$inbounds_file" ] && [ ! -L "$inbounds_file" ] || return 1
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
    local path parent name tmp_file index
    local -a files=("$inbounds_file")

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
    local publisher_unresolved=0
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
    if [ "$transaction_status" -eq 0 ]; then
        durable_transaction_checkpoint config-mutated || transaction_status=2
    fi
    [ "$transaction_status" -ne 0 ] || \
        commit_extra_protocol_service_state "$was_active" || transaction_status=$?
    if [ "$transaction_status" -eq 0 ]; then
        durable_transaction_checkpoint publishing || transaction_status=2
    fi
    if [ "$transaction_status" -eq 0 ]; then
        append_base_subscription_url "$client_line" || transaction_status=$?
        [ "$transaction_status" -ne 2 ] || publisher_unresolved=1
    fi
    if [ "$transaction_status" -ne 0 ]; then
        handle_extra_protocol_transaction_failure "$backup_dir" "$inbounds_file" "$was_active" \
            "$transaction_status" "$publisher_unresolved" \
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
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "额外协议添加"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _add_extra_protocol_transaction_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
}

_remove_extra_protocol_transaction_locked() {
    local inbounds_file="${1:-}"
    local url_scheme="${2:-}"
    local mutation_callback="${3:-}"
    shift 3 || return 1
    local delimiter_seen=0 backup_dir was_active=0 cleanup_status=0 transaction_status=0
    local publisher_unresolved=0
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
    if [ "$transaction_status" -eq 0 ]; then
        durable_transaction_checkpoint config-mutated || transaction_status=2
    fi
    [ "$transaction_status" -ne 0 ] || \
        commit_extra_protocol_service_state "$was_active" || transaction_status=$?
    if [ "$transaction_status" -eq 0 ]; then
        durable_transaction_checkpoint publishing || transaction_status=2
    fi
    if [ "$transaction_status" -eq 0 ]; then
        remove_url_by_tag "$url_scheme" || transaction_status=$?
        [ "$transaction_status" -ne 2 ] || publisher_unresolved=1
    fi
    if [ "$transaction_status" -ne 0 ]; then
        handle_extra_protocol_transaction_failure "$backup_dir" "$inbounds_file" "$was_active" \
            "$transaction_status" "$publisher_unresolved" \
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
        disarm_durable_transaction keep >/dev/null 2>&1 || true
        if [ "$cleanup_status" -eq 2 ]; then
            red "额外协议已删除，但防火墙清理状态未决；恢复证据已保留：${EXTRA_PROTOCOL_RECOVERY_PATH:-$backup_dir}"
            return 2
        fi
        yellow "额外协议已删除，但旧防火墙规则未能完全清理；恢复证据已保留：${EXTRA_PROTOCOL_RECOVERY_PATH:-$backup_dir}"
        return 3
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
    local status=0

    acquire_proxy_transaction_lock_checked "${conf_dir}" "额外协议删除"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    _remove_extra_protocol_transaction_locked "$@" || status=$?
    finish_transaction_release "$status" release_proxy_transaction_lock
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

# 独立 cfy 模块的安全安装与前台调用。cfy 保留自己的代码、命令和更新周期；
# 此处只提供入口，不复制节点生成逻辑，也不触碰 sing-box 服务配置。
cfy_executable_path() {
    printf '%s\n' "${SB_CFY_EXECUTABLE:-/usr/local/bin/cfy}"
}

cfy_download_url() {
    printf '%s\n' "${SB_CFY_DOWNLOAD_URL:-https://raw.githubusercontent.com/Pretic/Pre-cfy/80231df35f6a0cca9bf5f7b44d89bc3cf08c855a/cfy.sh}"
}

cfy_expected_download_sha256() {
    printf '%s\n' "${SB_CFY_DOWNLOAD_SHA256:-65363e470bcab5b7bbefd12b4c78322370e3f17870988f6531099437aeaf322e}"
}

validate_cfy_target_path() {
    local target="${1:-}"

    [ -n "$target" ] && [[ "$target" == /* ]] && [ "$target" != / ] && \
        [[ "$target" != */ ]] && [[ "$target" != *'//'* ]] && \
        [[ "$target" != *$'\n'* && "$target" != *$'\r'* ]] || return 1
    case "/${target#/}/" in
        */../*|*/./*) return 1 ;;
    esac
}

validate_cfy_script() {
    local script_file="${1:-}"

    [ -n "$script_file" ] && [ -f "$script_file" ] && [ ! -L "$script_file" ] && \
        [ -s "$script_file" ] && [ -r "$script_file" ] || return 1
    bash -n "$script_file" >/dev/null 2>&1 || return 1
    grep -Fq 'CFY_SOURCE_GENERATION_FILE=' "$script_file" && \
        grep -Fq 'ensure_stable_transaction_root()' "$script_file" && \
        grep -Fq 'with_subscription_lock()' "$script_file" && \
        grep -Fq 'publish_subscriptions_locked()' "$script_file"
}

validate_cfy_executable() {
    local executable="${1:-}"

    [ -n "$executable" ] && [ -f "$executable" ] && [ ! -L "$executable" ] && \
        [ -x "$executable" ]
}

install_cfy() {
    local target target_dir download_url expected_sha actual_sha
    local connect_timeout="${SB_CFY_CONNECT_TIMEOUT:-10}"
    local max_time="${SB_CFY_MAX_TIME:-30}"
    local tmp_file=''

    target=$(cfy_executable_path) || return 1
    download_url=$(cfy_download_url) || return 1
    expected_sha=$(cfy_expected_download_sha256) || return 1

    validate_cfy_target_path "$target" || {
        red "cfy 安装路径无效。"
        return 1
    }
    if [ -e "$target" ] || [ -L "$target" ]; then
        validate_cfy_executable "$target" && return 0
        red "已存在的 cfy 不是兼容的普通可执行文件，未覆盖：${target}"
        return 1
    fi

    target_dir=$(dirname -- "$target") || return 1
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] && [ -w "$target_dir" ] || {
        red "cfy 安装目录不存在或不可安全写入：${target_dir}"
        return 1
    }
    [[ "$download_url" =~ ^https://[^[:space:]]+$ ]] || {
        red "cfy 下载地址必须是有效的 HTTPS 地址。"
        return 1
    }
    [[ "$expected_sha" =~ ^[0-9A-Fa-f]{64}$ ]] || {
        red "cfy 下载校验值无效。"
        return 1
    }
    [[ "$connect_timeout" =~ ^[0-9]+$ ]] && [ "$connect_timeout" -ge 1 ] && \
        [ "$connect_timeout" -le 120 ] && \
        [[ "$max_time" =~ ^[0-9]+$ ]] && [ "$max_time" -ge "$connect_timeout" ] && \
        [ "$max_time" -le 600 ] || {
        red "cfy 下载超时设置无效。"
        return 1
    }
    command -v curl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 && \
        command -v mktemp >/dev/null 2>&1 && command -v ln >/dev/null 2>&1 || {
        red "安全安装 cfy 需要 curl、sha256sum、mktemp 和 ln。"
        return 1
    }

    tmp_file=$(mktemp "${target_dir}/.cfy.install.XXXXXX") || return 1
    if ! curl -fsSL --connect-timeout "$connect_timeout" --max-time "$max_time" \
        -o "$tmp_file" "$download_url"; then
        rm -f -- "$tmp_file"
        red "cfy 下载失败，现有节点和服务未修改。"
        return 1
    fi
    if [ ! -s "$tmp_file" ]; then
        rm -f -- "$tmp_file"
        red "cfy 下载内容为空，已取消安装。"
        return 1
    fi
    actual_sha=$(sha256sum -- "$tmp_file" 2>/dev/null) || {
        rm -f -- "$tmp_file"
        return 1
    }
    actual_sha=${actual_sha%%[[:space:]]*}
    if [ "${actual_sha,,}" != "${expected_sha,,}" ]; then
        rm -f -- "$tmp_file"
        red "cfy 下载校验失败，已取消安装。"
        return 1
    fi
    if ! validate_cfy_script "$tmp_file" || ! chmod 755 "$tmp_file"; then
        rm -f -- "$tmp_file"
        red "cfy 内容或权限校验失败，已取消安装。"
        return 1
    fi

    # 同目录硬链接加 -T，目标即使在下载后竞态变成目录或目录符号链接，
    # 也只会失败而不会跟随目录发布，且仍保留 no-clobber 语义。
    if ! ln -T -- "$tmp_file" "$target" 2>/dev/null; then
        rm -f -- "$tmp_file"
        red "cfy 安装目标已变化，未覆盖任何文件，请重试。"
        return 1
    fi
    if ! rm -f -- "$tmp_file"; then
        red "cfy 已安装，但临时文件清理失败：${tmp_file}"
        return 2
    fi
    validate_cfy_executable "$target" || {
        red "cfy 安装后校验失败，请手动检查：${target}"
        return 2
    }
    green "cfy 已安全安装到 ${target}。"
}

run_cfy_existing() {
    local executable

    executable=$(cfy_executable_path) || return 1
    validate_cfy_target_path "$executable" || {
        red "cfy 可执行文件路径无效。"
        return 1
    }
    validate_cfy_executable "$executable" || {
        red "未找到兼容的 cfy，请先选择菜单项 1 运行 cfy 节点优选并完成安装。"
        return 1
    }
    "$executable" "$@"
}

run_cfy() {
    local executable

    executable=$(cfy_executable_path) || return 1
    validate_cfy_target_path "$executable" || {
        red "cfy 可执行文件路径无效。"
        return 1
    }
    if [ ! -e "$executable" ] && [ ! -L "$executable" ]; then
        yellow "尚未安装 cfy，正在进行安全下载安装..."
        install_cfy || return $?
    fi
    run_cfy_existing
}

manage_cfy() {
    local cfy_choice status
    # shellcheck disable=SC2034 # reading() 通过变量名动态写入该暂停占位符。
    local cfy_pause

    while true; do
        clear; echo ""
        green "=== Cloudflare优选 ===\n"
        green "1. 运行 cfy 节点优选"
        green "2. 查看最近一次优选结果（cfy -c）"
        green "3. 更新 cfy（cfy --update）"
        purple "4. 返回 sb 主菜单"
        echo "==============="
        if ! reading "请输入选择: " cfy_choice; then
            return 0
        fi
        echo ""
        case "$cfy_choice" in
            1)
                if run_cfy; then status=0; else status=$?; fi
                [ "$status" -eq 0 ] || yellow "cfy 已退出（状态 ${status}），sing-box 服务和已有节点未修改。"
                ;;
            2)
                if run_cfy_existing -c; then status=0; else status=$?; fi
                [ "$status" -eq 0 ] || yellow "无法查看 cfy 结果（状态 ${status}）。"
                ;;
            3)
                if run_cfy_existing --update; then status=0; else status=$?; fi
                [ "$status" -eq 0 ] || yellow "cfy 更新失败（状态 ${status}），sing-box 服务不受影响。"
                ;;
            4) return 0 ;;
            *)
                red "无效的选项，请输入 1-4"
                continue
                ;;
        esac
        if ! reading "按回车返回 cfy 菜单..." cfy_pause; then
            return 0
        fi
    done
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
        --cfy) manage_cfy ;;
        -h|--help)
            echo ""
            green "用法: [sb或脚本] [参数], 示例: sb -c(查看节点信息)"
            echo ""
            green "  -i, --install     无交互安装sing-box"
            green "      --update      显式更新本地 sb 管理脚本，不修改已有节点"
            green "  -c, --check       查看节点信息和订阅链接"
            green "  -r, --restart     重新获取argo临时隧道并更新到订阅"
            green "      --cfy         进入 Cloudflare优选 菜单"
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
    case "$warp_status" in
        running) warp_status=$(green "$warp_status") ;;
        degraded) warp_status=$(yellow "$warp_status") ;;
        *) warp_status=$(red "$warp_status") ;;
    esac

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
    purple "11. Cloudflare优选"
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
            reading "请输入选择(0-11): " choice
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
                7)  disable_open_sub;   need_pause=false ;;
                8)  warp_manage;        need_pause=false ;;
                9)  manage_protocols;   need_pause=false ;;
                10)
                    clear
                    bash <(curl -Ls ssh_tool.eooce.com)
                    need_pause=false
                    ;;
                11) manage_cfy; need_pause=false ;;
                0)  exit 0 ;;
                *)
                    red "无效的选项，请输入 0-11"
                    need_pause=true
                    ;;
            esac
            [ "$need_pause" = true ] && read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
    done
fi
