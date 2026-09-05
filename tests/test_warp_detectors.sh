#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

source <(
    for name in check_unlock_netflix check_unlock_disney check_unlock_chatgpt \
      extract_html_visible_text check_unlock_gemini run_selected_unlock_checks; do
        extract_function "$name"
    done
)

curl() {
    local output='' format='' url='' code=200 effective='' body='' curl_rc=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
          -o) output="$2"; shift 2 ;;
          -w) format="$2"; shift 2 ;;
          https://*) url="$1"; shift ;;
          *) shift ;;
        esac
    done
    effective="$url"
    case "${MOCK_CASE}:${url}" in
      chatgpt-403:https://chatgpt.com) code=403; body='<html>challenge</html>' ;;
      chatgpt-403:https://ios.chat.openai.com) code=200; body='{"status":"ok"}' ;;
      chatgpt-restricted:https://chatgpt.com) code=403; body='<html>challenge</html>' ;;
      chatgpt-restricted:https://ios.chat.openai.com) code=403; body='{"cf_details":"Request is not allowed. Please try again later.","type":"dc"}' ;;
      chatgpt-web-error:https://chatgpt.com) code=000; body=''; curl_rc=28 ;;
      chatgpt-web-error:https://ios.chat.openai.com) code=403; body='{"cf_details":"Request is not allowed. Please try again later.","type":"dc"}' ;;
      chatgpt-web-error-clean:https://chatgpt.com) code=000; body=''; curl_rc=28 ;;
      chatgpt-web-error-clean:https://ios.chat.openai.com) code=200; body='{"status":"ok"}' ;;
      chatgpt-pass:https://chatgpt.com) code=200; body='<html>ChatGPT</html>' ;;
      chatgpt-pass:https://ios.chat.openai.com) code=200; body='{"status":"ok"}' ;;
      chatgpt-subdomain:https://chatgpt.com) code=200; effective='https://www.chatgpt.com/'; body='<html>ChatGPT</html>' ;;
      chatgpt-subdomain:https://ios.chat.openai.com) code=200; body='{"status":"ok"}' ;;
      chatgpt-path-spoof:https://chatgpt.com) code=200; effective='https://evil.com/path.chatgpt.com/'; body='<html>ChatGPT</html>' ;;
      chatgpt-path-spoof:https://ios.chat.openai.com) code=200; body='{"status":"ok"}' ;;
      gemini-timeout:https://gemini.google.com/app) code=000; curl_rc=28 ;;
      gemini-generic:https://gemini.google.com/app) code=200; body='<html>Google sign in</html>' ;;
      gemini-pass:https://gemini.google.com/app) code=200; body='[45631641,null,true]' ;;
      gemini-legacy-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title></head><body>[45631641,null,true] Service unavailable for maintenance</body></html>' ;;
      gemini-legacy-restricted:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title></head><body>[45631641,null,true] Gemini is unavailable in this region</body></html>' ;;
      gemini-current:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini","Something went wrong. Try again later.","maintenance"]});</script></head><body>Google AI</body></html>' ;;
      gemini-current-multiline:https://gemini.google.com/app) code=200; body=$'<html>\n<head><title>Gemini</title>\n<script src="/_/BardChatUi/_/js/app.js"></script>\n<script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script>\n<script>\nconst fallback = "Something went wrong. Try again later.";\n</script>\n<style>\n.maintenance { display: none; }\n</style></head>\n<body>Google AI</body>\n</html>' ;;
      gemini-current-template:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body>Google AI<template><p>Something went wrong. Try again later.</p></template></body></html>' ;;
      gemini-current-hidden:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body>Google AI<section class="notice" hidden>Scheduled maintenance</section></body></html>' ;;
      gemini-current-quoted-attribute:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><div data-note="safe > Something went wrong. Try again later.">Google AI</div></body></html>' ;;
      gemini-current-hidden-solidus:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><div hidden/>Something went wrong. Try again later.</div><p>Google AI</p></body></html>' ;;
      gemini-current-nested-list-scope:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><ul><li hidden>placeholder<ul><li>Something went wrong. Try again later.</li></ul></li></ul><p>Google AI</p></body></html>' ;;
      gemini-current-template-li-scope:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><ul><li hidden>placeholder<template><li>Something went wrong. Try again later.</li></template></li></ul><p>Google AI</p></body></html>' ;;
      gemini-current-template-p-scope:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<template><p>Service temporarily unavailable</p></template></p><p>Google AI</p></body></html>' ;;
      gemini-current-template-button-scope:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><button hidden>placeholder<template><button>Something went wrong. Try again later.</button></template></button><p>Google AI</p></body></html>' ;;
      gemini-current-p-start-button-scope:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<button><center>Something went wrong. Try again later.</center></button></p><p>Google AI</p></body></html>' ;;
      gemini-current-explicit-li-scope:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><ul><li hidden>placeholder<ul></li>Something went wrong. Try again later.</ul></li></ul><p>Google AI</p></body></html>' ;;
      gemini-current-explicit-p-button-scope:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<button></p>Something went wrong. Try again later.</button></p><p>Google AI</p></body></html>' ;;
      gemini-current-explicit-button-template-scope:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><button hidden>placeholder<template></button>Something went wrong. Try again later.</template></button><p>Google AI</p></body></html>' ;;
      gemini-current-explicit-div-template-scope:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><div hidden>placeholder<template></div>Something went wrong. Try again later.</template></div><p>Google AI</p></body></html>' ;;
      gemini-current-plaintext-hidden:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><div hidden><plaintext><script>Something went wrong. Try again later.</script></div></body></html>' ;;
      gemini-current-xmp-hidden:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><div hidden><xmp><script>Something went wrong. Try again later.</script></xmp></div><p>Google AI</p></body></html>' ;;
      gemini-marker-implicit-p-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<p>Service temporarily unavailable</body></html>' ;;
      gemini-marker-implicit-li-restricted:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><ul><li hidden>placeholder<li>Gemini is unavailable in this region</ul></body></html>' ;;
      gemini-marker-implicit-button-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><button hidden>placeholder<button>Service temporarily unavailable</button></button></body></html>' ;;
      gemini-marker-p-close-li-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<li>Service temporarily unavailable</li></body></html>' ;;
      gemini-marker-p-close-summary-restricted:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<summary>Gemini is unavailable in this region</summary></body></html>' ;;
      gemini-marker-p-close-center-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<center>Service temporarily unavailable</center></body></html>' ;;
      gemini-marker-p-close-dir-restricted:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<dir>Gemini is unavailable in this region</dir></body></html>' ;;
      gemini-marker-p-close-listing-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<listing>Service temporarily unavailable</listing></body></html>' ;;
      gemini-marker-p-close-plaintext-restricted:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><p hidden>placeholder<plaintext>Gemini is unavailable in this region</body></html>' ;;
      gemini-marker-heading-close-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><h1 hidden>placeholder<h2>Service temporarily unavailable</h2></body></html>' ;;
      gemini-marker-dd-close-dt-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><dl><dd hidden>placeholder<dt>Service temporarily unavailable</dt></dl></body></html>' ;;
      gemini-marker-dt-close-dd-restricted:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><dl><dt hidden>placeholder<dd>Gemini is unavailable in this region</dd></dl></body></html>' ;;
      gemini-marker-td-close-th-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><table><tr><td hidden>placeholder<th>Service temporarily unavailable</th></tr></table></body></html>' ;;
      gemini-marker-th-close-td-restricted:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><table><tr><th hidden>placeholder<td>Gemini is unavailable in this region</td></tr></table></body></html>' ;;
      gemini-marker-plaintext-raw-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><plaintext><script>Service temporarily unavailable</script></body></html>' ;;
      gemini-marker-xmp-raw-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body><xmp><script>Service temporarily unavailable</script></xmp></body></html>' ;;
      gemini-title-restricted:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title></head><body>Not currently available in your country</body></html>' ;;
      gemini-title-restricted-alt:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title></head><body>Gemini is not currently supported in your country</body></html>' ;;
      gemini-title-maintenance:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title></head><body>Service temporarily unavailable</body></html>' ;;
      gemini-marker-maintenance:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body>Service temporarily unavailable for maintenance</body></html>' ;;
      gemini-marker-error:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body>500 Internal Server Error. Something went wrong. Try again later.</body></html>' ;;
      gemini-marker-empty-shell:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:[]});</script></head><body></body></html>' ;;
      gemini-marker-no-title:https://gemini.google.com/app) code=200; body='<html><head><title>Google AI</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body>Google AI</body></html>' ;;
      gemini-marker-restricted-alt:https://gemini.google.com/app) code=200; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head><body>Gemini is unavailable&nbsp;in <strong>this</strong>&#32;region</body></html>' ;;
      gemini-marker-wrong-host:https://gemini.google.com/app) code=200; effective='https://accounts.google.com/'; body='<html><head><title>Gemini</title><script src="/_/BardChatUi/_/js/app.js"></script><script>AF_initDataCallback({key:"ds:0",data:["Gemini"]});</script></head></html>' ;;
      netflix-no-region:https://www.netflix.com/title/*) code=200; body='<meta property="og:video">' ;;
      netflix-pass:https://www.netflix.com/title/*) code=200; body='{"requestCountry":{"id":"US"}}<meta property="og:video">' ;;
      disney-assertion:https://disney.api.edge.bamgrid.com/devices) body='{"assertion":"device-token"}' ;;
      disney-assertion:https://disney.api.edge.bamgrid.com/token) body='{}' ;;
      *) code=500; body='' ;;
    esac
    if [ -n "$output" ] && [ "$output" != /dev/null ]; then
        printf '%s' "$body" > "$output"
    elif [ -z "$output" ]; then
        printf '%s' "$body"
    fi
    [ "$curl_rc" -eq 0 ] || return "$curl_rc"
    case "$format" in
      *url_effective*) printf '%s\t%s' "$code" "$effective" ;;
      *http_code*) printf '%s' "$code" ;;
    esac
}

