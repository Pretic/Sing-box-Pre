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

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    [[ "$actual" == "$expected" ]] || \
        fail "${description}: expected '${expected}', got '${actual}'"
}

for function_name in \
    remove_managed_singbox_link \
    auto_uninstall \
    detect_argo_tunnel_mode \
    get_quick_tunnel \
    refresh_quick_argo \
    dispatch_cli_action \
    dispatch_argo_menu_action \
    manage_argo; do
    load_function "$function_name"
done

green() { :; }
yellow() { :; }
red() { printf '%s\n' "$*" >&2; }
purple() { :; }
skyblue() { :; }
purple=''
re=''

# Exercise the real non-interactive uninstall against isolated filesystem roots.
# Only the two links created by supported sing-box installations may be removed.
command_exists() { return 1; }
restart_nginx() { fail 'uninstall unexpectedly restarted nginx'; }
PURGE_NGINX=0

run_uninstall_fixture() {
    local fixture_name="$1"
    local fixture_kind="$2"
    local link_target="${3:-}"
    local fixture_root="${tmp_dir}/uninstall-${fixture_name}"
    local singbox_path="${fixture_root}/usr/local/bin/sing-box"

    mkdir -p "$(dirname "$singbox_path")" "${fixture_root}/etc/sing-box"
    work_dir="${fixture_root}/etc/sing-box"
    printf 'runtime fixture\n' > "${work_dir}/runtime"
    if [[ "$fixture_kind" == symlink ]]; then
        ln -s "$link_target" "$singbox_path"
    else
        printf 'user binary\n' > "$singbox_path"
    fi

    auto_uninstall "$fixture_root"

    case "$fixture_name" in
        current|legacy)
            [[ ! -e "$singbox_path" && ! -L "$singbox_path" ]] || \
                fail "managed ${fixture_name} sing-box link was not removed"
            ;;
        custom)
            [[ -L "$singbox_path" ]] || fail 'custom sing-box symlink was removed'
            assert_equal "$link_target" "$(readlink "$singbox_path")" \
                'custom sing-box symlink target'
            ;;
        regular)
            [[ -f "$singbox_path" && ! -L "$singbox_path" ]] || \
                fail 'regular sing-box file was removed or replaced'
            assert_equal 'user binary' "$(cat "$singbox_path")" \
                'regular sing-box file content'
            ;;
    esac
}

case "$(uname -s)" in
    MINGW*)
        printf 'SKIP: POSIX symlink uninstall fixtures require Linux.\n'
        ;;
    *)
        run_uninstall_fixture current symlink '/etc/sing-box/sing-box'
        run_uninstall_fixture legacy symlink '/etc/sing-box/sb.sh'
        run_uninstall_fixture custom symlink '/opt/custom/sing-box'
        run_uninstall_fixture regular file
        ;;
esac

# Execute the same dispatcher used by the real CLI and interactive option 6.
# Fixed Tunnels must be rejected before restart, log parsing, or mutation.
refresh_log="${tmp_dir}/refresh.log"
work_dir="${tmp_dir}/refresh-runtime"
mkdir -p "$work_dir"
restart_argo() { printf '%s\n' restart >> "$refresh_log"; }
get_latest_argo_domain() {
    printf '%s\n' parse >> "$refresh_log"
    printf 'temporary.trycloudflare.com\n'
}
change_argo_domain() { printf '%s\n' change >> "$refresh_log"; }
sleep() { :; }

fixed_service="${tmp_dir}/fixed-argo.service"
printf '%s\n' \
    '[Service]' \
    'EnvironmentFile=-/etc/sing-box/argo.env' \
    'ExecStart=/etc/sing-box/argo tunnel --no-autoupdate run' \
    > "$fixed_service"
quick_service="${tmp_dir}/quick-argo.service"
printf '%s\n' \
    '[Service]' \
    'ExecStart=/etc/sing-box/argo tunnel --url http://127.0.0.1:8001 --no-autoupdate' \
    > "$quick_service"

assert_fixed_refresh_rejected() {
    local description="$1"
    shift
    local output status

    : > "$refresh_log"
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "${description} unexpectedly succeeded"
    [[ "$output" == *'固定'* ]] || fail "${description} has no fixed-Tunnel rejection"
    [[ ! -s "$refresh_log" ]] || \
        fail "${description} restarted, parsed logs, or mutated subscriptions"
}

: > "$refresh_log"
assert_fixed_refresh_rejected 'CLI -r dispatch' \
    dispatch_cli_action -r "$fixed_service"

dispatch_cli_action -r "$quick_service"
assert_equal $'restart\nparse\nchange' "$(cat "$refresh_log")" \
    'quick Tunnel CLI dispatch call sequence'

assert_fixed_refresh_rejected 'interactive option 6 dispatch' \
    dispatch_argo_menu_action 6 "$fixed_service"
: > "$refresh_log"
dispatch_argo_menu_action 6 "$quick_service"
assert_equal $'restart\nparse\nchange' "$(cat "$refresh_log")" \
    'quick Tunnel interactive dispatch call sequence'

# Dynamically drive manage_argo itself to prove option 6 reaches the shared
# dispatcher instead of merely testing the helper in isolation.
check_argo() { printf 'fixture\n'; }
clear() { :; }
reading() { printf -v "$2" '6'; }
assert_fixed_refresh_rejected 'manage_argo option 6' manage_argo "$fixed_service"
: > "$refresh_log"
manage_argo "$quick_service"
assert_equal $'restart\nparse\nchange' "$(cat "$refresh_log")" \
    'manage_argo quick Tunnel call sequence'

printf 'Uninstall and dispatcher tests passed.\n'
