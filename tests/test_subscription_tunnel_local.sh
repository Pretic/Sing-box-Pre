#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

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
    detect_argo_tunnel_mode \
    strip_local_tunnel_subscription_rule \
    render_local_tunnel_with_subscription \
    remove_local_tunnel_subscription_rule; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
    source <(printf '%s\n' "$function_source")
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fixture="${tmp_dir}/tunnel.yml"
reuse_out="${tmp_dir}/reuse.yml"
reuse_again="${tmp_dir}/reuse-again.yml"
separate_out="${tmp_dir}/separate.yml"
removed_out="${tmp_dir}/removed.yml"
token='0123456789abcdefghjkmnpqrstvwxyz'

cat > "$fixture" <<'YAML'
tunnel: 11111111-2222-3333-4444-555555555555
credentials-file: /etc/sing-box/tunnel.json
protocol: http2

ingress:
  - hostname: argo.example.com
    service: http://127.0.0.1:8001
    originRequest:
      noTLSVerify: true
  - hostname: admin.example.com
    service: http://127.0.0.1:9000
  - service: http_status:404
YAML

render_local_tunnel_with_subscription \
    "$fixture" "$reuse_out" 'argo.example.com' \
    "^/sub/${token}$" 8080 reuse

marker_line="$(grep -n 'sing-box-subscription:start' "$reuse_out" | cut -d: -f1)"
node_line="$(grep -n 'hostname: argo.example.com' "$reuse_out" | tail -1 | cut -d: -f1)"
[[ "$marker_line" -lt "$node_line" ]]
[[ "$(grep -c 'sing-box-subscription:start' "$reuse_out")" == 1 ]]
grep -Fq "path: ^/sub/${token}$" "$reuse_out"
grep -Fq 'service: http://127.0.0.1:8080' "$reuse_out"
grep -Fq 'noTLSVerify: true' "$reuse_out"
grep -Fq 'hostname: admin.example.com' "$reuse_out"
[[ "$(grep -v '^[[:space:]]*$' "$reuse_out" | tail -1)" == '  - service: http_status:404' ]]

render_local_tunnel_with_subscription \
    "$reuse_out" "$reuse_again" 'argo.example.com' \
    "^/sub/${token}$" 8080 reuse
cmp -s "$reuse_out" "$reuse_again"

render_local_tunnel_with_subscription \
    "$fixture" "$separate_out" 'sub.example.com' \
    "^/${token}$" 8080 separate
separate_marker="$(grep -n 'sing-box-subscription:start' "$separate_out" | cut -d: -f1)"
catchall_line="$(grep -n 'service: http_status:404' "$separate_out" | cut -d: -f1)"
[[ "$separate_marker" -lt "$catchall_line" ]]
grep -Fq 'hostname: sub.example.com' "$separate_out"

remove_local_tunnel_subscription_rule "$reuse_out" "$removed_out"
if grep -q 'sing-box-subscription' "$removed_out"; then
    echo 'FAIL: managed local Tunnel block was not removed' >&2
    exit 1
fi
grep -Fq 'hostname: argo.example.com' "$removed_out"
grep -Fq 'hostname: admin.example.com' "$removed_out"

bad_fixture="${tmp_dir}/bad.yml"
sed '/http_status:404/d' "$fixture" > "$bad_fixture"
assert_rejected 'local Tunnel config without final catch-all' \
    render_local_tunnel_with_subscription "$bad_fixture" "${tmp_dir}/bad-out.yml" \
    'sub.example.com' "^/${token}$" 8080 separate
assert_rejected 'reuse hostname absent from local Tunnel config' \
    render_local_tunnel_with_subscription "$fixture" "${tmp_dir}/missing-host.yml" \
    'missing.example.com' "^/sub/${token}$" 8080 reuse
assert_rejected 'unanchored Tunnel path regex' \
    render_local_tunnel_with_subscription "$fixture" "${tmp_dir}/unsafe-path.yml" \
    'sub.example.com' "/${token}" 8080 separate

quick_service="${tmp_dir}/quick.service"
local_service="${tmp_dir}/local.service"
remote_service="${tmp_dir}/remote.service"
printf '%s\n' 'ExecStart=/etc/sing-box/argo tunnel --url http://127.0.0.1:8001 run' > "$quick_service"
printf '%s\n' 'ExecStart=/etc/sing-box/argo tunnel --config /etc/sing-box/tunnel.yml run' > "$local_service"
printf '%s\n' 'ExecStart=/etc/sing-box/argo tunnel run --token REDACTED' > "$remote_service"
[[ "$(detect_argo_tunnel_mode "$quick_service")" == quick ]]
[[ "$(detect_argo_tunnel_mode "$local_service")" == local ]]
[[ "$(detect_argo_tunnel_mode "$remote_service")" == remote ]]

apply_source="$(extract_function apply_local_tunnel_subscription_rule)"
[[ -n "$apply_source" ]] || {
    echo 'FAIL: apply_local_tunnel_subscription_rule is not implemented' >&2
    exit 1
}
grep -Fq 'ingress validate' <<< "$apply_source"
grep -Fq 'ingress rule' <<< "$apply_source"
grep -Fq 'restart_argo' <<< "$apply_source"

echo 'Local Tunnel subscription tests passed.'
