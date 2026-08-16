#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

nat_block=$(sed -n '/^configure_hy2_nat_family() {/,/^render_vless_reality_inbound() {/p' "$script" | sed '$d')
[[ -n "$nat_block" ]] || fail 'HY2 NAT helper block could not be extracted'
source /dev/stdin <<< "$nat_block"
validate_port_source=$(sed -n '/^validate_port_value() {/,/^}/p' "$script")
[[ -n "$validate_port_source" ]] || fail 'port validation helper could not be extracted'
source /dev/stdin <<< "$validate_port_source"

work_dir="$tmp_root/work"
client_dir="$work_dir/url.txt"
combined_client_dir="$work_dir/all-url.txt"
conf_dir="$work_dir/conf"
HY2_NAT_STATE_FILE="$work_dir/hy2-nat.state"
mkdir -p "$work_dir" "$conf_dir"

HAS_IPV4=1
HAS_IPV6=1
HAS_IPTABLES_COMMAND=1
HAS_IP6TABLES_COMMAND=1
ipv4_stack_available() { [[ "$HAS_IPV4" == 1 ]]; }
ipv6_stack_available() { [[ "$HAS_IPV6" == 1 ]]; }
command_exists() {
    case "${1:-}" in
        iptables) [[ "$HAS_IPTABLES_COMMAND" == 1 ]] ;;
        ip6tables) [[ "$HAS_IP6TABLES_COMMAND" == 1 ]] ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}

nat_state="$tmp_root/firewall.state"
nat_log="$tmp_root/firewall.log"
FAIL_TOOL=''
FAIL_OP=''
FAIL_MATCH=''
FAIL_REMAINING=0

reset_firewall() {
    : > "$nat_state"
    : > "$nat_log"
    rm -f -- "$HY2_NAT_STATE_FILE"
    FAIL_TOOL=''
    FAIL_OP=''
    FAIL_MATCH=''
    FAIL_REMAINING=0
    HAS_IPV4=1
    HAS_IPV6=1
    HAS_IPTABLES_COMMAND=1
    HAS_IP6TABLES_COMMAND=1
}

add_chain() {
    printf 'CHAIN|%s|%s\n' "$1" "$2" >> "$nat_state"
}

add_rule() {
    printf 'RULE|%s|%s|%s\n' "$1" "$2" "$3" >> "$nat_state"
}

firewall_snapshot() {
    LC_ALL=C sort "$nat_state"
}

maybe_fail_firewall() {
    local tool="$1" op="$2" joined="$3"
    [[ "$FAIL_REMAINING" -gt 0 ]] || return 1
    [[ -z "$FAIL_TOOL" || "$FAIL_TOOL" == "$tool" ]] || return 1
    [[ -z "$FAIL_OP" || "$FAIL_OP" == "$op" ]] || return 1
    [[ -z "$FAIL_MATCH" || "$joined" == *"$FAIL_MATCH"* ]] || return 1
    FAIL_REMAINING=$((FAIL_REMAINING - 1))
    return 0
}

