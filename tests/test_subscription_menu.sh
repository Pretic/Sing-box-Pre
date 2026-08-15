#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

for item in \
    '5. 查看订阅链接与详细状态' \
    '6. 配置 Cloudflare HTTPS 订阅' \
    '7. 关闭 Cloudflare HTTPS 订阅' \
    '8. 重新生成订阅密钥'; do
    grep -Fq "$item" "$script" || {
        echo "FAIL: subscription menu item is missing: $item" >&2
        exit 1
    }
done

menu_source="$(extract_function menu)"
if grep -Fq 'HTTPS 订阅' <<< "$menu_source"; then
    echo 'FAIL: main menu contains detailed HTTPS subscription status' >&2
    exit 1
fi
grep -Fq -- '--Nginx 状态:' <<< "$menu_source"

argo_source="$(extract_function manage_argo)"
grep -Fq '是否同时配置 Cloudflare HTTPS 订阅？[y/N]' <<< "$argo_source" || {
    echo 'FAIL: fixed Tunnel flow does not offer the optional HTTPS subscription setup' >&2
    exit 1
}
grep -Fq 'configure_cf_https_subscription' <<< "$argo_source"
grep -Fq 'SUB_HTTPS_ENABLED=0' <<< "$argo_source" || {
    echo 'FAIL: switching to a quick Tunnel does not suspend verified HTTPS state' >&2
    exit 1
}

subscription_menu_source="$(extract_function disable_open_sub)"
grep -Fq 'update_cf_https_subscription_origin' <<< "$subscription_menu_source" || {
    echo 'FAIL: changing the Nginx subscription port does not update the active Tunnel origin' >&2
    exit 1
}

for function_name in \
    verify_https_subscription \
    print_manual_https_route \
    configure_cf_https_subscription \
    disable_cf_https_subscription \
    rotate_subscription_token \
    show_subscription_status \
    update_cf_https_subscription_origin \
    apply_local_tunnel_subscription_removal \
    remove_remote_tunnel_subscription_via_api; do
    [[ -n "$(extract_function "$function_name")" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
expected_file="${tmp_dir}/sub.txt"
response_file="${tmp_dir}/response.txt"
mock_curl="${tmp_dir}/curl"
printf '%s' 'c3Vic2NyaXB0aW9uLWNvbnRlbnQ=' > "$expected_file"
printf '%s' 'c3Vic2NyaXB0aW9uLWNvbnRlbnQ=' > "$response_file"

cat > "$mock_curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
cp "$MOCK_HTTPS_RESPONSE" "$output"
MOCK
chmod +x "$mock_curl"

export CURL_BIN="$mock_curl"
export MOCK_HTTPS_RESPONSE="$response_file"
work_dir="$tmp_dir"
SUB_HTTPS_VERIFIED_AT='unchanged'
source <(extract_function verify_https_subscription)

verify_https_subscription 'https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' "$expected_file"
[[ "$SUB_HTTPS_VERIFIED_AT" == unchanged ]]

printf '%s' 'different-content' > "$response_file"
if verify_https_subscription 'https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' "$expected_file"; then
    echo 'FAIL: HTTPS verification accepted mismatched content' >&2
    exit 1
fi
[[ "$SUB_HTTPS_VERIFIED_AT" == unchanged ]]

manual_source="$(extract_function print_manual_https_route)"
grep -Fq 'Hostname:' <<< "$manual_source"
grep -Fq 'Path:' <<< "$manual_source"
grep -Fq 'Type:' <<< "$manual_source"
grep -Fq 'http://localhost:' <<< "$manual_source"

for documentation_item in \
    '## 可选的 Cloudflare HTTPS 订阅' \
    '默认仍生成 HTTP 原始订阅' \
    '用户自己的 Cloudflare 域名' \
    'Cloudflare Tunnel/Connector Write' \
    'DNS Write' \
    '不写入磁盘' \
    'IPv4 单栈' \
    'IPv6 单栈' \
    '关闭节点订阅' \
    '关闭 Cloudflare HTTPS 订阅' \
    '重新生成订阅密钥'; do
    grep -Fq "$documentation_item" "$repo_root/README.md" || {
        echo "FAIL: README does not document: ${documentation_item}" >&2
        exit 1
    }
done

if rg -n 'cfut_|988600\.xyz|sing-box-subscription\.service|sing-box-subscription\.py|subscription-path|localhost:8081' \
    "$script" "$repo_root/README.md"; then
    echo 'FAIL: current private VPS implementation leaked into public runtime files' >&2
    exit 1
fi

echo 'Subscription workflow and menu tests passed.'
