#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
load_function() {
    local source_text
    source_text="$(sed -n "/^${1}() {/,/^}/p" "$script")"
    [[ -n "$source_text" ]] || fail "$1 is not implemented"
    source <(printf '%s\n' "$source_text")
}

for function_name in \
    validate_port_value resolve_service_ports persist_install_settings \
    apply_jq_config update_public_inbound_port get_uniform_inbound_port \
    node_change_snapshot_path node_change_restore_path \
    acquire_node_subscription_lock release_node_subscription_lock \
    publish_node_change_subscription \
    apply_node_change_transaction \
    mutate_public_port_files change_public_port_transaction; do
    load_function "$function_name"
done

red() { printf '%s\n' "$*" >&2; }
yellow() { :; }
green() { :; }
atomic_write_file() {
    local target="$1" mode="$2" tmp
    tmp="${target}.tmp"
    cat > "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$target"
}
validate_singbox_config() { jq empty "${conf_dir}/inbounds.json" >/dev/null; }
acquire_proxy_transaction_lock() { LOCKED=1; }
release_proxy_transaction_lock() { LOCKED=0; }
singbox_service_is_active() { [[ "$SERVICE_ACTIVE" -eq 1 ]]; }
restart_singbox_checked() { RESTARTS=$((RESTARTS + 1)); SERVICE_ACTIVE=1; }
stop_singbox_checked() { SERVICE_ACTIVE=0; }
update_sub() { printf '%s\n' published > "${work_dir}/base-sub.txt"; return "$PUBLISH_STATUS"; }
allow_port() { FIREWALL_LAST_ADDED_RECORDS=(new-owned-token); return "$OPEN_STATUS"; }
remove_owned_firewall_records_exact() { printf 'rollback:%s\n' "$*" >> "$FW_LOG"; return "$ROLLBACK_FW_STATUS"; }
remove_owned_firewall_ports_if_unused() { printf 'cleanup:%s\n' "$*" >> "$FW_LOG"; return "$OLD_CLEAN_STATUS"; }
configured_inbound_port_conflict_exists() { return "$CONFLICT_STATUS"; }

setup_fixture() {
    ROOT="${tmp_dir}/$1"
    work_dir="${ROOT}/etc/sing-box"
    conf_dir="${work_dir}/conf"
    client_dir="${work_dir}/url.txt"
    combined_client_dir="${work_dir}/all-url.txt"
    install_env_file="${work_dir}/install.env"
    ARGO_SYSTEMD_SERVICE_FILE="${ROOT}/etc/systemd/system/argo.service"
    ARGO_OPENRC_SERVICE_FILE="${ROOT}/etc/init.d/argo"
    mkdir -p "$conf_dir" "$(dirname "$ARGO_SYSTEMD_SERVICE_FILE")" "$(dirname "$ARGO_OPENRC_SERVICE_FILE")"
    cat > "${conf_dir}/inbounds.json" <<'JSON'
{"inbounds":[
 {"type":"vless","tag":"vless-reality","listen_port":11001,"users":[{"uuid":"11111111-1111-4111-8111-111111111111"}]},
 {"type":"hysteria2","tag":"hysteria2","listen_port":11002,"users":[{"password":"x"}]},
 {"type":"tuic","tag":"tuic","listen_port":11003,"users":[{"uuid":"x","password":"x"}]},
 {"type":"vless","tag":"vless-ws-argo","listen_port":8001,"users":[{"uuid":"x"}]}
]}
JSON
    cat > "$client_dir" <<'URLS'
vless://x@198.51.100.10:11001?security=reality&flow=xtls-rprx-vision#vless
hysteria2://x@198.51.100.10:11002#hy2
tuic://x:x@198.51.100.10:11003#tuic
URLS
    printf '%s\n' combined > "$combined_client_dir"
    printf '%s\n' old-base > "${work_dir}/base-sub.txt"
    printf '%s\n' old-all > "${work_dir}/all-sub.txt"
    printf '%s\n' old-sub > "${work_dir}/sub.txt"
    printf '%s\n' old-cfy > "${work_dir}/cfy-sub.txt"
    cat > "$install_env_file" <<'ENV'
PORT=11001
REALITY_PORT=11001
NGINX_PORT=11004
TUIC_PORT=11003
HY2_PORT=11002
ARGO_PORT=8001
ENV
    PORT=11001 REALITY_PORT=11001 NGINX_PORT=11004 TUIC_PORT=11003 HY2_PORT=11002 ARGO_PORT=8001
    vless_port=11001 nginx_port=11004 tuic_port=11003 hy2_port=11002 argo_port=8001
    export PORT REALITY_PORT NGINX_PORT TUIC_PORT HY2_PORT ARGO_PORT
    SERVICE_ACTIVE=1 RESTARTS=0 PUBLISH_STATUS=0 LOCKED=0
    OPEN_STATUS=0 ROLLBACK_FW_STATUS=0 OLD_CLEAN_STATUS=0 CONFLICT_STATUS=1
    FW_LOG="${ROOT}/firewall.log"
    : > "$FW_LOG"
}

