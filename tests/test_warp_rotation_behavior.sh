#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

rotate_block=$(sed -n '/^rotate_warp_identity_once() {/,/^}/p' "$script")
[[ -n "$rotate_block" ]] || fail 'rotate_warp_identity_once could not be extracted'
source /dev/stdin <<< "$rotate_block"

auto_select_block=$(sed -n '/^auto_select_warp_candidate() {/,/^}/p' "$script")
[[ -n "$auto_select_block" ]] || fail 'auto_select_warp_candidate could not be extracted'
source /dev/stdin <<< "$auto_select_block"

activation_block=$(sed -n '/^activate_warp_candidate() {/,/^}/p' "$script")
[[ -n "$activation_block" ]] || fail 'activate_warp_candidate could not be extracted'
stable_helper_block=$(sed -n '/^singbox_service_is_stably_active() {/,/^}/p' "$script")
stable_helper_count=$(grep -c '^singbox_service_is_stably_active() {' "$script" || true)
fast_helper_count=$(grep -c '^singbox_service_is_active() {' "$script" || true)
[ "$stable_helper_count" -eq 1 ] || \
    fail "found ${stable_helper_count} stable sing-box service helpers, expected one"
[ "$fast_helper_count" -eq 1 ] || \
    fail "found ${fast_helper_count} fast sing-box service helpers, expected one"
grep -Fq 'detect_usable_init_system' <<< "$stable_helper_block" || \
    fail 'stable sing-box service helper does not use the active-init detector'
stable_activation_checks=$(grep -c 'singbox_service_is_stably_active' <<< "$activation_block" || true)
[ "$stable_activation_checks" -eq 2 ] || \
    fail "WARP activation performs ${stable_activation_checks} stable service checks, expected two"
! grep -Fq 'singbox_service_is_active' <<< "$activation_block" || \
    fail 'WARP activation still uses the fast service helper'
activation_block=${activation_block/#activate_warp_candidate()/activate_warp_candidate_real()}
source /dev/stdin <<< "$activation_block"

generation_cleanup_block=$(sed -n '/^fail_warp_generation_after_registration() {/,/^}/p' "$script")
[[ -n "$generation_cleanup_block" ]] || fail 'registration failure cleanup helper could not be extracted'
source /dev/stdin <<< "$generation_cleanup_block"

identity_commit_block=$(sed -n '/^install_warp_identity_file() {/,/^generate_unique_warp_identity() {/p' "$script" | sed '$d')
[[ -n "$identity_commit_block" ]] || fail 'identity pair transaction helpers could not be extracted'
source /dev/stdin <<< "$identity_commit_block"

generation_block=$(sed -n '/^generate_unique_warp_identity() {/,/^}/p' "$script")
[[ -n "$generation_block" ]] || fail 'generate_unique_warp_identity could not be extracted'
generation_block=${generation_block/#generate_unique_warp_identity()/generate_unique_warp_identity_real()}
source /dev/stdin <<< "$generation_block"

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

reset_fixture() {
    rm -rf "$tmp_root/conf"
    mkdir -p "$tmp_root/conf/warp"
    conf_dir="$tmp_root/conf"
    printf '%s\n' active-A > "$conf_dir/active-identity"
    printf '%s\n' active-account > "$conf_dir/warp/account.json"
    printf '%s\n' current-route > "$conf_dir/route.json"

    GENERATE_CALLS=0
    START_CALLS=0
    STARTED_CALLS=0
    TRACE_CALLS=0
    ACTIVATE_CALLS=0
    RESTART_CALLS=0
    SERVICE_CALLS=0
    VERIFY_CALLS=0
    DELETE_CALLS=0
    STOP_CALLS=0
    CANDIDATE_REMOVE_CALLS=0
    BACKUP_REMOVE_CALLS=0
    PAIR_MV_CALLS=0
    ACTIVE_IP=A
    BASELINE_PROBE_OK=true
    LOG=''
    GENERATION_RESULTS=()
    START_RESULTS=()
    TRACE_RESULTS=()
    TRACE_IPS=()
    DELETE_RESULTS=()
    DELETE_TARGETS=()
    ACTIVATE_RESULTS=()
    RESTART_RESULTS=()
    SERVICE_RESULTS=()
    BACKUP_REMOVE_RESULTS=()
    PAIR_MV_RESULTS=()
    CANDIDATE_REMOVE_RESULTS=()
    SLEEP_DELAYS=()
    VERIFY_RESULT=0
    ALLOW_IPV6_FALLBACK=false
    JQ_MODE=activation
    CURL_MODE=none
    WARP_PROBE_PROXY='mock-proxy'
}

warp_endpoint_is_valid() { return 0; }
extract_warp_endpoint() { printf '%s\n' mock-endpoint; }
green() { LOG+="green:$*"$'\n'; }
yellow() { LOG+="yellow:$*"$'\n'; }
red() { LOG+="red:$*"$'\n'; }
sleep() { SLEEP_DELAYS+=("${1:-}"); }
jq() {
    if [ "$JQ_MODE" = generation_partial ]; then
        case " $* " in
          *' .config.client_id '*) printf '%s\n' invalid-client-id; return 0 ;;
          *' -e '*) return 0 ;;
          *) printf '%s\n' '{}' ; return 0 ;;
        esac
    fi
    if [ "$JQ_MODE" = generation_success ]; then
        case " $* " in
          *' .config.client_id '*) printf '%s\n' AQID; return 0 ;;
          *' .config.interface.addresses.v4 '*) printf '%s\n' 172.16.0.2; return 0 ;;
          *' .config.interface.addresses.v6 '*) printf '%s\n' 2606:4700:110::2; return 0 ;;
          *' .config.peers[0].public_key '*) printf '%s\n' peer-key; return 0 ;;
          *' . + {private_key:$private,reserved:$reserved} '*) printf '%s\n' new-account; return 0 ;;
          *' --argjson a '*) printf '%s\n' '[1,2,3]'; return 0 ;;
          *' --arg private '*) printf '%s\n' new-endpoint; return 0 ;;
          *' -e '*) return 0 ;;
          *) printf '%s\n' '{}' ; return 0 ;;
        esac
    fi
    local input="${!#}"
    if [ -f "$input" ]; then
        command cat "$input"
    else
        printf '%s\n' '{}'
    fi
}
command_exists() { return 0; }
curl() {
    local output_file='' arg
    [ "$CURL_MODE" = registered ] || return 1
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        if [ "$arg" = -o ] && [ "$#" -gt 0 ]; then
            output_file="$1"
            shift
        fi
    done
    [ -n "$output_file" ] || return 1
    printf '%s\n' '{"id":"partial-device","token":"partial-token"}' > "$output_file"
    printf '%s' 200
}
install() {
    [ "${1:-}" = -m ] && [ "$#" -eq 4 ] || return 1
    command cp "$3" "$4"
}
mv() {
    local result
    PAIR_MV_CALLS=$((PAIR_MV_CALLS + 1))
    result="${PAIR_MV_RESULTS[$((PAIR_MV_CALLS - 1))]:-0}"
    [ "$result" -eq 0 ] || return "$result"
    command mv "$@"
}
validate_singbox_config() { return 0; }
warp_endpoint_is_legacy() { return 1; }
write_warp_status_cache() { return 0; }
render_warp_route_family() {
    command cat "$1" > "$2"
    printf 'family=%s\n' "$3" >> "$2"
}

