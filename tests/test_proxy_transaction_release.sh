#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

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
    [ -n "$function_source" ] || fail "$1 is not implemented"
    source <(printf '%s\n' "$function_source")
}

load_optional_function() {
    local function_source

    function_source="$(extract_function "$1")"
    [ -z "$function_source" ] || source <(printf '%s\n' "$function_source")
}

assert_status() {
    local expected="$1" actual=0
    shift

    set +e
    "$@" >/dev/null 2>&1
    actual=$?
    set -e
    [ "$actual" -eq "$expected" ] || \
        fail "expected rc ${expected}, got ${actual}: $*"
}

load_optional_function finish_transaction_release
for function_name in \
    enable_hy2_port_hopping_transaction \
    disable_hy2_port_hopping_transaction \
    change_public_inbound_port_transaction \
    configure_cf_https_subscription \
    disable_cf_https_subscription \
    change_subscription_port_transaction \
    rotate_subscription_token \
    stop_subscription_service_transaction \
    start_subscription_service_transaction \
    restart_subscription_service_transaction \
    transition_to_quick_argo \
    transition_to_fixed_argo \
    apply_proxy_config_transaction \
    add_extra_protocol_transaction \
    remove_extra_protocol_transaction; do
    load_function "$function_name"
done

for function_name in \
    apply_node_change_transaction \
    durable_transaction_trap_handler \
    proxy_transaction_trap_handler; do
    load_function "$function_name"
done

conf_dir=/tmp/proxy-release-contract/conf
route_file="${conf_dir}/route.json"
outbound_file="${conf_dir}/outbounds.json"
MOCK_LOCKED_STATUS=0
MOCK_RELEASE_CALLS=0
MOCK_RELEASE_STATUS=2

acquire_proxy_transaction_lock_checked() { return 0; }
acquire_public_port_change_lock() { return 0; }
release_proxy_transaction_lock() {
    MOCK_RELEASE_CALLS=$((MOCK_RELEASE_CALLS + 1))
    if [ -n "${MOCK_RELEASE_LOG:-}" ]; then
        printf '%s\n' release >> "$MOCK_RELEASE_LOG"
    fi
    if [ -n "${MOCK_NODE_TRAP_ORDER_LOG:-}" ]; then
        if trap -p EXIT | grep -Fq _node_change_interrupt_handler; then
            printf '%s\n' release-before-restore >> "$MOCK_NODE_TRAP_ORDER_LOG"
        else
            printf '%s\n' release-after-restore >> "$MOCK_NODE_TRAP_ORDER_LOG"
        fi
    fi
    if [ -n "${TRAP_ACTION_LOG:-}" ]; then
        printf '%s\n' release >> "$TRAP_ACTION_LOG"
    fi
    return "$MOCK_RELEASE_STATUS"
}
release_public_port_change_lock() {
    MOCK_RELEASE_CALLS=$((MOCK_RELEASE_CALLS + 1))
    return "$MOCK_RELEASE_STATUS"
}
mock_locked_callback() { return "$MOCK_LOCKED_STATUS"; }
_enable_hy2_port_hopping_transaction_locked() { mock_locked_callback; }
_disable_hy2_port_hopping_transaction_locked() { mock_locked_callback; }
_change_public_inbound_port_transaction_locked() { mock_locked_callback; }
_configure_cf_https_subscription_locked() { mock_locked_callback; }
_disable_cf_https_subscription_locked() { mock_locked_callback; }
_change_subscription_port_transaction_locked() { mock_locked_callback; }
_rotate_subscription_token_locked() { mock_locked_callback; }
_stop_subscription_service_locked() { mock_locked_callback; }
_start_subscription_service_locked() { mock_locked_callback; }
_restart_subscription_service_locked() { mock_locked_callback; }
_transition_to_quick_argo_locked() { mock_locked_callback; }
_transition_to_fixed_argo_locked() { mock_locked_callback; }
_apply_proxy_config_transaction_locked() { mock_locked_callback; }
_add_extra_protocol_transaction_locked() { mock_locked_callback; }
_remove_extra_protocol_transaction_locked() { mock_locked_callback; }
reset_proxy_transaction_state() {
    [ -z "${TRAP_ACTION_LOG:-}" ] || printf '%s\n' proxy-reset >> "$TRAP_ACTION_LOG"
}
install_proxy_transaction_traps() { :; }
restore_proxy_transaction_traps() {
    [ -z "${TRAP_ACTION_LOG:-}" ] || printf '%s\n' proxy-restore >> "$TRAP_ACTION_LOG"
}
singbox_service_is_active() { return 1; }

