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
    validate_port_value resolve_service_ports persist_install_settings apply_jq_config \
    get_uniform_inbound_port \
    node_change_snapshot_path node_change_restore_path \
    acquire_node_subscription_lock release_node_subscription_lock \
    publish_node_change_subscription apply_node_change_transaction \
    detect_argo_tunnel_mode resolve_argo_service_definition \
    replace_local_argo_origin_port_file is_quick_argo_hostname extract_staged_argo_domain \
    prepare_quick_argo_domain_capture \
    wait_for_new_quick_argo_domain update_staged_argo_domain_file \
    argo_origin_port_conflict_exists \
    mutate_argo_port_files change_argo_port_transaction; do
    load_function "$function_name"
done

red() { :; }
yellow() { :; }
green() { :; }
atomic_write_file() {
    local target="$1" mode="$2" tmp
    tmp="${target}.tmp"
    cat > "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$target"
}
validate_singbox_config() { jq empty "${conf_dir}/inbounds.json" >/dev/null; }
command_exists() { [[ "$1" == ss ]]; }
detect_usable_init_system() { printf '%s\n' "$TEST_INIT_SYSTEM"; }
ss() {
    case "$LIVE_LISTENER_STATUS" in
        clear) return 0 ;;
        conflict) printf '%s\n' 'LISTEN 0 128 127.0.0.1:1'; return 0 ;;
        error) return 2 ;;
        *) return 2 ;;
    esac
}
acquire_proxy_transaction_lock() {
    [ "$LOCK_ACQUIRE_STATUS" -eq 0 ] || return "$LOCK_ACQUIRE_STATUS"
    : > "${ROOT}/config.lock"
    LOCK_CALLBACK_CALLS=$((LOCK_CALLBACK_CALLS + 1))
    if [ -n "$LOCK_MUTATION_CALLBACK" ]; then
        callback="$LOCK_MUTATION_CALLBACK"
        LOCK_MUTATION_CALLBACK=''
        "$callback"
    fi
    return 0
}
release_proxy_transaction_lock() { rm -f -- "${ROOT}/config.lock"; }
singbox_service_is_active() { [[ "$SERVICE_ACTIVE" -eq 1 ]]; }
restart_singbox_checked() { SINGBOX_RESTARTS=$((SINGBOX_RESTARTS + 1)); SERVICE_ACTIVE=1; }
stop_singbox_checked() { SERVICE_ACTIVE=0; }
argo_service_is_active() { [[ "$ARGO_ACTIVE" -eq 1 ]]; }
restart_argo_checked() {
    ARGO_RESTARTS=$((ARGO_RESTARTS + 1))
    ARGO_ACTIVE=1
    if [ "$ARGO_RESTART_FAIL_ONCE" -eq 1 ]; then
        ARGO_RESTART_FAIL_ONCE=0
        return 1
    fi
    if [ "${ARGO_DOMAIN_INDEX}" -lt "${#ARGO_DOMAIN_SEQUENCE[@]}" ]; then
        next_domain="${ARGO_DOMAIN_SEQUENCE[$ARGO_DOMAIN_INDEX]}"
        ARGO_DOMAIN_INDEX=$((ARGO_DOMAIN_INDEX + 1))
    else
        next_domain="new${ARGO_RESTARTS}.trycloudflare.com"
    fi
    if [ "$next_domain" != NONE ]; then
        printf 'INF quick tunnel https://%s\n' "$next_domain" >> "${work_dir}/argo.log"
    fi
}
stop_argo_checked() { ARGO_ACTIVE=0; }
get_latest_argo_domain() {
    if [ "$GET_DOMAIN_SIGNAL_ONCE" -eq 1 ] && [ ! -e "${ROOT}/domain-signal-fired" ]; then
        : > "${ROOT}/domain-signal-fired"
        kill -TERM "${SIGNAL_TARGET_PID:-$BASHPID}"
    fi
    sed -n 's|.*https://\([^/[:space:]]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -n 1
}
sleep() { :; }
update_sub() {
    local staged_base_file="${1:-}"
    local publish_result="$PUBLISH_STATUS"

    PUBLISH_CALLS=$((PUBLISH_CALLS + 1))
    printf '%s\n' published > "${work_dir}/base-sub.txt"
    if [ "${PUBLISH_INDEX}" -lt "${#PUBLISH_SEQUENCE[@]}" ]; then
        publish_result="${PUBLISH_SEQUENCE[$PUBLISH_INDEX]}"
        PUBLISH_INDEX=$((PUBLISH_INDEX + 1))
    fi
    if [ "$publish_result" -eq 0 ] && [ -n "$staged_base_file" ]; then
        cp -p -- "$staged_base_file" "$client_dir" || return 1
    fi
    return "$publish_result"
}