restart_singbox_checked() {
    local result
    RESTART_CALLS=$((RESTART_CALLS + 1))
    result="${RESTART_RESULTS[$((RESTART_CALLS - 1))]:-0}"
    [ "$result" -eq 0 ]
}

singbox_service_is_stably_active() {
    local result
    SERVICE_CALLS=$((SERVICE_CALLS + 1))
    result="${SERVICE_RESULTS[$((SERVICE_CALLS - 1))]:-0}"
    [ "$result" -eq 0 ]
}

verify_activated_warp() {
    VERIFY_CALLS=$((VERIFY_CALLS + 1))
    [ "$VERIFY_RESULT" -eq 0 ]
}
run_selected_unlock_checks() {
    WARP_UNLOCK_SUMMARY=''
    return 0
}

remove_warp_candidate_dir() {
    local target="$1" result
    CANDIDATE_REMOVE_CALLS=$((CANDIDATE_REMOVE_CALLS + 1))
    result="${CANDIDATE_REMOVE_RESULTS[$((CANDIDATE_REMOVE_CALLS - 1))]:-0}"
    [ "$result" -eq 0 ] || return "$result"
    command rm -rf -- "$target"
}

remove_warp_activation_backup() {
    local target="$1" result
    BACKUP_REMOVE_CALLS=$((BACKUP_REMOVE_CALLS + 1))
    result="${BACKUP_REMOVE_RESULTS[$((BACKUP_REMOVE_CALLS - 1))]:-0}"
    [ "$result" -eq 0 ] || return "$result"
    command rm -rf -- "$target"
}

probe_active_warp() {
    [ "$BASELINE_PROBE_OK" = true ] || return 1
    WARP_PROBE_IP="$ACTIVE_IP"
}

generate_unique_warp_identity() {
    local candidate_dir="$1" result
    GENERATE_CALLS=$((GENERATE_CALLS + 1))
    result="${GENERATION_RESULTS[$((GENERATE_CALLS - 1))]:-0}"
    if [ "$result" -eq 2 ]; then
        mkdir -p "$candidate_dir/.register.partial"
        printf '%s\n' "partial-account-${GENERATE_CALLS}" > "$candidate_dir/.register.partial/response.json"
        printf '%s\n' "partial-account-${GENERATE_CALLS}" > "$candidate_dir/account.json"
        return 2
    fi
    [ "$result" -eq 0 ] || return "$result"
    printf '%s\n' "candidate-${GENERATE_CALLS}" > "$candidate_dir/endpoint.json"
    printf '%s\n' "account-${GENERATE_CALLS}" > "$candidate_dir/account.json"
}

