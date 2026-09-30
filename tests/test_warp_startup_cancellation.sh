#!/usr/bin/env bash
set -euo pipefail
ensure_warp_adapter() { return 0; }
generate_warp_keypair() { "$singbox_bin" generate wg-keypair; }
begin_warp_serial_probe() { return 0; }
end_warp_serial_probe() { return 0; }
require_warp_candidate_memory() { return 0; }
SB=${SB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh}
for n in launch_warp_candidate_core render_warp_probe_config stop_warp_candidate_proxy warp_activation_generation cancel_warp_pending_candidate run_warp_candidate_operation rotate_warp_identity_once _rotate_warp_identity_once; do source <(sed -n "/^${n}() {/,/^}/p" "$SB"); done
d=$(mktemp -d)
cleanup(){ if [[ -f "$d/core.pid" ]]; then kill "$(cat "$d/core.pid")" 2>/dev/null || :; fi; rm -rf "$d"; }
trap cleanup EXIT
conf_dir="$d/conf"; mkdir -p "$conf_dir/warp"
red(){ :; }; yellow(){ :; }; green(){ :; }
warp_endpoint_is_valid(){ return 0; }; extract_warp_endpoint(){ echo '{}'; }
probe_active_warp(){ [[ "$1" == 4 ]] || return 1; WARP_PROBE_IP=198.51.100.1; }
generate_unique_warp_identity(){ printf '{"id":"synthetic"}' > "$1/account.json"; printf '{}' > "$1/endpoint.json"; }
source <(sed -n '/^start_warp_candidate_proxy() {/,/^}/p' "$SB" | sed '1s/start_warp_candidate_proxy()/start_warp_candidate_proxy_real()/')
work_dir="$d"; server_name=fixture-core
cat > "$d/fixture-core" <<'SH'
#!/bin/bash
[[ "$1" != check ]] || exit 0
exec python3 -c 'import time; time.sleep(300)' "$@"
SH
chmod 700 "$d/fixture-core"
warp_underlay_family(){ echo 4; }
command_exists(){ [[ "$1" == ss ]]; }
ss(){
 if [[ -n "${WARP_PROBE_PID:-}" ]]; then
  echo "$WARP_PROBE_PID" > "$d/core.pid"
  kill -TERM "$READINESS_OWNER"
 fi
}
start_warp_candidate_proxy(){ READINESS_OWNER=$BASHPID; start_warp_candidate_proxy_real "$@"; }

delete_warp_registration(){ echo cleaned > "$d/cloud-cleaned"; }
remove_warp_candidate_dir(){ rm -rf -- "$1"; }
probe_warp_trace(){ echo 'unexpected ready probe' >&2; return 1; }
rc=0
(trap - EXIT; rotate_warp_identity_once 4) || rc=$?
live=0; [[ ! -s "$d/core.pid" ]] || { kill -0 "$(cat "$d/core.pid")" 2>/dev/null && live=1 || :; }
remaining=$(find "$conf_dir/warp" -maxdepth 1 -name '.candidate.*' | wc -l)
printf 'cancel status=%s; surviving mock core=%s; candidate dirs=%s; cloud-cleanup=%s\n' "$rc" "$live" "$remaining" "$(test -f "$d/cloud-cleaned" && echo yes || echo no)"
[[ "$rc" != 0 && "$live" == 0 && "$remaining" == 0 && -f "$d/cloud-cleaned" ]] || { echo 'FAIL candidate cancellation leaked owned resources'; exit 1; }
