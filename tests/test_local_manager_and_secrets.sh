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
    write_local_manager_wrapper \
    is_legacy_raw_manager_wrapper \
    migrate_legacy_manager_shortcuts \
    create_shortcut \
    update_local_manager \
    update_shortcut \
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
# create only local wrappers. Prove the user-visible behavior by running `sb`
# with a curl executable that fails if routine management attempts a download.
shortcut_root="${tmp_dir}/shortcut"
manager_source="${tmp_dir}/manager-source.sh"
offline_bin="${tmp_dir}/offline-bin"
offline_curl_log="${tmp_dir}/offline-curl.log"
mkdir -p "${shortcut_root}/etc/sing-box" "$offline_bin"
printf '%s\n' '#!/bin/bash' 'printf "fixture manager:%s\\n" "$*"' > "$manager_source"
printf '%s\n' '#!/bin/bash' 'exit 0' > "${shortcut_root}/etc/sing-box/sing-box"
chmod 700 "${shortcut_root}/etc/sing-box/sing-box"
printf '%s\n' \
    '#!/bin/bash' \
    'printf "curl invoked\\n" >> "$OFFLINE_CURL_LOG"' \
    'exit 99' > "${offline_bin}/curl"
chmod 700 "${offline_bin}/curl"
MANAGER_SOURCE_SCRIPT="$manager_source"
work_dir="${shortcut_root}/etc/sing-box"
if ! create_shortcut "$shortcut_root"; then
    ls -l "${shortcut_root}/usr/local/bin" "${shortcut_root}/usr/bin" \
        "${shortcut_root}/etc/sing-box" "${shortcut_root}/usr/local/lib/sing-box-pre" >&2 || true
    for shortcut_path in \
        "${shortcut_root}/usr/local/bin/sb" \
        "${shortcut_root}/usr/bin/sb" \
        "${shortcut_root}/usr/local/bin/sing-box"; do
        printf 'shortcut diagnostic: %s -> %s\n' "$shortcut_path" \
            "$(readlink "$shortcut_path" 2>/dev/null || printf '<not-a-link>')" >&2
    done
    fail 'create_shortcut failed for the isolated install root'
fi

local_manager="${shortcut_root}/usr/local/lib/sing-box-pre/sing-box.sh"
wrapper="${shortcut_root}/etc/sing-box/sb.sh"
[[ -f "$local_manager" ]] || fail 'create_shortcut did not install the local manager'
assert_mode 700 "$local_manager"
assert_equal "${shortcut_root}/etc/sing-box/sb.sh" \
    "$(readlink "${shortcut_root}/usr/local/bin/sb")" 'local sb link target'
assert_equal "${shortcut_root}/etc/sing-box/sb.sh" \
    "$(readlink "${shortcut_root}/usr/bin/sb")" 'usr sb link target'
assert_equal "${shortcut_root}/etc/sing-box/sing-box" \
    "$(readlink "${shortcut_root}/usr/local/bin/sing-box")" 'sing-box binary link target'
shortcut_output="$(OFFLINE_CURL_LOG="$offline_curl_log" PATH="${offline_bin}:$PATH" \
    "${shortcut_root}/usr/local/bin/sb" --offline-check)" || \
    fail 'locally installed sb did not run offline'
assert_equal 'fixture manager:--offline-check' "$shortcut_output" \
    'locally installed sb output'
[[ ! -e "$offline_curl_log" ]] || fail 'routine sb execution attempted a download'

# The historical baseline wrapper downloaded Raw GitHub on every invocation,
# and all three shortcuts pointed at that wrapper. A real explicit update must
# migrate only those managed targets, preserve a custom shortcut, and leave sb
# runnable with the network disabled.
legacy_root="${tmp_dir}/legacy-update"
legacy_wrapper="${legacy_root}/etc/sing-box/sb.sh"
legacy_manager="${legacy_root}/usr/local/lib/sing-box-pre/sing-box.sh"
mkdir -p "${legacy_root}/etc/sing-box" \
    "${legacy_root}/usr/local/bin" "${legacy_root}/usr/bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exec bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) "$@"' \
    > "$legacy_wrapper"
