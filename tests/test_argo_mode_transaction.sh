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

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

for function_name in \
    is_valid_ipv4_address is_valid_ipv6_address is_valid_endpoint_hostname \
    parse_cfip_endpoint format_vless_endpoint rebuild_argo_client_address_set_file \
    get_current_argo_preferred_endpoint create_argo_transition_snapshot \
    restore_argo_transition_snapshot activate_argo_service_mode \
    transition_to_quick_argo transition_to_fixed_argo; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    source <(printf '%s\n' "$function_source")
done

root="${tmp_dir}/root"
work_dir="${root}/etc/sing-box"
client_dir="${work_dir}/url.txt"
mkdir -p "${root}/etc/systemd/system" "$work_dir"
service_file="${root}/etc/systemd/system/argo.service"
transition_log="${tmp_dir}/transition.log"
ARGO_TRANSITION_ROOT="$root"
ARGO_PORT=8080
CFIP=default-edge.example.com
CFPORT=443
ARGO_DOMAIN=fixed.example.com
ARGO_AUTH=old-token
ARGO_FIXED_READY=1
ArgoDomain=fixed.example.com
SUB_HTTPS_ENABLED=1

printf '%s\n' fixed-service > "$service_file"
printf '%s\n' TUNNEL_TOKEN=old-token > "${work_dir}/argo.env"
printf '%s\n' old-tunnel > "${work_dir}/tunnel.yml"
cat > "$client_dir" <<'EOF'
vless://id@fixed.example.com:443?security=tls&sni=fixed.example.com&type=ws&host=fixed.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo
vless://id@user-edge.example.com:8443?security=tls&sni=fixed.example.com&type=ws&host=fixed.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo-preferred
EOF
cp "$client_dir" "${work_dir}/cfy-url.txt"

