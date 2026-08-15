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

assert_count() {
    local expected="$1"
    local pattern="$2"
    local text="$3"
    local description="$4"
    local actual
    actual="$(grep -Fc "$pattern" <<< "$text" || true)"
    assert_equal "$expected" "$actual" "$description"
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
assert_fail validate_port_value 0443 REALITY_PORT
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
REALITY_PORT=0443
NGINX_PORT=443
TUIC_PORT=23003
HY2_PORT=23005
ARGO_PORT=18001
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
assert_equal $'0.0.0.0\n::' "$(get_listener_address 1 1 1)" \
    'bindv6only explicit dual listeners'
assert_fail get_listener_address 0 0 0

for function_name in \
    render_vless_reality_inbound \
    render_argo_inbound \
    render_hysteria2_inbound \
    render_tuic_inbound \
    render_inbounds_config; do
    load_function "$function_name"
done

uuid='11111111-1111-4111-8111-111111111111'
private_key='test-private-key'
vless_port=12000
argo_port=18001
hy2_port=23005
tuic_port=23003
work_dir="${tmp_dir}/render-work"

inbounds_v4="$(render_inbounds_config 1 0 0)"
assert_count 3 '"listen": "0.0.0.0"' "$inbounds_v4" 'IPv4-only public inbound count'
assert_count 0 '"listen": "::"' "$inbounds_v4" 'IPv4-only IPv6 inbound count'

inbounds_v6="$(render_inbounds_config 0 1 0)"
assert_count 0 '"listen": "0.0.0.0"' "$inbounds_v6" 'IPv6-only IPv4 inbound count'
assert_count 3 '"listen": "::"' "$inbounds_v6" 'IPv6-only public inbound count'

inbounds_dual="$(render_inbounds_config 1 1 0)"
assert_count 0 '"listen": "0.0.0.0"' "$inbounds_dual" 'dual-stack shared-socket IPv4 inbound count'
assert_count 3 '"listen": "::"' "$inbounds_dual" 'dual-stack shared-socket inbound count'

inbounds_v6only="$(render_inbounds_config 1 1 1)"
assert_count 3 '"listen": "0.0.0.0"' "$inbounds_v6only" 'bindv6only IPv4 inbound count'
assert_count 3 '"listen": "::"' "$inbounds_v6only" 'bindv6only IPv6 inbound count'
for expected_tag in vless-reality-ipv6 hysteria2-ipv6 tuic-ipv6; do
    grep -Fq "\"tag\": \"${expected_tag}\"" <<< "$inbounds_v6only" || \
        fail "bindv6only rendering is missing unique tag ${expected_tag}"
done
assert_count 2 '"listen_port": 12000' "$inbounds_v6only" 'bindv6only Reality port count'
assert_count 2 '"listen_port": 23005' "$inbounds_v6only" 'bindv6only Hysteria2 port count'
assert_count 2 '"listen_port": 23003' "$inbounds_v6only" 'bindv6only TUIC port count'
assert_count 1 '"listen_port": 18001' "$inbounds_v6only" 'Argo loopback port count'
duplicate_tags="$(grep -o '"tag": "[^"]*"' <<< "$inbounds_v6only" | sort | uniq -d || true)"
[[ -z "$duplicate_tags" ]] || fail "bindv6only rendering contains duplicate tags: ${duplicate_tags}"
if command -v jq >/dev/null 2>&1; then
    for rendered in "$inbounds_v4" "$inbounds_v6" "$inbounds_dual" "$inbounds_v6only"; do
        jq -e . >/dev/null <<< "$rendered" || fail 'rendered inbounds are not valid JSON'
    done
fi

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

ufw() { printf 'ufw %s\n' "$*" >> "$CALL_LOG"; }
firewall-cmd() { printf 'firewall-cmd %s\n' "$*" >> "$CALL_LOG"; }
iptables() {
    printf 'iptables %s\n' "$*" >> "$CALL_LOG"
    [[ "${1:-}" != -C ]]
}
ip6tables() {
    printf 'ip6tables %s\n' "$*" >> "$CALL_LOG"
    [[ "${1:-}" != -C ]]
}
systemctl() {
    [[ "${1:-}" == is-active && "${2:-}" == firewalld ]]
}

for FIREWALL_BACKEND in ufw firewall-cmd iptables ip6tables; do
    : > "$CALL_LOG"
    command_exists() {
        [[ "$1" == "$FIREWALL_BACKEND" ]]
    }
    assert_ok allow_port 23001 tcp
    assert_ok allow_port 23003/udp
    if grep -Eq -- '--set-target|--set-policy|(^|[[:space:]])-P([[:space:]]|$)|default allow' "$CALL_LOG"; then
        fail "${FIREWALL_BACKEND} changed a global firewall policy"
    fi
    case "$FIREWALL_BACKEND" in
        ufw)
            grep -Fq 'ufw allow in 23001/tcp' "$CALL_LOG" || fail 'ufw exact TCP rule is missing'
            grep -Fq 'ufw allow in 23003/udp' "$CALL_LOG" || fail 'ufw exact UDP rule is missing'
            ;;
        firewall-cmd)
            grep -Fq -- '--add-port=23001/tcp' "$CALL_LOG" || fail 'firewalld exact TCP rule is missing'
            grep -Fq -- '--add-port=23003/udp' "$CALL_LOG" || fail 'firewalld exact UDP rule is missing'
            ;;
        iptables)
            grep -Fq 'iptables -I INPUT -p tcp --dport 23001 -j ACCEPT' "$CALL_LOG" || \
                fail 'iptables exact TCP rule is missing'
            grep -Fq 'iptables -I INPUT -p udp --dport 23003 -j ACCEPT' "$CALL_LOG" || \
                fail 'iptables exact UDP rule is missing'
            ;;
        ip6tables)
            grep -Fq 'ip6tables -I INPUT -p tcp --dport 23001 -j ACCEPT' "$CALL_LOG" || \
                fail 'ip6tables exact TCP rule is missing'
            grep -Fq 'ip6tables -I INPUT -p udp --dport 23003 -j ACCEPT' "$CALL_LOG" || \
                fail 'ip6tables exact UDP rule is missing'
            ;;
    esac
