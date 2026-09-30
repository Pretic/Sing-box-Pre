#!/usr/bin/env bash
set -euo pipefail
ensure_warp_adapter() { return 0; }
script=$(cd "$(dirname "$0")/.." && pwd)/sing-box.sh
for n in run_warp_adapter generate_warp_keypair; do source <(sed -n "/^$n() {/,/^}/p" "$script"); done
d=$(mktemp -d); chmod 700 "$d"; trap 'rm -rf "$d"' EXIT
red(){ :; }
SB_WARP_ADAPTER=${SB_KEYPAIR_TEST_BINARY:-$d/adapter}
if [[ -z ${SB_KEYPAIR_TEST_BINARY:-} ]]; then
cat > "$SB_WARP_ADAPTER" <<'ADAPTER'
#!/bin/bash
[[ $1 = keypair ]] || exit 1
shift
while (($#)); do case $1 in --input) input=$2;; --response) response=$2;; --metadata) metadata=$2;; *) exit 1;; esac; shift 2; done
[[ $(cat "$input") = '{}' ]] || exit 1
umask 077
printf '{"private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","public_key":"AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="}\n' > "$response"
printf '{"http_status":0,"request_state":"not_sent","error":""}\n' > "$metadata"
ADAPTER
chmod 700 "$SB_WARP_ADAPTER"
fi
singbox_bin=/must-not-run-core
keys=$(generate_warp_keypair "$d")
private=$(awk -F': ' '/PrivateKey/{print $2}' <<< "$keys")
public=$(awk -F': ' '/PublicKey/{print $2}' <<< "$keys")
[[ $(base64 -d <<< "$private" | wc -c) = 32 && $(base64 -d <<< "$public" | wc -c) = 32 ]]
[[ $(stat -c %a "$d/key-response.json") = 600 ]]
SB_WARP_ADAPTER="$d/missing"
rc=0; generate_warp_keypair "$d" >/dev/null || rc=$?
[[ $rc = 8 ]]
echo 'WARP local keypair bridge uses private files and never starts the core or registers.'
