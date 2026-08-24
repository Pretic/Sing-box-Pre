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

load_function() {
    local function_source
    function_source="$(sed -n "/^${1}() {/,/^}/p" "$script")"
    [[ -n "$function_source" ]] || fail "$1 is not implemented"
    source <(printf '%s\n' "$function_source")
}

load_function package_is_installed
load_function manage_packages
load_function purge_nginx_package
load_function perform_singbox_uninstall

red() { printf '%s\n' "$*" >&2; }
yellow() { :; }
green() { :; }

# Explicit Nginx removal must never broaden itself into a system-wide orphan
# dependency purge.
package_log="${tmp_dir}/package.log"
work_dir="${tmp_dir}/existing-install"
mkdir -p "$work_dir"
command_exists() {
    case "$1" in
        apt|dpkg-query) return 0 ;;
        *) return 1 ;;
    esac
}
dpkg-query() { printf '%s\n' 'install ok installed'; }
apt() { printf 'apt %s\n' "$*" >> "$package_log"; }
purge_nginx_package >/dev/null 2>&1 || fail 'standalone Nginx package removal failed'
grep -Fqx 'apt remove -y nginx' "$package_log" || fail 'Nginx package was not explicitly removed'
if grep -Fq autoremove "$package_log"; then
    fail 'Nginx package removal invoked autoremove'
fi

# A package remains installed even if its executable is absent from PATH.  The
# purge decision must use the package database, not command discovery.
: > "$package_log"
command_exists() {
    case "$1" in
        apt|dpkg-query) return 0 ;;
        *) return 1 ;;
    esac
}
purge_nginx_package >/dev/null 2>&1 || fail 'PATH-less installed Nginx package was not removed'
grep -Fqx 'apt remove -y nginx' "$package_log" || \
    fail 'PATH-less installed Nginx package was skipped'

# Query errors are neither "installed" nor "absent" and must fail closed
# before issuing a package mutation.
: > "$package_log"
dpkg-query() { return 2; }
set +e
# The fixture replaces purge_nginx_package below for the post-commit case;
# this call intentionally exercises the implementation loaded above.
# shellcheck disable=SC2218
purge_nginx_package >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "package query error returned ${status} instead of 1"
[[ ! -s "$package_log" ]] || fail 'package query error still invoked package removal'

# Package removal is a post-commit step.  A partial package-manager failure
# cannot roll the already-completed base uninstall back, so it must return rc2
# and retain secure recovery evidence without falsely reporting rc1/success.
ROOT="${tmp_dir}/purge-partial"
work_dir=/etc/sing-box
mkdir -p "${ROOT}/etc/sing-box" "${ROOT}/etc/nginx/conf.d"
printf '%s\n' runtime > "${ROOT}/etc/sing-box/runtime.state"
printf '%s\n' 'server {}' > "${ROOT}/etc/nginx/conf.d/sing-box.conf"
uninstall_log="${tmp_dir}/uninstall.log"
: > "$uninstall_log"
command_exists() { [[ "$1" == nginx ]]; }
package_is_installed() { [[ "$1" == nginx ]]; }
managed_service_process_is_running() { return 1; }
detect_usable_init_system() { return 1; }
remove_hy2_port_hopping() { printf '%s\n' base-hy2 >> "$uninstall_log"; }
remove_owned_firewall_rules() { printf '%s\n' base-firewall >> "$uninstall_log"; }
remove_managed_nginx_include() { printf '%s\n' base-nginx-config >> "$uninstall_log"; }
remove_managed_singbox_link() { printf '%s\n' base-links >> "$uninstall_log"; }
purge_nginx_package() { printf '%s\n' package-purge >> "$uninstall_log"; return 1; }
restart_nginx() { return 0; }
nginx() { return 0; }

set +e
purge_output="$(perform_singbox_uninstall "$ROOT" 1 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "partial package purge returned ${status} instead of 2"
[[ ! -e "${ROOT}/etc/sing-box" ]] || fail 'base install survived post-commit package purge failure'
[[ ! -e "${ROOT}/etc/nginx/conf.d/sing-box.conf" ]] || \
    fail 'managed Nginx configuration survived base uninstall commit'
[[ "$(tr '\n' ' ' < "$uninstall_log")" == \
   'base-hy2 base-firewall base-nginx-config base-links package-purge ' ]] || \
    fail "package purge did not run after base commit: $(tr '\n' ' ' < "$uninstall_log")"
shopt -s nullglob
recoveries=("${ROOT}/var/lib/sing-box-uninstall"/.uninstall-recovery.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'partial package purge did not retain one recovery directory'
[[ "$(stat -c '%a' "${recoveries[0]}")" == 700 ]] || fail 'package recovery directory is not 0700'
[[ -f "${recoveries[0]}/package-purge.conf" && \
   "$(stat -c '%a' "${recoveries[0]}/package-purge.conf")" == 600 ]] || \
    fail 'package recovery evidence is missing or not 0600'
[[ -f "${recoveries[0]}/service-state.conf" && \
   "$(stat -c '%a' "${recoveries[0]}/service-state.conf")" == 600 ]] || \
    fail 'package recovery lacks secure pre-uninstall service state'
[[ "$purge_output" == *'基础卸载已完成'*'Nginx 软件包卸载不完整'*"${recoveries[0]}"* ]] || \
    fail 'partial package purge did not report committed base state and recovery path'

printf 'Uninstall package transaction tests passed.\n'
