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

function_source="$(sed -n '/^rotate_subscription_token() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] || fail 'rotate_subscription_token is not implemented'
source <(printf '%s\n' "$function_source")

work_dir="${tmp_dir}/work"
mkdir -p "$work_dir" "${tmp_dir}/nginx"
subscription_state_file="${work_dir}/subscription.conf"
NGINX_SUBSCRIPTION_CONF="${tmp_dir}/nginx/sing-box.conf"
purple=''
re=''
OLD_PATH=/oldtoken0123456789abcdefghjkmnpqr
NEW_TOKEN=newtoken0123456789abcdefghjkmnpqr
printf '%s\n' old-state > "$subscription_state_file"
printf 'listen 18080; path %s;\n' "$OLD_PATH" > "$NGINX_SUBSCRIPTION_CONF"

load_subscription_state() {
    SUB_TOKEN="${OLD_PATH#/}"
    SUB_HTTP_PATH="$OLD_PATH"
    SUB_HTTPS_ENABLED=0
    SUB_HTTPS_DOMAIN=''
    SUB_HTTPS_DOMAIN_MODE=''
    SUB_HTTPS_PATH=''
    SUB_TUNNEL_MODE=''
    SUB_HTTPS_VERIFIED_AT=''
}
get_nginx_subscription_port() { printf '18080\n'; }
get_nginx_subscription_paths() { printf '%s\n' "$OLD_PATH"; }
is_valid_http_subscription_path() { return 0; }
generate_subscription_token() { printf '%s\n' "$NEW_TOKEN"; }
reading() { confirm=y; }
get_subscription_host() { printf 'example.test\n'; }
build_http_subscription_url() { printf 'http://example.test:18080%s\n' "$3"; }
green() { :; }
yellow() { printf '%s\n' "$*" >&2; }
red() { printf '%s\n' "$*" >&2; }
nginx() { return 0; }
restart_nginx() { return 0; }

apply_calls=0
apply_status=0
apply_nginx_subscription_config() {
    apply_calls=$((apply_calls + 1))
    printf 'listen %s; path %s;\n' "$1" "$2" > "$NGINX_SUBSCRIPTION_CONF"
    return "$apply_status"
}

save_status=1
save_subscription_state() {
    [ "$save_status" -eq 0 ] || return 1
    printf 'token=%s\npath=%s\n' "$SUB_TOKEN" "$SUB_HTTP_PATH" > "$subscription_state_file"
}

commit_status=0
mv() {
    if [[ "${1:-}" == -f && "${2:-}" == */pending-state.conf && "${3:-}" == "$subscription_state_file" ]]; then
        [ "$commit_status" -eq 0 ] || return 1
    fi
    command mv "$@"
}

restore_status=0
cp() {
    if [[ "${1:-}" == -p && "${2:-}" == */nginx.conf && "${3:-}" == "$NGINX_SUBSCRIPTION_CONF" ]]; then
        [ "$restore_status" -eq 0 ] || return 1
    fi
    command cp "$@"
}

CLEANUP_FAIL=0
rm() {
    if [[ "$CLEANUP_FAIL" -eq 1 && "${1:-}" == -rf && "${2:-}" == -- && \
          "${3:-}" == "${work_dir}"/.subscription-token.* ]]; then
        return 1
    fi
    command rm "$@"
}

assert_runtime_unchanged() {
    [[ "$(< "$NGINX_SUBSCRIPTION_CONF")" == "listen 18080; path ${OLD_PATH};" ]] || \
        fail "$1 changed the active Nginx subscription path"
    [[ "$(< "$subscription_state_file")" == old-state ]] || \
        fail "$1 changed the authoritative subscription state"
}

# A state writer failure must be detected during prepare, before Nginx changes.
set +e
rotate_subscription_token
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "state prepare failure returned ${status} instead of 1"
[[ "$apply_calls" -eq 0 ]] || fail 'state prepare failure still changed Nginx'
assert_runtime_unchanged 'state prepare failure'
shopt -s nullglob
recoveries=("${work_dir}"/.subscription-token.*)
[[ "${#recoveries[@]}" -eq 0 ]] || fail 'state prepare failure leaked transaction files'

