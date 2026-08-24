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

function_source="$(sed -n '/^perform_singbox_uninstall() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] || fail 'perform_singbox_uninstall is not implemented'
source <(printf '%s\n' "$function_source")

work_dir=/etc/sing-box
uninstall_log="${tmp_dir}/uninstall.log"
remove_hy2_port_hopping() { printf '%s\n' hy2-clean >> "$uninstall_log"; }
remove_owned_firewall_rules() { printf '%s\n' firewall-clean >> "$uninstall_log"; }
remove_managed_nginx_include() { printf '%s\n' nginx-clean >> "$uninstall_log"; }
remove_managed_singbox_link() { printf '%s\n' links-clean >> "$uninstall_log"; }
purge_nginx_package() { printf '%s\n' nginx-purge >> "$uninstall_log"; }
restart_nginx() { return 0; }
nginx() { return 0; }
red() { printf '%s\n' "$*" >&2; }
yellow() { printf '%s\n' "$*" >&2; }
green() { :; }

new_root() {
    ROOT="${tmp_dir}/$1"
    mkdir -p "${ROOT}/etc/sing-box" "${ROOT}/etc/nginx/conf.d"
    printf '%s\n' keep > "${ROOT}/etc/sing-box/recovery.state"
    : > "$uninstall_log"
}

# Missing unit + exact managed process is a fail-close inventory error. No
# init action or destructive cleanup may run.
new_root orphan-sing
managed_service_process_is_running() { [[ "$1" == sing-box ]]; }
command_exists() { return 1; }
detect_usable_init_system() { printf '%s\n' detect-init >> "$uninstall_log"; return 1; }
set +e
perform_singbox_uninstall "$ROOT" 0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "orphan managed sing-box process returned ${status} instead of 1"
[[ -f "${ROOT}/etc/sing-box/recovery.state" ]] || fail 'orphan process inventory deleted recovery state'
[[ ! -s "$uninstall_log" ]] || fail "orphan process inventory caused side effects: $(< "$uninstall_log")"

# Purging an already inactive Nginx installation with no unit must not issue a
# guaranteed-to-fail stop. Base cleanup and package purge remain valid.
new_root nginx-inactive-no-unit
printf '%s\n' 'server {}' > "${ROOT}/etc/nginx/conf.d/sing-box.conf"
managed_service_process_is_running() { return 1; }
command_exists() { [[ "$1" == nginx ]]; }
detect_usable_init_system() { printf '%s\n' detect-init >> "$uninstall_log"; return 1; }
perform_singbox_uninstall "$ROOT" 1 >/dev/null 2>&1 || \
    fail 'inactive Nginx without a unit could not be purged'
grep -Fqx nginx-purge "$uninstall_log" || fail 'inactive no-unit Nginx purge did not run package removal'
if grep -Fq detect-init "$uninstall_log"; then
    fail 'inactive no-unit Nginx purge unnecessarily required an init system'
fi

# The same missing-unit topology is unsafe while the exact Nginx binary is
# active: abort before base cleanup or package mutation.
new_root nginx-active-no-unit
printf '%s\n' 'server {}' > "${ROOT}/etc/nginx/conf.d/sing-box.conf"
managed_service_process_is_running() { [[ "$1" == nginx ]]; }
command_exists() { [[ "$1" == nginx ]]; }
set +e
perform_singbox_uninstall "$ROOT" 1 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "orphan Nginx process returned ${status} instead of 1"
if grep -Eq 'hy2-clean|nginx-clean|links-clean|nginx-purge' "$uninstall_log"; then
    fail 'orphan Nginx process allowed destructive cleanup'
fi

# Quiescing is all-or-rollback. If Argo stop fails after sing-box was stopped
# and disabled, restore sing-box's original active/enabled state.
setup_mid_stop_failure() {
    new_root "$1"
    mkdir -p "${ROOT}/etc/systemd/system"
    printf '%s\n' unit > "${ROOT}/etc/systemd/system/sing-box.service"
    printf '%s\n' unit > "${ROOT}/etc/systemd/system/argo.service"
    SING_ACTIVE=1
    SING_ENABLED=1
    ARGO_ACTIVE=1
    ARGO_ENABLED=1
    RESTORE_FAIL="$2"
    managed_service_process_is_running() { return 1; }
    command_exists() { [[ "$1" == systemctl ]]; }
    detect_usable_init_system() { printf 'systemd\n'; }
    systemctl() {
        case "$1 $2 ${3:-}" in
            'is-active --quiet sing-box') [[ "$SING_ACTIVE" -eq 1 ]] ;;
            'is-active --quiet argo') [[ "$ARGO_ACTIVE" -eq 1 ]] ;;
            'is-enabled --quiet sing-box') [[ "$SING_ENABLED" -eq 1 ]] ;;
            'is-enabled --quiet argo') [[ "$ARGO_ENABLED" -eq 1 ]] ;;
            'stop sing-box ' ) SING_ACTIVE=0 ;;
            'disable sing-box ' ) SING_ENABLED=0 ;;
            'stop argo ' ) return 1 ;;
            'start sing-box ' )
                [[ "$RESTORE_FAIL" -eq 0 ]] || return 1
                SING_ACTIVE=1
                ;;
            'enable sing-box ' ) SING_ENABLED=1 ;;
            *) return 0 ;;
        esac
    }
}

setup_mid_stop_failure rollback-complete 0
set +e
perform_singbox_uninstall "$ROOT" 0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "fully restored quiesce failure returned ${status} instead of 1"
[[ "$SING_ACTIVE" -eq 1 && "$SING_ENABLED" -eq 1 ]] || \
    fail 'mid-quiesce failure did not restore sing-box active/enabled state'
[[ -f "${ROOT}/etc/sing-box/recovery.state" ]] || fail 'mid-quiesce rollback deleted work state'

# If restoration itself fails, return rc=2 and retain a secure inventory file.
setup_mid_stop_failure rollback-incomplete 1
set +e
recovery_output="$(perform_singbox_uninstall "$ROOT" 0 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "incomplete quiesce rollback returned ${status} instead of 2"
shopt -s nullglob
recoveries=("${ROOT}/etc/sing-box"/.uninstall-recovery.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'incomplete quiesce rollback did not retain one recovery directory'
[[ "$(stat -c '%a' "${recoveries[0]}")" == 700 ]] || fail 'uninstall recovery directory is not mode 0700'
[[ -f "${recoveries[0]}/service-state.conf" && \
   "$(stat -c '%a' "${recoveries[0]}/service-state.conf")" == 600 ]] || \
    fail 'uninstall service-state evidence is missing or not mode 0600'
[[ "$recovery_output" == *'自动回滚不完整'*"${recoveries[0]}"* ]] || \
    fail 'incomplete quiesce rollback did not report the recovery directory'

printf 'Uninstall service/process matrix tests passed.\n'