setup_fixture success
change_public_port_transaction reality 12001 >/dev/null 2>&1 || fail 'Reality port transaction failed'
[[ "$(jq -r '[.inbounds[]|select(.tag|startswith("vless-reality"))|.listen_port]|unique|.[0]' "$conf_dir/inbounds.json")" == 12001 ]] || fail 'Reality inbounds port not committed'
grep -Fq ':12001?' "$client_dir" || fail 'Reality client port not committed'
grep -Fqx 'REALITY_PORT=12001' "$install_env_file" || fail 'install.env retained stale Reality port'
[[ "$REALITY_PORT" == 12001 && "$vless_port" == 12001 ]] || fail 'runtime Reality port variables remained stale'
grep -Fq 'cleanup:' "$FW_LOG" || fail 'old owned port cleanup was not attempted after commit'

setup_fixture inactive-success
SERVICE_ACTIVE=0
change_public_port_transaction reality 12001 >/dev/null 2>&1 || fail 'inactive Reality port transaction failed'
[[ "$SERVICE_ACTIVE" -eq 0 && "$RESTARTS" -eq 0 ]] || \
    fail 'successful port transaction started an initially inactive sing-box service'

setup_fixture inactive-publish-fail
SERVICE_ACTIVE=0
PUBLISH_STATUS=1
if change_public_port_transaction reality 12001 >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 1 && "$SERVICE_ACTIVE" -eq 0 && "$RESTARTS" -eq 0 ]] || \
    fail 'failed port transaction changed an initially inactive sing-box service state'

setup_fixture publish-fail
cp -a "$conf_dir/inbounds.json" "$tmp_dir/port-old-inbounds"
cp -a "$client_dir" "$tmp_dir/port-old-client"
cp -a "$install_env_file" "$tmp_dir/port-old-env"
PUBLISH_STATUS=1
set +e
change_public_port_transaction reality 12001 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "port publish failure returned ${status} instead of rc1"
cmp -s "$tmp_dir/port-old-inbounds" "$conf_dir/inbounds.json" || fail 'port rollback did not restore inbounds'
cmp -s "$tmp_dir/port-old-client" "$client_dir" || fail 'port rollback did not restore client source'
cmp -s "$tmp_dir/port-old-env" "$install_env_file" || fail 'port rollback did not restore install.env'
[[ "$REALITY_PORT" == 11001 && "$vless_port" == 11001 ]] || fail 'port rollback did not restore runtime variables'
grep -Fq 'rollback:new-owned-token' "$FW_LOG" || fail 'port rollback did not remove newly-owned firewall record'

setup_fixture rollback-incomplete
PUBLISH_STATUS=1
ROLLBACK_FW_STATUS=1
set +e
recovery_log="${ROOT}/recovery.log"
change_public_port_transaction reality 12001 >"$recovery_log" 2>&1
status=$?
set -e
recovery_output=$(cat "$recovery_log")
[[ "$status" -eq 2 ]] || fail "firewall rollback failure returned ${status} instead of rc2"
shopt -s nullglob
recoveries=("${work_dir}"/.node-change-recovery.*)
[[ "${#recoveries[@]}" -eq 1 && "$(stat -c '%a' "${recoveries[0]}")" == 700 ]] || \
    fail 'incomplete port rollback did not retain one 0700 recovery directory'
[[ -f "${recoveries[0]}/transaction.conf" && "$(stat -c '%a' "${recoveries[0]}/transaction.conf")" == 600 ]] || \
    fail 'port rollback recovery metadata missing or not 0600'
[[ "$recovery_output" == *'自动回滚不完整'*"${recoveries[0]}"* ]] || fail 'port rc2 did not report recovery path'

setup_fixture cleanup-residue
OLD_CLEAN_STATUS=1
set +e
change_public_port_transaction reality 12001 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 3 ]] || fail "old firewall cleanup failure returned ${status} instead of rc3"
[[ "$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.listen_port' "$conf_dir/inbounds.json")" == 12001 ]] || \
    fail 'rc3 cleanup residue rolled back healthy committed config'

setup_fixture conflict
CONFLICT_STATUS=0
set +e
change_public_port_transaction reality 12001 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 && "$RESTARTS" -eq 0 ]] || fail 'known port conflict did not fail before mutation'

setup_fixture conflict-query-error
CONFLICT_STATUS=2
set +e
change_public_port_transaction reality 12001 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 && "$RESTARTS" -eq 0 ]] || fail 'unsafe port conflict query did not propagate rc2'

printf 'Public port change transaction tests passed.\n'
