#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

load_function() {
    local name="$1" source_text
    source_text="$(extract_function "$name")"
    [ -n "$source_text" ] || fail "${name} is not implemented"
    source <(printf '%s\n' "$source_text")
}

assert_ok() {
    "$@" >/dev/null 2>&1 || {
        [ -z "${CALL_LOG:-}" ] || [ ! -f "$CALL_LOG" ] || tail -n 30 "$CALL_LOG" >&2
        fail "expected success: $*"
    }
}

assert_fail() {
    if "$@" >/dev/null 2>&1; then
        fail "expected failure: $*"
    fi
}

assert_status() {
    local expected="$1"
    shift
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    [ "$actual" -eq "$expected" ] || fail "expected status ${expected}, got ${actual}: $*"
}

assert_contains() {
    local needle="$1" file="$2" message="$3"
    grep -Fq -- "$needle" "$file" || fail "$message"
}

assert_not_contains() {
    local needle="$1" file="$2" message="$3"
    if grep -Fq -- "$needle" "$file"; then
        fail "$message"
    fi
}

for name in \
    validate_port_value \
    atomic_write_secret_file \
    acquire_firewall_lock \
    release_firewall_lock \
    select_firewall_backend \
    read_firewall_state \
    write_firewall_state_records \
    firewall_state_has_record \
    ufw_is_active \
    firewalld_is_active \
    ufw_port_is_open \
    firewall_record_is_live \
    raw_port_is_open \
    raw_input_policy_is_accept \
    raw_input_chain_is_unfiltered \
    raw_command_uses_nft \
    nft_input_filter_status \
    firewall_state_matches_backend \
    raw_firewall_persistence_available \
    add_firewall_record \
    delete_firewall_record \
    persist_raw_firewall_rules \
    rollback_added_firewall_records \
    rollback_deleted_firewall_records \
    write_firewall_recovery_records \
    rollback_firewall_add_transaction \
    rollback_firewall_delete_transaction \
    _allow_port_locked \
    allow_port \
    firewall_record_backend_available \
    _remove_owned_firewall_records_locked \
    _remove_owned_firewall_port_locked \
    remove_owned_firewall_port \
    remove_owned_firewall_records_exact \
    _remove_owned_firewall_ports_locked \
    remove_owned_firewall_ports \
    configured_inbound_port_conflict_exists \
    configured_inbound_firewall_consumer_exists \
    nginx_configured_port_conflict_exists \
    nginx_firewall_consumer_exists \
    firewall_record_has_configured_consumer \
    _remove_owned_firewall_ports_if_unused_locked \
    remove_owned_firewall_ports_if_unused \
    remove_owned_firewall_rules \
    validate_singbox_config \
    validate_installed_singbox_config_strict \
    apply_jq_config \
    update_public_inbound_port \
    get_uniform_inbound_port \
    rewrite_public_client_port \
    public_port_conflicts \
    cleanup_public_port_backup \
    apply_public_port_service_state \
    restore_public_port_service_state \
    rollback_public_port_signal_transaction \
    acquire_proxy_transaction_lock \
    acquire_proxy_transaction_lock_checked \
    release_proxy_transaction_lock \
    reset_durable_transaction_state \
    assert_no_pending_durable_transaction \
    write_durable_transaction_registry \
    cleanup_durable_transaction_registry \
    write_durable_transaction_manifest \
    restore_durable_transaction_traps \
    arm_durable_transaction \
    durable_transaction_checkpoint \
    durable_transaction_set_owned_records \
    durable_transaction_trap_handler \
    disarm_durable_transaction \
    acquire_public_port_change_lock \
    release_public_port_change_lock \
    read_hy2_nat_state_records \
    read_active_hy2_port_hopping \
    _change_public_inbound_port_transaction_locked \
    change_public_inbound_port_transaction \
    change_subscription_port_transaction \
    add_extra_protocol_transaction \
    enable_hy2_port_hopping_transaction \
    disable_hy2_port_hopping_transaction \
    stop_subscription_service_transaction \
    start_subscription_service_transaction \
    restart_subscription_service_transaction; do
    load_function "$name"
done

validate_installed_singbox_config_strict() { return 0; }

work_dir="${tmp_root}/work"
server_name=sing-box
conf_dir="${work_dir}/conf"
FIREWALL_STATE_FILE="${work_dir}/firewall.state"
CALL_LOG="${tmp_root}/calls.log"
UFW_LIVE="${tmp_root}/ufw.live"
FIREWALLD_RUNTIME="${tmp_root}/firewalld.runtime"
FIREWALLD_PERMANENT="${tmp_root}/firewalld.permanent"
IPTABLES4_LIVE="${tmp_root}/iptables4.live"
IPTABLES6_LIVE="${tmp_root}/iptables6.live"
export FIREWALL_STATE_FILE CALL_LOG UFW_LIVE FIREWALLD_RUNTIME FIREWALLD_PERMANENT
export IPTABLES4_LIVE IPTABLES6_LIVE

MOCK_UFW=0
MOCK_UFW_ACTIVE=0
MOCK_UFW_STATUS_FAIL_ON=0
MOCK_FIREWALLD=0
MOCK_FIREWALLD_ACTIVE=0
MOCK_FIREWALLD_STATE_ERROR=0
MOCK_IPTABLES=0
MOCK_IP6TABLES=0
MOCK_NFT=0
MOCK_NFT_QUERY_FAIL=0
MOCK_NFT_INVALID_JSON=0
MOCK_NFT_INPUT_HOOK=0
MOCK_NFT_COMPAT_HOOK=0
MOCK_IP6_ADD_FAIL=0
MOCK_FIREWALLD_PERMANENT_ADD_FAIL=0
MOCK_RAW_PERSIST_FAIL=0
MOCK_RAW_PERSIST_AVAILABLE=1
MOCK_FLOCK_AVAILABLE=1
MOCK_RAW_DELETE_FAIL=0
MOCK_RAW_QUERY_ERROR=0
MOCK_RAW_POLICY_QUERY_ERROR=0
MOCK_IPTABLES_NFT=0
MOCK_IPTABLES_VERSION_QUERY_ERROR=0
MOCK_IPTABLES_POLICY=DROP
MOCK_RC_SERVICE=0
MOCK_RC_IPTABLES=0
MOCK_RC_IP6TABLES=0

reset_fixture() {
    rm -rf -- "$work_dir"
    mkdir -p -- "$work_dir" "$conf_dir"
    : > "$CALL_LOG"
    : > "$UFW_LIVE"
    : > "$FIREWALLD_RUNTIME"
    : > "$FIREWALLD_PERMANENT"
    : > "$IPTABLES4_LIVE"
    : > "$IPTABLES6_LIVE"
    MOCK_UFW=0
    MOCK_UFW_ACTIVE=0
    MOCK_UFW_STATUS_FAIL_ON=0
    MOCK_FIREWALLD=0
    MOCK_FIREWALLD_ACTIVE=0
    MOCK_FIREWALLD_STATE_ERROR=0
    MOCK_IPTABLES=0
    MOCK_IP6TABLES=0
    MOCK_NFT=0
    MOCK_NFT_QUERY_FAIL=0
    MOCK_NFT_INVALID_JSON=0
    MOCK_NFT_INPUT_HOOK=0
    MOCK_NFT_COMPAT_HOOK=0
    MOCK_IP6_ADD_FAIL=0
    MOCK_FIREWALLD_PERMANENT_ADD_FAIL=0
    MOCK_RAW_PERSIST_FAIL=0
    MOCK_RAW_PERSIST_AVAILABLE=1
    MOCK_FLOCK_AVAILABLE=1
    MOCK_RAW_DELETE_FAIL=0
    MOCK_RAW_QUERY_ERROR=0
    MOCK_RAW_POLICY_QUERY_ERROR=0
    MOCK_IPTABLES_NFT=0
    MOCK_IPTABLES_VERSION_QUERY_ERROR=0
    MOCK_IPTABLES_POLICY=DROP
    MOCK_RC_SERVICE=0
    MOCK_RC_IPTABLES=0
    MOCK_RC_IP6TABLES=0
}

command_exists() {
    case "$1" in
        ufw) [ "$MOCK_UFW" = 1 ] ;;
        firewall-cmd) [ "$MOCK_FIREWALLD" = 1 ] ;;
        iptables) [ "$MOCK_IPTABLES" = 1 ] ;;
        ip6tables) [ "$MOCK_IP6TABLES" = 1 ] ;;
        nft) [ "$MOCK_NFT" = 1 ] ;;
        netfilter-persistent) [ "$MOCK_RAW_PERSIST_AVAILABLE" = 1 ] ;;
        rc-service) [ "$MOCK_RC_SERVICE" = 1 ] ;;
        flock) [ "$MOCK_FLOCK_AVAILABLE" = 1 ] ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}

rc-service() {
    printf 'rc-service %s\n' "$*" >> "$CALL_LOG"
    if [ "${1:-}" = -e ]; then
        case "${2:-}" in
            iptables) [ "$MOCK_RC_IPTABLES" = 1 ] ;;
            ip6tables) [ "$MOCK_RC_IP6TABLES" = 1 ] ;;
            *) return 1 ;;
        esac
        return
    fi
    case "${1:-}" in
        iptables) [ "$MOCK_RC_IPTABLES" = 1 ] ;;
        ip6tables) [ "$MOCK_RC_IP6TABLES" = 1 ] ;;
        *) return 1 ;;
    esac
    [ "${2:-}" = save ]
}

ipv4_stack_available() { return 0; }
ipv6_stack_available() { return 0; }
red() { printf 'red %s\n' "$*" >> "$CALL_LOG"; }
yellow() { printf 'yellow %s\n' "$*" >> "$CALL_LOG"; }

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$CALL_LOG"
    [ "${1:-}" = is-active ] && [ "${2:-}" = firewalld ] && [ "$MOCK_FIREWALLD_ACTIVE" = 1 ]
}

netfilter-persistent() {
    printf 'netfilter-persistent %s\n' "$*" >> "$CALL_LOG"
    [ "$MOCK_RAW_PERSIST_FAIL" = 0 ]
}