invoke_wrapper() {
    case "$1" in
        enable_hy2_port_hopping_transaction) enable_hy2_port_hopping_transaction 50000 50100 ;;
        disable_hy2_port_hopping_transaction) disable_hy2_port_hopping_transaction ;;
        change_public_inbound_port_transaction) change_public_inbound_port_transaction config reality 23000 tcp ;;
        configure_cf_https_subscription) configure_cf_https_subscription ;;
        disable_cf_https_subscription) disable_cf_https_subscription ;;
        change_subscription_port_transaction) change_subscription_port_transaction 23001 /token '' ;;
        rotate_subscription_token) rotate_subscription_token ;;
        stop_subscription_service_transaction) stop_subscription_service_transaction ;;
        start_subscription_service_transaction) start_subscription_service_transaction ;;
        restart_subscription_service_transaction) restart_subscription_service_transaction ;;
        transition_to_quick_argo) transition_to_quick_argo ;;
        transition_to_fixed_argo) transition_to_fixed_argo ;;
        apply_proxy_config_transaction) apply_proxy_config_transaction filter filter ;;
        add_extra_protocol_transaction) add_extra_protocol_transaction ;;
        remove_extra_protocol_transaction) remove_extra_protocol_transaction ;;
        *) return 99 ;;
    esac
}

for wrapper in \
    enable_hy2_port_hopping_transaction \
    disable_hy2_port_hopping_transaction \
    change_public_inbound_port_transaction \
    configure_cf_https_subscription \
    disable_cf_https_subscription \
    change_subscription_port_transaction \
    rotate_subscription_token \
    stop_subscription_service_transaction \
    start_subscription_service_transaction \
    restart_subscription_service_transaction \
    transition_to_quick_argo \
    transition_to_fixed_argo \
    apply_proxy_config_transaction \
    add_extra_protocol_transaction \
    remove_extra_protocol_transaction; do
    for MOCK_LOCKED_STATUS in 0 1; do
        MOCK_RELEASE_CALLS=0
        assert_status 2 invoke_wrapper "$wrapper"
        [ "$MOCK_RELEASE_CALLS" -eq 1 ] || \
            fail "${wrapper} attempted ${MOCK_RELEASE_CALLS} releases, expected 1"
    done
done

for operation_status in 0 1 2 3; do
    for MOCK_RELEASE_STATUS in 0 2; do
        MOCK_RELEASE_CALLS=0
        expected_status="$operation_status"
        [ "$MOCK_RELEASE_STATUS" -eq 0 ] || expected_status=2
        assert_status "$expected_status" \
            finish_transaction_release "$operation_status" release_proxy_transaction_lock
        [ "$MOCK_RELEASE_CALLS" -eq 1 ] || \
            fail "finish helper attempted ${MOCK_RELEASE_CALLS} releases, expected 1"
    done
done

test_tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_tmp_dir"' EXIT

