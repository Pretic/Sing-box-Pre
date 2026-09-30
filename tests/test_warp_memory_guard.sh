#!/usr/bin/env bash
set -euo pipefail
ensure_warp_adapter() { return 0; }
generate_warp_keypair() { "$singbox_bin" generate wg-keypair; }
script=$(cd "$(dirname "$0")/.." && pwd)/sing-box.sh
for n in warp_available_memory_kb require_warp_candidate_memory; do source <(sed -n "/^$n() {/,/^}/p" "$script"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir -p "$d/proc/self" "$d/cg/child"
printf 'MemAvailable: 100000 kB\n' > "$d/proc/meminfo"
printf '0::/child\n' > "$d/proc/self/cgroup"
printf '1 0 0:1 / %s rw - cgroup2 cgroup rw\n' "$d/cg" > "$d/proc/self/mountinfo"
printf 'max\n' > "$d/cg/memory.max"; echo 100 > "$d/cg/memory.current"
echo 134217728 > "$d/cg/child/memory.max"; echo 83886080 > "$d/cg/child/memory.current"
[[ $(warp_available_memory_kb "$d/proc") = 49152 ]]
# Tightest ancestor wins over a looser child.
echo 104857600 > "$d/cg/memory.max"; echo 83886080 > "$d/cg/memory.current"
[[ $(warp_available_memory_kb "$d/proc") = 20480 ]]
# A non-root mounted subtree maps membership correctly.
sed -i "s@ / $d/cg @ /child $d/cg @" "$d/proc/self/mountinfo"
[[ $(warp_available_memory_kb "$d/proc") = 20480 ]]
# Namespace-root membership also maps to the exposed mount.
printf '0::/\n' > "$d/proc/self/cgroup"
[[ $(warp_available_memory_kb "$d/proc") = 20480 ]]
# v1 memory controller.
printf '3:cpu,memory:/\n' > "$d/proc/self/cgroup"
printf '1 0 0:1 / %s rw - cgroup cgroup rw,memory\n' "$d/cg" > "$d/proc/self/mountinfo"
echo 134217728 > "$d/cg/memory.limit_in_bytes"; echo 83886080 > "$d/cg/memory.usage_in_bytes"
[[ $(warp_available_memory_kb "$d/proc") = 49152 ]]
echo 9223372036854771712 > "$d/cg/memory.limit_in_bytes"
[[ $(warp_available_memory_kb "$d/proc") = 100000 ]]
# Missing or malformed measurements never invent headroom.
echo bad > "$d/cg/memory.limit_in_bytes"
if warp_available_memory_kb "$d/proc" >/dev/null; then exit 1; fi
: > "$d/proc/meminfo"
if warp_available_memory_kb "$d/proc" >/dev/null; then exit 1; fi
red(){ :; }
warp_available_memory_kb(){ echo 65535; }
rc=0; require_warp_candidate_memory || rc=$?
[[ $rc = 10 && $WARP_CANDIDATE_MEMORY_BLOCKED = 1 ]]
warp_available_memory_kb(){ echo 65536; }
require_warp_candidate_memory
[[ $WARP_CANDIDATE_MEMORY_BLOCKED = 0 ]]
warp_available_memory_kb(){ return 1; }
rc=0; require_warp_candidate_memory || rc=$?
[[ $rc = 10 ]]
# Resource stops must not be retried as network errors by sustained controller.
source <(sed -n '/^rotate_warp_identity_until_new() {/,/^}/p' "$script")
rotate_warp_identity_once(){ return 10; }; warp_rotation_now(){ echo 100; }
warp_rotation_wait(){ echo 'unexpected retry' >&2; exit 1; }; yellow(){ :; }
rc=0; rotate_warp_identity_until_new 4 || rc=$?
[[ $rc = 10 ]]
echo 'WARP memory headroom/cgroup/terminal resource guard tests passed.'
# Both candidate workflows refuse before any registration when RAM is low.
for n in _rotate_warp_identity_once _auto_select_warp_candidate; do source <(sed -n "/^$n() {/,/^}/p" "$script"); done
conf_dir="$d/conf"; mkdir -p "$conf_dir/warp"
warp_activation_generation(){ echo fixture; }; warp_endpoint_is_valid(){ return 0; }
extract_warp_endpoint(){ echo '{}'; }; probe_active_warp(){ WARP_PROBE_IP=198.51.100.1; [[ $1 = 4 ]]; }
generate_unique_warp_identity(){ echo called >> "$d/registered"; echo '{}' > "$1/account.json"; echo '{}' > "$1/endpoint.json"; }
for fn in _rotate_warp_identity_once _auto_select_warp_candidate; do
 rc=0; "$fn" 4 || rc=$?
 [[ $rc = 10 && ! -e "$d/registered" ]]
done
# A late pressure change after registration cleans the one candidate, then stops.
warp_available_memory_kb(){ echo 100000; }
start_warp_candidate_proxy(){ WARP_CANDIDATE_MEMORY_BLOCKED=1; return 10; }
delete_warp_registration(){ echo deleted >> "$d/deleted"; }
remove_warp_candidate_dir(){ rm -rf -- "$1"; }
for fn in _rotate_warp_identity_once _auto_select_warp_candidate; do
 rc=0; "$fn" 4 || rc=$?
 [[ $rc = 10 ]]
done
[[ $(wc -l < "$d/registered") = 2 && $(wc -l < "$d/deleted") = 2 ]]
[[ -z $(find "$conf_dir/warp" -mindepth 1 -print -quit) ]]
echo 'Memory pressure stops registration before allocation and cleans late candidates.'
