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

conf_dir=/tmp/proxy-release-contract/conf
route_file="${conf_dir}/route.json"
outbound_file="${conf_dir}/outbounds.json"
MOCK_LOCKED_STATUS=0
MOCK_RELEASE_CALLS=0

acquire_proxy_transaction_lock_checked() { return 0; }
acquire_public_port_change_lock() { return 0; }
release_proxy_transaction_lock() {
    MOCK_RELEASE_CALLS=$((MOCK_RELEASE_CALLS + 1))
    return 2
}
release_public_port_change_lock() {
    MOCK_RELEASE_CALLS=$((MOCK_RELEASE_CALLS + 1))
    return 2
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
reset_proxy_transaction_state() { :; }
install_proxy_transaction_traps() { :; }
restore_proxy_transaction_traps() { :; }
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

printf 'Proxy transaction release tests passed.\n'