red() { :; }
yellow() { :; }
acquire_proxy_transaction_lock() { return 0; }
node_change_snapshot_path() { return 0; }
node_change_restore_path() {
    [ -z "${NODE_RESTORE_LOG:-}" ] || printf '%s\n' restore >> "$NODE_RESTORE_LOG"
    return "${NODE_RESTORE_STATUS:-0}"
}
validate_singbox_config() { return 0; }
publish_node_change_subscription() { return "${NODE_PUBLISH_STATUS:-0}"; }
cleanup_durable_transaction_registry() {
    [ -z "${TRAP_ACTION_LOG:-}" ] || printf '%s\n' durable-cleanup >> "$TRAP_ACTION_LOG"
    return "${DURABLE_CLEANUP_STATUS:-0}"
}
restore_durable_transaction_traps() {
    [ -z "${TRAP_ACTION_LOG:-}" ] || printf '%s\n' durable-restore >> "$TRAP_ACTION_LOG"
}
reset_durable_transaction_state() {
    [ -z "${TRAP_ACTION_LOG:-}" ] || printf '%s\n' durable-reset >> "$TRAP_ACTION_LOG"
}
write_durable_transaction_manifest() {
    [ -z "${TRAP_ACTION_LOG:-}" ] || printf '%s\n' durable-manifest >> "$TRAP_ACTION_LOG"
}
cleanup_proxy_transaction_artifacts() {
    [ -z "${TRAP_ACTION_LOG:-}" ] || printf '%s\n' proxy-cleanup >> "$TRAP_ACTION_LOG"
    return "${PROXY_CLEANUP_STATUS:-0}"
}
restore_proxy_config_transaction() {
    [ -z "${TRAP_ACTION_LOG:-}" ] || printf '%s\n' proxy-rollback >> "$TRAP_ACTION_LOG"
    return "${PROXY_RESTORE_STATUS:-0}"
}
report_proxy_transaction_fatal() { :; }

setup_node_fixture() {
    work_dir="${test_tmp_dir}/$1"
    conf_dir="${work_dir}/conf"
    client_dir="${work_dir}/url.txt"
    install_env_file="${work_dir}/install.env"
    ARGO_SYSTEMD_SERVICE_FILE="${work_dir}/argo-systemd.service"
    ARGO_OPENRC_SERVICE_FILE="${work_dir}/argo-openrc"
    mkdir -p "$conf_dir"
    printf '%s\n' original-client > "$client_dir"
    printf '%s\n' 'PORT=23000' > "$install_env_file"
    MOCK_RELEASE_CALLS=0
    MOCK_RELEASE_LOG="${work_dir}/release.log"
    MOCK_NODE_TRAP_ORDER_LOG="${work_dir}/release-order.log"
    NODE_RESTORE_LOG="${work_dir}/restore.log"
    NODE_RESTORE_STATUS=0
    NODE_PUBLISH_STATUS=0
    TRAP_ACTION_LOG=''
}

assert_single_node_release() {
    local release_count=0

    if [ -f "$MOCK_RELEASE_LOG" ]; then
        release_count=$(wc -l < "$MOCK_RELEASE_LOG")
    fi
    [ "$release_count" -eq 1 ] || \
        fail "node transaction attempted ${release_count} releases, expected 1"
}

assert_node_release_before_trap_restore() {
    local release_order=''

    [ -f "$MOCK_NODE_TRAP_ORDER_LOG" ] && IFS= read -r release_order < "$MOCK_NODE_TRAP_ORDER_LOG"
    [ "$release_order" = release-before-restore ] || \
        fail "node lock release happened after the previous EXIT trap was restored"
}

assert_node_restore_count() {
    local expected="$1" restore_count=0

    if [ -f "$NODE_RESTORE_LOG" ]; then
        restore_count=$(wc -l < "$NODE_RESTORE_LOG")
    fi
    [ "$restore_count" -eq "$expected" ] || \
        fail "node transaction performed ${restore_count} restores, expected ${expected}"
}

assert_node_recovery_count() {
    local expected="$1"
    local -a recovery_paths=()

    shopt -s nullglob
    recovery_paths=("${work_dir}"/.node-change-recovery.*)
    shopt -u nullglob
    [ "${#recovery_paths[@]}" -eq "$expected" ] || \
        fail "node transaction retained ${#recovery_paths[@]} recoveries, expected ${expected}"
}

node_success_mutation() {
    printf '%s\n' changed-client > "$1"
}

node_noop_mutation() {
    NODE_CHANGE_NOOP=1
}

node_interrupting_mutation() {
    kill -TERM "$BASHPID"
}

