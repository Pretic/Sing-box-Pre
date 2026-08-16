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

assert_mode() {
    local expected="$1"
    local path="$2"
    case "$(uname -s)" in
        MINGW*) return 0 ;;
    esac
    assert_equal "$expected" "$(stat -c '%a' "$path")" "unexpected mode for ${path}"
}

for function_name in \
    atomic_write_secret_file \
    harden_runtime_secret_permissions \
    write_fixed_argo_credentials \
    write_argo_systemd_service \
    write_argo_openrc_service \
    create_shortcut \
    update_local_manager \
    probe_proxy_url \
    detect_argo_tunnel_mode \
    refresh_quick_argo; do
    load_function "$function_name"
done

grep -Eq '^umask[[:space:]]+077([[:space:]]|$)' "$script" || \
    fail 'sing-box.sh does not establish umask 077 before secret generation'

green() { :; }
red() { printf '%s\n' "$*" >&2; }
yellow() { printf '%s\n' "$*" >&2; }

# The normal installation path must keep a syntax-checked local manager and
# create only local wrappers. It must not need GitHub for routine `sb` use.
shortcut_root="${tmp_dir}/shortcut"
manager_source="${tmp_dir}/manager-source.sh"
mkdir -p "${shortcut_root}/etc/sing-box"
printf '%s\n' '#!/bin/bash' 'printf "fixture manager\\n"' > "$manager_source"
MANAGER_SOURCE_SCRIPT="$manager_source"
work_dir="${shortcut_root}/etc/sing-box"
assert_ok create_shortcut "$shortcut_root"

local_manager="${shortcut_root}/usr/local/lib/sing-box-pre/sing-box.sh"
wrapper="${shortcut_root}/etc/sing-box/sb.sh"
[[ -f "$local_manager" ]] || fail 'create_shortcut did not install the local manager'
assert_mode 700 "$local_manager"
assert_equal $'#!/bin/bash\nset -e\nexec /usr/local/lib/sing-box-pre/sing-box.sh "$@"' \
    "$(cat "$wrapper")" 'unexpected sb wrapper content'
! grep -Eq 'raw\.githubusercontent\.com.*sing-box\.sh' "$wrapper" || \
    fail 'routine sb wrapper still downloads the manager'
assert_equal "${shortcut_root}/etc/sing-box/sb.sh" \
    "$(readlink "${shortcut_root}/usr/local/bin/sb")" 'local sb link target'
assert_equal "${shortcut_root}/etc/sing-box/sb.sh" \
    "$(readlink "${shortcut_root}/usr/bin/sb")" 'usr sb link target'
assert_equal '/etc/sing-box/sing-box' \
    "$(readlink "${shortcut_root}/usr/local/bin/sing-box")" 'sing-box binary link target'

# Explicit update is the only manager path that downloads. It validates first,
# preserves the previous version, and atomically installs mode 0700.
update_root="${tmp_dir}/update"
update_manager="${update_root}/usr/local/lib/sing-box-pre/sing-box.sh"
mkdir -p "$(dirname "$update_manager")"
printf '%s\n' '#!/bin/bash' 'printf "old manager\\n"' > "$update_manager"
chmod 700 "$update_manager"
old_manager_content="$(cat "$update_manager")"
curl_log="${tmp_dir}/curl-update.log"
download_body='#!/bin/bash
printf "new manager\\n"
'
curl() {
    local output='' argument
    : > "$curl_log"
    while [[ "$#" -gt 0 ]]; do
        argument="$1"
        printf '%s\n' "$argument" >> "$curl_log"
        shift
        if [[ "$argument" == -o ]]; then
            [[ "$#" -gt 0 ]] || return 2
            output="$1"
            printf '%s\n' "$1" >> "$curl_log"
            shift
        fi
    done
    [[ -n "$output" ]] || return 2
    printf '%s' "$download_body" > "$output"
}

assert_ok update_local_manager "$update_root" 'https://updates.example.test/sing-box.sh'
grep -Fqx 'https://updates.example.test/sing-box.sh' "$curl_log" || \
    fail 'explicit update did not download the requested manager URL'
