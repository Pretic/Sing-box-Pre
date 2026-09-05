#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for name in is_valid_ipv4_address is_valid_ipv6_address warp_underlay_family warp_bootstrap_ip_valid warp_forget_bootstrap_ip warp_resolve_bootstrap_ip render_warp_probe_config; do
    source <(sed -n "/^${name}() {/,/^}/p" "$script")
done
MOCK_TMP=$(mktemp -d); trap 'rm -rf -- "$MOCK_TMP"' EXIT
conf_dir="$MOCK_TMP/conf"; mkdir -p "$conf_dir/warp"
fail() { echo "FAIL: $*" >&2; exit 1; }
declare -F warp_resolve_bootstrap_ip >/dev/null || fail 'bounded bootstrap DNS resolver missing'
MOCK_NOW=1700000000; date() { echo "$MOCK_NOW"; }
MOCK_UNDERLAY=4
ip() { [[ "$1" == "-$MOCK_UNDERLAY" ]]; }
timeout() { [[ "$MOCK_NATIVE" == yes ]] || return 124; echo '162.159.137.105 STREAM fixture'; }
curl() {
    echo request >> "$MOCK_TMP/requests"
    case "$*" in *cloudflare-dns.com*) return 7 ;; esac
    if [[ "$scenario" == malformed ]]; then echo '{"Status":0,"Question":[{"name":"wrong.example","type":1}],"Answer":[{"type":1,"TTL":60,"data":"127.0.0.1"}]}'; return; fi
    if [[ "$MOCK_UNDERLAY" == 6 ]]; then
        [[ " $* " == *' type=AAAA '* ]] || return 22
        echo '{"Status":0,"Question":[{"name":"api.cloudflareclient.com","type":28}],"Answer":[{"type":28,"TTL":20,"data":"2606:4700:110::1"}]}'
        return
    fi
    printf '{"Status":0,"Question":[{"name":"api.cloudflareclient.com","type":1}],"Answer":[{"type":1,"TTL":%s,"data":"162.159.137.106"}]}\n' "$MOCK_TTL"
}
MOCK_NATIVE=yes; scenario=good; MOCK_TTL=20
[[ "$(warp_resolve_bootstrap_ip api.cloudflareclient.com)" == 162.159.137.105 ]] || fail 'MOCK_NATIVE DNS failed'
MOCK_NATIVE=no
[[ "$(warp_resolve_bootstrap_ip api.cloudflareclient.com)" == 162.159.137.105 ]] || fail 'fresh cache was not used'
[[ ! -e "$MOCK_TMP/requests" ]] || fail 'cache still did network queries'
MOCK_NOW=$((MOCK_NOW+61))
[[ "$(warp_resolve_bootstrap_ip api.cloudflareclient.com)" == 162.159.137.106 ]] || fail 'expired MOCK_NATIVE cache did not fall back to second DoH provider'
[[ "$(wc -l < "$MOCK_TMP/requests")" == 2 ]] || fail 'DoH fallback order/count wrong'
MOCK_NATIVE=yes
[[ "$(warp_resolve_bootstrap_ip api.cloudflareclient.com true)" == 162.159.137.106 ]] || fail 'fresh DoH retry reused native DNS'
[[ "$(wc -l < "$MOCK_TMP/requests")" == 4 ]] || fail 'fresh DoH retry used cache'
MOCK_NATIVE=no
[[ "$(stat -c %a "$conf_dir/warp/dns-cache/api.cloudflareclient.com.json")" == 600 ]] || fail 'cache mode not private'
warp_forget_bootstrap_ip api.cloudflareclient.com
scenario=malformed
if warp_resolve_bootstrap_ip api.cloudflareclient.com >/dev/null; then fail 'wrong-question/private answer accepted'; fi
scenario=good; MOCK_TTL=0
warp_resolve_bootstrap_ip api.cloudflareclient.com >/dev/null
[[ ! -e "$conf_dir/warp/dns-cache/api.cloudflareclient.com.json" ]] || fail 'TTL zero answer persisted'
if warp_resolve_bootstrap_ip 'evil.example' >/dev/null; then fail 'arbitrary bootstrap hostname accepted'; fi
ln -s "$MOCK_TMP/outside" "$conf_dir/warp/dns-cache/api.cloudflareclient.com.json"
if warp_resolve_bootstrap_ip api.cloudflareclient.com >/dev/null; then fail 'symlink cache accepted'; fi
[[ ! -e "$MOCK_TMP/outside" ]] || fail 'symlink cache target written'
rm -f "$conf_dir/warp/dns-cache/api.cloudflareclient.com.json"
MOCK_UNDERLAY=6
[[ "$(warp_resolve_bootstrap_ip api.cloudflareclient.com)" == 2606:4700:110::1 ]] || fail 'IPv6 underlay DNS fallback failed'
MOCK_UNDERLAY=4
[[ "$(warp_resolve_bootstrap_ip api.cloudflareclient.com)" == 162.159.137.106 ]] || fail 'IPv6 cache survived loss of IPv6 underlay'
MOCK_UNDERLAY=6
[[ "$(warp_resolve_bootstrap_ip api.cloudflareclient.com)" == 2606:4700:110::1 ]] || fail 'IPv4 cache survived loss of IPv4 underlay'
endpoint='{"type":"wireguard","tag":"wireguard-out"}'
for family in 4 6; do
 for mode in local cloudflare google; do
  config=$(render_warp_probe_config "$endpoint" 22222 "$family" "$mode")
  jq -e --arg family "$family" --arg mode "$mode" '.dns.strategy == (if $family=="4" then "ipv4_only" else "ipv6_only" end) and .dns.final==$mode' <<< "$config" >/dev/null || fail 'DNS mode/family mismatch'
  jq -e '.dns.servers[1].server=="2606:4700:4700::1111" and .dns.servers[2].server=="2001:4860:4860::8888"' <<< "$config" >/dev/null || fail 'underlay and WARP exit families were conflated'
 done
done
echo 'WARP bootstrap DNS tests passed.'
