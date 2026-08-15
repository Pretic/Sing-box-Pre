#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

command -v jq >/dev/null 2>&1 || {
    echo 'FAIL: jq is required for WARP routing tests' >&2
    exit 1
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for function_name in \
    extract_warp_endpoint \
    warp_endpoint_is_legacy \
    warp_endpoint_is_valid \
    generate_unique_warp_identity \
    warp_endpoint_json \
    warp_rule_sets_json \
    ensure_warp_prerequisites \
    restart_singbox_checked \
    apply_warp_route_update \
    add_service_route \
    delete_service_route \
    set_global_route \
    restore_direct_route; do
    grep -Eq "^${function_name}\(\) \{" "$script" || \
        fail "${function_name} is not implemented"
done

warp_block=$(sed -n '/^extract_warp_endpoint() {/,/^warp_manage() {/p' "$script" | sed '$d')
[[ -n "$warp_block" ]] || fail 'WARP helper block could not be extracted'
source /dev/stdin <<< "$warp_block"

command_exists() { command -v "$1" >/dev/null 2>&1; }
red() { :; }
green() { :; }
yellow() { :; }
purple() { :; }
skyblue() { :; }

MOCK_VALIDATE_STATUS=0
MOCK_RESTART_STATUS=0
MOCK_RESTART_CALLS=0
validate_singbox_config() {
    return "$MOCK_VALIDATE_STATUS"
}
restart_singbox_checked() {
    MOCK_RESTART_CALLS=$((MOCK_RESTART_CALLS + 1))
    return "$MOCK_RESTART_STATUS"
}

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

reset_fixture() {
    rm -rf "$tmp_root/conf"
    mkdir -p "$tmp_root/conf"
    conf_dir="$tmp_root/conf"
    route_file="$conf_dir/route.json"
    outbound_file="$conf_dir/outbounds.json"
    work_dir="$tmp_root/work"
    server_name='sing-box'
    MOCK_VALIDATE_STATUS=0
    MOCK_RESTART_STATUS=0
    MOCK_RESTART_CALLS=0

    mkdir -p "$conf_dir/warp"
    cat > "$conf_dir/warp/endpoint.json" <<'EOF'
{
  "type": "wireguard",
  "tag": "wireguard-out",
  "mtu": 1280,
  "address": ["172.16.0.2/32", "2606:4700:110:8abc::1234/128"],
  "private_key": "test-unique-private-key",
  "peers": [{
    "address": "engage.cloudflareclient.com",
    "port": 2408,
    "public_key": "test-peer-public-key",
    "allowed_ips": ["0.0.0.0/0", "::/0"],
    "persistent_keepalive_interval": 25,
    "reserved": [1, 2, 3]
  }]
}
EOF
    chmod 600 "$conf_dir/warp/endpoint.json"
}

write_custom_fixture() {
    cat > "$outbound_file" <<'EOF'
{"outbounds":[{"type":"socks","tag":"custom-proxy","server":"127.0.0.1","server_port":1080}]}
EOF
    cat > "$conf_dir/endpoints.json" <<'EOF'
{"endpoints":[{"type":"tailscale","tag":"custom-endpoint"}]}
EOF
    cat > "$route_file" <<'EOF'
{
  "route": {
    "rule_set": [
      {"tag":"custom","type":"remote","format":"binary","url":"https://example.com/custom.srs","download_detour":"direct"}
    ],
    "rules": [
      {"domain_suffix":["example.com"],"action":"route","outbound":"custom-proxy"}
    ],
    "final": "custom-proxy"
  }
}
EOF
}

reset_fixture
write_custom_fixture
ensure_warp_prerequisites

jq -e '.outbounds | any(.tag == "direct" and .type == "direct")' "$outbound_file" >/dev/null || \
    fail 'direct outbound was not repaired'
jq -e '.outbounds | any(.tag == "custom-proxy")' "$outbound_file" >/dev/null || \
    fail 'custom outbound was not preserved'
jq -e '.endpoints | any(.tag == "wireguard-out" and .type == "wireguard")' "$conf_dir/endpoints.json" >/dev/null || \
    fail 'wireguard-out endpoint was not repaired'
jq -e '.endpoints | any(
    .tag == "wireguard-out" and
    (.address | index("2606:4700:110:8abc::1234/128")) and
    (.peers | any((.reserved | length) == 3)) and
    (.peers | any(.persistent_keepalive_interval == 25))
)' "$conf_dir/endpoints.json" >/dev/null || \
    fail 'wireguard-out endpoint did not use persisted unique state with reserved bytes and keepalive'
jq -e '.endpoints | any(.tag == "custom-endpoint")' "$conf_dir/endpoints.json" >/dev/null || \
    fail 'custom endpoint was not preserved'
jq -e '.route.rule_set | any(.tag == "streaming")' "$route_file" >/dev/null || \
    fail 'streaming rule set was not added'
jq -e '.route.rule_set | any(.tag == "custom")' "$route_file" >/dev/null || \
    fail 'custom rule set was not preserved'
jq -e '.route.rules | any(.domain_suffix == ["example.com"])' "$route_file" >/dev/null || \
    fail 'unrelated route rule was not preserved'
[[ "$(jq -r '.route.final' "$route_file")" == custom-proxy ]] || \
    fail 'existing route final was overwritten during repair'