locked_set_quick_port() {
    apply_jq_config "${conf_dir}/inbounds.json" --arg port "$LOCK_PORT_OVERRIDE" '
      (.inbounds[] | select(.tag == "vless-ws-argo") | .listen_port) = ($port | tonumber)
    '
    sed -i -E "s#(http://(127[.]0[.]0[.]1|localhost):)[0-9]+#\\1${LOCK_PORT_OVERRIDE}#" \
        "$ARGO_SYSTEMD_SERVICE_FILE"
    sed -i -E "s/^ARGO_PORT=.*/ARGO_PORT=${LOCK_PORT_OVERRIDE}/" "$install_env_file"
    ARGO_PORT="$LOCK_PORT_OVERRIDE"
    argo_port="$LOCK_PORT_OVERRIDE"
    if [ -n "${LOCK_DOMAIN_OVERRIDE:-}" ]; then
        sed -i -E \
            "s#([?&]sni=)[^&#]*#\\1${LOCK_DOMAIN_OVERRIDE}#g; s#([?&]host=)[^&#]*#\\1${LOCK_DOMAIN_OVERRIDE}#g" \
            "$client_dir"
    fi
}

locked_switch_remote_to_quick() {
    cat > "$ARGO_SYSTEMD_SERVICE_FILE" <<UNIT
[Service]
ExecStart=/etc/sing-box/argo tunnel --url http://127.0.0.1:${ARGO_PORT} --no-autoupdate
UNIT
    chmod 644 "$ARGO_SYSTEMD_SERVICE_FILE"
}

locked_switch_quick_to_remote() {
    cat > "$ARGO_SYSTEMD_SERVICE_FILE" <<'UNIT'
[Service]
EnvironmentFile=-/etc/sing-box/argo.env
ExecStart=/etc/sing-box/argo tunnel --no-autoupdate run
UNIT
    chmod 644 "$ARGO_SYSTEMD_SERVICE_FILE"
}

setup_fixture() {
    local name="$1" mode="$2"
    ROOT="${tmp_dir}/${name}"
    work_dir="${ROOT}/etc/sing-box"
    conf_dir="${work_dir}/conf"
    client_dir="${work_dir}/url.txt"
    combined_client_dir="${work_dir}/all-url.txt"
    install_env_file="${work_dir}/install.env"
    ARGO_SYSTEMD_SERVICE_FILE="${ROOT}/etc/systemd/system/argo.service"
    ARGO_OPENRC_SERVICE_FILE="${ROOT}/etc/init.d/argo"
    mkdir -p "$conf_dir" "$(dirname "$ARGO_SYSTEMD_SERVICE_FILE")"
    cat > "${conf_dir}/inbounds.json" <<'JSON'
{"inbounds":[
 {"type":"vless","tag":"vless-reality","listen_port":11001,"users":[{"uuid":"11111111-1111-4111-8111-111111111111"}]},
 {"type":"vless","tag":"vless-ws-argo","listen":"127.0.0.1","listen_port":8001,"users":[{"uuid":"11111111-1111-4111-8111-111111111111"}]}
]}
JSON
    printf '%s\n' 'vless://x@edge.example:443?security=tls&sni=old.trycloudflare.com&type=ws&host=old.trycloudflare.com&path=%2Fvless-argo#argo' > "$client_dir"
    printf '%s\n' old-combined > "$combined_client_dir"
    printf '%s\n' old-base > "${work_dir}/base-sub.txt"
    printf '%s\n' old-all > "${work_dir}/all-sub.txt"
    printf '%s\n' old-sub > "${work_dir}/sub.txt"
    cat > "$install_env_file" <<'ENV'
PORT=11001
REALITY_PORT=11001
NGINX_PORT=11004
TUIC_PORT=11003
HY2_PORT=11002
ARGO_PORT=8001
ENV
    TEST_INIT_SYSTEM=systemd
    case "$mode" in
        quick)
            cat > "$ARGO_SYSTEMD_SERVICE_FILE" <<'UNIT'
