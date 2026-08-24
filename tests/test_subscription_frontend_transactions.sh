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

# Load only the production surface exercised here.  Optional subscription
# transaction helpers are discovered by name so a later implementation can
# split snapshot/rollback work out of the four entrypoints without requiring
# this harness to source the script's executable entrypoint.
required_functions=(
    render_nginx_subscription_location
    render_nginx_subscription_server
    get_nginx_subscription_port
    get_nginx_subscription_paths
    classify_nginx_subscription_config
    validate_managed_subscription_runtime
    _configure_cf_https_subscription_locked
    configure_cf_https_subscription
    _disable_cf_https_subscription_locked
    disable_cf_https_subscription
    _rotate_subscription_token_locked
    rotate_subscription_token
    _start_subscription_service_locked
    start_subscription_service_transaction
    reset_durable_transaction_state
    assert_no_pending_durable_transaction
    write_durable_transaction_registry
    cleanup_durable_transaction_registry
    write_durable_transaction_manifest
    restore_durable_transaction_traps
    arm_durable_transaction
    durable_transaction_checkpoint
    durable_transaction_set_owned_records
    durable_transaction_trap_handler
    disarm_durable_transaction
)
mapfile -t optional_functions < <(
    sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)() {$/\1/p' "$script" |
        grep -E '(subscription.*(frontend|https|token|create).*(transaction|snapshot|rollback)|^(snapshot|restore|rollback|arm|finalize|prepare|commit).*subscription)' || true
)
declare -A loaded_functions=()
for function_name in "${required_functions[@]}" "${optional_functions[@]}"; do
    [ -z "${loaded_functions[$function_name]:-}" ] || continue
    function_source="$(extract_function "$function_name")"
    [ -n "$function_source" ] || {
        printf 'FAIL: required production function %s is missing\n' "$function_name" >&2
        exit 1
    }
    source <(printf '%s\n' "$function_source") || {
        printf 'FAIL: unable to load production function %s\n' "$function_name" >&2
        exit 1
    }
    loaded_functions[$function_name]=1
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