start_warp_candidate_proxy() {
    local result
    if [ "${2:-4}" = 6 ] && [ "$ALLOW_IPV6_FALLBACK" != true ]; then
        return 1
    fi
    START_CALLS=$((START_CALLS + 1))
    result="${START_RESULTS[$((START_CALLS - 1))]:-0}"
    [ "$result" -eq 0 ] || return "$result"
    STARTED_CALLS=$((STARTED_CALLS + 1))
    WARP_PROBE_PROXY='mock-proxy'
}

probe_warp_trace() {
    local result
    TRACE_CALLS=$((TRACE_CALLS + 1))
    result="${TRACE_RESULTS[$((TRACE_CALLS - 1))]:-0}"
    [ "$result" -eq 0 ] || return "$result"
    WARP_PROBE_IP="${TRACE_IPS[$((TRACE_CALLS - 1))]}"
    WARP_PROBE_STATE=on
}

stop_warp_candidate_proxy() {
    STOP_CALLS=$((STOP_CALLS + 1))
}

delete_warp_registration() {
    local target="$1" result
    DELETE_CALLS=$((DELETE_CALLS + 1))
    DELETE_TARGETS+=("$target")
    result="${DELETE_RESULTS[$((DELETE_CALLS - 1))]:-0}"
    [ "$result" -eq 0 ]
}

activate_warp_candidate() {
    local candidate_dir="$1" expected_ip="$2" result
    ACTIVATE_CALLS=$((ACTIVATE_CALLS + 1))
    RESTART_CALLS=$((RESTART_CALLS + 1))
    [ -s "$candidate_dir/account.json" ] || return 1
    result="${ACTIVATE_RESULTS[$((ACTIVATE_CALLS - 1))]:-0}"
    if [ "$result" -eq 0 ] || [ "$result" -eq 3 ]; then
        printf '%s\n' "active-${expected_ip}" > "$conf_dir/active-identity"
    fi
    return "$result"
}

assert_no_candidate_directories() {
    if find "$conf_dir/warp" -maxdepth 1 -type d -name '.candidate.*' -print -quit | grep -q .; then
        fail 'a local candidate directory was not cleaned'
    fi
}

assert_one_candidate_directory() {
    local candidate_count
    candidate_count=$(find "$conf_dir/warp" -maxdepth 1 -type d -name '.candidate.*' | wc -l | tr -d ' ')
    [ "$candidate_count" -eq 1 ] || fail "found ${candidate_count} candidate directories, expected 1"
}

assert_no_activation_backups() {
    if find "$conf_dir" -maxdepth 1 -type d -name '.warp-activate.*' -print -quit | grep -q .; then
        fail 'an activation backup directory was not cleaned'
    fi
}

assert_one_activation_backup() {
    local backup_count
    backup_count=$(find "$conf_dir" -maxdepth 1 -type d -name '.warp-activate.*' | wc -l | tr -d ' ')
    [ "$backup_count" -eq 1 ] || fail "found ${backup_count} activation backups, expected 1"
}

make_activation_candidate() {
    local candidate_dir="$conf_dir/warp/.candidate.activation"
    printf '%s\n' current-endpoint > "$conf_dir/endpoints.json"
    printf '%s\n' old-endpoint > "$conf_dir/warp/endpoint.json"
    printf '%s\n' old-account > "$conf_dir/warp/account.json"
    mkdir -p "$candidate_dir"
    printf '%s\n' new-endpoint > "$candidate_dir/endpoint.json"
    printf '%s\n' new-account > "$candidate_dir/account.json"
    printf '%s\n' "$candidate_dir"
}

assert_candidate_delete_targets() {
    local expected="$1" target
    [ "${#DELETE_TARGETS[@]}" -eq "$expected" ] || \
        fail "recorded ${#DELETE_TARGETS[@]} deletion targets, expected ${expected}"
    for target in "${DELETE_TARGETS[@]}"; do
        case "$target" in
          "$conf_dir"/warp/.candidate.*/account.json) ;;
          *) fail "non-candidate registration deletion target: ${target}" ;;
        esac
        [ "$target" != "$conf_dir/warp/account.json" ] || fail 'active account was sent for deletion'
    done
}

reset_fixture
TRACE_IPS=(A A B)
rotate_warp_identity_once || fail 'rotation rejected the first different candidate'
[ "$GENERATE_CALLS" -eq 3 ] || fail "generated ${GENERATE_CALLS} candidates, expected 3"
[ "$DELETE_CALLS" -eq 2 ] || fail "deleted ${DELETE_CALLS} same-IP candidates, expected 2"
[ "$STOP_CALLS" -eq 3 ] || fail "stopped ${STOP_CALLS} proxies, expected 3"
[ "$STOP_CALLS" -eq "$STARTED_CALLS" ] || fail 'proxy stop count did not match started candidates'
[ "$ACTIVATE_CALLS" -eq 1 ] || fail "activated ${ACTIVATE_CALLS} candidates, expected 1"
[ "$RESTART_CALLS" -eq 1 ] || fail "restarted ${RESTART_CALLS} times, expected 1"
[ "$(<"$conf_dir/active-identity")" = active-B ] || fail 'candidate B was not activated'
assert_candidate_delete_targets 2
assert_no_candidate_directories