nft() {
    printf 'nft %s\n' "$*" >> "$CALL_LOG"
    [ "$MOCK_NFT_QUERY_FAIL" = 0 ] || return 2
    [ "$*" = '-j list ruleset' ] || return 1
    if [ "$MOCK_NFT_INVALID_JSON" = 1 ]; then
        printf 'not-json\n'
    elif [ "$MOCK_NFT_INPUT_HOOK" = 1 ]; then
        printf '%s\n' '{"nftables":[{"chain":{"family":"inet","table":"filter","name":"input","type":"filter","hook":"input","prio":0,"policy":"drop"}}]}'
    elif [ "$MOCK_NFT_COMPAT_HOOK" = 1 ]; then
        printf '%s\n' '{"nftables":[{"chain":{"family":"ip","table":"filter","name":"INPUT","type":"filter","hook":"input","prio":0,"policy":"accept"}}]}'
    else
        printf '%s\n' '{"nftables":[]}'
    fi
}

ufw() {
    printf 'ufw %s\n' "$*" >> "$CALL_LOG"
    case "${1:-}" in
        status)
            local status_call_count
            status_call_count=$(grep -c '^ufw status' "$CALL_LOG")
            if [ "$MOCK_UFW_STATUS_FAIL_ON" -eq "$status_call_count" ]; then
                return 2
            fi
            if [ "$MOCK_UFW_ACTIVE" = 1 ]; then
                printf 'Status: active\n'
                cat "$UFW_LIVE"
            else
                printf 'Status: inactive\n'
            fi
            ;;
        allow)
            local family=4 address='' port='' proto='' previous=''
            for argument in "$@"; do
                [ "$previous" = to ] && address="$argument"
                [ "$previous" = port ] && port="$argument"
                [ "$previous" = proto ] && proto="$argument"
                previous="$argument"
            done
            if [ -z "$port" ]; then
                port="${3%/*}"
                proto="${3#*/}"
            fi
            [ "$address" = '::/0' ] && family=6
            if [ "$family" = 6 ]; then
                printf '%s/%s (v6) ALLOW IN Anywhere (v6)\n' "$port" "$proto" >> "$UFW_LIVE"
            else
                printf '%s/%s ALLOW IN Anywhere\n' "$port" "$proto" >> "$UFW_LIVE"
            fi
            ;;
        delete)
            local family=4 address='' port='' proto='' previous='' rule tmp
            for argument in "$@"; do
                [ "$previous" = to ] && address="$argument"
                [ "$previous" = port ] && port="$argument"
                [ "$previous" = proto ] && proto="$argument"
                previous="$argument"
            done
            if [ -z "$port" ]; then
                rule="${4:-${3:-}}"
                port="${rule%/*}"
                proto="${rule#*/}"
            fi
            [ "$address" = '::/0' ] && family=6
            tmp="${UFW_LIVE}.tmp"
            if [ "$family" = 6 ]; then
                awk -v rule="${port}/${proto} (v6) ALLOW IN Anywhere (v6)" '
                    {
                        normalized=$0
                        sub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*/, "", normalized)
                        if (normalized != rule) print
                    }
                ' "$UFW_LIVE" > "$tmp"
            else
                awk -v rule="${port}/${proto} ALLOW IN Anywhere" '
                    {
                        normalized=$0
                        sub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*/, "", normalized)
                        if (normalized != rule) print
                    }
                ' "$UFW_LIVE" > "$tmp"
            fi
            mv -f -- "$tmp" "$UFW_LIVE"
            ;;
    esac
}

firewall_cmd_has() {
    local file="$1" rule="$2"
    grep -Fxq -- "$rule" "$file"
}

firewall-cmd() {
    printf 'firewall-cmd %s\n' "$*" >> "$CALL_LOG"
    local permanent=0 zone='public' action='' rule='' file
    [ "$#" -eq 1 ] && [ "$1" = --state ] && {
        [ "$MOCK_FIREWALLD_STATE_ERROR" = 0 ] || return 2
        if [ "$MOCK_FIREWALLD_ACTIVE" = 1 ]; then
            printf 'running\n'
            return 0
        fi
        printf 'not running\n'
        return 1
        return
    }
    [ "$#" -eq 1 ] && [ "$1" = --get-default-zone ] && { printf 'public\n'; return; }
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --permanent) permanent=1 ;;
            --zone=*) zone="${1#--zone=}" ;;
            --query-port=*) action=query; rule="${1#--query-port=}" ;;
            --add-port=*) action=add; rule="${1#--add-port=}" ;;
            --remove-port=*) action=remove; rule="${1#--remove-port=}" ;;
        esac
        shift
    done
    file="$FIREWALLD_RUNTIME"
    [ "$permanent" = 1 ] && file="$FIREWALLD_PERMANENT"
    case "$action" in
        query) firewall_cmd_has "$file" "${zone}|${rule}" ;;
        add)
            [ "$permanent" = 1 ] && [ "$MOCK_FIREWALLD_PERMANENT_ADD_FAIL" = 1 ] && return 1
            printf '%s|%s\n' "$zone" "$rule" >> "$file"
            ;;
        remove)
            local tmp="${file}.tmp"
            grep -Fvx -- "${zone}|${rule}" "$file" > "$tmp" || true
            mv -f -- "$tmp" "$file"
            ;;
        *) return 1 ;;
    esac
}

mock_iptables() {
    local family="$1" file tool op chain spec tmp
    shift
    if [ "$family" = 4 ]; then
        file="$IPTABLES4_LIVE"
        tool=iptables
    else
        file="$IPTABLES6_LIVE"
        tool=ip6tables
    fi
    printf '%s %s\n' "$tool" "$*" >> "$CALL_LOG"
    op="${1:-}"
    if [ "$op" = -V ]; then
        [ "$MOCK_IPTABLES_VERSION_QUERY_ERROR" = 0 ] || return 2
        if [ "$MOCK_IPTABLES_NFT" = 1 ]; then
            printf '%s v1.8.9 (nf_tables)\n' "$tool"
        else
            printf '%s v1.8.9 (legacy)\n' "$tool"
        fi
        return 0
    fi
    if [ "$op" = -S ] && [ "${2:-}" = INPUT ]; then
        [ "$MOCK_RAW_POLICY_QUERY_ERROR" = 0 ] || return 2
        printf '%s\n' "-P INPUT ${MOCK_IPTABLES_POLICY}"
        sed 's/^/-A /' "$file"
        return 0
    fi
    chain="${2:-}"
    shift 2 || true
    spec="$chain $*"
    case "$op" in
        -C)
            [ "$MOCK_RAW_QUERY_ERROR" = 0 ] || return 2
            grep -Fxq -- "$spec" "$file"
            ;;
        -I)
            [ "$family" = 6 ] && [ "$MOCK_IP6_ADD_FAIL" = 1 ] && return 1
            tmp="${file}.tmp"
            printf '%s\n' "$spec" | cat - "$file" > "$tmp"
            mv -f -- "$tmp" "$file"
            ;;
        -A)
            [ "$family" = 6 ] && [ "$MOCK_IP6_ADD_FAIL" = 1 ] && return 1
            printf '%s\n' "$spec" >> "$file"
            ;;
        -D)
            [ "$MOCK_RAW_DELETE_FAIL" = 1 ] && return 1
            tmp="${file}.tmp"
            grep -Fvx -- "$spec" "$file" > "$tmp" || true
            mv -f -- "$tmp" "$file"
            ;;
        *) return 1 ;;
    esac
}

iptables() { mock_iptables 4 "$@"; }
ip6tables() { mock_iptables 6 "$@"; }

# Active UFW owns the decision when firewalld is installed but inactive and
# raw compatibility tools also exist.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
MOCK_FIREWALLD=1
MOCK_FIREWALLD_ACTIVE=0
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
assert_ok allow_port --families 1 1 23001/tcp
assert_contains 'ufw allow in proto tcp to 0.0.0.0/0 port 23001' "$CALL_LOG" 'active UFW did not receive the IPv4 rule'
assert_contains 'ufw allow in proto tcp to ::/0 port 23001' "$CALL_LOG" 'active UFW did not receive the IPv6 rule'
assert_not_contains 'firewall-cmd --add-port=23001/tcp' "$CALL_LOG" 'firewalld was mutated behind active UFW'
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'raw iptables was mutated behind active UFW'
assert_contains 'ufw|4|23001|tcp' "$FIREWALL_STATE_FILE" 'new IPv4 UFW rule was not recorded as owned'
assert_contains 'ufw|6|23001|tcp' "$FIREWALL_STATE_FILE" 'new IPv6 UFW rule was not recorded as owned'
[ "$(stat -c '%a' "$FIREWALL_STATE_FILE")" = 600 ] || fail 'firewall ownership state is not mode 0600'
[ "$(stat -c '%a' "${work_dir}/.firewall.lock")" = 600 ] || fail 'firewall lock is not mode 0600'

# An installed firewall manager whose state cannot be queried is not proof
# that it is inactive.  Backend selection must fail closed rather than mutate
# raw iptables behind a potentially active UFW/firewalld instance.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
MOCK_UFW_STATUS_FAIL_ON=1
MOCK_IPTABLES=1
assert_fail allow_port --families 1 0 23027/tcp
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'UFW query failure incorrectly fell back to raw iptables'
assert_not_contains 'ufw allow' "$CALL_LOG" 'UFW was mutated after its active-state query failed'

reset_fixture
MOCK_FIREWALLD=1
MOCK_FIREWALLD_ACTIVE=1
MOCK_FIREWALLD_STATE_ERROR=1
MOCK_IPTABLES=1
assert_fail allow_port --families 1 0 23028/tcp
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'firewalld query failure incorrectly fell back to raw iptables'
assert_not_contains 'firewall-cmd --add-port' "$CALL_LOG" 'firewalld was mutated after its state query failed'

# UFW can also fail between backend selection and the exact rule query.  That
# second failure is an unknown state, not evidence that the rule is absent.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
MOCK_UFW_STATUS_FAIL_ON=2
MOCK_IPTABLES=1
assert_fail allow_port --families 1 0 23029/tcp
assert_not_contains 'ufw allow' "$CALL_LOG" 'UFW rule was added after the second active-state query failed'
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'second UFW query failure switched firewall backends'

