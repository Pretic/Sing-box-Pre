#!/usr/bin/env bash
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/sing-box.sh
for n in singbox_check_config_dir activate_warp_candidate; do source <(sed -n "/^$n() {/,/^}/p" "$script"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d/conf"; work_dir="$d"; server_name=checker; mkdir "$conf_dir"
cat > "$d/checker" <<'CORE'
#!/bin/bash
[[ ! -e $D/running ]] || { echo overlap > "$D/failure"; exit 1; }
[[ ${REJECT_CHECK:-0} != 1 ]]
CORE
chmod 700 "$d/checker"; export D="$d"
warp_use_serial_probe(){ return 0; }; red(){ :; }; yellow(){ :; }
singbox_service_is_active(){ [[ -e $d/running ]]; }
singbox_service_is_stably_active(){ singbox_service_is_active; }
stop_singbox_checked(){ rm -f "$d/running"; echo stop >> "$d/events"; }
restart_singbox_checked(){ [[ ${RESTORE_FAIL:-0} != 1 ]] || return 1; touch "$d/running"; echo start >> "$d/events"; }
PROXY_TX_STAGE=staging
touch "$d/running"; singbox_check_config_dir "$conf_dir"
[[ -e $d/running && ! -e $d/failure ]]
export REJECT_CHECK=1
if singbox_check_config_dir "$conf_dir"; then exit 1; fi
[[ -e $d/running && ! -e $d/failure ]]
unset REJECT_CHECK
rm "$d/running"; singbox_check_config_dir "$conf_dir"; [[ ! -e $d/running ]]
touch "$d/running"; RESTORE_FAIL=1
rc=0; singbox_check_config_dir "$conf_dir" || rc=$?
[[ $rc = 2 && $PROXY_TX_MEMORY_FATAL = 1 ]]
unset RESTORE_FAIL
# Activation has its own lock and rollback; early failure restores untouched old service.
acquire_proxy_transaction_lock_checked(){ touch "$d/lock"; }
release_proxy_transaction_lock(){ rm "$d/lock"; }
warp_activation_generation(){ echo generation; }
_activate_warp_candidate_locked(){ [[ ! -e $d/running && -e $d/lock ]]; return 1; }
touch "$d/running"; rc=0; activate_warp_candidate /unused '' '' 4 '' generation || rc=$?
[[ $rc = 1 && -e $d/running && ! -e $d/lock ]]
# Simulated TERM after stop is recovered without attempting registration.
_activate_warp_candidate_locked(){ kill -TERM "$BASHPID"; }
rc=0; activate_warp_candidate /unused '' '' 4 '' generation || rc=$?
[[ $rc = 143 && -e $d/running && ! -e $d/lock ]]
echo 'Low-memory staged checks and activation serialize, preserve stopped state, and restore on interruption.'