reset_fixture
TRACE_IPS=(A A A A A)
if rotate_warp_identity_once; then
    fail 'all-same-IP rotation unexpectedly succeeded'
fi
[ "$GENERATE_CALLS" -eq 5 ] || fail "generated ${GENERATE_CALLS} candidates, expected 5"
[ "$DELETE_CALLS" -eq 5 ] || fail "deleted ${DELETE_CALLS} same-IP candidates, expected 5"
[ "$STOP_CALLS" -eq 5 ] || fail "stopped ${STOP_CALLS} proxies, expected 5"
[ "$STOP_CALLS" -eq "$STARTED_CALLS" ] || fail 'proxy stop count did not match started candidates'
[ "$ACTIVATE_CALLS" -eq 0 ] || fail "activated ${ACTIVATE_CALLS} same-IP candidates"
[ "$RESTART_CALLS" -eq 0 ] || fail "restarted ${RESTART_CALLS} times for same-IP candidates"
[ "$(<"$conf_dir/active-identity")" = active-A ] || fail 'all-same-IP exhaustion changed the active identity'
[[ "$LOG" == *'未获得不同的 Cloudflare WARP 出口 IP'* ]] || fail 'same-IP exhaustion was not clearly reported'
assert_candidate_delete_targets 5
assert_no_candidate_directories

reset_fixture
BASELINE_PROBE_OK=false
TRACE_IPS=(B)
if rotate_warp_identity_once; then
    fail 'rotation unexpectedly succeeded without a current WARP baseline'
fi
[ "$GENERATE_CALLS" -eq 0 ] || fail 'a candidate was generated after the baseline probe failed'
[ "$STOP_CALLS" -eq 0 ] || fail 'a proxy was stopped after the baseline probe failed'
[ "$DELETE_CALLS" -eq 0 ] || fail 'a registration was deleted after the baseline probe failed'
[ "$ACTIVATE_CALLS" -eq 0 ] || fail 'a candidate was activated after the baseline probe failed'
[ "$RESTART_CALLS" -eq 0 ] || fail 'sing-box was restarted after the baseline probe failed'
[ "$(<"$conf_dir/active-identity")" = active-A ] || fail 'baseline failure changed the active identity'
assert_candidate_delete_targets 0
assert_no_candidate_directories

reset_fixture
GENERATION_RESULTS=(1 0 0 0)
START_RESULTS=(1 0 0)
TRACE_RESULTS=(1 0)
TRACE_IPS=(unused B)
rotate_warp_identity_once || fail 'rotation did not continue past transient candidate failures'
[ "$GENERATE_CALLS" -eq 4 ] || fail "generated ${GENERATE_CALLS} candidates, expected 4"
[ "$START_CALLS" -eq 3 ] || fail "attempted to start ${START_CALLS} proxies, expected 3"
[ "$STARTED_CALLS" -eq 2 ] || fail "started ${STARTED_CALLS} proxies, expected 2"
[ "$STOP_CALLS" -eq 2 ] || fail "stopped ${STOP_CALLS} proxies, expected 2"
[ "$STOP_CALLS" -eq "$STARTED_CALLS" ] || fail 'proxy stop count did not match started candidates'
[ "$DELETE_CALLS" -eq 2 ] || fail "deleted ${DELETE_CALLS} failed candidates, expected 2"
[ "$ACTIVATE_CALLS" -eq 1 ] || fail "activated ${ACTIVATE_CALLS} candidates, expected 1"
[ "$RESTART_CALLS" -eq 1 ] || fail "restarted ${RESTART_CALLS} times, expected 1"
[ "$(<"$conf_dir/active-identity")" = active-B ] || fail 'candidate B was not activated after transient failures'
[ "${SLEEP_DELAYS[*]}" = '2 4 6' ] || fail "transient retry backoff was '${SLEEP_DELAYS[*]}', expected '2 4 6'"
assert_candidate_delete_targets 2
assert_no_candidate_directories

reset_fixture
TRACE_IPS=(A A A A A)
DELETE_RESULTS=(1)
if rotate_warp_identity_once; then cleanup_rc=0; else cleanup_rc=$?; fi
[ "$cleanup_rc" -eq 2 ] || fail "cloud cleanup failure returned ${cleanup_rc}, expected 2"
[ "$GENERATE_CALLS" -eq 1 ] || fail 'rotation continued after cloud cleanup failed'
[ "$STARTED_CALLS" -eq 1 ] || fail 'unexpected proxy start count before cloud cleanup failure'
[ "$STOP_CALLS" -eq 1 ] || fail 'the rejected candidate proxy was not stopped exactly once'
[ "$DELETE_CALLS" -eq 1 ] || fail 'cloud deletion was not attempted exactly once'
[ "$ACTIVATE_CALLS" -eq 0 ] || fail 'a candidate was activated after cloud cleanup failed'
[ "$RESTART_CALLS" -eq 0 ] || fail 'sing-box was restarted after cloud cleanup failed'
[ "$(<"$conf_dir/active-identity")" = active-A ] || fail 'cloud cleanup failure changed the active identity'
assert_candidate_delete_targets 1
preserved_dir=$(dirname "${DELETE_TARGETS[0]}")
[ -d "$preserved_dir" ] || fail 'candidate directory was removed after cloud deletion failed'
[ -s "$preserved_dir/account.json" ] || fail 'candidate credentials were removed after cloud deletion failed'
[[ "$LOG" == *'候选凭据保留在:'* ]] || fail 'cloud cleanup failure omitted the recovery path'

