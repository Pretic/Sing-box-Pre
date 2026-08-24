#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'command rm -rf "$tmp_dir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

function_source="$(sed -n '/^perform_singbox_uninstall() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] || fail 'perform_singbox_uninstall is not implemented'
source <(printf '%s\n' "$function_source")

work_dir=/etc/sing-box
red() { printf '%s\n' "$*" >&2; }
yellow() { :; }
green() { :; }
managed_service_process_is_running() { return 1; }
command_exists() {
    [[ "$1" == systemctl ]] && return 0
    [[ "$1" == nginx && "$FAIL_STAGE" == nginx-reload ]]
}
detect_usable_init_system() { printf 'systemd\n'; }
restart_nginx() { return 0; }
purge_nginx_package() { return 0; }

FAIL_STAGE=''
FAIL_ONCE=0
DAEMON_RELOADS=0
FIREWALL_REMOVALS=0
FIREWALL_RESTORES=0
FIREWALL_PERSISTS=0

systemctl() {
    case "$1 ${2:-} ${3:-}" in
        'is-active --quiet sing-box') [[ "$SING_ACTIVE" -eq 1 ]] ;;
        'is-active --quiet argo') [[ "$ARGO_ACTIVE" -eq 1 ]] ;;
        'is-enabled --quiet sing-box') [[ "$SING_ENABLED" -eq 1 ]] ;;
        'is-enabled --quiet argo') [[ "$ARGO_ENABLED" -eq 1 ]] ;;
        'stop sing-box ' ) SING_ACTIVE=0 ;;
        'stop argo ' ) ARGO_ACTIVE=0 ;;
        'disable sing-box ' ) SING_ENABLED=0 ;;
        'disable argo ' ) ARGO_ENABLED=0 ;;
        'start sing-box ' ) SING_ACTIVE=1 ;;
        'start argo ' ) ARGO_ACTIVE=1 ;;
        'enable sing-box ' ) SING_ENABLED=1 ;;
        'enable argo ' ) ARGO_ENABLED=1 ;;
        'daemon-reload  ' )
            DAEMON_RELOADS=$((DAEMON_RELOADS + 1))
            if [[ "$FAIL_STAGE" == daemon-reload && "$DAEMON_RELOADS" -eq 1 ]]; then
                return 1
            fi
            ;;
        *) return 0 ;;
    esac
}

remove_hy2_port_hopping() {
    case "$FAIL_STAGE" in
        hy2-full) return 1 ;;
        hy2-uncertain) return 2 ;;
        *) return 0 ;;
    esac
}
remove_owned_firewall_rules() {
    FIREWALL_REMOVALS=$((FIREWALL_REMOVALS + 1))
    rm -f "${ROOT}/firewall-live/owned"
    case "$FAIL_STAGE" in
        firewall-full) return 1 ;;
        firewall-uncertain) return 2 ;;
        *) return 0 ;;
    esac
}
acquire_firewall_lock() { return 0; }
release_firewall_lock() { return 0; }
read_firewall_state() {
    mapfile -t FIREWALL_STATE_RECORDS < <(tail -n +2 "$FIREWALL_STATE_FILE")
}
firewall_record_is_live() {
    [[ -e "${ROOT}/firewall-live/owned" ]]
}
add_firewall_record() {
    FIREWALL_RESTORES=$((FIREWALL_RESTORES + 1))
    [[ "$FAIL_STAGE" != firewall-restore ]] || return 1
    : > "${ROOT}/firewall-live/owned"
}
persist_raw_firewall_rules() {
    FIREWALL_PERSISTS=$((FIREWALL_PERSISTS + 1))
    return 0
}
restore_hy2_nat_records() { return 0; }
persist_hy2_nat_rules() { return 0; }
remove_managed_nginx_include() {
    [[ "$FAIL_STAGE" != nginx-config && "$FAIL_STAGE" != firewall-restore ]]
}
remove_managed_singbox_link() { [[ "$FAIL_STAGE" != links ]]; }
nginx() {
    if [[ "$FAIL_STAGE" == nginx-reload && "$FAIL_ONCE" -eq 0 ]]; then
        FAIL_ONCE=1
        return 1
    fi
    return 0
}

