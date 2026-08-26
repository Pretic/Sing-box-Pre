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
    is_valid_subscription_domain \
    is_argo_hostname \
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
    partial_install_argo_service_mode \
    validate_partial_install_argo_resume \
    partial_install_service_is_active \
    enable_install_services \
    partial_install_singbox_runtime_is_ready \
    wait_for_partial_install_singbox_ready \
    wait_for_partial_install_argo_stably_active \
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
ARGO_DOMAIN=''

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
grep -Fqx 'RESUME_VERSION=2' "$PARTIAL_INSTALL_STATE_FILE" || \
    fail 'partial install state did not use schema v2'
grep -Fqx 'ARGO_DOMAIN=' "$PARTIAL_INSTALL_STATE_FILE" || \
    fail 'quick Argo resume state did not persist an explicitly empty domain'
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
uuid='' password='' private_key='' public_key='' ARGO_FIXED_READY='' ARGO_DOMAIN='stale.example.com'
assert_ok load_partial_install_resume_state
[[ "$uuid" == '123e4567-e89b-42d3-a456-426614174000' ]] || fail 'UUID was not restored'
[[ "$password" == 'AbCdEfGhJkMnPqRsTuVwXy12' ]] || fail 'subscription token was not restored'
[[ "$private_key" == 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' ]] || fail 'private key was not restored'
[[ "$public_key" == 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' ]] || fail 'public key was not restored'
[[ "$ARGO_FIXED_READY" == 0 && -z "$ARGO_DOMAIN" ]] || \
    fail 'quick Argo resume did not clear the process domain'

# Fixed Argo recovery must survive a fresh process where ARGO_DOMAIN is empty.
ARGO_FIXED_READY=1
ARGO_DOMAIN='fixed.example.com'
assert_ok persist_partial_install_resume_state
grep -Fqx 'ARGO_DOMAIN=fixed.example.com' "$PARTIAL_INSTALL_STATE_FILE" || \
    fail 'fixed Argo resume state did not persist its domain'
cp "$PARTIAL_INSTALL_STATE_FILE" "${PARTIAL_INSTALL_STATE_FILE}.fixed-good"
uuid='' password='' private_key='' public_key='' ARGO_FIXED_READY='' ARGO_DOMAIN=''
assert_ok load_partial_install_resume_state
[[ "$ARGO_FIXED_READY" == 1 && "$ARGO_DOMAIN" == fixed.example.com ]] || \
    fail 'fixed Argo domain was not restored into an empty process environment'

# The schema is a strict record: fixed/quick domain combinations, duplicate
# keys, and line injection must all fail closed without changing good state.
cp "$PARTIAL_INSTALL_STATE_FILE" "${PARTIAL_INSTALL_STATE_FILE}.before-invalid"
ARGO_DOMAIN=''
assert_fail persist_partial_install_resume_state
cmp -s "$PARTIAL_INSTALL_STATE_FILE" "${PARTIAL_INSTALL_STATE_FILE}.before-invalid" || \
    fail 'invalid fixed Argo state replaced the last good resume record'
ARGO_FIXED_READY=0
ARGO_DOMAIN='fixed.example.com'
assert_fail persist_partial_install_resume_state
ARGO_FIXED_READY=1
ARGO_DOMAIN=$'fixed.example.com\nINJECTED=1'
assert_fail persist_partial_install_resume_state

cp "${PARTIAL_INSTALL_STATE_FILE}.fixed-good" "$PARTIAL_INSTALL_STATE_FILE"
printf 'ARGO_DOMAIN=other.example.com\n' >> "$PARTIAL_INSTALL_STATE_FILE"
assert_fail load_partial_install_resume_state
cp "${PARTIAL_INSTALL_STATE_FILE}.fixed-good" "$PARTIAL_INSTALL_STATE_FILE"
printf 'INJECTED=1\n' >> "$PARTIAL_INSTALL_STATE_FILE"
assert_fail load_partial_install_resume_state

# Legacy v1 records are compatible only for quick mode. A v1 fixed record lost
# its domain by design and therefore must make prepare fail closed with rc=2.
sed -e 's/^RESUME_VERSION=2$/RESUME_VERSION=1/' \
    -e 's/^ARGO_FIXED_READY=1$/ARGO_FIXED_READY=0/' \
    -e '/^ARGO_DOMAIN=/d' \
    "${PARTIAL_INSTALL_STATE_FILE}.fixed-good" > "$PARTIAL_INSTALL_STATE_FILE"
chmod 600 "$PARTIAL_INSTALL_STATE_FILE"
ARGO_FIXED_READY='' ARGO_DOMAIN='stale.example.com'
assert_ok load_partial_install_resume_state
[[ "$ARGO_FIXED_READY" == 0 && -z "$ARGO_DOMAIN" ]] || \
    fail 'legacy v1 quick state did not load safely with an empty domain'

sed -e 's/^RESUME_VERSION=2$/RESUME_VERSION=1/' \
    -e '/^ARGO_DOMAIN=/d' \
    "${PARTIAL_INSTALL_STATE_FILE}.fixed-good" > "$PARTIAL_INSTALL_STATE_FILE"
chmod 600 "$PARTIAL_INSTALL_STATE_FILE"
assert_fail load_partial_install_resume_state
set +e
prepare_partial_install_resume systemd
legacy_fixed_status=$?
set -e
[[ "$legacy_fixed_status" -eq 2 ]] || \
    fail "legacy v1 fixed state returned ${legacy_fixed_status}, expected prepare rc=2"

ARGO_FIXED_READY=0
ARGO_DOMAIN=''
assert_ok persist_partial_install_resume_state

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

# Resume must bind the restored fixed domain to the exact canonical Argo mode.
# Token mode carries the hostname only in resume state; local mode additionally
# requires exactly one matching tunnel.yml hostname.
ARGO_FIXED_READY=1
ARGO_DOMAIN='fixed.example.com'
assert_ok persist_partial_install_resume_state
render_argo_systemd_service token > "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service"
render_argo_openrc_service token > "${INSTALL_OPENRC_INIT_DIR}/argo"
chmod 700 "${INSTALL_OPENRC_INIT_DIR}/argo"
ARGO_FIXED_READY='' ARGO_DOMAIN=''
assert_ok load_partial_install_resume_state
for init_system in systemd openrc; do
    assert_ok validate_partial_install_argo_resume "$init_system"
done
[[ "$ARGO_DOMAIN" == fixed.example.com ]] || \
    fail 'token resume lost the restored fixed Argo domain'

render_argo_systemd_service quick > "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service"
render_argo_openrc_service quick > "${INSTALL_OPENRC_INIT_DIR}/argo"
chmod 700 "${INSTALL_OPENRC_INIT_DIR}/argo"
for init_system in systemd openrc; do
    assert_fail validate_partial_install_argo_resume "$init_system"
done

render_argo_systemd_service local > "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service"
render_argo_openrc_service local > "${INSTALL_OPENRC_INIT_DIR}/argo"
chmod 700 "${INSTALL_OPENRC_INIT_DIR}/argo"
cat > "${work_dir}/tunnel.yml" <<'YAML'
tunnel: 11111111-1111-4111-8111-111111111111
ingress:
  - hostname: fixed.example.com
    service: http://127.0.0.1:18001
  - service: http_status:404
YAML
ARGO_FIXED_READY='' ARGO_DOMAIN=''
assert_ok load_partial_install_resume_state
for init_system in systemd openrc; do
    assert_ok validate_partial_install_argo_resume "$init_system"
done
[[ "$ARGO_DOMAIN" == fixed.example.com ]] || \
    fail 'local resume lost the restored fixed Argo domain'

sed -i 's/fixed\.example\.com/wrong.example.com/' "${work_dir}/tunnel.yml"
for init_system in systemd openrc; do
    assert_fail validate_partial_install_argo_resume "$init_system"
done
sed -i 's/wrong\.example\.com/fixed.example.com/' "${work_dir}/tunnel.yml"
sed -i '/hostname: fixed\.example\.com/a\  - hostname: fixed.example.com\n    service: http://127.0.0.1:18001' \
    "${work_dir}/tunnel.yml"
for init_system in systemd openrc; do
    assert_fail validate_partial_install_argo_resume "$init_system"
done
cat > "${work_dir}/tunnel.yml" <<'YAML'
ingress:
  - hostname: fixed.example.com # injected
    service: http://127.0.0.1:18001
  - service: http_status:404
YAML
for init_system in systemd openrc; do
    assert_fail validate_partial_install_argo_resume "$init_system"
done

ARGO_FIXED_READY=0
ARGO_DOMAIN=''
assert_ok persist_partial_install_resume_state
render_argo_systemd_service quick > "${INSTALL_SYSTEMD_UNIT_DIR}/argo.service"
render_argo_openrc_service quick > "${INSTALL_OPENRC_INIT_DIR}/argo"
chmod 700 "${INSTALL_OPENRC_INIT_DIR}/argo"
for init_system in systemd openrc; do
    assert_ok validate_partial_install_argo_resume "$init_system"
done

saved_validate_argo_resume="$(declare -f validate_partial_install_argo_resume)"
ARGO_RESUME_VALIDATION_CALLED=0
validate_partial_install_argo_resume() {
    ARGO_RESUME_VALIDATION_CALLED=1
    return 1
}
set +e
prepare_partial_install_resume systemd
prepare_argo_status=$?
set -e
[[ "$prepare_argo_status" -eq 2 ]] || \
    fail "unsafe Argo resume returned ${prepare_argo_status}, expected prepare rc=2"
[[ "$ARGO_RESUME_VALIDATION_CALLED" -eq 1 ]] || \
    fail 'prepare bypassed fixed/quick Argo resume validation'
eval "$saved_validate_argo_resume"

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

# Exercise bounded service readiness through both init backends. A newly
# started sing-box may become active before its listeners appear, and Argo
# must remain active for two consecutive observations before it is accepted.
saved_partial_service_is_active="$(declare -f partial_install_service_is_active)"
saved_validate_resume_runtime="$(declare -f validate_partial_install_resume_runtime)"
saved_systemctl="$(declare -f systemctl)"
saved_rc_service="$(declare -f rc-service)"
saved_port_is_listening="$(declare -f port_is_listening)"
INSTALL_SERVICE_LOG="${tmp_dir}/install-service-helper.log"
SING_ACTIVE_SEQUENCE=()
ARGO_ACTIVE_SEQUENCE=()
SING_ACTIVE_INDEX=0
ARGO_ACTIVE_INDEX=0
INSTALL_PREFLIGHT_STATUS=0
INSTALL_PREFLIGHT_PROBE_ACTIVE=0
INSTALL_LISTENERS_READY=1
validate_partial_install_resume_runtime() {
    printf 'validate %s\n' "$1" >> "$INSTALL_SERVICE_LOG"
    if [ "$INSTALL_PREFLIGHT_PROBE_ACTIVE" -eq 1 ]; then
        partial_install_service_is_active "$1" sing-box || :
    fi
    return "$INSTALL_PREFLIGHT_STATUS"
}
partial_install_service_is_active() {
    local service_name="${2:-}" index length value=0

    if [ "$service_name" = sing-box ]; then
        index=$SING_ACTIVE_INDEX
        length=${#SING_ACTIVE_SEQUENCE[@]}
        if [ "$length" -gt 0 ]; then
            [ "$index" -lt "$length" ] || index=$((length - 1))
            value=${SING_ACTIVE_SEQUENCE[$index]}
        fi
        SING_ACTIVE_INDEX=$((SING_ACTIVE_INDEX + 1))
    else
        index=$ARGO_ACTIVE_INDEX
        length=${#ARGO_ACTIVE_SEQUENCE[@]}
        if [ "$length" -gt 0 ]; then
            [ "$index" -lt "$length" ] || index=$((length - 1))
            value=${ARGO_ACTIVE_SEQUENCE[$index]}
        fi
        ARGO_ACTIVE_INDEX=$((ARGO_ACTIVE_INDEX + 1))
    fi
    [ "$value" -eq 1 ]
}
port_is_listening() { [ "$INSTALL_LISTENERS_READY" -eq 1 ]; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$INSTALL_SERVICE_LOG"; }
rc-update() { printf 'rc-update %s\n' "$*" >> "$INSTALL_SERVICE_LOG"; }
rc-service() {
    printf 'rc-service %s\n' "$*" >> "$INSTALL_SERVICE_LOG"
}

run_start_readiness_case() {
    local expected_status="$1" init_system="$2" actual_status

    : > "$INSTALL_SERVICE_LOG"
    SING_ACTIVE_INDEX=0
    ARGO_ACTIVE_INDEX=0
    set +e
    start_pending_install_services "$init_system"
    actual_status=$?
    set -e
    [[ "$actual_status" -eq "$expected_status" ]] || \
        fail "${init_system} readiness returned ${actual_status}, expected ${expected_status}"
}

PARTIAL_INSTALL_READY_ATTEMPTS=6
PARTIAL_INSTALL_READY_INTERVAL=0
for init_system in systemd openrc; do
    : > "$INSTALL_SERVICE_LOG"
    assert_ok enable_install_services "$init_system"

    SING_ACTIVE_SEQUENCE=(0 0 1)
    ARGO_ACTIVE_SEQUENCE=(0 1 0 1 1)
    INSTALL_PREFLIGHT_STATUS=0
    INSTALL_LISTENERS_READY=1
    run_start_readiness_case 0 "$init_system"
    if [ "$init_system" = systemd ]; then
        grep -Fqx 'systemctl start sing-box' "$INSTALL_SERVICE_LOG" || \
            fail 'systemd slow-start case did not start sing-box'
        grep -Fqx 'systemctl start argo' "$INSTALL_SERVICE_LOG" || \
            fail 'systemd slow-start case did not start Argo'
    else
        grep -Fqx 'rc-service sing-box start' "$INSTALL_SERVICE_LOG" || \
            fail 'OpenRC slow-start case did not start sing-box'
        grep -Fqx 'rc-service argo start' "$INSTALL_SERVICE_LOG" || \
            fail 'OpenRC slow-start case did not start Argo'
    fi
    [[ "$ARGO_ACTIVE_INDEX" -ge 5 ]] || \
        fail "${init_system} Argo was accepted without two consecutive active checks"

    # The first active observation is not durable: sing-box may exit while
    # runtime validation is sampling it. Re-query after validation, restart an
    # inactive service, and still require bounded listener readiness.
    SING_ACTIVE_SEQUENCE=(1 0 0 1)
    ARGO_ACTIVE_SEQUENCE=(1 1 1)
    INSTALL_PREFLIGHT_STATUS=0
    INSTALL_PREFLIGHT_PROBE_ACTIVE=1
    INSTALL_LISTENERS_READY=1
    run_start_readiness_case 0 "$init_system"
    if [ "$init_system" = systemd ]; then
        grep -Fqx 'systemctl start sing-box' "$INSTALL_SERVICE_LOG" || \
            fail 'systemd active-to-inactive race skipped sing-box restart'
    else
        grep -Fqx 'rc-service sing-box start' "$INSTALL_SERVICE_LOG" || \
            fail 'OpenRC active-to-inactive race skipped sing-box restart'
    fi
    [[ "$SING_ACTIVE_INDEX" -ge 4 ]] || \
        fail "${init_system} active-to-inactive race skipped bounded sing-box readiness"
    INSTALL_PREFLIGHT_PROBE_ACTIVE=0

    PARTIAL_INSTALL_READY_ATTEMPTS=3
    SING_ACTIVE_SEQUENCE=(0 1 1 1)
    ARGO_ACTIVE_SEQUENCE=()
    INSTALL_PREFLIGHT_STATUS=0
    INSTALL_LISTENERS_READY=0
    run_start_readiness_case 1 "$init_system"
    ! grep -Eq '(systemctl start argo|rc-service argo start)' "$INSTALL_SERVICE_LOG" || \
        fail "${init_system} started Argo after sing-box readiness timeout"

    SING_ACTIVE_SEQUENCE=(1)
    ARGO_ACTIVE_SEQUENCE=()
    INSTALL_PREFLIGHT_STATUS=2
    INSTALL_LISTENERS_READY=0
    run_start_readiness_case 2 "$init_system"
    ! grep -Eq '(systemctl start sing-box|rc-service sing-box start)' "$INSTALL_SERVICE_LOG" || \
        fail "${init_system} restarted an already-active sing-box with missing listeners"

    SING_ACTIVE_SEQUENCE=(0)
    ARGO_ACTIVE_SEQUENCE=()
    INSTALL_PREFLIGHT_STATUS=2
    INSTALL_LISTENERS_READY=1
    run_start_readiness_case 2 "$init_system"
    ! grep -Eq '(systemctl start sing-box|rc-service sing-box start)' "$INSTALL_SERVICE_LOG" || \
        fail "${init_system} started sing-box over an inactive foreign listener"

    SING_ACTIVE_SEQUENCE=(1)
    ARGO_ACTIVE_SEQUENCE=(0 1 0 1)
    INSTALL_PREFLIGHT_STATUS=0
    INSTALL_LISTENERS_READY=1
    run_start_readiness_case 1 "$init_system"

    PARTIAL_INSTALL_READY_ATTEMPTS=6
done
eval "$saved_partial_service_is_active"
eval "$saved_validate_resume_runtime"
eval "$saved_systemctl"
eval "$saved_rc_service"
eval "$saved_port_is_listening"
unset -f rc-update
unset PARTIAL_INSTALL_READY_ATTEMPTS PARTIAL_INSTALL_READY_INTERVAL

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