# Missing flock fails closed before any firewall mutation.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
MOCK_FLOCK_AVAILABLE=0
assert_fail allow_port --families 1 0 23013/tcp
assert_not_contains 'ufw allow in 23013/tcp' "$CALL_LOG" 'firewall changed without the ownership lock'

# Concurrent writers serialize the complete state read-modify-write cycle.
reset_fixture
MOCK_IPTABLES=1
( allow_port --families 1 0 23101/tcp ) & first_writer=$!
( allow_port --families 1 0 23102/udp ) & second_writer=$!
wait "$first_writer" || fail 'first concurrent firewall writer failed'
wait "$second_writer" || fail 'second concurrent firewall writer failed'
assert_contains 'iptables|4|sing-box-pre|23101|tcp' "$FIREWALL_STATE_FILE" 'first concurrent ownership record was lost'
assert_contains 'iptables|4|sing-box-pre|23102|udp' "$FIREWALL_STATE_FILE" 'second concurrent ownership record was lost'

# A pre-existing exact rule is never recorded or removed.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
printf '23002/tcp ALLOW IN Anywhere\n' > "$UFW_LIVE"
assert_ok allow_port --families 1 0 23002/tcp
if [ -s "$FIREWALL_STATE_FILE" ] && grep -Fq '23002|tcp' "$FIREWALL_STATE_FILE"; then
    fail 'pre-existing UFW rule was claimed as owned'
fi
assert_ok remove_owned_firewall_rules
assert_contains '23002/tcp ALLOW IN Anywhere' "$UFW_LIVE" 'pre-existing UFW rule was removed'

reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
printf '23018/tcp (v6) ALLOW IN Anywhere (v6)\n' > "$UFW_LIVE"
assert_ok allow_port --families 0 1 23018/tcp
if [ -s "$FIREWALL_STATE_FILE" ] && grep -Fq '23018|tcp' "$FIREWALL_STATE_FILE"; then
    fail 'pre-existing IPv6-only UFW rule was claimed as owned'
fi

# IPv6-only UFW state never satisfies an IPv4 request.  The missing IPv4
# family is added and owned independently while the pre-existing IPv6 rule is
# left unclaimed.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
printf '23019/tcp (v6) ALLOW IN Anywhere (v6)\n' > "$UFW_LIVE"
assert_ok allow_port --families 1 1 23019/tcp
assert_contains '23019/tcp ALLOW IN Anywhere' "$UFW_LIVE" 'IPv6-only UFW rule incorrectly satisfied IPv4'
assert_contains '23019/tcp (v6) ALLOW IN Anywhere (v6)' "$UFW_LIVE" 'pre-existing IPv6 UFW rule disappeared'
assert_contains 'ufw|4|23019|tcp' "$FIREWALL_STATE_FILE" 'created IPv4 UFW rule is not independently owned'
assert_not_contains 'ufw|6|23019|tcp' "$FIREWALL_STATE_FILE" 'pre-existing IPv6 UFW rule was claimed'

# Numbered UFW output is public only when its From column is exactly the
# corresponding Anywhere value.  Restricted-source allows do not open the
# public port and are never claimed or removed by this script.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
printf '%s\n' \
    '[ 1] 23023/tcp ALLOW IN 192.0.2.0/24' \
    '[ 2] 23023/tcp (v6) ALLOW IN 2001:db8::/64' > "$UFW_LIVE"
assert_ok allow_port --families 1 1 23023/tcp
assert_contains '23023/tcp ALLOW IN Anywhere' "$UFW_LIVE" 'restricted IPv4 UFW rule incorrectly satisfied public access'
assert_contains '23023/tcp (v6) ALLOW IN Anywhere (v6)' "$UFW_LIVE" 'restricted IPv6 UFW rule incorrectly satisfied public access'
assert_contains 'ufw|4|23023|tcp' "$FIREWALL_STATE_FILE" 'created global IPv4 UFW rule is not owned'
assert_contains 'ufw|6|23023|tcp' "$FIREWALL_STATE_FILE" 'created global IPv6 UFW rule is not owned'
assert_ok remove_owned_firewall_rules
assert_contains '[ 1] 23023/tcp ALLOW IN 192.0.2.0/24' "$UFW_LIVE" 'restricted IPv4 UFW rule was deleted'
assert_contains '[ 2] 23023/tcp (v6) ALLOW IN 2001:db8::/64' "$UFW_LIVE" 'restricted IPv6 UFW rule was deleted'

reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
printf '%s\n' \
    '[ 7] 23024/tcp ALLOW IN Anywhere' \
    '[ 8] 23024/tcp (v6) ALLOW IN Anywhere (v6)' > "$UFW_LIVE"
assert_ok allow_port --families 1 1 23024/tcp
if [ -s "$FIREWALL_STATE_FILE" ] && grep -Fq '23024|tcp' "$FIREWALL_STATE_FILE"; then
    fail 'numbered pre-existing public UFW rules were claimed as owned'
fi

# An installed but inactive UFW cannot safely validate/delete owned rules.
# Cleanup and uninstall must fail closed and preserve state evidence.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
assert_ok allow_port --families 1 0 23020/tcp
state_before="$(cat "$FIREWALL_STATE_FILE")"
MOCK_UFW_ACTIVE=0
assert_fail remove_owned_firewall_rules
[ "$(cat "$FIREWALL_STATE_FILE")" = "$state_before" ] || fail 'inactive UFW caused owned state deletion'
assert_not_contains 'ufw delete' "$CALL_LOG" 'inactive UFW was mutated during fail-closed cleanup'

# Firewalld is updated in both runtime/permanent scopes without a global reload.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
MOCK_FIREWALLD=1
MOCK_FIREWALLD_ACTIVE=1
assert_fail allow_port --families 1 1 23003/udp
assert_not_contains 'ufw allow' "$CALL_LOG" 'dual-active firewall managers mutated UFW before failing'
assert_not_contains 'firewall-cmd --add-port' "$CALL_LOG" 'dual-active firewall managers mutated firewalld before failing'

reset_fixture
MOCK_FIREWALLD=1
MOCK_FIREWALLD_ACTIVE=1
MOCK_IPTABLES=1
assert_ok allow_port --families 1 1 23003/udp
assert_contains 'public|23003/udp' "$FIREWALLD_RUNTIME" 'firewalld runtime rule is missing'
assert_contains 'public|23003/udp' "$FIREWALLD_PERMANENT" 'firewalld permanent rule is missing'
assert_not_contains 'firewall-cmd --reload' "$CALL_LOG" 'firewalld was globally reloaded'
assert_ok remove_owned_firewall_port 23003/udp
[ ! -s "$FIREWALLD_RUNTIME" ] || fail 'owned firewalld runtime rule remained'
[ ! -s "$FIREWALLD_PERMANENT" ] || fail 'owned firewalld permanent rule remained'

# Runtime and permanent firewalld scopes have independent ownership.  A
# pre-existing runtime rule survives when only the permanent half was created.
reset_fixture
MOCK_FIREWALLD=1
MOCK_FIREWALLD_ACTIVE=1
printf 'public|23008/tcp\n' > "$FIREWALLD_RUNTIME"
assert_ok allow_port --families 1 0 23008/tcp
assert_contains 'public|23008/tcp' "$FIREWALLD_RUNTIME" 'pre-existing runtime rule disappeared'
assert_contains 'public|23008/tcp' "$FIREWALLD_PERMANENT" 'missing permanent rule was not created'
assert_not_contains 'firewalld|runtime|public|23008|tcp' "$FIREWALL_STATE_FILE" 'pre-existing runtime rule was claimed'
assert_contains 'firewalld|permanent|public|23008|tcp' "$FIREWALL_STATE_FILE" 'created permanent rule was not owned'
assert_ok remove_owned_firewall_port 23008/tcp
assert_contains 'public|23008/tcp' "$FIREWALLD_RUNTIME" 'pre-existing runtime rule was removed'
[ ! -s "$FIREWALLD_PERMANENT" ] || fail 'owned permanent rule remained'

# Exact-token cleanup removes only records created by the caller, not every
# owned scope sharing the same port.
reset_fixture
MOCK_FIREWALLD=1
MOCK_FIREWALLD_ACTIVE=1
assert_ok allow_port --families 1 0 23017/tcp
assert_ok remove_owned_firewall_records_exact 'firewalld|runtime|public|23017|tcp'
[ ! -s "$FIREWALLD_RUNTIME" ] || fail 'exact runtime token remained'
assert_contains 'public|23017/tcp' "$FIREWALLD_PERMANENT" 'exact cleanup removed an unrelated permanent token'
assert_contains 'firewalld|permanent|public|23017|tcp' "$FIREWALL_STATE_FILE" 'remaining permanent ownership was lost'

# Multi-protocol cleanup is one ownership transaction, so deleting an inbound
# cannot remove TCP and then strand UDP (or vice versa).
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
assert_ok allow_port --families 1 0 23030/tcp 23030/udp
assert_ok remove_owned_firewall_ports 23030/tcp 23030/udp
assert_not_contains '23030/tcp ALLOW IN Anywhere' "$UFW_LIVE" 'multi-rule cleanup left the owned TCP rule'
assert_not_contains '23030/udp ALLOW IN Anywhere' "$UFW_LIVE" 'multi-rule cleanup left the owned UDP rule'
[ ! -e "$FIREWALL_STATE_FILE" ] || fail 'multi-rule cleanup left ownership state'

# Shared-port cleanup is consumer- and family-aware: removing one protocol must
# not delete a rule still required by another configured inbound.
shared_inbounds="${tmp_root}/shared-inbounds.json"
get_bindv6only() { printf '%s\n' 1; }
printf '%s\n' '{"inbounds":[{"type":"anytls","tag":"shared-v4","listen":"0.0.0.0","listen_port":23031}]}' > "$shared_inbounds"
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
assert_ok allow_port --families 1 1 23031/tcp
assert_ok remove_owned_firewall_ports_if_unused "$shared_inbounds" 23031/tcp
assert_contains '23031/tcp ALLOW IN Anywhere' "$UFW_LIVE" 'shared IPv4 consumer lost its owned UFW rule'
assert_not_contains '23031/tcp (v6) ALLOW IN Anywhere (v6)' "$UFW_LIVE" 'unused IPv6 UFW rule was retained'
assert_contains 'ufw|4|23031|tcp' "$FIREWALL_STATE_FILE" 'shared IPv4 ownership record was removed'
assert_not_contains 'ufw|6|23031|tcp' "$FIREWALL_STATE_FILE" 'unused IPv6 ownership record remained'
printf '%s\n' '{"inbounds":[]}' > "$shared_inbounds"
assert_ok remove_owned_firewall_ports_if_unused "$shared_inbounds" 23031/tcp
[ ! -e "$FIREWALL_STATE_FILE" ] || fail 'unused shared-port ownership was not removed'

