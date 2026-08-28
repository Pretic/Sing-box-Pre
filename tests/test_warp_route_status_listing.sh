#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

listing_block=$(sed -n '/^list_enabled_warp_route_mappings() {/,/^}/p' "$script")
[[ -n "$listing_block" ]] || fail 'WARP route status listing helper is missing'
# shellcheck disable=SC1090
source /dev/stdin <<< "$listing_block"

tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT
route_file="$tmp_root/route.json"
cat > "$route_file" <<'JSON'
{
  "route": {
    "rules": [
      {"rule_set":["openai"],"network":["tcp","udp"],"action":"resolve","strategy":"prefer_ipv6"},
      {"rule_set":["openai"],"action":"route","outbound":"wireguard-out"},
      {"rule_set":["direct-only"],"action":"route","outbound":"direct"}
    ]
  }
}
JSON

actual=$(list_enabled_warp_route_mappings "$route_file")
expected=$'direct-only -> direct\nopenai -> wireguard-out'
[[ "$actual" = "$expected" ]] || fail "unexpected WARP route listing: ${actual}"
[[ "$actual" != *unknown* ]] || fail 'managed IPv6 resolve rule was shown as an unknown route'

echo 'WARP route status listing tests passed.'
