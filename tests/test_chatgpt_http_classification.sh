#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in extract_html_visible_text classify_chatgpt_response check_unlock_chatgpt; do source <(sed -n "/^${f}() {/,/^}/p" "$script"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
url=https://chatgpt.com/
assert_result() {
 local expected="$1" status="$2" code="$3" rc=0
 classify_chatgpt_response "$code" "$url" "$d/body" "$d/headers" || rc=$?
 [[ "$rc" == "$expected" && "$WARP_UNLOCK_STATUS" == "$status" ]] || { echo "unexpected result: $rc $WARP_UNLOCK_STATUS"; exit 1; }
}
: > "$d/headers"
printf '<title>ChatGPT</title><script src="/cdn/assets/app.js"></script>' > "$d/body"
assert_result 0 '网页可达' 200
printf 'cf-mitigated: challenge\r\n' > "$d/headers"
assert_result 2 '需要网页验证' 200
assert_result 2 '需要网页验证' 403
: > "$d/headers"
printf '<title>Just a moment...</title>' > "$d/body"
assert_result 2 '需要网页验证' 403
printf '{"error":{"code":"unsupported_country_region_territory"}}' > "$d/body"
assert_result 1 '地区不支持' 403
printf '{"error":{"code":"disallowed","message":"Request is not allowed"}}' > "$d/body"
assert_result 1 '请求被拒绝（HTTP 403）' 403
printf '<title>Attention Required! | Cloudflare</title>' > "$d/body"
assert_result 2 '请求被拦截（HTTP 403）' 403
printf '<html>forbidden</html>' > "$d/body"
assert_result 2 'HTTP 403，原因未确认' 403
assert_result 2 '请求过于频繁（HTTP 429）' 429
assert_result 2 '需要登录（HTTP 401）' 401
assert_result 2 '服务异常（HTTP 503）' 503
printf '<html>Hello</html>' > "$d/body"
assert_result 2 '未确认可用' 200
# An app shell with hidden fallback strings must not be rejected.
printf '<title>ChatGPT</title><script>window.__reactRouterContext={error:"unsupported country"}</script>' > "$d/body"
assert_result 0 '网页可达' 200
url=https://evil.example/path.chatgpt.com/
assert_result 2 '未确认可用' 200
url=https://chatgpt.com/
# The actual HTTP function must GET the web page, never call the iOS endpoint.
warp_platform_curl() {
 local o='' h=''
 while (($#)); do
  case "$1" in
    -o) o=$2; shift 2 ;;
    -D) h=$2; shift 2 ;;
    *ios.chat.openai.com*|-I|-sSIL) return 99 ;;
    *) shift ;;
  esac
 done
 printf '<title>ChatGPT</title><script src="/_next/static/app.js"></script>' > "$o"
 : > "$h"
 printf '200\thttps://chatgpt.com/'
 return "${HTTP_RC:-0}"
}
check_unlock_chatgpt proxy; [[ "$WARP_UNLOCK_STATUS" == '网页可达' ]]
HTTP_RC=28
if check_unlock_chatgpt proxy; then exit 1; else [[ "$?" == 2 ]]; fi
[[ "$WARP_UNLOCK_STATUS" == '检测超时' ]]
HTTP_RC=6
if check_unlock_chatgpt proxy; then exit 1; else [[ "$?" == 2 ]]; fi
[[ "$WARP_UNLOCK_STATUS" == '域名解析失败' ]]
echo 'ChatGPT web scope, challenge, denial, HTTP and transport classifications passed.'