MOCK_CASE=chatgpt-403
if check_unlock_chatgpt proxy; then fail 'ChatGPT HTTP 403 was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "ChatGPT HTTP 403 returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=chatgpt-pass
check_unlock_chatgpt proxy || fail 'ChatGPT known-good response was rejected'

MOCK_CASE=chatgpt-subdomain
check_unlock_chatgpt proxy || fail 'ChatGPT genuine subdomain was rejected'

MOCK_CASE=chatgpt-path-spoof
if check_unlock_chatgpt proxy; then fail 'ChatGPT path spoof on an external host was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "ChatGPT path spoof returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=chatgpt-restricted
if check_unlock_chatgpt proxy; then fail 'ChatGPT explicit not-allowed response was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "ChatGPT explicit restriction returned ${rc}, expected restricted rc=1"

MOCK_CASE=chatgpt-web-error
if check_unlock_chatgpt proxy; then fail 'ChatGPT restriction was accepted after the web probe failed'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "ChatGPT web probe failure hid an explicit restriction: rc=${rc}, expected restricted rc=1"

MOCK_CASE=chatgpt-web-error-clean
if check_unlock_chatgpt proxy; then fail 'ChatGPT was accepted without a successful web probe'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "ChatGPT missing web evidence returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-generic
if check_unlock_gemini proxy; then fail 'Gemini generic HTTP 200 page was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini generic page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-timeout
if check_unlock_gemini proxy; then fail 'Gemini timeout was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail 'Gemini timeout must remain inconclusive'
[[ "$WARP_UNLOCK_STATUS" == *'超时'* ]] || fail 'Gemini timeout reason was hidden'

