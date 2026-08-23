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

function_source="$(sed -n '/^configure_cf_https_subscription() {/,/^}/p' "$script")"
[[ -n "$function_source" ]] || fail 'configure_cf_https_subscription is not implemented'
source <(printf '%s\n' "$function_source")

work_dir="${tmp_dir}/work"
mkdir -p "$work_dir" "${tmp_dir}/nginx"
subscription_state_file="${work_dir}/subscription.conf"
NGINX_SUBSCRIPTION_CONF="${tmp_dir}/nginx/sing-box.conf"
purple=''
re=''
MODE=local
NEW_TOKEN=newtoken0123456789abcdefghjkmnpqr

reset_fixture() {
    printf '%s\n' old-state > "$subscription_state_file"
    printf '%s\n' nginx-old > "$NGINX_SUBSCRIPTION_CONF"
    printf '%s\n' tunnel-old > "${work_dir}/tunnel.yml"
    rm -f "${work_dir}/tunnel.yml.bak.subscription"
    APPLY_CALLS=0
    REMOTE_CALLS=0
    REMOTE_ROUTE=old
}

load_subscription_state() {
    SUB_TOKEN=oldtoken0123456789abcdefghjkmnpqr
    SUB_HTTP_PATH=/oldtoken0123456789abcdefghjkmnpqr
    SUB_HTTPS_ENABLED=1
    SUB_HTTPS_DOMAIN=old.example.com
    SUB_HTTPS_DOMAIN_MODE=reuse
    SUB_HTTPS_PATH=/sub/oldtoken0123456789abcdefghjkmnpqr
    SUB_TUNNEL_MODE="$MODE"
    SUB_HTTPS_VERIFIED_AT=old-time
}
detect_argo_tunnel_mode() { printf '%s\n' "$MODE"; }
is_valid_subscription_path() { return 0; }
is_valid_subscription_domain() { return 0; }
is_valid_subscription_token() { return 0; }
is_valid_http_subscription_path() { return 0; }
get_nginx_subscription_port() { printf '18080\n'; }
get_nginx_subscription_paths() { printf '/oldtoken0123456789abcdefghjkmnpqr\n'; }
generate_subscription_token() { printf '%s\n' "$NEW_TOKEN"; }
build_https_subscription_url() { printf 'https://%s%s\n' "$1" "$2"; }
reading() { confirm=y; apply_method=1; manual_confirm=y; choice=1; }
green() { :; }
yellow() { printf '%s\n' "$*" >&2; }
red() { printf '%s\n' "$*" >&2; }
nginx() { return 0; }
restart_nginx() { return 0; }
restart_argo() { return 0; }

save_subscription_state() {
    printf 'token=%s\npath=%s\n' "$SUB_TOKEN" "$SUB_HTTPS_PATH" > "$subscription_state_file"
}
apply_nginx_subscription_config() {
    APPLY_CALLS=$((APPLY_CALLS + 1))
    printf '%s\n' nginx-new > "$NGINX_SUBSCRIPTION_CONF"
}
apply_local_tunnel_subscription_rule() {
    command cp "$5" "${5}.bak.subscription"
    printf '%s\n' tunnel-new > "$5"
}
apply_remote_tunnel_subscription_rule() {
    REMOTE_CALLS=$((REMOTE_CALLS + 1))
    if [[ "$1" == old.example.com && "$2" == '^/sub/oldtoken0123456789abcdefghjkmnpqr$' && \
          "$REMOTE_CALLS" -gt 1 ]]; then
        REMOTE_ROUTE=old
    else
        REMOTE_ROUTE=new
    fi
}
print_manual_https_route() { :; }
verify_https_subscription() { return 0; }

