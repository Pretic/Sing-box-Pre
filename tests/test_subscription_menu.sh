#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

for item in \
    '5. 查看订阅链接与详细状态' \
    '6. 配置 Cloudflare HTTPS 订阅' \
    '7. 关闭 Cloudflare HTTPS 订阅' \
    '8. 重新生成订阅密钥'; do
    grep -Fq "$item" "$script" || {
        echo "FAIL: subscription menu item is missing: $item" >&2
        exit 1
    }
done

menu_source="$(extract_function menu)"
if grep -Fq 'HTTPS 订阅' <<< "$menu_source"; then
    echo 'FAIL: main menu contains detailed HTTPS subscription status' >&2
    exit 1
fi
grep -Fq -- '--Nginx 状态:' <<< "$menu_source"

argo_source="$(extract_function manage_argo)"
grep -Fq '是否同时配置 Cloudflare HTTPS 订阅？[y/N]' <<< "$argo_source" || {
    echo 'FAIL: fixed Tunnel flow does not offer the optional HTTPS subscription setup' >&2
    exit 1
}
grep -Fq 'configure_cf_https_subscription' <<< "$argo_source"
grep -Fq 'transition_to_quick_argo' <<< "$argo_source" || {
    echo 'FAIL: switching to a quick Tunnel bypasses the transaction helper' >&2
    exit 1
}
quick_transition_source="$(extract_function transition_to_quick_argo)"
grep -Fq 'disable_cf_https_subscription' <<< "$quick_transition_source" || {
    echo 'FAIL: quick Tunnel transaction does not remove the active HTTPS route' >&2
    exit 1
}
grep -Fq '原服务、凭据、订阅与 HTTPS 状态已恢复' <<< "$argo_source" && \
grep -Fq '自动回滚不完整' <<< "$argo_source" || {
    echo 'FAIL: switching to a quick Tunnel does not distinguish complete and incomplete rollback' >&2
    exit 1
}

subscription_menu_source="$(extract_function disable_open_sub)"
grep -Fq 'change_subscription_port_transaction' <<< "$subscription_menu_source" || {
    echo 'FAIL: changing the Nginx subscription port does not use the full transaction helper' >&2
    exit 1
}

