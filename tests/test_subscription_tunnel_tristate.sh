#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

if [[ -z "${JQ_BIN:-}" ]]; then
    if command -v jq >/dev/null 2>&1; then
        JQ_BIN="$(command -v jq)"
    elif [[ -x "${repo_root}/../tools/jq.exe" ]]; then
        JQ_BIN="${repo_root}/../tools/jq.exe"
    else
        echo 'FAIL: jq is required for Tunnel tri-state tests' >&2
        exit 1
    fi
fi
export JQ_BIN

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for function_name in \
    is_valid_subscription_domain \
    is_valid_subscription_path \
    is_valid_tunnel_subscription_regex \
    apply_local_tunnel_subscription_rule \
    build_remote_tunnel_config \
    build_dns_change_plan \
    rollback_remote_tunnel_configuration \
    rollback_cloudflare_dns_change \
    apply_remote_tunnel_subscription_rule; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "${function_name} is not implemented"
    source <(printf '%s\n' "$function_source")
done

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
work_dir="${tmp_root}/remote"
mkdir -p "$work_dir"

CF_TEST_TOKEN='abcdefghijklmnopqrstuvwxyzABCDEF'
ACCOUNT_ID='0123456789abcdef0123456789abcdef'
TUNNEL_ID='11111111-2222-3333-4444-555555555555'
ZONE_ID='fedcba9876543210fedcba9876543210'
SUB_TOKEN='0123456789abcdefghjkmnpqrstvwxyz'
REMOTE_CONFIG='{
  "ingress": [
    {"hostname":"sub.example.com","service":"http://127.0.0.1:8001"},
    {"service":"http_status:404"}
  ]
}'

red() {
    printf '%s' "$*"
}

READING_VALUES=()
READING_INDEX=0
reading() {
    local prompt_text="${1:-}"
    local destination="${2:-}"
    local value="${READING_VALUES[READING_INDEX]:-}"

    : "$prompt_text"
    [[ -n "$destination" ]] || return 1
    printf -v "$destination" '%s' "$value"
    READING_INDEX=$((READING_INDEX + 1))
}

API_SCENARIO=''
CONFIG_PUT_COUNT=0
TOKEN_BODY_LEAK=0
cloudflare_api() {
    local method="${1:-}"
    local url="${2:-}"
    local body_file="${3:-}"

    if [[ -n "$body_file" && -r "$body_file" ]] && \
       grep -Fq -- "$CF_TEST_TOKEN" "$body_file"; then
        TOKEN_BODY_LEAK=1
        return 1
    fi

    case "${method}:${url}" in
        GET:*'/configurations')
            printf '{"success":true,"result":{"config":%s}}\n' "$REMOTE_CONFIG"
            ;;
        PUT:*'/configurations')
            CONFIG_PUT_COUNT=$((CONFIG_PUT_COUNT + 1))
            if [[ "$CONFIG_PUT_COUNT" -eq 1 ]]; then
                case "$API_SCENARIO" in
                    remote_put_lost_rollback_ok|remote_put_lost_rollback_failed)
                        return 1
                        ;;
                    success|dns_create_missing_id)
                        printf '%s\n' '{"success":true,"result":{}}'
                        return 0
                        ;;
                    *) return 1 ;;
                esac
            fi

            "$JQ_BIN" -e \
                '.config.ingress[0].hostname == "sub.example.com" and
                 .config.ingress[-1].service == "http_status:404"' \
                "$body_file" >/dev/null || return 1
            [[ "$API_SCENARIO" != remote_put_lost_rollback_failed ]] || return 1
            printf '%s\n' '{"success":true,"result":{}}'
            ;;
        GET:*'/dns_records?'*)
            printf '%s\n' '{"success":true,"result":[]}'
            ;;
        POST:*'/dns_records')
            [[ "$API_SCENARIO" == dns_create_missing_id ]] || return 1
            printf '%s\n' '{"success":true,"result":{}}'
            ;;
        DELETE:*'/dns_records/'*)
            printf '%s\n' '{"success":true,"result":{}}'
            ;;
        *) return 1 ;;
    esac
}

