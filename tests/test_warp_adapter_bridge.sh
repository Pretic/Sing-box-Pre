#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in run_warp_adapter warp_registration_post delete_warp_registration; do source <(sed -n "/^${f}() {/,/^}/p" "$script"); done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
red() { :; }
printf '{"key":"public-only"}' > "$d/request"
SB_WARP_ADAPTER="$d/adapter"
export CASE METADATA_LOG="$d/input-copy"
cat > "$SB_WARP_ADAPTER" <<'SH'
#!/bin/bash
operation=$1; shift
while (($#)); do case "$1" in --input) input=$2 ;; --response) response=$2 ;; --metadata) metadata=$2 ;; esac; shift 2; done
[[ $(stat -c %a "$(dirname "$response")") == 700 ]] || exit 99
[[ "$operation" != delete ]] || cp "$input" "$METADATA_LOG"
case "$CASE" in
 ok) printf '{"id":"device","token":"token"}' > "$response"; printf '{"http_status":200,"request_state":"response_received"}' > "$metadata" ;;
 limit) printf '{}' > "$response"; printf '{"http_status":429,"retry_after":"700","request_state":"response_received"}' > "$metadata"; exit 1 ;;
 reject) printf '{}' > "$response"; printf '{"http_status":403,"request_state":"response_received"}' > "$metadata"; exit 1 ;;
 ambiguous) printf '{"id":"device"}' > "$response"; printf '{"http_status":200,"request_state":"unknown"}' > "$metadata"; exit 1 ;;
 invalid) : > "$response"; printf '{"http_status":0,"request_state":"not_sent","error":"invalid_public_key"}' > "$metadata"; exit 1 ;;
 notsent) : > "$response"; printf '{"http_status":0,"request_state":"not_sent"}' > "$metadata"; exit 1 ;;
 delete) : > "$response"; printf '{"http_status":204,"request_state":"response_received"}' > "$metadata" ;;
esac
SH
chmod 755 "$SB_WARP_ADAPTER"
for row in 'ok 0' 'limit 7' 'reject 5' 'ambiguous 2' 'notsent 4' 'invalid 5'; do
 read -r CASE expected <<< "$row"; rc=0
 warp_registration_post "$d/request" "$d/response" || rc=$?
 [[ "$rc" == "$expected" ]] || { echo "$CASE=$rc expected$expected"; exit 1; }
 [[ "$CASE" != limit || "$WARP_REGISTRATION_RETRY_AFTER" == 700 ]]
done
printf '{"id":"fixture","token":"private-fixture-token"}' > "$d/account"
CASE=delete; delete_warp_registration "$d/account"
jq -e '.device_id=="fixture" and .token=="private-fixture-token"' "$d/input-copy" >/dev/null
SB_WARP_ADAPTER="$d/missing"; rc=0
warp_registration_post "$d/request" "$d/response" || rc=$?
[[ "$rc" == 8 ]]
echo 'Adapter bridge preserves response certainty, rate limits and private file-only credentials.'
