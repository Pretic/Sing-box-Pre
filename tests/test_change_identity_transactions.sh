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
    finish_transaction_release \
    apply_jq_config validate_uuid_value is_valid_ipv4_address is_valid_ipv6_address \
    node_change_snapshot_path node_change_restore_path \
    acquire_node_subscription_lock release_node_subscription_lock \
    publish_node_change_subscription apply_node_change_transaction \
    mutate_uuid_node_files change_uuid_transaction \
    public_route_dns_strategy mutate_reality_sni_files change_reality_sni_transaction \
    mutate_client_ip_files change_client_ip_transaction; do
    load_function "$function_name"
done

red() { printf '%s\n' "$*" >&2; }
yellow() { :; }
green() { :; }
validate_singbox_config() { jq empty "${conf_dir}/inbounds.json" >/dev/null; }
is_valid_subscription_domain() { [[ "$1" == example.com || "$1" == old.example ]]; }
acquire_proxy_transaction_lock() { LOCKED=1; : > "${ROOT}/config.lock"; }
release_proxy_transaction_lock() { LOCKED=0; rm -f -- "${ROOT}/config.lock"; }
singbox_service_is_active() { [[ "$SERVICE_ACTIVE" -eq 1 ]]; }
restart_singbox_checked() {
    local pending_signal="${RESTART_SIGNAL:-}"
    RESTARTS=$((RESTARTS + 1))
    SERVICE_ACTIVE=1
    if [ -n "$pending_signal" ]; then
        RESTART_SIGNAL=''
        kill -s "$pending_signal" "$BASHPID"
    fi
}
stop_singbox_checked() { SERVICE_ACTIVE=0; }
update_sub() {
    PUBLISH_ATTEMPTS=$((PUBLISH_ATTEMPTS + 1))
    printf '%s\n' new-published > "${work_dir}/base-sub.txt"
    [ -z "${PUBLISH_CFY_VALUE:-}" ] || printf '%s\n' "$PUBLISH_CFY_VALUE" > "${work_dir}/cfy-sub.txt"
    if [ -n "${PUBLISH_SIGNAL:-}" ]; then
        local pending_signal="$PUBLISH_SIGNAL"
        PUBLISH_SIGNAL=''
        kill -s "$pending_signal" "$BASHPID"
    fi
    return "$PUBLISH_STATUS"
}

setup_fixture() {
    ROOT="${tmp_dir}/$1"
    work_dir="${ROOT}/etc/sing-box"
    conf_dir="${work_dir}/conf"
    client_dir="${work_dir}/url.txt"
    combined_client_dir="${work_dir}/all-url.txt"
    install_env_file="${work_dir}/install.env"
    ARGO_SYSTEMD_SERVICE_FILE="${ROOT}/etc/systemd/system/argo.service"
    ARGO_OPENRC_SERVICE_FILE="${ROOT}/etc/init.d/argo"
    mkdir -p "$conf_dir" "$(dirname "$ARGO_SYSTEMD_SERVICE_FILE")" \
        "$(dirname "$ARGO_OPENRC_SERVICE_FILE")"
    printf '%s\n' '{"dns":{"servers":[{"type":"local","tag":"local"}]}}' > "${conf_dir}/dns.json"
    cat > "${conf_dir}/inbounds.json" <<'JSON'
{"inbounds":[
 {"type":"vless","tag":"vless-reality","listen_port":11001,"users":[{"uuid":"11111111-1111-4111-8111-111111111111"}],"tls":{"server_name":"old.example","reality":{"handshake":{"server":"old.example"}}}},
 {"type":"vless","tag":"vless-ws-argo","listen_port":8001,"users":[{"uuid":"11111111-1111-4111-8111-111111111111"}]},
 {"type":"hysteria2","tag":"hysteria2","listen_port":11002,"users":[{"password":"11111111-1111-4111-8111-111111111111"}]},
 {"type":"tuic","tag":"tuic","listen_port":11003,"users":[{"uuid":"11111111-1111-4111-8111-111111111111","password":"11111111-1111-4111-8111-111111111111"}]},
 {"type":"anytls","tag":"anytls","listen_port":12000,"users":[{"password":"11111111-1111-4111-8111-111111111111"}]},
 {"type":"socks","tag":"socks5-in","listen_port":12001,"users":[{"username":"u","password":"11111111-1111-4111-8111-111111111111"}]},
 {"type":"shadowsocks","tag":"shadowsocks-2022","listen_port":12002,"password":"independent-secret"}
]}
JSON
    cat > "$client_dir" <<'URLS'
vless://11111111-1111-4111-8111-111111111111@198.51.100.10:11001?security=reality&sni=old.example&flow=xtls-rprx-vision#vless
hysteria2://11111111-1111-4111-8111-111111111111@198.51.100.10:11002#hy2
tuic://11111111-1111-4111-8111-111111111111:11111111-1111-4111-8111-111111111111@198.51.100.10:11003#tuic
anytls://11111111-1111-4111-8111-111111111111@198.51.100.10:12000#any
socks://dToxMTExMTExMS0xMTExLTQxMTEtODExMS0xMTExMTExMTExMTE=@198.51.100.10:12001#socks
URLS
    printf '%s\n' old-combined > "$combined_client_dir"
    printf '%s\n' old-base > "${work_dir}/base-sub.txt"
    printf '%s\n' old-all-sub > "${work_dir}/all-sub.txt"
    printf '%s\n' old-sub > "${work_dir}/sub.txt"
    printf '%s\n' old-cfy-sub > "${work_dir}/cfy-sub.txt"
    printf '%s\n' cfy-owned-source > "${work_dir}/cfy-url.txt"
    cat > "$install_env_file" <<'ENV'
PORT=11001
REALITY_PORT=11001
NGINX_PORT=11004
TUIC_PORT=11003
HY2_PORT=11002
ARGO_PORT=8001
ENV
    printf '%s\n' quick-unit > "$ARGO_SYSTEMD_SERVICE_FILE"
    printf '%s\n' quick-openrc > "$ARGO_OPENRC_SERVICE_FILE"
    PORT=11001 REALITY_PORT=11001 NGINX_PORT=11004 TUIC_PORT=11003 HY2_PORT=11002 ARGO_PORT=8001
    vless_port=11001 nginx_port=11004 tuic_port=11003 hy2_port=11002 argo_port=8001
    export PORT REALITY_PORT NGINX_PORT TUIC_PORT HY2_PORT ARGO_PORT
    SERVICE_ACTIVE=1 RESTARTS=0 PUBLISH_ATTEMPTS=0 PUBLISH_STATUS=0 LOCKED=0
    PUBLISH_CFY_VALUE=''
    PUBLISH_SIGNAL=''
    RESTART_SIGNAL=''
    MUTATION_SIGNAL=TERM
}

