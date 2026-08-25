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

load_function() {
    local source

    source="$(extract_function "$1")"
    [[ -n "$source" ]] || fail "$1 is not implemented"
    source <(printf '%s\n' "$source")
}

for function_name in \
    render_singbox_systemd_service \
    render_singbox_openrc_service \
    render_argo_systemd_service \
    render_argo_openrc_service \
    partial_install_state_path \
    persist_partial_install_resume_state \
    load_partial_install_resume_state \
    validate_partial_install_config_credentials \
    validate_partial_install_config_ports \
    partial_install_service_definition_is_managed \
    partial_install_service_is_active \
    enable_install_services \
    start_pending_install_services \
    partial_install_nginx_listener_is_managed \
    validate_partial_install_resume_runtime \
    prepare_partial_install_resume \
    clear_partial_install_resume_state; do
    load_function "$function_name"
done

assert_ok() {
    "$@" || fail "expected success: $*"
}

assert_fail() {
    if "$@"; then
        fail "expected failure: $*"
    fi
}

work_dir="${tmp_dir}/etc/sing-box"
conf_dir="${work_dir}/conf"
install_env_file="${work_dir}/install.env"
PARTIAL_INSTALL_STATE_FILE="${work_dir}/install-resume.state"
INSTALL_SYSTEMD_UNIT_DIR="${tmp_dir}/etc/systemd/system"
INSTALL_OPENRC_INIT_DIR="${tmp_dir}/etc/init.d"
NGINX_SUBSCRIPTION_CONF="${tmp_dir}/etc/nginx/conf.d/sing-box.conf"
mkdir -p "$conf_dir" "$INSTALL_SYSTEMD_UNIT_DIR" "$INSTALL_OPENRC_INIT_DIR" \
    "$(dirname "$NGINX_SUBSCRIPTION_CONF")"

uuid='123e4567-e89b-42d3-a456-426614174000'
password='AbCdEfGhJkMnPqRsTuVwXy12'
private_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
public_key='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
ARGO_FIXED_READY=0

atomic_write_secret_file() {
    local target="$1"
    cat > "$target"
    chmod 600 "$target"
}
validate_installed_singbox_config_strict() { return 0; }
get_uniform_inbound_port() {
    case "$2" in
        reality) printf '%s\n' "${MOCK_REALITY_PORT:-24443}" ;;
        hysteria2) printf '%s\n' "${MOCK_HY2_PORT:-24444}" ;;
        tuic) printf '%s\n' "${MOCK_TUIC_PORT:-24443}" ;;
        argo) printf '%s\n' "${MOCK_ARGO_PORT:-18001}" ;;
        *) return 1 ;;
    esac
}
assert_ok persist_partial_install_resume_state
if [[ "$(uname -s)" != MINGW* ]]; then
    [[ "$(stat -c '%a' "$PARTIAL_INSTALL_STATE_FILE")" == 600 ]] || \
        fail 'partial install credentials were not stored with mode 600'
else
    stat() {
        if [[ "$*" == "-c %a ${PARTIAL_INSTALL_STATE_FILE}" ]]; then
            printf '600\n'
        else
            command stat "$@"
        fi
    }