[Service]
ExecStart=/etc/sing-box/argo tunnel --url http://127.0.0.1:8001 --no-autoupdate
UNIT
            ;;
        local)
            cat > "$ARGO_SYSTEMD_SERVICE_FILE" <<'UNIT'
[Service]
ExecStart=/etc/sing-box/argo tunnel --config /etc/sing-box/tunnel.yml --no-autoupdate run
UNIT
            cat > "${work_dir}/tunnel.yml" <<'YAML'
ingress:
  - hostname: node.example
    service: http://127.0.0.1:8001
  - hostname: sub.example
    service: http://127.0.0.1:11004
YAML
            ;;
        remote)
            cat > "$ARGO_SYSTEMD_SERVICE_FILE" <<'UNIT'
[Service]
EnvironmentFile=-/etc/sing-box/argo.env
ExecStart=/etc/sing-box/argo tunnel --no-autoupdate run
UNIT
            ;;
        openrc)
            TEST_INIT_SYSTEM=openrc
            rm -f -- "$ARGO_SYSTEMD_SERVICE_FILE"
            mkdir -p "$(dirname "$ARGO_OPENRC_SERVICE_FILE")"
            cat > "$ARGO_OPENRC_SERVICE_FILE" <<'OPENRC'
#!/sbin/openrc-run
command="/etc/sing-box/argo"
command_args="tunnel --url http://localhost:8001 --no-autoupdate --protocol http2"
OPENRC
            chmod 755 "$ARGO_OPENRC_SERVICE_FILE"
            ;;
    esac
    [ ! -e "$ARGO_SYSTEMD_SERVICE_FILE" ] || chmod 644 "$ARGO_SYSTEMD_SERVICE_FILE"
    PORT=11001 REALITY_PORT=11001 NGINX_PORT=11004 TUIC_PORT=11003 HY2_PORT=11002 ARGO_PORT=8001
    vless_port=11001 nginx_port=11004 tuic_port=11003 hy2_port=11002 argo_port=8001
    export PORT REALITY_PORT NGINX_PORT TUIC_PORT HY2_PORT ARGO_PORT
    SERVICE_ACTIVE=1 ARGO_ACTIVE=1 SINGBOX_RESTARTS=0 ARGO_RESTARTS=0
    ARGO_RESTART_FAIL_ONCE=0 PUBLISH_STATUS=0
    ARGO_DOMAIN_SEQUENCE=()
    ARGO_DOMAIN_INDEX=0
    PUBLISH_SEQUENCE=()
    PUBLISH_INDEX=0
    GET_DOMAIN_SIGNAL_ONCE=0
    LOCK_MUTATION_CALLBACK=''
    LOCK_CALLBACK_CALLS=0
    LOCK_ACQUIRE_STATUS=0
    LOCK_PORT_OVERRIDE=''
    LOCK_DOMAIN_OVERRIDE=''
    PUBLISH_CALLS=0
    LIVE_LISTENER_STATUS=clear
    ARGO_DOMAIN_WAIT_ATTEMPTS=2
    ARGO_DOMAIN_WAIT_INTERVAL=0
}

setup_fixture quick-success quick
change_argo_port_transaction 8011 || fail 'quick Argo port transaction failed'
[[ "$(jq -r '.inbounds[]|select(.tag=="vless-ws-argo")|.listen_port' "${conf_dir}/inbounds.json")" == 8011 ]] || \
    fail 'quick Argo inbound port not committed'
grep -Fq 'http://127.0.0.1:8011' "$ARGO_SYSTEMD_SERVICE_FILE" || fail 'quick Argo unit retained old origin port'
grep -Fqx 'ARGO_PORT=8011' "$install_env_file" || fail 'quick Argo install.env retained old port'
[[ "$ARGO_PORT" == 8011 && "$argo_port" == 8011 ]] || fail 'quick Argo runtime variables remained stale'
grep -Fq '@edge.example:443?' "$client_dir" || fail 'quick Argo origin change altered the public preferred endpoint'
grep -Fq 'sni=new1.trycloudflare.com' "$client_dir" || fail 'quick Argo restart did not publish the new SNI'
grep -Fq 'host=new1.trycloudflare.com' "$client_dir" || fail 'quick Argo restart did not publish the new Host'
[[ "$SINGBOX_RESTARTS" -eq 1 && "$ARGO_RESTARTS" -eq 1 ]] || fail 'quick Argo services were not restarted once'