mock_iptables() {
    local tool="$1"
    shift
    local -a args=("$@")
    local op='' chain='' spec='' joined="$*" i
    printf '%s %s\n' "$tool" "$joined" >> "$nat_log"

    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[$i]}" in
            -N|-A|-C|-D|-F|-X|-S)
                op="${args[$i]}"
                chain="${args[$((i + 1))]:-}"
                spec="${args[*]:$((i + 2))}"
                break
                ;;
        esac
    done
    [[ -n "$op" && -n "$chain" ]] || return 2
    maybe_fail_firewall "$tool" "$op" "$joined" && return 1

    case "$op" in
        -N)
            grep -Fxq "CHAIN|$tool|$chain" "$nat_state" 2>/dev/null && return 1
            add_chain "$tool" "$chain"
            ;;
        -A)
            grep -Fxq "CHAIN|$tool|$chain" "$nat_state" 2>/dev/null || return 1
            add_rule "$tool" "$chain" "$spec"
            ;;
        -C)
            grep -Fxq "RULE|$tool|$chain|$spec" "$nat_state" 2>/dev/null
            ;;
        -D)
            local target="RULE|$tool|$chain|$spec"
            grep -Fxq "$target" "$nat_state" 2>/dev/null || return 1
            awk -v target="$target" '!removed && $0 == target { removed=1; next } { print }' \
                "$nat_state" > "$nat_state.tmp"
            mv -f "$nat_state.tmp" "$nat_state"
            ;;
        -F)
            awk -F'|' -v tool="$tool" -v chain="$chain" \
                '!( $1 == "RULE" && $2 == tool && $3 == chain )' "$nat_state" > "$nat_state.tmp"
            mv -f "$nat_state.tmp" "$nat_state"
            ;;
        -X)
            grep -Fxq "CHAIN|$tool|$chain" "$nat_state" 2>/dev/null || return 1
            ! grep -Fq "RULE|$tool|$chain|" "$nat_state" || return 1
            ! awk -F'|' -v tool="$tool" -v chain="$chain" \
                '$1 == "RULE" && $2 == tool && $4 ~ ("(^| )-j " chain "($| )") { found=1 } END { exit !found }' \
                "$nat_state" || return 1
            awk -v target="CHAIN|$tool|$chain" '$0 != target' "$nat_state" > "$nat_state.tmp"
            mv -f "$nat_state.tmp" "$nat_state"
            ;;
        -S)
            grep -Fxq "CHAIN|$tool|$chain" "$nat_state" 2>/dev/null || return 1
            printf '%s\n' "-N $chain"
            awk -F'|' -v tool="$tool" -v chain="$chain" \
                '$1 == "RULE" && $2 == tool && $3 == chain { print "-A " chain " " $4 }' "$nat_state"
            ;;
    esac
}

iptables() { mock_iptables iptables "$@"; }
ip6tables() { mock_iptables ip6tables "$@"; }
PERSIST_FAILURES=0
PERSIST_CALLS=0
persist_hy2_nat_rules() {
    PERSIST_CALLS=$((PERSIST_CALLS + 1))
    if [[ "$PERSIST_FAILURES" -gt 0 ]]; then
        PERSIST_FAILURES=$((PERSIST_FAILURES - 1))
        return 1
    fi
}

prepare_empty_firewall() {
    reset_firewall
    add_chain iptables PREROUTING
    add_chain ip6tables PREROUTING
    PERSIST_FAILURES=0
    PERSIST_CALLS=0
}

assert_no_owned_firewall_state() {
    local description="$1"
    if grep -Eq 'SBHY2_|sb-hy2-' "$nat_state"; then
        fail "$description left a generated chain or rule"
    fi
    [[ ! -e "$HY2_NAT_STATE_FILE" ]] || fail "$description left ownership state"
}

# RED 1: an administrator-owned PRENET_HY2 chain must never be adopted or changed.
reset_firewall
add_chain iptables PREROUTING
add_chain iptables PRENET_HY2
add_rule iptables PRENET_HY2 '-p tcp --dport 443 -j ACCEPT'
add_chain ip6tables PREROUTING
add_chain ip6tables PRENET_HY2
add_rule ip6tables PRENET_HY2 '-p udp --dport 53000:53100 -j ACCEPT'
external_before=$(firewall_snapshot)

add_hy2_port_hopping 50000 50100 8443 || fail 'HY2 add failed while safe unique chains were available'
grep -Fxq 'RULE|iptables|PRENET_HY2|-p tcp --dport 443 -j ACCEPT' "$nat_state" || \
    fail 'IPv4 administrator rule was changed during HY2 add'
grep -Fxq 'RULE|ip6tables|PRENET_HY2|-p udp --dport 53000:53100 -j ACCEPT' "$nat_state" || \
    fail 'IPv6 administrator rule was changed during HY2 add'
[[ -f "$HY2_NAT_STATE_FILE" ]] || fail 'HY2 ownership state was not persisted'
if grep -Fq '|PRENET_HY2|' "$HY2_NAT_STATE_FILE"; then
    fail 'administrator-owned PRENET_HY2 was recorded as script-owned'
fi
if [[ "$(uname -s)" != MINGW* ]]; then
    [[ "$(stat -c '%a' "$HY2_NAT_STATE_FILE")" == 600 ]] || fail 'HY2 ownership state is not mode 600'