printf '%s\n' '{"inbounds":[{"type":"anytls","tag":"shared-v4","listen":"0.0.0.0","listen_port":23032}]}' > "$shared_inbounds"
reset_fixture
MOCK_FIREWALLD=1
MOCK_FIREWALLD_ACTIVE=1
assert_ok allow_port --families 1 1 23032/tcp
assert_ok remove_owned_firewall_ports_if_unused "$shared_inbounds" 23032/tcp
assert_contains 'public|23032/tcp' "$FIREWALLD_RUNTIME" 'family-agnostic runtime rule ignored a shared consumer'
assert_contains 'public|23032/tcp' "$FIREWALLD_PERMANENT" 'family-agnostic permanent rule ignored a shared consumer'

# Port allocation and firewall-consumer checks intentionally have different
# address semantics: a stopped loopback inbound still conflicts with a new
# listener, but it does not justify retaining a public firewall rule.
printf '%s\n' '{"inbounds":[{"type":"anytls","tag":"loopback","listen":"127.0.0.1","listen_port":23033}]}' > "$shared_inbounds"
assert_ok configured_inbound_port_conflict_exists "$shared_inbounds" 23033 tcp
assert_status 1 configured_inbound_firewall_consumer_exists "$shared_inbounds" 23033 tcp any
assert_status 1 configured_inbound_port_conflict_exists "$shared_inbounds" 23033 udp

printf '%s\n' '{broken' > "$shared_inbounds"
assert_status 2 configured_inbound_port_conflict_exists "$shared_inbounds" 23033 tcp
assert_status 2 configured_inbound_firewall_consumer_exists "$shared_inbounds" 23033 tcp any

get_bindv6only() { printf '%s\n' 0; }
printf '%s\n' '{"inbounds":[{"type":"anytls","tag":"dual-wildcard","listen":"::","listen_port":23034}]}' > "$shared_inbounds"
assert_ok configured_inbound_firewall_consumer_exists "$shared_inbounds" 23034 tcp 4
assert_ok configured_inbound_firewall_consumer_exists "$shared_inbounds" 23034 tcp 6

shared_nginx="${tmp_root}/shared-nginx.conf"
cat > "$shared_nginx" <<'EOF'
listen 23035;
listen [::]:23036;
listen [::]:23037 ipv6only=off;
EOF
assert_ok nginx_firewall_consumer_exists "$shared_nginx" 23035 4
assert_status 1 nginx_firewall_consumer_exists "$shared_nginx" 23035 6
assert_ok nginx_firewall_consumer_exists "$shared_nginx" 23036 6
assert_status 1 nginx_firewall_consumer_exists "$shared_nginx" 23036 4
assert_ok nginx_firewall_consumer_exists "$shared_nginx" 23037 4
assert_ok nginx_firewall_consumer_exists "$shared_nginx" 23037 6
printf '%s\n' 'listen 127.0.0.1:23039;' >> "$shared_nginx"
assert_ok nginx_configured_port_conflict_exists "$shared_nginx" 23035 tcp
assert_ok nginx_configured_port_conflict_exists "$shared_nginx" 23036 tcp
assert_ok nginx_configured_port_conflict_exists "$shared_nginx" 23039 tcp
assert_status 1 nginx_configured_port_conflict_exists "$shared_nginx" 23039 udp
assert_status 1 nginx_configured_port_conflict_exists "${tmp_root}/missing-nginx.conf" 23039 tcp
unsafe_nginx="${tmp_root}/unsafe-nginx.conf"
ln -s "$shared_nginx" "$unsafe_nginx"
assert_status 2 nginx_configured_port_conflict_exists "$unsafe_nginx" 23039 tcp
rm -f -- "$unsafe_nginx"
printf '%s\n' 'listen 23039;' > "$unsafe_nginx"
chmod 000 "$unsafe_nginx"
assert_status 2 nginx_configured_port_conflict_exists "$unsafe_nginx" 23039 tcp
chmod 600 "$unsafe_nginx"

# Raw iptables ownership is also family-aware.  A dual wildcard consumes both
# records, while an IPv6-only listener allows only the IPv4 record to be removed.
reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
assert_ok allow_port --families 1 1 23038/tcp
assert_ok remove_owned_firewall_ports_if_unused "$shared_inbounds" 23038/tcp
# No matching port consumer exists yet, so both records above should be gone.
[ ! -e "$FIREWALL_STATE_FILE" ] || fail 'unused raw dual-family records remained'

printf '%s\n' '{"inbounds":[{"type":"anytls","tag":"shared-dual","listen":"::","listen_port":23038}]}' > "$shared_inbounds"
reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
assert_ok allow_port --families 1 1 23038/tcp
assert_ok remove_owned_firewall_ports_if_unused "$shared_inbounds" 23038/tcp
assert_contains 'iptables|4|sing-box-pre|23038|tcp' "$FIREWALL_STATE_FILE" 'dual wildcard lost its raw IPv4 ownership'
assert_contains 'iptables|6|sing-box-pre|23038|tcp' "$FIREWALL_STATE_FILE" 'dual wildcard lost its raw IPv6 ownership'

get_bindv6only() { printf '%s\n' 1; }
assert_ok remove_owned_firewall_ports_if_unused "$shared_inbounds" 23038/tcp
assert_not_contains 'iptables|4|sing-box-pre|23038|tcp' "$FIREWALL_STATE_FILE" 'IPv6-only wildcard retained unused raw IPv4 ownership'
assert_contains 'iptables|6|sing-box-pre|23038|tcp' "$FIREWALL_STATE_FILE" 'IPv6-only wildcard lost raw IPv6 ownership'

# A firewalld permanent-scope failure rolls back the runtime half.
reset_fixture
MOCK_FIREWALLD=1
MOCK_FIREWALLD_ACTIVE=1
MOCK_FIREWALLD_PERMANENT_ADD_FAIL=1
assert_fail allow_port --families 1 0 23009/tcp
[ ! -s "$FIREWALLD_RUNTIME" ] || fail 'runtime firewalld rule remained after permanent add failed'
[ ! -e "$FIREWALL_STATE_FILE" ] || fail 'failed firewalld transaction created ownership state'

# A stock minimal VPS may have no local firewall manager or raw iptables
# command at all.  In that case there is nothing local for this script to
# mutate, so installation must continue with an explicit warning and without
# claiming ownership state.
reset_fixture
assert_ok allow_port --families 1 0 23003/tcp
assert_contains '未检测到本机防火墙后端' "$CALL_LOG" 'missing-firewall compatibility path did not warn'
[ ! -e "$FIREWALL_STATE_FILE" ] || fail 'missing-firewall compatibility path created ownership state'
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'missing-firewall compatibility path attempted a raw mutation'

reset_fixture
assert_ok allow_port --families 1 1 23003/tcp
assert_contains '未检测到本机防火墙后端' "$CALL_LOG" 'dual-stack missing-firewall compatibility path did not warn'
[ ! -e "$FIREWALL_STATE_FILE" ] || fail 'dual-stack missing-firewall compatibility path created ownership state'

reset_fixture
assert_ok allow_port --families 0 1 23003/tcp
assert_contains '未检测到本机防火墙后端' "$CALL_LOG" 'IPv6-only missing-firewall compatibility path did not warn'

reset_fixture
MOCK_NFT=1
MOCK_NFT_INPUT_HOOK=1
assert_fail allow_port --families 1 0 23003/tcp
assert_not_contains '未检测到本机防火墙后端' "$CALL_LOG" 'nftables-only host was misclassified as having no firewall'

reset_fixture
MOCK_NFT=1
assert_ok allow_port --families 1 0 23003/tcp
assert_contains '未检测到本机防火墙后端' "$CALL_LOG" 'empty nftables ruleset did not use missing-firewall compatibility path'

reset_fixture
MOCK_NFT=1
MOCK_NFT_QUERY_FAIL=1
assert_fail allow_port --families 1 0 23003/tcp
assert_not_contains '未检测到本机防火墙后端' "$CALL_LOG" 'nftables query failure was misclassified as no firewall'

reset_fixture
MOCK_NFT=1
MOCK_NFT_INVALID_JSON=1
assert_status 2 allow_port --families 1 0 23003/tcp
assert_not_contains '未检测到本机防火墙后端' "$CALL_LOG" 'invalid nftables JSON was misclassified as no firewall'

reset_fixture
printf 'version=1\niptables|4|sing-box-pre|23003|tcp\n' > "$FIREWALL_STATE_FILE"
assert_fail allow_port --families 1 0 23003/tcp
assert_contains '所有权记录不一致' "$CALL_LOG" 'missing owned firewall backend did not fail closed'

reset_fixture
MOCK_IPTABLES=1
assert_fail allow_port --families 1 1 23003/tcp
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'partial dual-stack backend mutated one family before failing'

reset_fixture
MOCK_IPTABLES=1
MOCK_IPTABLES_POLICY=ACCEPT
assert_ok allow_port --families 1 1 23003/tcp
assert_contains '双栈防火墙后端不完整' "$CALL_LOG" 'safe partial dual-stack backend did not warn'
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'safe partial dual-stack compatibility path mutated one family'

# Existing ownership must never drift silently to another backend.
reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
printf 'version=1\niptables|4|sing-box-pre|23003|tcp\n' > "$FIREWALL_STATE_FILE"
assert_fail allow_port --families 1 0 23003/tcp
assert_not_contains 'ufw allow' "$CALL_LOG" 'backend drift mixed UFW rules into raw ownership state'

