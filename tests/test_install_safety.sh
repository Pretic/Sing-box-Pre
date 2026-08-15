#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

load_function() {
    local function_name="$1"
    local function_source
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "${function_name} is not implemented"
    source <(printf '%s\n' "$function_source")
}

assert_ok() {
    "$@" >/dev/null 2>&1 || fail "expected success: $*"
}

assert_fail() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure: $*"
    fi
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    [[ "$actual" == "$expected" ]] || \
        fail "${description}: expected '${expected}', got '${actual}'"
}

for function_name in \
    validate_port_value \
    resolve_service_ports \
    port_is_listening \
    check_service_ports_available \
    get_listener_address \
    load_install_settings \
    persist_install_settings \
    atomic_write_file \
    manage_packages \
    allow_port \
    is_valid_subscription_path \
    is_valid_http_subscription_path \
    render_nginx_subscription_location \
    render_nginx_subscription_server \
    auto_install; do
    load_function "$function_name"
done

assert_fail validate_port_value '' REALITY_PORT
assert_fail validate_port_value 0 REALITY_PORT
assert_fail validate_port_value 65536 REALITY_PORT
assert_fail validate_port_value not-a-port REALITY_PORT
assert_ok validate_port_value 443 REALITY_PORT

PORT=10000
REALITY_PORT=''
NGINX_PORT=''
TUIC_PORT=''
HY2_PORT=''
ARGO_PORT=''
assert_ok resolve_service_ports
assert_equal '10000,10001,10002,10003,8001' \
    "$vless_port,$nginx_port,$tuic_port,$hy2_port,$argo_port" \
    'default service ports changed'

PORT=65533
REALITY_PORT=''
NGINX_PORT=''
TUIC_PORT=''
HY2_PORT=''
ARGO_PORT=''
assert_fail resolve_service_ports

PORT=12000
REALITY_PORT=''
NGINX_PORT=23001
TUIC_PORT=23003
HY2_PORT=23005
ARGO_PORT=18001
assert_ok resolve_service_ports
assert_equal '12000,23001,23003,23005,18001' \
    "$vless_port,$nginx_port,$tuic_port,$hy2_port,$argo_port" \
    'explicit service ports were not preserved'

PORT=12000
REALITY_PORT=23001
NGINX_PORT=23001
TUIC_PORT=23003
HY2_PORT=23005
ARGO_PORT=18001
assert_fail resolve_service_ports

command_exists() { [[ "$1" == ss ]]; }
ss() {
    if [[ "$*" == *':23003'* ]]; then
        printf '%s\n' 'udp UNCONN 0 0 0.0.0.0:23003 0.0.0.0:*'
    fi
}
PORT=12000
REALITY_PORT=''
NGINX_PORT=23001
TUIC_PORT=23003
HY2_PORT=23005
ARGO_PORT=18001
assert_ok resolve_service_ports
assert_fail check_service_ports_available
ss() { :; }
assert_ok check_service_ports_available

settings_file="${tmp_dir}/install.env"
PORT=12000
REALITY_PORT=22001
NGINX_PORT=23001
TUIC_PORT=23003
HY2_PORT=23005
ARGO_PORT=18001
assert_ok persist_install_settings "$settings_file"
for expected_line in \
    'PORT=12000' \
    'REALITY_PORT=22001' \
    'NGINX_PORT=23001' \
    'TUIC_PORT=23003' \
    'HY2_PORT=23005' \
    'ARGO_PORT=18001'; do
    grep -Fxq "$expected_line" "$settings_file" || \
        fail "install.env is missing ${expected_line}"
done
if [[ "$(uname -s)" == MINGW* ]]; then
    grep -Fq 'atomic_write_file "$settings_file" 600' \
        <<< "$(extract_function persist_install_settings)" || \
        fail 'persist_install_settings does not request mode 0600'
else
    assert_equal 600 "$(stat -c '%a' "$settings_file")" 'install.env mode'
