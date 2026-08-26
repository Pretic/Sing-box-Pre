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

# Every lifecycle entry point must select its backend through the active-init
# detector. Merely having apk/rc-service installed must not divert a running
# systemd host (and vice versa when OpenRC is active).
direct_backend_functions=(
    check_service
    legacy_services_are_active
    detect_argo_tunnel_mode
    apply_nginx_subscription_config
    manage_service
    query_nginx_service_state
    nginx_service_is_active
    stop_nginx_checked
    resolve_argo_service_definition
    restart_singbox_checked
    stop_singbox_checked
    singbox_service_is_stably_active
    singbox_service_is_active
    argo_service_is_active
    restart_argo_checked
    stop_argo_checked
)
for function_name in "${direct_backend_functions[@]}"; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    grep -Fq 'detect_usable_init_system' <<< "$function_source" || \
        fail "$function_name does not use the canonical active-init detector"
    if grep -Eq 'command_exists (apk|rc-service|systemctl)' <<< "$function_source"; then
        fail "$function_name still selects lifecycle backend from command presence"
    fi
    source <(printf '%s\n' "$function_source")
done

for function_name in _stop_subscription_service_locked manage_argo; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    if grep -Eq 'command_exists (apk|rc-service|systemctl)' <<< "$function_source"; then
        fail "$function_name still selects lifecycle backend from command presence"
    fi
    source <(printf '%s\n' "$function_source")
done
stop_subscription_source="$(extract_function _stop_subscription_service_locked)"
grep -Fq 'query_nginx_service_state' <<< "$stop_subscription_source" || \
    fail 'subscription stop does not delegate tri-state active-backend status checks'
grep -Fq 'stop_nginx_checked' <<< "$stop_subscription_source" || \
    fail 'subscription stop does not delegate active-backend stop'
manage_argo_source="$(extract_function manage_argo)"
grep -Fq 'resolve_argo_service_definition' <<< "$manage_argo_source" || \
    fail 'Argo menu does not resolve its definition through the active backend'

# When both backends are installed and report usable runtimes, the canonical
# detector's systemd priority must also govern lifecycle helpers.
mixed_root="${tmp_dir}/mixed-active-init"
mixed_service_file="${mixed_root}/sing-box"
MIXED_BACKEND_LOG="${mixed_root}/backend.log"
SYSTEMD_RUNTIME_DIR="${mixed_root}/run/systemd/system"
OPENRC_SOFTLEVEL_FILE="${mixed_root}/run/openrc/softlevel"
mkdir -p "$SYSTEMD_RUNTIME_DIR" "$(dirname "$OPENRC_SOFTLEVEL_FILE")"
: > "$OPENRC_SOFTLEVEL_FILE"
: > "$mixed_service_file"
: > "$MIXED_BACKEND_LOG"
command_exists() {
    case "${1:-}" in systemctl|rc-update|rc-service) return 0 ;; *) return 1 ;; esac
}
green() { :; }
yellow() { :; }
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$MIXED_BACKEND_LOG"
    case "$*" in
        show-environment) return 0 ;;
        'is-active sing-box') printf 'active\n'; return 0 ;;
        *) return 0 ;;
    esac
}
rc-service() { printf 'rc-service %s\n' "$*" >> "$MIXED_BACKEND_LOG"; return 0; }
assert_equal systemd "$(detect_usable_init_system)" \
    'mixed active init detector priority'
check_service sing-box "$mixed_service_file" >/dev/null
grep -Fq 'systemctl is-active sing-box' "$MIXED_BACKEND_LOG" || \
    fail 'mixed active lifecycle helper did not use the canonical systemd backend'
! grep -Fq 'rc-service ' "$MIXED_BACKEND_LOG" || \
    fail 'mixed active lifecycle helper also invoked OpenRC'

backend_root="${tmp_dir}/backend-coexist"
work_dir="${backend_root}/etc/sing-box"
server_name=sing-box
ARGO_SYSTEMD_SERVICE_FILE="${backend_root}/etc/systemd/system/argo.service"
ARGO_OPENRC_SERVICE_FILE="${backend_root}/etc/init.d/argo"
mkdir -p "$work_dir" "$(dirname "$ARGO_SYSTEMD_SERVICE_FILE")" \
    "$(dirname "$ARGO_OPENRC_SERVICE_FILE")"
: > "${work_dir}/sing-box"
: > "${work_dir}/argo"
: > "${work_dir}/nginx"
cat > "$ARGO_SYSTEMD_SERVICE_FILE" <<'EOF'
ExecStart=/bin/sh -c '/etc/sing-box/argo tunnel --url http://127.0.0.1:8001 --no-autoupdate'
EOF
cat > "$ARGO_OPENRC_SERVICE_FILE" <<'EOF'
start_pre() { . /etc/sing-box/argo.env; }
command_args="tunnel --no-autoupdate run"
EOF
BACKEND_LOG="${backend_root}/backend.log"
NGINX_MOCK_RAW=0
command_exists() { return 0; }
command() {
    if [[ "${1:-}" == -v && "${2:-}" == nginx ]]; then
        printf '%s\n' "${work_dir}/nginx"
        return 0
    fi
    builtin command "$@"
}
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$BACKEND_LOG"
    case "$*" in
        'is-active --quiet nginx') return "$NGINX_MOCK_RAW" ;;
        'stop nginx') NGINX_MOCK_RAW=3 ;;
    esac
    return 0
}
rc-service() {
    printf 'rc-service %s\n' "$*" >> "$BACKEND_LOG"
    case "$*" in
        'nginx status') return "$NGINX_MOCK_RAW" ;;
        'nginx stop') NGINX_MOCK_RAW=3 ;;
    esac
    return 0
}
red() { :; }
yellow() { :; }
green() { printf '%s\n' "$*"; }