# Raw iptables owns only marker-tagged rules; unrelated/pre-existing rules survive.
reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
MOCK_NFT=1
MOCK_NFT_INPUT_HOOK=1
assert_fail allow_port --families 1 1 23004/tcp
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'raw backend mutated rules despite an unmanaged native nft INPUT hook'

reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
MOCK_NFT=1
MOCK_NFT_COMPAT_HOOK=1
MOCK_IPTABLES_NFT=1
assert_ok allow_port --families 1 1 23004/tcp
assert_contains 'iptables|4|sing-box-pre|23004|tcp' "$FIREWALL_STATE_FILE" 'iptables-nft compatibility hook was treated as unmanaged native nft'

reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
MOCK_NFT=1
assert_ok allow_port --families 1 1 23004/tcp

reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
MOCK_NFT=1
MOCK_IPTABLES_VERSION_QUERY_ERROR=1
assert_status 2 allow_port --families 1 1 23004/tcp
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'raw backend mutated rules after iptables backend detection failed'

reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
printf 'INPUT -p tcp --dport 23004 -j ACCEPT\n' > "$IPTABLES4_LIVE"
assert_ok allow_port --families 1 1 23004/tcp 23005/udp
assert_contains 'INPUT -p tcp --dport 23004 -j ACCEPT' "$IPTABLES4_LIVE" 'pre-existing IPv4 rule changed'
assert_contains '23005' "$FIREWALL_STATE_FILE" 'new raw rule was not recorded'
assert_contains '--comment sing-box-pre' "$IPTABLES4_LIVE" 'owned raw rule lacks its marker'
assert_ok remove_owned_firewall_rules
assert_contains 'INPUT -p tcp --dport 23004 -j ACCEPT' "$IPTABLES4_LIVE" 'pre-existing raw rule was removed'
if grep -Fq -- '--dport 23005' "$IPTABLES4_LIVE" || grep -Fq -- '--dport 23005' "$IPTABLES6_LIVE"; then
    fail 'owned raw rule remained after cleanup'
fi

# A cross-family partial add failure rolls back this call and does not claim state.
reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
MOCK_IP6_ADD_FAIL=1
assert_fail allow_port --families 1 1 23006/tcp
if grep -Fq -- '--dport 23006' "$IPTABLES4_LIVE"; then
    fail 'IPv4 rule remained after the IPv6 half failed'
fi
if [ -e "$FIREWALL_STATE_FILE" ] && grep -Fq '23006' "$FIREWALL_STATE_FILE"; then
    fail 'failed partial add was recorded as owned'
fi

# Persist and state-write failures roll back live rules and preserve the old
# ownership generation.
reset_fixture
MOCK_IPTABLES=1
MOCK_RAW_PERSIST_FAIL=1
assert_fail allow_port --families 1 0 23010/tcp
if grep -Fq -- '--dport 23010' "$IPTABLES4_LIVE"; then
    fail 'raw rule remained after persistence failed'
fi
[ ! -e "$FIREWALL_STATE_FILE" ] || fail 'persistence failure created ownership state'

# An ACCEPT default policy does not prove that the port is reachable: an
# earlier explicit DROP can still intercept it.  The script must create and
# persist its own marker rule at the head of INPUT, or fail closed when no
# persistence facility exists.
reset_fixture
MOCK_IPTABLES=1
MOCK_IPTABLES_POLICY=ACCEPT
printf 'INPUT -p tcp --dport 23014 -j DROP\n' > "$IPTABLES4_LIVE"
assert_ok allow_port --families 1 0 23014/tcp
assert_contains 'iptables -I INPUT -p tcp --dport 23014 -m comment --comment sing-box-pre -j ACCEPT' "$CALL_LOG" 'INPUT ACCEPT incorrectly skipped the owned allow rule'
[[ "$(head -n 1 "$IPTABLES4_LIVE")" == *'--comment sing-box-pre -j ACCEPT' ]] || \
    fail 'owned raw allow rule was not inserted ahead of an explicit DROP'
assert_contains 'iptables|4|sing-box-pre|23014|tcp' "$FIREWALL_STATE_FILE" 'INPUT ACCEPT rule was not recorded as owned'

reset_fixture
MOCK_IPTABLES=1
MOCK_IPTABLES_POLICY=ACCEPT
MOCK_RAW_PERSIST_AVAILABLE=0
assert_ok allow_port --families 1 0 23015/tcp
assert_contains 'INPUT 链未启用过滤' "$CALL_LOG" 'unfiltered raw compatibility path did not warn'
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'unfiltered raw compatibility path added an ephemeral rule'
[ ! -e "$FIREWALL_STATE_FILE" ] || fail 'unfiltered raw compatibility path created ownership state'

reset_fixture
MOCK_IPTABLES=1
MOCK_IPTABLES_POLICY=ACCEPT
MOCK_RAW_PERSIST_AVAILABLE=0
printf 'INPUT -p tcp --dport 23015 -j DROP\n' > "$IPTABLES4_LIVE"
assert_fail allow_port --families 1 0 23015/tcp
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'filtered raw backend was mutated without persistence support'

reset_fixture
MOCK_IPTABLES=1
MOCK_IPTABLES_POLICY=ACCEPT
MOCK_RAW_PERSIST_AVAILABLE=0
MOCK_RAW_POLICY_QUERY_ERROR=1
assert_status 2 allow_port --families 1 0 23015/tcp
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'raw INPUT query failure was mutated without persistence support'

# OpenRC persistence is validated for every family that would be changed
# before the first live mutation.  A missing ip6tables service therefore
# leaves both families untouched instead of relying on rollback.
reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
MOCK_RAW_PERSIST_AVAILABLE=0
MOCK_RC_SERVICE=1
MOCK_RC_IPTABLES=1
MOCK_RC_IP6TABLES=0
assert_fail allow_port --families 1 1 23021/tcp
assert_not_contains '--dport 23021' "$IPTABLES4_LIVE" 'IPv4 raw half survived missing IPv6 persistence service'
assert_not_contains '--dport 23021' "$IPTABLES6_LIVE" 'IPv6 raw rule was added without its persistence service'
assert_not_contains 'iptables -I INPUT' "$CALL_LOG" 'raw dual-stack add mutated live rules before all-family persistence preflight'
assert_not_contains 'rc-service iptables save' "$CALL_LOG" 'preflight-only failure unnecessarily persisted an unchanged IPv4 family'
assert_not_contains 'rc-service ip6tables save' "$CALL_LOG" 'unchanged/unavailable IPv6 family was blindly saved'

reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
MOCK_RAW_PERSIST_AVAILABLE=0
MOCK_RC_SERVICE=1
MOCK_RC_IPTABLES=1
MOCK_RC_IP6TABLES=1
assert_ok allow_port --families 0 1 23022/udp
assert_contains 'rc-service ip6tables save' "$CALL_LOG" 'changed IPv6 family was not persisted'
assert_not_contains 'rc-service iptables save' "$CALL_LOG" 'unchanged IPv4 family was unnecessarily saved'
state_before="$(cat "$FIREWALL_STATE_FILE")"
MOCK_RC_IP6TABLES=0
assert_fail remove_owned_firewall_port 23022/udp
assert_contains '--dport 23022' "$IPTABLES6_LIVE" 'IPv6 rule was deleted without a persistence service'
[ "$(cat "$FIREWALL_STATE_FILE")" = "$state_before" ] || fail 'missing IPv6 persistence service rewrote state'

# Cleanup must preflight persistence for every live raw family before deleting
# the first rule.  Otherwise a dual-stack cleanup can delete/persist neither
# side consistently when only the IPv4 OpenRC service exists.
reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
assert_ok allow_port --families 1 1 23025/tcp
state_before="$(cat "$FIREWALL_STATE_FILE")"
MOCK_RAW_PERSIST_AVAILABLE=0
MOCK_RC_SERVICE=1
MOCK_RC_IPTABLES=1
MOCK_RC_IP6TABLES=0
: > "$CALL_LOG"
assert_fail remove_owned_firewall_rules
assert_contains '--dport 23025' "$IPTABLES4_LIVE" 'IPv4 rule was deleted before IPv6 persistence preflight failed'
assert_contains '--dport 23025' "$IPTABLES6_LIVE" 'IPv6 rule disappeared during failed dual-stack cleanup'
[ "$(cat "$FIREWALL_STATE_FILE")" = "$state_before" ] || fail 'failed dual-stack cleanup rewrote ownership state'
assert_not_contains 'iptables -D INPUT' "$CALL_LOG" 'raw cleanup mutated IPv4 before preflighting every family'

# A query error is not proof that an owned rule is absent.  Cleanup must keep
# both the live rule and its ownership evidence instead of orphaning it.
reset_fixture
MOCK_IPTABLES=1
assert_ok allow_port --families 1 0 23026/tcp
state_before="$(cat "$FIREWALL_STATE_FILE")"
MOCK_RAW_QUERY_ERROR=1
assert_fail remove_owned_firewall_rules
assert_contains '--dport 23026' "$IPTABLES4_LIVE" 'query failure orphaned a live raw rule'
[ "$(cat "$FIREWALL_STATE_FILE")" = "$state_before" ] || fail 'query failure discarded firewall ownership evidence'

# If rollback itself fails, return the fatal status and preserve a 0600
# recovery record instead of silently orphaning the new raw rule.
reset_fixture
MOCK_IPTABLES=1
MOCK_IP6TABLES=1
MOCK_IP6_ADD_FAIL=1
MOCK_RAW_DELETE_FAIL=1
assert_status 2 allow_port --families 1 1 23016/tcp
assert_contains 'iptables|4|sing-box-pre|23016|tcp' "${work_dir}/firewall.recovery" 'rollback failure evidence is missing'
[ "$(stat -c '%a' "${work_dir}/firewall.recovery")" = 600 ] || fail 'recovery evidence is not mode 0600'
assert_status 2 remove_owned_firewall_rules
assert_contains 'iptables|4|sing-box-pre|23016|tcp' "${work_dir}/firewall.recovery" 'cleanup erased unresolved recovery evidence'

reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
printf 'not-a-directory\n' > "${tmp_root}/state-parent"
FIREWALL_STATE_FILE="${tmp_root}/state-parent/firewall.state"
assert_fail allow_port --families 1 0 23011/tcp
if grep -Fq '23011/tcp ALLOW IN' "$UFW_LIVE"; then
    fail 'UFW rule remained after ownership state could not be written'