cp() {
    if [[ "$FAIL_STAGE" == snapshot && "$FAIL_ONCE" -eq 0 ]]; then
        local argument
        for argument in "$@"; do
            if [[ "$argument" == "$ROOT/etc/sing-box" ]]; then
                FAIL_ONCE=1
                return 1
            fi
        done
    fi
    command cp "$@"
}

rm() {
    if [[ "$FAIL_STAGE" == workdir && "$FAIL_ONCE" -eq 0 ]]; then
        local argument
        for argument in "$@"; do
            if [[ "$argument" == "$ROOT/etc/sing-box" ]]; then
                FAIL_ONCE=1
                return 1
            fi
        done
    fi
    command rm "$@"
}

setup_case() {
    local name="$1"
    ROOT="${tmp_dir}/${name}"
    command mkdir -p "${ROOT}/etc/systemd/system" \
        "${ROOT}/etc/sing-box" "${ROOT}/etc/nginx/conf.d"
    printf '%s\n' sing-unit > "${ROOT}/etc/systemd/system/sing-box.service"
    printf '%s\n' argo-unit > "${ROOT}/etc/systemd/system/argo.service"
    printf '%s\n' runtime > "${ROOT}/etc/sing-box/runtime.state"
    printf '%s\n' version=1 'iptables|4|sing-box-managed|443|tcp' \
        > "${ROOT}/etc/sing-box/firewall.state"
    mkdir -p "${ROOT}/firewall-live"
    : > "${ROOT}/firewall-live/owned"
    : > "${ROOT}/firewall-live/external"
    printf '%s\n' 'server {}' > "${ROOT}/etc/nginx/conf.d/sing-box.conf"
    SING_ACTIVE=1
    ARGO_ACTIVE=1
    SING_ENABLED=1
    ARGO_ENABLED=1
    FAIL_ONCE=0
    DAEMON_RELOADS=0
    FIREWALL_REMOVALS=0
    FIREWALL_RESTORES=0
    FIREWALL_PERSISTS=0
}

assert_full_rollback() {
    local stage="$1"
    local status

    setup_case "$stage"
    FAIL_STAGE="$stage"
    set +e
    perform_singbox_uninstall "$ROOT" 0 >/dev/null 2>&1
    status=$?
    set -e
    [[ "$status" -eq 1 ]] || fail "${stage} returned ${status} instead of fully-restored rc1"
    [[ "$SING_ACTIVE" -eq 1 && "$ARGO_ACTIVE" -eq 1 && \
       "$SING_ENABLED" -eq 1 && "$ARGO_ENABLED" -eq 1 ]] || \
        fail "${stage} did not restore active/enabled service state"
    [[ -f "${ROOT}/etc/sing-box/runtime.state" ]] || fail "${stage} did not restore workdir"
    [[ -f "${ROOT}/etc/systemd/system/sing-box.service" && \
       -f "${ROOT}/etc/systemd/system/argo.service" ]] || fail "${stage} did not restore units"
    [[ -f "${ROOT}/etc/nginx/conf.d/sing-box.conf" ]] || fail "${stage} did not restore Nginx config"
    [[ -e "${ROOT}/firewall-live/owned" ]] || fail "${stage} did not restore its owned firewall rule"
    [[ -e "${ROOT}/firewall-live/external" ]] || fail "${stage} touched an external firewall rule"
}

for stage in snapshot hy2-full firewall-full nginx-config nginx-reload daemon-reload links workdir; do
    assert_full_rollback "$stage"
done

