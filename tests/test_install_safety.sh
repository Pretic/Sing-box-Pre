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

assert_file_content() {
    local expected="$1"
    local path="$2"
    local description="$3"
    local actual
    actual="$(command cat "$path")"
    assert_equal "$expected" "$actual" "$description"
}

assert_no_temp_files() {
    local directory="$1"
    local pattern="$2"
    local description="$3"
    if compgen -G "${directory}/${pattern}" >/dev/null; then
        fail "$description"
    fi
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
    write_base64_subscription \
    sync_combined_subscription \
    update_sub \
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

subscription_root="${tmp_dir}/subscription-failures"
setup_subscription_fixture() {
    command rm -rf "$subscription_root"
    command mkdir -p "$subscription_root"
    work_dir="$subscription_root"
    client_dir="${work_dir}/url.txt"
    combined_client_dir="${work_dir}/all-url.txt"
    builtin printf '%s\n' 'vless://fixture' > "$client_dir"
    builtin printf '%s\n' 'cfy://fixture' > "${work_dir}/cfy-url.txt"
    builtin printf '%s\n' 'old-base-sub' > "${work_dir}/base-sub.txt"
    builtin printf '%s\n' 'old-cfy-sub' > "${work_dir}/cfy-sub.txt"
    builtin printf '%s\n' 'old-all-url' > "$combined_client_dir"
    builtin printf '%s\n' 'old-all-sub' > "${work_dir}/all-sub.txt"
    builtin printf '%s\n' 'old-sub' > "${work_dir}/sub.txt"
}

assert_subscription_publications_unchanged() {
    assert_file_content 'old-cfy-sub' "${work_dir}/cfy-sub.txt" 'cfy subscription changed after a failed sync'
    assert_file_content 'old-all-url' "$combined_client_dir" 'combined URL publication changed after a failed sync'
    assert_file_content 'old-all-sub' "${work_dir}/all-sub.txt" 'combined base64 publication changed after a failed sync'
    assert_file_content 'old-sub' "${work_dir}/sub.txt" 'main subscription changed after a failed sync'
}

setup_subscription_fixture
BASE64_PRIMARY_CALLS=0
BASE64_PIPELINE_FAILURE=0
base64() {
    if [[ "${1:-}" == '-w0' ]]; then
        BASE64_PRIMARY_CALLS=$((BASE64_PRIMARY_CALLS + 1))
        BASE64_PIPELINE_FAILURE=1
        return 1
    fi
    builtin printf 'partial-base64'
    [[ "$BASE64_PIPELINE_FAILURE" != 1 ]]
}
set +o pipefail
if write_base64_subscription "$client_dir" "${work_dir}/base-sub.txt" >/dev/null 2>&1; then
    fail 'write_base64_subscription ignored a failed fallback base64 producer without caller pipefail'
fi
set -o pipefail
unset -f base64
assert_file_content 'old-base-sub' "${work_dir}/base-sub.txt" 'failed base64 generation replaced the published subscription'
assert_no_temp_files "$work_dir" '.tmp.base-sub.txt.*' 'failed base64 generation left a temporary file'

setup_subscription_fixture
WRITE_STAGE_LOG="${work_dir}/write-stage.log"
mktemp() {
    builtin printf '%s\n' "${work_dir}/missing/.tmp.base-sub.txt.injected"
}
chmod() {
    builtin printf '%s\n' chmod >> "$WRITE_STAGE_LOG"
    return 0
}
mv() {
    builtin printf '%s\n' mv >> "$WRITE_STAGE_LOG"
    return 0
}
assert_fail write_base64_subscription "${work_dir}/missing-source.txt" "${work_dir}/base-sub.txt"
[[ ! -e "$WRITE_STAGE_LOG" ]] || fail 'write_base64_subscription continued after its empty-file truncate failed'
unset -f mktemp chmod mv
assert_file_content 'old-base-sub' "${work_dir}/base-sub.txt" 'failed empty subscription write replaced the published subscription'

setup_subscription_fixture
chmod() {
    [[ "${2:-}" != "${work_dir}/.tmp.base-sub.txt."* ]]
}
assert_fail write_base64_subscription "$client_dir" "${work_dir}/base-sub.txt"
unset -f chmod
assert_file_content 'old-base-sub' "${work_dir}/base-sub.txt" 'chmod failure replaced the published subscription'
assert_no_temp_files "$work_dir" '.tmp.base-sub.txt.*' 'chmod failure left a temporary subscription file'

setup_subscription_fixture
mv() {
    local target=''
    for target in "$@"; do :; done
    [[ "$target" != "${work_dir}/base-sub.txt" ]] || return 1
    command mv "$@"
}
assert_fail write_base64_subscription "$client_dir" "${work_dir}/base-sub.txt"
unset -f mv
assert_file_content 'old-base-sub' "${work_dir}/base-sub.txt" 'mv failure replaced the published subscription'
assert_no_temp_files "$work_dir" '.tmp.base-sub.txt.*' 'mv failure left a temporary subscription file'

run_combined_generation_failure() {
    local stage="$1"
    setup_subscription_fixture
    COMBINED_FAIL_STAGE="$stage"
    sed() {
        local source_file="${*: -1}"
        if [[ "$COMBINED_FAIL_STAGE" == sed_client && "$source_file" == "$client_dir" ]]; then
            return 1
        fi
        if [[ "$COMBINED_FAIL_STAGE" == sed_cfy && "$source_file" == "${work_dir}/cfy-url.txt" ]]; then
            return 1
        fi
        command sed "$@"
    }
    printf() {
        if [[ "$COMBINED_FAIL_STAGE" == separator && "$#" -eq 1 && "$1" == '\n' ]]; then
            return 1
        fi
        builtin printf "$@"
    }
    chmod() {
        if [[ "$COMBINED_FAIL_STAGE" == chmod && "${2:-}" == "${work_dir}/.tmp.all-url."* ]]; then
            return 1
        fi
        command chmod "$@"
    }

    assert_fail sync_combined_subscription
    unset -f sed printf chmod
    assert_subscription_publications_unchanged
    assert_no_temp_files "$work_dir" '.tmp.all-url.*' "${stage} failure left a combined-subscription temporary file"
}

for COMBINED_GENERATION_FAILURE in sed_client sed_cfy separator chmod; do
    run_combined_generation_failure "$COMBINED_GENERATION_FAILURE"
done

setup_subscription_fixture
SUBSCRIPTION_MV_FAIL_TARGET="${work_dir}/base-sub.txt"
mv() {
    local target=''
    for target in "$@"; do :; done
    if [[ "$target" == "$SUBSCRIPTION_MV_FAIL_TARGET" ]]; then
        return 1
    fi
    command mv "$@"
}
assert_fail update_sub
unset -f mv

atomic_write_source="$(extract_function atomic_write_file)"
run_empty_subscription_failure() {
    local failure_name="$1"
    command rm -rf "$subscription_root"
    command mkdir -p "$subscription_root"
    work_dir="$subscription_root"
    client_dir="${work_dir}/url.txt"
    combined_client_dir="${work_dir}/all-url.txt"
    ATOMIC_FAIL_TARGET="${work_dir}/${failure_name}"
    atomic_write_file() {
        local target_file="$1"
        if [[ "$target_file" == "$ATOMIC_FAIL_TARGET" ]]; then
            return 1
        fi
        command cat >/dev/null
    }
    assert_fail sync_combined_subscription
    unset -f atomic_write_file
    source <(printf '%s\n' "$atomic_write_source")
}

run_empty_subscription_failure all-url.txt
run_empty_subscription_failure all-sub.txt

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
    combined_client_dir="${work_dir}/all-url.txt"
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
    builtin printf '%s\n' 'custom://preserved' > "$client_dir"
}

