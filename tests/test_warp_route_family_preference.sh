#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

family_block=$(sed -n '/^render_warp_route_family() {/,/^}/p' "$script")
[[ -n "$family_block" ]] || fail 'render_warp_route_family is not implemented'
# shellcheck disable=SC1090
source /dev/stdin <<< "$family_block"

tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT
source_file="$tmp_root/route.json"
output_file="$tmp_root/route.next.json"

cat > "$source_file" <<'JSON'
{
  "route": {
    "rules": [
      {"port":[80,443],"action":"sniff"},
      {"domain_suffix":["custom.example"],"action":"resolve","strategy":"prefer_ipv6"},
      {"rule_set":["openai"],"action":"route","outbound":"wireguard-out"},
      {"rule_set":["direct-only"],"action":"route","outbound":"direct"}
    ],
    "final":"direct"
  }
}
JSON

render_warp_route_family "$source_file" "$output_file" 6 || fail 'IPv6 route preference render failed'
jq -e '
  [.route.rules[] | select(
    .action == "resolve" and .strategy == "prefer_ipv6" and
    .network == ["tcp","udp"] and .rule_set == ["openai"]
  )] | length == 1
' "$output_file" >/dev/null || fail 'managed IPv6 resolve rule was not rendered exactly once'
sniff_index=$(jq '[.route.rules | to_entries[] | select(.value.action == "sniff") | .key][0]' "$output_file")
resolve_index=$(jq '[.route.rules | to_entries[] | select(.value.action == "resolve" and .value.network == ["tcp","udp"]) | .key][0]' "$output_file")
route_index=$(jq '[.route.rules | to_entries[] | select(.value.outbound == "wireguard-out") | .key][0]' "$output_file")
[[ "$sniff_index" -lt "$resolve_index" && "$resolve_index" -lt "$route_index" ]] ||
    fail 'managed resolve rule is not between sniff and WARP route rules'
jq -e '.route.rules | any(.domain_suffix == ["custom.example"])' "$output_file" >/dev/null ||
    fail 'unrelated custom resolve rule was removed'

mv "$output_file" "$source_file"
render_warp_route_family "$source_file" "$output_file" 6 || fail 'idempotent IPv6 render failed'
[[ "$(jq '[.route.rules[] | select(.action == "resolve" and .network == ["tcp","udp"])] | length' "$output_file")" -eq 1 ]] ||
    fail 'repeated IPv6 render duplicated the managed resolve rule'

jq '.route.rules += [{"rule_set":["netflix"],"action":"route","outbound":"wireguard-out"}]' \
    "$output_file" > "$source_file"
render_warp_route_family "$source_file" "$output_file" 6 || fail 'expanded IPv6 render failed'
jq -e '
  [.route.rules[] | select(.action == "resolve" and .network == ["tcp","udp"])][0].rule_set
  | sort == ["netflix","openai"]
' "$output_file" >/dev/null || fail 'managed resolve rule did not track all WARP-routed rule sets'

mv "$output_file" "$source_file"
render_warp_route_family "$source_file" "$output_file" 4 || fail 'IPv4 route preference render failed'
[[ "$(jq '[.route.rules[] | select(.action == "resolve" and .network == ["tcp","udp"])] | length' "$output_file")" -eq 0 ]] ||
    fail 'IPv4 render retained the managed IPv6 resolve rule'
jq -e '.route.rules | any(.domain_suffix == ["custom.example"])' "$output_file" >/dev/null ||
    fail 'IPv4 render removed an unrelated custom resolve rule'

echo 'WARP route family preference tests passed.'
