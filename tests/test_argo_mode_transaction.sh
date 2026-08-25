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
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
mkdir -p "${root}/etc/systemd/system" "$conf_dir"
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
printf '%s\n' old-cfy-generation > "${work_dir}/cfy-source.generation"

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
FRONTEND_RECOVERY_PATH=''
_disable_cf_https_subscription_locked() {
    printf '%s\n' disable-https >> "$transition_log"
    if [ "$disable_status" -eq 3 ]; then
        FRONTEND_RECOVERY_PATH="${work_dir}/.mock-frontend-recovery"
        mkdir -p "$FRONTEND_RECOVERY_PATH"
    fi
    return "$disable_status"
}
disable_cf_https_subscription() { _disable_cf_https_subscription_locked "$@"; }
PROXY_LOCK_STATUS=0
acquire_proxy_transaction_lock_checked() {
    printf '%s\n' proxy-lock >> "$transition_log"
    return "$PROXY_LOCK_STATUS"
}
release_proxy_transaction_lock() { printf '%s\n' proxy-unlock >> "$transition_log"; }
publish_status=1
concurrent_base_on_publish_failure=0
ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE=''
ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION=''
ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION=''
CAS_ROLLBACK_STATUS=0
change_argo_transition_subscription() {
    printf '%s\n' publish-domain >> "$transition_log"
    if [[ "$publish_status" -ne 0 && "$concurrent_base_on_publish_failure" -eq 1 ]]; then
        printf '%s\n' concurrent-base-generation > "$client_dir"
    fi
    if [[ "$publish_status" -eq 0 && "${5:-0}" -eq 1 ]]; then
        ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE="${work_dir}/.mock-argo-subscription-rollback"
        ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION=mock-old-generation
        ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION=mock-new-generation
        printf '%s\n' mock-preimage > "$ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE"
    fi
    return "$publish_status"
}
restore_argo_transition_subscription() {
    printf '%s\n' rollback-subscription-cas >> "$transition_log"
    if [ "$CAS_ROLLBACK_STATUS" -eq 0 ]; then
        command rm -f -- "$1"
    fi
    return "$CAS_ROLLBACK_STATUS"
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

# Argo transition recovery owns only the service and credentials. Subscription
# files have their own canonical transaction, so the outer snapshot must not
# retain or restore either the base source or cfy-owned state.
ownership_snapshot="$(create_argo_transition_snapshot systemd)" || \
    fail 'could not create Argo ownership snapshot'
[[ ! -e "${ownership_snapshot}/client" && \
   ! -e "${ownership_snapshot}/client.absent" ]] || \
    fail 'Argo transition snapshot retained the base subscription'
cfy_snapshot_artifact=0
[[ ! -e "${ownership_snapshot}/cfy" && ! -e "${ownership_snapshot}/cfy.absent" ]] || \
    cfy_snapshot_artifact=1
[[ ! -e "${ownership_snapshot}/cfy-source.generation" && \
   ! -e "${ownership_snapshot}/cfy-source.generation.absent" ]] || \
    cfy_snapshot_artifact=1
printf '%s\n' cfy-owner-new-url > "${work_dir}/cfy-url.txt"
printf '%s\n' cfy-owner-new-generation > "${work_dir}/cfy-source.generation"
printf '%s\n' concurrent-base-generation > "$client_dir"
restore_argo_transition_snapshot "$ownership_snapshot" systemd || \
    fail 'could not restore Argo ownership snapshot'
[[ "$cfy_snapshot_artifact" -eq 0 ]] || \
    fail 'Argo transition snapshot retained cfy-owned artifacts'
[[ "$(command cat "${work_dir}/cfy-url.txt")" == cfy-owner-new-url ]] || \
    fail 'Argo transition rollback overwrote cfy-url.txt'
[[ "$(command cat "${work_dir}/cfy-source.generation")" == cfy-owner-new-generation ]] || \
    fail 'Argo transition rollback overwrote cfy-source.generation'
[[ "$(command cat "$client_dir")" == concurrent-base-generation ]] || \
    fail 'Argo transition rollback overwrote a concurrent base subscription'
command rm -rf -- "$ownership_snapshot"

# Both public transition entry points must fail closed before touching runtime
# state when the checked proxy lock reports pending durable recovery evidence.
before_service="$(command cat "$service_file")"
before_client="$(command cat "$client_dir")"
before_env="$(command cat "${work_dir}/argo.env")"
PROXY_LOCK_STATUS=2
for pending_transition in quick fixed; do
    if [ "$pending_transition" = quick ]; then
        if transition_to_quick_argo; then
            pending_status=0
        else
            pending_status=$?
        fi
    else
        if transition_to_fixed_argo fixed2.example.com token new-token; then
            pending_status=0
        else
            pending_status=$?
        fi
    fi
    [[ "$pending_status" -eq 2 ]] || \
        fail "${pending_transition} Argo transition did not preserve pending proxy-lock rc=2"
done
[[ "$(command cat "$service_file")" == "$before_service" ]] || \
    fail 'pending proxy transaction allowed an Argo service mutation'
[[ "$(command cat "$client_dir")" == "$before_client" ]] || \
    fail 'pending proxy transaction allowed an Argo subscription mutation'
[[ "$(command cat "${work_dir}/argo.env")" == "$before_env" ]] || \
    fail 'pending proxy transaction allowed an Argo credential mutation'
if grep -Eq '^(quick-domain|publish-domain|proxy-unlock)$' "$transition_log"; then
    fail 'pending proxy transaction reached or released an unacquired Argo transaction'
fi
for function_name in _transition_to_quick_argo_locked _transition_to_fixed_argo_locked; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    source <(printf '%s\n' "$function_source")
done
PROXY_LOCK_STATUS=0
: > "$transition_log"

# A failed locked publisher owns its own atomic rollback. The surrounding Argo
# service rollback must not republish or restore an older base generation.
cat > "$client_dir" <<'EOF'
vless://id@fixed.example.com:443?security=tls&sni=fixed.example.com&type=ws&host=fixed.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo
vless://id@user-edge.example.com:8443?security=tls&sni=fixed.example.com&type=ws&host=fixed.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo-preferred
EOF
concurrent_base_on_publish_failure=1
if transition_to_quick_argo >/dev/null 2>&1; then
    fail 'fixed-to-quick transition succeeded after concurrent publish failure'
fi
[[ "$(command cat "$client_dir")" == concurrent-base-generation ]] || \
    fail 'Argo outer rollback overwrote the concurrent base generation'
if grep -Fq rollback-publish "$transition_log"; then
    fail 'Argo outer rollback republished subscription state it does not own'
fi
if grep -Fq disable-https "$transition_log"; then
    fail 'quick transition disabled HTTPS after its locked subscription publisher failed'
fi
concurrent_base_on_publish_failure=0
: > "$transition_log"

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
    fail 'HTTPS was disabled after quick subscription publication failed'
fi
shopt -s nullglob
snapshots=("${work_dir}"/.argo-transition.*)
[[ "${#snapshots[@]}" -eq 0 ]] || fail 'complete rollback retained a transition snapshot'

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

# HTTPS disable rc=3 means the target state committed with retained recovery
# evidence. The surrounding quick transition must finish its commit, preserve
# that evidence, and return rc=3 instead of attempting an unsafe outer rollback.
: > "$transition_log"
publish_status=0
disable_status=3
if transition_to_quick_argo >/dev/null 2>&1; then
    disable_cleanup_status=0
else
    disable_cleanup_status=$?
fi
[[ "$disable_cleanup_status" -eq 3 ]] || \
    fail "HTTPS disable cleanup residue became rc ${disable_cleanup_status} during quick transition"
grep -Fqx quick-service "$service_file" || \
    fail 'HTTPS disable rc=3 rolled back the committed quick service'
[[ -d "$FRONTEND_RECOVERY_PATH" ]] || \
    fail 'HTTPS disable rc=3 discarded frontend recovery evidence'
snapshots=("${work_dir}"/.argo-transition.*)
[[ "${#snapshots[@]}" -eq 0 ]] || \
    fail 'HTTPS disable rc=3 retained an unrelated outer transition snapshot'
command rm -rf -- "$FRONTEND_RECOVERY_PATH"
FRONTEND_RECOVERY_PATH=''
disable_status=0
printf '%s\n' fixed-service > "$service_file"
printf '%s\n' TUNNEL_TOKEN=old-token > "${work_dir}/argo.env"
printf '%s\n' old-tunnel > "${work_dir}/tunnel.yml"
ARGO_DOMAIN=fixed.example.com
ARGO_AUTH=old-token
ARGO_FIXED_READY=1
ArgoDomain=fixed.example.com

# On success, the current user-selected preferred endpoint is retained. The
# subscription commit precedes HTTPS cleanup so a publish failure is still a
# fully recoverable rc=1; later failures use a generation-CAS rollback.
: > "$transition_log"
cat > "$client_dir" <<'EOF'
vless://id@fixed.example.com:443?security=tls&sni=fixed.example.com&type=ws&host=fixed.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo
vless://id@user-edge.example.com:8443?security=tls&sni=fixed.example.com&type=ws&host=fixed.example.com&path=%2Fvless-argo#Node-vless-ws-tls-argo-preferred
EOF
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