# Network ownership is cleaned inside the transaction, after service quiesce,
# and a later failure restores both live/persistent firewall ownership without
# touching external rules.
setup_case network-cross-domain
FAIL_STAGE=nginx-config
set +e
perform_singbox_uninstall "$ROOT" 0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "cross-domain rollback returned ${status} instead of rc1"
[[ "$FIREWALL_REMOVALS" -eq 1 ]] || fail 'owned firewall cleanup was not delegated exactly once'
[[ "$FIREWALL_RESTORES" -eq 1 && "$FIREWALL_PERSISTS" -eq 1 ]] || \
    fail 'owned firewall live/persistent state was not restored'
[[ -e "${ROOT}/firewall-live/external" ]] || fail 'cross-domain rollback touched an external rule'

setup_case successful-network-cleanup
FAIL_STAGE=''
perform_singbox_uninstall "$ROOT" 0 >/dev/null 2>&1 || fail 'successful network uninstall failed'
[[ ! -e "${ROOT}/firewall-live/owned" ]] || fail 'successful uninstall retained an owned firewall rule'
[[ -e "${ROOT}/firewall-live/external" ]] || fail 'successful uninstall removed an external firewall rule'
[[ "$FIREWALL_REMOVALS" -eq 1 ]] || fail 'successful uninstall cleaned firewall ownership more than once'

# A lower layer that already reports incomplete firewall recovery forces rc2
# even when filesystem and service restoration succeeds.
setup_case hy2-uncertain
FAIL_STAGE=hy2-uncertain
set +e
perform_singbox_uninstall "$ROOT" 0 >"${ROOT}/recovery-output" 2>&1
status=$?
set -e
recovery_output="$(cat "${ROOT}/recovery-output")"
[[ "$status" -eq 2 ]] || fail "uncertain HY2 cleanup returned ${status} instead of rc2"
[[ "$SING_ACTIVE" -eq 0 && "$ARGO_ACTIVE" -eq 0 && \
   "$SING_ENABLED" -eq 0 && "$ARGO_ENABLED" -eq 0 ]] || \
    fail 'rc2 recovery restarted services despite uncertain network state'
shopt -s nullglob
recoveries=("${ROOT}/var/lib/sing-box-uninstall"/.uninstall-recovery.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'uncertain HY2 cleanup did not retain one recovery snapshot'
[[ "$(stat -c '%a' "${recoveries[0]}")" == 700 ]] || fail 'retained uninstall snapshot is not 0700'
[[ -f "${recoveries[0]}/recovery.conf" && \
   "$(stat -c '%a' "${recoveries[0]}/recovery.conf")" == 600 ]] || \
    fail 'retained uninstall recovery metadata is missing or not 0600'
[[ "$recovery_output" == *'自动回滚不完整'*"${recoveries[0]}"* ]] || \
    fail 'uncertain HY2 cleanup did not report recovery path'

# A firewall restore failure is also rc2, retains secure recovery evidence,
# and leaves both services quiesced.
setup_case firewall-restore
FAIL_STAGE=firewall-restore
set +e
perform_singbox_uninstall "$ROOT" 0 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "firewall restore failure returned ${status} instead of rc2"
recoveries=("${ROOT}/var/lib/sing-box-uninstall"/.uninstall-recovery.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'firewall restore failure did not retain recovery evidence'
[[ "$(stat -c '%a' "${recoveries[0]}")" == 700 ]] || fail 'firewall recovery directory is not 0700'
[[ "$(stat -c '%a' "${recoveries[0]}/recovery.conf")" == 600 ]] || fail 'firewall recovery metadata is not 0600'
[[ "$SING_ACTIVE" -eq 0 && "$ARGO_ACTIVE" -eq 0 && \
   "$SING_ENABLED" -eq 0 && "$ARGO_ENABLED" -eq 0 ]] || \
    fail 'firewall rc2 recovery restarted services'

printf 'Post-quiesce uninstall transaction tests passed.\n'
