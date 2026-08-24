#!/usr/bin/env bash

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

failures=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

required_functions=(
    render_nginx_subscription_location
    render_nginx_subscription_server
    get_nginx_subscription_port
    get_nginx_subscription_paths
    classify_nginx_subscription_config
    validate_managed_subscription_runtime
    backup_subscription_frontend_snapshot
    subscription_frontend_snapshot_file_digest
    verify_subscription_frontend_snapshot_baseline
    cleanup_subscription_frontend_snapshot
    restore_subscription_frontend_snapshot
    rollback_subscription_frontend_signal_transaction
    prepare_subscription_frontend_state_transaction
    commit_subscription_frontend_state_transaction
    _configure_cf_https_subscription_locked
    _disable_cf_https_subscription_locked
    _rotate_subscription_token_locked
    restore_subscription_port_snapshot
    rollback_subscription_port_transaction
    rollback_subscription_port_signal_transaction
    _change_subscription_port_transaction_locked
    reset_durable_transaction_state
    assert_no_pending_durable_transaction
    write_durable_transaction_registry
    cleanup_durable_transaction_registry
    write_durable_transaction_manifest
    restore_durable_transaction_traps
    arm_durable_transaction
    durable_transaction_checkpoint
    durable_transaction_set_owned_records
    disarm_durable_transaction
    durable_transaction_trap_handler
)

for function_name in "${required_functions[@]}"; do
    function_source="$(extract_function "$function_name")"
    [ -n "$function_source" ] || {
        printf 'FAIL: required production function %s is missing\n' "$function_name" >&2
        exit 1
    }
    # shellcheck disable=SC1090
    source <(printf '%s\n' "$function_source") || {
        printf 'FAIL: unable to load production function %s\n' "$function_name" >&2
        exit 1
    }
done

run_case() {
    local name="$1"
    shift
    if ( "$@" ); then
        printf 'PASS: %s\n' "$name"
    else
        printf 'RED:  %s\n' "$name" >&2
        failures=$((failures + 1))
    fi
}

digest() {
    sha256sum "$1" | awk '{print $1}'
}

write_state_file() {
    local target="$1"
    local enabled="${2:-0}"
    local token="${3:-11111111111111111111111111111111}"
    local http_path="${4:-/${token}}"
    local https_path="${5:-/sub/${token}}"

    {
        printf 'SUB_TOKEN=%q\n' "$token"
        printf 'SUB_HTTP_PATH=%q\n' "$http_path"
        printf 'SUB_HTTPS_ENABLED=%q\n' "$enabled"
        if [ "$enabled" = 1 ]; then
            printf 'SUB_HTTPS_DOMAIN=%q\n' 'node.example.test'
            printf 'SUB_HTTPS_DOMAIN_MODE=%q\n' 'reuse'
            printf 'SUB_HTTPS_PATH=%q\n' "$https_path"
            printf 'SUB_TUNNEL_MODE=%q\n' 'local'
            printf 'SUB_HTTPS_VERIFIED_AT=%q\n' '2026-01-01T00:00:00Z'
        else
            printf 'SUB_HTTPS_DOMAIN=%q\n' ''
            printf 'SUB_HTTPS_DOMAIN_MODE=%q\n' ''
            printf 'SUB_HTTPS_PATH=%q\n' ''
            printf 'SUB_TUNNEL_MODE=%q\n' ''
            printf 'SUB_HTTPS_VERIFIED_AT=%q\n' ''
        fi
    } > "$target"
    chmod 600 "$target"
}

