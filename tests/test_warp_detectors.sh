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
      check_unlock_gemini run_selected_unlock_checks; do
        extract_function "$name"
    done
)

curl() {
    local output='' format='' url='' code=200 effective='' body=''
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
      chatgpt-pass:https://chatgpt.com) code=200; body='<html>ChatGPT</html>' ;;
      chatgpt-pass:https://ios.chat.openai.com) code=200; body='{"status":"ok"}' ;;
      gemini-generic:https://gemini.google.com/app) code=200; body='<html>Google sign in</html>' ;;
      gemini-pass:https://gemini.google.com/app) code=200; body='[45631641,null,true]' ;;
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

MOCK_CASE=chatgpt-restricted
if check_unlock_chatgpt proxy; then fail 'ChatGPT explicit not-allowed response was accepted'; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "ChatGPT explicit restriction returned ${rc}, expected restricted rc=1"

MOCK_CASE=gemini-generic
if check_unlock_gemini proxy; then fail 'Gemini generic HTTP 200 page was accepted'; else rc=$?; fi
[ "$rc" -eq 2 ] || fail "Gemini generic page returned ${rc}, expected ambiguous rc=2"

MOCK_CASE=gemini-pass
check_unlock_gemini proxy || fail 'Gemini positive application marker was rejected'

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