fi
if grep -Eq 'UUID|PRIVATE|PASSWORD|TOKEN|AUTH' "$settings_file"; then
    fail 'install.env contains a secret setting'
fi

unset PORT REALITY_PORT NGINX_PORT TUIC_PORT HY2_PORT ARGO_PORT
assert_ok load_install_settings "$settings_file"
assert_equal '12000,22001,23001,23003,23005,18001' \
    "$PORT,$REALITY_PORT,$NGINX_PORT,$TUIC_PORT,$HY2_PORT,$ARGO_PORT" \
    'saved install settings were not loaded'
REALITY_PORT=24001
assert_ok load_install_settings "$settings_file"
assert_equal 24001 "$REALITY_PORT" 'environment override was replaced by install.env'

assert_equal '0.0.0.0' "$(get_listener_address 1 0 0)" 'IPv4-only listener'
assert_equal '::' "$(get_listener_address 0 1 0)" 'IPv6-only listener'
assert_equal '::' "$(get_listener_address 1 1 0)" 'dual-stack listener'
assert_equal '0.0.0.0' "$(get_listener_address 1 1 1)" \
    'bindv6only dual-stack listener'
assert_fail get_listener_address 0 0 0

token='0123456789abcdefghjkmnpqrstvwxyz'
nginx_v4_only="$(render_nginx_subscription_server 23001 "/${token}" '' 0)"
grep -Fq 'listen 23001;' <<< "$nginx_v4_only" || fail 'Nginx IPv4 listen is missing'
if grep -Fq 'listen [::]:23001;' <<< "$nginx_v4_only"; then
    fail 'Nginx emitted an IPv6 listen without IPv6 socket support'
fi
nginx_dual="$(render_nginx_subscription_server 23001 "/${token}" '' 1)"
grep -Fq 'listen [::]:23001;' <<< "$nginx_dual" || \
    fail 'Nginx IPv6 listen is missing when IPv6 sockets are supported'

CALL_LOG="${tmp_dir}/package-calls.log"
export CALL_LOG
red() { :; }
green() { :; }
yellow() { :; }
apt() { printf 'apt %s\n' "$*" >> "$CALL_LOG"; }
dnf() { printf 'dnf %s\n' "$*" >> "$CALL_LOG"; }
yum() { printf 'yum %s\n' "$*" >> "$CALL_LOG"; }
apk() { printf 'apk %s\n' "$*" >> "$CALL_LOG"; }

for package_manager in apt dnf yum apk; do
    : > "$CALL_LOG"
    MOCK_PACKAGE_MANAGER="$package_manager"
    command_exists() {
        [[ "$1" == "$MOCK_PACKAGE_MANAGER" ]]
    }
    work_dir="${tmp_dir}/not-installed-${package_manager}"
    assert_ok manage_packages install missing-tool
    if grep -Eiq '(^|[[:space:]])(upgrade|full-upgrade|dist-upgrade)([[:space:]]|$)' "$CALL_LOG"; then
        fail "${package_manager} performed a full-system upgrade"
    fi
    if grep -Eq '^(dnf|yum) update([[:space:]]|$)' "$CALL_LOG"; then
        fail "${package_manager} performed a full-system update"
    fi
    case "$package_manager" in
        apt) grep -Fq 'apt update -y' "$CALL_LOG" || fail 'apt metadata was not refreshed' ;;
        dnf) grep -Fq 'dnf makecache' "$CALL_LOG" || fail 'dnf metadata was not refreshed safely' ;;
        yum) grep -Fq 'yum makecache' "$CALL_LOG" || fail 'yum metadata was not refreshed safely' ;;
        apk) grep -Fq 'apk update' "$CALL_LOG" || fail 'apk metadata was not refreshed' ;;
    esac
done