write_state_file() {
    local target="$1"
    local enabled="${2:-0}"
    local token="${3:-11111111111111111111111111111111}"
    local https_path="${4:-}"
    local tunnel_mode="${5:-local}"

    {
        printf 'SUB_TOKEN=%q\n' "$token"
        printf 'SUB_HTTP_PATH=%q\n' "/${token}"
        printf 'SUB_HTTPS_ENABLED=%q\n' "$enabled"
        if [ "$enabled" = 1 ]; then
            printf 'SUB_HTTPS_DOMAIN=%q\n' 'node.example.test'
            printf 'SUB_HTTPS_DOMAIN_MODE=%q\n' 'reuse'
            printf 'SUB_HTTPS_PATH=%q\n' "$https_path"
            printf 'SUB_TUNNEL_MODE=%q\n' "$tunnel_mode"
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

setup_frontend_fixture() {
    local name="$1"
    local initially_active="${2:-1}"

    case_dir="${tmp_dir}/${name}"
    work_dir="${case_dir}/work"
    conf_dir="${work_dir}/conf"
    NGINX_SUBSCRIPTION_CONF="${case_dir}/sing-box.conf"
    subscription_state_file="${work_dir}/subscription.state"
    FRONTEND_STATE_TARGET="$subscription_state_file"
    FRONTEND_LOG="${case_dir}/calls.log"
    SERVICE_STATE_FILE="${case_dir}/nginx.active"
    mkdir -p "$conf_dir"
    : > "$FRONTEND_LOG"
    printf '%s\n' "$initially_active" > "$SERVICE_STATE_FILE"
    printf '%s\n' 'tunnel: test-tunnel' > "${work_dir}/tunnel.yml"
    cat >> "${work_dir}/tunnel.yml" <<'YAML'
ingress:
  - hostname: node.example.test
    service: http://127.0.0.1:8001
  - service: http_status:404
YAML
    : > "${conf_dir}/inbounds.json"

    purple=''
    re=''
    STATE_COMMIT_FAIL_ONCE=0
    APPLY_FAIL=0
    FRONTEND_RECOVERY_PATH=''
    DURABLE_SIGNAL_STAGE=''
    DURABLE_SIGNAL_NAME='TERM'
    DURABLE_TX_REGISTRY_DIR="$conf_dir"
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
        printf 'save-state:%s\n' "$subscription_state_file" >> "$FRONTEND_LOG"
        if [ "$STATE_COMMIT_FAIL_ONCE" -eq 1 ] &&
           [ "$subscription_state_file" = "$FRONTEND_STATE_TARGET" ] &&
           grep -Fq '/0123456789abcdefghjkmnpqrstvwxyz' "$NGINX_SUBSCRIPTION_CONF" 2>/dev/null; then
            STATE_COMMIT_FAIL_ONCE=0
            return 1
        fi
        write_state_file "$subscription_state_file" "${SUB_HTTPS_ENABLED:-0}" \
            "${SUB_TOKEN:-}" "${SUB_HTTPS_PATH:-}"
    }
    mv() {
        local source_path='' destination_path=''
        if [ "$#" -ge 2 ]; then
            source_path="${@: -2:1}"
            destination_path="${@: -1}"
        fi
        if [ "$STATE_COMMIT_FAIL_ONCE" -eq 1 ] &&
           [ "$destination_path" = "$FRONTEND_STATE_TARGET" ] &&
           [[ "$source_path" == *subscription-state-pending* ]] &&
           grep -Fq '/0123456789abcdefghjkmnpqrstvwxyz' "$NGINX_SUBSCRIPTION_CONF" 2>/dev/null; then
            STATE_COMMIT_FAIL_ONCE=0
            return 1
        fi
        command mv "$@"
    }
    reading() { printf -v "$2" '%s' y; }
    generate_subscription_token() { printf '%s\n' '0123456789abcdefghjkmnpqrstvwxyz'; }
    detect_argo_tunnel_mode() { printf '%s\n' local; }
    get_subscription_host() { printf '%s\n' 'subscription.example.test'; }
    build_http_subscription_url() { printf 'http://%s:%s%s\n' "$1" "$2" "$3"; }
    build_https_subscription_url() { printf 'https://%s%s\n' "$1" "$2"; }
    verify_https_subscription() { return 0; }
    print_manual_https_route() { :; }
    apply_local_tunnel_subscription_rule() {
        printf 'mutate:tunnel-add\n' >> "$FRONTEND_LOG"
        return 0
    }
    apply_local_tunnel_subscription_removal() {
        printf 'mutate:tunnel-remove\n' >> "$FRONTEND_LOG"
        return 0
    }
    apply_remote_tunnel_subscription_rule() { return 1; }
    remove_remote_tunnel_subscription_via_api() { return 1; }
    apply_nginx_subscription_config() {
        local port="$1" http_path="$2" https_path="${3:-}" preserve="${4:-start}"
        local candidate="${case_dir}/nginx.candidate"
        printf 'mutate:nginx:%s:%s:%s:%s\n' "$port" "$http_path" "$https_path" "$preserve" >> "$FRONTEND_LOG"
        [ "$APPLY_FAIL" -eq 0 ] || return 1
        render_nginx_subscription_server "$port" "$http_path" "$https_path" 0 > "$candidate" || return 1
        command mv -f -- "$candidate" "$NGINX_SUBSCRIPTION_CONF" || return 1
        case "$preserve" in
            0) ;;
            1) printf '1\n' > "$SERVICE_STATE_FILE" ;;
            start|'') printf '1\n' > "$SERVICE_STATE_FILE" ;;
            *) return 1 ;;
        esac
    }
    nginx_service_is_active() { [ "$(cat "$SERVICE_STATE_FILE")" = 1 ]; }
    start_nginx() { printf 'start-nginx\n' >> "$FRONTEND_LOG"; printf '1\n' > "$SERVICE_STATE_FILE"; }
    restart_nginx() { printf 'restart-nginx\n' >> "$FRONTEND_LOG"; printf '1\n' > "$SERVICE_STATE_FILE"; }
    stop_nginx_checked() { printf 'stop-nginx\n' >> "$FRONTEND_LOG"; printf '0\n' > "$SERVICE_STATE_FILE"; }
    restart_argo() { printf 'restart-argo\n' >> "$FRONTEND_LOG"; }
    nginx() {
        if [ "${1:-}" = -s ] && [ "${2:-}" = reload ]; then
            nginx_service_is_active
        else
            return 0
        fi
    }
    command_exists() { [ "${1:-}" = nginx ]; }
    green() { :; }
    yellow() { :; }
    red() { :; }
    acquire_proxy_transaction_lock_checked() {
        local status=0
        assert_no_pending_durable_transaction "$1" || status=$?
        [ "$status" -eq 0 ] || return "$status"
        printf 'lock\n' >> "$FRONTEND_LOG"
    }
    release_proxy_transaction_lock() { printf 'unlock\n' >> "$FRONTEND_LOG"; }
    durable_transaction_hook() {
        [ -n "$DURABLE_SIGNAL_STAGE" ] && [ "$1" = "$DURABLE_SIGNAL_STAGE" ] || return 0
        kill -s "$DURABLE_SIGNAL_NAME" "$BASHPID"
    }
}

