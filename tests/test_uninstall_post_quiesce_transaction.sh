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
remove_managed_nginx_include() { [[ "$FAIL_STAGE" != nginx-config ]]; }
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
    printf '%s\n' 'server {}' > "${ROOT}/etc/nginx/conf.d/sing-box.conf"
    SING_ACTIVE=1
    ARGO_ACTIVE=1
    SING_ENABLED=1
    ARGO_ENABLED=1
    FAIL_ONCE=0
    DAEMON_RELOADS=0
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
}

for stage in snapshot hy2-full nginx-config nginx-reload daemon-reload links workdir; do
    assert_full_rollback "$stage"
done

# A lower layer that already reports incomplete firewall recovery forces rc2
# even when filesystem and service restoration succeeds.
setup_case hy2-uncertain
FAIL_STAGE=hy2-uncertain
set +e
recovery_output="$(perform_singbox_uninstall "$ROOT" 0 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "uncertain HY2 cleanup returned ${status} instead of rc2"
shopt -s nullglob
recoveries=("${ROOT}/var/lib/sing-box-uninstall"/.uninstall-recovery.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'uncertain HY2 cleanup did not retain one recovery snapshot'
[[ "$(stat -c '%a' "${recoveries[0]}")" == 700 ]] || fail 'retained uninstall snapshot is not 0700'
[[ -f "${recoveries[0]}/recovery.conf" && \
   "$(stat -c '%a' "${recoveries[0]}/recovery.conf")" == 600 ]] || \
    fail 'retained uninstall recovery metadata is missing or not 0600'
[[ "$recovery_output" == *'自动回滚不完整'*"${recoveries[0]}"* ]] || \
    fail 'uncertain HY2 cleanup did not report recovery path'

printf 'Post-quiesce uninstall transaction tests passed.\n'