commit_status=1
CORRUPT_COMMIT=0
mv() {
    if [[ "${1:-}" == -f && "${2:-}" == */pending-state.conf && \
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

RESTORE_STATUS=0
cp() {
    if [[ "${1:-}" == -p && "${2:-}" == */nginx.conf && "${3:-}" == "$NGINX_SUBSCRIPTION_CONF" ]]; then
        [ "$RESTORE_STATUS" -eq 0 ] || return 1
    fi
    command cp "$@"
}

CLEANUP_FAIL=0
rm() {
    if [[ "$CLEANUP_FAIL" -eq 1 && "${1:-}" == -rf && "${2:-}" == -- && \
          "${3:-}" == "${work_dir}"/.subscription-enable.* ]]; then
        return 1
    fi
    command rm "$@"
}

assert_local_rollback() {
    [[ "$APPLY_CALLS" -eq 1 ]] || fail 'local transaction did not reach the state commit boundary'
    [[ "$(< "$NGINX_SUBSCRIPTION_CONF")" == nginx-old ]] || fail 'local commit failure did not restore Nginx'
    [[ "$(< "${work_dir}/tunnel.yml")" == tunnel-old ]] || fail 'local commit failure did not restore tunnel.yml'
    [[ "$(< "$subscription_state_file")" == old-state ]] || fail 'local commit failure replaced active state'
    [[ ! -e "${work_dir}/tunnel.yml.bak.subscription" ]] || fail 'local commit failure leaked a Tunnel backup'
}

reset_fixture
set +e
configure_cf_https_subscription 1 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "local state commit failure returned ${status} instead of 1"
assert_local_rollback

# A commit call can return success while the authoritative file is truncated
# or replaced incorrectly. Compare it with the prepared state and roll back.
reset_fixture
commit_status=0
CORRUPT_COMMIT=1
set +e
configure_cf_https_subscription 1 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "corrupt HTTPS state commit returned ${status} instead of 1"
assert_local_rollback
CORRUPT_COMMIT=0
commit_status=1

# A failed local restore is rc=2 and retains all exact inputs needed for
# manual recovery under a secure directory.
reset_fixture
RESTORE_STATUS=1
set +e
recovery_output="$(configure_cf_https_subscription 1 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "incomplete local HTTPS rollback returned ${status} instead of 2"
shopt -s nullglob
recoveries=("${work_dir}"/.subscription-enable.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'incomplete HTTPS rollback did not retain one recovery directory'
recovery_dir="${recoveries[0]}"
[[ "$(stat -c '%a' "$recovery_dir")" == 700 ]] || fail 'HTTPS recovery directory is not mode 0700'
while IFS= read -r recovery_file; do
    [[ "$(stat -c '%a' "$recovery_file")" == 600 ]] || \
        fail "HTTPS recovery artifact is not mode 0600: ${recovery_file}"
done < <(find "$recovery_dir" -maxdepth 1 -type f -print)
[[ "$recovery_output" == *'自动回滚不完整'*"$recovery_dir"* ]] || \
    fail 'incomplete HTTPS rollback did not report the retained recovery directory'
rm -rf -- "$recovery_dir"
RESTORE_STATUS=0

# Remote automatic route changes need an explicit compensating transaction;
# restoring only Nginx would leave Cloudflare pointing at the uncommitted path.
MODE=remote
reset_fixture
set +e
configure_cf_https_subscription 1 >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "remote state commit failure returned ${status} instead of 1"
[[ "$APPLY_CALLS" -eq 1 ]] || fail 'remote transaction did not reach the state commit boundary'
[[ "$REMOTE_CALLS" -eq 2 && "$REMOTE_ROUTE" == old ]] || \
    fail 'remote state commit failure did not restore the old Cloudflare route'
[[ "$(< "$NGINX_SUBSCRIPTION_CONF")" == nginx-old ]] || fail 'remote commit failure did not restore Nginx'
[[ "$(< "$subscription_state_file")" == old-state ]] || fail 'remote commit failure replaced active state'

# Once state, Tunnel and Nginx are healthy, only backup cleanup can fail. That
# is rc=3 (committed with residue), not rc=2 (uncertain state).
MODE=local
reset_fixture
commit_status=0
CLEANUP_FAIL=1
set +e
cleanup_output="$(configure_cf_https_subscription 1 2>&1)"
status=$?
set -e
[[ "$status" -eq 3 ]] || fail "HTTPS post-commit cleanup returned ${status} instead of rc=3"
recoveries=("${work_dir}"/.subscription-enable.*)
[[ "${#recoveries[@]}" -eq 1 ]] || fail 'HTTPS cleanup warning did not retain one secure transaction directory'
[[ "$cleanup_output" == *'已成功'*"${recoveries[0]}"* ]] || \
    fail 'HTTPS cleanup warning did not report committed success and the retained path'
command rm -rf -- "${recoveries[0]}"

printf 'HTTPS enable transaction tests passed.\n'