chmod 700 "$legacy_wrapper"
ln -s "$legacy_wrapper" "${legacy_root}/usr/local/bin/sb"
ln -s '/opt/custom/sb-manager' "${legacy_root}/usr/bin/sb"
ln -s "$legacy_wrapper" "${legacy_root}/usr/local/bin/sing-box"

curl_log="${tmp_dir}/curl-update.log"
active_update_root="$legacy_root"
download_body='#!/bin/bash
printf "updated manager:%s\\n" "$*"
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
    [[ -n "$output" && "$output" == "${active_update_root}/"* ]] || return 2
    printf '%s' "$download_body" > "$output"
}

assert_ok update_shortcut "$legacy_root" 'https://updates.example.test/sing-box.sh'
grep -Fqx 'https://updates.example.test/sing-box.sh' "$curl_log" || \
    fail 'legacy explicit update did not use the requested manager URL'
assert_equal "$legacy_wrapper" "$(readlink "${legacy_root}/usr/local/bin/sb")" \
    'legacy managed sb link target after migration'
assert_equal '/opt/custom/sb-manager' "$(readlink "${legacy_root}/usr/bin/sb")" \
    'custom sb link was replaced during migration'
assert_equal "${legacy_root}/etc/sing-box/sing-box" \
    "$(readlink "${legacy_root}/usr/local/bin/sing-box")" \
    'legacy sing-box link target after migration'
legacy_output="$(OFFLINE_CURL_LOG="$offline_curl_log" PATH="${offline_bin}:$PATH" \
    "${legacy_root}/usr/local/bin/sb" --migrated-check)" || \
    fail 'migrated legacy sb did not run offline'
assert_equal 'updated manager:--migrated-check' "$legacy_output" \
    'migrated legacy sb output'
[[ ! -e "$offline_curl_log" ]] || fail 'migrated legacy sb still attempted a download'
assert_mode 700 "$legacy_manager"

run_legacy_migration_rollback_case() {
    local failure_stage="$1"
    local fixture="${tmp_dir}/legacy-rollback-${failure_stage}"
    local wrapper_file="${fixture}/etc/sing-box/sb.sh"
    local manager_file="${fixture}/usr/local/lib/sing-box-pre/sing-box.sh"
    local previous_file="${manager_file}.previous"
    local local_sb="${fixture}/usr/local/bin/sb"
    local usr_sb="${fixture}/usr/bin/sb"
    local singbox_link="${fixture}/usr/local/bin/sing-box"
    local old_wrapper old_manager old_previous
    local old_local_sb old_usr_sb old_singbox_link
    local failure_marker="${fixture}/failure-triggered"

    mkdir -p "${fixture}/etc/sing-box" \
        "${fixture}/usr/local/lib/sing-box-pre" \
        "${fixture}/usr/local/bin" "${fixture}/usr/bin"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'exec bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) "$@"' \
        > "$wrapper_file"
    printf '%s\n' '#!/bin/bash' 'printf "working manager\\n"' > "$manager_file"
    printf '%s\n' '#!/bin/bash' 'printf "older manager\\n"' > "$previous_file"
    chmod 700 "$wrapper_file" "$manager_file" "$previous_file"
    ln -s "$wrapper_file" "$local_sb"
    ln -s "$wrapper_file" "$usr_sb"
    ln -s "$wrapper_file" "$singbox_link"

    old_wrapper="$(cat "$wrapper_file")"
    old_manager="$(cat "$manager_file")"
    old_previous="$(cat "$previous_file")"
    old_local_sb="$(readlink "$local_sb")"
    old_usr_sb="$(readlink "$usr_sb")"
    old_singbox_link="$(readlink "$singbox_link")"
    active_update_root="$fixture"
    rm -f "$failure_marker"

    mv() {
        local destination=''
        for destination in "$@"; do :; done
        if [[ "$failure_stage" == wrapper && ! -e "$failure_marker" && \
              "$destination" == "$wrapper_file" ]]; then
            : > "$failure_marker"
            return 1
        fi
        if [[ "$failure_stage" == link && ! -e "$failure_marker" && \
              "$destination" == "$singbox_link" ]]; then
            : > "$failure_marker"
            return 1
        fi
        command mv "$@"
    }
    ln() {
        local destination=''
        for destination in "$@"; do :; done
        command ln "$@"
    }

    assert_fail update_shortcut "$fixture" 'https://updates.example.test/sing-box.sh'
    [[ -e "$failure_marker" ]] || fail "${failure_stage} migration fault was not reached"
    assert_equal "$old_manager" "$(cat "$manager_file")" \
        "${failure_stage} migration failure changed the current manager"
    assert_equal "$old_previous" "$(cat "$previous_file")" \
        "${failure_stage} migration failure changed the existing previous manager"
    assert_equal "$old_wrapper" "$(cat "$wrapper_file")" \
        "${failure_stage} migration failure changed the legacy wrapper"
    assert_equal "$old_local_sb" "$(readlink "$local_sb")" \
        "${failure_stage} migration failure changed the local sb link"
    assert_equal "$old_usr_sb" "$(readlink "$usr_sb")" \
        "${failure_stage} migration failure changed the usr sb link"
    assert_equal "$old_singbox_link" "$(readlink "$singbox_link")" \
        "${failure_stage} migration failure changed the sing-box link"
    unset -f mv ln
}