setup_fixture local-success local
change_argo_port_transaction 8012 >/dev/null 2>&1 || fail 'local fixed Argo port transaction failed'
grep -Fq 'service: http://127.0.0.1:8012' "${work_dir}/tunnel.yml" || fail 'local tunnel retained old node origin'
grep -Fq 'service: http://127.0.0.1:11004' "${work_dir}/tunnel.yml" || fail 'local tunnel changed HTTPS subscription origin'

setup_fixture local-ambiguous local
sed -i '/hostname: sub.example/a\    service: http://127.0.0.1:8001' "${work_dir}/tunnel.yml"
cp -a "${work_dir}/tunnel.yml" "$tmp_dir/old-ambiguous-tunnel"
set +e
change_argo_port_transaction 8022 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "ambiguous local Argo origin returned ${status} instead of rc1"
cmp -s "$tmp_dir/old-ambiguous-tunnel" "${work_dir}/tunnel.yml" || \
    fail 'ambiguous local Argo origin was partially modified'

setup_fixture openrc-inactive openrc
SERVICE_ACTIVE=0 ARGO_ACTIVE=0
change_argo_port_transaction 8023 >/dev/null 2>&1 || fail 'OpenRC quick Argo port transaction failed'
grep -Fq 'http://127.0.0.1:8023' "$ARGO_OPENRC_SERVICE_FILE" || fail 'OpenRC command_args retained old origin port'
[[ "$SINGBOX_RESTARTS" -eq 0 && "$ARGO_RESTARTS" -eq 0 ]] || fail 'inactive OpenRC services were unexpectedly started'

setup_fixture remote-rejected remote
old_hash="$(sha256sum "${conf_dir}/inbounds.json" "$install_env_file" "$ARGO_SYSTEMD_SERVICE_FILE")"
set +e
change_argo_port_transaction 8013 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "remote-token Argo port change returned ${status} instead of rc1"
[[ "$old_hash" == "$(sha256sum "${conf_dir}/inbounds.json" "$install_env_file" "$ARGO_SYSTEMD_SERVICE_FILE")" ]] || \
    fail 'remote-token rejection changed local state'
[[ "$SINGBOX_RESTARTS" -eq 0 && "$ARGO_RESTARTS" -eq 0 ]] || fail 'remote-token rejection restarted services'

# Decisions made before taking the config lock can be stale.  The transaction
# must re-read both the authoritative port and tunnel mode after lock acquisition.
setup_fixture lock-port-changed quick
LOCK_PORT_OVERRIDE=8002
LOCK_MUTATION_CALLBACK=locked_set_quick_port
change_argo_port_transaction 8001 >/dev/null 2>&1 || \
    fail 'lock-time port change was not reconciled to the requested port'
[[ "$LOCK_CALLBACK_CALLS" -eq 1 ]] || fail 'same-at-call-time Argo request bypassed the config lock'
[[ "$(jq -r '.inbounds[]|select(.tag=="vless-ws-argo")|.listen_port' "${conf_dir}/inbounds.json")" == 8001 ]] || \
    fail 'lock-time authoritative Argo port was not updated'

setup_fixture lock-remote-became-quick remote
LOCK_MUTATION_CALLBACK=locked_switch_remote_to_quick
change_argo_port_transaction 8017 >/dev/null 2>&1 || \
    fail 'remote-to-quick lock-time transition was rejected from stale pre-lock state'
[[ "$LOCK_CALLBACK_CALLS" -eq 1 && "$ARGO_RESTARTS" -eq 1 ]] || \
    fail 'remote-to-quick lock-time transition did not use the authoritative quick mode'