MOCK_CASE=gemini-pass
check_unlock_gemini proxy || fail 'Gemini positive application marker was rejected'

MOCK_CASE=gemini-legacy-error
if check_unlock_gemini proxy; then fail 'Gemini legacy marker overrode an explicit service error'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini legacy marker error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-legacy-restricted
if check_unlock_gemini proxy; then fail 'Gemini legacy marker overrode an explicit region restriction'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini legacy marker restricted page returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-current
check_unlock_gemini proxy || fail 'Gemini current application page was rejected after the legacy marker disappeared'
[ "$WARP_UNLOCK_STATUS" = '网络/地区可用' ] || fail "Gemini current page status was ${WARP_UNLOCK_STATUS}, expected 网络/地区可用"

MOCK_CASE=gemini-current-multiline
check_unlock_gemini proxy || fail 'Gemini multiline application page was rejected because hidden script/style fallback text was scanned'
[ "$WARP_UNLOCK_STATUS" = '网络/地区可用' ] || fail "Gemini multiline page status was ${WARP_UNLOCK_STATUS}, expected 网络/地区可用"

MOCK_CASE=gemini-current-template
check_unlock_gemini proxy || fail 'Gemini application page was rejected because inert template text was scanned'

MOCK_CASE=gemini-current-hidden
check_unlock_gemini proxy || fail 'Gemini application page was rejected because hidden element text was scanned'