else
    grep -Fq 'chmod 600 "$state_file"' <<< "$nat_block" || \
        fail 'HY2 ownership state does not request mode 600 on POSIX hosts'
fi

remove_hy2_port_hopping || fail 'HY2 remove failed for owned unique chains'
[[ "$(firewall_snapshot)" == "$external_before" ]] || \
    fail 'HY2 remove changed administrator-owned chains or rules'

# RED 2: the exact shape produced by the legacy script is safe to adopt.
reset_firewall
for family in iptables ip6tables; do
    add_chain "$family" PREROUTING
    add_chain "$family" PRENET_HY2
    add_rule "$family" PRENET_HY2 \
        '-p udp --dport 52000:52100 -m comment --comment prenet-hy2 -j DNAT --to-destination :9443'
    add_rule "$family" PREROUTING \
        '-p udp -m comment --comment prenet-hy2 -j PRENET_HY2'
done
legacy_before=$(firewall_snapshot)
add_hy2_port_hopping 52000 52100 9443 || fail 'exact legacy HY2 rules were not adopted'
[[ "$(firewall_snapshot)" == "$legacy_before" ]] || fail 'legacy adoption changed live firewall rules'
[[ "$(grep -Fc '|PRENET_HY2|prenet-hy2|52000|52100|9443' "$HY2_NAT_STATE_FILE")" -eq 2 ]] || \
    fail 'exact legacy rules were not recorded as adopted ownership'
remove_hy2_port_hopping || fail 'adopted legacy HY2 rules could not be removed'
if grep -Eq 'PRENET_HY2|prenet-hy2' "$nat_state"; then
    fail 'adopted legacy HY2 resources remained after removal'
fi

# RED 3: every append and cross-family failure rolls back only this attempt.
for failure_case in dnat jump; do
    prepare_empty_firewall
    FAIL_TOOL=iptables
    FAIL_OP=-A
    FAIL_REMAINING=1
    if [[ "$failure_case" == dnat ]]; then
        FAIL_MATCH='--dport 53000:53100'
    else
        FAIL_MATCH='PREROUTING'
    fi
    if add_hy2_port_hopping 53000 53100 10443; then
        fail "$failure_case append failure was reported as success"
    fi
    assert_no_owned_firewall_state "$failure_case append failure"
done

prepare_empty_firewall
FAIL_TOOL=ip6tables
FAIL_OP=-A
FAIL_MATCH='--dport 53100:53200'
FAIL_REMAINING=1
if add_hy2_port_hopping 53100 53200 10443; then
    fail 'IPv6 partial configuration failure was reported as success'
fi
assert_no_owned_firewall_state 'IPv6 partial configuration failure'

prepare_empty_firewall
original_state_writer=$(declare -f write_hy2_nat_state_records)
write_hy2_nat_state_records() { return 1; }
if add_hy2_port_hopping 53200 53300 10443; then
    fail 'ownership-state persistence failure was reported as success'
fi
eval "$original_state_writer"
assert_no_owned_firewall_state 'ownership-state persistence failure'

prepare_empty_firewall
PERSIST_FAILURES=1
if add_hy2_port_hopping 53300 53400 10443; then
    fail 'firewall persistence failure was reported as success'
fi
assert_no_owned_firewall_state 'firewall persistence failure'

# RED 4: range changes are replace transactions, not stacked rules.
prepare_empty_firewall
add_hy2_port_hopping 54000 54100 11443 || fail 'initial HY2 range could not be added'
old_nat_snapshot=$(firewall_snapshot)
old_owner_snapshot=$(<"$HY2_NAT_STATE_FILE")
PERSIST_FAILURES=1
if add_hy2_port_hopping 54200 54300 11443; then
    fail 'changed range succeeded despite persistence failure'
fi
[[ "$(firewall_snapshot)" == "$old_nat_snapshot" ]] || \
    fail 'failed range replacement did not preserve the old live rules exactly'
[[ "$(<"$HY2_NAT_STATE_FILE")" == "$old_owner_snapshot" ]] || \
    fail 'failed range replacement changed ownership state'