run_get_info_generation_failure() {
    local stage="$1"
    setup_get_info_fixture "$stage"
    INFO_CAT_CALLS=0
    INFO_UPDATE_CALLED=0
    mktemp() {
        if [[ "$INFO_FAIL_STAGE" == truncate && "${1:-}" == "${work_dir}/.tmp.url.txt."* ]]; then
            builtin printf '%s\n' "${work_dir}/missing/.tmp.url.txt.injected"
            return 0
        fi
        command mktemp "$@"
    }
    cat() {
        if [[ "$#" -eq 0 ]]; then
            INFO_CAT_CALLS=$((INFO_CAT_CALLS + 1))
            if [[ "$INFO_FAIL_STAGE" == heredoc && "$INFO_CAT_CALLS" -eq 1 ]]; then
                return 1
            fi
            if [[ "$INFO_FAIL_STAGE" == append && "$INFO_CAT_CALLS" -eq 2 ]]; then
                return 1
            fi
        fi
        command cat "$@"
    }
    mv() {
        local target=''
        for target in "$@"; do :; done
        if [[ "$INFO_FAIL_STAGE" == mv && "$target" == "$client_dir" ]]; then
            return 1
        fi
        command mv "$@"
    }
    update_sub() {
        INFO_UPDATE_CALLED=1
        return 0
    }
    chmod() { command chmod "$@"; }

    assert_fail get_info
    unset -f mktemp cat mv update_sub chmod
    assert_file_content 'custom://preserved' "$client_dir" "${stage} failure replaced url.txt"
    [[ "$INFO_UPDATE_CALLED" -eq 0 ]] || fail "${stage} failure still called update_sub"
    assert_no_temp_files "$work_dir" '.tmp.url.txt.*' "${stage} failure left a url.txt temporary file"
}