MOCK_CASE=gemini-current-quoted-attribute
check_unlock_gemini proxy || fail 'Gemini application page was rejected because quoted attribute text after > was scanned'

MOCK_CASE=gemini-current-hidden-solidus
check_unlock_gemini proxy || fail 'Gemini hidden non-void element with a trailing slash exposed hidden error text'

MOCK_CASE=gemini-current-nested-list-scope
check_unlock_gemini proxy || fail 'Gemini nested list crossed li scope and exposed hidden error text'

MOCK_CASE=gemini-current-template-li-scope
check_unlock_gemini proxy || fail 'Gemini template boundary was crossed while implicitly closing li'

MOCK_CASE=gemini-current-template-p-scope
check_unlock_gemini proxy || fail 'Gemini template boundary was crossed while implicitly closing p'

MOCK_CASE=gemini-current-template-button-scope
check_unlock_gemini proxy || fail 'Gemini template boundary was crossed while implicitly closing button'

MOCK_CASE=gemini-current-p-start-button-scope
check_unlock_gemini proxy || fail 'Gemini p start-tag closure crossed a button scope'

MOCK_CASE=gemini-current-explicit-li-scope
check_unlock_gemini proxy || fail 'Gemini explicit li end tag crossed a nested list scope'

MOCK_CASE=gemini-current-explicit-p-button-scope
check_unlock_gemini proxy || fail 'Gemini explicit p end tag crossed a button scope'

MOCK_CASE=gemini-current-explicit-button-template-scope
check_unlock_gemini proxy || fail 'Gemini explicit button end tag crossed a template scope'

MOCK_CASE=gemini-current-explicit-div-template-scope
check_unlock_gemini proxy || fail 'Gemini explicit div end tag crossed a template scope'

MOCK_CASE=gemini-current-plaintext-hidden
check_unlock_gemini proxy || fail 'Gemini hidden plaintext content was treated as visible'

MOCK_CASE=gemini-current-xmp-hidden
check_unlock_gemini proxy || fail 'Gemini hidden xmp content was treated as visible'

