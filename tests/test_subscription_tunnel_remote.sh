#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
if [[ -z "${JQ_BIN:-}" ]]; then
    if command -v jq >/dev/null 2>&1; then
        JQ_BIN="$(command -v jq)"
    elif [[ -x "${repo_root}/../tools/jq.exe" ]]; then
        JQ_BIN="${repo_root}/../tools/jq.exe"
    else
        echo 'FAIL: jq is required for remote Tunnel subscription tests' >&2
        exit 1
    fi
fi
export JQ_BIN

[[ -x "$JQ_BIN" ]] || {
    echo "FAIL: test jq is missing: $JQ_BIN" >&2
    exit 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

assert_rejected() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: accepted ${description}" >&2
        exit 1
    fi
}

for function_name in \
    is_valid_subscription_domain \
    is_valid_subscription_path \
    is_valid_tunnel_subscription_regex \
    build_remote_tunnel_config \
    remove_remote_tunnel_subscription_rule \
    build_dns_change_plan; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
    source <(printf '%s\n' "$function_source")
done

token='0123456789abcdefghjkmnpqrstvwxyz'
fixture='{
  "ingress": [
    {
      "hostname": "argo.example.com",
      "service": "http://127.0.0.1:8001",
      "originRequest": {"noTLSVerify": true}
    },
    {
      "hostname": "admin.example.com",
      "service": "http://127.0.0.1:9000",
      "originRequest": {"connectTimeout": "30s"}
    },
    {"service": "http_status:404"}
  ],
  "warp-routing": {"enabled": true},
  "unknownFutureField": {"preserve": "yes"}
}'

updated="$(build_remote_tunnel_config \
    "$fixture" 'argo.example.com' "^/sub/${token}$" \
    'http://127.0.0.1:8080' reuse '' '')"

"$JQ_BIN" -e '."warp-routing".enabled == true' <<< "$updated" >/dev/null
"$JQ_BIN" -e '.unknownFutureField.preserve == "yes"' <<< "$updated" >/dev/null
"$JQ_BIN" -e '.ingress[-1].service == "http_status:404"' <<< "$updated" >/dev/null
"$JQ_BIN" -e --arg path "^/sub/${token}$" '
  .ingress[0].hostname == "argo.example.com" and
  .ingress[0].path == $path and
  .ingress[0].service == "http://127.0.0.1:8080"
' <<< "$updated" >/dev/null
"$JQ_BIN" -e '.ingress[1].originRequest.noTLSVerify == true' <<< "$updated" >/dev/null
[[ "$("$JQ_BIN" --arg path "^/sub/${token}$" \
    '[.ingress[] | select(.path? == $path)] | length' <<< "$updated")" == 1 ]]

idempotent="$(build_remote_tunnel_config \
    "$updated" 'argo.example.com' "^/sub/${token}$" \
    'http://127.0.0.1:8080' reuse 'argo.example.com' "^/sub/${token}$")"
diff -u <("$JQ_BIN" -S . <<< "$updated") <("$JQ_BIN" -S . <<< "$idempotent")

separate="$(build_remote_tunnel_config \
    "$fixture" 'sub.example.com' "^/${token}$" \
    'http://127.0.0.1:8080' separate '' '')"
[[ "$("$JQ_BIN" -r '.ingress[-2].hostname' <<< "$separate")" == 'sub.example.com' ]]
[[ "$("$JQ_BIN" -r '.ingress[-1].service' <<< "$separate")" == 'http_status:404' ]]

removed="$(remove_remote_tunnel_subscription_rule \
    "$updated" 'argo.example.com' "^/sub/${token}$")"
[[ "$("$JQ_BIN" --arg path "^/sub/${token}$" \
    '[.ingress[] | select(.path? == $path)] | length' <<< "$removed")" == 0 ]]
"$JQ_BIN" -e '.ingress[0].originRequest.noTLSVerify == true' <<< "$removed" >/dev/null

bad_no_catchall='{"ingress":[{"hostname":"argo.example.com","service":"http://localhost:8001"}]}'
assert_rejected 'remote config without final catch-all' \
    build_remote_tunnel_config "$bad_no_catchall" 'sub.example.com' "^/${token}$" \
    'http://127.0.0.1:8080' separate '' ''
assert_rejected 'reuse host absent from remote config' \
    build_remote_tunnel_config "$fixture" 'missing.example.com' "^/sub/${token}$" \
    'http://127.0.0.1:8080' reuse '' ''
assert_rejected 'invalid JSON' \
    build_remote_tunnel_config '{invalid' 'sub.example.com' "^/${token}$" \
    'http://127.0.0.1:8080' separate '' ''

records_empty='[]'
create_plan="$(build_dns_change_plan "$records_empty" \
    '11111111-2222-3333-4444-555555555555' 'sub.example.com')"
[[ "$("$JQ_BIN" -r '.action' <<< "$create_plan")" == create ]]
[[ "$("$JQ_BIN" -r '.desired.content' <<< "$create_plan")" == \
   '11111111-2222-3333-4444-555555555555.cfargotunnel.com' ]]

records_old='[{"id":"dns-1","type":"CNAME","name":"sub.example.com","content":"old.example.net","proxied":false,"ttl":120}]'
update_plan="$(build_dns_change_plan "$records_old" \
    '11111111-2222-3333-4444-555555555555' 'sub.example.com')"
[[ "$("$JQ_BIN" -r '.action' <<< "$update_plan")" == update ]]
[[ "$("$JQ_BIN" -r '.original.id' <<< "$update_plan")" == dns-1 ]]

records_ready='[{"id":"dns-1","type":"CNAME","name":"sub.example.com","content":"11111111-2222-3333-4444-555555555555.cfargotunnel.com","proxied":true,"ttl":1}]'
noop_plan="$(build_dns_change_plan "$records_ready" \
    '11111111-2222-3333-4444-555555555555' 'sub.example.com')"
[[ "$("$JQ_BIN" -r '.action' <<< "$noop_plan")" == noop ]]

api_source="$(extract_function cloudflare_api)"
apply_source="$(extract_function apply_remote_tunnel_subscription_rule)"
[[ -n "$api_source" && -n "$apply_source" ]] || {
    echo 'FAIL: remote Cloudflare API transaction functions are missing' >&2
    exit 1
}
grep -Fq -- '--config -' <<< "$api_source"
grep -Fq 'unset CF_API_TOKEN' <<< "$apply_source"
grep -Fq 'rollback_remote_tunnel_configuration' <<< "$apply_source"
grep -Fq 'rollback_cloudflare_dns_change' <<< "$apply_source"

echo 'Remote Tunnel subscription tests passed.'
