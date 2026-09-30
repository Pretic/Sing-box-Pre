#!/usr/bin/env bash
set -euo pipefail
ensure_warp_adapter() { return 0; }
generate_warp_keypair() { "$singbox_bin" generate wg-keypair; }
require_warp_candidate_memory() { return 0; }
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in _rotate_warp_identity_once rotate_warp_identity_until_new warp_rotation_now _auto_select_warp_candidate; do
    source <(sed -n "/^${f}() {/,/^}/p" "$script")
done
rotate_warp_identity_once() { _rotate_warp_identity_once "$@"; }
auto_select_warp_candidate() { _auto_select_warp_candidate "$@"; }
warp_activation_generation() { printf baseline; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d/conf"; mkdir -p "$conf_dir/warp"
printf 'keep-existing-identity' > "$conf_dir/warp/account.json"
red() { :; }; yellow() { :; }; green() { :; }; sleep() { :; }
warp_endpoint_is_valid() { return 0; }
extract_warp_endpoint() { printf '{}'; }
probe_active_warp() { if [[ "$1" == 4 ]]; then WARP_PROBE_IP=198.51.100.1; else WARP_PROBE_IP=2001:db8::1; fi; }
generate_unique_warp_identity() { calls=$((calls+1)); return 5; }
remove_warp_candidate_dir() { rm -rf -- "$1"; }
for action in rotate_warp_identity_once rotate_warp_identity_until_new auto_select_warp_candidate; do
    calls=0; rc=0
    "$action" || rc=$?
    [[ "$rc" == 5 && "$calls" == 1 ]] || { echo "$action retried refused registration: rc=$rc calls=$calls"; exit 1; }
    [[ "$(cat "$conf_dir/warp/account.json")" == keep-existing-identity ]]
    [[ -z "$(find "$conf_dir/warp" -maxdepth 1 -name '.candidate.*' -print -quit)" ]]
done
echo 'Registration refusal stops both candidate selection and repeated batches without replacing identity.'
