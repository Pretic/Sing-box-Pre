#!/usr/bin/env bash
set -euo pipefail
ensure_warp_adapter() { return 0; }
generate_warp_keypair() { "$singbox_bin" generate wg-keypair; }
require_warp_candidate_memory() { return 0; }
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^generate_unique_warp_identity() {/,/^}/p' "$script")
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
work_dir="$d"; conf_dir="$d/conf"; server_name=fixture-core
mkdir -p "$conf_dir"
cat > "$d/fixture-core" <<'SH'
#!/bin/sh
printf 'PrivateKey: fixture-private-key\nPublicKey: fixture-public-key\n'
SH
chmod 755 "$d/fixture-core"
command_exists() { command -v "$1" >/dev/null 2>&1; }
red() { printf '%s\n' "$*"; }; yellow() { :; }; green() { :; }
warp_registration_post() {
    local register_dir; register_dir=$(dirname "$1")
    [[ "$(cat "$register_dir/private.key")" == fixture-private-key && "$(stat -c %a "$register_dir/private.key")" == 600 ]]
    printf '{"id":"partial-fixture"}' > "$2"
    return 2
}
rc=0; generate_unique_warp_identity > "$d/output" || rc=$?
[[ "$rc" == 2 ]]
recovery=$(find "$conf_dir/warp" -maxdepth 1 -name '.register.*' -type d -print -quit)
[[ -n "$recovery" && -s "$recovery/private.key" && -s "$recovery/response.json" ]]
! grep -q fixture-private-key "$d/output"
echo 'Ambiguous registration retains private key before POST without printing it.'

# JSON empty strings are truthy in jq; they are not usable cloud credentials.
warp_registration_post() { printf '{"id":"","token":""}' > "$2"; return 0; }
delete_warp_registration() { echo unexpected > "$d/deleted"; return 0; }
rc=0; generate_unique_warp_identity > "$d/empty-output" || rc=$?
[[ "$rc" == 2 && ! -e "$d/deleted" ]]
[[ "$(find "$conf_dir/warp" -name private.key | wc -l)" == 2 ]]
source <(sed -n '/^delete_warp_registration() {/,/^}/p' "$script")
for body in '{"id":"","token":""}' '{"id":1,"token":true}' 'invalid'; do
 printf '%s' "$body" > "$d/bad-account"
 if delete_warp_registration "$d/bad-account"; then echo 'malformed credentials claimed deleted'; exit 1; fi
done
echo 'Malformed successful responses preserve recovery instead of claiming cloud cleanup.'