reset_fixture
TRACE_IPS=(B)
ACTIVATE_RESULTS=(1)
if rotate_warp_identity_once; then activation_rc=0; else activation_rc=$?; fi
[ "$activation_rc" -eq 1 ] || fail "rolled-back activation returned ${activation_rc}, expected 1"
[ "$DELETE_CALLS" -eq 1 ] || fail 'rolled-back candidate registration was not deleted exactly once'
[ "$(<"$conf_dir/active-identity")" = active-A ] || fail 'rolled-back activation changed the active identity'
assert_candidate_delete_targets 1
assert_no_candidate_directories

reset_fixture
TRACE_IPS=(B)
ACTIVATE_RESULTS=(1)
DELETE_RESULTS=(1)
if rotate_warp_identity_once; then activation_cleanup_rc=0; else activation_cleanup_rc=$?; fi
[ "$activation_cleanup_rc" -eq 2 ] || fail "rolled-back cloud cleanup failure returned ${activation_cleanup_rc}, expected 2"
[ "$DELETE_CALLS" -eq 1 ] || fail 'rolled-back cloud deletion was not attempted exactly once'
[ "$(<"$conf_dir/active-identity")" = active-A ] || fail 'rolled-back cloud cleanup failure changed the active identity'
assert_candidate_delete_targets 1
assert_one_candidate_directory
preserved_dir=$(dirname "${DELETE_TARGETS[0]}")
[ -s "$preserved_dir/account.json" ] || fail 'rolled-back candidate credentials were discarded after DELETE failed'

reset_fixture
TRACE_IPS=(B)
ACTIVATE_RESULTS=(2)
if rotate_warp_identity_once; then incomplete_rc=0; else incomplete_rc=$?; fi
[ "$incomplete_rc" -eq 2 ] || fail "incomplete rollback returned ${incomplete_rc}, expected 2"
[ "$DELETE_CALLS" -eq 0 ] || fail 'candidate registration was deleted after incomplete rollback'
[ "$(<"$conf_dir/active-identity")" = active-A ] || fail 'mock incomplete rollback unexpectedly committed the candidate'
assert_one_candidate_directory

reset_fixture
TRACE_IPS=(B)
ACTIVATE_RESULTS=(3)
rotate_warp_identity_once || fail 'committed activation with cleanup warning was treated as a failed rotation'
[ "$DELETE_CALLS" -eq 0 ] || fail 'the committed active registration was sent for deletion'
[ "$(<"$conf_dir/active-identity")" = active-B ] || fail 'committed cleanup-warning activation did not remain active'
assert_no_candidate_directories
[[ "$LOG" == *'清理未完成'* ]] || fail 'committed cleanup warning was not reported'

reset_fixture
TRACE_IPS=(B)
CANDIDATE_REMOVE_RESULTS=(1)
rotate_warp_identity_once || fail 'candidate local cleanup failure downgraded a committed activation'
[ "$DELETE_CALLS" -eq 0 ] || fail 'active registration was deleted after candidate local cleanup failed'
[ "$(<"$conf_dir/active-identity")" = active-B ] || fail 'candidate local cleanup failure changed the committed identity'
assert_one_candidate_directory
[[ "$LOG" == *'候选凭据保留在:'* ]] || fail 'candidate local cleanup failure omitted its recovery path'

reset_fixture
GENERATION_RESULTS=(2 0)
if rotate_warp_identity_once; then partial_rc=0; else partial_rc=$?; fi
[ "$partial_rc" -eq 2 ] || fail "partial-registration failure returned ${partial_rc}, expected 2"
[ "$GENERATE_CALLS" -eq 1 ] || fail 'rotation retried after registration state became uncertain'
[ "$START_CALLS" -eq 0 ] || fail 'rotation probed a partial registration'
[ "$DELETE_CALLS" -eq 0 ] || fail 'outer rotation deleted a partial registration it does not own'
assert_one_candidate_directory
partial_dir=$(find "$conf_dir/warp" -maxdepth 1 -type d -name '.candidate.*' -print -quit)
[ -s "$partial_dir/.register.partial/response.json" ] || fail 'partial-registration recovery response was discarded'