fi
FIREWALL_STATE_FILE="${work_dir}/firewall.state"

# Corrupt state and unavailable owned backends fail closed and preserve evidence.
reset_fixture
printf 'version=1\ncorrupt|entry\n' > "$FIREWALL_STATE_FILE"
chmod 600 "$FIREWALL_STATE_FILE"
state_before="$(cat "$FIREWALL_STATE_FILE")"
assert_fail remove_owned_firewall_rules
[ "$(cat "$FIREWALL_STATE_FILE")" = "$state_before" ] || fail 'corrupt ownership state was rewritten'

printf 'version=1\niptables|4|sing-box-pre|23012|tcp|injected\n' > "$FIREWALL_STATE_FILE"
state_before="$(cat "$FIREWALL_STATE_FILE")"
assert_fail remove_owned_firewall_rules
[ "$(cat "$FIREWALL_STATE_FILE")" = "$state_before" ] || fail 'extra state fields were accepted or rewritten'

reset_fixture
MOCK_UFW=1
MOCK_UFW_ACTIVE=1
assert_ok allow_port --families 1 0 23007/tcp
state_before="$(cat "$FIREWALL_STATE_FILE")"
MOCK_UFW=0
MOCK_UFW_ACTIVE=0
assert_fail remove_owned_firewall_rules
[ "$(cat "$FIREWALL_STATE_FILE")" = "$state_before" ] || fail 'state was deleted while its backend was unavailable'

# The shared transaction must clean HY2 then owned firewall state before the
# workdir, while public entry points delegate instead of mutating directly.
uninstall_source="$(extract_function perform_singbox_uninstall)"
hy2_cleanup_line="$(grep -n 'remove_hy2_port_hopping' <<< "$uninstall_source" | head -1 | cut -d: -f1 || true)"
cleanup_line="$(grep -n 'remove_owned_firewall_rules' <<< "$uninstall_source" | head -1 | cut -d: -f1 || true)"
delete_line="$(grep -n 'rm -rf.*target_work_dir' <<< "$uninstall_source" | head -1 | cut -d: -f1 || true)"
[ -n "$hy2_cleanup_line" ] && [ -n "$cleanup_line" ] && [ -n "$delete_line" ] || \
    fail 'shared uninstall transaction is not wired to HY2/firewall cleanup'
[ "$hy2_cleanup_line" -lt "$cleanup_line" ] || fail 'shared uninstall cleans firewall before HY2 NAT'
[ "$cleanup_line" -lt "$delete_line" ] || fail 'shared uninstall deletes ownership state before cleanup'
for uninstall_name in uninstall_singbox auto_uninstall; do
    uninstall_source="$(extract_function "$uninstall_name")"
    grep -q 'perform_singbox_uninstall' <<< "$uninstall_source" || \
        fail "${uninstall_name} does not delegate to the shared transaction"
    ! grep -q 'remove_owned_firewall_rules\|remove_hy2_port_hopping' <<< "$uninstall_source" || \
        fail "${uninstall_name} bypasses the shared network transaction"
done

# Reality port helpers select VLESS inbounds by the vless-reality tag family,
# rather than looking for the nonexistent type "reality".
selector_file="${tmp_root}/selector-inbounds.json"
cat > "$selector_file" <<'JSON'
{"inbounds":[
  {"type":"vless","tag":"vless-reality-ipv4","listen_port":22000},
  {"type":"vless","tag":"vless-reality-ipv6","listen_port":22000},
  {"type":"vless","tag":"vless-other","listen_port":22010},
  {"type":"hysteria2","tag":"hy2","listen_port":22020}
]}
JSON
[ "$(get_uniform_inbound_port "$selector_file" reality)" = 22000 ] || \
    fail 'Reality selector did not recognize VLESS reality tags'
assert_ok update_public_inbound_port "$selector_file" reality 22001
[ "$(jq -r '[.inbounds[] | select(.tag | startswith("vless-reality")) | .listen_port] | unique | join(",")' "$selector_file")" = 22001 ] || \
    fail 'Reality port update missed a tagged VLESS inbound'
[ "$(jq -r '.inbounds[] | select(.tag == "vless-other") | .listen_port' "$selector_file")" = 22010 ] || \
    fail 'Reality port update changed an unrelated VLESS inbound'

# Client URL rewriting supports bracketed IPv6 authorities and migrates the
# HY2 mport listen-port prefix while preserving its hopping range.
ipv6_clients="${tmp_root}/ipv6-clients.txt"
cat > "$ipv6_clients" <<'EOF_CLIENTS'
vless://id@[2001:db8::10]:22000?flow=xtls-rprx-vision#reality
hysteria2://id@[2001:db8::11]:22020?insecure=1&mport=22020,50000-50100#hy2
tuic://id@[2001:db8::12]:22030?congestion_control=bbr#tuic
EOF_CLIENTS
assert_ok rewrite_public_client_port reality 22100 "$ipv6_clients"
assert_ok rewrite_public_client_port hysteria2 22120 "$ipv6_clients"
assert_ok rewrite_public_client_port tuic 22130 "$ipv6_clients"
assert_contains '@[2001:db8::10]:22100?' "$ipv6_clients" 'bracketed Reality IPv6 port was not rewritten'
assert_contains '@[2001:db8::11]:22120?' "$ipv6_clients" 'bracketed HY2 IPv6 port was not rewritten'
assert_contains 'mport=22120,50000-50100' "$ipv6_clients" 'HY2 mport listen port did not migrate'
assert_contains '@[2001:db8::12]:22130?' "$ipv6_clients" 'bracketed TUIC IPv6 port was not rewritten'

HY2_NAT_STATE_FILE="${tmp_root}/active-hy2.state"
printf '%s\n' \
    'iptables|SBHY2_4_ab_01|sb-hy2-SBHY2_4_ab_01|50000|50100|22020|created' \
    'ip6tables|SBHY2_6_cd_01|sb-hy2-SBHY2_6_cd_01|50000|50100|22020|created' > "$HY2_NAT_STATE_FILE"
assert_ok read_active_hy2_port_hopping 22020
[ "$HY2_ACTIVE_HOP_MIN,$HY2_ACTIVE_HOP_MAX,$HY2_ACTIVE_HOP_LISTEN" = '50000,50100,22020' ] || \
    fail 'valid active HY2 state was not parsed'
assert_status 2 read_active_hy2_port_hopping 22021
printf '%s\n' 'iptables|bad|record|with|extra|fields|created|injected' > "$HY2_NAT_STATE_FILE"
assert_status 2 read_active_hy2_port_hopping 22020
rm -f -- "$HY2_NAT_STATE_FILE"
HY2_NAT_STATE_FILE="${work_dir}/hy2-nat.state"

# Dynamic public-port changes open the new port first and remove the old owned
# rule only after config, service and subscription publication all succeed.
transaction_log="${tmp_root}/transaction.log"
client_dir="${tmp_root}/url.txt"
transaction_inbounds="${tmp_root}/transaction-inbounds.json"
reset_transaction_fixture() {
    command rm -f -- "${conf_dir}/.durable-transaction.pending"
    find "$tmp_root" -maxdepth 2 -type d -name '.durable-transaction.*' -exec rm -rf -- {} + 2>/dev/null || true
    cat > "$transaction_inbounds" <<'JSON'
{"inbounds":[
  {"type":"vless","tag":"vless-reality-ipv4","listen_port":22000},
  {"type":"hysteria2","tag":"hysteria2","listen_port":22020},
  {"type":"tuic","tag":"tuic","listen_port":22030}
]}
JSON
    cat > "$client_dir" <<'CLIENTS'
vless://id@[2001:db8::10]:22000?flow=xtls-rprx-vision#reality
hysteria2://id@[2001:db8::11]:22020?insecure=1&mport=22020,50000-50100#hy2
tuic://id@[2001:db8::12]:22030?congestion_control=bbr#tuic
CLIENTS
    rm -f -- "$HY2_NAT_STATE_FILE"
    : > "$transaction_log"
    CONFIG_FAIL=0
    SUBSCRIPTION_FAIL=0
    SUBSCRIPTION_STATUS=0
    PUBLIC_CLEANUP_STATUS=0
    PUBLIC_BACKUP_MODE_OK=1
    PUBLIC_PORT_RECOVERY_PATH=''
    MOCK_CONFLICT_PORT=''
    SERVICE_ACTIVE=1
    DURABLE_HOOK_LOG=0
    DURABLE_SIGNAL_STAGE=''
    REWRITE_AFTER_PUBLICATION=''
    reset_durable_transaction_state
}
validate_singbox_config() { [ "${CONFIG_FAIL:-0}" = 0 ]; }
get_nginx_subscription_port() {
    [ -n "${MOCK_SUBSCRIPTION_PORT:-}" ] || return 1
    printf '%s\n' "$MOCK_SUBSCRIPTION_PORT"
}
port_is_listening() { [ -n "${MOCK_CONFLICT_PORT:-}" ] && [ "$MOCK_CONFLICT_PORT" = "$1" ]; }

# Public port changes use transport-aware conflicts so a port-limited NAT VPS
# can reuse one numeric port across TCP and UDP, but never within one transport.
conflict_inbounds="${tmp_root}/public-port-conflicts.json"
cat > "$conflict_inbounds" <<'JSON'
{"inbounds":[
  {"type":"vless","tag":"vless-reality","listen_port":22000},
  {"type":"hysteria2","tag":"hysteria2","listen_port":22020},
  {"type":"tuic","tag":"tuic","listen_port":22030},
  {"type":"anytls","tag":"anytls","listen_port":22040}
]}
JSON
MOCK_CONFLICT_PORT=''
MOCK_SUBSCRIPTION_PORT=''
assert_status 1 public_port_conflicts "$conflict_inbounds" reality 22020 tcp
assert_status 1 public_port_conflicts "$conflict_inbounds" hysteria2 22000 udp
assert_ok public_port_conflicts "$conflict_inbounds" reality 22040 tcp
assert_ok public_port_conflicts "$conflict_inbounds" hysteria2 22030 udp
MOCK_SUBSCRIPTION_PORT=22050
assert_status 1 public_port_conflicts "$conflict_inbounds" hysteria2 22050 udp
assert_ok public_port_conflicts "$conflict_inbounds" reality 22050 tcp
MOCK_SUBSCRIPTION_PORT=''

