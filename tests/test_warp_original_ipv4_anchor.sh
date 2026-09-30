#!/usr/bin/env bash
set -euo pipefail
ensure_warp_adapter() { return 0; }
generate_warp_keypair() { "$singbox_bin" generate wg-keypair; }
require_warp_candidate_memory() { return 0; }
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in _rotate_warp_identity_once run_warp_candidate_operation; do source <(sed -n "/^${f}() {/,/^}/p" "$script"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d/conf"; mkdir -p "$conf_dir/warp"
red(){ :; }; yellow(){ :; }; green(){ :; }
warp_endpoint_is_valid(){ :; }; extract_warp_endpoint(){ echo '{}'; }
warp_activation_generation(){ echo "$GEN"; }
probe_active_warp(){ if [[ "$1" == 4 ]]; then WARP_PROBE_IP=$ACTUAL; else WARP_PROBE_IP=2001:db8::1; fi; }
generate_unique_warp_identity(){ echo attempted >> "$d/registrations"; return 5; }
remove_warp_candidate_dir(){ rm -rf -- "$1"; }
switch_current_warp_to_ipv4(){ echo "$1" > "$d/prior-for-switch"; }
WARP_ROTATION_TRACK_ORIGINAL=1
WARP_ROTATION_ORIGINAL_IP=''; WARP_ROTATION_ORIGINAL_GENERATION=''
GEN=initial; ACTUAL=198.51.100.1
rc=0; run_warp_candidate_operation _rotate_warp_identity_once 4 || rc=$?
[[ "$rc" == 5 && "$WARP_ROTATION_ORIGINAL_IP" == 198.51.100.1 && "$WARP_ROTATION_ORIGINAL_GENERATION" == initial ]]
ACTUAL=198.51.100.2
run_warp_candidate_operation _rotate_warp_identity_once 4
[[ "$(cat "$d/prior-for-switch")" == 198.51.100.1 && "$(wc -l < "$d/registrations")" == 1 ]]
GEN=newer; rc=0; run_warp_candidate_operation _rotate_warp_identity_once 4 || rc=$?
[[ "$rc" == 9 && "$(wc -l < "$d/registrations")" == 1 ]]
echo 'Original IPv4/config anchor persists across worker batches; provider change is rechecked and newer config preserved.'
