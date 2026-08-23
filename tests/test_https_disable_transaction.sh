#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

function_source="$(sed -n '/^disable_cf_https_subscription() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] || fail 'disable_cf_https_subscription is not implemented'
source <(printf '%s\n' "$function_source")

green() { :; }
yellow() { printf '%s\n' "$*" >&2; }
red() { printf '%s\n' "$*" >&2; }
reading() { method=1; confirm=y; }
detect_argo_tunnel_mode() { printf 'local\n'; }
get_nginx_subscription_port() { printf '18080\n'; }
get_nginx_subscription_paths() { printf '/0123456789abcdefghjkmnpqrstvwxyz\n'; }
is_valid_http_subscription_path() { return 0; }
restart_argo() { return 0; }
restart_nginx() { return 0; }
nginx() { return 0; }

work_dir="${tmp_dir}/work"
mkdir -p "$work_dir" "${tmp_dir}/nginx"
subscription_state_file="${work_dir}/subscription.conf"
NGINX_SUBSCRIPTION_CONF="${tmp_dir}/nginx/sing-box.conf"
tunnel_file="${work_dir}/tunnel.yml"
printf '%s\n' 'state=enabled' > "$subscription_state_file"
printf '%s\n' 'tunnel-with-route' > "$tunnel_file"
printf '%s\n' 'nginx-with-https-path' > "$NGINX_SUBSCRIPTION_CONF"

load_subscription_state() {
    SUB_HTTPS_ENABLED=1
    SUB_TUNNEL_MODE=local
    SUB_HTTPS_DOMAIN=sub.example.com
    SUB_HTTPS_DOMAIN_MODE=reuse
    SUB_HTTPS_PATH=/sub/0123456789abcdefghjkmnpqrstvwxyz
    SUB_HTTP_PATH=/0123456789abcdefghjkmnpqrstvwxyz
}

operation_log="${tmp_dir}/operations.log"
save_status=1
save_subscription_state() {
    printf '%s\n' save-state >> "$operation_log"
    [ "$save_status" -eq 0 ] || return 1
    printf '%s\n' 'state=disabled' > "$subscription_state_file"
}
apply_local_tunnel_subscription_removal() {
    printf '%s\n' remove-route >> "$operation_log"
    printf '%s\n' 'tunnel-without-route' > "$1"
}
nginx_status=0
apply_nginx_subscription_config() {
    printf '%s\n' update-nginx >> "$operation_log"
    printf '%s\n' 'nginx-http-only' > "$NGINX_SUBSCRIPTION_CONF"
    return "$nginx_status"
}

# A state writer failure is detected during prepare, before Tunnel or Nginx
# is touched.
if disable_cf_https_subscription >/dev/null 2>&1; then
    fail 'disable succeeded after pending state preparation failed'
fi
[[ "$(command cat "$operation_log")" == save-state ]] || \
    fail "state preparation failure still changed runtime config: $(tr '\n' ',' < "$operation_log")"
[[ "$(command cat "$tunnel_file")" == tunnel-with-route ]] || fail 'route changed after state prepare failure'
[[ "$(command cat "$NGINX_SUBSCRIPTION_CONF")" == nginx-with-https-path ]] || fail 'nginx changed after state prepare failure'
[[ "$(command cat "$subscription_state_file")" == state=enabled ]] || fail 'active state changed after prepare failure'

# If Nginx preparation fails after local route removal, the exact Tunnel and
# Nginx files are restored and the enabled state remains authoritative.
: > "$operation_log"
save_status=0
nginx_status=1
if disable_cf_https_subscription >/dev/null 2>&1; then
    fail 'disable succeeded after Nginx update failed'
fi
[[ "$(command cat "$tunnel_file")" == tunnel-with-route ]] || fail 'Tunnel route was not rolled back'
[[ "$(command cat "$NGINX_SUBSCRIPTION_CONF")" == nginx-with-https-path ]] || fail 'Nginx config was not rolled back'
[[ "$(command cat "$subscription_state_file")" == state=enabled ]] || fail 'enabled state was overwritten before commit'

commit_status=1
CORRUPT_COMMIT=0
mv() {
    if [[ "${1:-}" == -f && "${2:-}" == *subscription-disable-pending* && \
          "${3:-}" == "$subscription_state_file" ]]; then
        [ "$commit_status" -eq 0 ] || return 1
        command mv "$@"
        if [ "$CORRUPT_COMMIT" -eq 1 ]; then
            printf '%s\n' corrupt-state > "$subscription_state_file"
        fi
        return 0
    fi
    command mv "$@"
}

restore_status=0
cp() {
    if [[ "${1:-}" == -p && "${2:-}" == *subscription-disable-nginx* && \
          "${3:-}" == "$NGINX_SUBSCRIPTION_CONF" ]]; then
        [ "$restore_status" -eq 0 ] || return 1
    fi
    command cp "$@"
}

CLEANUP_FAIL=0
rm() {
    if [[ "$CLEANUP_FAIL" -eq 1 && "${1:-}" == -f && \
          "${2:-}" == *subscription-disable-nginx* ]]; then
        return 1
    fi
    command rm "$@"
}

