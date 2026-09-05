#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^warp_registration_post() {/,/^}/p' "$script")
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
conf_dir="$tmp/conf"; mkdir -p "$conf_dir/warp"
printf '{"key":"same-request"}\n' > "$tmp/request.json"
fail() { echo "FAIL: $*" >&2; exit 1; }
declare -F warp_registration_post >/dev/null || fail 'registration transport helper missing'
warp_resolve_bootstrap_ip() {
    [[ "$scenario" != dns_fail ]] || return 1
    if [[ -f "$calls" ]]; then [[ "${2:-false}" == true ]] || fail 'retry reused native DNS'; fi
    echo 162.159.137.105
}
warp_forget_bootstrap_ip() { :; }; sleep() { :; }
calls="$tmp/calls"
curl() {
    [[ "$1" == -q ]] || fail 'curlrc was not disabled'
    local output='' arg previous='' attempt=0
    for arg in "$@"; do
        [[ "$arg" != --location && "$arg" != -L ]] || fail 'POST follows redirects'
        [[ "$previous" != -o ]] || output="$arg"
        previous="$arg"
    done
    [[ " $* " == *' --retry 0 '* && " $* " == *' --resolve '* ]] || fail 'missing retry / DNS controls'
    [[ ! -f "$calls" ]] || read -r attempt < "$calls"
    attempt=$((attempt+1)); echo "$attempt" > "$calls"
    cmp -s "$tmp/request.json" "$tmp/original.json" || fail 'retry changed request identity'
    : > "$output"
    case "$scenario" in
      safe_then_ok) if [[ "$attempt" == 1 ]]; then printf '000\t0\t0'; return 7; fi ;;
      exhausted) printf '000\t0\t0'; return 7 ;;
      timeout) printf '000\t0\t0'; return 28 ;;
      sent) printf '000\t120\t0'; return 7 ;;
      malformed) printf '000'; return 6 ;;
      server_error) echo '{}' > "$output"; printf '503\t120\t22'; return 0 ;;
      rejected) echo '{}' > "$output"; printf '429\t120\t22'; return 0 ;;
      redirect) echo '{}' > "$output"; printf '302\t120\t22'; return 0 ;;
    esac
    echo '{"id":"fixture-device","token":"fixture-token"}' > "$output"
    printf '200\t120\t22'
}
cp "$tmp/request.json" "$tmp/original.json"
for row in 'safe_then_ok 0 2' 'exhausted 4 2' 'timeout 2 1' 'sent 2 1' 'malformed 2 1' 'server_error 2 1' 'rejected 1 1' 'redirect 2 1' 'dns_fail 4 0'; do
    read -r scenario expected expected_calls <<< "$row"
    rm -f "$calls"; rc=0
    warp_registration_post "$tmp/request.json" "$tmp/response.json" > "$tmp/status" || rc=$?
    actual=0; [[ ! -f "$calls" ]] || read -r actual < "$calls"
    [[ "$rc" == "$expected" && "$actual" == "$expected_calls" ]] || fail "$scenario rc=$rc calls=$actual"
done
source <(sed -n '/^delete_warp_registration() {/,/^}/p' "$script")
warp_resolve_bootstrap_ip() { echo 162.159.137.105; }
printf '{"id":"fixture-device","token":"fixture-token"}' > "$tmp/account.json"
curl() {
    [[ "$1" == -q && " $* " == *' --resolve api.cloudflareclient.com:443:162.159.137.105 '* ]] || fail 'DELETE did not use bounded bootstrap'
    printf '%s' "$delete_http"
}
for delete_http in 200 204; do delete_warp_registration "$tmp/account.json" || fail 'successful cleanup rejected'; done
for delete_http in 302 503; do
    if delete_warp_registration "$tmp/account.json"; then fail 'uncertain cleanup discarded credentials'; fi
done
echo 'WARP registration transport tests passed.'
