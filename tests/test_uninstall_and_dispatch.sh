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
    uninstall_singbox \
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
green=''
yellow=''
purple=''
re=''

# Exercise the real non-interactive uninstall against isolated filesystem roots.
# Only the two links created by supported sing-box installations may be removed.
command_exists() { return 1; }
restart_nginx() { fail 'uninstall unexpectedly restarted nginx'; }
remove_owned_firewall_rules() { :; }
HY2_REMOVE_FAIL=0
remove_hy2_port_hopping() { [[ "$HY2_REMOVE_FAIL" -eq 0 ]]; }
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

# HY2 NAT cleanup owns state inside work_dir and therefore must fail closed
# before either firewall cleanup or destructive uninstall steps.
hy2_failure_root="${tmp_dir}/uninstall-hy2-failure"
work_dir="${hy2_failure_root}/etc/sing-box"
mkdir -p "$work_dir"
printf 'owned NAT evidence\n' > "${work_dir}/hy2-nat.state"
HY2_REMOVE_FAIL=1
if auto_uninstall "$hy2_failure_root" >/dev/null 2>&1; then
    fail 'auto uninstall continued after HY2 NAT cleanup failed'
fi
[[ -f "${work_dir}/hy2-nat.state" ]] || fail 'failed HY2 cleanup lost ownership evidence'
HY2_REMOVE_FAIL=0

# The interactive uninstaller must use the same safe shortcut cleanup as the
# non-interactive path. A guarded rm makes the pre-fix call safe even though it
# ignores the fixture root: paths outside the fixture are logged, never run.
run_interactive_uninstall_fixture() {
    local fixture_name="$1"
    local fixture_kind="$2"
    local fixture_root="${tmp_dir}/interactive-${fixture_name}"
    local denied_log="${fixture_root}/denied-rm.log"
    local local_singbox="${fixture_root}/usr/local/bin/sing-box"
    local local_sb="${fixture_root}/usr/local/bin/sb"
    local usr_sb="${fixture_root}/usr/bin/sb"
    local path

    mkdir -p "$(dirname "$local_singbox")" "$(dirname "$usr_sb")" \
        "${fixture_root}/etc/sing-box"
    : > "$denied_log"
    work_dir="${fixture_root}/etc/sing-box"
    printf 'runtime fixture\n' > "${work_dir}/runtime"

    case "$fixture_kind" in
        current)
            ln -s '/etc/sing-box/sing-box' "$local_singbox"
            ln -s '/etc/sing-box/sb.sh' "$local_sb"
            ln -s '/etc/sing-box/sb.sh' "$usr_sb"
            ;;
        legacy)
            ln -s '/etc/sing-box/sb.sh' "$local_singbox"
            ln -s '/etc/sing-box/sb.sh' "$local_sb"
            ln -s '/etc/sing-box/sb.sh' "$usr_sb"
            ;;
        custom)
            ln -s '/opt/custom/sing-box' "$local_singbox"
            ln -s '/opt/custom/local-sb' "$local_sb"
            ln -s '/opt/custom/usr-sb' "$usr_sb"
            ;;
        regular)
            printf 'user sing-box\n' > "$local_singbox"
            printf 'user local sb\n' > "$local_sb"
            printf 'user usr sb\n' > "$usr_sb"
            ;;
    esac

    (
        rm() {
            local argument allowed=1
            for argument in "$@"; do
                [[ "$argument" == -* ]] && continue
                if [[ "$argument" != "$fixture_root" && \
                      "$argument" != "$fixture_root/"* ]]; then
                    printf '%s\n' "$argument" >> "$denied_log"
                    allowed=0
                fi
            done
            [[ "$allowed" -eq 0 ]] || command rm "$@"
            return 0
        }
        command_exists() { [[ "${1:-}" == rc-service ]]; }
        rc-service() { :; }
        rc-update() { :; }
        reading_count=0
        reading() {
            reading_count=$((reading_count + 1))
            if [[ "$reading_count" -eq 1 ]]; then
                printf -v "$2" 'y'
            else
                printf -v "$2" 'n'
            fi
        }
        server_name=sing-box
        uninstall_singbox "$fixture_root"
    )

    [[ ! -s "$denied_log" ]] || \
        fail "interactive uninstall escaped fixture root: $(tr '\n' ' ' < "$denied_log")"
    [[ ! -e "$work_dir" ]] || fail 'interactive uninstall did not remove work_dir'

    case "$fixture_kind" in
        current|legacy)
            for path in "$local_singbox" "$local_sb" "$usr_sb"; do
                [[ ! -e "$path" && ! -L "$path" ]] || \
                    fail "interactive uninstall retained managed link: ${path}"
            done
            ;;
        custom)
            for path in "$local_singbox" "$local_sb" "$usr_sb"; do
                [[ -L "$path" ]] || fail "interactive uninstall removed custom link: ${path}"
            done
            assert_equal '/opt/custom/sing-box' "$(readlink "$local_singbox")" \
                'custom interactive sing-box target'
            assert_equal '/opt/custom/local-sb' "$(readlink "$local_sb")" \
                'custom interactive local sb target'
            assert_equal '/opt/custom/usr-sb' "$(readlink "$usr_sb")" \
                'custom interactive usr sb target'
            ;;
        regular)
            for path in "$local_singbox" "$local_sb" "$usr_sb"; do
                [[ -f "$path" && ! -L "$path" ]] || \
                    fail "interactive uninstall removed regular file: ${path}"
            done
            assert_equal 'user sing-box' "$(cat "$local_singbox")" \
                'interactive regular sing-box content'
            assert_equal 'user local sb' "$(cat "$local_sb")" \
                'interactive regular local sb content'
            assert_equal 'user usr sb' "$(cat "$usr_sb")" \
                'interactive regular usr sb content'
            ;;
    esac
}

case "$(uname -s)" in
    MINGW*) run_interactive_uninstall_fixture regular regular ;;
    *)
        run_interactive_uninstall_fixture current current
        run_interactive_uninstall_fixture legacy legacy
        run_interactive_uninstall_fixture custom custom
        run_interactive_uninstall_fixture regular regular
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

# Every CLI alias must return the status from the action it dispatches. Unique
# mock statuses prove both handler selection and exact propagation.
auto_install() { return 41; }
update_shortcut() { return 42; }
auto_uninstall() { return 43; }
check_nodes() { return 44; }
refresh_quick_argo() { return 45; }

assert_dispatch_status() {
    local expected="$1"
    local action="$2"
    local actual

    set +e
    dispatch_cli_action "$action" "${tmp_dir}/unused-service" >/dev/null 2>&1
    actual=$?
    set -e
    assert_equal "$expected" "$actual" "${action} dispatcher status"
}

for action in -i --install; do assert_dispatch_status 41 "$action"; done
for action in --update --upgrade; do assert_dispatch_status 42 "$action"; done
for action in -u --uninstall --purge-nginx; do assert_dispatch_status 43 "$action"; done
for action in -c --check; do assert_dispatch_status 44 "$action"; done
for action in -r --restart; do assert_dispatch_status 45 "$action"; done
for action in -h --help; do assert_dispatch_status 0 "$action"; done
assert_dispatch_status 1 --unknown-action

printf 'Uninstall and dispatcher tests passed.\n'
