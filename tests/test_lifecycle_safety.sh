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
grep -Fq 'nginx_service_is_active' <<< "$stop_subscription_source" || \
    fail 'subscription stop does not delegate active-backend status checks'
grep -Fq 'stop_nginx_checked' <<< "$stop_subscription_source" || \
    fail 'subscription stop does not delegate active-backend stop'
manage_argo_source="$(extract_function manage_argo)"
grep -Fq 'resolve_argo_service_definition' <<< "$manage_argo_source" || \
    fail 'Argo menu does not resolve its definition through the active backend'

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
NGINX_MOCK_ACTIVE=1
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
        'is-active --quiet nginx') [ "$NGINX_MOCK_ACTIVE" -eq 1 ]; return $? ;;
        'stop nginx') NGINX_MOCK_ACTIVE=0 ;;
    esac
    return 0
}
rc-service() {
    printf 'rc-service %s\n' "$*" >> "$BACKEND_LOG"
    case "$*" in
        'nginx status') [ "$NGINX_MOCK_ACTIVE" -eq 1 ]; return $? ;;
        'nginx stop') NGINX_MOCK_ACTIVE=0 ;;
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
    NGINX_MOCK_ACTIVE=1
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
    NGINX_MOCK_ACTIVE=1
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
