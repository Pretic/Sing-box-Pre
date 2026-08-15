#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for function_name in \
    delete_warp_registration \
    start_warp_candidate_proxy \
    stop_warp_candidate_proxy \
    probe_warp_trace \
    check_unlock_netflix \
    check_unlock_disney \
    check_unlock_chatgpt \
    check_unlock_gemini \
    run_selected_unlock_checks \
    activate_warp_candidate \
    rotate_warp_identity_once \
    auto_select_warp_candidate \
    show_warp_status_and_unlocks \
    get_warp_menu_status; do
    grep -Eq "^${function_name}\(\) \{" "$script" || fail "${function_name} is not implemented"
done

grep -Fq 'local state_dir="${1:-${conf_dir}/warp}"' "$script" || \
    fail 'identity generation does not accept an isolated destination'
grep -Fq 'local WARP_MAX_CANDIDATES=5' "$script" || \
    fail 'automatic selection is not capped at five candidates'
grep -Fq -- '---WARP 状态:' "$script" || fail 'main-menu WARP status is missing'
grep -Fq '5. 查看内置 WARP 状态及解锁情况' "$script" || fail 'status menu item is missing'
grep -Fq '6. 更换内置 WARP 身份/IP' "$script" || fail 'single rotation menu item is missing'
grep -Fq '7. 自动优选 WARP IP（多平台解锁）' "$script" || fail 'automatic selector menu item is missing'

for service in Netflix Disney+ ChatGPT Gemini; do
    grep -Fq "$service" "$script" || fail "$service unlock support is missing"
done

if grep -nE 'show_warp_status_and_unlocks|get_warp_menu_status' "$script" | \
   grep -Eq 'private_key|\.token|client_id|reserved'; then
    fail 'status functions appear to expose WARP credentials'
fi

grep -Fq 'not configured' "$script" || fail 'not configured status is missing'
grep -Fq 'degraded' "$script" || fail 'degraded status is missing'

chatgpt_block=$(sed -n '/^check_unlock_chatgpt() {/,/^check_unlock_gemini() {/p' "$script")
grep -Fq '%{http_code}' <<< "$chatgpt_block" || \
    fail 'ChatGPT reachability does not record the final HTTP status'
grep -Fq '%{url_effective}' <<< "$chatgpt_block" || \
    fail 'ChatGPT reachability does not record the final URL'
! grep -Eq '\(200\|301\|302\|307\|308\|403\)|\^\(200\|301\|302\|307\|308\|403\)' <<< "$chatgpt_block" || \
    fail 'ChatGPT HTTP 403 must never be accepted as unlocked'
grep -Fq 'ios.chat.openai.com' <<< "$chatgpt_block" || fail 'ChatGPT iOS restriction probe is missing'
grep -Fq "'\\(1\\)|\\(2\\)'" <<< "$chatgpt_block" || fail 'ChatGPT disallowed-ISP markers are not checked'
! grep -Fq 'ios.chat.openai.com 2>/dev/null || true' <<< "$chatgpt_block" || \
    fail 'ChatGPT iOS network failures are silently accepted'

disney_block=$(sed -n '/^check_unlock_disney() {/,/^check_unlock_chatgpt() {/p' "$script")
grep -Fq 'disney.api.edge.bamgrid.com/token' <<< "$disney_block" || \
    fail 'Disney token exchange is missing'
grep -Fq 'graph/v1/device/graphql' <<< "$disney_block" || \
    fail 'Disney supported-location GraphQL probe is missing'
grep -Fq 'inSupportedLocation' <<< "$disney_block" || \
    fail 'Disney supported-location result is not checked'

netflix_block=$(sed -n '/^check_unlock_netflix() {/,/^check_unlock_disney() {/p' "$script")
grep -Fq '81280792' <<< "$netflix_block" || fail 'Netflix primary title probe is missing'
grep -Fq '70143836' <<< "$netflix_block" || fail 'Netflix secondary title probe is missing'
grep -Fq 'requestCountry' <<< "$netflix_block" || fail 'Netflix region parsing is missing'
grep -Eq '\[ -n "\$region" \]|\[\[ -n "\$region" \]\]' <<< "$netflix_block" || \
    fail 'Netflix must reject ambiguous responses without a region'

gemini_block=$(sed -n '/^check_unlock_gemini() {/,/^run_selected_unlock_checks() {/p' "$script")
grep -Fq 'Accept-Language: en-US,en;q=0.9' <<< "$gemini_block" || \
    fail 'Gemini probe does not request a stable English response'
grep -Fq '%{url_effective}' <<< "$gemini_block" || \
    fail 'Gemini probe does not validate the effective URL'
grep -Fq '45631641,null,true' <<< "$gemini_block" || \
    fail 'Gemini probe lacks a positive application marker'
! grep -Fq 'head -c 200000' <<< "$gemini_block" || \
    fail 'Gemini probe truncates the response before checking markers'

stop_block=$(sed -n '/^stop_warp_candidate_proxy() {/,/^start_warp_candidate_proxy() {/p' "$script")
grep -Fq '/proc/${WARP_PROBE_PID}/cmdline' <<< "$stop_block" || \
    fail 'probe cleanup does not verify process ownership'
grep -Fq '"${conf_dir}/warp/.probe."*' <<< "$stop_block" || \
    fail 'probe cleanup does not constrain its directory'
status_block=$(sed -n '/^show_warp_status_and_unlocks() {/,/^get_warp_menu_status() {/p' "$script")
! grep -Fq 'ensure_warp_prerequisites' <<< "$status_block" || \
    fail 'status-only action mutates WARP prerequisites'

activate_block=$(sed -n '/^activate_warp_candidate() {/,/^verify_activated_warp() {/p' "$script")
grep -Fq 'return 2' <<< "$activate_block" || \
    fail 'activation does not distinguish an incomplete rollback from a normal rejection'
grep -Fq '保留恢复目录' <<< "$activate_block" || \
    fail 'activation does not preserve recovery data after an incomplete rollback'

auto_block=$(sed -n '/^auto_select_warp_candidate() {/,/^show_warp_status_and_unlocks() {/p' "$script")
grep -Eq 'activate_rc.*-eq 2' <<< "$auto_block" || \
    fail 'automatic selection does not stop immediately after an incomplete rollback'

echo 'WARP rotation tests passed.'