render_http_config() {
    local port="${1:-24000}"
    local token="${2:-11111111111111111111111111111111}"
    local https_path="${3:-}"
    render_nginx_subscription_server "$port" "/${token}" "$https_path" 0 > "$NGINX_SUBSCRIPTION_CONF"
}

test_http_rotate_service_state() {
    local initial
    for initial in 1 0; do
        setup_frontend_fixture "rotate-state-${initial}" "$initial"
        render_http_config
        write_state_file "$subscription_state_file" 0
        _rotate_subscription_token_locked >/dev/null 2>&1 || fail "HTTP-only rotate failed with Nginx state ${initial}" || return 1
        [ "$(cat "$SERVICE_STATE_FILE")" = "$initial" ] || {
            fail "HTTP-only rotate changed Nginx service state ${initial}"; return 1;
        }
        grep -Fq '/0123456789abcdefghjkmnpqrstvwxyz' "$NGINX_SUBSCRIPTION_CONF" || {
            fail 'HTTP-only rotate did not commit the new Nginx path'; return 1;
        }
    done
}

test_http_rotate_state_failure_rolls_back() {
    local initial status before_config before_state
    for initial in 1 0; do
        setup_frontend_fixture "rotate-state-failure-${initial}" "$initial"
        render_http_config
        write_state_file "$subscription_state_file" 0
        before_config="$(sha256sum "$NGINX_SUBSCRIPTION_CONF")"
        before_state="$(sha256sum "$subscription_state_file")"
        STATE_COMMIT_FAIL_ONCE=1
        status=0
        _rotate_subscription_token_locked >/dev/null 2>&1 || status=$?
        [ "$status" -ne 0 ] || { fail 'state commit failure was reported as success'; return 1; }
        [ "$(sha256sum "$NGINX_SUBSCRIPTION_CONF")" = "$before_config" ] || {
            fail 'state commit failure did not restore Nginx config'; return 1;
        }
        [ "$(sha256sum "$subscription_state_file")" = "$before_state" ] || {
            fail 'state commit failure did not restore subscription state'; return 1;
        }
        [ "$(cat "$SERVICE_STATE_FILE")" = "$initial" ] || {
            fail 'state commit failure did not restore Nginx service state'; return 1;
        }
    done
}

prepare_rejection_shape() {
    local shape="$1"
    case "$shape" in
        custom)
            cat > "$NGINX_SUBSCRIPTION_CONF" <<'EOF'
server {
    listen 24000;
    location = /11111111111111111111111111111111 { alias /srv/custom.txt; }
}
EOF
            ;;
        partial)
            printf 'server { listen 24000; }\n' > "$NGINX_SUBSCRIPTION_CONF"
            ;;
        symlink)
            render_nginx_subscription_server 24000 /11111111111111111111111111111111 '' 0 > "${case_dir}/real-nginx.conf"
            ln -s "${case_dir}/real-nginx.conf" "$NGINX_SUBSCRIPTION_CONF"
            ;;
        inconsistent)
            render_http_config
            ;;
        *) return 1 ;;
    esac
    write_state_file "$subscription_state_file" 1 \
        11111111111111111111111111111111 /sub/11111111111111111111111111111111
}