detect_usable_init_system() { printf 'systemd\n'; }
detect_argo_tunnel_mode() {
    if grep -Fq quick-service "$service_file"; then printf 'quick\n'; else printf 'remote\n'; fi
}
write_argo_systemd_service() {
    printf '%s-service\n' "$1" > "${2}/etc/systemd/system/argo.service"
}
write_argo_openrc_service() { fail 'unexpected OpenRC writer'; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$transition_log"; }
restart_argo() { printf '%s\n' restart >> "$transition_log"; }
get_quick_tunnel() { ArgoDomain=quick.trycloudflare.com; printf '%s\n' quick-domain >> "$transition_log"; }
use_quick_argo_fallback() { ARGO_FIXED_READY=0; ARGO_DOMAIN=''; ARGO_AUTH=''; }
load_subscription_state() { SUB_HTTPS_ENABLED=1; }
disable_status=0
disable_cf_https_subscription() {
    printf '%s\n' disable-https >> "$transition_log"
    return "$disable_status"
}
publish_status=1
change_argo_domain() { printf '%s\n' publish-domain >> "$transition_log"; return "$publish_status"; }
rollback_publish_status=0
update_sub() {
    printf '%s\n' rollback-publish >> "$transition_log"
    return "$rollback_publish_status"
}
red() { printf '%s\n' "$*" >&2; }
yellow() { printf '%s\n' "$*" >&2; }
CLEANUP_FAIL=0
rm() {
    if [[ "$CLEANUP_FAIL" -eq 1 && "${1:-}" == -rf && "${2:-}" == -- && \
          "${3:-}" == "${work_dir}"/.argo-transition.* ]]; then
        return 1
    fi
    command rm "$@"
}

before_service="$(command cat "$service_file")"
before_client="$(command cat "$client_dir")"
before_env="$(command cat "${work_dir}/argo.env")"
if transition_to_quick_argo >/dev/null 2>&1; then
    fail 'fixed-to-quick transition succeeded after subscription publish failure'
fi
[[ "$(command cat "$service_file")" == "$before_service" ]] || fail 'service file was not rolled back'
[[ "$(command cat "$client_dir")" == "$before_client" ]] || fail 'client source was not rolled back'
[[ "$(command cat "${work_dir}/argo.env")" == "$before_env" ]] || fail 'fixed credential was not rolled back'
if grep -Fq disable-https "$transition_log"; then
    fail 'HTTPS was disabled before quick Tunnel/subscription preparation succeeded'
fi
shopt -s nullglob
snapshots=("${work_dir}"/.argo-transition.*)
[[ "${#snapshots[@]}" -eq 0 ]] || fail 'complete rollback retained a transition snapshot'

# If runtime files restore but republishing the restored subscription fails,
# rollback is incomplete. The caller must receive rc=2 and the exact 0700
# recovery directory with 0600 artifacts must remain available.
: > "$transition_log"
publish_status=1
rollback_publish_status=1
set +e
recovery_output="$(transition_to_quick_argo 2>&1)"
recovery_status=$?
set -e
[[ "$recovery_status" -eq 2 ]] || \
    fail "incomplete rollback returned ${recovery_status} instead of 2"
snapshots=("${work_dir}"/.argo-transition.*)
[[ "${#snapshots[@]}" -eq 1 ]] || \
    fail 'incomplete rollback did not retain exactly one transition snapshot'
recovery_dir="${snapshots[0]}"
[[ "$(stat -c '%a' "$recovery_dir")" == 700 ]] || \
    fail 'transition recovery directory is not mode 0700'
while IFS= read -r recovery_file; do
    [[ "$(stat -c '%a' "$recovery_file")" == 600 ]] || \
        fail "transition recovery artifact is not mode 0600: ${recovery_file}"
done < <(find "$recovery_dir" -maxdepth 1 -type f -print)
[[ "$recovery_output" == *'自动回滚不完整'*"$recovery_dir"* ]] || \
    fail 'incomplete rollback did not report the retained recovery path'
rm -rf -- "$recovery_dir"
rollback_publish_status=0

# An incomplete HTTPS-disable rollback is already an externally inconsistent
# state. The surrounding mode transaction must preserve rc=2 and its own
# recovery snapshot instead of downgrading the result to a recoverable rc=1.
: > "$transition_log"
publish_status=0
disable_status=2
set +e
disable_output="$(transition_to_quick_argo 2>&1)"
disable_transition_status=$?
set -e
[[ "$disable_transition_status" -eq 2 ]] || \
    fail "HTTPS disable rc=2 was converted into ${disable_transition_status}"
snapshots=("${work_dir}"/.argo-transition.*)
[[ "${#snapshots[@]}" -eq 1 ]] || \
    fail 'HTTPS disable rc=2 did not retain the surrounding transition snapshot'
[[ "$disable_output" == *'自动回滚不完整'*"${snapshots[0]}"* ]] || \
    fail 'HTTPS disable rc=2 did not report the surrounding recovery snapshot'
[[ "$(command cat "$service_file")" == "$before_service" ]] || \
    fail 'HTTPS disable rc=2 did not restore the fixed service definition'
rm -rf -- "${snapshots[0]}"
disable_status=0

# On success, the current user-selected preferred endpoint is retained and
# HTTPS cleanup is the final irreversible step after publication.
: > "$transition_log"
publish_status=0
CLEANUP_FAIL=1
set +e
cleanup_output="$(transition_to_quick_argo 2>&1)"
cleanup_status=$?
set -e
[[ "$cleanup_status" -eq 3 ]] || \
    fail "successful fixed-to-quick cleanup warning returned ${cleanup_status} instead of rc=3"
grep -Fqx quick-service "$service_file" || fail 'quick service definition was not committed'
grep -Fq '@user-edge.example.com:8443?' "$client_dir" || fail 'user preferred endpoint was not retained'
[[ ! -e "${work_dir}/argo.env" && ! -e "${work_dir}/tunnel.yml" ]] || fail 'obsolete fixed credentials survived quick commit'
publish_line="$(grep -n '^publish-domain$' "$transition_log" | cut -d: -f1)"
disable_line="$(grep -n '^disable-https$' "$transition_log" | cut -d: -f1)"
[[ "$publish_line" =~ ^[0-9]+$ && "$disable_line" =~ ^[0-9]+$ ]] || fail 'transition log is incomplete'
(( publish_line < disable_line )) || fail 'HTTPS was disabled before quick subscription publication'
snapshots=("${work_dir}"/.argo-transition.*)
[[ "${#snapshots[@]}" -eq 1 ]] || fail 'transition cleanup warning did not retain one secure snapshot'
[[ "$cleanup_output" == *'已成功'*"${snapshots[0]}"* ]] || \
    fail 'transition cleanup warning did not report committed success and the retained snapshot'
command rm -rf -- "${snapshots[0]}"
CLEANUP_FAIL=0

# A failed quick-to-fixed transition restores the prior quick mode, client and
# absence of fixed credentials.
: > "$transition_log"
before_service="$(command cat "$service_file")"
before_client="$(command cat "$client_dir")"
publish_status=1
write_fixed_argo_credentials() {
    printf 'TUNNEL_TOKEN=%s\n' "$2" > "${3}/etc/sing-box/argo.env"
}
if transition_to_fixed_argo fixed2.example.com token new-token >/dev/null 2>&1; then
    fail 'quick-to-fixed transition succeeded after publish failure'
fi
[[ "$(command cat "$service_file")" == "$before_service" ]] || fail 'quick service was not restored'
[[ "$(command cat "$client_dir")" == "$before_client" ]] || fail 'quick client was not restored'
[[ ! -e "${work_dir}/argo.env" ]] || fail 'failed fixed credential survived rollback'

printf 'Argo mode transaction tests passed.\n'
