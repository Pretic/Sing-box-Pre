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
# shellcheck disable=SC1091
source /dev/stdin <<< "$warp_block"

add_rule_menu_block=$(sed -n '/^add_rule_menu() {/,/^set_global_outbound() {/p' "$script" | sed '$d')
[[ -n "$add_rule_menu_block" ]] || fail 'WARP rule menu could not be extracted'
if grep -Fq 'native_ipv6_available' <<< "$add_rule_menu_block"; then
    fail 'WARP rule menu must not automatically bypass WARP for selected-service IPv6 traffic'
fi
if grep -Fq 'ipv6_direct_fallback' <<< "$add_rule_menu_block"; then
    fail 'WARP rule menu must use the full-route default instead of an automatic IPv6 fallback'
fi

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
    # Used by functions sourced dynamically from sing-box.sh.
    # shellcheck disable=SC2034
    work_dir="$tmp_root/work"
    # shellcheck disable=SC2034
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

jq -e --arg path "$work_dir/cache.db" \
    '.experimental.cache_file.enabled == true and .experimental.cache_file.path == $path' \
    "$route_file" >/dev/null || fail 'remote rule sets must have a persistent cache after repair'

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
streaming_url='https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-entertainment.srs'
jq -e --arg url "$streaming_url" \
    '.route.rule_set | any(.tag == "streaming" and .url == $url)' \
    "$route_file" >/dev/null || \
    fail 'streaming rule set does not use the verified full entertainment source'
if grep -Fq 'geo-lite/geosite/proxymedia.srs' "$script"; then
    fail 'incomplete proxymedia streaming source is still present'
fi
[[ "$(grep -Fc "$streaming_url" "$script")" -eq 2 ]] || \
    fail 'initial and repair streaming rule declarations are not synchronized'
jq -e '.route.rule_set | any(.tag == "custom")' "$route_file" >/dev/null || \
    fail 'custom rule set was not preserved'
jq -e '.route.rules | any(.domain_suffix == ["example.com"])' "$route_file" >/dev/null || \
    fail 'unrelated route rule was not preserved'
[[ "$(jq -r '.route.final' "$route_file")" == custom-proxy ]] || \
    fail 'existing route final was overwritten during repair'

cat > "$conf_dir/endpoints.json" <<'EOF'
{"endpoints":[{"type":"wireguard","tag":"wireguard-out","address":["172.16.0.2/32","2606:4700:110:8dfe:d141:69bb:6b80:925/128"],"private_key":"legacy","peers":[{"public_key":"legacy","reserved":[78,135,76]}]}]}
EOF
jq '.experimental = {cache_file: {enabled: false, path: "/custom/rules.db", cache_id: "custom"}, clash_api: {external_controller: "127.0.0.1:9090"}}' \
    "$route_file" > "$tmp_root/custom-route.json"
mv "$tmp_root/custom-route.json" "$route_file"
ensure_warp_prerequisites
jq -e '.experimental == {cache_file: {enabled: false, path: "/custom/rules.db", cache_id: "custom"}, clash_api: {external_controller: "127.0.0.1:9090"}}' \
    "$route_file" >/dev/null || fail 'repair must preserve explicit cache settings and unrelated experimental options'
jq -e '.endpoints | any(
    .tag == "wireguard-out" and
    (.address | index("2606:4700:110:8abc::1234/128")) and
    ((.address | index("2606:4700:110:8dfe:d141:69bb:6b80:925/128")) | not)
)' "$conf_dir/endpoints.json" >/dev/null || \
    fail 'legacy shared WARP identity was not migrated to persisted unique state'

add_service_route google wireguard-out
[[ "$(jq '[.route.rules[] | select(.rule_set? | index("google"))] | length' "$route_file")" -eq 1 ]] || \
    fail 'default WARP service route should have one rule covering both address families'
jq -e '.route.rules | any(
    (.rule_set? | index("google")) and
    .outbound == "wireguard-out" and
    (.ip_version? == null)
)' "$route_file" >/dev/null || \
    fail 'default WARP service route did not send IPv4 and IPv6 to wireguard-out'

add_service_route google wireguard-out true
[[ "$(jq -r '.route.rules[0].action' "$route_file")" == sniff ]] || \
    fail 'sniff rule is not first'
[[ "$(jq '[.route.rules[] | select(.rule_set? | index("google"))] | length' "$route_file")" -eq 2 ]] || \
    fail 'explicit IPv6 fallback should retain IPv6 direct and WARP rules'
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
    fail 'explicit full-route service should have one WARP rule'
jq -e '.route.rules | any((.rule_set? | index("youtube")) and .outbound == "wireguard-out")' "$route_file" >/dev/null || \
    fail 'explicit full-route service did not select wireguard-out'

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

add_service_route gemini wireguard-out
[[ "$(jq -r '.route.final' "$route_file")" == direct ]] || \
    fail 'selective WARP routing changed the fallback for unselected services'
jq -e '.route.rules | any((.rule_set? | index("gemini")) and .outbound == "wireguard-out")' "$route_file" >/dev/null || \
    fail 'selected service was not routed through WARP after direct restore'
jq -e '.route.rules | all((.rule_set? | index("netflix")) | not)' "$route_file" >/dev/null || \
    fail 'an unselected service unexpectedly gained a WARP route'

reset_fixture
ensure_warp_prerequisites
jq -e --arg path "$work_dir/cache.db" \
    '.experimental.cache_file.enabled == true and .experimental.cache_file.path == $path and .route.final == "direct"' \
    "$route_file" >/dev/null || fail 'new route configuration must enable persistent rule caching'

reset_fixture
write_custom_fixture
cp "$route_file" "$tmp_root/route.before"
cat > "$conf_dir/experimental.json" <<'EOF'
{"experimental":{"cache_file":{"enabled":false,"path":"/external/cache.db"}}}
EOF
cp "$conf_dir/experimental.json" "$tmp_root/experimental.before"
ensure_warp_prerequisites
jq -e '.experimental.cache_file == null' "$route_file" >/dev/null || \
    fail 'repair must not override cache settings from another configuration file'
cmp -s "$tmp_root/experimental.before" "$conf_dir/experimental.json" || \
    fail 'repair modified a separate experimental configuration'

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
if grep -Fq "rm -rf \${route_file} \${conf_dir}/endpoints.json" "$script"; then
    fail 'global proxy still deletes route and endpoint files'
fi

echo 'WARP routing tests passed.'