test_frontend_fail_close_matrix() {
    local operation shape status config_hash state_hash link_target
    for operation in configure disable; do
        for shape in custom partial symlink inconsistent; do
            setup_frontend_fixture "reject-${operation}-${shape}" 1
            prepare_rejection_shape "$shape" || return 1
            config_hash="$(sha256sum "$NGINX_SUBSCRIPTION_CONF")"
            state_hash="$(sha256sum "$subscription_state_file")"
            link_target="$(readlink "$NGINX_SUBSCRIPTION_CONF" 2>/dev/null || true)"
            status=0
            if [ "$operation" = configure ]; then
                _configure_cf_https_subscription_locked 1 >/dev/null 2>&1 || status=$?
            else
                _disable_cf_https_subscription_locked >/dev/null 2>&1 || status=$?
            fi
            [ "$status" -ne 0 ] || {
                fail "${operation} accepted ${shape} config/state"; return 1;
            }
            [ "$(sha256sum "$NGINX_SUBSCRIPTION_CONF")" = "$config_hash" ] || {
                fail "${operation}/${shape} mutated Nginx"; return 1;
            }
            [ "$(sha256sum "$subscription_state_file")" = "$state_hash" ] || {
                fail "${operation}/${shape} mutated state"; return 1;
            }
            [ "$(readlink "$NGINX_SUBSCRIPTION_CONF" 2>/dev/null || true)" = "$link_target" ] || {
                fail "${operation}/${shape} replaced a symlink"; return 1;
            }
            if grep -Eq '^(mutate:|restart-|start-|stop-)' "$FRONTEND_LOG"; then
                fail "${operation}/${shape} performed a runtime mutation"; return 1
            fi
        done
    done
}

set_remote_caller_inputs() {
    REMOTE_CALLER_INPUTS=("$@")
    REMOTE_CALLER_INPUT_INDEX=0
    reading() {
        local destination="${2:-}"

        [ -n "$destination" ] || return 1
        [ "$REMOTE_CALLER_INPUT_INDEX" -lt "${#REMOTE_CALLER_INPUTS[@]}" ] || return 1
        printf -v "$destination" '%s' \
            "${REMOTE_CALLER_INPUTS[$REMOTE_CALLER_INPUT_INDEX]}"
        REMOTE_CALLER_INPUT_INDEX=$((REMOTE_CALLER_INPUT_INDEX + 1))
    }
}

assert_remote_safe_rollback() {
    local operation="$1" status="$2" before_config="$3" before_state="$4"
    local registry="${conf_dir}/.durable-transaction.pending"

    [ "$status" -eq 1 ] || {
        fail "${operation} API helper safe failure returned ${status}, expected 1"; return 1;
    }
    [ "$(sha256sum "$NGINX_SUBSCRIPTION_CONF")" = "$before_config" ] || {
        fail "${operation} API helper failure did not restore Nginx"; return 1;
    }
    [ "$(sha256sum "$subscription_state_file")" = "$before_state" ] || {
        fail "${operation} API helper failure did not restore subscription state"; return 1;
    }
    [ "$(cat "$SERVICE_STATE_FILE")" = 1 ] || {
        fail "${operation} API helper failure did not restore active Nginx"; return 1;
    }
    [ ! -e "$registry" ] || {
        fail "${operation} API helper safe rollback left a pending registry"; return 1;
    }
    if compgen -G "${conf_dir}/.subscription-frontend.*" >/dev/null; then
        fail "${operation} API helper safe rollback left snapshot evidence"; return 1
    fi
    [ "$REMOTE_HELPER_CALLS" -eq 1 ] || {
        fail "${operation} API path did not call exactly one remote helper"; return 1;
    }
    grep -Fq 'unlock' "$FRONTEND_LOG" || {
        fail "${operation} caller did not release its proxy lock"; return 1;
    }
}

