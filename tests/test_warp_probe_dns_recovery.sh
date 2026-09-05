#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for name in warp_probe_dns_fallback stop_warp_candidate_proxy; do
    source <(sed -n "/^${name}() {/,/^}/p" "$script")
done
fixture_root=$(mktemp -d)
conf_dir="$fixture_root/conf"; mkdir -p "$conf_dir/warp"
work_dir="$fixture_root"; server_name=missing
trap 'stop_warp_candidate_proxy; rm -rf -- "$fixture_root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
WARP_PROBE_BINARY="$fixture_root/fake-sing-box"
cat > "$WARP_PROBE_BINARY" <<'SH'
#!/bin/bash
if [ "$1" = check ]; then [ "${REJECT_CHECK:-0}" != 1 ]; exit $?; fi
exec python3 -c 'import time; time.sleep(300)' "$@"
SH
chmod 700 "$WARP_PROBE_BINARY"
WARP_PROBE_DIR=$(mktemp -d "$conf_dir/warp/.probe.XXXXXX")
printf '{"dns":{"final":"local"},"endpoints":[{"private_key":"fixture"}],"inbounds":[{"listen_port":22222}]}\n' > "$WARP_PROBE_DIR/config.json"
"$WARP_PROBE_BINARY" run -c "$WARP_PROBE_DIR/config.json" & WARP_PROBE_PID=$!
sleep 0.1
first_pid=$WARP_PROBE_PID
export REJECT_CHECK=1
if warp_probe_dns_fallback; then fail 'invalid config accepted'; fi
kill -0 "$first_pid" || fail 'check failure stopped the working proxy'
export REJECT_CHECK=0
for mode in cloudflare google; do
    old_pid=$WARP_PROBE_PID
    warp_probe_dns_fallback || fail 'DNS profile failed to switch'
    kill -0 "$WARP_PROBE_PID" || fail 'new proxy not running'
    if kill -0 "$old_pid" 2>/dev/null; then fail 'previous proxy still alive'; fi
    jq -e --arg mode "$mode" '.dns.final==$mode and .endpoints[0].private_key=="fixture" and .inbounds[0].listen_port==22222' "$WARP_PROBE_DIR/config.json" >/dev/null || fail 'switch changed identity or port'
done
if warp_probe_dns_fallback; then fail 'unbounded DNS profile rotation'; fi
last_pid=$WARP_PROBE_PID; last_dir=$WARP_PROBE_DIR
stop_warp_candidate_proxy
if kill -0 "$last_pid" 2>/dev/null || [[ -e "$last_dir" ]]; then fail 'probe cleanup incomplete'; fi
echo 'WARP probe DNS recovery tests passed.'