fi
uuid='' password='' private_key='' public_key='' ARGO_FIXED_READY=''
assert_ok load_partial_install_resume_state
[[ "$uuid" == '123e4567-e89b-42d3-a456-426614174000' ]] || fail 'UUID was not restored'
[[ "$password" == 'AbCdEfGhJkMnPqRsTuVwXy12' ]] || fail 'subscription token was not restored'
[[ "$private_key" == 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' ]] || fail 'private key was not restored'
[[ "$public_key" == 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' ]] || fail 'public key was not restored'

cat > "${conf_dir}/inbounds.json" <<EOF
{
  "inbounds": [
    {"type":"vless","tag":"vless-reality","users":[{"uuid":"${uuid}"}],"tls":{"reality":{"private_key":"${private_key}"}}},
    {"type":"vless","tag":"vless-ws-argo","users":[{"uuid":"${uuid}"}]},
    {"type":"hysteria2","users":[{"password":"${uuid}"}]},
    {"type":"tuic","users":[{"uuid":"${uuid}","password":"${uuid}"}]}
  ]
}
EOF
assert_ok validate_partial_install_config_credentials
jq 'del(.inbounds[] | select(.type == "tuic"))' "${conf_dir}/inbounds.json" > "${conf_dir}/inbounds.tmp"
mv "${conf_dir}/inbounds.tmp" "${conf_dir}/inbounds.json"
assert_fail validate_partial_install_config_credentials

cp "$PARTIAL_INSTALL_STATE_FILE" "${PARTIAL_INSTALL_STATE_FILE}.good"
printf 'UUID=00000000-0000-0000-0000-000000000000\n' >> "$PARTIAL_INSTALL_STATE_FILE"
assert_fail load_partial_install_resume_state
mv "${PARTIAL_INSTALL_STATE_FILE}.good" "$PARTIAL_INSTALL_STATE_FILE"

argo_port=18001
ARGO_PORT=18001
render_singbox_systemd_service > "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service"
render_argo_systemd_service quick > "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service"
render_singbox_openrc_service > "${INSTALL_OPENRC_INIT_DIR}/sing-box"
render_argo_openrc_service quick > "${INSTALL_OPENRC_INIT_DIR}/argo"
chmod 700 "${INSTALL_OPENRC_INIT_DIR}/sing-box" "${INSTALL_OPENRC_INIT_DIR}/argo"

for init_system in systemd openrc; do
    assert_ok partial_install_service_definition_is_managed "$init_system" sing-box
    assert_ok partial_install_service_definition_is_managed "$init_system" argo
done

cp "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service" "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service.good"
sed -i '/sing-box-pre:managed-service-v1/d' "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service"
assert_fail partial_install_service_definition_is_managed systemd sing-box
mv "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service.good" "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service"

cp "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service" "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service.good"
sed -i 's/# sing-box-pre:managed-service-v1/# sing-box-pre:managed-service-v1 foreign-suffix/' \
    "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service"
assert_fail partial_install_service_definition_is_managed systemd sing-box
mv "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service.good" "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service"

cp "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service" "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service.good"
printf 'ExecStartPre=/usr/local/bin/foreign-hook\n' >> "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service"
assert_fail partial_install_service_definition_is_managed systemd sing-box
mv "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service.good" "${INSTALL_SYSTEMD_UNIT_DIR}/sing-box.service"

cp "${INSTALL_OPENRC_INIT_DIR}/argo" "${INSTALL_OPENRC_INIT_DIR}/argo.good"
sed -i 's#command="/etc/sing-box/argo"#command="/usr/local/bin/foreign-argo"#' \
    "${INSTALL_OPENRC_INIT_DIR}/argo"
assert_fail partial_install_service_definition_is_managed openrc argo
mv "${INSTALL_OPENRC_INIT_DIR}/argo.good" "${INSTALL_OPENRC_INIT_DIR}/argo"
chmod 700 "${INSTALL_OPENRC_INIT_DIR}/argo"

cp "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service" "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service.good"
printf 'Environment=FOREIGN_LIFECYCLE_HOOK=1\n' >> "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service"
assert_fail partial_install_service_definition_is_managed systemd argo
mv "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service.good" "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service"

cp "${INSTALL_OPENRC_INIT_DIR}/sing-box" "${INSTALL_OPENRC_INIT_DIR}/sing-box.good"
printf '%s\n' 'depend() {' '    need foreign-service' '}' >> "${INSTALL_OPENRC_INIT_DIR}/sing-box"
assert_fail partial_install_service_definition_is_managed openrc sing-box
mv "${INSTALL_OPENRC_INIT_DIR}/sing-box.good" "${INSTALL_OPENRC_INIT_DIR}/sing-box"
chmod 700 "${INSTALL_OPENRC_INIT_DIR}/sing-box"

vless_port=24443
nginx_port=24444
tuic_port=24443
hy2_port=24444
argo_port=18001
printf '{}\n' > "${conf_dir}/inbounds.json"
assert_ok validate_partial_install_config_ports
MOCK_TUIC_PORT=29999
assert_fail validate_partial_install_config_ports
unset MOCK_TUIC_PORT
LISTENER_CASE=managed
port_is_listening() {
    local rule="${1}/${2}"
    case "$LISTENER_CASE:$rule" in
        managed:24443/tcp|managed:24443/udp|managed:24444/tcp|managed:24444/udp|managed:18001/tcp) return 0 ;;
        no-nginx:24443/tcp|no-nginx:24443/udp|no-nginx:24444/udp|no-nginx:18001/tcp) return 0 ;;
        inactive-foreign:24443/tcp) return 0 ;;
        active-missing:24443/tcp|active-missing:24443/udp|active-missing:18001/tcp) return 0 ;;
        foreign-core:*) return 0 ;;
    esac
    return 1
}
systemctl() { return 0; }
rc-service() { return 0; }
classify_nginx_subscription_config() { return "${NGINX_CLASSIFY_STATUS:-0}"; }
get_nginx_subscription_port() { printf '%s\n' "${NGINX_CONFIG_PORT:-24444}"; }