NEW_UUID='22222222-2222-4222-8222-222222222222'

setup_fixture invalid-uuid
old_hash="$(sha256sum "${conf_dir}/inbounds.json" "$client_dir")"
set +e
change_uuid_transaction not-a-uuid >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "invalid UUID returned ${status} instead of 1"
[[ "$PUBLISH_ATTEMPTS" -eq 0 && "$old_hash" == "$(sha256sum "${conf_dir}/inbounds.json" "$client_dir")" ]] || \
    fail 'invalid UUID caused mutation or publication'

setup_fixture uuid-success
change_uuid_transaction "$NEW_UUID" >/dev/null 2>&1 || fail 'valid UUID transaction failed'
[[ "$(jq -r '.inbounds[]|select(.tag=="vless-reality")|.users[0].uuid' "${conf_dir}/inbounds.json")" == "$NEW_UUID" ]] || fail 'vless UUID unchanged'
[[ "$(jq -r '.inbounds[]|select(.type=="hysteria2")|.users[0].password' "${conf_dir}/inbounds.json")" == "$NEW_UUID" ]] || fail 'Hysteria2 UUID-derived password unchanged'
[[ "$(jq -r '.inbounds[]|select(.type=="tuic")|.users[0].uuid+":"+.users[0].password' "${conf_dir}/inbounds.json")" == "$NEW_UUID:$NEW_UUID" ]] || fail 'TUIC credentials unchanged'
[[ "$(jq -r '.inbounds[]|select(.tag=="anytls")|.users[0].password' "${conf_dir}/inbounds.json")" == "$NEW_UUID" ]] || fail 'managed AnyTLS password unchanged'
[[ "$(jq -r '.inbounds[]|select(.tag=="socks5-in")|.users[0].password' "${conf_dir}/inbounds.json")" == '11111111-1111-4111-8111-111111111111' ]] || fail 'UUID rotation changed Socks password'
grep -Fqx cfy-owned-source "${work_dir}/cfy-url.txt" || fail 'UUID rotation changed cfy-owned source'
grep -Fq 'socks://' "$client_dir" || fail 'UUID rotation removed independent Socks link'