for INFO_GENERATION_FAILURE in truncate heredoc append mv; do
    run_get_info_generation_failure "$INFO_GENERATION_FAILURE"
done

source <(printf '%s\n' "$(extract_function update_sub)")
mv() {
    local target=''
    for target in "$@"; do :; done
    if [[ "$INFO_FAIL_STAGE" == update_sub && "$target" == "${work_dir}/base-sub.txt" ]]; then
        return 1
    fi
    command mv "$@"
}
chmod() {
    [[ "$INFO_FAIL_STAGE" != chmod ]] || return 1
    command chmod "$@"
}

setup_get_info_fixture update_sub
assert_fail get_info
setup_get_info_fixture chmod
assert_fail get_info
unset -f mv chmod

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
systemctl() { return 0; }
sleep() { :; }
record_install_stage() {
    builtin printf '%s\n' "$1" >> "$INSTALL_CALL_LOG"
    [[ "$INSTALL_FAIL_STAGE" != "$1" ]]
}
main_systemd_services() { record_install_stage services; }
alpine_openrc_services() { record_install_stage services; }
change_hosts() { :; }
rc-service() { :; }
manage_packages() { record_install_stage packages; }
install_singbox() { record_install_stage install; }
validate_singbox_config() { record_install_stage config; }
add_nginx_conf() { record_install_stage nginx; }
get_info() { record_install_stage info; }
create_shortcut() { record_install_stage shortcut; }
green() { printf '%s\n' "$*"; }
yellow() { printf '%s\n' "$*"; }
red() { printf '%s\n' "$*"; }

load_function run_install_flow
load_function interactive_install

run_install_failure_case() {
    local mode="$1"
    local stage="$2"
    local output status expected_calls
    INSTALL_FAIL_STAGE="$stage"
    INSTALL_CALL_LOG="${tmp_dir}/install-${mode}-${stage}.log"
    : > "$INSTALL_CALL_LOG"
    set +e
    output="$(${mode}_install 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "${mode}_install ignored ${stage} failure"
    if grep -Fq 'sing-box 安装完成' <<< "$output"; then
        fail "${mode}_install reported success after ${stage} failure"
    fi
    case "$stage" in
        packages) expected_calls=$'packages' ;;
        install) expected_calls=$'packages\ninstall' ;;
        config) expected_calls=$'packages\ninstall\nconfig' ;;
        services) expected_calls=$'packages\ninstall\nconfig\nservices' ;;
        nginx) expected_calls=$'packages\ninstall\nconfig\nservices\nnginx' ;;
        info) expected_calls=$'packages\ninstall\nconfig\nservices\nnginx\ninfo' ;;
        shortcut) expected_calls=$'packages\ninstall\nconfig\nservices\nnginx\ninfo\nshortcut' ;;
    esac
    assert_file_content "$expected_calls" "$INSTALL_CALL_LOG" "${mode}_install did not stop at ${stage} failure"
}

for INSTALL_MODE in auto interactive; do
    for INSTALL_FAILURE in packages install config services nginx info shortcut; do
        run_install_failure_case "$INSTALL_MODE" "$INSTALL_FAILURE"
    done
done

install_case="$(sed -n '/^    -i | --install)/,/^        ;;/p' "$script")"
grep -Fq 'exit $?' <<< "$install_case" || \
    fail 'the --install command-line path masks auto_install failures'

interactive_case="$(sed -n '/^                1)/,/^                    ;;/p' "$script")"
grep -Fq 'interactive_install' <<< "$interactive_case" || \
    fail 'the interactive install path does not use the fail-fast install orchestrator'

echo 'Install safety tests passed.'