assert_equal "${download_body%$'\n'}" "$(cat "$update_manager")" 'updated manager content'
assert_equal "$old_manager_content" "$(cat "${update_manager}.previous")" \
    'previous manager backup'
assert_mode 700 "$update_manager"
assert_mode 700 "${update_manager}.previous"

previous_content="$(cat "${update_manager}.previous")"
current_content="$(cat "$update_manager")"
download_body=$'#!/bin/bash\nif\n'
assert_fail update_local_manager "$update_root" 'https://updates.example.test/invalid.sh'
assert_equal "$current_content" "$(cat "$update_manager")" \
    'invalid explicit update replaced the working manager'
assert_equal "$previous_content" "$(cat "${update_manager}.previous")" \
    'invalid explicit update replaced the previous backup'
unset -f curl

# Secret writers must be safe even when invoked by code running with umask 022.
secret_root="${tmp_dir}/secrets"
mkdir -p "${secret_root}/etc/sing-box/conf"
old_umask="$(umask)"
umask 022
printf '%s\n' '{"inbounds":[{"users":[{"uuid":"fixture-uuid"}]}]}' | \
    atomic_write_secret_file "${secret_root}/etc/sing-box/conf/inbounds.json"
printf '%s\n' '{"outbounds":[{"password":"fixture-password"}]}' | \
    atomic_write_secret_file "${secret_root}/etc/sing-box/conf/outbounds.json"
assert_ok write_fixed_argo_credentials json \
    '{"TunnelID":"fixture","TunnelSecret":"json-secret-value"}' "$secret_root"
umask "$old_umask"
for secret_file in \
    "${secret_root}/etc/sing-box/conf/inbounds.json" \
    "${secret_root}/etc/sing-box/conf/outbounds.json" \
    "${secret_root}/etc/sing-box/tunnel.json"; do
    assert_mode 600 "$secret_file"
done
chmod 644 \
    "${secret_root}/etc/sing-box/conf/inbounds.json" \
    "${secret_root}/etc/sing-box/conf/outbounds.json" \
    "${secret_root}/etc/sing-box/tunnel.json"
assert_ok harden_runtime_secret_permissions "$secret_root"
for secret_file in \
    "${secret_root}/etc/sing-box/conf/inbounds.json" \
    "${secret_root}/etc/sing-box/conf/outbounds.json" \
    "${secret_root}/etc/sing-box/tunnel.json"; do
    assert_mode 600 "$secret_file"
done

token_output="$(write_fixed_argo_credentials token 'secret-value' "$secret_root" 2>&1)"
[[ "$token_output" != *secret-value* ]] || fail 'fixed Tunnel token was printed'
argo_env="${secret_root}/etc/sing-box/argo.env"
assert_mode 600 "$argo_env"
assert_equal 'TUNNEL_TOKEN=secret-value' "$(cat "$argo_env")" \
    'fixed Tunnel environment file content'
[[ ! -e "${secret_root}/etc/sing-box/argo.token" ]] || \
    fail 'fixed Tunnel token was stored in the obsolete token file'

safe_env_content="$(cat "$argo_env")"
for malicious_token in \
    'secret value' \
    'secret"value' \
    "secret'value" \
    'secret$value' \
    $'secret-value\nINJECTED_VARIABLE=1' \
    $'secret-value\rINJECTED_DIRECTIVE=1'; do
    assert_fail write_fixed_argo_credentials token "$malicious_token" "$secret_root"
    assert_equal "$safe_env_content" "$(cat "$argo_env")" \
        'rejected token injection changed argo.env'
done
assert_equal 1 "$(wc -l < "$argo_env" | tr -d '[:space:]')" \
    'fixed Tunnel environment file contains injected directives'
[[ "$(cat "$argo_env")" =~ ^TUNNEL_TOKEN=[A-Za-z0-9._=-]+$ ]] || \
    fail 'fixed Tunnel environment file contains unsafe shell/systemd syntax'

ARGO_PORT=8001
assert_ok write_argo_systemd_service token "$secret_root"
assert_ok write_argo_openrc_service token "$secret_root"
systemd_unit="${secret_root}/etc/systemd/system/argo.service"
openrc_init="${secret_root}/etc/init.d/argo"
grep -Fq 'EnvironmentFile=-/etc/sing-box/argo.env' "$systemd_unit" || \
    fail 'systemd unit does not load the root-only Tunnel environment'
