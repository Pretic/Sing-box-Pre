#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

command -v jq >/dev/null 2>&1 || {
    echo 'FAIL: jq is required for route and NAT safety tests' >&2
    exit 1
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for function_name in \
    singbox_check_config_dir \
    singbox_service_is_active \
    atomic_replace_config_file \
    apply_proxy_config_transaction \
    mutate_proxy_transaction \
    add_proxy_outbound_transaction \
    configure_hy2_nat_family \
    remove_hy2_nat_family \
    add_hy2_port_hopping \
    remove_hy2_port_hopping; do
    grep -Eq "^${function_name}\(\) \{" "$script" || \
        fail "${function_name} is not implemented"
done

proxy_block=$(sed -n '/^singbox_check_config_dir() {/,/^add_service_route() {/p' "$script" | sed '$d')
[[ -n "$proxy_block" ]] || fail 'proxy transaction helper block could not be extracted'
source /dev/stdin <<< "$proxy_block"

HAS_IPTABLES_COMMAND=1
HAS_IP6TABLES_COMMAND=1
command_exists() {
    case "$1" in
        iptables) [[ "$HAS_IPTABLES_COMMAND" == 1 ]] ;;
        ip6tables) [[ "$HAS_IP6TABLES_COMMAND" == 1 ]] ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}
red() { :; }
green() { :; }
yellow() { :; }

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

service_log="$tmp_root/service.log"
restart_failures="$tmp_root/restart.failures"
active_failures="$tmp_root/active.failures"

consume_failure() {
    local state_file="$1"
    local remaining=0
    [[ -s "$state_file" ]] && remaining=$(<"$state_file")
    if [[ "$remaining" -gt 0 ]]; then
        printf '%s\n' "$((remaining - 1))" > "$state_file"
        return 0
    fi
    return 1
}

restart_singbox_checked() {
    printf '%s\n' restart >> "$service_log"
    ! consume_failure "$restart_failures"
}

singbox_service_is_active() {
    printf '%s\n' active >> "$service_log"
    ! consume_failure "$active_failures"
}

check_log="$tmp_root/check.log"
check_capture="$tmp_root/check-capture"
check_failures="$tmp_root/check.failures"
mock_singbox="$tmp_root/sing-box"
mkdir -p "$check_capture"