assert_remote_manual_unknown() {
    local operation="$1" status="$2"
    local registry="${conf_dir}/.durable-transaction.pending" evidence=''

    [ "$status" -eq 2 ] || {
        fail "${operation} unconfirmed manual change returned ${status}, expected 2"; return 1;
    }
    [ -f "$registry" ] && [ ! -L "$registry" ] || {
        fail "${operation} unconfirmed manual change did not preserve registry"; return 1;
    }
    IFS= read -r evidence < "$registry" || evidence=''
    [ -d "$evidence" ] && [ ! -L "$evidence" ] || {
        fail "${operation} registry does not reference preserved evidence"; return 1;
    }
    [ -f "${evidence}/manifest" ] && \
        grep -Fqx 'stage=publishing' "${evidence}/manifest" || {
        fail "${operation} manual unknown evidence is not at publishing"; return 1;
    }
    [ "$REMOTE_HELPER_CALLS" -eq 0 ] || {
        fail "${operation} manual path unexpectedly called a remote API helper"; return 1;
    }
    grep -Fq 'unlock' "$FRONTEND_LOG" || {
        fail "${operation} caller did not release its proxy lock"; return 1;
    }
}

run_remote_frontend_caller_case() {
    local operation="$1" path_kind="$2"
    local status=0 before_config before_state
    local token=11111111111111111111111111111111
    local https_path="/sub/${token}"

    setup_frontend_fixture "remote-${operation}-${path_kind}" 1
    detect_argo_tunnel_mode() { printf '%s\n' remote; }
    REMOTE_HELPER_CALLS=0
    apply_remote_tunnel_subscription_rule() {
        REMOTE_HELPER_CALLS=$((REMOTE_HELPER_CALLS + 1))
        return 1
    }
    remove_remote_tunnel_subscription_via_api() {
        REMOTE_HELPER_CALLS=$((REMOTE_HELPER_CALLS + 1))
        return 1
    }

    case "$operation" in
        configure)
            render_http_config 24000 "$token"
            write_state_file "$subscription_state_file" 0 "$token"
            if [ "$path_kind" = api-safe-failure ]; then
                set_remote_caller_inputs 1 node.example.test 1
            else
                set_remote_caller_inputs 1 node.example.test 2 n
            fi
            before_config="$(sha256sum "$NGINX_SUBSCRIPTION_CONF")"
            before_state="$(sha256sum "$subscription_state_file")"
            configure_cf_https_subscription >/dev/null 2>&1 || status=$?
            ;;
        disable)
            render_http_config 24000 "$token" "$https_path"
            write_state_file "$subscription_state_file" 1 "$token" "$https_path" remote
            if [ "$path_kind" = api-safe-failure ]; then
                set_remote_caller_inputs 1
            else
                set_remote_caller_inputs 2 n
            fi
            before_config="$(sha256sum "$NGINX_SUBSCRIPTION_CONF")"
            before_state="$(sha256sum "$subscription_state_file")"
            disable_cf_https_subscription >/dev/null 2>&1 || status=$?
            ;;
        *) return 1 ;;
    esac

    if [ "$path_kind" = api-safe-failure ]; then
        assert_remote_safe_rollback "$operation" "$status" \
            "$before_config" "$before_state"
    else
        assert_remote_manual_unknown "$operation" "$status"
    fi
}

test_remote_frontend_caller_tristate() {
    run_remote_frontend_caller_case configure api-safe-failure || return 1
    run_remote_frontend_caller_case disable api-safe-failure || return 1
    run_remote_frontend_caller_case configure manual-unknown || return 1
    run_remote_frontend_caller_case disable manual-unknown || return 1
}