for init_system in systemd openrc; do
    NGINX_CLASSIFY_STATUS=0 NGINX_CONFIG_PORT=24444 LISTENER_CASE=managed
    assert_ok validate_partial_install_resume_runtime "$init_system"
    LISTENER_CASE=no-nginx
    assert_ok validate_partial_install_resume_runtime "$init_system"
done

# Resume may safely repair either inactive core service. An active sing-box
# must own every configured listener; an inactive one is safe only when all
# expected core ports are empty. A foreign listener is an unresolved rc=2.
SYSTEMD_SINGBOX_ACTIVE=1
SYSTEMD_ARGO_ACTIVE=0
OPENRC_SINGBOX_ACTIVE=1
OPENRC_ARGO_ACTIVE=0
systemctl() {
    case "$*" in
        'is-active --quiet sing-box') [[ "$SYSTEMD_SINGBOX_ACTIVE" -eq 1 ]] ;;
        'is-active --quiet argo') [[ "$SYSTEMD_ARGO_ACTIVE" -eq 1 ]] ;;
        'is-active --quiet nginx') return 1 ;;
        *) return 0 ;;
    esac
}
rc-service() {
    case "$*" in
        'sing-box status') [[ "$OPENRC_SINGBOX_ACTIVE" -eq 1 ]] ;;
        'argo status') [[ "$OPENRC_ARGO_ACTIVE" -eq 1 ]] ;;
        'nginx status') return 1 ;;
        *) return 0 ;;
    esac
}
for init_system in systemd openrc; do
    LISTENER_CASE=no-nginx
    assert_ok validate_partial_install_resume_runtime "$init_system"

    if [ "$init_system" = systemd ]; then
        SYSTEMD_SINGBOX_ACTIVE=0
    else
        OPENRC_SINGBOX_ACTIVE=0
    fi
    LISTENER_CASE=none
    assert_ok validate_partial_install_resume_runtime "$init_system"

    LISTENER_CASE=inactive-foreign
    set +e
    validate_partial_install_resume_runtime "$init_system"
    unsafe_listener_status=$?
    set -e
    [[ "$unsafe_listener_status" -eq 2 ]] || \
        fail "${init_system} foreign resume listener returned ${unsafe_listener_status}, expected rc=2"

    if [ "$init_system" = systemd ]; then
        SYSTEMD_SINGBOX_ACTIVE=1
    else
        OPENRC_SINGBOX_ACTIVE=1
    fi
    LISTENER_CASE=active-missing
    set +e
    validate_partial_install_resume_runtime "$init_system"
    missing_listener_status=$?
    set -e
    [[ "$missing_listener_status" -eq 2 ]] || \
        fail "${init_system} active service with missing listeners returned ${missing_listener_status}, expected rc=2"
done