run_remote_case() {
    local scenario="$1"
    local mode="$2"
    local expected_rc="$3"
    local case_log="${tmp_root}/${scenario}.log"
    local rc

    API_SCENARIO="$scenario"
    CONFIG_PUT_COUNT=0
    TOKEN_BODY_LEAK=0
    READING_INDEX=0
    if [[ "$mode" == separate ]]; then
        READING_VALUES=("$ACCOUNT_ID" "$TUNNEL_ID" "$ZONE_ID")
    else
        READING_VALUES=("$ACCOUNT_ID" "$TUNNEL_ID")
    fi

    set +e
    apply_remote_tunnel_subscription_rule \
        'sub.example.com' "^/${SUB_TOKEN}$" 8080 "$mode" '' '' '' \
        >"$case_log" 2>&1 <<<"$CF_TEST_TOKEN"
    rc=$?
    set -e

    [[ "$rc" -eq "$expected_rc" ]] || \
        fail "${scenario} returned ${rc}, expected ${expected_rc}"
    [[ "$TOKEN_BODY_LEAK" -eq 0 ]] || \
        fail "${scenario} copied the API token into a request body"
    if grep -Fq -- "$CF_TEST_TOKEN" "$case_log"; then
        fail "${scenario} exposed the API token in output"
    fi
    if [[ -n "${CF_TUNNEL_RECOVERY_PATH:-}" && -d "$CF_TUNNEL_RECOVERY_PATH" ]] &&
       grep -R -Fq -- "$CF_TEST_TOKEN" "$CF_TUNNEL_RECOVERY_PATH"; then
        fail "${scenario} retained the API token in recovery evidence"
    fi
    [[ -z "${CF_API_TOKEN+x}" ]] || \
        fail "${scenario} retained the API token after completion"
}

# 0 means the requested remote state was confirmed successful.
run_remote_case success reuse 0

# A lost PUT response is uncertain until an explicit rollback is attempted.
# Confirming the old Tunnel config again makes the final result a safe failure (1).
run_remote_case remote_put_lost_rollback_ok reuse 1

# If the compensating PUT is also unconfirmed, the remote state remains unknown (2).
run_remote_case remote_put_lost_rollback_failed reuse 2

# A successful DNS create response without a record id cannot be compensated safely.
# Even when the Tunnel config rollback succeeds, the DNS result remains unknown (2).
run_remote_case dns_create_missing_id separate 2

# Local mutation follows the same contract. A failed first restart triggers rollback;
# failure to restart the restored config means runtime state is unknown (2).
work_dir="${tmp_root}/local"
mkdir -p "$work_dir"
tunnel_config="${work_dir}/tunnel.yml"
original_config="${tmp_root}/local-original.yml"
printf '%s\n' \
    'ingress:' \
    '  - hostname: sub.example.com' \
    '    service: http://127.0.0.1:8001' \
    '  - service: http_status:404' >"$tunnel_config"
cp -p "$tunnel_config" "$original_config"

cat >"${work_dir}/argo" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 700 "${work_dir}/argo"

render_local_tunnel_with_subscription() {
    local input_file="$1"
    local output_file="$2"

    cp -p "$input_file" "$output_file" || return 1
    printf '%s\n' '# changed by offline test' >>"$output_file"
}

RESTART_CALLS=0
restart_argo() {
    RESTART_CALLS=$((RESTART_CALLS + 1))
    return 1
}

set +e
apply_local_tunnel_subscription_rule \
    'sub.example.com' "^/${SUB_TOKEN}$" 8080 reuse "$tunnel_config" '' \
    >"${tmp_root}/local.log" 2>&1
local_rc=$?
set -e

[[ "$local_rc" -eq 2 ]] || \
    fail "local rollback restart failure returned ${local_rc}, expected 2"
[[ "$RESTART_CALLS" -eq 2 ]] || \
    fail "local rollback restart was not attempted after the initial restart failure"
cmp -s "$original_config" "$tunnel_config" || \
    fail "local configuration was not restored before reporting unknown runtime state"

echo 'Tunnel tri-state transaction tests passed.'