setup_fixture uuid-publish-fail
cp -a "$conf_dir/inbounds.json" "$tmp_dir/old-inbounds"
cp -a "$client_dir" "$tmp_dir/old-client"
cp -a "${work_dir}/base-sub.txt" "$tmp_dir/old-base"
PUBLISH_STATUS=1
PUBLISH_CFY_VALUE=concurrent-cfy-result
set +e
change_uuid_transaction "$NEW_UUID" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "UUID publish failure returned ${status} instead of rc1"
cmp -s "$tmp_dir/old-inbounds" "$conf_dir/inbounds.json" || fail 'UUID publish failure did not restore inbounds'
cmp -s "$tmp_dir/old-client" "$client_dir" || fail 'UUID publish failure did not restore client source'
cmp -s "$tmp_dir/old-base" "${work_dir}/base-sub.txt" || fail 'UUID publish failure did not restore subscription'
grep -Fqx concurrent-cfy-result "${work_dir}/cfy-sub.txt" || fail 'UUID rollback overwrote cfy-owned output'
[[ "$RESTARTS" -eq 2 && "$SERVICE_ACTIVE" -eq 1 ]] || fail 'UUID publish rollback did not restore runtime'

mutation_returns_two() {
    local staged_client="$1"
    printf '%s\n' partial-change > "$staged_client"
    jq '(.inbounds[0].listen_port) = 19999' "${conf_dir}/inbounds.json" > "${conf_dir}/rc2.json"
    mv -f "${conf_dir}/rc2.json" "${conf_dir}/inbounds.json"
    return 2
}
setup_fixture mutator-rc2
cp -a "$client_dir" "$tmp_dir/old-rc2-client"
cp -a "${conf_dir}/inbounds.json" "$tmp_dir/old-rc2-inbounds"
set +e
rc2_log="${ROOT}/rc2.log"
apply_node_change_transaction mutation_returns_two 0 '' '' >"$rc2_log" 2>&1
status=$?
set -e
rc2_output=$(cat "$rc2_log")
[[ "$status" -eq 2 ]] || fail "mutator rc2 was flattened to ${status}"
cmp -s "$tmp_dir/old-rc2-client" "$client_dir" || fail 'mutator rc2 did not restore client source'
cmp -s "$tmp_dir/old-rc2-inbounds" "${conf_dir}/inbounds.json" || fail 'mutator rc2 did not restore inbounds'
shopt -s nullglob
rc2_recoveries=("${work_dir}"/.node-change-recovery.*)
[[ "${#rc2_recoveries[@]}" -eq 1 ]] || fail 'mutator rc2 did not retain recovery evidence'

interrupting_mutation() {
    local staged_client="$1"
    printf '%s\n' interrupted-change > "$staged_client"
    jq '(.inbounds[0].listen_port) = 18888' "${conf_dir}/inbounds.json" > "${conf_dir}/interrupted.json"
    mv -f "${conf_dir}/interrupted.json" "${conf_dir}/inbounds.json"
    kill -s "${MUTATION_SIGNAL:-TERM}" "$BASHPID"
}
setup_fixture interrupted
cp -a "$client_dir" "$tmp_dir/old-interrupt-client"
cp -a "${conf_dir}/inbounds.json" "$tmp_dir/old-interrupt-inbounds"
set +e
( trap - EXIT; apply_node_change_transaction interrupting_mutation 0 '' '' ) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 143 ]] || fail "TERM transaction returned ${status} instead of 143"
cmp -s "$tmp_dir/old-interrupt-client" "$client_dir" || fail 'TERM did not restore client source'
cmp -s "$tmp_dir/old-interrupt-inbounds" "${conf_dir}/inbounds.json" || fail 'TERM did not restore inbounds'
interrupt_recoveries=("${work_dir}"/.node-change-recovery.*)
[[ "${#interrupt_recoveries[@]}" -eq 1 ]] || fail 'TERM did not retain recovery evidence'
[[ "$(stat -c '%a' "${interrupt_recoveries[0]}")" == 700 ]] || fail 'TERM recovery directory is not 0700'
[[ -f "${interrupt_recoveries[0]}/transaction.conf" && \
   "$(stat -c '%a' "${interrupt_recoveries[0]}/transaction.conf")" == 600 ]] || \
    fail 'TERM recovery metadata is missing or not 0600'
grep -Fqx 'stage=mutating' "${interrupt_recoveries[0]}/transaction.conf" || \
    fail 'TERM recovery metadata did not record mutating stage'
[[ ! -e "${ROOT}/config.lock" && ! -e "${work_dir}/.subscription-publish.lock.d" ]] || \
    fail 'TERM left a transaction lock behind'

setup_fixture interrupted-hup
cp -a "${conf_dir}/inbounds.json" "$tmp_dir/old-hup-inbounds"
MUTATION_SIGNAL=HUP
export MUTATION_SIGNAL
set +e
( trap - EXIT; apply_node_change_transaction interrupting_mutation 0 '' '' ) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 129 ]] || fail "HUP transaction returned ${status} instead of 129"
cmp -s "$tmp_dir/old-hup-inbounds" "${conf_dir}/inbounds.json" || fail 'HUP did not restore inbounds'
[[ ! -e "${ROOT}/config.lock" ]] || fail 'HUP left the config lock behind'