grep -Fq 'ExecStart=/etc/sing-box/argo tunnel --no-autoupdate run' "$systemd_unit" || \
    fail 'systemd fixed Tunnel command is unexpected'
grep -Fq '. /etc/sing-box/argo.env' "$openrc_init" || \
    fail 'OpenRC does not load the root-only Tunnel environment'
grep -Fq 'command_args="tunnel --no-autoupdate run"' "$openrc_init" || \
    fail 'OpenRC fixed Tunnel command is unexpected'
! grep -R -Fq -- '--token' "${secret_root}/etc/systemd/system" "${secret_root}/etc/init.d" || \
    fail 'a fixed Tunnel init command still places the token on the command line'
! grep -R -Fq 'secret-value' "${secret_root}/etc/systemd/system" "${secret_root}/etc/init.d" || \
    fail 'a fixed Tunnel secret leaked into an init definition'

manage_argo_source="$(extract_function manage_argo)"
grep -Fq 'reading_secret' <<< "$manage_argo_source" || \
    fail 'interactive fixed Tunnel credentials are not read without echo'

# The health check may disclose a credentialed URL only to curl's --proxy
# option; destination, output and logs must stay credential-free.
proxy_log="${tmp_dir}/proxy-curl.log"
proxy_url='http://alice:password@example.test:3128'
curl() {
    printf '%s\n' "$@" > "$proxy_log"
}
proxy_output="$(probe_proxy_url "$proxy_url" 2>&1)"
assert_equal '' "$proxy_output" 'proxy health check output'
mapfile -t proxy_args < "$proxy_log"
proxy_count=0
for index in "${!proxy_args[@]}"; do
    if [[ "${proxy_args[$index]}" == "$proxy_url" ]]; then
        proxy_count=$((proxy_count + 1))
        [[ "$index" -gt 0 && "${proxy_args[$((index - 1))]}" == --proxy ]] || \
            fail 'credentialed proxy URL was not confined to --proxy'
    fi
done
assert_equal 1 "$proxy_count" 'credentialed proxy URL argument count'
grep -Fqx 'https://www.cloudflare.com/cdn-cgi/trace' "$proxy_log" || \
    fail 'proxy health check does not use the Cloudflare trace destination'
grep -Fqx -- '-o' "$proxy_log" || fail 'proxy health check does not discard its response'
grep -Fqx '/dev/null' "$proxy_log" || fail 'proxy health check response is not discarded'
unset -f curl

# CLI and interactive refresh paths share one guard. A fixed Tunnel must fail
# before restart, log parsing or subscription mutation.
refresh_log="${tmp_dir}/refresh.log"
get_quick_tunnel() { printf '%s\n' get >> "$refresh_log"; }
change_argo_domain() { printf '%s\n' change >> "$refresh_log"; }
restart_argo() { printf '%s\n' restart >> "$refresh_log"; }
get_latest_argo_domain() { printf '%s\n' parse >> "$refresh_log"; }
: > "$refresh_log"
set +e
fixed_output="$(refresh_quick_argo "$systemd_unit" 2>&1)"
fixed_status=$?
set -e
[[ "$fixed_status" -ne 0 ]] || fail 'fixed Tunnel refresh unexpectedly succeeded'
[[ "$fixed_output" == *'固定'* ]] || fail 'fixed Tunnel refresh has no clear rejection message'
[[ ! -s "$refresh_log" ]] || fail 'fixed Tunnel refresh restarted or parsed a temporary hostname'

quick_service="${tmp_dir}/quick-argo.service"
printf '%s\n' \
    '[Service]' \
    'ExecStart=/etc/sing-box/argo tunnel --url http://127.0.0.1:8001 --no-autoupdate' \
    > "$quick_service"
assert_ok refresh_quick_argo "$quick_service"
assert_equal $'get\nchange' "$(cat "$refresh_log")" 'quick Tunnel refresh call sequence'

printf 'Local manager and secret safety tests passed.\n'