add_hy2_port_hopping 54200 54300 11443 || fail 'changed HY2 range was not transactionally replaced'
[[ "$(grep -Fc -- '--dport 54200:54300' "$nat_state")" -eq 2 ]] || \
    fail 'replacement range is not unique per address family'
if grep -Fq -- '--dport 54000:54100' "$nat_state"; then
    fail 'old HY2 range remained stacked after replacement'
fi

# RED 5: remove failure keeps both the old live rules and ownership state.
remove_before_nat=$(firewall_snapshot)
remove_before_owner=$(<"$HY2_NAT_STATE_FILE")
FAIL_TOOL=iptables
FAIL_OP=-D
FAIL_MATCH='--dport 54200:54300'
FAIL_REMAINING=1
if remove_hy2_port_hopping; then
    fail 'partial HY2 remove failure was reported as success'
fi
[[ "$(firewall_snapshot)" == "$remove_before_nat" ]] || \
    fail 'partial HY2 remove failure did not restore live rules exactly'
[[ "$(<"$HY2_NAT_STATE_FILE")" == "$remove_before_owner" ]] || \
    fail 'partial HY2 remove failure changed ownership state'

FAIL_TOOL=''
FAIL_OP=''
FAIL_MATCH=''
FAIL_REMAINING=0
PERSIST_FAILURES=1
if remove_hy2_port_hopping; then
    fail 'HY2 remove succeeded despite firewall persistence failure'
fi
[[ "$(firewall_snapshot)" == "$remove_before_nat" ]] || \
    fail 'remove persistence failure did not restore live rules exactly'
[[ "$(<"$HY2_NAT_STATE_FILE")" == "$remove_before_owner" ]] || \
    fail 'remove persistence failure changed ownership state'

# Existing single-stack support remains scoped to the available family.
prepare_empty_firewall
HAS_IPV6=0
HAS_IP6TABLES_COMMAND=0
add_hy2_port_hopping 55000 55100 12443 || fail 'IPv4-only HY2 add failed'
[[ "$(wc -l < "$HY2_NAT_STATE_FILE" | tr -d ' ')" -eq 1 ]] || \
    fail 'IPv4-only HY2 add persisted an unavailable family'
if grep -q '^ip6tables ' "$nat_log"; then
    fail 'IPv4-only HY2 add invoked ip6tables'
fi
remove_hy2_port_hopping || fail 'IPv4-only HY2 remove failed'

# RED 6: menu-facing helpers stage first and roll back every committed surface.
for helper_name in \
    stage_hy2_client_file \
    enable_hy2_port_hopping_transaction \
    disable_hy2_port_hopping_transaction; do
    declare -F "$helper_name" >/dev/null || fail "$helper_name is not implemented"
done

SERVICE_ACTIVE=1
RESTART_FAILURES=0
UPDATE_SUB_FAILURES=0
ATOMIC_CLIENT_FAILURES=0
RESTART_CALLS=0

singbox_service_is_active() { [[ "$SERVICE_ACTIVE" == 1 ]]; }
restart_singbox() {
    RESTART_CALLS=$((RESTART_CALLS + 1))
    if [[ "$RESTART_FAILURES" -gt 0 ]]; then
        RESTART_FAILURES=$((RESTART_FAILURES - 1))
        return 1
    fi
    SERVICE_ACTIVE=1
}
stop_singbox() { SERVICE_ACTIVE=0; }
get_uniform_inbound_port() { printf '%s\n' 12443; }
get_realip() { printf '%s\n' '203.0.113.10'; }
get_hy2_certificate_fingerprint() { printf '%s\n' 'AA%3ABB%3ACC'; }
get_hy2_node_label() { printf '%s\n' 'CN-Test_ISP'; }
atomic_replace_hy2_client() {
    if [[ "$ATOMIC_CLIENT_FAILURES" -gt 0 ]]; then
        ATOMIC_CLIENT_FAILURES=$((ATOMIC_CLIENT_FAILURES - 1))
        return 1
    fi
    mv -f -- "$1" "$2"
}
update_sub() {
    printf '%s\n' broken-publication > "$work_dir/base-sub.txt"
    if [[ "$UPDATE_SUB_FAILURES" -gt 0 ]]; then
        UPDATE_SUB_FAILURES=$((UPDATE_SUB_FAILURES - 1))
        return 1
    fi
    cp -- "$client_dir" "$work_dir/base-sub.txt"
    cp -- "$client_dir" "$combined_client_dir"
    cp -- "$client_dir" "$work_dir/all-sub.txt"
    cp -- "$client_dir" "$work_dir/sub.txt"
}