exercise_selected_backend() {
    local selected_backend="$1" expected_mode expected_definition

    SELECTED_INIT_SYSTEM="$selected_backend"
    detect_usable_init_system() { printf '%s\n' "$SELECTED_INIT_SYSTEM"; }
    NGINX_MOCK_RAW=0
    : > "$BACKEND_LOG"
    check_service sing-box "${work_dir}/sing-box" >/dev/null
    manage_service sing-box restart >/dev/null
    nginx_service_is_active
    stop_nginx_checked
    restart_singbox_checked >/dev/null
    stop_singbox_checked
    argo_service_is_active
    restart_argo_checked >/dev/null
    stop_argo_checked
    NGINX_MOCK_RAW=0
    _stop_subscription_service_locked >/dev/null

    if [ "$selected_backend" = systemd ]; then
        ! grep -Fq 'rc-service ' "$BACKEND_LOG" || \
            fail 'systemd lifecycle was diverted to coexisting rc-service'
        grep -Fq 'systemctl ' "$BACKEND_LOG" || \
            fail 'systemd lifecycle did not use systemctl'
        expected_mode=quick
        expected_definition="$ARGO_SYSTEMD_SERVICE_FILE"
    else
        ! grep -Fq 'systemctl ' "$BACKEND_LOG" || \
            fail 'OpenRC lifecycle was diverted to coexisting systemctl'
        grep -Fq 'rc-service ' "$BACKEND_LOG" || \
            fail 'OpenRC lifecycle did not use rc-service'
        expected_mode=remote
        expected_definition="$ARGO_OPENRC_SERVICE_FILE"
    fi
    [[ "$(detect_argo_tunnel_mode)" == "$expected_mode" ]] || \
        fail "${selected_backend} Argo mode used the wrong service definition"
    [[ "$(resolve_argo_service_definition)" == "$expected_definition" ]] || \
        fail "${selected_backend} Argo definition resolver chose the wrong backend"
}

exercise_selected_backend systemd
exercise_selected_backend openrc

# Nginx stop is tri-state: only raw 0 is active and raw 3 is explicitly
# inactive. Raw 1/4 (including a dead system bus) are query errors and must not
# be reported as an already-stopped success.
NGINX_QUERY_RAW=0
NGINX_STOP_RAW=3
NGINX_STOP_STATUS=0
NGINX_STOP_CALLS=0
systemctl() {
    case "$*" in
        'is-active --quiet nginx') return "$NGINX_QUERY_RAW" ;;
        'stop nginx')
            NGINX_STOP_CALLS=$((NGINX_STOP_CALLS + 1))
            NGINX_QUERY_RAW=$NGINX_STOP_RAW
            return "$NGINX_STOP_STATUS"
            ;;
    esac
    return 0
}
rc-service() {
    case "$*" in
        'nginx status') return "$NGINX_QUERY_RAW" ;;
        'nginx stop')
            NGINX_STOP_CALLS=$((NGINX_STOP_CALLS + 1))
            NGINX_QUERY_RAW=$NGINX_STOP_RAW
            return "$NGINX_STOP_STATUS"
            ;;
    esac
    return 0
}
for selected_backend in systemd openrc; do
    SELECTED_INIT_SYSTEM="$selected_backend"
    detect_usable_init_system() { printf '%s\n' "$SELECTED_INIT_SYSTEM"; }

    NGINX_QUERY_RAW=0
    assert_equal active "$(query_nginx_service_state)" \
        "${selected_backend} raw0 Nginx state"
    NGINX_QUERY_RAW=3
    assert_equal inactive "$(query_nginx_service_state)" \
        "${selected_backend} raw3 Nginx state"
    for query_error in 1 4; do
        NGINX_QUERY_RAW=$query_error
        assert_equal error "$(query_nginx_service_state)" \
            "${selected_backend} raw${query_error} Nginx state"
        NGINX_STOP_CALLS=0
        if _stop_subscription_service_locked >/dev/null; then
            fail "${selected_backend} raw${query_error} query error was reported as stopped"
        fi
        [[ "$NGINX_STOP_CALLS" -eq 0 ]] || \
            fail "${selected_backend} raw${query_error} query error attempted a stop"
    done

    NGINX_QUERY_RAW=3
    NGINX_STOP_CALLS=0
    _stop_subscription_service_locked >/dev/null || \
        fail "${selected_backend} explicit inactive state was not idempotent"
    [[ "$NGINX_STOP_CALLS" -eq 0 ]] || \
        fail "${selected_backend} explicit inactive state attempted a stop"

    NGINX_QUERY_RAW=0
    NGINX_STOP_RAW=3
    NGINX_STOP_STATUS=0
    NGINX_STOP_CALLS=0
    _stop_subscription_service_locked >/dev/null || \
        fail "${selected_backend} active-to-inactive stop failed"
    [[ "$NGINX_STOP_CALLS" -eq 1 ]] || \
        fail "${selected_backend} active Nginx was not stopped exactly once"

    NGINX_QUERY_RAW=0
    NGINX_STOP_RAW=1
    NGINX_STOP_STATUS=0
    NGINX_STOP_CALLS=0
    if _stop_subscription_service_locked >/dev/null; then
        fail "${selected_backend} post-stop query error was reported as success"
    fi
done

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