run_legacy_migration_rollback_case wrapper
run_legacy_migration_rollback_case link
unset -f curl

# Explicit update is the only manager path that downloads. It validates first,
# preserves the previous version, and atomically installs mode 0700.
update_root="${tmp_dir}/update"
update_manager="${update_root}/usr/local/lib/sing-box-pre/sing-box.sh"
mkdir -p "$(dirname "$update_manager")"
printf '%s\n' '#!/bin/bash' 'printf "old manager\\n"' > "$update_manager"
chmod 700 "$update_manager"
old_manager_content="$(cat "$update_manager")"
curl_log="${tmp_dir}/curl-manager-update.log"
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

run_atomic_previous_failure_case() {
    local failure_stage="$1"
    local fixture="${tmp_dir}/atomic-previous-${failure_stage}"
    local manager_dir="${fixture}/usr/local/lib/sing-box-pre"
    local manager_file="${manager_dir}/sing-box.sh"
    local previous_file="${manager_file}.previous"
    local failure_marker="${fixture}/failure-triggered"
    local old_manager old_previous source_path destination_path

    mkdir -p "$manager_dir"
    printf '%s\n' '#!/bin/bash' 'printf "stable current manager\\n"' > "$manager_file"
    printf '%s\n' '#!/bin/bash' 'printf "stable older manager\\n"' > "$previous_file"
    chmod 700 "$manager_file" "$previous_file"
    old_manager="$(cat "$manager_file")"
    old_previous="$(cat "$previous_file")"
    download_body=$'#!/bin/bash\nprintf "candidate manager\\n"\n'
    rm -f "$failure_marker"

    cp() {
        source_path="${@: -2:1}"
        destination_path="${@: -1}"
        if [[ "$failure_stage" == partial-copy && ! -e "$failure_marker" && \
              "$source_path" == "$manager_file" && \
              "$destination_path" == "${manager_dir}/.sing-box.sh.previous."* ]]; then
            printf 'partial backup' > "$destination_path"
            : > "$failure_marker"
            return 1
        fi
        command cp "$@"
    }
    chmod() {
        destination_path="${@: -1}"
        if [[ "$failure_stage" == previous-chmod && ! -e "$failure_marker" && \
              "$destination_path" == "${manager_dir}/.sing-box.sh.previous."* ]]; then
            : > "$failure_marker"
            return 1
        fi
        command chmod "$@"
    }
    mv() {
        source_path="${@: -2:1}"
        destination_path="${@: -1}"
        if [[ "$failure_stage" == previous-mv && ! -e "$failure_marker" && \
              "$source_path" == "${manager_dir}/.sing-box.sh.previous."* && \
              "$destination_path" == "$previous_file" ]]; then
            : > "$failure_marker"
            return 1
        fi
        if [[ "$failure_stage" == manager-mv && ! -e "$failure_marker" && \
              "$source_path" == "${manager_dir}/.sing-box.sh.new."* && \
              "$destination_path" == "$manager_file" ]]; then
            : > "$failure_marker"
            return 1
        fi
        command mv "$@"
    }

    assert_fail update_local_manager "$fixture" 'https://updates.example.test/fault.sh'
    [[ -e "$failure_marker" ]] || fail "${failure_stage} update fault was not reached"
    assert_equal "$old_manager" "$(cat "$manager_file")" \
        "${failure_stage} changed the current manager"
    assert_equal "$old_previous" "$(cat "$previous_file")" \
        "${failure_stage} changed the existing previous manager"
    if find "$manager_dir" -maxdepth 1 -type f -name '.sing-box.sh.*' -print -quit | grep -q .; then
        fail "${failure_stage} left a manager update temporary file"
    fi
    unset -f cp chmod mv
}