MOCK_CASE=gemini-marker-implicit-p-error
if check_unlock_gemini proxy; then fail 'Gemini visible error after an implicitly closed hidden p was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini implicit-p error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-implicit-li-restricted
if check_unlock_gemini proxy; then fail 'Gemini visible restriction after an implicitly closed hidden li was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini implicit-li restriction page returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-marker-implicit-button-error
if check_unlock_gemini proxy; then fail 'Gemini visible error after an implicitly closed hidden button was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini implicit-button error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-p-close-li-error
if check_unlock_gemini proxy; then fail 'Gemini visible error after li implicitly closed a hidden p was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini p-close-li error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-p-close-summary-restricted
if check_unlock_gemini proxy; then fail 'Gemini visible restriction after summary implicitly closed a hidden p was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini p-close-summary restriction returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-marker-p-close-center-error
if check_unlock_gemini proxy; then fail 'Gemini visible error after center implicitly closed a hidden p was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini p-close-center error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-p-close-dir-restricted
if check_unlock_gemini proxy; then fail 'Gemini visible restriction after dir implicitly closed a hidden p was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini p-close-dir restriction returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-marker-p-close-listing-error
if check_unlock_gemini proxy; then fail 'Gemini visible error after listing implicitly closed a hidden p was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini p-close-listing error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-p-close-plaintext-restricted
if check_unlock_gemini proxy; then fail 'Gemini visible restriction after plaintext implicitly closed a hidden p was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini p-close-plaintext restriction returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-marker-heading-close-error
if check_unlock_gemini proxy; then fail 'Gemini visible error after a heading implicitly closed another heading was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini heading-close error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-dd-close-dt-error
if check_unlock_gemini proxy; then fail 'Gemini visible error after dt implicitly closed dd was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini dd-close-dt error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-dt-close-dd-restricted
if check_unlock_gemini proxy; then fail 'Gemini visible restriction after dd implicitly closed dt was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini dt-close-dd restriction returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-marker-td-close-th-error
if check_unlock_gemini proxy; then fail 'Gemini visible error after th implicitly closed td was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini td-close-th error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-th-close-td-restricted
if check_unlock_gemini proxy; then fail 'Gemini visible restriction after td implicitly closed th was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini th-close-td restriction returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-marker-plaintext-raw-error
if check_unlock_gemini proxy; then fail 'Gemini visible plaintext error containing script characters was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini plaintext raw error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-xmp-raw-error
if check_unlock_gemini proxy; then fail 'Gemini visible xmp error containing script characters was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini xmp raw error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-title-restricted
if check_unlock_gemini proxy; then fail 'Gemini titled restriction page was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini titled restriction returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-title-restricted-alt
if check_unlock_gemini proxy; then fail 'Gemini alternative titled restriction page was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini alternative titled restriction returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-title-maintenance
if check_unlock_gemini proxy; then fail 'Gemini branded maintenance page was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini branded maintenance page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-maintenance
if check_unlock_gemini proxy; then fail 'Gemini static marker on a maintenance page was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini marker maintenance page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-error
if check_unlock_gemini proxy; then fail 'Gemini static marker on an error page was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini marker error page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-empty-shell
if check_unlock_gemini proxy; then fail 'Gemini double-marker empty shell was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini double-marker empty shell returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-no-title
if check_unlock_gemini proxy; then fail 'Gemini double-marker page without a Gemini title was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini marker page without a Gemini title returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-marker-restricted-alt
if check_unlock_gemini proxy; then fail 'Gemini initialized application page overrode an explicit region restriction'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "Gemini initialized restricted page returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-marker-wrong-host
if check_unlock_gemini proxy; then fail 'Gemini application marker on a non-Gemini effective host was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini wrong effective host returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=netflix-no-region
if check_unlock_netflix proxy; then fail 'Netflix response without a region was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Netflix missing-region response returned ${rc}, expected rc=2"

MOCK_CASE=netflix-pass
check_unlock_netflix proxy || fail 'Netflix two-title positive response was rejected'

MOCK_CASE=disney-assertion
if check_unlock_disney proxy; then fail 'Disney assertion-only response was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Disney assertion-only response returned ${rc}, expected rc=2"

if run_selected_unlock_checks proxy ''; then fail 'empty platform selection was accepted'; fi
if run_selected_unlock_checks proxy 15; then fail 'invalid platform selection was accepted'; fi

echo 'WARP detector tests passed.'