run_rotate_signal_case() {
    local stage="$1" signal_name="$2" expected_status="$3"
    local status=0 before_config before_state registry evidence

    setup_frontend_fixture "rotate-signal-${stage}-${signal_name}" 0
    render_http_config
    write_state_file "$subscription_state_file" 0
    before_config="$(sha256sum "$NGINX_SUBSCRIPTION_CONF")"
    before_state="$(sha256sum "$subscription_state_file")"
    DURABLE_SIGNAL_STAGE="$stage"
    DURABLE_SIGNAL_NAME="$signal_name"
    ( trap - EXIT; rotate_subscription_token >/dev/null 2>&1 ) || status=$?
    [ "$status" -eq "$expected_status" ] || {
        fail "${stage}/${signal_name} returned ${status}, expected ${expected_status}"; return 1;
    }
    registry="${conf_dir}/.durable-transaction.pending"
    if [ "$stage" = config-mutated ]; then
        [ "$(sha256sum "$NGINX_SUBSCRIPTION_CONF")" = "$before_config" ] || {
            fail "${signal_name} at config-mutated did not restore Nginx"; return 1;
        }
        [ "$(sha256sum "$subscription_state_file")" = "$before_state" ] || {
            fail "${signal_name} at config-mutated did not restore state"; return 1;
        }
        [ "$(cat "$SERVICE_STATE_FILE")" = 0 ] || {
            fail "${signal_name} at config-mutated started inactive Nginx"; return 1;
        }
        [ ! -e "$registry" ] || { fail 'safe signal rollback left a pending registry'; return 1; }
    else
        [ -f "$registry" ] && [ ! -L "$registry" ] || {
            fail "${signal_name} at publishing did not preserve the unified registry"; return 1;
        }
        IFS= read -r evidence < "$registry" || evidence=''
        [ -f "${evidence}/manifest" ] && grep -Fqx 'stage=publishing' "${evidence}/manifest" || {
            fail 'publishing recovery evidence is missing or has the wrong stage'; return 1;
        }
        status=0
        acquire_proxy_transaction_lock_checked "$conf_dir" next-transaction >/dev/null 2>&1 || status=$?
        [ "$status" -eq 2 ] || {
            fail "pending publishing registry allowed a new transaction (${status})"; return 1;
        }
    fi
}

test_rotate_signal_boundaries() {
    run_rotate_signal_case config-mutated TERM 143 || return 1
    run_rotate_signal_case config-mutated HUP 129 || return 1
    run_rotate_signal_case publishing TERM 2 || return 1
    run_rotate_signal_case publishing HUP 2 || return 1
}

setup_start_fixture() {
    local name="$1" signal_mode="$2"
    setup_frontend_fixture "$name" 0
    command rm -f -- "$NGINX_SUBSCRIPTION_CONF" "$subscription_state_file"
    START_SIGNAL_MODE="$signal_mode"
    START_INPUT_PORT=25000
    FIREWALL_LAST_ADDED_RECORDS=()

    get_subscription_host() { printf '%s\n' subscription.example.test; }
    reading() { printf -v "$2" '%s' "$START_INPUT_PORT"; }
    validate_port_value() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
    configured_inbound_port_conflict_exists() { return 1; }
    port_is_listening() { return 1; }
    allow_port() {
        local registry="${conf_dir}/.durable-transaction.pending"
        [ -f "$registry" ] && [ ! -L "$registry" ] || {
            printf 'arm-missing-before-allow\n' >> "$FRONTEND_LOG"
            return 97
        }
        printf 'armed-before-allow\n' >> "$FRONTEND_LOG"
        case "$START_SIGNAL_MODE" in
            KILL) kill -KILL "$BASHPID" ;;
            TERM) kill -TERM "$BASHPID" ;;
            *) return 98 ;;
        esac
    }
    remove_owned_firewall_records_exact() { printf 'remove-firewall\n' >> "$FRONTEND_LOG"; }
    apply_nginx_subscription_config() {
        render_nginx_subscription_server "$1" "$2" "${3:-}" 0 > "$NGINX_SUBSCRIPTION_CONF"
        printf '1\n' > "$SERVICE_STATE_FILE"
    }
}

run_start_signal_case() {
    local signal_mode="$1" expected_status="$2"
    local status=0 registry evidence

    setup_start_fixture "start-${signal_mode}" "$signal_mode"
    ( trap - EXIT; start_subscription_service_transaction >/dev/null 2>&1 ) || status=$?
    [ "$status" -eq "$expected_status" ] || {
        fail "start-create ${signal_mode} returned ${status}, expected ${expected_status}"; return 1;
    }
    grep -Fqx 'armed-before-allow' "$FRONTEND_LOG" || {
        fail "start-create ${signal_mode} reached allow_port before durable arm"; return 1;
    }
    registry="${conf_dir}/.durable-transaction.pending"
    [ -f "$registry" ] && [ ! -L "$registry" ] || {
        fail "start-create ${signal_mode} did not preserve its registry"; return 1;
    }
    IFS= read -r evidence < "$registry" || evidence=''
    [ -f "${evidence}/manifest" ] || {
        fail "start-create ${signal_mode} registry has no durable manifest"; return 1;
    }
    status=0
    acquire_proxy_transaction_lock_checked "$conf_dir" next-transaction >/dev/null 2>&1 || status=$?
    [ "$status" -eq 2 ] || {
        fail "start-create ${signal_mode} evidence allowed the next transaction (${status})"; return 1;
    }
}

