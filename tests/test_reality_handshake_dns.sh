#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
load_function() {
    local source_text
    source_text="$(sed -n "/^${1}() {/,/^}/p" "$script")"
    [[ -n "$source_text" ]] || fail "$1 is not implemented"
    source <(printf '%s\n' "$source_text")
}

load_function render_vless_reality_inbound
uuid='11111111-1111-4111-8111-111111111111'
private_key='test-private-key'
vless_port=12000 argo_port=18001 hy2_port=23005 tuic_port=23003
work_dir="$tmp_dir"
render_vless_reality_inbound vless-reality 0.0.0.0 ipv4_only > "$tmp_dir/inbound.json"
jq -e '.tls.reality.handshake.domain_resolver == {server:"local",strategy:"ipv4_only"}' \
    "$tmp_dir/inbound.json" >/dev/null || fail 'IPv4 Reality handshake can still select IPv6'

for function_name in reality_handshake_dns_strategy render_argo_inbound \
    render_hysteria2_inbound render_tuic_inbound render_inbounds_config \
    mutate_reality_sni_files apply_jq_config; do
    load_function "$function_name"
done

# Listening on IPv6 or having an address does not establish a public IPv6 route.
ip() {
    case "$*" in
        '-4 route get 1.1.1.1') [[ "$ROUTE4" == 1 ]] ;;
        '-6 route get 2606:4700:4700::1111') [[ "$ROUTE6" == 1 ]] ;;
        *) fail "unexpected route probe: $*" ;;
    esac
}
for scenario in '1 0 ipv4_only' '0 1 ipv6_only' '1 1 prefer_ipv4' '0 0 prefer_ipv4'; do
    read -r ROUTE4 ROUTE6 expected <<< "$scenario"
    [[ "$(reality_handshake_dns_strategy)" == "$expected" ]] || fail "wrong route strategy: $scenario"
    # Both listeners must use the same available outbound route family.
    render_inbounds_config 1 1 1 > "$tmp_dir/rendered.json"
    jq -e --arg strategy "$expected" '
      [.inbounds[] | select(.tls.reality != null)] as $reality |
      ($reality | length == 2) and
      all($reality[]; .tls.reality.handshake.domain_resolver == {server:"local",strategy:$strategy}) and
      all($reality[]; .users[0].uuid == "11111111-1111-4111-8111-111111111111" and
          .listen_port == 12000 and .tls.reality.private_key == "test-private-key" and .tls.reality.short_id == [""]) and
      all(.inbounds[] | select(.tls.reality == null); .tls.reality.handshake.domain_resolver == null)
    ' "$tmp_dir/rendered.json" >/dev/null || fail "listener family affected handshake/identity: $scenario"
done

ROUTE4=1 ROUTE6=0
conf_dir="$tmp_dir/conf"
mkdir -p "$conf_dir"
printf '%s\n' '{"dns":{"servers":[{"type":"local","tag":"local"}]}}' > "$conf_dir/dns.json"
is_valid_subscription_domain() { [[ "$1" == example.com ]]; }
validate_singbox_config() { jq empty "$conf_dir/inbounds.json" >/dev/null; }
red() { printf '%s\n' "$*" >&2; }
for custom in '{}' '{"domain_resolver":"custom"}' \
    '{"domain_resolver":{"server":"custom","strategy":"prefer_ipv6"}}' \
    '{"domain_strategy":"ipv6_only"}' '{"detour":"socks-out"}'; do
    jq --argjson custom "$custom" '.tls.reality.handshake += $custom | {inbounds:[.]}' \
        "$tmp_dir/inbound.json" | jq 'if $ARGS.positional[0] == "{}" then
          del(.inbounds[0].tls.reality.handshake.domain_resolver) else . end' \
          --args "$custom" > "$conf_dir/inbounds.json"
    # Legacy detour/domain_strategy fixtures must not contain the new resolver.
    if [[ "$custom" == *domain_strategy* || "$custom" == *detour* ]]; then
        jq 'del(.inbounds[0].tls.reality.handshake.domain_resolver)' "$conf_dir/inbounds.json" > "$tmp_dir/legacy.json"
        mv "$tmp_dir/legacy.json" "$conf_dir/inbounds.json"
    fi
    cp "$conf_dir/inbounds.json" "$tmp_dir/before.json"
    printf '%s\n' 'vless://test@example.net:12000?security=reality&sni=old.example&flow=xtls-rprx-vision' > "$tmp_dir/url.txt"
    mutate_reality_sni_files "$tmp_dir/url.txt" example.com || fail 'SNI update failed'
    jq -e '.inbounds[0].tls.server_name == "example.com" and .inbounds[0].tls.reality.handshake.server == "example.com"' \
        "$conf_dir/inbounds.json" >/dev/null || fail 'SNI was not updated'
    if [[ "$custom" == '{}' ]]; then
        jq -e '.inbounds[0].tls.reality.handshake.domain_resolver == {server:"local",strategy:"ipv4_only"}' \
            "$conf_dir/inbounds.json" >/dev/null || fail 'legacy default handshake was not repaired'
    else
        jq -S '.inbounds[0].tls.reality.handshake | del(.server)' "$tmp_dir/before.json" > "$tmp_dir/before-handshake"
        jq -S '.inbounds[0].tls.reality.handshake | del(.server)' "$conf_dir/inbounds.json" > "$tmp_dir/after-handshake"
        cmp -s "$tmp_dir/before-handshake" "$tmp_dir/after-handshake" || fail "custom DNS/dial settings changed: $custom"
    fi
    for file in before.json conf/inbounds.json; do
        jq -S '.inbounds[0] | del(.tls.server_name,.tls.reality.handshake)' "$tmp_dir/$file" > "$tmp_dir/$(basename "$file").identity"
    done
    cmp -s "$tmp_dir/before.json.identity" "$tmp_dir/inbounds.json.identity" || fail 'SNI edit changed node identity'
done
printf '%s\n' '{"dns":{"servers":[{"type":"local","tag":"custom"}]}}' > "$conf_dir/dns.json"
jq '{inbounds:[.]} | del(.inbounds[0].tls.reality.handshake.domain_resolver)' \
    "$tmp_dir/inbound.json" > "$conf_dir/inbounds.json"
mutate_reality_sni_files "$tmp_dir/url.txt" example.com || fail 'custom default DNS blocked SNI editing'
jq -e '.inbounds[0].tls.reality.handshake.domain_resolver == null' "$conf_dir/inbounds.json" >/dev/null || \
    fail 'SNI edit introduced a reference to a missing local DNS server'
printf 'Reality handshake DNS tests passed.\n'