# Exercise the real install lifecycle helpers as well as the orchestration
# boundary below: enable both definitions, skip an already-active sing-box,
# start only inactive Argo, and stop before Argo when runtime validation is
# unsafe.
saved_partial_service_is_active="$(declare -f partial_install_service_is_active)"
saved_validate_resume_runtime="$(declare -f validate_partial_install_resume_runtime)"
saved_systemctl="$(declare -f systemctl)"
saved_rc_service="$(declare -f rc-service)"
INSTALL_SERVICE_LOG="${tmp_dir}/install-service-helper.log"
INSTALL_SINGBOX_ACTIVE=1
INSTALL_ARGO_ACTIVE=0
INSTALL_RUNTIME_STATUS=0
validate_partial_install_resume_runtime() {
    printf 'validate %s\n' "$1" >> "$INSTALL_SERVICE_LOG"
    return "$INSTALL_RUNTIME_STATUS"
}
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$INSTALL_SERVICE_LOG"
    case "$*" in
        'is-active --quiet sing-box') [[ "$INSTALL_SINGBOX_ACTIVE" -eq 1 ]] ;;
        'is-active --quiet argo') [[ "$INSTALL_ARGO_ACTIVE" -eq 1 ]] ;;
        'start sing-box') INSTALL_SINGBOX_ACTIVE=1 ;;
        'start argo') INSTALL_ARGO_ACTIVE=1 ;;
        *) return 0 ;;
    esac
}
rc-update() { printf 'rc-update %s\n' "$*" >> "$INSTALL_SERVICE_LOG"; }
rc-service() {
    printf 'rc-service %s\n' "$*" >> "$INSTALL_SERVICE_LOG"
    case "$*" in
        'sing-box status') [[ "$INSTALL_SINGBOX_ACTIVE" -eq 1 ]] ;;
        'argo status') [[ "$INSTALL_ARGO_ACTIVE" -eq 1 ]] ;;
        'sing-box start') INSTALL_SINGBOX_ACTIVE=1 ;;
        'argo start') INSTALL_ARGO_ACTIVE=1 ;;
        *) return 0 ;;
    esac
}
for init_system in systemd openrc; do
    : > "$INSTALL_SERVICE_LOG"
    INSTALL_SINGBOX_ACTIVE=1
    INSTALL_ARGO_ACTIVE=0
    INSTALL_RUNTIME_STATUS=0
    assert_ok enable_install_services "$init_system"
    assert_ok start_pending_install_services "$init_system"
    if [ "$init_system" = systemd ]; then
        grep -Fqx 'systemctl enable sing-box' "$INSTALL_SERVICE_LOG" || \
            fail 'systemd install helper did not enable sing-box'
        grep -Fqx 'systemctl enable argo' "$INSTALL_SERVICE_LOG" || \
            fail 'systemd install helper did not enable Argo'
        grep -Fqx 'systemctl start argo' "$INSTALL_SERVICE_LOG" || \
            fail 'systemd install helper did not start inactive Argo'
        ! grep -Fqx 'systemctl start sing-box' "$INSTALL_SERVICE_LOG" || \
            fail 'systemd install helper restarted active sing-box'
    else
        grep -Fqx 'rc-update add sing-box default' "$INSTALL_SERVICE_LOG" || \
            fail 'OpenRC install helper did not enable sing-box'
        grep -Fqx 'rc-update add argo default' "$INSTALL_SERVICE_LOG" || \
            fail 'OpenRC install helper did not enable Argo'
        grep -Fqx 'rc-service argo start' "$INSTALL_SERVICE_LOG" || \
            fail 'OpenRC install helper did not start inactive Argo'
        ! grep -Fqx 'rc-service sing-box start' "$INSTALL_SERVICE_LOG" || \
            fail 'OpenRC install helper restarted active sing-box'
    fi
    [[ "$(grep -Fc "validate ${init_system}" "$INSTALL_SERVICE_LOG")" -eq 1 ]] || \
        fail "${init_system} install helper did not validate sing-box runtime exactly once"

    : > "$INSTALL_SERVICE_LOG"
    INSTALL_ARGO_ACTIVE=0
    INSTALL_RUNTIME_STATUS=2
    set +e
    start_pending_install_services "$init_system"
    helper_status=$?
    set -e
    [[ "$helper_status" -eq 2 ]] || \
        fail "${init_system} unsafe install runtime returned ${helper_status}, expected rc=2"
    ! grep -Eq '(systemctl start argo|rc-service argo start)' "$INSTALL_SERVICE_LOG" || \
        fail "${init_system} install helper started Argo after unsafe sing-box validation"
