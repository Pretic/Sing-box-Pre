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
    local function_source
    function_source="$(extract_function "$1")"
    [[ -n "$function_source" ]] || fail "$1 is not implemented"
    source <(printf '%s\n' "$function_source")
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    [[ "$actual" == "$expected" ]] || \
        fail "${description}: expected '${expected}', got '${actual}'"
}

# An unsupported init system must be rejected before the install marker,
# packages, configuration, or any service definition is changed.
load_function detect_usable_init_system
load_function run_install_flow
install_log="${tmp_dir}/install.log"
clear_install_complete_marker() { printf '%s\n' marker >> "$install_log"; }
manage_packages() { printf '%s\n' packages >> "$install_log"; }
install_singbox() { printf '%s\n' install >> "$install_log"; }
validate_singbox_config() { printf '%s\n' validate >> "$install_log"; }
command_exists() { return 1; }
red() { :; }
if run_install_flow >/dev/null 2>&1; then
    fail 'unsupported init system unexpectedly passed install preflight'
fi
[[ ! -e "$install_log" ]] || \
    fail "unsupported init system caused side effects: $(tr '\n' ' ' < "$install_log")"

# A systemctl executable inside a container/WSL/chroot is not evidence that
# systemd is the active init system. A dead system bus must fail the same
# side-effect-free preflight.
: > "$install_log"
command_exists() { [[ "$1" == systemctl ]]; }
systemctl() { return 1; }
SYSTEMD_RUNTIME_DIR="${tmp_dir}/missing-systemd-runtime"
OPENRC_SOFTLEVEL_FILE="${tmp_dir}/missing-openrc-softlevel"
if run_install_flow >/dev/null 2>&1; then
    fail 'dead systemctl unexpectedly passed install preflight'
fi
[[ ! -s "$install_log" ]] || \
    fail "dead systemctl caused side effects: $(tr '\n' ' ' < "$install_log")"

load_function perform_singbox_uninstall

# A service stop failure is a hard boundary: definitions, NAT recovery state,
# Nginx configuration and the work directory all remain untouched.
uninstall_root="${tmp_dir}/stop-fail-root"
mkdir -p "${uninstall_root}/etc/systemd/system" \
         "${uninstall_root}/etc/sing-box" \
         "${uninstall_root}/etc/nginx/conf.d"
printf '%s\n' unit > "${uninstall_root}/etc/systemd/system/sing-box.service"
printf '%s\n' unit > "${uninstall_root}/etc/systemd/system/argo.service"
printf '%s\n' recovery > "${uninstall_root}/etc/sing-box/recovery.state"
uninstall_log="${tmp_dir}/uninstall.log"
work_dir='/etc/sing-box'
detect_usable_init_system() { printf 'systemd\n'; }
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$uninstall_log"
    [[ "$1 $2" != 'stop sing-box' ]]
}
command_exists() { [[ "$1" == systemctl ]]; }
remove_hy2_port_hopping() { printf '%s\n' hy2-clean >> "$uninstall_log"; }
remove_owned_firewall_rules() { printf '%s\n' firewall-clean >> "$uninstall_log"; }
remove_managed_nginx_include() { printf '%s\n' nginx-main-clean >> "$uninstall_log"; }
remove_managed_singbox_link() { printf '%s\n' links-clean >> "$uninstall_log"; }
restart_nginx() { printf '%s\n' nginx-reload >> "$uninstall_log"; }
purge_nginx_package() { printf '%s\n' nginx-purge >> "$uninstall_log"; }
red() { :; }
yellow() { :; }
green() { :; }
if perform_singbox_uninstall "$uninstall_root" 0 >/dev/null 2>&1; then
    fail 'uninstall continued after sing-box stop failure'
fi
[[ -f "${uninstall_root}/etc/systemd/system/sing-box.service" ]] || fail 'unit removed after stop failure'
[[ -f "${uninstall_root}/etc/sing-box/recovery.state" ]] || fail 'recovery state removed after stop failure'
if grep -Eq 'hy2-clean|nginx-main-clean|links-clean' "$uninstall_log"; then
    fail 'destructive cleanup ran after stop failure'
fi

# A completely absent install is idempotent even if no init system is active.
empty_root="${tmp_dir}/already-absent"
mkdir -p "$empty_root"
detect_usable_init_system() { return 1; }
command_exists() { return 1; }
perform_singbox_uninstall "$empty_root" 0 >/dev/null 2>&1 || \
    fail 'already absent uninstall was not idempotent'

printf 'Lifecycle safety tests passed.\n'