reset_fixture
GENERATION_RESULTS=(2 2 2 2 2)
if auto_select_warp_candidate 1; then auto_partial_rc=0; else auto_partial_rc=$?; fi
[ "$auto_partial_rc" -eq 2 ] || fail "auto-select partial-registration failure returned ${auto_partial_rc}, expected 2"
[ "$GENERATE_CALLS" -eq 1 ] || fail 'auto-select retried after registration state became uncertain'
[ "$START_CALLS" -eq 0 ] || fail 'auto-select probed a partial registration'
assert_one_candidate_directory
auto_partial_dir=$(find "$conf_dir/warp" -maxdepth 1 -type d -name '.candidate.*' -print -quit)
[ -s "$auto_partial_dir/.register.partial/response.json" ] || fail 'auto-select discarded partial-registration recovery credentials'

reset_fixture
TRACE_IPS=(B B B B B)
ACTIVATE_RESULTS=(3 3 3 3 3)
auto_select_warp_candidate 1 || fail 'auto-select treated committed cleanup-warning activation as failure'
[ "$GENERATE_CALLS" -eq 1 ] || fail 'auto-select continued after committed cleanup-warning activation'
[ "$ACTIVATE_CALLS" -eq 1 ] || fail 'auto-select activated more than one committed cleanup-warning candidate'
[ "$DELETE_CALLS" -eq 0 ] || fail 'auto-select deleted the committed active registration'
[ "$STOP_CALLS" -eq 1 ] || fail "auto-select stopped the committed candidate proxy ${STOP_CALLS} times, expected once"
[ "$(<"$conf_dir/active-identity")" = active-B ] || fail 'auto-select did not retain the committed cleanup-warning identity'
assert_no_candidate_directories

reset_fixture
TRACE_IPS=(B B B B B)
ACTIVATE_RESULTS=(1 0)
DELETE_RESULTS=(1)
if auto_select_warp_candidate 1; then auto_rollback_cleanup_rc=0; else auto_rollback_cleanup_rc=$?; fi
[ "$auto_rollback_cleanup_rc" -eq 2 ] || fail "auto-select rolled-back cloud cleanup failure returned ${auto_rollback_cleanup_rc}, expected 2"
[ "$GENERATE_CALLS" -eq 1 ] || fail 'auto-select retried after rolled-back candidate DELETE failed'
[ "$DELETE_CALLS" -eq 1 ] || fail 'auto-select did not attempt one rolled-back candidate DELETE'
[ "$STOP_CALLS" -eq 1 ] || fail "auto-select double-stopped the rolled-back candidate proxy (${STOP_CALLS} stops)"
[ "$(<"$conf_dir/active-identity")" = active-A ] || fail 'auto-select cloud cleanup failure changed the active identity'
assert_one_candidate_directory
auto_preserved_dir=$(dirname "${DELETE_TARGETS[0]}")
[ -s "$auto_preserved_dir/account.json" ] || fail 'auto-select discarded rolled-back candidate credentials after DELETE failed'

reset_fixture
TRACE_IPS=(B)
ACTIVATE_RESULTS=(2)
if auto_select_warp_candidate 1; then auto_incomplete_rc=0; else auto_incomplete_rc=$?; fi
[ "$auto_incomplete_rc" -eq 2 ] || fail "auto-select incomplete rollback returned ${auto_incomplete_rc}, expected 2"
[ "$DELETE_CALLS" -eq 0 ] || fail 'auto-select deleted candidate registration after incomplete rollback'
[ "$STOP_CALLS" -eq 1 ] || fail "auto-select stopped incomplete-rollback proxy ${STOP_CALLS} times, expected once"
assert_one_candidate_directory

reset_fixture
TRACE_IPS=(B)
ACTIVATE_RESULTS=(1)
CANDIDATE_REMOVE_RESULTS=(1)
if auto_select_warp_candidate 1; then auto_local_cleanup_rc=0; else auto_local_cleanup_rc=$?; fi
[ "$auto_local_cleanup_rc" -eq 2 ] || fail "auto-select rolled-back local cleanup failure returned ${auto_local_cleanup_rc}, expected 2"
[ "$DELETE_CALLS" -eq 1 ] || fail 'auto-select did not delete rolled-back cloud candidate before local cleanup'
[ "$STOP_CALLS" -eq 1 ] || fail "auto-select double-stopped proxy before local cleanup failure (${STOP_CALLS} stops)"
[ "$(<"$conf_dir/active-identity")" = active-A ] || fail 'auto-select local cleanup failure changed the active identity'
assert_one_candidate_directory

reset_fixture
TRACE_IPS=(B C)
ACTIVATE_RESULTS=(1 0)
auto_select_warp_candidate 1 || fail 'auto-select did not continue after a fully cleaned rc=1 rollback'
[ "$GENERATE_CALLS" -eq 2 ] || fail 'auto-select did not use exactly two candidates after one clean rollback'
[ "$DELETE_CALLS" -eq 1 ] || fail 'auto-select clean rollback did not delete exactly one inactive candidate'
[ "$STOP_CALLS" -eq 2 ] || fail "auto-select proxy stop count was ${STOP_CALLS}, expected 2"
[ "$STOP_CALLS" -eq "$STARTED_CALLS" ] || fail 'auto-select double-stopped a proxy after clean rollback'
[ "$(<"$conf_dir/active-identity")" = active-C ] || fail 'auto-select did not commit the candidate after a clean rollback retry'
assert_no_candidate_directories

