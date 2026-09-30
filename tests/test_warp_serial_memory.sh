#!/usr/bin/env bash
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/sing-box.sh
for n in warp_use_serial_probe require_warp_candidate_memory begin_warp_serial_probe end_warp_serial_probe start_warp_candidate_proxy launch_warp_candidate_core stop_warp_candidate_proxy render_warp_probe_config run_warp_candidate_operation; do source <(sed -n "/^$n() {/,/^}/p" "$script"); done
d=$(mktemp -d); conf_dir="$d/conf"; work_dir="$d"; server_name=fake-core
mkdir -p "$conf_dir/warp"; echo '{}' > "$d/production.json"
cleanup(){ for f in "$d"/*.pid; do [[ ! -f $f ]] || kill "$(cat "$f")" 2>/dev/null || :; done; rm -rf "$d"; }
trap cleanup EXIT
cat > "$d/fake-core" <<'CORE'
#!/usr/bin/env bash
if [[ $1 == check ]]; then
 if [[ -f $D/production.pid ]] && kill -0 "$(cat "$D/production.pid")" 2>/dev/null; then echo overlapping >> "$D/error"; exit 1; fi
 echo check >> "$D/events"; exit 0
fi
exec python3 -c 'import time; time.sleep(300)' "$@"
CORE
chmod 700 "$d/fake-core"; export D="$d"
red(){ :; }; yellow(){ :; }; green(){ :; }
warp_available_memory_kb(){ if [[ ${2:-} = capacity ]]; then echo 131072; else echo 70000; fi; }
warp_endpoint_is_valid(){ return 0; }; warp_underlay_family(){ echo 4; }
warp_activation_generation(){ echo generation1; }; baseline_generation=generation1
acquire_proxy_transaction_lock_checked(){ [[ ! -e $d/lock ]]; touch "$d/lock"; echo lock >> "$d/events"; }
release_proxy_transaction_lock(){ rm -f "$d/lock"; echo unlock >> "$d/events"; }
singbox_service_is_active(){ [[ -f $d/production.pid ]] && kill -0 "$(cat "$d/production.pid")" 2>/dev/null; }
singbox_service_is_stably_active(){ singbox_service_is_active; }
stop_singbox_checked(){
 [[ -e $d/lock ]]; echo stop >> "$d/events"
 local pid; pid=$(cat "$d/production.pid"); kill "$pid"; wait "$pid" 2>/dev/null || :; rm "$d/production.pid"
}
restart_singbox_checked(){
 [[ ! -e $d/candidate.pid ]] || ! kill -0 "$(cat "$d/candidate.pid")" 2>/dev/null
 [[ ${RESTORE_FAIL:-0} != 1 ]] || return 1
 "$d/fake-core" run -c "$d/production.json" & echo $! > "$d/production.pid"
 sleep 0.03; echo restore >> "$d/events"
}
command_exists(){ [[ $1 = ss ]]; }
ss(){ if [[ -n ${WARP_PROBE_PID:-} ]]; then echo "$WARP_PROBE_PID" > "$d/candidate.pid"; printf 'LISTEN 0 1 127.0.0.1:%s\n' "$WARP_PROBE_PORT"; fi; }
cancel_warp_pending_candidate(){ stop_warp_candidate_proxy; }
restart_singbox_checked
start_warp_candidate_proxy '{"peers":[{"address":"127.0.0.1"}]}' 4
[[ -e $d/lock ]]; ! singbox_service_is_active; kill -0 "$WARP_PROBE_PID"
stop_warp_candidate_proxy
singbox_service_is_active; [[ ! -e $d/lock && ! -e $d/error ]]
# Stopped input must remain stopped.
touch "$d/lock"; stop_singbox_checked; rm "$d/lock"
if start_warp_candidate_proxy '{"peers":[{"address":"127.0.0.1"}]}' 4; then exit 1; fi
! singbox_service_is_active; [[ ! -e $d/lock ]]
restart_singbox_checked
# Generation changed before stop: no service interruption.
baseline_generation=old
rc=0; start_warp_candidate_proxy '{"peers":[{"address":"127.0.0.1"}]}' 4 || rc=$?
[[ $rc = 9 ]]; singbox_service_is_active; [[ ! -e $d/lock ]]
baseline_generation=generation1
# Real outer TERM during a ready candidate must restore and unlock.
callback(){ start_warp_candidate_proxy '{"peers":[{"address":"127.0.0.1"}]}' 4; touch "$d/ready"; while :; do sleep .05; done; }
run_warp_candidate_operation callback & operation=$!
for i in {1..100}; do [[ ! -f $d/ready ]] || break; sleep .02; done
[[ -f $d/ready ]]; kill -TERM "$operation"
rc=0; wait "$operation" || rc=$?
[[ $rc = 143 ]]; singbox_service_is_active; [[ ! -e $d/lock && ! -e $d/error ]]
! kill -0 "$(cat "$d/candidate.pid")" 2>/dev/null
# Failed restoration is terminal and doesn't launch another candidate.
start_warp_candidate_proxy '{"peers":[{"address":"127.0.0.1"}]}' 4
RESTORE_FAIL=1; rc=0; stop_warp_candidate_proxy || rc=$?
[[ $rc = 2 && $WARP_SERIAL_RESTORE_FAILED = 1 && ! -e $d/lock ]]
echo 'Serial WARP one-core lifecycle, lock, cancellation, stopped-state and restore-failure tests passed.'