node_failure_mutation() { return 1; }
node_fatal_mutation() { return 2; }

invoke_node_interrupt() (
    trap - EXIT
    apply_node_change_transaction node_interrupting_mutation 0 '' ''
)

for MOCK_RELEASE_STATUS in 0 2; do
    setup_node_fixture "normal-${MOCK_RELEASE_STATUS}"
    if [ "$MOCK_RELEASE_STATUS" -eq 0 ]; then
        assert_status 0 apply_node_change_transaction node_success_mutation 0 '' ''
    else
        assert_status 2 apply_node_change_transaction node_success_mutation 0 '' ''
    fi
    assert_single_node_release
    assert_node_release_before_trap_restore
    assert_node_restore_count 0
    assert_node_recovery_count 0

    setup_node_fixture "noop-${MOCK_RELEASE_STATUS}"
    if [ "$MOCK_RELEASE_STATUS" -eq 0 ]; then
        assert_status 0 apply_node_change_transaction node_noop_mutation 0 '' ''
    else
        assert_status 2 apply_node_change_transaction node_noop_mutation 0 '' ''
    fi
    assert_single_node_release
    assert_node_release_before_trap_restore
    assert_node_restore_count 0
    assert_node_recovery_count 0

    setup_node_fixture "interrupt-${MOCK_RELEASE_STATUS}"
    MOCK_NODE_TRAP_ORDER_LOG=''
    if [ "$MOCK_RELEASE_STATUS" -eq 0 ]; then
        assert_status 143 invoke_node_interrupt
    else
        assert_status 2 invoke_node_interrupt
    fi
    assert_single_node_release
    assert_node_restore_count 5
    assert_node_recovery_count 1

    setup_node_fixture "rollback-${MOCK_RELEASE_STATUS}"
    expected_status=1
    [ "$MOCK_RELEASE_STATUS" -eq 0 ] || expected_status=2
    assert_status "$expected_status" \
        apply_node_change_transaction node_failure_mutation 0 '' ''
    assert_single_node_release
    assert_node_release_before_trap_restore
    assert_node_restore_count 5
    assert_node_recovery_count 0

    setup_node_fixture "fatal-${MOCK_RELEASE_STATUS}"
    assert_status 2 apply_node_change_transaction node_fatal_mutation 0 '' ''
    assert_single_node_release
    assert_node_release_before_trap_restore
    assert_node_restore_count 5
    assert_node_recovery_count 1

    setup_node_fixture "committed-${MOCK_RELEASE_STATUS}"
    NODE_PUBLISH_STATUS=3
    expected_status=3
    [ "$MOCK_RELEASE_STATUS" -eq 0 ] || expected_status=2
    assert_status "$expected_status" \
        apply_node_change_transaction node_success_mutation 0 '' ''
    assert_single_node_release
    assert_node_release_before_trap_restore
    assert_node_restore_count 0
    assert_node_recovery_count 0
done

durable_test_rollback() {
    [ -z "${TRAP_ACTION_LOG:-}" ] || printf '%s\n' durable-rollback >> "$TRAP_ACTION_LOG"
    return 0
}

invoke_durable_trap() (
    local event="$1" original_status="$2" stage="${3:-precommit}"
    local recovery_dir

    recovery_dir="${test_tmp_dir}/durable-${event}-${original_status}-${stage}-${MOCK_RELEASE_STATUS}"

    trap - HUP INT TERM EXIT
    rm -rf -- "$recovery_dir"
    mkdir -p "$recovery_dir"
    DURABLE_TX_ACTIVE=1
    DURABLE_TX_HANDLING=0
    DURABLE_TX_STAGE="$stage"
    DURABLE_TX_RECOVERY_DIR="$recovery_dir"
    DURABLE_TX_RECOVERY_VAR=DURABLE_TEST_RECOVERY
    DURABLE_TX_ROLLBACK_CALLBACK=durable_test_rollback
    DURABLE_TX_ROLLBACK_ARGS=()
    DURABLE_TEST_RECOVERY=''
    durable_transaction_trap_handler "$event" "$original_status"
)