done
eval "$saved_partial_service_is_active"
eval "$saved_validate_resume_runtime"
eval "$saved_systemctl"
eval "$saved_rc_service"
unset -f rc-update

LISTENER_CASE=managed NGINX_CLASSIFY_STATUS=2
assert_fail validate_partial_install_resume_runtime systemd
NGINX_CLASSIFY_STATUS=0 NGINX_CONFIG_PORT=29999
assert_fail validate_partial_install_resume_runtime systemd

systemctl() {
    [[ "$*" != 'is-active --quiet sing-box' ]]
}
LISTENER_CASE=foreign-core NGINX_CLASSIFY_STATUS=0 NGINX_CONFIG_PORT=24444
assert_fail validate_partial_install_resume_runtime systemd

# Removing the durable resume state is the only action that permits a fresh
# install (and therefore fresh credentials) after an incomplete attempt.
assert_ok clear_partial_install_resume_state
[[ ! -e "$PARTIAL_INSTALL_STATE_FILE" ]] || fail 'resume state survived explicit cleanup'

load_function rollback_failed_install_firewall_records
load_function handle_failed_install_stage
load_function run_install_flow

detect_usable_init_system() { printf '%s\n' "$TEST_INIT_SYSTEM"; }
clear_install_complete_marker() { rm -f "${work_dir}/.install-complete"; }
manage_packages() { :; }
validate_singbox_config() { :; }
sleep() { :; }
change_hosts() { :; }
remove_owned_firewall_records_exact() { :; }
green() { :; }
yellow() { :; }
red() { :; }
validate_installed_singbox_config_strict() { :; }
get_hy2_certificate_fingerprint() { printf '%s\n' 'AA%3ABB%3ACC'; }
validate_partial_install_config_credentials() {
    [[ "$uuid" == '123e4567-e89b-42d3-a456-426614174000' && \
       "$password" == 'AbCdEfGhJkMnPqRsTuVwXy12' && \
       "$private_key" == 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' && \
       "$public_key" == 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' ]]
}
systemctl() { :; }
rc-service() { :; }
port_is_listening() {
    case "${1}/${2}" in
        24443/tcp|24443/udp|24444/udp|18001/tcp) return 0 ;;
        24444/tcp) [[ "$NGINX_READY" -eq 1 ]] ;;
        *) return 1 ;;
    esac
}
classify_nginx_subscription_config() { :; }
get_nginx_subscription_port() { printf '%s\n' 24444; }

record_late_stage() {
    local stage="$1"

    printf '%s\n' "$stage" >> "$INSTALL_CALL_LOG"
    [[ "$INSTALL_FAIL_STAGE" != "$stage" ]]
}
install_singbox() {
    install_count=$((install_count + 1))
    uuid='123e4567-e89b-42d3-a456-426614174000'
    password='AbCdEfGhJkMnPqRsTuVwXy12'
    private_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    public_key='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
    fingerprint='STALE'
    ARGO_FIXED_READY=0
    FIREWALL_LAST_ADDED_RECORDS=('iptables|4|sing-box-pre|24443|tcp')
    printf '{}\n' > "${conf_dir}/inbounds.json"
}
main_systemd_services() { service_count=$((service_count + 1)); }
alpine_openrc_services() { service_count=$((service_count + 1)); }
add_nginx_conf() {
    record_late_stage nginx || return 1
    NGINX_READY=1
}
get_info() { record_late_stage info; }
create_shortcut() { record_late_stage shortcut; }
mark_install_complete() {
    record_late_stage marker || return 1
    printf 'complete\n' > "${work_dir}/.install-complete"
}