prepare_menu_fixture() {
    prepare_empty_firewall
    add_hy2_port_hopping 56000 56100 12443 || fail 'menu fixture NAT setup failed'
    printf '%s\n' \
        'vless://unchanged' \
        'hysteria2://11111111-2222-3333-4444-555555555555@198.51.100.1:12443?peer=www.bing.com&insecure=1&mport=12443,56000-56100#old' \
        'tuic://unchanged' > "$client_dir"
    local path
    for path in "$work_dir/base-sub.txt" "$combined_client_dir" "$work_dir/all-sub.txt" "$work_dir/sub.txt"; do
        printf 'old:%s\n' "$(basename "$path")" > "$path"
    done
    MENU_NAT_BEFORE=$(firewall_snapshot)
    MENU_OWNER_BEFORE=$(<"$HY2_NAT_STATE_FILE")
    SERVICE_ACTIVE=1
    RESTART_FAILURES=0
    UPDATE_SUB_FAILURES=0
    ATOMIC_CLIENT_FAILURES=0
    RESTART_CALLS=0
}

assert_menu_fixture_restored() {
    local description="$1" path
    [[ "$(firewall_snapshot)" == "$MENU_NAT_BEFORE" ]] || fail "$description did not restore NAT"
    [[ "$(<"$HY2_NAT_STATE_FILE")" == "$MENU_OWNER_BEFORE" ]] || fail "$description did not restore NAT state"
    grep -Fq 'mport=12443,56000-56100' "$client_dir" || fail "$description did not restore client"
    for path in "$work_dir/base-sub.txt" "$combined_client_dir" "$work_dir/all-sub.txt" "$work_dir/sub.txt"; do
        [[ "$(<"$path")" == "old:$(basename "$path")" ]] || \
            fail "$description did not restore $(basename "$path")"
    done
    [[ "$SERVICE_ACTIVE" == 1 ]] || fail "$description did not restore service state"
}

prepare_menu_fixture
original_fingerprint_helper=$(declare -f get_hy2_certificate_fingerprint)
get_hy2_certificate_fingerprint() { return 1; }
if enable_hy2_port_hopping_transaction 56200 56300; then
    fail 'HY2 menu enable succeeded despite certificate failure'
fi
eval "$original_fingerprint_helper"
assert_menu_fixture_restored 'certificate failure'
[[ "$RESTART_CALLS" -eq 0 ]] || fail 'certificate failure restarted the service'

prepare_menu_fixture
original_stage_helper=$(declare -f stage_hy2_client_file)
stage_hy2_client_file() { return 1; }
if enable_hy2_port_hopping_transaction 56200 56300; then
    fail 'HY2 menu enable succeeded despite client generation failure'
fi
eval "$original_stage_helper"
assert_menu_fixture_restored 'client generation failure'
[[ "$RESTART_CALLS" -eq 0 ]] || fail 'client generation failure restarted the service'

for failure_stage in atomic restart update_sub; do
    prepare_menu_fixture
    case "$failure_stage" in
        atomic) ATOMIC_CLIENT_FAILURES=1 ;;
        restart) RESTART_FAILURES=1 ;;
        update_sub) UPDATE_SUB_FAILURES=1 ;;
    esac
    if enable_hy2_port_hopping_transaction 56200 56300; then
        fail "HY2 menu enable succeeded despite $failure_stage failure"
    fi
    assert_menu_fixture_restored "$failure_stage failure"
done

prepare_menu_fixture
enable_hy2_port_hopping_transaction 56200 56300 || fail 'HY2 menu enable transaction failed'
grep -Fq 'mport=12443,56200-56300' "$client_dir" || fail 'HY2 menu enable did not commit staged client'
if grep -Fq -- '--dport 56000:56100' "$nat_state"; then
    fail 'HY2 menu enable stacked the old NAT range'
