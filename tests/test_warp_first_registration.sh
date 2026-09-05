#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for name in red green yellow extract_warp_endpoint warp_endpoint_is_valid warp_endpoint_is_legacy warp_endpoint_json; do
    source <(sed -n "/^${name}() {/,/^}/p" "$script")
done
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
conf_dir="$test_dir/conf"
mkdir -p "$conf_dir"
generate_unique_warp_identity() {
    mkdir -p "$conf_dir/warp"
    cat > "$conf_dir/warp/endpoint.json" <<'JSON'
{"type":"wireguard","tag":"wireguard-out","address":["172.16.0.2/32","2606:4700:110:1234::1/128"],"private_key":"fixture-private-key","peers":[{"address":"engage.cloudflareclient.com","port":2408,"public_key":"fixture-public-key","allowed_ips":["0.0.0.0/0","::/0"],"reserved":[1,2,3]}]}
JSON
    green 'Registered fixture identity.'
}

endpoint=$(warp_endpoint_json 2>"$test_dir/diagnostics")
jq -e '.type == "wireguard" and .peers[0].persistent_keepalive_interval == 25' <<< "$endpoint" >/dev/null 2>&1 || {
    echo 'FAIL: first registration mixed progress messages into endpoint JSON' >&2; exit 1;
}
grep -q 'Registered fixture identity' "$test_dir/diagnostics" || {
    echo 'FAIL: registration progress was lost instead of sent to stderr' >&2; exit 1;
}
second=$(warp_endpoint_json)
[[ "$second" == "$endpoint" ]] || { echo 'FAIL: saved identity was not reused' >&2; exit 1; }
rm -f "$conf_dir/warp/endpoint.json"
generate_unique_warp_identity() { red 'Registration rejected.'; return 2; }
if warp_endpoint_json >"$test_dir/failure-json" 2>"$test_dir/failure-log"; then
    echo 'FAIL: registration failure was accepted' >&2; exit 1;
fi
[[ ! -s "$test_dir/failure-json" ]] || { echo 'FAIL: registration failure polluted JSON output' >&2; exit 1; }
echo 'WARP first-registration JSON tests passed.'