run_partial_service_retry_case() {
    local init_system="$1" first_status
    local saved_prepare_partial_install_resume

    work_dir="${tmp_dir}/service-retry-${init_system}"
    conf_dir="${work_dir}/conf"
    PARTIAL_INSTALL_STATE_FILE="${work_dir}/install-resume.state"
    mkdir -p "$conf_dir"
    INSTALL_CALL_LOG="${work_dir}/calls.log"
    SERVICE_START_LOG="${work_dir}/service-starts.log"
    : > "$INSTALL_CALL_LOG"
    : > "$SERVICE_START_LOG"
    TEST_INIT_SYSTEM="$init_system"
    INSTALL_FAIL_STAGE=none
    NGINX_READY=0
    install_count=0
    service_count=0
    MOCK_SINGBOX_ACTIVE=0
    MOCK_ARGO_ACTIVE=0
    MOCK_ARGO_START_FAILURES=1
    FIREWALL_LAST_ADDED_RECORDS=()

    saved_prepare_partial_install_resume="$(declare -f prepare_partial_install_resume)"
    prepare_partial_install_resume() {
        [ -f "$PARTIAL_INSTALL_STATE_FILE" ] || return 1
        load_partial_install_resume_state
    }
    enable_install_services() {
        [ -f "$PARTIAL_INSTALL_STATE_FILE" ] || \
            fail "${init_system} enabled services before persisting resume state"
        printf 'enable %s\n' "$1" >> "$SERVICE_START_LOG"
    }
    start_pending_install_services() {
        [ -f "$PARTIAL_INSTALL_STATE_FILE" ] || \
            fail "${init_system} started services before persisting resume state"
        if [ "$MOCK_SINGBOX_ACTIVE" -eq 0 ]; then
            printf 'start sing-box\n' >> "$SERVICE_START_LOG"
            MOCK_SINGBOX_ACTIVE=1
        fi
        if [ "$MOCK_ARGO_ACTIVE" -eq 0 ]; then
            printf 'start argo\n' >> "$SERVICE_START_LOG"
            if [ "$MOCK_ARGO_START_FAILURES" -gt 0 ]; then
                MOCK_ARGO_START_FAILURES=$((MOCK_ARGO_START_FAILURES - 1))
                return 1
            fi
            MOCK_ARGO_ACTIVE=1
        fi
    }
    systemctl() {
        case "$*" in
            'is-active --quiet sing-box') [[ "$MOCK_SINGBOX_ACTIVE" -eq 1 ]] ;;
            'is-active --quiet argo') [[ "$MOCK_ARGO_ACTIVE" -eq 1 ]] ;;
            *) return 0 ;;
        esac
    }
    rc-service() {
        case "$*" in
            'sing-box restart') MOCK_SINGBOX_ACTIVE=1 ;;
            'argo restart')
                if [ "$MOCK_ARGO_START_FAILURES" -gt 0 ]; then
                    MOCK_ARGO_START_FAILURES=$((MOCK_ARGO_START_FAILURES - 1))
                    return 1
                fi
                MOCK_ARGO_ACTIVE=1
                ;;
            'sing-box status') [[ "$MOCK_SINGBOX_ACTIVE" -eq 1 ]] ;;
            'argo status') [[ "$MOCK_ARGO_ACTIVE" -eq 1 ]] ;;
            *) return 0 ;;
        esac
    }

    set +e
    run_install_flow >/dev/null 2>&1
    first_status=$?
    set -e
    [[ "$first_status" -eq 1 ]] || \
        fail "${init_system} partial service start returned ${first_status}, expected rc=1"
    [[ -f "$PARTIAL_INSTALL_STATE_FILE" ]] || \
        fail "${init_system} partial service start did not retain resume credentials"
    [[ "$install_count" -eq 1 && "$service_count" -eq 1 ]] || \
        fail "${init_system} partial service start did not run one install/definition pass"

    assert_ok run_install_flow
    [[ "$install_count" -eq 1 ]] || \
        fail "${init_system} service retry regenerated credentials"
    [[ "$service_count" -eq 1 ]] || \
        fail "${init_system} service retry rewrote managed definitions"
    [[ "$(grep -Fc 'start sing-box' "$SERVICE_START_LOG")" -eq 1 ]] || \
        fail "${init_system} service retry restarted an already active sing-box"
    [[ "$(grep -Fc 'start argo' "$SERVICE_START_LOG")" -eq 2 ]] || \
        fail "${init_system} service retry did not retry only the inactive Argo service"
    [[ ! -e "$PARTIAL_INSTALL_STATE_FILE" ]] || \
        fail "${init_system} successful service retry retained resume credentials"

    eval "$saved_prepare_partial_install_resume"
}