setup_fixture restart-interrupted
cp -a "$client_dir" "$tmp_dir/old-restart-interrupt-client"
cp -a "${conf_dir}/inbounds.json" "$tmp_dir/old-restart-interrupt-inbounds"
RESTART_SIGNAL=TERM
export RESTART_SIGNAL
set +e
( trap - EXIT; change_uuid_transaction "$NEW_UUID" ) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 143 ]] || fail "restart TERM returned ${status} instead of 143"
cmp -s "$tmp_dir/old-restart-interrupt-client" "$client_dir" || fail 'restart TERM changed live client source'
cmp -s "$tmp_dir/old-restart-interrupt-inbounds" "${conf_dir}/inbounds.json" || \
    fail 'restart TERM did not restore inbounds'
restart_recoveries=("${work_dir}"/.node-change-recovery.*)
[[ "${#restart_recoveries[@]}" -eq 1 ]] || fail 'restart TERM did not retain recovery evidence'
grep -Fqx 'stage=restarting' "${restart_recoveries[0]}/transaction.conf" || \
    fail 'restart TERM recovery metadata did not record restarting stage'
[[ ! -e "${ROOT}/config.lock" ]] || fail 'restart TERM left the config lock behind'

setup_fixture publisher-interrupted
cp -a "$client_dir" "$tmp_dir/old-publisher-interrupt-client"
cp -a "${conf_dir}/inbounds.json" "$tmp_dir/old-publisher-interrupt-inbounds"
PUBLISH_SIGNAL=TERM
export PUBLISH_SIGNAL
set +e
( trap - EXIT; change_uuid_transaction "$NEW_UUID" ) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 143 ]] || fail "publisher TERM returned ${status} instead of 143"
cmp -s "$tmp_dir/old-publisher-interrupt-client" "$client_dir" || fail 'publisher TERM did not restore client source'
cmp -s "$tmp_dir/old-publisher-interrupt-inbounds" "${conf_dir}/inbounds.json" || \
    fail 'publisher TERM did not restore inbounds'
publisher_recoveries=("${work_dir}"/.node-subscription-recovery.*)
outer_recoveries=("${work_dir}"/.node-change-recovery.*)
[[ "${#publisher_recoveries[@]}" -eq 1 && "${#outer_recoveries[@]}" -eq 1 ]] || \
    fail 'publisher TERM did not retain both subscription and config recovery evidence'
grep -Fqx 'stage=publishing' "${outer_recoveries[0]}/transaction.conf" || \
    fail 'publisher TERM recovery metadata did not record publishing stage'
grep -Fqx 'rollback_complete=0' "${outer_recoveries[0]}/transaction.conf" || \
    fail 'publisher TERM incorrectly claimed a complete outer rollback'
[[ "$(stat -c '%a' "${publisher_recoveries[0]}")" == 700 && \
   "$(stat -c '%a' "${publisher_recoveries[0]}/transaction.conf")" == 600 ]] || \
    fail 'publisher TERM recovery evidence has unsafe permissions'
[[ ! -e "${ROOT}/config.lock" && ! -e "${work_dir}/.subscription-publish.lock.d" ]] || \
    fail 'publisher TERM left a transaction lock behind'

setup_fixture sni-publish-fail
cp -a "$conf_dir/inbounds.json" "$tmp_dir/old-sni-inbounds"
cp -a "$client_dir" "$tmp_dir/old-sni-client"
PUBLISH_STATUS=1
set +e
change_reality_sni_transaction example.com >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "SNI publish failure returned ${status} instead of rc1"
cmp -s "$tmp_dir/old-sni-inbounds" "$conf_dir/inbounds.json" || fail 'SNI rollback did not restore inbounds'
cmp -s "$tmp_dir/old-sni-client" "$client_dir" || fail 'SNI rollback did not restore client source'

setup_fixture ip-publish-fail
cp -a "$client_dir" "$tmp_dir/old-ip-client"
PUBLISH_STATUS=1
set +e
change_client_ip_transaction ipv6 '2001:db8::20' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "IP publish failure returned ${status} instead of rc1"
cmp -s "$tmp_dir/old-ip-client" "$client_dir" || fail 'IP publish rollback did not restore client source'
[[ "$RESTARTS" -eq 0 ]] || fail 'client-only IP mutation restarted sing-box'

printf 'Identity/SNI/IP change transaction tests passed.\n'