for previous_failure_stage in \
    partial-copy previous-chmod previous-mv manager-mv; do
    run_atomic_previous_failure_case "$previous_failure_stage"
done
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

# The health check must keep the credentialed proxy URL out of argv. Curl reads
# it from a mode-0600 temporary config that is removed on success and failure.
proxy_tmp_dir="${tmp_dir}/proxy-config"
proxy_log="${tmp_dir}/proxy-curl-argv.log"
proxy_config_capture="${tmp_dir}/proxy-curl-config.capture"
proxy_config_path_log="${tmp_dir}/proxy-curl-config-path.log"
proxy_config_mode_log="${tmp_dir}/proxy-curl-config-mode.log"
proxy_url='http://alice:pa\"ss@example.test:3128'
mkdir -p "$proxy_tmp_dir"
PROXY_CURL_CONFIG_DIR="$proxy_tmp_dir"
PROXY_CURL_STATUS=0
curl() {
    printf '%s\n' "$@" > "$proxy_log"
    local argument previous='' config_path=''
    for argument in "$@"; do
        if [[ "$previous" == --config ]]; then
            config_path="$argument"
        fi
        previous="$argument"
    done
    if [[ -n "$config_path" ]]; then
        printf '%s\n' "$config_path" > "$proxy_config_path_log"
        stat -c '%a' "$config_path" > "$proxy_config_mode_log"
        command cp "$config_path" "$proxy_config_capture"
    fi
    return "$PROXY_CURL_STATUS"
}
proxy_output="$(probe_proxy_url "$proxy_url" 2>&1)"
assert_equal '' "$proxy_output" 'proxy health check output'
mapfile -t proxy_args < "$proxy_log"
assert_equal 3 "${#proxy_args[@]}" 'proxy health check curl argv count'
assert_equal '--config' "${proxy_args[0]}" 'proxy health check config option'
assert_equal 'https://www.cloudflare.com/cdn-cgi/trace' "${proxy_args[2]}" \
    'proxy health check destination'
[[ "${proxy_args[*]}" != *"$proxy_url"* ]] || \
    fail 'credentialed proxy URL leaked into curl argv'
if [[ "$(uname -s)" != MINGW* ]]; then
    assert_equal 600 "$(cat "$proxy_config_mode_log")" 'proxy curl config mode'
fi
grep -Fqx 'proxy = "http://alice:pa\\\"ss@example.test:3128"' "$proxy_config_capture" || \
    fail 'proxy URL was not safely escaped in the curl config'
grep -Fqx 'output = "/dev/null"' "$proxy_config_capture" || \
    fail 'proxy health check response is not discarded by config'
proxy_config_path="$(cat "$proxy_config_path_log")"
[[ ! -e "$proxy_config_path" ]] || fail 'successful proxy check left its curl config'

PROXY_CURL_STATUS=23
assert_fail probe_proxy_url 'http://alice:password@example.test:3128'
failed_proxy_config_path="$(cat "$proxy_config_path_log")"
[[ ! -e "$failed_proxy_config_path" ]] || fail 'failed proxy check left its curl config'

for malicious_proxy_url in \
    $'http://alice:password@example.test:3128\nnext = "injected"' \
    $'http://alice:password@example.test:3128\rnext = "injected"'; do
    : > "$proxy_log"
    assert_fail probe_proxy_url "$malicious_proxy_url"
    [[ ! -s "$proxy_log" ]] || fail 'CRLF proxy URL reached curl'
done
if find "$proxy_tmp_dir" -maxdepth 1 -type f -print -quit | grep -q .; then
    fail 'proxy health checks left a temporary curl config'
fi
unset PROXY_CURL_CONFIG_DIR PROXY_CURL_STATUS
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