reset_fixture
GENERATION_RESULTS=(1 1 1 1 1)
if rotate_warp_identity_once; then
    fail 'all-failed candidate rotation unexpectedly succeeded'
fi
[ "$GENERATE_CALLS" -eq 5 ] || fail "all-failed exhaustion generated ${GENERATE_CALLS} candidates, expected 5"
[ "${SLEEP_DELAYS[*]}" = '2 4 6 8' ] || fail "all-failed backoff was '${SLEEP_DELAYS[*]}', expected '2 4 6 8'"
[[ "$LOG" == *'候选均在生成或探测阶段失败'* ]] || fail 'all-failed exhaustion was reported as same-IP exhaustion'
assert_no_candidate_directories

reset_fixture
activation_candidate=$(make_activation_candidate)
VERIFY_RESULT=1
if activate_warp_candidate_real "$activation_candidate" B; then real_activation_rc=0; else real_activation_rc=$?; fi
[ "$real_activation_rc" -eq 1 ] || fail "real rolled-back activation returned ${real_activation_rc}, expected 1"
[ "$(<"$conf_dir/warp/account.json")" = old-account ] || fail 'real rc=1 activation did not restore the old account'
[ "$(<"$conf_dir/route.json")" = current-route ] || fail 'real rc=1 activation did not restore the old route'
[ ! -e "$conf_dir/warp/preferred-family" ] || fail 'real rc=1 activation retained the candidate address family'
[ "$DELETE_CALLS" -eq 0 ] || fail 'real rc=1 activation deleted a cloud registration'
assert_no_activation_backups

reset_fixture
activation_candidate=$(make_activation_candidate)
VERIFY_RESULT=1
RESTART_RESULTS=(0 1)
if activate_warp_candidate_real "$activation_candidate" B; then real_incomplete_rc=0; else real_incomplete_rc=$?; fi
[ "$real_incomplete_rc" -eq 2 ] || fail "real incomplete rollback returned ${real_incomplete_rc}, expected 2"
[ "$DELETE_CALLS" -eq 0 ] || fail 'real incomplete rollback deleted a cloud registration'
assert_one_activation_backup
[ -s "$activation_candidate/account.json" ] || fail 'real incomplete rollback lost candidate credentials'

reset_fixture
activation_candidate=$(make_activation_candidate)
DELETE_RESULTS=(1)
if activate_warp_candidate_real "$activation_candidate" B; then old_delete_rc=0; else old_delete_rc=$?; fi
[ "$old_delete_rc" -eq 3 ] || fail "committed old-registration cleanup failure returned ${old_delete_rc}, expected 3"
[ "$(<"$conf_dir/warp/account.json")" = new-account ] || fail 'old-registration cleanup failure rolled back the committed account'
assert_one_activation_backup
activation_backup=$(find "$conf_dir" -maxdepth 1 -type d -name '.warp-activate.*' -print -quit)
[ "$(<"$activation_backup/account.json")" = old-account ] || fail 'old registration credentials were not preserved in the activation backup'

reset_fixture
activation_candidate=$(make_activation_candidate)
BACKUP_REMOVE_RESULTS=(1)
if activate_warp_candidate_real "$activation_candidate" B; then backup_cleanup_rc=0; else backup_cleanup_rc=$?; fi
[ "$backup_cleanup_rc" -eq 3 ] || fail "committed backup cleanup failure returned ${backup_cleanup_rc}, expected 3"
[ "$(<"$conf_dir/warp/account.json")" = new-account ] || fail 'backup cleanup failure rolled back the committed account'
[ "$DELETE_CALLS" -eq 1 ] || fail 'old registration was not deleted before backup cleanup failed'
assert_one_activation_backup

reset_fixture
activation_candidate=$(make_activation_candidate)
if activate_warp_candidate_real "$activation_candidate" B '' 6; then family_commit_rc=0; else family_commit_rc=$?; fi
[ "$family_commit_rc" -eq 0 ] || fail "IPv6-family activation returned ${family_commit_rc}, expected 0"
[ "$(<"$conf_dir/warp/preferred-family")" = 6 ] || fail 'IPv6-family activation did not persist family 6'
grep -Fqx 'family=6' "$conf_dir/route.json" || fail 'IPv6-family activation did not commit its rendered route'
assert_no_activation_backups

reset_fixture
JQ_MODE=generation_partial
CURL_MODE=registered
work_dir="$tmp_root/work"
server_name=sing-box
mkdir -p "$work_dir"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "PrivateKey: private-key\\nPublicKey: public-key\\n"' > "$work_dir/$server_name"
chmod +x "$work_dir/$server_name"
generation_state="$conf_dir/warp/.candidate.real-generation"
mkdir -p "$generation_state"
DELETE_RESULTS=(1)
if generate_unique_warp_identity_real "$generation_state"; then real_generation_rc=0; else real_generation_rc=$?; fi
[ "$real_generation_rc" -eq 2 ] || fail "real partial-registration cleanup failure returned ${real_generation_rc}, expected 2"
[ "$DELETE_CALLS" -eq 1 ] || fail 'real partial-registration cleanup did not attempt one cloud DELETE'
generation_recovery=$(find "$generation_state" -maxdepth 1 -type d -name '.register.*' -print -quit)
[ -n "$generation_recovery" ] || fail 'real partial-registration recovery directory was discarded'
[ -s "$generation_recovery/response.json" ] || fail 'real partial-registration response credentials were discarded'