# A commit failure with successful runtime restoration is rc=1 and leaves no
# stale pending/backup files.
: > "$operation_log"
nginx_status=0
printf '%s\n' 'tunnel-with-route' > "$tunnel_file"
printf '%s\n' 'nginx-with-https-path' > "$NGINX_SUBSCRIPTION_CONF"
set +e
disable_cf_https_subscription >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "complete disable rollback returned ${status} instead of 1"
[[ "$(command cat "$tunnel_file")" == tunnel-with-route ]] || fail 'commit failure did not restore Tunnel route'
[[ "$(command cat "$NGINX_SUBSCRIPTION_CONF")" == nginx-with-https-path ]] || fail 'commit failure did not restore Nginx'
shopt -s nullglob
recoveries=("${work_dir}"/.subscription-disable-*)
[[ "${#recoveries[@]}" -eq 0 ]] || fail 'complete disable rollback leaked temporary recovery files'

# Verify the committed state byte-for-byte; a successful mv with corrupt
# contents must restore the old state and runtime as rc=1.
printf '%s\n' 'state=enabled' > "$subscription_state_file"
printf '%s\n' 'tunnel-with-route' > "$tunnel_file"
printf '%s\n' 'nginx-with-https-path' > "$NGINX_SUBSCRIPTION_CONF"
commit_status=0
CORRUPT_COMMIT=1
set +e
disable_cf_https_subscription >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "corrupt disable state commit returned ${status} instead of 1"
[[ "$(< "$subscription_state_file")" == state=enabled ]] || fail 'corrupt commit did not restore old state'
[[ "$(< "$tunnel_file")" == tunnel-with-route ]] || fail 'corrupt commit did not restore Tunnel route'
[[ "$(< "$NGINX_SUBSCRIPTION_CONF")" == nginx-with-https-path ]] || fail 'corrupt commit did not restore Nginx'
CORRUPT_COMMIT=0
commit_status=1

# A failed Nginx restore is rc=2 and must retain the exact pending state,
# Nginx and Tunnel backups under one secure recovery directory.
printf '%s\n' 'tunnel-with-route' > "$tunnel_file"
printf '%s\n' 'nginx-with-https-path' > "$NGINX_SUBSCRIPTION_CONF"
restore_status=1
set +e
recovery_output="$(disable_cf_https_subscription 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "incomplete disable rollback returned ${status} instead of 2"
recoveries=("${work_dir}"/.subscription-disable-recovery.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'incomplete disable rollback did not retain one recovery directory'
recovery_dir="${recoveries[0]}"
[[ "$(stat -c '%a' "$recovery_dir")" == 700 ]] || fail 'disable recovery directory is not mode 0700'
while IFS= read -r recovery_file; do
    [[ "$(stat -c '%a' "$recovery_file")" == 600 ]] || \
        fail "disable recovery artifact is not mode 0600: ${recovery_file}"
done < <(find "$recovery_dir" -maxdepth 1 -type f -print)
[[ -f "${recovery_dir}/pending-state.conf" && -f "${recovery_dir}/nginx.conf" && \
   -f "${recovery_dir}/old-state.conf" && -f "${recovery_dir}/expected-state.conf" && \
   -f "${recovery_dir}/tunnel.yml" && -f "${recovery_dir}/recovery.conf" ]] || \
    fail 'disable recovery directory is missing exact rollback artifacts'
[[ "$recovery_output" == *'自动回滚不完整'*"$recovery_dir"* ]] || \
    fail 'incomplete disable rollback did not report the retained recovery directory'
command rm -rf -- "$recovery_dir"

# State commit is already healthy before backup cleanup. Residue is rc=3 and
# must be reported without claiming that the disable transaction failed.
printf '%s\n' 'tunnel-with-route' > "$tunnel_file"
printf '%s\n' 'nginx-with-https-path' > "$NGINX_SUBSCRIPTION_CONF"
restore_status=0
commit_status=0
CLEANUP_FAIL=1
set +e
cleanup_output="$(disable_cf_https_subscription 2>&1)"
status=$?
set -e
[[ "$status" -eq 3 ]] || fail "disable post-commit cleanup returned ${status} instead of rc=3"
leftovers=("$(dirname "$NGINX_SUBSCRIPTION_CONF")"/.subscription-disable-nginx.* \
    "${work_dir}"/.subscription-disable-tunnel.* \
    "${work_dir}"/.subscription-disable-old-state.* \
    "${work_dir}"/.subscription-disable-expected-state.*)
[[ "${#leftovers[@]}" -eq 4 ]] || \
    fail "disable cleanup warning retained unexpected backup files: ${leftovers[*]-none}"
[[ "$cleanup_output" == *'已成功'*'未能清理'* ]] || \
    fail 'disable cleanup warning did not distinguish committed success from residue'
for leftover in "${leftovers[@]}"; do
    [[ "$cleanup_output" == *"$leftover"* ]] || fail "disable cleanup warning omitted residue path: ${leftover}"
    command rm -f -- "$leftover"
done

printf 'HTTPS disable transaction tests passed.\n'