setup_fixture() {
    local name="$1"
    local initially_active="${2:-1}"

    case_dir="${tmp_dir}/${name}"
    work_dir="${case_dir}/work"
    conf_dir="${work_dir}/conf"
    NGINX_SUBSCRIPTION_CONF="${case_dir}/sing-box.conf"
    subscription_state_file="${work_dir}/subscription.state"
    STATE_TARGET="$subscription_state_file"
    SERVICE_STATE_FILE="${case_dir}/nginx.active"
    CALL_LOG="${case_dir}/calls.log"
    mkdir -p "$conf_dir"
    : > "$CALL_LOG"
    printf '%s\n' "$initially_active" > "$SERVICE_STATE_FILE"
    cat > "${work_dir}/tunnel.yml" <<'YAML'
tunnel: test-tunnel
ingress:
  - hostname: node.example.test
    service: http://127.0.0.1:8001
  - service: http_status:404
YAML
    : > "${conf_dir}/inbounds.json"

    purple=''
    re=''
    APPLY_FAIL=0
    STATE_COMMIT_FAIL_ONCE=0
    CORRUPT_CONFIG_AFTER_ROUTE=0
    DURABLE_SIGNAL_STAGE=''
    DURABLE_SIGNAL_NAME='TERM'
    DURABLE_TX_REGISTRY_DIR="$conf_dir"
    FRONTEND_RECOVERY_PATH=''
    SUBSCRIPTION_PORT_RECOVERY_PATH=''
    FIREWALL_LAST_ADDED_RECORDS=()
    reset_durable_transaction_state

    is_valid_http_subscription_path() {
        [[ "${1:-}" == /* && "${1:-}" != *[[:space:]]* ]]
    }
    is_valid_subscription_path() { is_valid_http_subscription_path "${1:-}"; }
    is_valid_subscription_token() { [[ "${1:-}" =~ ^[A-Za-z0-9_-]{32}$ ]]; }
    is_valid_subscription_domain() { [[ "${1:-}" =~ ^[A-Za-z0-9.-]+$ ]]; }
    load_subscription_state() {
        SUB_TOKEN=''
        SUB_HTTP_PATH=''
        SUB_HTTPS_ENABLED=0
        SUB_HTTPS_DOMAIN=''
        SUB_HTTPS_DOMAIN_MODE=''
        SUB_HTTPS_PATH=''
        SUB_TUNNEL_MODE=''
        SUB_HTTPS_VERIFIED_AT=''
        [ ! -f "$subscription_state_file" ] || source "$subscription_state_file"
    }
    save_subscription_state() {
        write_state_file "$subscription_state_file" "${SUB_HTTPS_ENABLED:-0}" \
            "${SUB_TOKEN:-}" "${SUB_HTTP_PATH:-}" "${SUB_HTTPS_PATH:-}"
    }
    mv() {
        local source_path destination_path
        source_path="${@: -2:1}"
        destination_path="${@: -1}"
        if [ "$STATE_COMMIT_FAIL_ONCE" -eq 1 ] && \
           [ "$destination_path" = "$STATE_TARGET" ] && \
           [[ "$(basename "$source_path")" == .subscription-state-pending.* ]]; then
            STATE_COMMIT_FAIL_ONCE=0
            return 1
        fi
        command mv "$@"
    }
    reading() {
        case "$1" in
            *'[1-2'*) printf -v "$2" '%s' 1 ;;
            *端口*) printf -v "$2" '%s' 25001 ;;
            *) printf -v "$2" '%s' y ;;
        esac
    }
    generate_subscription_token() { printf '%s\n' '0123456789abcdefghjkmnpqrstvwxyz'; }
    detect_argo_tunnel_mode() { printf '%s\n' local; }
    get_subscription_host() { printf '%s\n' subscription.example.test; }
    build_http_subscription_url() { printf 'http://%s:%s%s\n' "$1" "$2" "$3"; }
    build_https_subscription_url() { printf 'https://%s%s\n' "$1" "$2"; }
    verify_https_subscription() { return 0; }
    print_manual_https_route() { :; }
    apply_remote_tunnel_subscription_rule() { return 1; }
    remove_remote_tunnel_subscription_via_api() { return 1; }
    apply_local_tunnel_subscription_rule() {
        printf 'route-add\n' >> "$CALL_LOG"
        printf '\n# managed-route:%s:%s:%s\n' "$1" "$2" "$3" >> "$5"
    }
    apply_local_tunnel_subscription_removal() {
        local target="$1"
        printf 'route-remove\n' >> "$CALL_LOG"
        cat > "$target" <<'YAML'
tunnel: test-tunnel
ingress:
  - service: http_status:404
YAML
        if [ "$CORRUPT_CONFIG_AFTER_ROUTE" -eq 1 ]; then
            printf 'server { listen broken; }\n' > "$NGINX_SUBSCRIPTION_CONF"
        fi
    }
    apply_nginx_subscription_config() {
        local port="$1" http_path="$2" https_path="${3:-}" preserve="${4:-start}"
        local config_file="${5:-$NGINX_SUBSCRIPTION_CONF}"
        local candidate="${case_dir}/nginx.candidate"
        printf 'nginx-apply:%s:%s:%s:%s\n' "$port" "$http_path" "$https_path" "$preserve" >> "$CALL_LOG"
        [ "$APPLY_FAIL" -eq 0 ] || return 1
        render_nginx_subscription_server "$port" "$http_path" "$https_path" 0 > "$candidate" || return 1
        command mv -f -- "$candidate" "$config_file" || return 1
        case "$preserve" in
            0) ;;
            1|start|'') printf '1\n' > "$SERVICE_STATE_FILE" ;;
            *) return 1 ;;
        esac
    }
    nginx_service_is_active() { [ "$(cat "$SERVICE_STATE_FILE")" = 1 ]; }
    check_argo() { return 0; }
    restart_argo() { printf 'argo-restart\n' >> "$CALL_LOG"; }
    stop_argo() { printf 'argo-stop\n' >> "$CALL_LOG"; }
    start_nginx() { printf '1\n' > "$SERVICE_STATE_FILE"; }
    restart_nginx() { printf '1\n' > "$SERVICE_STATE_FILE"; }
    stop_nginx_checked() { printf '0\n' > "$SERVICE_STATE_FILE"; }
    nginx() {
        if [ "${1:-}" = -t ]; then
            return 0
        fi
        if [ "${1:-}" = -s ] && [ "${2:-}" = reload ]; then
            nginx_service_is_active
            return $?
        fi
        return 0
    }
    command_exists() { [ "${1:-}" = nginx ]; }
    validate_port_value() {
        [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
    }
    configured_inbound_port_conflict_exists() { return 1; }
    port_is_listening() { return 1; }
    allow_port() {
        FIREWALL_LAST_ADDED_RECORDS=("raw|4|${1%/*}|tcp")
        printf 'allow:%s\n' "$1" >> "$CALL_LOG"
    }
    remove_owned_firewall_records_exact() { printf 'firewall-rollback\n' >> "$CALL_LOG"; }
    remove_owned_firewall_ports_if_unused() { printf 'firewall-clean-old\n' >> "$CALL_LOG"; }
    update_cf_https_subscription_origin() { printf 'origin:%s\n' "$1" >> "$CALL_LOG"; }
    green() { :; }
    yellow() { :; }
    red() { :; }
    durable_transaction_hook() {
        [ -n "$DURABLE_SIGNAL_STAGE" ] && [ "$1" = "$DURABLE_SIGNAL_STAGE" ] || return 0
        kill -s "$DURABLE_SIGNAL_NAME" "$BASHPID"
    }
}

render_http_frontend() {
    local token="${1:-11111111111111111111111111111111}"
    local port="${2:-24000}"
    render_nginx_subscription_server "$port" "/${token}" '' 0 > "$NGINX_SUBSCRIPTION_CONF"
    write_state_file "$subscription_state_file" 0 "$token" "/${token}" ''
}

render_https_frontend() {
    local token="${1:-11111111111111111111111111111111}"
    local port="${2:-24000}"
    render_nginx_subscription_server "$port" "/${token}" "/sub/${token}" 0 > "$NGINX_SUBSCRIPTION_CONF"
    write_state_file "$subscription_state_file" 1 "$token" "/${token}" "/sub/${token}"
}

assert_frontend_exact() {
    local config_digest="$1" state_digest="$2" tunnel_digest="$3" service_state="$4"
    local label="${5:-frontend}" status=0

    [ "$(digest "$NGINX_SUBSCRIPTION_CONF")" = "$config_digest" ] || {
        fail "${label}: Nginx config was not restored exactly"
        status=1
    }
    [ "$(digest "$subscription_state_file")" = "$state_digest" ] || {
        fail "${label}: subscription state was not restored exactly"
        status=1
    }
    [ "$(digest "${work_dir}/tunnel.yml")" = "$tunnel_digest" ] || {
        fail "${label}: local tunnel was not restored exactly"
        status=1
    }
    [ "$(cat "$SERVICE_STATE_FILE")" = "$service_state" ] || {
        fail "${label}: Nginx service state was not restored"
        status=1
    }
    return "$status"
}

assert_no_frontend_evidence() {
    local label="${1:-frontend}" status=0

    [ ! -e "${conf_dir}/.durable-transaction.pending" ] || {
        fail "${label}: safe rollback left a pending durable registry"
        status=1
    }
    if find "$conf_dir" -maxdepth 1 -type d -name '.subscription-frontend.*' -print -quit | grep -q .; then
        fail "${label}: safe rollback left a frontend snapshot"
        status=1
    fi
    return "$status"
}

test_configure_inactive_fail_close() {
    local status=0 config_before state_before tunnel_before

    setup_fixture configure-inactive 0
    render_http_frontend
    config_before="$(digest "$NGINX_SUBSCRIPTION_CONF")"
    state_before="$(digest "$subscription_state_file")"
    tunnel_before="$(digest "${work_dir}/tunnel.yml")"
    _configure_cf_https_subscription_locked >/dev/null 2>&1 || status=$?
    [ "$status" -eq 1 ] || fail "inactive configure returned ${status}, expected 1" || return 1
    assert_frontend_exact "$config_before" "$state_before" "$tunnel_before" 0 configure-inactive || return 1
    [ ! -s "$CALL_LOG" ] || fail 'inactive configure performed a runtime mutation' || return 1
    assert_no_frontend_evidence configure-inactive
}

test_disable_failure_rollbacks() {
    local mode initial status config_before state_before tunnel_before

    for mode in nginx-apply state-commit nginx-post-route; do
        for initial in 0 1; do
            setup_fixture "disable-${mode}-${initial}" "$initial"
            render_https_frontend
            config_before="$(digest "$NGINX_SUBSCRIPTION_CONF")"
            state_before="$(digest "$subscription_state_file")"
            tunnel_before="$(digest "${work_dir}/tunnel.yml")"
            case "$mode" in
                nginx-apply) APPLY_FAIL=1 ;;
                state-commit) STATE_COMMIT_FAIL_ONCE=1 ;;
                nginx-post-route) CORRUPT_CONFIG_AFTER_ROUTE=1 ;;
            esac
            status=0
            _disable_cf_https_subscription_locked >/dev/null 2>&1 || status=$?
            [ "$status" -ne 0 ] || fail "disable ${mode}/${initial} reported success" || return 1
            assert_frontend_exact "$config_before" "$state_before" "$tunnel_before" \
                "$initial" "${mode}/${initial}" || return 1
            if [ "$mode" = nginx-apply ]; then
                ! grep -Fqx route-remove "$CALL_LOG" || fail 'route was removed after Nginx apply failed' || return 1
            else
                grep -Fqx route-remove "$CALL_LOG" || fail "${mode} did not reach local route removal" || return 1
            fi
            assert_no_frontend_evidence "${mode}/${initial}" || return 1
        done
    done
}

run_frontend_signal_case() {
    local operation="$1" stage="$2" expected_status="$3"
    local status=0 config_before state_before tunnel_before registry evidence

    setup_fixture "signal-${operation}-${stage}" 1
    if [ "$operation" = configure ]; then
        render_http_frontend
    else
        render_https_frontend
    fi
    config_before="$(digest "$NGINX_SUBSCRIPTION_CONF")"
    state_before="$(digest "$subscription_state_file")"
    tunnel_before="$(digest "${work_dir}/tunnel.yml")"
    DURABLE_SIGNAL_STAGE="$stage"
    (
        trap - EXIT
        if [ "$operation" = configure ]; then
            _configure_cf_https_subscription_locked >/dev/null 2>&1
        else
            _disable_cf_https_subscription_locked >/dev/null 2>&1
        fi
    ) || status=$?
    [ "$status" -eq "$expected_status" ] || {
        fail "${operation}/${stage} returned ${status}, expected ${expected_status}"
        return 1
    }
    registry="${conf_dir}/.durable-transaction.pending"
    if [ "$stage" = config-mutated ]; then
        assert_frontend_exact "$config_before" "$state_before" "$tunnel_before" 1 \
            "${operation}/${stage}" || return 1
        assert_no_frontend_evidence "${operation}/${stage}" || return 1
    else
        [ -f "$registry" ] && [ ! -L "$registry" ] || {
            fail "${operation}/publishing did not preserve the unified registry"
            return 1
        }
        IFS= read -r evidence < "$registry" || evidence=''
        [ -f "${evidence}/manifest" ] && grep -Fqx 'stage=publishing' "${evidence}/manifest" || {
            fail "${operation}/publishing registry has no publishing manifest"
            return 1
        }
    fi
}

test_configure_disable_signal_boundaries() {
    run_frontend_signal_case configure config-mutated 143 || return 1
    run_frontend_signal_case configure publishing 2 || return 1
    run_frontend_signal_case disable config-mutated 143 || return 1
    run_frontend_signal_case disable publishing 2 || return 1
}

test_https_two_path_port_transaction() {
    local status=0 state_before
    local -a paths=()

    setup_fixture https-port 0
    render_https_frontend
    state_before="$(digest "$subscription_state_file")"
    _change_subscription_port_transaction_locked "$NGINX_SUBSCRIPTION_CONF" 25001 >/dev/null 2>&1 || status=$?
    [ "$status" -eq 0 ] || fail "two-path HTTPS port transaction returned ${status}" || return 1
    [ "$(get_nginx_subscription_port "$NGINX_SUBSCRIPTION_CONF")" = 25001 ] || fail 'HTTPS port was not changed' || return 1
    mapfile -t paths < <(get_nginx_subscription_paths "$NGINX_SUBSCRIPTION_CONF")
    [ "${#paths[@]}" -eq 2 ] || fail 'HTTPS port change lost a subscription path' || return 1
    [ "${paths[0]}" = /11111111111111111111111111111111 ] || fail 'HTTP path changed during HTTPS port transaction' || return 1
    [ "${paths[1]}" = /sub/11111111111111111111111111111111 ] || fail 'HTTPS path changed during HTTPS port transaction' || return 1
    [ "$(digest "$subscription_state_file")" = "$state_before" ] || fail 'HTTPS port transaction changed subscription state' || return 1
    validate_managed_subscription_runtime "$NGINX_SUBSCRIPTION_CONF" https || fail 'two-path HTTPS runtime is unusable after port change' || return 1
    grep -Fqx 'origin:25001' "$CALL_LOG" || fail 'HTTPS origin was not updated to the new port' || return 1
    [ ! -e "${conf_dir}/.durable-transaction.pending" ] || fail 'successful HTTPS port change left a pending registry'
}

test_http_rotate_rejects_inconsistent_state() {
    local status=0 config_before state_before tunnel_before

    setup_fixture rotate-inconsistent 1
    render_nginx_subscription_server 24000 /11111111111111111111111111111111 '' 0 > "$NGINX_SUBSCRIPTION_CONF"
    write_state_file "$subscription_state_file" 0 22222222222222222222222222222222 \
        /22222222222222222222222222222222 ''
    config_before="$(digest "$NGINX_SUBSCRIPTION_CONF")"
    state_before="$(digest "$subscription_state_file")"
    tunnel_before="$(digest "${work_dir}/tunnel.yml")"
    _rotate_subscription_token_locked >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail 'HTTP rotate accepted inconsistent config/state' || return 1
    assert_frontend_exact "$config_before" "$state_before" "$tunnel_before" 1 \
        rotate-inconsistent || return 1
    [ ! -s "$CALL_LOG" ] || fail 'rejected HTTP rotate performed a runtime mutation' || return 1
    assert_no_frontend_evidence rotate-inconsistent
}

run_case 'configure refuses inactive Nginx without mutation' test_configure_inactive_fail_close
run_case 'disable restores tunnel, config, state, and service state on local failures' test_disable_failure_rollbacks
run_case 'configure/disable signals roll back locally or preserve one publishing registry' test_configure_disable_signal_boundaries
run_case 'two-path HTTPS frontend remains usable across subscription port change' test_https_two_path_port_transaction
run_case 'HTTP rotate rejects inconsistent state without mutation' test_http_rotate_rejects_inconsistent_state

if [ "$failures" -ne 0 ]; then
    printf 'Extended subscription frontend tests: %d RED group(s).\n' "$failures" >&2
    exit 1
fi

printf 'Extended subscription frontend durability tests passed.\n'