done

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
grep -Fq 'render_inbounds_config "$has_v4" "$has_v6" "$bindv6only"' <<< "$install_source" || \
    fail 'sing-box inbounds do not use the stack-aware renderer'
if grep -Fq 'ping -c' <<< "$install_source"; then
    fail 'install_singbox still uses ping to select the network stack'
fi

load_function get_info
get_public_ipv4() { printf '%s\n' '203.0.113.10'; }
get_public_ipv6() { return 1; }
get_realip() { return 1; }
get_subscription_host() { printf '%s\n' '203.0.113.10'; }
get_country_code() { printf '%s\n' 'US'; }
sanitize_node_name() { printf '%s\n' "$1"; }
get_default_node_name() { printf '%s\n' 'fixture'; }
format_node_name_prefix() { printf '%s-%s\n' "$1" "$2"; }
get_latest_argo_domain() { return 1; }
restart_argo() { :; }
list_argo_client_addresses() { printf '%s\t%s\n' 'cdn.example.test' stable; }
resolve_installed_subscription_source_url() { return 1; }
build_http_subscription_url() { printf '%s\n' 'http://203.0.113.10:23001/sub'; }
show_subscription_links() { :; }
clear() { :; }

setup_get_info_fixture() {
    work_dir="${tmp_dir}/get-info"
    client_dir="${work_dir}/url.txt"
    command rm -rf "$work_dir"
    command mkdir -p "$work_dir"
    uuid='11111111-1111-4111-8111-111111111111'
    public_key='test-public-key'
    vless_port=12000
    nginx_port=23001
    hy2_port=23005
    tuic_port=23003
    password='test-password'
    fingerprint='test-fingerprint'
    NODE_NAME='fixture'
    SKIP_NODE_NAME_PROMPT=1
    ARGO_FIXED_READY=1
    ARGO_DOMAIN='argo.example.test'
    CFIP='cdn.example.test'
    CFPORT=443
    INCLUDE_UDP_LINKS=0
    re=''
    purple=''
    INFO_FAIL_STAGE="$1"
}
update_sub() {
    if [[ "$INFO_FAIL_STAGE" == update_sub ]]; then
        return 1
    fi
    printf '%s\n' subscription > "${work_dir}/sub.txt"
}
chmod() {
    [[ "$INFO_FAIL_STAGE" != chmod ]]
}

setup_get_info_fixture update_sub
assert_fail get_info
setup_get_info_fixture chmod
assert_fail get_info
unset -f chmod

add_nginx_source="$(sed -n '/^add_nginx_conf() {/,/^# 从已安装配置中获取UUID/p' "$script" | sed '$d')"
[[ -n "$add_nginx_source" ]] || fail 'add_nginx_conf is not implemented'
grep -Fq 'NGINX_MAIN_CONF' <<< "$add_nginx_source" || \
    fail 'add_nginx_conf does not expose an isolated main-config fixture path'
source <(printf '%s\n' "$add_nginx_source")

