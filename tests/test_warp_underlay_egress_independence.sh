#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in extract_warp_endpoint warp_endpoint_is_valid warp_endpoint_is_legacy warp_endpoint_json render_warp_route_family; do
 source <(sed -n "/^${f}() {/,/^}/p" "$script")
done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d/conf"; mkdir -p "$conf_dir"
warp_underlay_family() { printf '%s' "$UNDERLAY"; }
cat > "$conf_dir/endpoints.json" <<'JSON'
{"endpoints":[{"type":"wireguard","tag":"wireguard-out","address":["172.16.0.2/32","2606:4700:110::1/128"],"private_key":"fixture","domain_resolver":{"server":"local","strategy":"prefer_ipv4"},"peers":[{"address":"engage.cloudflareclient.com","port":2408,"public_key":"fixture","allowed_ips":["0.0.0.0/0","::/0"],"reserved":[1,2,3]}]}]}
JSON
for UNDERLAY in 4 6; do
 endpoint=$(warp_endpoint_json)
 jq -e --arg strategy "ipv${UNDERLAY}_only" '.domain_resolver.strategy==$strategy and (.address|length)==2' <<< "$endpoint" >/dev/null
done
jq '.endpoints[0].domain_resolver={"server":"my-custom-dns","strategy":"prefer_ipv4"}' "$conf_dir/endpoints.json" > "$d/next"; mv "$d/next" "$conf_dir/endpoints.json"
warp_endpoint_json | jq -e '.domain_resolver=={"server":"my-custom-dns","strategy":"prefer_ipv4"}' >/dev/null
cat > "$d/route" <<'JSON'
{"route":{"final":"wireguard-out","rules":[{"domain":["bypass.example"],"action":"route","outbound":"direct"},{"inbound":["custom"],"action":"sniff"},{"rule_set":["custom"],"network":["tcp","udp"],"action":"resolve","strategy":"ipv4_only"},{"rule_set":["openai"],"action":"route","outbound":"wireguard-out"}]}}
JSON
render_warp_route_family "$d/route" "$d/out" 4
jq -e '.route.rules[0].outbound=="direct" and .route.rules[1].inbound==["custom"] and .route.rules[2].rule_set==["custom"] and .route.rules[3].strategy=="ipv4_only" and .route.rules[4].outbound=="wireguard-out" and .route.rules[-1].strategy=="ipv4_only" and .route.rules[-1].rule_set==null' "$d/out" >/dev/null
cp "$d/out" "$d/once"
render_warp_route_family "$d/once" "$d/out" 4
cmp "$d/once" "$d/out"
echo 'Peer underlay selection stays independent from WARP domain egress; custom rule order and resolvers survive.'