for TEST_INIT_SYSTEM in systemd openrc; do
    run_partial_service_retry_case "$TEST_INIT_SYSTEM"
done

enable_install_services() { :; }
start_pending_install_services() { :; }
systemctl() { :; }
rc-service() { :; }

for TEST_INIT_SYSTEM in systemd openrc; do
    for late_failure in nginx info shortcut marker; do
        work_dir="${tmp_dir}/reentry-${TEST_INIT_SYSTEM}-${late_failure}"
        conf_dir="${work_dir}/conf"
        PARTIAL_INSTALL_STATE_FILE="${work_dir}/install-resume.state"
        mkdir -p "$conf_dir"
        INSTALL_CALL_LOG="${work_dir}/calls.log"
        : > "$INSTALL_CALL_LOG"
        install_count=0
        service_count=0
        NGINX_READY=0
        INSTALL_FAIL_STAGE="$late_failure"
        FIREWALL_LAST_ADDED_RECORDS=()

        if run_install_flow >/dev/null 2>&1; then
            fail "${TEST_INIT_SYSTEM} ${late_failure} late failure unexpectedly succeeded"
        fi
        [[ -f "$PARTIAL_INSTALL_STATE_FILE" ]] || \
            fail "${TEST_INIT_SYSTEM} ${late_failure} did not retain resume credentials"
        [[ "$install_count" -eq 1 && "$service_count" -eq 1 ]] || \
            fail "${TEST_INIT_SYSTEM} ${late_failure} initial stage counts are wrong"

        INSTALL_FAIL_STAGE=none
        assert_ok run_install_flow
        [[ "$install_count" -eq 1 ]] || \
            fail "${TEST_INIT_SYSTEM} ${late_failure} retry regenerated credentials"
        [[ "$service_count" -eq 1 ]] || \
            fail "${TEST_INIT_SYSTEM} ${late_failure} retry rewrote active service definitions"
        [[ "$uuid" == '123e4567-e89b-42d3-a456-426614174000' ]] || \
            fail "${TEST_INIT_SYSTEM} ${late_failure} retry changed UUID"
        [[ "$fingerprint" == 'AA%3ABB%3ACC' ]] || \
            fail "${TEST_INIT_SYSTEM} ${late_failure} retry did not restore certificate fingerprint"
        [[ -f "${work_dir}/.install-complete" ]] || \
            fail "${TEST_INIT_SYSTEM} ${late_failure} retry did not complete"
        [[ ! -e "$PARTIAL_INSTALL_STATE_FILE" ]] || \
            fail "${TEST_INIT_SYSTEM} ${late_failure} left resume credentials after success"
    done
done

# A durable late-stage resume record takes precedence over legacy-install
# migration.  Otherwise shortcut/marker failures can be misclassified as a
# complete legacy install and the unfinished stage is never retried.
load_function prepare_existing_install
work_dir="${tmp_dir}/legacy-short-circuit"
PARTIAL_INSTALL_STATE_FILE="${work_dir}/install-resume.state"
mkdir -p "$work_dir"
printf 'resume evidence\n' > "$PARTIAL_INSTALL_STATE_FILE"
check_singbox() { :; }
is_install_complete() { return 1; }
legacy_install_is_complete() { :; }
LEGACY_MARK_CALLED=0
mark_install_complete() { LEGACY_MARK_CALLED=1; }
assert_fail prepare_existing_install
[[ "$LEGACY_MARK_CALLED" -eq 0 ]] || \
    fail 'late-stage resume evidence was replaced by legacy completion migration'

printf 'Partial install reentry tests passed.\n'