# A final state commit failure after Nginx changed is fully reversible.
save_status=0
commit_status=1
set +e
rotate_subscription_token
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "fully rolled-back commit failure returned ${status} instead of 1"
assert_runtime_unchanged 'state commit failure'
recoveries=("${work_dir}"/.subscription-token.*)
[[ "${#recoveries[@]}" -eq 0 ]] || fail 'complete token rollback retained transaction files'

# Upgraded installs may have a working Nginx subscription before the lifecycle
# state file existed. Absence is authoritative evidence and must be restored as
# absence if the commit fails.
command rm -f "$subscription_state_file"
printf 'listen 18080; path %s;\n' "$OLD_PATH" > "$NGINX_SUBSCRIPTION_CONF"
before_apply_calls=$apply_calls
set +e
rotate_subscription_token >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "absent-state rollback returned ${status} instead of 1"
[[ "$apply_calls" -eq $((before_apply_calls + 1)) ]] || \
    fail 'absent-state transaction was rejected before exercising commit rollback'
[[ ! -e "$subscription_state_file" ]] || fail 'absent-state rollback created an authoritative state file'
[[ "$(< "$NGINX_SUBSCRIPTION_CONF")" == "listen 18080; path ${OLD_PATH};" ]] || \
    fail 'absent-state rollback did not restore Nginx'
recoveries=("${work_dir}"/.subscription-token.*)
[[ "${#recoveries[@]}" -eq 0 ]] || fail 'absent-state rollback leaked transaction files'
printf '%s\n' old-state > "$subscription_state_file"

# If restoring Nginx fails, rc=2 and the exact secure transaction directory
# must be retained for manual recovery.
restore_status=1
set +e
recovery_output="$(rotate_subscription_token 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "incomplete token rollback returned ${status} instead of 2"
recoveries=("${work_dir}"/.subscription-token.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'incomplete token rollback did not retain one recovery directory'
recovery_dir="${recoveries[0]}"
[[ "$(stat -c '%a' "$recovery_dir")" == 700 ]] || fail 'token recovery directory is not mode 0700'
while IFS= read -r recovery_file; do
    [[ "$(stat -c '%a' "$recovery_file")" == 600 ]] || \
        fail "token recovery artifact is not mode 0600: ${recovery_file}"
done < <(find "$recovery_dir" -maxdepth 1 -type f -print)
[[ -f "${recovery_dir}/nginx.conf" && -f "${recovery_dir}/old-state.conf" && \
   -f "${recovery_dir}/expected-state.conf" && -f "${recovery_dir}/pending-state.conf" ]] || \
    fail 'incomplete token rollback did not retain old and expected state evidence'
[[ "$recovery_output" == *'自动回滚不完整'*"$recovery_dir"* ]] || \
    fail 'incomplete token rollback did not report the retained recovery directory'
command rm -rf -- "$recovery_dir"

# Cleanup happens after the new state and Nginx config are committed. Failure
# to remove a secure transaction directory is a warning, not a false rc=2
# transaction failure.
printf '%s\n' old-state > "$subscription_state_file"
printf 'listen 18080; path %s;\n' "$OLD_PATH" > "$NGINX_SUBSCRIPTION_CONF"
commit_status=0
restore_status=0
CLEANUP_FAIL=1
set +e
cleanup_output="$(rotate_subscription_token 2>&1)"
status=$?
set -e
[[ "$status" -eq 3 ]] || fail "post-commit cleanup warning returned ${status} instead of rc=3"
[[ "$(< "$NGINX_SUBSCRIPTION_CONF")" == "listen 18080; path /${NEW_TOKEN};" ]] || \
    fail 'successful token rotation did not keep the committed Nginx path'
grep -Fq "token=${NEW_TOKEN}" "$subscription_state_file" || \
    fail 'successful token rotation did not keep the committed state'
recoveries=("${work_dir}"/.subscription-token.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'cleanup warning did not identify one retained transaction directory'
[[ "$cleanup_output" == *'已成功'*"${recoveries[0]}"* ]] || \
    fail "cleanup warning did not clearly report success and the retained path: ${cleanup_output}"
command rm -rf -- "${recoveries[0]}"

printf 'Subscription token transaction tests passed.\n'