: > "$CALL_LOG"
command_exists() {
    case "$1" in
        firewall-cmd|netfilter-persistent|service) return 0 ;;
        *) return 1 ;;
    esac
}
systemctl() {
    [[ "${1:-}" == is-active && "${2:-}" == firewalld ]]
}
firewall-cmd() { printf 'firewall-cmd %s\n' "$*" >> "$CALL_LOG"; }
service() { printf 'service %s\n' "$*" >> "$CALL_LOG"; }
assert_ok allow_port 23001 tcp
assert_ok allow_port 23003/udp
if grep -Eq -- '--set-target|--set-policy|(^|[[:space:]])-P([[:space:]]|$)|default allow' "$CALL_LOG"; then
    fail 'allow_port changed a global firewall policy'
fi
grep -Fq -- '--add-port=23001/tcp' "$CALL_LOG" || fail 'exact TCP firewall port is missing'
grep -Fq -- '--add-port=23003/udp' "$CALL_LOG" || fail 'exact UDP firewall port is missing'

install_source="$(sed -n '/^install_singbox() {/,/^# debian\/ubuntu\/centos/p' "$script" | sed '$d')"
[[ -n "$install_source" ]] || fail 'install_singbox is not implemented'
resolve_line="$(grep -n 'resolve_service_ports' <<< "$install_source" | head -1 | cut -d: -f1)"
download_line="$(grep -n 'download_binary' <<< "$install_source" | head -1 | cut -d: -f1)"
write_line="$(grep -n 'mkdir -p.*work_dir' <<< "$install_source" | head -1 | cut -d: -f1)"
[[ -n "$resolve_line" && -n "$download_line" && -n "$write_line" ]] || \
    fail 'install_singbox does not wire validated ports before installation'
(( resolve_line < download_line && resolve_line < write_line )) || \
    fail 'service ports are not validated before downloads or writes'
grep -Fq 'persist_install_settings' <<< "$install_source" || \
    fail 'validated install settings are not persisted'
grep -Fq 'check_service_ports_available' <<< "$install_source" || \
    fail 'auto-install does not reject occupied service ports'
grep -Fq 'get_listener_address' <<< "$install_source" || \
    fail 'sing-box inbounds do not use the stack-aware listener helper'
if grep -Fq 'ping -c' <<< "$install_source"; then
    fail 'install_singbox still uses ping to select the network stack'
fi

check_singbox() { return 2; }
command_exists() { [[ "$1" == systemctl ]]; }
systemctl() { [[ "$AUTO_FAIL_STAGE" != services ]]; }
sleep() { :; }
main_systemd_services() { [[ "$AUTO_FAIL_STAGE" != services ]]; }
alpine_openrc_services() { [[ "$AUTO_FAIL_STAGE" != services ]]; }
change_hosts() { :; }
rc-service() { :; }
manage_packages() { [[ "$AUTO_FAIL_STAGE" != packages ]]; }
install_singbox() { [[ "$AUTO_FAIL_STAGE" != install ]]; }
validate_singbox_config() { [[ "$AUTO_FAIL_STAGE" != config ]]; }
add_nginx_conf() { [[ "$AUTO_FAIL_STAGE" != nginx ]]; }
get_info() { [[ "$AUTO_FAIL_STAGE" != info ]]; }
create_shortcut() { [[ "$AUTO_FAIL_STAGE" != shortcut ]]; }
green() { printf '%s\n' "$*"; }
yellow() { printf '%s\n' "$*"; }
red() { printf '%s\n' "$*"; }

for AUTO_FAIL_STAGE in packages install config services nginx info shortcut; do
    set +e
    auto_output="$(auto_install 2>&1)"
    auto_status=$?
    set -e
    [[ "$auto_status" -ne 0 ]] || fail "auto_install ignored ${AUTO_FAIL_STAGE} failure"
    if grep -Fq 'sing-box 安装完成' <<< "$auto_output"; then
        fail "auto_install reported success after ${AUTO_FAIL_STAGE} failure"
    fi
done

install_case="$(sed -n '/^    -i | --install)/,/^        ;;/p' "$script")"
grep -Fq 'exit $?' <<< "$install_case" || \
    fail 'the --install command-line path masks auto_install failures'

echo 'Install safety tests passed.'