setup_fixture lock-quick-became-remote quick
LOCK_MUTATION_CALLBACK=locked_switch_quick_to_remote
if change_argo_port_transaction 8018 >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 1 ]] || fail "quick-to-remote lock-time transition returned ${status} instead of rc1"
grep -Fq 'EnvironmentFile=-/etc/sing-box/argo.env' "$ARGO_SYSTEMD_SERVICE_FILE" || \
    fail 'quick-to-remote lock-time rejection rolled back the concurrent mode change'
[[ "$SINGBOX_RESTARTS" -eq 0 && "$ARGO_RESTARTS" -eq 0 ]] || \
    fail 'quick-to-remote lock-time rejection restarted services'

setup_fixture lock-port-already-committed quick
LOCK_PORT_OVERRIDE=8019
LOCK_DOMAIN_OVERRIDE=concurrent.trycloudflare.com
LOCK_MUTATION_CALLBACK=locked_set_quick_port
change_argo_port_transaction 8019 >/dev/null 2>&1 || \
    fail 'lock-time already-committed Argo port did not return success'
[[ "$SINGBOX_RESTARTS" -eq 0 && "$ARGO_RESTARTS" -eq 0 && "$PUBLISH_CALLS" -eq 0 ]] || \
    fail 'lock-time no-op restarted services or republished subscriptions'
grep -Fq 'sni=concurrent.trycloudflare.com' "$client_dir" || \
    fail 'lock-time no-op overwrote the authoritative subscription state'

setup_fixture configured-port-conflict quick
jq '.inbounds += [{"type":"socks","tag":"socks-in","listen":"127.0.0.1","listen_port":8020}]' \
    "${conf_dir}/inbounds.json" > "${conf_dir}/inbounds.next"
mv -f "${conf_dir}/inbounds.next" "${conf_dir}/inbounds.json"
old_hash="$(sha256sum "${conf_dir}/inbounds.json" "$install_env_file" "$ARGO_SYSTEMD_SERVICE_FILE")"
if change_argo_port_transaction 8020 >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 1 ]] || fail "configured Argo origin conflict returned ${status} instead of rc1"
[[ "$old_hash" == "$(sha256sum "${conf_dir}/inbounds.json" "$install_env_file" "$ARGO_SYSTEMD_SERVICE_FILE")" ]] || \
    fail 'configured Argo origin conflict changed files'
[[ "$SINGBOX_RESTARTS" -eq 0 && "$ARGO_RESTARTS" -eq 0 ]] || \
    fail 'configured Argo origin conflict restarted services'

setup_fixture live-port-conflict quick
LIVE_LISTENER_STATUS=conflict
if change_argo_port_transaction 8021 >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 1 ]] || fail "live Argo origin conflict returned ${status} instead of rc1"
[[ "$SINGBOX_RESTARTS" -eq 0 && "$ARGO_RESTARTS" -eq 0 ]] || \
    fail 'live Argo origin conflict restarted services'

setup_fixture live-port-query-error quick
LIVE_LISTENER_STATUS=error
if change_argo_port_transaction 8022 >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 2 ]] || fail "unsafe Argo listener query returned ${status} instead of rc2"
[[ "$SINGBOX_RESTARTS" -eq 0 && "$ARGO_RESTARTS" -eq 0 ]] || \
    fail 'unsafe Argo listener query restarted services'

setup_fixture unresolved-config-lock quick
LOCK_ACQUIRE_STATUS=2
if change_argo_port_transaction 8027 >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 2 ]] || fail "unresolved config lock returned ${status} instead of rc2"
[[ "$LOCK_CALLBACK_CALLS" -eq 0 && "$SINGBOX_RESTARTS" -eq 0 && "$ARGO_RESTARTS" -eq 0 && \
   "$PUBLISH_CALLS" -eq 0 ]] || fail 'unresolved config lock allowed mutation or service activity'