test_start_arm_and_registry() {
    run_start_signal_case KILL 137 || return 1
    run_start_signal_case TERM 2 || return 1
}

test_start_rejects_prompt_window_replacement() {
    local status=0 foreign_config foreign_state

    setup_frontend_fixture start-create-toctou 0
    command rm -f -- "$NGINX_SUBSCRIPTION_CONF" "$subscription_state_file"
    foreign_config='server { listen 31999; # foreign-create }'
    foreign_state='SUB_TOKEN=foreign-create-state'
    get_subscription_host() {
        printf '%s\n' "$foreign_config" > "$NGINX_SUBSCRIPTION_CONF"
        printf '%s\n' "$foreign_state" > "$subscription_state_file"
        printf '%s\n' subscription.example.test
    }
    reading() { printf -v "$2" '%s' 25000; }
    validate_port_value() { return 0; }
    configured_inbound_port_conflict_exists() { return 1; }
    port_is_listening() { return 1; }
    allow_port() {
        printf 'unexpected-allow\n' >> "$FRONTEND_LOG"
        FIREWALL_LAST_ADDED_RECORDS=("raw|4|${1%/*}|tcp")
    }

    _start_subscription_service_locked >/dev/null 2>&1 || status=$?
    [ "$status" -eq 2 ] || {
        fail "start-create prompt-window replacement returned ${status}, expected 2"; return 1;
    }
    [ "$(cat "$NGINX_SUBSCRIPTION_CONF")" = "$foreign_config" ] || {
        fail 'start-create overwrote a config that appeared during prompting'; return 1;
    }
    [ "$(cat "$subscription_state_file")" = "$foreign_state" ] || {
        fail 'start-create overwrote state that appeared during prompting'; return 1;
    }
    ! grep -Fq 'unexpected-allow' "$FRONTEND_LOG" || {
        fail 'start-create opened the firewall after its absent baseline changed'; return 1;
    }

    setup_frontend_fixture start-existing-toctou 0
    render_nginx_subscription_server 25000 \
        '/11111111111111111111111111111111' '' 0 > "$NGINX_SUBSCRIPTION_CONF"
    write_state_file "$subscription_state_file" 0
    foreign_config='server { listen 31998; # foreign-existing }'
    get_subscription_host() {
        printf '%s\n' "$foreign_config" > "$NGINX_SUBSCRIPTION_CONF"
        printf '%s\n' subscription.example.test
    }
    status=0
    _start_subscription_service_locked >/dev/null 2>&1 || status=$?
    [ "$status" -eq 2 ] || {
        fail "start-existing prompt-window replacement returned ${status}, expected 2"; return 1;
    }
    [ "$(cat "$NGINX_SUBSCRIPTION_CONF")" = "$foreign_config" ] || {
        fail 'start-existing overwrote a config changed during host discovery'; return 1;
    }
    [ "$(cat "$SERVICE_STATE_FILE")" = 0 ] || {
        fail 'start-existing started Nginx after its baseline changed'; return 1;
    }
}

run_case 'HTTP-only rotate preserves active/inactive Nginx state' test_http_rotate_service_state
run_case 'HTTP-only rotate restores Nginx and state after state commit failure' test_http_rotate_state_failure_rolls_back
run_case 'configure/disable reject unmanaged or inconsistent frontend state without mutation' test_frontend_fail_close_matrix
run_case 'configure/disable callers distinguish remote safe rollback from manual unknown' test_remote_frontend_caller_tristate
run_case 'TERM/HUP rollback or preserve one durable registry at the correct boundary' test_rotate_signal_boundaries
run_case 'start-create arms before allow_port and KILL/TERM block the next transaction' test_start_arm_and_registry
run_case 'start rejects config/state replacement during host or port prompting' test_start_rejects_prompt_window_replacement

if [ "$failures" -ne 0 ]; then
    printf 'Subscription frontend transaction harness: %d RED group(s).\n' "$failures" >&2
    exit 1
fi

printf 'Subscription frontend transaction tests passed.\n'