allow_port() {
    local backup_candidate
    [ "$(get_uniform_inbound_port "$transaction_inbounds" "$MOCK_PROTOCOL")" = "$MOCK_OLD_PORT" ] || \
        fail 'firewall was opened after config mutation instead of before it'
    backup_candidate=$(find "$(dirname "$client_dir")" -maxdepth 1 -name '.port-client-backup.*' -print -quit)
    if [ -n "$backup_candidate" ] && [ "$(stat -c '%a' "$backup_candidate")" != 600 ]; then
        PUBLIC_BACKUP_MODE_OK=0
    fi
    printf 'allow:%s\n' "$1" >> "$transaction_log"
    [ "${ALLOW_STATUS:-0}" = 0 ] || return "$ALLOW_STATUS"
    FIREWALL_LAST_ADDED_RECORDS=("${MOCK_ALLOW_RECORDS[@]}")
}
restart_singbox() {
    local current_port
    current_port=$(get_uniform_inbound_port "$transaction_inbounds" "$MOCK_PROTOCOL") || return 1
    printf 'restart:%s\n' "$current_port" >> "$transaction_log"
    SERVICE_ACTIVE=1
}
singbox_service_is_active() { [ "$SERVICE_ACTIVE" -eq 1 ]; }
stop_singbox_checked() {
    printf 'stop-singbox\n' >> "$transaction_log"
    SERVICE_ACTIVE=0
}
durable_transaction_hook() {
    if [ -n "$DURABLE_SIGNAL_STAGE" ] && [ "$DURABLE_SIGNAL_STAGE" = "$1" ]; then
        kill -TERM "$BASHPID"
    fi
    [ "$DURABLE_HOOK_LOG" -eq 1 ] || return 0
    printf 'durable:%s\n' "$1" >> "$transaction_log"
}
add_hy2_port_hopping() {
    printf 'nat:%s-%s:%s\n' "$1" "$2" "$3" >> "$transaction_log"
    [ "${HY2_NAT_FAIL_PORT:-}" != "$3" ]
}
update_sub() {
    local current_port scheme publication_status
    current_port=$(get_uniform_inbound_port "$transaction_inbounds" "$MOCK_PROTOCOL") || return 1
    case "$MOCK_PROTOCOL" in
        reality) scheme=vless ;;
        hysteria2) scheme=hysteria2 ;;
        tuic) scheme=tuic ;;
    esac
    grep -Eq "^${scheme}://.*:${current_port}[?]" "$client_dir" || \
        fail 'subscription publication ran before the client URL was rewritten'
    printf 'subscription:%s\n' "$current_port" >> "$transaction_log"
    if [ -n "$REWRITE_AFTER_PUBLICATION" ]; then
        update_public_inbound_port "$transaction_inbounds" "$MOCK_PROTOCOL" \
            "$REWRITE_AFTER_PUBLICATION" || return 1
    fi
    [ "${SUBSCRIPTION_FAIL:-0}" = 0 ] || return 1
    publication_status="${SUBSCRIPTION_STATUS:-0}"
    SUBSCRIPTION_STATUS=0
    [ "$publication_status" = 0 ] || return "$publication_status"
}
remove_owned_firewall_port() { printf 'remove:%s\n' "$1" >> "$transaction_log"; }
remove_owned_firewall_records_exact() { printf 'remove-record:%s\n' "$1" >> "$transaction_log"; }
cleanup_public_port_backup() {
    [ "$PUBLIC_CLEANUP_STATUS" -eq 0 ] || return "$PUBLIC_CLEANUP_STATUS"
    command rm -f -- "$1"
}

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
MOCK_ALLOW_RECORDS=('ufw|4|23000|tcp')
assert_ok change_public_inbound_port_transaction "$transaction_inbounds" reality 23000 tcp
expected_order=$'allow:23000/tcp\nrestart:23000\nsubscription:23000\nremove:22000/tcp'
[ "$(cat "$transaction_log")" = "$expected_order" ] || fail 'dynamic port transaction order is unsafe'
[ "$(get_uniform_inbound_port "$transaction_inbounds" reality)" = 23000 ] || fail 'Reality config did not commit'
assert_contains '@[2001:db8::10]:23000?' "$client_dir" 'Reality client URL did not commit'
[ "$PUBLIC_BACKUP_MODE_OK" -eq 1 ] || fail 'public-port client backup was not mode 0600'

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
MOCK_ALLOW_RECORDS=('ufw|4|23010|tcp')
SERVICE_ACTIVE=0
assert_ok change_public_inbound_port_transaction "$transaction_inbounds" reality 23010 tcp
[ "$SERVICE_ACTIVE" -eq 0 ] || fail 'successful public-port change started an initially inactive sing-box service'
assert_not_contains 'restart:' "$transaction_log" 'inactive public-port success restarted sing-box'
[ "$(get_uniform_inbound_port "$transaction_inbounds" reality)" = 23010 ] || \
    fail 'inactive public-port success did not commit its config'

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
MOCK_ALLOW_RECORDS=('ufw|4|23011|tcp')
SERVICE_ACTIVE=0
SUBSCRIPTION_FAIL=1
assert_fail change_public_inbound_port_transaction "$transaction_inbounds" reality 23011 tcp
[ "$SERVICE_ACTIVE" -eq 0 ] || fail 'failed public-port rollback started an initially inactive sing-box service'
assert_not_contains 'restart:' "$transaction_log" 'inactive public-port rollback restarted sing-box'
[ "$(get_uniform_inbound_port "$transaction_inbounds" reality)" = 22000 ] || \
    fail 'inactive public-port rollback did not restore the old config'

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
MOCK_ALLOW_RECORDS=('ufw|4|23012|tcp')
DURABLE_HOOK_LOG=1
assert_ok change_public_inbound_port_transaction "$transaction_inbounds" reality 23012 tcp
public_durable_stages="$(grep '^durable:' "$transaction_log")"
[ "$public_durable_stages" = $'durable:firewall-mutating\ndurable:precommit\ndurable:config-mutated\ndurable:publishing\ndurable:committed' ] || \
    fail "public-port durable checkpoints are incomplete or unsafe: ${public_durable_stages}"

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
MOCK_ALLOW_RECORDS=('ufw|4|23013|tcp')
DURABLE_SIGNAL_STAGE=config-mutated
signal_status=0
( trap - EXIT; change_public_inbound_port_transaction "$transaction_inbounds" reality 23013 tcp ) || \
    signal_status=$?
[ "$signal_status" -eq 143 ] || fail "config-mutated TERM returned ${signal_status}, expected 143"
[ "$(get_uniform_inbound_port "$transaction_inbounds" reality)" = 22000 ] || \
    fail 'TERM after config mutation did not restore the old public port'
assert_contains 'remove-record:ufw|4|23013|tcp' "$transaction_log" \
    'TERM after config mutation leaked the new firewall ownership record'

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
MOCK_ALLOW_RECORDS=('ufw|4|23014|tcp')
REWRITE_AFTER_PUBLICATION=23999
assert_status 2 change_public_inbound_port_transaction "$transaction_inbounds" reality 23014 tcp
[ "${DURABLE_TX_ACTIVE:-0}" -eq 0 ] || fail 'generation mismatch leaked armed durable transaction state'
[ -d "$PUBLIC_PORT_RECOVERY_PATH" ] || fail 'generation mismatch did not preserve durable evidence'
exec {recheck_fd}>"${conf_dir}/.proxy-transaction.lock"
flock -n "$recheck_fd" || fail 'generation mismatch leaked the underlying common config lock'
flock -u "$recheck_fd"
exec {recheck_fd}>&-
command rm -f -- "${conf_dir}/.durable-transaction.pending"
command rm -rf -- "$PUBLIC_PORT_RECOVERY_PATH"

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
MOCK_ALLOW_RECORDS=('ufw|4|23009|tcp')
PUBLIC_CLEANUP_STATUS=1
assert_status 3 change_public_inbound_port_transaction "$transaction_inbounds" reality 23009 tcp
[ -d "$PUBLIC_PORT_RECOVERY_PATH" ] || fail 'healthy public-port cleanup residue did not expose its durable evidence path'
[ "$(get_uniform_inbound_port "$transaction_inbounds" reality)" = 23009 ] || \
    fail 'backup residue incorrectly rolled back a healthy public-port change'

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
SUBSCRIPTION_FAIL=1
MOCK_ALLOW_RECORDS=('ufw|4|23001|tcp')
assert_fail change_public_inbound_port_transaction "$transaction_inbounds" reality 23001 tcp
assert_not_contains 'remove:22000/tcp' "$transaction_log" 'old firewall rule was removed after publication failed'
assert_contains 'remove-record:ufw|4|23001|tcp' "$transaction_log" 'new ownership token was not rolled back after publication failed'
[ "$(get_uniform_inbound_port "$transaction_inbounds" reality)" = 22000 ] || fail 'failed Reality config was not restored'
assert_contains '@[2001:db8::10]:22000?' "$client_dir" 'failed Reality client URL was not restored'

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
SUBSCRIPTION_STATUS=3
MOCK_ALLOW_RECORDS=('ufw|4|23007|tcp')
assert_status 3 change_public_inbound_port_transaction "$transaction_inbounds" reality 23007 tcp
assert_contains 'remove-record:ufw|4|23007|tcp' "$transaction_log" 'generation-conflict port change leaked new firewall ownership'
[ "$(get_uniform_inbound_port "$transaction_inbounds" reality)" = 22000 ] || \
    fail 'generation-conflict public port change did not restore config'

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
SUBSCRIPTION_STATUS=2
MOCK_ALLOW_RECORDS=('ufw|4|23008|tcp')
assert_status 1 change_public_inbound_port_transaction "$transaction_inbounds" reality 23008 tcp
assert_contains 'remove-record:ufw|4|23008|tcp' "$transaction_log" 'fully rolled-back fatal port change leaked ownership'
[ "$(get_uniform_inbound_port "$transaction_inbounds" reality)" = 22000 ] || \
    fail 'fully rolled-back fatal public port change did not restore config'