reset_fixture
JQ_MODE=generation_success
CURL_MODE=registered
work_dir="$tmp_root/work-pair-empty"
server_name=sing-box
mkdir -p "$work_dir"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "PrivateKey: private-key\\nPublicKey: public-key\\n"' > "$work_dir/$server_name"
chmod +x "$work_dir/$server_name"
rm -f -- "$conf_dir/warp/endpoint.json" "$conf_dir/warp/account.json"
PAIR_MV_RESULTS=(0 1)
if generate_unique_warp_identity_real; then empty_pair_rc=0; else empty_pair_rc=$?; fi
[ "$empty_pair_rc" -eq 1 ] || fail "second-move failure without an old pair returned ${empty_pair_rc}, expected 1"
[ "$DELETE_CALLS" -eq 1 ] || fail 'second-move failure did not clean the new cloud registration'
[ ! -e "$conf_dir/warp/endpoint.json" ] || fail 'second-move failure left a new endpoint without its account'
[ ! -e "$conf_dir/warp/account.json" ] || fail 'second-move failure left a new account without its endpoint'

reset_fixture
JQ_MODE=generation_success
CURL_MODE=registered
work_dir="$tmp_root/work-pair-restore"
server_name=sing-box
mkdir -p "$work_dir"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "PrivateKey: private-key\\nPublicKey: public-key\\n"' > "$work_dir/$server_name"
chmod +x "$work_dir/$server_name"
printf '%s\n' old-endpoint > "$conf_dir/warp/endpoint.json"
printf '%s\n' old-account > "$conf_dir/warp/account.json"
PAIR_MV_RESULTS=(0 1)
if generate_unique_warp_identity_real; then restored_pair_rc=0; else restored_pair_rc=$?; fi
[ "$restored_pair_rc" -eq 1 ] || fail "second-move failure with an old pair returned ${restored_pair_rc}, expected 1"
[ "$DELETE_CALLS" -eq 1 ] || fail 'restored-pair failure did not clean the new cloud registration'
[ "$(<"$conf_dir/warp/endpoint.json")" = old-endpoint ] || fail 'old endpoint was not restored after pair commit failed'
[ "$(<"$conf_dir/warp/account.json")" = old-account ] || fail 'old account was not restored after pair commit failed'
! find "$conf_dir/warp" -maxdepth 1 -type d -name '.identity-commit.*' -print -quit | grep -q . || \
  fail 'completed pair rollback left a transaction directory'

reset_fixture
JQ_MODE=generation_success
CURL_MODE=registered
work_dir="$tmp_root/work-pair-incomplete"
server_name=sing-box
mkdir -p "$work_dir"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "PrivateKey: private-key\\nPublicKey: public-key\\n"' > "$work_dir/$server_name"
chmod +x "$work_dir/$server_name"
printf '%s\n' old-endpoint > "$conf_dir/warp/endpoint.json"
printf '%s\n' old-account > "$conf_dir/warp/account.json"
PAIR_MV_RESULTS=(0 1 1)
if generate_unique_warp_identity_real; then incomplete_pair_rc=0; else incomplete_pair_rc=$?; fi
[ "$incomplete_pair_rc" -eq 2 ] || fail "incomplete pair rollback returned ${incomplete_pair_rc}, expected 2"
[ "$DELETE_CALLS" -eq 0 ] || fail 'incomplete pair rollback deleted the possibly active new registration'
pair_transaction=$(find "$conf_dir/warp" -maxdepth 1 -type d -name '.identity-commit.*' -print -quit)
[ -n "$pair_transaction" ] || fail 'incomplete pair rollback discarded transaction recovery materials'
[ -s "$pair_transaction/old-endpoint.json" ] || fail 'incomplete pair rollback lost the old endpoint backup'
pair_register=$(find "$conf_dir/warp" -maxdepth 1 -type d -name '.register.*' -print -quit)
[ -n "$pair_register" ] || fail 'incomplete pair rollback discarded registration recovery materials'
[ -s "$pair_register/response.json" ] || fail 'incomplete pair rollback lost cloud registration credentials'

[[ "$rotate_block" != *WARP_KEEP_FAILED_CANDIDATE* ]] || fail 'rotate_warp_identity_once still exposes misleading WARP_KEEP_FAILED_CANDIDATE state'
[[ "$activation_block" != *WARP_KEEP_FAILED_CANDIDATE* ]] || fail 'activate_warp_candidate still exposes misleading WARP_KEEP_FAILED_CANDIDATE state'
! grep -q 'WARP_KEEP_FAILED_CANDIDATE' "$script" || fail 'sing-box.sh still contains misleading WARP_KEEP_FAILED_CANDIDATE state'

echo 'WARP rotation behavior tests passed.'