fi

MENU_NAT_BEFORE=$(firewall_snapshot)
MENU_OWNER_BEFORE=$(<"$HY2_NAT_STATE_FILE")
cp -- "$client_dir" "$tmp_root/enabled-client.expected"
cp -- "$work_dir/base-sub.txt" "$tmp_root/enabled-base.expected"
cp -- "$combined_client_dir" "$tmp_root/enabled-all-url.expected"
cp -- "$work_dir/all-sub.txt" "$tmp_root/enabled-all-sub.expected"
cp -- "$work_dir/sub.txt" "$tmp_root/enabled-sub.expected"
UPDATE_SUB_FAILURES=1
if disable_hy2_port_hopping_transaction; then
    fail 'HY2 menu disable succeeded despite update_sub failure'
fi
[[ "$(firewall_snapshot)" == "$MENU_NAT_BEFORE" ]] || fail 'disable failure did not restore NAT'
[[ "$(<"$HY2_NAT_STATE_FILE")" == "$MENU_OWNER_BEFORE" ]] || fail 'disable failure did not restore NAT state'
cmp -s -- "$client_dir" "$tmp_root/enabled-client.expected" || fail 'disable failure did not restore client'
cmp -s -- "$work_dir/base-sub.txt" "$tmp_root/enabled-base.expected" || fail 'disable failure did not restore base-sub'
cmp -s -- "$combined_client_dir" "$tmp_root/enabled-all-url.expected" || fail 'disable failure did not restore all-url'
cmp -s -- "$work_dir/all-sub.txt" "$tmp_root/enabled-all-sub.expected" || fail 'disable failure did not restore all-sub'
cmp -s -- "$work_dir/sub.txt" "$tmp_root/enabled-sub.expected" || fail 'disable failure did not restore sub'
[[ "$SERVICE_ACTIVE" == 1 ]] || fail 'disable failure did not restore service state'

disable_hy2_port_hopping_transaction || fail 'HY2 menu disable transaction failed'
[[ ! -e "$HY2_NAT_STATE_FILE" ]] || fail 'HY2 menu disable left NAT ownership state'
if grep -Eq 'SBHY2_|sb-hy2-' "$nat_state"; then
    fail 'HY2 menu disable left owned firewall resources'
fi
if grep -Fq '&mport=' "$client_dir"; then
    fail 'HY2 menu disable left mport in the client'
fi

change_config_source=$(sed -n '/^change_config() {/,/^change_ip() {/p' "$script" | sed '$d')
grep -Fq 'enable_hy2_port_hopping_transaction "$min_port" "$max_port"' <<< "$change_config_source" || \
    fail 'HY2 enable menu does not use the transaction helper'
grep -Fq 'disable_hy2_port_hopping_transaction' <<< "$change_config_source" || \
    fail 'HY2 disable menu does not use the transaction helper'

# The production persistence helper must propagate backend failures.
production_persist_source=$(sed -n '/^persist_hy2_nat_rules() {/,/^}/p' "$script")
[[ -n "$production_persist_source" ]] || fail 'production persistence helper is missing'
eval "$production_persist_source"
command_exists() {
    case "${1:-}" in
        netfilter-persistent|rc-service) return 1 ;;
        service|iptables|ip6tables) return 0 ;;
        *) return 1 ;;
    esac
}
service() {
    [[ "${1:-}" != iptables ]]
}
if persist_hy2_nat_rules; then
    fail 'service iptables persistence failure was swallowed'
fi

# RED 7: service wrappers return the actual backend result, not the print result.
manage_service_source=$(sed -n '/^manage_service() {/,/^}/p' "$script")
[[ -n "$manage_service_source" ]] || fail 'manage_service is missing'
eval "$manage_service_source"
check_service() { printf '%s\n' running; }
command_exists() { [[ "${1:-}" == systemctl ]]; }
systemctl() {
    [[ "${1:-}" != restart ]]
}
red() { :; }
green() { :; }
yellow() { :; }
if manage_service sing-box restart; then
    fail 'manage_service swallowed a systemctl restart failure'
fi

echo 'HY2 transaction tests passed.'