invoke_proxy_trap() (
    local event="$1" original_status="$2" stage="${3:-locked}"

    trap - INT TERM EXIT
    PROXY_TX_STAGE="$stage"
    proxy_transaction_trap_handler "$event" "$original_status"
)

setup_trap_action_log() {
    TRAP_ACTION_LOG="${test_tmp_dir}/$1.actions"
    : > "$TRAP_ACTION_LOG"
    MOCK_RELEASE_LOG=''
    MOCK_NODE_TRAP_ORDER_LOG=''
    DURABLE_CLEANUP_STATUS=0
    PROXY_CLEANUP_STATUS=0
    PROXY_RESTORE_STATUS=0
}

assert_trap_actions() {
    local expected="$1" actual='' release_count=0

    if [ -f "$TRAP_ACTION_LOG" ]; then
        actual=$(paste -sd, -- "$TRAP_ACTION_LOG")
        release_count=$(grep -c '^release$' "$TRAP_ACTION_LOG" || true)
    fi
    [ "$actual" = "$expected" ] || \
        fail "trap actions were '${actual}', expected '${expected}'"
    [ "$release_count" -eq 1 ] || \
        fail "trap attempted ${release_count} releases, expected 1"
}

for MOCK_RELEASE_STATUS in 0 2; do
    setup_trap_action_log "durable-exit-${MOCK_RELEASE_STATUS}"
    if [ "$MOCK_RELEASE_STATUS" -eq 0 ]; then
        assert_status 0 invoke_durable_trap EXIT 0
    else
        assert_status 2 invoke_durable_trap EXIT 0
    fi
    assert_trap_actions durable-rollback,durable-cleanup,release,durable-restore,durable-reset
    [ ! -e "${test_tmp_dir}/durable-EXIT-0-precommit-${MOCK_RELEASE_STATUS}" ] || \
        fail 'durable precommit recovery survived a complete rollback'

    setup_trap_action_log "durable-term-${MOCK_RELEASE_STATUS}"
    if [ "$MOCK_RELEASE_STATUS" -eq 0 ]; then
        assert_status 143 invoke_durable_trap TERM 143
    else
        assert_status 2 invoke_durable_trap TERM 143
    fi
    assert_trap_actions durable-rollback,durable-cleanup,release,durable-restore,durable-reset

    setup_trap_action_log "durable-committed-${MOCK_RELEASE_STATUS}"
    if [ "$MOCK_RELEASE_STATUS" -eq 0 ]; then
        assert_status 3 invoke_durable_trap EXIT 0 committed
    else
        assert_status 2 invoke_durable_trap EXIT 0 committed
    fi
    assert_trap_actions durable-manifest,release,durable-restore,durable-reset
    [ -d "${test_tmp_dir}/durable-EXIT-0-committed-${MOCK_RELEASE_STATUS}" ] || \
        fail 'durable committed recovery evidence was removed during release'

    setup_trap_action_log "proxy-exit-${MOCK_RELEASE_STATUS}"
    if [ "$MOCK_RELEASE_STATUS" -eq 0 ]; then
        assert_status 0 invoke_proxy_trap EXIT 0
    else
        assert_status 2 invoke_proxy_trap EXIT 0
    fi
    assert_trap_actions proxy-cleanup,release,proxy-reset,proxy-restore

    setup_trap_action_log "proxy-term-${MOCK_RELEASE_STATUS}"
    if [ "$MOCK_RELEASE_STATUS" -eq 0 ]; then
        assert_status 143 invoke_proxy_trap TERM 143 commit-in-progress
    else
        assert_status 2 invoke_proxy_trap TERM 143 commit-in-progress
    fi
    assert_trap_actions proxy-rollback,proxy-cleanup,release,proxy-reset,proxy-restore
done

if extract_function apply_node_change_transaction | \
   grep -Eq '^[[:space:]]+release_proxy_transaction_lock([[:space:]]|$)'; then
    fail 'apply_node_change_transaction retains a direct lock release path'
fi

printf 'Proxy transaction release tests passed.\n'