for function_name in \
    verify_https_subscription \
    print_manual_https_route \
    configure_cf_https_subscription \
    disable_cf_https_subscription \
    rotate_subscription_token \
    show_subscription_status \
    update_cf_https_subscription_origin \
    apply_local_tunnel_subscription_removal \
    remove_remote_tunnel_subscription_via_api; do
    [[ -n "$(extract_function "$function_name")" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for function_name in \
    restore_subscription_port_snapshot \
    rollback_subscription_port_transaction \
    rollback_subscription_port_signal_transaction \
    reset_durable_transaction_state \
    assert_no_pending_durable_transaction \
    write_durable_transaction_registry \
    cleanup_durable_transaction_registry \
    write_durable_transaction_manifest \
    restore_durable_transaction_traps \
    arm_durable_transaction \
    durable_transaction_checkpoint \
    durable_transaction_set_owned_records \
    durable_transaction_trap_handler \
    disarm_durable_transaction \
    acquire_proxy_transaction_lock_checked \
    _change_subscription_port_transaction_locked \
    change_subscription_port_transaction; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
    source <(printf '%s\n' "$function_source")
done

port_tx_dir="${tmp_dir}/port-transaction"
mkdir -p "$port_tx_dir"
port_tx_config="${port_tx_dir}/sing-box.conf"
port_tx_log="${port_tx_dir}/calls.log"
conf_dir="${port_tx_dir}/conf"
mkdir -p "$conf_dir"
printf '%s\n' '{"inbounds":[]}' > "${conf_dir}/inbounds.json"
NGINX_SUBSCRIPTION_CONF="$port_tx_config"
FIREWALL_LAST_ADDED_RECORDS=()
ALLOW_STATUS=0
APPLY_FAIL=0
ORIGIN_FAIL_NEW=0
REMOVE_EXACT_FAIL=0
REMOVE_OLD_FAIL=0
CONFIGURED_CONSUMER_STATUS=1
LISTENER_OCCUPIED=0
NGINX_ACTIVE=1
LOCK_REWRITE_OLD_PORT=''
LOCK_REWRITE_HTTP_PATH=''
LOCK_REWRITE_HTTPS_PATH=''
RM_BACKUP_FAIL=0
BACKUP_MODE_OK=1
SUBSCRIPTION_PORT_RECOVERY_PATH=''
DURABLE_HOOK_LOG=0
DURABLE_SIGNAL_STAGE=''

reset_port_transaction() {
    command rm -f -- "${conf_dir}/.durable-transaction.pending"
    find "$port_tx_dir" -maxdepth 1 -type d -name '.durable-transaction.*' -exec rm -rf -- {} + 2>/dev/null || true
    write_managed_port_config 21000 /http-token /https-token
    : > "$port_tx_log"
    FIREWALL_LAST_ADDED_RECORDS=()
    ALLOW_STATUS=0
    APPLY_FAIL=0
    ORIGIN_FAIL_NEW=0
    REMOVE_EXACT_FAIL=0
    REMOVE_OLD_FAIL=0
    CONFIGURED_CONSUMER_STATUS=1
    LISTENER_OCCUPIED=0
    NGINX_ACTIVE=1
    LOCK_REWRITE_OLD_PORT=''
    LOCK_REWRITE_HTTP_PATH=''
    LOCK_REWRITE_HTTPS_PATH=''
    RM_BACKUP_FAIL=0
    BACKUP_MODE_OK=1
    SUBSCRIPTION_PORT_RECOVERY_PATH=''
    DURABLE_HOOK_LOG=0
    DURABLE_SIGNAL_STAGE=''
    reset_durable_transaction_state
}

write_managed_port_config() {
    local port="$1" http_path="$2" https_path="${3:-}"
    {
        printf '# managed-test\nlisten %s;\n' "$port"
        printf 'location = %s { alias /etc/sing-box/sub.txt; }\n' "$http_path"
        [ -z "$https_path" ] || \
            printf 'location = %s { alias /etc/sing-box/sub.txt; }\n' "$https_path"
    } > "$port_tx_config"
}

validate_port_value() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
is_valid_http_subscription_path() { [[ "${1:-}" == /* && "${1:-}" != *[[:space:]]* ]]; }
get_nginx_subscription_port() { sed -n 's/^listen \([0-9][0-9]*\);/\1/p' "$1"; }
get_nginx_subscription_paths() {
    sed -n 's/^location = \(\/[^ ]*\) .*/\1/p' "$1"
}
classify_nginx_subscription_config() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 2
    grep -Fqx '# managed-test' "$1" || return 2
    [ -n "$(get_nginx_subscription_port "$1")" ] || return 2
    [ -n "$(get_nginx_subscription_paths "$1")" ] || return 2
}
validate_managed_subscription_runtime() {
    classify_nginx_subscription_config "$1"
}
allow_port() {
    printf 'allow:%s\n' "$1" >> "$port_tx_log"
    [ "$ALLOW_STATUS" -eq 0 ] || return "$ALLOW_STATUS"
    FIREWALL_LAST_ADDED_RECORDS=('ufw|4|22000|tcp')
}
apply_nginx_subscription_config() {
    local backup_candidate
    printf 'apply:%s:%s\n' "$1" "${4:-missing}" >> "$port_tx_log"
    backup_candidate=$(find "$(dirname "$port_tx_config")" -maxdepth 1 -name '.subscription-port-backup.*' -print -quit)
    if [ -n "$backup_candidate" ] && [ "$(stat -c '%a' "$backup_candidate")" != 600 ]; then
        BACKUP_MODE_OK=0
    fi
    [ "$APPLY_FAIL" -eq 0 ] || return 1
    write_managed_port_config "$1" "$2" "${3:-}"
}
nginx_service_is_active() { [ "$NGINX_ACTIVE" -eq 1 ]; }
stop_nginx_checked() {
    printf 'stop-nginx\n' >> "$port_tx_log"
    NGINX_ACTIVE=0
}
update_cf_https_subscription_origin() {
    printf 'origin:%s:%s\n' "$1" "${2:-1}" >> "$port_tx_log"
    if [ "$ORIGIN_FAIL_NEW" -eq 1 ] && [ "$1" = 22000 ]; then
        return 1
    fi
}
remove_owned_firewall_records_exact() {
    printf 'remove-exact:%s\n' "$1" >> "$port_tx_log"
    [ "$REMOVE_EXACT_FAIL" -eq 0 ]
}
remove_owned_firewall_ports_if_unused() {
    printf 'remove-old:%s\n' "$*" >> "$port_tx_log"
    [ "$REMOVE_OLD_FAIL" -eq 0 ]
}
configured_inbound_port_conflict_exists() {
    printf 'consumer:%s/%s:any\n' "$2" "$3" >> "$port_tx_log"
    return "$CONFIGURED_CONSUMER_STATUS"
}
port_is_listening() {
    printf 'listen-check:%s/%s\n' "$1" "$2" >> "$port_tx_log"
    [ "$LISTENER_OCCUPIED" -eq 1 ]
}
nginx() {
    printf 'nginx:%s\n' "$*" >> "$port_tx_log"
    if [ "${1:-}" = -s ] && [ "${2:-}" = reload ]; then
        [ "$NGINX_ACTIVE" -eq 1 ]
    fi
}
restart_nginx() {
    printf 'restart-nginx\n' >> "$port_tx_log"
    NGINX_ACTIVE=1
}
red() { :; }
acquire_proxy_transaction_lock() {
    printf 'lock\n' >> "$port_tx_log"
    if [ -n "$LOCK_REWRITE_OLD_PORT" ]; then
        write_managed_port_config "$LOCK_REWRITE_OLD_PORT" \
            "${LOCK_REWRITE_HTTP_PATH:-/http-token}" \
            "${LOCK_REWRITE_HTTPS_PATH:-/https-token}"
    fi
}
release_proxy_transaction_lock() { printf 'unlock\n' >> "$port_tx_log"; }
durable_transaction_hook() {
    if [ -n "$DURABLE_SIGNAL_STAGE" ] && [ "$DURABLE_SIGNAL_STAGE" = "$1" ]; then
        kill -TERM "$BASHPID"
    fi
    [ "$DURABLE_HOOK_LOG" -eq 1 ] || return 0
    printf 'durable:%s\n' "$1" >> "$port_tx_log"
}
rm() {
    if [ "$RM_BACKUP_FAIL" -eq 1 ] && printf '%s\n' "$*" | grep -q '.subscription-port-backup.'; then
        return 1
    fi
    command rm "$@"
}

reset_port_transaction
change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token || {
    echo 'FAIL: subscription port transaction did not commit' >&2
    exit 1
}
[[ "$(get_nginx_subscription_port "$port_tx_config")" == 22000 ]] || {
    echo 'FAIL: committed subscription config kept the old port' >&2
    exit 1
}
[[ "$BACKUP_MODE_OK" -eq 1 ]] || {
    echo 'FAIL: subscription backup containing secret paths was not mode 0600' >&2
    exit 1
}
expected_port_order=$'lock\nconsumer:22000/tcp:any\nlisten-check:22000/tcp\nallow:22000/tcp\napply:22000:1\norigin:22000:1\nremove-old:'"${conf_dir}/inbounds.json --nginx-config ${port_tx_config} 21000/tcp"$'\nunlock'
[[ "$(cat "$port_tx_log")" == "$expected_port_order" ]] || {
    echo 'FAIL: subscription port transaction order is unsafe' >&2
    exit 1
}

reset_port_transaction
DURABLE_HOOK_LOG=1
change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token || {
    echo 'FAIL: durable subscription port transaction did not commit' >&2
    exit 1
}
subscription_durable_stages="$(grep '^durable:' "$port_tx_log")"
[[ "$subscription_durable_stages" == $'durable:firewall-mutating\ndurable:precommit\ndurable:config-mutated\ndurable:publishing\ndurable:committed' ]] || {
    echo "FAIL: subscription durable checkpoints are incomplete: ${subscription_durable_stages}" >&2
    exit 1
}

reset_port_transaction
DURABLE_SIGNAL_STAGE=publishing
publishing_status=0
( trap - EXIT; change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token ) || \
    publishing_status=$?
[[ "$publishing_status" -eq 2 ]] || {
    echo "FAIL: publishing-boundary TERM returned ${publishing_status}, expected unresolved rc 2" >&2
    exit 1
}
[[ "$(get_nginx_subscription_port "$port_tx_config")" == 22000 ]] || {
    echo 'FAIL: publishing-boundary TERM falsely rolled back a possibly published config' >&2
    exit 1
}
if grep -q '^origin:' "$port_tx_log"; then
    echo 'FAIL: publishing checkpoint TERM reached the Tunnel origin call' >&2
    exit 1
fi
publishing_evidence=$(find "$port_tx_dir" -maxdepth 1 -type d -name '.durable-transaction.*' -print -quit)
[[ -n "$publishing_evidence" && -f "$publishing_evidence/manifest" ]] || {
    echo 'FAIL: publishing-boundary TERM did not preserve durable evidence' >&2
    exit 1
}

reset_port_transaction
LOCK_REWRITE_OLD_PORT=21500
LOCK_REWRITE_HTTP_PATH=/rotated-http-token
LOCK_REWRITE_HTTPS_PATH=/rotated-https-token
change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token || {
    echo 'FAIL: lock-time state-change subscription transaction did not commit' >&2
    exit 1
}
grep -Fq "remove-old:${conf_dir}/inbounds.json --nginx-config ${port_tx_config} 21500/tcp" "$port_tx_log" || {
    echo 'FAIL: subscription transaction used an old port read before the config lock' >&2
    exit 1
}
[[ "$(get_nginx_subscription_paths "$port_tx_config")" == $'/rotated-http-token\n/rotated-https-token' ]] || {
    echo 'FAIL: subscription port transaction resurrected pre-lock subscription paths' >&2
    exit 1
}

reset_port_transaction
cat > "$port_tx_config" <<'EOF'
server {
    listen 21000;
    location = /custom-token { alias /srv/custom-sub.txt; }
}
EOF
unmanaged_hash="$(sha256sum "$port_tx_config")"
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    echo 'FAIL: parseable unmanaged Nginx config was overwritten by port change' >&2
    exit 1
fi
[[ "$(sha256sum "$port_tx_config")" == "$unmanaged_hash" ]] || {
    echo 'FAIL: rejected unmanaged Nginx config changed on disk' >&2
    exit 1
}
if grep -q '^allow:' "$port_tx_log"; then
    echo 'FAIL: firewall mutated before unmanaged Nginx config rejection' >&2
    exit 1
fi

reset_port_transaction
NGINX_ACTIVE=0
change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token || {
    echo 'FAIL: inactive-Nginx subscription port transaction did not commit' >&2
    exit 1
}
[[ "$NGINX_ACTIVE" -eq 0 ]] || {
    echo 'FAIL: successful port change started an initially inactive Nginx service' >&2
    exit 1
}
grep -Fqx 'apply:22000:0' "$port_tx_log" || {
    echo 'FAIL: inactive Nginx state was not passed to config apply' >&2
    exit 1
}
grep -Fqx 'origin:22000:0' "$port_tx_log" || {
    echo 'FAIL: inactive HTTPS origin update did not disable live verification' >&2
    exit 1
}
if grep -Eq '^(restart-nginx|stop-nginx)$' "$port_tx_log"; then
    echo 'FAIL: inactive success path changed Nginx service state' >&2
    exit 1
fi

reset_port_transaction
CONFIGURED_CONSUMER_STATUS=0
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    echo 'FAIL: configured but inactive sing-box port conflict was accepted' >&2
    exit 1
fi
grep -Fqx 'consumer:22000/tcp:any' "$port_tx_log" || {
    echo 'FAIL: configured sing-box conflict was not checked' >&2
    exit 1
}
if grep -q '^allow:' "$port_tx_log"; then
    echo 'FAIL: firewall changed after configured-port conflict' >&2
    exit 1
fi

reset_port_transaction
CONFIGURED_CONSUMER_STATUS=2
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    conflict_status=0
else
    conflict_status=$?
fi
[[ "$conflict_status" -eq 2 ]] || {
    echo 'FAIL: configured-port query error was not propagated as fatal' >&2
    exit 1
}

reset_port_transaction
LISTENER_OCCUPIED=1
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    echo 'FAIL: live listener conflict was accepted' >&2
    exit 1
fi
if grep -q '^allow:' "$port_tx_log"; then
    echo 'FAIL: firewall changed after live-listener conflict' >&2
    exit 1
fi

reset_port_transaction
ALLOW_STATUS=2
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    port_status=0
else
    port_status=$?
fi
[[ "$port_status" -eq 2 ]] || { echo 'FAIL: fatal firewall status was not propagated' >&2; exit 1; }
[[ -d "$SUBSCRIPTION_PORT_RECOVERY_PATH" ]] || {
    echo 'FAIL: fatal firewall status discarded its durable recovery evidence' >&2
    exit 1
}
grep -Fqx 'allow:22000/tcp' "$port_tx_log" || { echo 'FAIL: firewall was not attempted first' >&2; exit 1; }
if grep -q '^apply:' "$port_tx_log"; then
    echo 'FAIL: Nginx changed after firewall failure' >&2
    exit 1
fi

reset_port_transaction
APPLY_FAIL=1
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    echo 'FAIL: failed Nginx apply was reported as success' >&2
    exit 1
fi
[[ "$(get_nginx_subscription_port "$port_tx_config")" == 21000 ]] || {
    echo 'FAIL: Nginx apply failure did not restore the old port' >&2
    exit 1
}
grep -Fq 'remove-exact:ufw|4|22000|tcp' "$port_tx_log" || {
    echo 'FAIL: Nginx apply failure leaked the new firewall ownership token' >&2
    exit 1
}

reset_port_transaction
ORIGIN_FAIL_NEW=1
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    echo 'FAIL: Tunnel origin failure was reported as success' >&2
    exit 1
fi
[[ "$(get_nginx_subscription_port "$port_tx_config")" == 21000 ]] || {
    echo 'FAIL: Tunnel origin failure did not restore Nginx' >&2
    exit 1
}
grep -Fq 'origin:21000:1' "$port_tx_log" || {
    echo 'FAIL: Tunnel origin rollback did not restore the old origin' >&2
    exit 1
}
grep -Fq 'remove-exact:ufw|4|22000|tcp' "$port_tx_log" || {
    echo 'FAIL: Tunnel origin failure leaked the new firewall ownership token' >&2
    exit 1
}

reset_port_transaction
APPLY_FAIL=1
REMOVE_EXACT_FAIL=1
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    fatal_port_status=0
else
    fatal_port_status=$?
fi
[[ "$fatal_port_status" -eq 2 && -d "$SUBSCRIPTION_PORT_RECOVERY_PATH" ]] || {
    echo 'FAIL: incomplete subscription rollback did not return 2 with recovery evidence' >&2
    exit 1
}

reset_port_transaction
REMOVE_OLD_FAIL=1
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    fatal_port_status=0
else
    fatal_port_status=$?
fi
[[ "$fatal_port_status" -eq 2 && -d "$SUBSCRIPTION_PORT_RECOVERY_PATH" ]] || {
    echo 'FAIL: committed port with failed old-rule cleanup did not preserve recovery evidence' >&2
    exit 1
}
[[ "$(get_nginx_subscription_port "$port_tx_config")" == 22000 ]] || {
    echo 'FAIL: old-rule cleanup failure incorrectly rolled back the working new port' >&2
    exit 1
}

reset_port_transaction
RM_BACKUP_FAIL=1
if change_subscription_port_transaction "$port_tx_config" 22000 /http-token /https-token; then
    cleanup_status=0
else
    cleanup_status=$?
fi
[[ "$cleanup_status" -eq 3 && -d "$SUBSCRIPTION_PORT_RECOVERY_PATH" ]] || {
    echo 'FAIL: committed port with backup cleanup residue did not return 3 with its path' >&2
    exit 1
}
[[ "$(get_nginx_subscription_port "$port_tx_config")" == 22000 ]] || {
    echo 'FAIL: backup cleanup residue incorrectly rolled back a healthy port change' >&2
    exit 1
}
RM_BACKUP_FAIL=0

for function_name in \
    render_nginx_subscription_location \
    render_nginx_subscription_server \
    get_nginx_subscription_port \
    get_nginx_subscription_paths \
    classify_nginx_subscription_config \
    backup_subscription_frontend_snapshot \
    subscription_frontend_snapshot_file_digest \
    verify_subscription_frontend_snapshot_baseline \
    cleanup_subscription_frontend_snapshot \
    restore_subscription_frontend_snapshot \
    rollback_subscription_frontend_signal_transaction \
    prepare_subscription_frontend_state_transaction \
    commit_subscription_frontend_state_transaction \
    _stop_subscription_service_locked \
    _start_subscription_service_locked; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
    source <(printf '%s\n' "$function_source")
done

start_tx_dir="${tmp_dir}/subscription-start"
mkdir -p "${start_tx_dir}/conf"
start_tx_config="${start_tx_dir}/sing-box.conf"
start_tx_log="${start_tx_dir}/calls.log"
conf_dir="${start_tx_dir}/conf"
subscription_state_file="${start_tx_dir}/subscription.state"
NGINX_SUBSCRIPTION_CONF="$start_tx_config"
purple=''
re=''
START_INPUT_PORT=24000
START_NGINX_ACTIVE=0
START_ALLOW_STATUS=0
START_APPLY_FAIL=0
START_SAVE_FAIL=0
START_URL_FAIL=0
START_STOP_FAIL=0
FIREWALL_LAST_ADDED_RECORDS=()

reset_start_transaction() {
    command rm -f -- "$start_tx_config" "$subscription_state_file"
    find "$conf_dir" -maxdepth 1 -type d -name '.subscription-create.*' -exec rm -rf -- {} +
    : > "$start_tx_log"
    START_INPUT_PORT=24000
    START_NGINX_ACTIVE=0
    START_ALLOW_STATUS=0
    START_APPLY_FAIL=0
    START_SAVE_FAIL=0
    START_URL_FAIL=0
    START_STOP_FAIL=0
    FIREWALL_LAST_ADDED_RECORDS=()
    SUBSCRIPTION_CREATE_RECOVERY_PATH=''
}

is_valid_http_subscription_path() {
    [[ "${1:-}" == /* && "${1:-}" != *[[:space:]]* ]]
}
is_valid_subscription_path() { is_valid_http_subscription_path "$1"; }
ipv6_socket_available() { return 1; }
get_subscription_host() { printf '%s\n' 'subscription.example.test'; }
generate_subscription_token() { printf '%s\n' '0123456789abcdefghjkmnpqrstvwxyz'; }
reading() { printf -v "$2" '%s' "$START_INPUT_PORT"; }
validate_port_value() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
configured_inbound_port_conflict_exists() {
    printf 'configured-conflict:%s/%s\n' "$2" "$3" >> "$start_tx_log"
    return 1
}
port_is_listening() {
    printf 'listen-check:%s/%s\n' "$1" "$2" >> "$start_tx_log"
    return 1
}
allow_port() {
    printf 'allow:%s\n' "$1" >> "$start_tx_log"
    [ "$START_ALLOW_STATUS" -eq 0 ] || return "$START_ALLOW_STATUS"
    FIREWALL_LAST_ADDED_RECORDS=("raw|4|${1%/*}|${1#*/}")
}
apply_nginx_subscription_config() {
    printf 'apply:%s:%s\n' "$1" "$2" >> "$start_tx_log"
    [ "$START_APPLY_FAIL" -eq 0 ] || return 1
    render_nginx_subscription_server "$1" "$2" "${3:-}" 0 > "$start_tx_config"
    START_NGINX_ACTIVE=1
}
load_subscription_state() { :; }
save_subscription_state() {
    printf 'save-state\n' >> "$start_tx_log"
    [ "$START_SAVE_FAIL" -eq 0 ] || return 1
    printf 'SUB_HTTP_PATH=%q\n' "$SUB_HTTP_PATH" > "$subscription_state_file"
}
build_http_subscription_url() {
    printf 'build-url:%s:%s:%s\n' "$1" "$2" "$3" >> "$start_tx_log"
    [ "$START_URL_FAIL" -eq 0 ] || return 1
    printf 'http://%s:%s%s\n' "$1" "$2" "$3"
}
nginx_service_is_active() { [ "$START_NGINX_ACTIVE" -eq 1 ]; }
start_nginx() {
    printf 'start-nginx\n' >> "$start_tx_log"
    START_NGINX_ACTIVE=1
}
restart_nginx() {
    printf 'restart-nginx\n' >> "$start_tx_log"
    START_NGINX_ACTIVE=1
}
stop_nginx_checked() {
    printf 'stop-nginx\n' >> "$start_tx_log"
    [ "$START_STOP_FAIL" -eq 0 ] || return 1
    START_NGINX_ACTIVE=0
}
remove_owned_firewall_records_exact() {
    printf 'remove-exact:%s\n' "$*" >> "$start_tx_log"
}
command_exists() { [ "$1" = nginx ]; }
green() { :; }
yellow() { :; }
red() { :; }

reset_start_transaction
cat > "$start_tx_config" <<'EOF'
server {
    listen 24000;
    location = /custom-token { alias /srv/custom-sub.txt; }
}
EOF
custom_hash_before="$(sha256sum "$start_tx_config")"
if _start_subscription_service_locked; then
    echo 'FAIL: parseable but unmanaged Nginx config was accepted as a managed subscription' >&2
    exit 1
fi
[[ "$(sha256sum "$start_tx_config")" == "$custom_hash_before" ]] || {
    echo 'FAIL: unmanaged Nginx config was overwritten' >&2
    exit 1
}
[[ ! -s "$start_tx_log" ]] || {
    echo 'FAIL: unmanaged Nginx config caused runtime/firewall mutation' >&2
    exit 1
}

reset_start_transaction
printf 'server { listen 24000; }\n' > "$start_tx_config"
partial_hash_before="$(sha256sum "$start_tx_config")"
if _start_subscription_service_locked; then
    echo 'FAIL: partially parseable Nginx config was treated as absent' >&2
    exit 1
fi
[[ "$(sha256sum "$start_tx_config")" == "$partial_hash_before" ]] || {
    echo 'FAIL: partially parseable Nginx config was overwritten' >&2
    exit 1
}

reset_start_transaction
cat > "$subscription_state_file" <<'EOF'
SUB_HTTPS_ENABLED=1
SUB_HTTPS_DOMAIN=sub.example.test
SUB_HTTPS_PATH=/stale-https-token
SUB_HTTPS_VERIFIED_AT=2026-01-01T00:00:00Z
EOF
stale_state_hash="$(sha256sum "$subscription_state_file")"
if _start_subscription_service_locked; then
    echo 'FAIL: missing Nginx config with stale HTTPS state was silently rebuilt' >&2
    exit 1
fi
[[ "$(sha256sum "$subscription_state_file")" == "$stale_state_hash" && ! -e "$start_tx_config" ]] || {
    echo 'FAIL: inconsistent stale HTTPS state was modified instead of rejected' >&2
    exit 1
}
[[ ! -s "$start_tx_log" ]] || {
    echo 'FAIL: stale HTTPS state caused runtime/firewall mutation' >&2
    exit 1
}

reset_start_transaction
render_nginx_subscription_server 24000 /managed-token '' 0 > "$start_tx_config"
_start_subscription_service_locked || {
    echo 'FAIL: canonical managed Nginx subscription config was rejected' >&2
    exit 1
}
grep -Fqx 'start-nginx' "$start_tx_log" || {
    echo 'FAIL: existing managed subscription service was not started' >&2
    exit 1
}
if grep -q '^allow:' "$start_tx_log"; then
    echo 'FAIL: starting an existing managed subscription opened a new firewall rule' >&2
    exit 1
fi

reset_start_transaction
START_INPUT_PORT=25000
_start_subscription_service_locked || {
    echo 'FAIL: first-time subscription creation transaction did not commit' >&2
    exit 1
}
grep -Fqx 'allow:25000/tcp' "$start_tx_log" || {
    echo 'FAIL: NAT-assigned subscription listen port was not opened' >&2
    exit 1
}
grep -Fqx 'apply:25000:/0123456789abcdefghjkmnpqrstvwxyz' "$start_tx_log" || {
    echo 'FAIL: NAT-assigned subscription listen port was not applied' >&2
    exit 1
}
[[ "$(get_nginx_subscription_port "$start_tx_config")" == 25000 ]] || {
    echo 'FAIL: created subscription config did not retain the requested listen port' >&2
    exit 1
}

reset_start_transaction
START_INPUT_PORT=25001
START_ALLOW_STATUS=1
if _start_subscription_service_locked; then
    echo 'FAIL: subscription creation succeeded after firewall failure' >&2
    exit 1
fi
[[ ! -e "$start_tx_config" ]] || {
    echo 'FAIL: subscription config was created after firewall failure' >&2
    exit 1
}
if grep -q '^apply:' "$start_tx_log"; then
    echo 'FAIL: subscription config apply ran after firewall failure' >&2
    exit 1
fi

reset_start_transaction
START_INPUT_PORT=25002
START_SAVE_FAIL=1
if _start_subscription_service_locked; then
    echo 'FAIL: subscription creation succeeded after state publication failure' >&2
    exit 1
fi
[[ ! -e "$start_tx_config" && ! -e "$subscription_state_file" ]] || {
    echo 'FAIL: state publication failure did not restore absent config/state' >&2
    exit 1
}
[[ "$START_NGINX_ACTIVE" -eq 0 ]] || {
    echo 'FAIL: failed first-time creation left Nginx running' >&2
    exit 1
}
if grep -Fq 'allow:25002/tcp' "$start_tx_log"; then
    grep -Fq 'remove-exact:raw|4|25002|tcp' "$start_tx_log" || {
        echo 'FAIL: failed first-time creation leaked its owned firewall rule' >&2
        exit 1
    }
elif grep -q '^apply:' "$start_tx_log"; then
    echo 'FAIL: state preflight failure mutated Nginx before opening the firewall' >&2
    exit 1
fi

reset_start_transaction
START_NGINX_ACTIVE=1
START_STOP_FAIL=1
systemctl() {
    case "$1" in
        is-active) [ "$START_NGINX_ACTIVE" -eq 1 ] ;;
        stop) printf 'systemctl-stop\n' >> "$start_tx_log"; return 1 ;;
        *) return 1 ;;
    esac
}
if _stop_subscription_service_locked; then
    echo 'FAIL: Nginx stop failure was swallowed' >&2
    exit 1
fi

expected_file="${tmp_dir}/sub.txt"
response_file="${tmp_dir}/response.txt"
mock_curl="${tmp_dir}/curl"
printf '%s' 'c3Vic2NyaXB0aW9uLWNvbnRlbnQ=' > "$expected_file"
printf '%s' 'c3Vic2NyaXB0aW9uLWNvbnRlbnQ=' > "$response_file"

cat > "$mock_curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
cp "$MOCK_HTTPS_RESPONSE" "$output"
MOCK
chmod +x "$mock_curl"

export CURL_BIN="$mock_curl"
export MOCK_HTTPS_RESPONSE="$response_file"
work_dir="$tmp_dir"
SUB_HTTPS_VERIFIED_AT='unchanged'
source <(extract_function verify_https_subscription)

verify_https_subscription 'https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' "$expected_file"
[[ "$SUB_HTTPS_VERIFIED_AT" == unchanged ]]

printf '%s' 'different-content' > "$response_file"
if verify_https_subscription 'https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' "$expected_file"; then
    echo 'FAIL: HTTPS verification accepted mismatched content' >&2
    exit 1
fi
[[ "$SUB_HTTPS_VERIFIED_AT" == unchanged ]]

manual_source="$(extract_function print_manual_https_route)"
grep -Fq 'Hostname:' <<< "$manual_source"
grep -Fq 'Path:' <<< "$manual_source"
grep -Fq 'Type:' <<< "$manual_source"
grep -Fq 'http://localhost:' <<< "$manual_source"

for documentation_item in \
    '## 可选的 Cloudflare HTTPS 订阅' \
    '默认仍生成 HTTP 原始订阅' \
    '用户自己的 Cloudflare 域名' \
    'Cloudflare Tunnel/Connector Write' \
    'DNS Write' \
    '不写入磁盘' \
    'IPv4 单栈' \
    'IPv6 单栈' \
    '关闭节点订阅' \
    '关闭 Cloudflare HTTPS 订阅' \
    '重新生成订阅密钥'; do
    grep -Fq "$documentation_item" "$repo_root/README.md" || {
        echo "FAIL: README does not document: ${documentation_item}" >&2
        exit 1
    }
done

if rg -n 'cfut_|988600\.xyz|sing-box-subscription\.service|sing-box-subscription\.py|subscription-path|localhost:8081' \
    "$script" "$repo_root/README.md"; then
    echo 'FAIL: current private VPS implementation leaked into public runtime files' >&2
    exit 1
fi

echo 'Subscription workflow and menu tests passed.'