cat > "$mock_singbox" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 3 && "$1" == check && "$2" == -C ]] || exit 91
stage_dir="$3"
printf '%s\n' "$*" >> "$CHECK_LOG"
[[ "$stage_dir" != "$PRODUCTION_CONF" ]] || exit 92
cmp -s "$EXPECTED_ROUTE" "$PRODUCTION_CONF/route.json" || exit 93
cmp -s "$EXPECTED_OUTBOUNDS" "$PRODUCTION_CONF/outbounds.json" || exit 94
jq empty "$stage_dir"/*.json >/dev/null
cp "$stage_dir/route.json" "$CHECK_CAPTURE/route.json"
cp "$stage_dir/outbounds.json" "$CHECK_CAPTURE/outbounds.json"
remaining=0
[[ -s "$CHECK_FAILURES" ]] && remaining=$(<"$CHECK_FAILURES")
if [[ "$remaining" -gt 0 ]]; then
    printf '%s\n' "$((remaining - 1))" > "$CHECK_FAILURES"
    exit 95
fi
EOF
chmod +x "$mock_singbox"

export CHECK_LOG="$check_log"
export CHECK_CAPTURE="$check_capture"
export CHECK_FAILURES="$check_failures"

write_proxy_fixture() {
    conf_dir="$tmp_root/conf"
    route_file="$conf_dir/route.json"
    outbound_file="$conf_dir/outbounds.json"
    rm -rf "$conf_dir"
    mkdir -p "$conf_dir"
    : > "$service_log"
    : > "$check_log"
    printf '0\n' > "$check_failures"
    printf '0\n' > "$restart_failures"
    printf '0\n' > "$active_failures"

    cat > "$route_file" <<'EOF'
{
  "route": {
    "rules": [
      {"rule_set":["netflix"],"action":"route","outbound":"proxy-a"},
      {"domain_suffix":["target.example"],"action":"route","outbound":"proxy-a"},
      {"domain_suffix":["keep.example"],"action":"route","outbound":"proxy-b"},
      {"port":[80,443],"action":"sniff"}
    ],
    "final": "proxy-a"
  }
}
EOF
    cat > "$outbound_file" <<'EOF'
{
  "outbounds": [
    {"type":"direct","tag":"direct"},
    {"type":"socks","tag":"proxy-a","server":"192.0.2.10","server_port":1080},
    {"type":"socks","tag":"proxy-ab","server":"192.0.2.11","server_port":1080},
    {"type":"http","tag":"proxy-b","server":"192.0.2.12","server_port":8080}
  ]
}
EOF
    cat > "$conf_dir/log.json" <<'EOF'
{"log":{"level":"warn"}}
EOF
    cp "$route_file" "$tmp_root/expected-route"
    cp "$outbound_file" "$tmp_root/expected-outbounds"
    export PRODUCTION_CONF="$conf_dir"
    export EXPECTED_ROUTE="$tmp_root/expected-route"
    export EXPECTED_OUTBOUNDS="$tmp_root/expected-outbounds"
    SINGBOX_CHECK_BIN="$mock_singbox"
}

assert_proxy_fixture_restored() {
    cmp -s "$EXPECTED_ROUTE" "$route_file" || fail "$1 did not restore route.json byte-for-byte"
    cmp -s "$EXPECTED_OUTBOUNDS" "$outbound_file" || fail "$1 did not restore outbounds.json byte-for-byte"
    [[ "$(grep -c '^restart$' "$service_log" || true)" -ge 1 ]] || \
        fail "$1 did not restore the sing-box service"
    [[ "$(grep -c '^active$' "$service_log" || true)" -ge 1 ]] || \
        fail "$1 did not verify the restored service"
}

write_proxy_fixture
mutate_proxy_transaction proxy-a direct
[[ "$(jq -r '.route.final' "$route_file")" == direct ]] || \
    fail 'deleting the final outbound did not fall back to direct'
[[ "$(jq '[.route.rules[] | select(.outbound? == "proxy-a")] | length' "$route_file")" -eq 0 ]] || \
    fail 'route rules still reference the deleted outbound'
[[ "$(jq '[.route.rules[] | select(.domain_suffix? == ["target.example"])] | length' "$route_file")" -eq 0 ]] || \
    fail 'rules routed through the deleted outbound were not removed'
jq -e '.route.rules | any(.domain_suffix? == ["keep.example"] and .outbound == "proxy-b")' \
    "$route_file" >/dev/null || fail 'an unrelated route rule was removed'
[[ "$(jq '[.outbounds[] | select(.tag == "proxy-a")] | length' "$outbound_file")" -eq 0 ]] || \
    fail 'the exact outbound was not deleted'
jq -e '.outbounds | any(.tag == "proxy-ab")' "$outbound_file" >/dev/null || \
    fail 'prefix-matching outbound was deleted accidentally'
grep -Eq '^check -C .+' "$check_log" || fail 'sing-box check -C was not executed'
[[ "$(jq -r '.route.final' "$check_capture/route.json")" == direct ]] || \
    fail 'the staged route was not checked'
[[ "$(jq '[.outbounds[] | select(.tag == "proxy-a")] | length' "$check_capture/outbounds.json")" -eq 0 ]] || \
    fail 'the staged outbound deletion was not checked'

write_proxy_fixture
mutate_proxy_transaction proxy-a proxy-b
[[ "$(jq -r '.route.final' "$route_file")" == proxy-b ]] || \
    fail 'replacement did not rewrite route.final'
[[ "$(jq '[.route.rules[] | select(.outbound? == "proxy-a")] | length' "$route_file")" -eq 0 ]] || \
    fail 'replacement left route rules on the old outbound'
[[ "$(jq '[.route.rules[] | select(.outbound? == "proxy-b")] | length' "$route_file")" -eq 3 ]] || \
    fail 'replacement did not rewrite all old route-rule references'

write_proxy_fixture
add_proxy_outbound_transaction \
    '{"type":"http","tag":"proxy-new","server":"192.0.2.20","server_port":3128}' true
jq -e '.outbounds | any(.tag == "proxy-new" and .server_port == 3128)' "$outbound_file" >/dev/null || \
    fail 'proxy addition was not committed'
jq -e '.route.rules | any((.rule_set? | index("netflix")) and .outbound == "proxy-new")' \
    "$route_file" >/dev/null || fail 'proxy addition and route switch were not committed together'
[[ "$(grep -c '^restart$' "$service_log")" -eq 1 ]] || \
    fail 'proxy addition restarted more than once instead of using one transaction'

write_proxy_fixture
printf '1\n' > "$check_failures"
if mutate_proxy_transaction proxy-a direct; then
    fail 'proxy mutation succeeded despite a staged config-check failure'
fi
assert_proxy_fixture_restored 'config-check failure'

write_proxy_fixture
printf '1\n' > "$restart_failures"
if mutate_proxy_transaction proxy-a direct; then
    fail 'proxy mutation succeeded despite a restart failure'
fi
assert_proxy_fixture_restored 'restart failure'
[[ "$(grep -c '^restart$' "$service_log")" -ge 2 ]] || \
    fail 'restart failure did not restart the restored configuration'

write_proxy_fixture
printf '1\n' > "$active_failures"
if mutate_proxy_transaction proxy-a direct; then
    fail 'proxy mutation succeeded despite an inactive service'
fi
assert_proxy_fixture_restored 'active-check failure'
[[ "$(grep -c '^active$' "$service_log")" -ge 2 ]] || \
    fail 'active-check failure did not verify the restored configuration'

write_proxy_fixture
atomic_replace_calls=0
atomic_replace_config_file() {
    atomic_replace_calls=$((atomic_replace_calls + 1))
    [[ "$atomic_replace_calls" -ne 2 ]] || return 1
    mv -f -- "$1" "$2"
}
if mutate_proxy_transaction proxy-a direct; then
    fail 'proxy mutation succeeded despite the second atomic replacement failing'
fi
assert_proxy_fixture_restored 'atomic replacement failure'

nat_block=$(sed -n '/^configure_hy2_nat_family() {/,/^render_vless_reality_inbound() {/p' "$script" | sed '$d')
[[ -n "$nat_block" ]] || fail 'HY2 NAT helper block could not be extracted'
source /dev/stdin <<< "$nat_block"
validate_port_source=$(sed -n '/^validate_port_value() {/,/^}/p' "$script")
[[ -n "$validate_port_source" ]] || fail 'port validation helper could not be extracted'
source /dev/stdin <<< "$validate_port_source"

nat_state="$tmp_root/nat.state"
nat_log="$tmp_root/nat.log"
HAS_IPV4=1
HAS_IPV6=1

ipv4_stack_available() { [[ "$HAS_IPV4" == 1 ]]; }
ipv6_stack_available() { [[ "$HAS_IPV6" == 1 ]]; }
persist_hy2_nat_rules() { :; }

mock_iptables() {
    local tool="$1"
    shift
    local joined="$*"
    local state_line delete_line chain
    printf '%s %s\n' "$tool" "$joined" >> "$nat_log"

    case " $joined " in
        *' -N '*)
            chain="${joined##* -N }"
            state_line="CHAIN|$tool|$chain"
            grep -Fxq "$state_line" "$nat_state" 2>/dev/null && return 1
            printf '%s\n' "$state_line" >> "$nat_state"
            ;;
        *' -C '*)
            state_line="$tool|${joined/ -C / -A }"
            grep -Fxq "$state_line" "$nat_state" 2>/dev/null
            ;;
        *' -A '*)
            printf '%s|%s\n' "$tool" "$joined" >> "$nat_state"
            ;;
        *' -D '*)
            delete_line="$tool|${joined/ -D / -A }"
            awk -v target="$delete_line" '$0 != target' "$nat_state" > "$nat_state.tmp"
            mv "$nat_state.tmp" "$nat_state"
            ;;
        *' -F '*)
            chain="${joined##* -F }"
            awk -v prefix="$tool|-t nat -A $chain " 'index($0, prefix) != 1' \
                "$nat_state" > "$nat_state.tmp"
            mv "$nat_state.tmp" "$nat_state"
            ;;
        *' -X '*)
            chain="${joined##* -X }"
            delete_line="CHAIN|$tool|$chain"
            awk -v target="$delete_line" '$0 != target' "$nat_state" > "$nat_state.tmp"
            mv "$nat_state.tmp" "$nat_state"
            ;;
        *) return 1 ;;
    esac
}

iptables() { mock_iptables iptables "$@"; }
ip6tables() { mock_iptables ip6tables "$@"; }

: > "$nat_state"
: > "$nat_log"
printf '%s\n' 'iptables|-t nat -A PREROUTING -p tcp --dport 8443 -j REDIRECT --to-ports 9443' >> "$nat_state"
printf '%s\n' 'ip6tables|-t nat -A PREROUTING -p tcp --dport 8443 -j ACCEPT' >> "$nat_state"

add_hy2_port_hopping 50000 50100 8443
add_hy2_port_hopping 50000 50100 8443
[[ "$(grep -Fxc 'iptables|-t nat -A PREROUTING -p udp -m comment --comment prenet-hy2 -j PRENET_HY2' "$nat_state")" -eq 1 ]] || \
    fail 'IPv4 HY2 jump was not idempotent'
[[ "$(grep -Fxc 'ip6tables|-t nat -A PREROUTING -p udp -m comment --comment prenet-hy2 -j PRENET_HY2' "$nat_state")" -eq 1 ]] || \
    fail 'IPv6 HY2 jump was not idempotent'
[[ "$(grep -Fc -- '--dport 50000:50100 -m comment --comment prenet-hy2 -j DNAT --to-destination :8443' "$nat_state")" -eq 2 ]] || \
    fail 'HY2 DNAT rules were not idempotent per address family'

remove_hy2_port_hopping
remove_hy2_port_hopping
grep -Fxq 'iptables|-t nat -A PREROUTING -p tcp --dport 8443 -j REDIRECT --to-ports 9443' "$nat_state" || \
    fail 'unrelated IPv4 PREROUTING rule was removed'
grep -Fxq 'ip6tables|-t nat -A PREROUTING -p tcp --dport 8443 -j ACCEPT' "$nat_state" || \
    fail 'unrelated IPv6 PREROUTING rule was removed'
if grep -Eq -- '(^| )-F PREROUTING($| )|(^| )-P (PREROUTING|INPUT|FORWARD|OUTPUT)($| )' "$nat_log"; then
    fail 'HY2 cleanup flushed a built-in chain or changed a policy'
fi
if grep -Eq 'PRENET_HY2|prenet-hy2' "$nat_state"; then
    fail 'HY2 cleanup left an owned jump, rule, or chain'
fi

: > "$nat_state"
: > "$nat_log"
HAS_IPV6=0
HAS_IP6TABLES_COMMAND=0
add_hy2_port_hopping 51000 51100 8443
grep -q '^iptables ' "$nat_log" || fail 'IPv4-only host did not configure IPv4 NAT'
if grep -q '^ip6tables ' "$nat_log"; then
    fail 'IPv4-only host configured IPv6 NAT despite the missing stack'
fi
remove_hy2_port_hopping || fail 'cleanup failed merely because ip6tables was unavailable'

if grep -Eq 'iptables .* -t nat -F PREROUTING|ip6tables .* -t nat -F PREROUTING' "$script"; then
    fail 'the script still flushes the built-in PREROUTING chain'
fi

echo 'Route and HY2 NAT safety tests passed.'