# A port that was already owned/pre-existing has an empty token; a later
# config failure must not delete that shared rule.
reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
MOCK_ALLOW_RECORDS=()
CONFIG_FAIL=1
assert_fail change_public_inbound_port_transaction "$transaction_inbounds" reality 23002 tcp
assert_not_contains 'remove-record:' "$transaction_log" 'pre-existing/newly shared firewall ownership was deleted on rollback'
assert_not_contains 'remove:23002/tcp' "$transaction_log" 'pre-existing port was removed by broad rollback'

# Conflicting inbound/subscription ports are rejected before the firewall is
# touched.
reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
MOCK_CONFLICT_PORT=23003
assert_fail change_public_inbound_port_transaction "$transaction_inbounds" reality 23003 tcp
assert_not_contains 'allow:23003/tcp' "$transaction_log" 'conflicting port reached firewall mutation'

reset_transaction_fixture
MOCK_PROTOCOL=reality
MOCK_OLD_PORT=22000
ALLOW_STATUS=2
assert_status 2 change_public_inbound_port_transaction "$transaction_inbounds" reality 23004 tcp
assert_not_contains 'restart:23004' "$transaction_log" 'configuration changed after fatal firewall failure'
[ -d "$PUBLIC_PORT_RECOVERY_PATH" ] || \
    fail 'fatal firewall failure did not preserve public-port recovery evidence'
[ -f "${conf_dir}/.durable-transaction.pending" ] || \
    fail 'fatal firewall failure removed the pending durable registry'
assert_status 2 acquire_proxy_transaction_lock "${conf_dir}"
unset ALLOW_STATUS

# An active HY2 hopping configuration migrates its DNAT destination together
# with the public listen port.  Publication failure restores both NAT and the
# old config before releasing the transaction.
reset_transaction_fixture
MOCK_PROTOCOL=hysteria2
MOCK_OLD_PORT=22020
printf '%s\n' 'iptables|SBHY2_4_ab_01|sb-hy2-SBHY2_4_ab_01|50000|50100|22020|created' > "$HY2_NAT_STATE_FILE"
MOCK_ALLOW_RECORDS=('ufw|4|23005|udp')
assert_ok change_public_inbound_port_transaction "$transaction_inbounds" hysteria2 23005 udp
expected_order=$'allow:23005/udp\nnat:50000-50100:23005\nrestart:23005\nsubscription:23005\nremove:22020/udp'
[ "$(cat "$transaction_log")" = "$expected_order" ] || fail 'active HY2 NAT was not migrated transactionally'
assert_contains 'mport=23005,50000-50100' "$client_dir" 'active HY2 mport did not migrate with DNAT'

reset_transaction_fixture
MOCK_PROTOCOL=hysteria2
MOCK_OLD_PORT=22020
printf '%s\n' 'iptables|SBHY2_4_ab_01|sb-hy2-SBHY2_4_ab_01|50000|50100|22020|created' > "$HY2_NAT_STATE_FILE"
SUBSCRIPTION_FAIL=1
MOCK_ALLOW_RECORDS=('ufw|4|23006|udp')
assert_fail change_public_inbound_port_transaction "$transaction_inbounds" hysteria2 23006 udp
assert_contains 'nat:50000-50100:23006' "$transaction_log" 'new HY2 DNAT destination was not attempted'
assert_contains 'restart:22020' "$transaction_log" 'HY2 config was not restored after publication failure'
assert_contains 'nat:50000-50100:22020' "$transaction_log" 'old HY2 DNAT destination was not restored'
assert_contains 'remove-record:ufw|4|23006|udp' "$transaction_log" 'failed HY2 change leaked new firewall ownership'
assert_contains 'mport=22020,50000-50100' "$client_dir" 'failed HY2 mport change was not restored'

# The public-port transaction uses its own whole-operation lock.  It must not
# hold/re-enter the firewall lock while waiting, and concurrent transactions
# cannot overlap their config/firewall/subscription sequence.
reset_transaction_fixture
serial_log="${tmp_root}/serial.log"
: > "$serial_log"
_change_public_inbound_port_transaction_locked() {
    printf 'start:%s\n' "$3" >> "$serial_log"
    sleep 0.1
    printf 'end:%s\n' "$3" >> "$serial_log"
}
( change_public_inbound_port_transaction ignored reality 23100 tcp ) & serial_first=$!
( change_public_inbound_port_transaction ignored reality 23101 tcp ) & serial_second=$!
wait "$serial_first" || fail 'first serialized public-port transaction failed'
wait "$serial_second" || fail 'second serialized public-port transaction failed'
serial_contents="$(cat "$serial_log")"
case "$serial_contents" in
    $'start:23100\nend:23100\nstart:23101\nend:23101'|\
    $'start:23101\nend:23101\nstart:23100\nend:23100') ;;
    *) fail 'public-port transactions overlapped instead of serializing' ;;
esac
[ "$(stat -c '%a' "${conf_dir}/.proxy-transaction.lock")" = 600 ] || \
    fail 'shared config transaction lock is not mode 0600'

# Public inbound, Nginx subscription and extra-protocol mutations share the
# same config lock, so consumers are always scanned against a stable config.
cross_entry_log="${tmp_root}/cross-entry.log"
: > "$cross_entry_log"
_change_public_inbound_port_transaction_locked() {
    printf 'start:public\n' >> "$cross_entry_log"
    sleep 0.1
    printf 'end:public\n' >> "$cross_entry_log"
}
_change_subscription_port_transaction_locked() {
    printf 'start:subscription\n' >> "$cross_entry_log"
    sleep 0.1
    printf 'end:subscription\n' >> "$cross_entry_log"
}
_add_extra_protocol_transaction_locked() {
    printf 'start:extra\n' >> "$cross_entry_log"
    sleep 0.1
    printf 'end:extra\n' >> "$cross_entry_log"
}
_enable_hy2_port_hopping_transaction_locked() {
    printf 'start:hy2-enable\n' >> "$cross_entry_log"
    sleep 0.1
    printf 'end:hy2-enable\n' >> "$cross_entry_log"
}
_disable_hy2_port_hopping_transaction_locked() {
    printf 'start:hy2-disable\n' >> "$cross_entry_log"
    sleep 0.1
    printf 'end:hy2-disable\n' >> "$cross_entry_log"
}
_stop_subscription_service_locked() {
    printf 'start:subscription-stop\n' >> "$cross_entry_log"
    sleep 0.1
    printf 'end:subscription-stop\n' >> "$cross_entry_log"
}
_start_subscription_service_locked() {
    printf 'start:subscription-start\n' >> "$cross_entry_log"
    sleep 0.1
    printf 'end:subscription-start\n' >> "$cross_entry_log"
}
_restart_subscription_service_locked() {
    printf 'start:subscription-restart\n' >> "$cross_entry_log"
    sleep 0.1
    printf 'end:subscription-restart\n' >> "$cross_entry_log"
}
( change_public_inbound_port_transaction ignored reality 23110 tcp ) & cross_public=$!
( change_subscription_port_transaction ignored 23111 /token '' ) & cross_subscription=$!
( add_extra_protocol_transaction ignored client callback --families 1 0 23112/tcp -- tag ) & cross_extra=$!
( enable_hy2_port_hopping_transaction 50000 50100 ) & cross_hy2_enable=$!
( disable_hy2_port_hopping_transaction ) & cross_hy2_disable=$!
( stop_subscription_service_transaction ) & cross_sub_stop=$!
( start_subscription_service_transaction ) & cross_sub_start=$!
( restart_subscription_service_transaction ) & cross_sub_restart=$!
wait "$cross_public" || fail 'cross-entry public transaction failed'
wait "$cross_subscription" || fail 'cross-entry subscription transaction failed'
wait "$cross_extra" || fail 'cross-entry extra transaction failed'
wait "$cross_hy2_enable" || fail 'cross-entry HY2 enable transaction failed'
wait "$cross_hy2_disable" || fail 'cross-entry HY2 disable transaction failed'
wait "$cross_sub_stop" || fail 'cross-entry subscription stop failed'
wait "$cross_sub_start" || fail 'cross-entry subscription start failed'
wait "$cross_sub_restart" || fail 'cross-entry subscription restart failed'
awk '
    /^start:/ { if (active) exit 1; active=substr($0, 7); next }
    /^end:/   { if (!active || substr($0, 5) != active) exit 1; active=""; next }
    END       { if (active) exit 1 }
' "$cross_entry_log" || fail 'public/subscription/extra config transactions overlapped'

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
    apply_proxy_config_transaction \
    add_extra_protocol_transaction \
    remove_extra_protocol_transaction; do
    wrapper_source="$(extract_function "$wrapper")"
    grep -Eq 'acquire_(public_port_change|proxy_transaction)_lock(_checked)?' <<< "$wrapper_source" || \
        fail "${wrapper} bypasses the common config lock"
    if grep -Eq 'acquire_(public_port_change|proxy_transaction)_lock(_checked)?[^;]*(\|\| return 1|\|\| \{)' <<< "$wrapper_source"; then
        fail "${wrapper} collapses pending durable rc 2 into busy rc 1"
    fi
    grep -Fq 'release_proxy_transaction_lock' <<< "$wrapper_source" || \
        grep -Fq 'release_public_port_change_lock' <<< "$wrapper_source" || \
        fail "${wrapper} does not release the common config lock"
done

# Busy is rc 1, while pending/damaged durable state and unknown lock failures
# are fail-closed rc 2.
LOCK_RESULT=0
acquire_proxy_transaction_lock() { return "$LOCK_RESULT"; }
red() { :; }
LOCK_RESULT=0
assert_ok acquire_proxy_transaction_lock_checked "$conf_dir" test-operation
LOCK_RESULT=1
assert_status 1 acquire_proxy_transaction_lock_checked "$conf_dir" test-operation
LOCK_RESULT=2
assert_status 2 acquire_proxy_transaction_lock_checked "$conf_dir" test-operation
LOCK_RESULT=9
assert_status 2 acquire_proxy_transaction_lock_checked "$conf_dir" test-operation

printf 'Firewall ownership tests passed.\n'