cat > "$conf_dir/endpoints.json" <<'EOF'
{"endpoints":[{"type":"wireguard","tag":"wireguard-out","address":["172.16.0.2/32","2606:4700:110:8dfe:d141:69bb:6b80:925/128"],"private_key":"legacy","peers":[{"public_key":"legacy","reserved":[78,135,76]}]}]}
EOF
ensure_warp_prerequisites
jq -e '.endpoints | any(
    .tag == "wireguard-out" and
    (.address | index("2606:4700:110:8abc::1234/128")) and
    ((.address | index("2606:4700:110:8dfe:d141:69bb:6b80:925/128")) | not)
)' "$conf_dir/endpoints.json" >/dev/null || \
    fail 'legacy shared WARP identity was not migrated to persisted unique state'

add_service_route google wireguard-out true
[[ "$(jq -r '.route.rules[0].action' "$route_file")" == sniff ]] || \
    fail 'sniff rule is not first'
[[ "$(jq '[.route.rules[] | select(.rule_set? | index("google"))] | length' "$route_file")" -eq 2 ]] || \
    fail 'dual-stack WARP service should have IPv6 direct and WARP rules'
direct_index=$(jq '[.route.rules | to_entries[] | select(.value.rule_set? | index("google")) | select(.value.ip_version == 6 and .value.outbound == "direct") | .key][0]' "$route_file")
warp_index=$(jq '[.route.rules | to_entries[] | select(.value.rule_set? | index("google")) | select((.value.ip_version? // 0) != 6 and .value.outbound == "wireguard-out") | .key][0]' "$route_file")
[[ "$direct_index" != null && "$warp_index" != null && "$direct_index" -lt "$warp_index" ]] || \
    fail 'IPv6 direct fallback must precede the WARP service rule'

add_service_route google wireguard-out true
[[ "$(jq '[.route.rules[] | select(.rule_set? | index("google"))] | length' "$route_file")" -eq 2 ]] || \
    fail 'adding a service twice created duplicate rules'

delete_service_route google
[[ "$(jq '[.route.rules[] | select(.rule_set? | index("google"))] | length' "$route_file")" -eq 0 ]] || \
    fail 'service rules were not deleted'
jq -e '.route.rules | any(.domain_suffix == ["example.com"])' "$route_file" >/dev/null || \
    fail 'service deletion removed an unrelated rule'

add_service_route youtube wireguard-out false
[[ "$(jq '[.route.rules[] | select(.rule_set? | index("youtube"))] | length' "$route_file")" -eq 1 ]] || \
    fail 'single-stack WARP service should have one WARP rule'
jq -e '.route.rules | any((.rule_set? | index("youtube")) and .outbound == "wireguard-out")' "$route_file" >/dev/null || \
    fail 'single-stack WARP service did not select wireguard-out'

set_global_route custom-proxy
[[ "$(jq -r '.route.final' "$route_file")" == custom-proxy ]] || \
    fail 'global route final was not set explicitly'
[[ "$(jq '.route.rules | length' "$route_file")" -eq 0 ]] || \
    fail 'global route retained selective rules'
[[ -s "$conf_dir/endpoints.json" ]] || fail 'global route deleted endpoints.json'
jq -e '.outbounds | any(.tag == "direct")' "$outbound_file" >/dev/null || \
    fail 'global route deleted the direct outbound'

restore_direct_route
[[ "$(jq -r '.route.final' "$route_file")" == direct ]] || \
    fail 'direct route was not restored explicitly'
[[ -s "$conf_dir/endpoints.json" ]] || fail 'direct restore deleted endpoints.json'

reset_fixture
write_custom_fixture
cp "$route_file" "$tmp_root/route.before"
MOCK_RESTART_STATUS=1
if add_service_route netflix wireguard-out false; then
    fail 'route update succeeded despite restart failure'
fi
cmp -s "$tmp_root/route.before" "$route_file" || \
    fail 'route was not rolled back after restart failure'
[[ "$MOCK_RESTART_CALLS" -ge 2 ]] || \
    fail 'previous configuration was not restarted after rollback'

reset_fixture
write_custom_fixture
cp "$route_file" "$tmp_root/route.validate.before"
MOCK_VALIDATE_STATUS=1
if add_service_route tiktok wireguard-out false; then
    fail 'route update succeeded despite validation failure'
fi
cmp -s "$tmp_root/route.validate.before" "$route_file" || \
    fail 'route was not rolled back after validation failure'

reset_fixture
cat > "$route_file" <<'EOF'
{"route":{"rules":[],"final":"direct"}}
EOF
cp "$route_file" "$tmp_root/ensure-route.before"
MOCK_VALIDATE_STATUS=1
if ensure_warp_prerequisites; then
    fail 'prerequisite repair succeeded despite validation failure'
fi
cmp -s "$tmp_root/ensure-route.before" "$route_file" || \
    fail 'route was not restored after prerequisite validation failure'
[[ ! -e "$outbound_file" ]] || fail 'new outbounds file was not removed during rollback'
[[ ! -e "$conf_dir/endpoints.json" ]] || fail 'new endpoints file was not removed during rollback'

grep -Fq '10. 常见流媒体（聚合规则）' "$script" || \
    fail 'common streaming menu item is missing'
grep -Fq '内置 WARP 出站:' "$script" || \
    fail 'WARP readiness status is missing'
if grep -Fq 'YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=' "$script"; then
    fail 'legacy shared WARP private key is still embedded in the public script'
fi
if grep -Fq 'rm -rf ${route_file} ${conf_dir}/endpoints.json' "$script"; then
    fail 'global proxy still deletes route and endpoint files'
fi

echo 'WARP routing tests passed.'