setup_fixture publish-failure quick
cp -a "${conf_dir}/inbounds.json" "$tmp_dir/old-argo-inbounds"
cp -a "$install_env_file" "$tmp_dir/old-argo-env"
cp -a "$ARGO_SYSTEMD_SERVICE_FILE" "$tmp_dir/old-argo-unit"
PUBLISH_SEQUENCE=(1 0)
set +e
change_argo_port_transaction 8014 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "Argo publish failure returned ${status} instead of rc1"
cmp -s "$tmp_dir/old-argo-inbounds" "${conf_dir}/inbounds.json" || fail 'Argo publish rollback did not restore inbounds'
cmp -s "$tmp_dir/old-argo-env" "$install_env_file" || fail 'Argo publish rollback did not restore install.env'
cmp -s "$tmp_dir/old-argo-unit" "$ARGO_SYSTEMD_SERVICE_FILE" || fail 'Argo publish rollback did not restore unit'
[[ "$ARGO_PORT" == 8001 && "$argo_port" == 8001 ]] || fail 'Argo publish rollback retained new runtime port'
[[ "$SINGBOX_RESTARTS" -eq 2 && "$ARGO_RESTARTS" -eq 2 ]] || fail 'Argo publish rollback did not restore both runtimes'
grep -Fq 'sni=new2.trycloudflare.com' "$client_dir" || fail 'Argo publish rollback did not publish the recovered quick domain'

setup_fixture first-domain-failure quick
ARGO_DOMAIN_SEQUENCE=(NONE recovered.trycloudflare.com)
if change_argo_port_transaction 8024 >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 1 ]] || fail "first quick-domain failure returned ${status} instead of rc1 after recovery"
[[ "$(jq -r '.inbounds[]|select(.tag=="vless-ws-argo")|.listen_port' "${conf_dir}/inbounds.json")" == 8001 ]] || \
    fail 'first quick-domain failure did not restore the old origin port'
grep -Fq 'sni=recovered.trycloudflare.com' "$client_dir" || fail 'first quick-domain failure did not publish the rollback domain'
[[ "$ARGO_RESTARTS" -eq 2 ]] || fail 'first quick-domain failure did not restart Argo for recovery'

setup_fixture rollback-domain-failure quick
ARGO_DOMAIN_SEQUENCE=(NONE NONE)
if change_argo_port_transaction 8025 >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 2 ]] || fail "rollback quick-domain failure returned ${status} instead of rc2"
shopt -s nullglob
recoveries=("${work_dir}"/.node-change-recovery.*)
[[ "${#recoveries[@]}" -eq 1 && "$(stat -c '%a' "${recoveries[0]}")" == 700 ]] || \
    fail 'rollback quick-domain failure did not retain one 0700 recovery directory'
[[ -f "${recoveries[0]}/transaction.conf" && "$(stat -c '%a' "${recoveries[0]}/transaction.conf")" == 600 ]] || \
    fail 'rollback quick-domain recovery metadata is missing or insecure'

setup_fixture quick-domain-signal quick
ARGO_DOMAIN_SEQUENCE=(interrupted.trycloudflare.com recovered-signal.trycloudflare.com)
GET_DOMAIN_SIGNAL_ONCE=1
set +e
(
    trap - EXIT
    SIGNAL_TARGET_PID="$BASHPID"
    change_argo_port_transaction 8026 >/dev/null 2>&1
)
status=$?
set -e
[[ "$status" -eq 143 ]] || fail "quick-domain TERM returned ${status} instead of 143"
grep -Fq 'sni=recovered-signal.trycloudflare.com' "$client_dir" || \
    fail 'quick-domain signal recovery did not publish the recovered domain'
recoveries=("${work_dir}"/.node-change-recovery.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'quick-domain signal did not retain recovery evidence'

setup_fixture argo-restart-failure quick
ARGO_RESTART_FAIL_ONCE=1
set +e
change_argo_port_transaction 8015 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "Argo restart failure returned ${status} instead of rc1"
[[ "$(jq -r '.inbounds[]|select(.tag=="vless-ws-argo")|.listen_port' "${conf_dir}/inbounds.json")" == 8001 ]] || \
    fail 'Argo restart failure did not roll back inbounds'
[[ "$ARGO_RESTARTS" -eq 2 && "$ARGO_ACTIVE" -eq 1 ]] || fail 'Argo restart rollback did not restore active service'

setup_fixture inactive quick
SERVICE_ACTIVE=0 ARGO_ACTIVE=0
change_argo_port_transaction 8016 >/dev/null 2>&1 || fail 'inactive Argo port transaction failed'
[[ "$SINGBOX_RESTARTS" -eq 0 && "$ARGO_RESTARTS" -eq 0 ]] || fail 'inactive services were unexpectedly started'

printf 'Argo port change transaction tests passed.\n'