run_add_nginx_failure() {
    local stage="$1"
    local fixture="${tmp_dir}/nginx-${stage}"
    command rm -rf "$fixture"
    command mkdir -p "$fixture/conf.d"
    NGINX_MAIN_CONF="${fixture}/nginx.conf"
    NGINX_CONF_DIR="${fixture}/conf.d"
    NGINX_SUBSCRIPTION_CONF="${fixture}/conf.d/sing-box.conf"
    NGINX_FAIL_STAGE="$stage"
    NGINX_SED_CALLS=0
    if [[ "$stage" != write ]]; then
        printf '%s\n' 'http {' '}' > "$NGINX_MAIN_CONF"
    fi

    command_exists() { [[ "$1" == nginx ]]; }
    mkdir() {
        [[ "$NGINX_FAIL_STAGE" != mkdir ]] || return 1
        command mkdir "$@"
    }
    cp() {
        [[ "$NGINX_FAIL_STAGE" != cp ]] || return 1
        command cp "$@"
    }
    chmod() { :; }
    sed() {
        if [[ "$NGINX_FAIL_STAGE" == sed ]]; then
            return 1
        fi
        if [[ "$NGINX_FAIL_STAGE" == include ]]; then
            NGINX_SED_CALLS=$((NGINX_SED_CALLS + 1))
            [[ "$NGINX_SED_CALLS" -eq 1 ]]
            return
        fi
        command sed "$@"
    }
    cat() {
        [[ "$NGINX_FAIL_STAGE" != write ]] || return 1
        command cat "$@"
    }
    apply_nginx_subscription_config() { :; }

    assert_fail add_nginx_conf
    unset -f mkdir cp chmod sed cat
}

for NGINX_FAILURE in mkdir cp sed include write; do
    run_add_nginx_failure "$NGINX_FAILURE"
done

shortcut_source="$(extract_function create_shortcut)"
[[ -n "$shortcut_source" ]] || fail 'create_shortcut is not implemented'
grep -Fq 'SHORTCUT_ROOT' <<< "$shortcut_source" || \
    fail 'create_shortcut does not expose an isolated filesystem fixture root'
source <(printf '%s\n' "$shortcut_source")

run_shortcut_case() {
    local stage="$1"
    local fixture="${tmp_dir}/shortcut-${stage}"
    command rm -rf "$fixture"
    command mkdir -p "${fixture}/etc/sing-box"
    SHORTCUT_ROOT="$fixture"
    work_dir="${fixture}/etc/sing-box"
    SHORTCUT_FAIL_STAGE="$stage"

    cat() {
        [[ "$SHORTCUT_FAIL_STAGE" != write ]] || return 1
        command cat "$@"
    }
    chmod() {
        [[ "$SHORTCUT_FAIL_STAGE" != chmod ]] || return 1
        command chmod "$@"
    }
    mkdir() {
        if [[ "$SHORTCUT_FAIL_STAGE" == mkdir && "$*" == *'/usr/local/bin'* ]]; then
            return 1
        fi
        command mkdir "$@"
    }
    ln() {
        local target=''
        for target in "$@"; do :; done
        [[ "$SHORTCUT_FAIL_STAGE" != ln ]] || return 1
        if [[ "$SHORTCUT_FAIL_STAGE" == missing_second && "$target" == "${SHORTCUT_ROOT}/usr/bin/sb" ]]; then
            return 0
        fi
        command ln "$@"
    }

    if [[ "$stage" == none ]]; then
        assert_ok create_shortcut
        [[ -s "${fixture}/usr/local/bin/sb" && -s "${fixture}/usr/bin/sb" ]] || \
            fail 'create_shortcut did not create both fixture links'
        if [[ "$(uname -s)" != MINGW* ]]; then
            [[ -L "${fixture}/usr/local/bin/sb" && -L "${fixture}/usr/bin/sb" ]] || \
                fail 'create_shortcut fixture outputs are not symbolic links'
        fi
    else
        assert_fail create_shortcut
    fi
    unset -f cat chmod mkdir ln
}

for SHORTCUT_FAILURE in write chmod mkdir ln missing_second; do
    run_shortcut_case "$SHORTCUT_FAILURE"
done
run_shortcut_case none

sing_box_bin="${SING_BOX_BIN:-/etc/sing-box/sing-box}"
if [[ -x "$sing_box_bin" ]] && command -v openssl >/dev/null 2>&1; then
    check_root="${tmp_dir}/sing-box-check"
    command mkdir -p "${check_root}/conf"
    work_dir="$check_root"
    keypair="$($sing_box_bin generate reality-keypair)"
    private_key="$(awk '/PrivateKey:/ {print $2}' <<< "$keypair")"
    public_key="$(awk '/PublicKey:/ {print $2}' <<< "$keypair")"
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key" >/dev/null 2>&1
    openssl req -new -x509 -days 1 -key "${work_dir}/private.key" \
        -out "${work_dir}/cert.pem" -subj '/CN=bing.com' >/dev/null 2>&1
    render_inbounds_config 1 1 1 > "${check_root}/conf/inbounds.json"
    printf '%s\n' '{"outbounds":[{"type":"direct","tag":"direct"}]}' > "${check_root}/conf/outbounds.json"
    printf '%s\n' '{"endpoints":[]}' > "${check_root}/conf/endpoints.json"
    printf '%s\n' '{"route":{"rules":[],"final":"direct"}}' > "${check_root}/conf/route.json"
    "$sing_box_bin" check -C "${check_root}/conf" >/dev/null 2>&1 || \
        fail 'sing-box rejected the bindv6only dual-listener fixture'
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
