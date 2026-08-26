#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

for function_name in \
    finish_transaction_release \
    get_listener_address \
    format_url_host \
    read_extra_protocol_ports \
    resolve_extra_protocol_listeners \
    resolve_extra_protocol_server_host \
    backup_extra_protocol_transaction \
    restore_extra_protocol_files \
    restore_extra_protocol_service_state \
    commit_extra_protocol_service_state \
    cleanup_extra_protocol_backup \
    handle_extra_protocol_transaction_failure \
    rollback_extra_protocol_signal_transaction \
    reset_durable_transaction_state \
    assert_no_pending_durable_transaction \
    write_durable_transaction_registry \
    cleanup_durable_transaction_registry \
    write_durable_transaction_manifest \
    restore_durable_transaction_traps \
    arm_durable_transaction \
    durable_transaction_checkpoint \
    durable_transaction_set_owned_records \
    durable_transaction_trap_handler \
    disarm_durable_transaction \
    extra_protocol_tag_exists \
    get_extra_protocol_uniform_port \
    with_subscription_lock \
    encode_subscription_source \
    read_strict_subscription_generation_file \
    get_base_subscription_generation_locked \
    select_cfy_subscription_source_locked \
    publish_subscriptions_locked \
    mutate_base_subscription_locked \
    mutate_base_subscription \
    remove_url_by_tag_file \
    remove_url_by_tag \
    acquire_proxy_transaction_lock_checked \
    _add_extra_protocol_transaction_locked \
    add_extra_protocol_transaction \
    _remove_extra_protocol_transaction_locked \
    remove_extra_protocol_transaction \
    mutate_socks5_inbound_add \
    mutate_anytls_inbound_add \
    mutate_ss2022_inbound_add \
    mutate_extra_protocol_inbound_remove; do
    function_source="$(extract_function "$function_name")"
    [ -n "$function_source" ] || fail "${function_name} is not implemented"
    source <(printf '%s\n' "$function_source")
done

for function_name in add_socks5_inbound add_anytls add_ss2022; do
    function_source="$(extract_function "$function_name")"
    grep -Fq 'add_extra_protocol_transaction' <<< "$function_source" || \
        fail "${function_name} bypasses the extra-protocol add transaction"
    grep -Fq 'resolve_extra_protocol_listeners' <<< "$function_source" || \
        fail "${function_name} bypasses listener-family resolution"
    grep -Fq 'resolve_extra_protocol_server_host' <<< "$function_source" || \
        fail "${function_name} can publish an unresolved server host"
    grep -Fq -- '--families' <<< "$function_source" || \
        fail "${function_name} does not scope firewall rules to its listener families"
    grep -Fq 'public_port' <<< "$function_source" || \
        fail "${function_name} does not separate its public NAT mapping port"
done
for function_name in remove_socks5_inbound remove_anytls remove_ss2022; do
    grep -Fq 'remove_extra_protocol_transaction' <<< "$(extract_function "$function_name")" || \
        fail "${function_name} bypasses the extra-protocol remove transaction"
done

work_dir="${tmp_root}/work"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
combined_client_dir="${work_dir}/all-url.txt"
inbounds_file="${conf_dir}/inbounds.json"
call_log="${tmp_root}/calls.log"
mkdir -p "$conf_dir"

SERVICE_ACTIVE=1
ALLOW_STATUS=0
UPDATE_FAILURES=0
UPDATE_STATUS=0
RESTART_FAILURES=0
RESTORE_SERVICE_FAIL=0
VALIDATE_FAILURES=0
REMOVE_EXACT_FAIL=0
REMOVE_PORTS_STATUS=0
CONFIG_CONFLICT_STATUS=1
LISTENER_OCCUPIED=0
NGINX_CONFLICT_STATUS=1
EXTRA_PROTOCOL_RECOVERY_PATH=''
LOCK_SET_CONFLICT=0
LOCK_SET_TAG_PRESENT=0
LOCK_SET_REMOVE_PORT=''
TAG_EXISTS_STATUS=1
CURRENT_EXTRA_PORT=24000
CURRENT_EXTRA_PORT_STATUS=0
MUTATION_STATUS=0
CLEANUP_BACKUP_STATUS=0
DURABLE_HOOK_LOG=0
DURABLE_HOOK_FAIL_STAGE=''

reset_fixture() {
    command rm -f -- "${conf_dir}/.durable-transaction.pending"
    find "$work_dir" -maxdepth 2 -type d -name '.durable-transaction.*' -exec rm -rf -- {} + 2>/dev/null || true
    printf 'old-config\n' > "$inbounds_file"
    printf 'old-client\n' > "$client_dir"
    : > "$call_log"
    SERVICE_ACTIVE=1
    ALLOW_STATUS=0
    UPDATE_FAILURES=0
    UPDATE_STATUS=0
    RESTART_FAILURES=0
    RESTORE_SERVICE_FAIL=0
    VALIDATE_FAILURES=0
    REMOVE_EXACT_FAIL=0
    REMOVE_PORTS_STATUS=0
    CONFIG_CONFLICT_STATUS=1
    LISTENER_OCCUPIED=0
    NGINX_CONFLICT_STATUS=1
    EXTRA_PROTOCOL_RECOVERY_PATH=''
    LOCK_SET_CONFLICT=0
    LOCK_SET_TAG_PRESENT=0
    LOCK_SET_REMOVE_PORT=''
    TAG_EXISTS_STATUS=1
    CURRENT_EXTRA_PORT=24000
    CURRENT_EXTRA_PORT_STATUS=0
    MUTATION_STATUS=0
    CLEANUP_BACKUP_STATUS=0
    DURABLE_HOOK_LOG=0
    DURABLE_HOOK_FAIL_STAGE=''
    FIREWALL_LAST_ADDED_RECORDS=()
    reset_durable_transaction_state
}

singbox_service_is_active() { [ "$SERVICE_ACTIVE" -eq 1 ]; }
allow_port() {
    printf 'allow:%s\n' "$*" >> "$call_log"
    [ "$ALLOW_STATUS" -eq 0 ] || return "$ALLOW_STATUS"
    FIREWALL_LAST_ADDED_RECORDS=('ufw|4|24000|tcp' 'ufw|4|24000|udp')
}
restart_singbox() {
    printf 'restart\n' >> "$call_log"
    if [ "$RESTART_FAILURES" -gt 0 ]; then
        RESTART_FAILURES=$((RESTART_FAILURES - 1))
        return 1
    fi
    SERVICE_ACTIVE=1
}
validate_installed_singbox_config_strict() {
    printf 'validate\n' >> "$call_log"
    if [ "$VALIDATE_FAILURES" -gt 0 ]; then
        VALIDATE_FAILURES=$((VALIDATE_FAILURES - 1))
        return 1
    fi
}
stop_singbox_checked() {
    printf 'stop\n' >> "$call_log"
    SERVICE_ACTIVE=0
}
update_sub() {
    printf 'subscription\n' >> "$call_log"
    if [ "$UPDATE_FAILURES" -gt 0 ]; then
        UPDATE_FAILURES=$((UPDATE_FAILURES - 1))
        return 1
    fi
    [ "$UPDATE_STATUS" -eq 0 ] || return "$UPDATE_STATUS"
}
append_base_subscription_url() {
    update_sub || return $?
    printf '\n%s\n' "$1" >> "$client_dir"
}
remove_owned_firewall_records_exact() {
    printf 'remove-exact:%s\n' "$*" >> "$call_log"
    [ "$REMOVE_EXACT_FAIL" -eq 0 ]
}
remove_owned_firewall_ports_if_unused() {
    printf 'remove-ports:%s\n' "$*" >> "$call_log"
    [ "$REMOVE_PORTS_STATUS" -eq 0 ] || return "$REMOVE_PORTS_STATUS"
}
configured_inbound_port_conflict_exists() {
    printf 'conflict:%s/%s\n' "$2" "$3" >> "$call_log"
    return "$CONFIG_CONFLICT_STATUS"
}
port_is_listening() {
    printf 'listen-check:%s/%s\n' "$1" "$2" >> "$call_log"
    [ "$LISTENER_OCCUPIED" -eq 1 ]
}
nginx_configured_port_conflict_exists() {
    printf 'nginx-conflict:%s/%s\n' "$2" "$3" >> "$call_log"
    return "$NGINX_CONFLICT_STATUS"
}
red() { :; }
acquire_proxy_transaction_lock() {
    printf 'lock\n' >> "$call_log"
    [ "$LOCK_SET_CONFLICT" -eq 0 ] || CONFIG_CONFLICT_STATUS=0
    [ "$LOCK_SET_TAG_PRESENT" -eq 0 ] || TAG_EXISTS_STATUS=0
    [ -z "$LOCK_SET_REMOVE_PORT" ] || CURRENT_EXTRA_PORT="$LOCK_SET_REMOVE_PORT"
}
release_proxy_transaction_lock() { printf 'unlock\n' >> "$call_log"; }
acquire_transaction_lock_with_legacy() { return 0; }
release_transaction_lock_with_legacy() { return 0; }
durable_transaction_hook() {
    [ "$DURABLE_HOOK_LOG" -ne 1 ] || printf 'durable:%s\n' "$1" >> "$call_log"
    [ -z "$DURABLE_HOOK_FAIL_STAGE" ] || [ "$1" != "$DURABLE_HOOK_FAIL_STAGE" ]
}
validate_port_value() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
cleanup_extra_protocol_backup() {
    [ "$CLEANUP_BACKUP_STATUS" -eq 0 ] || return "$CLEANUP_BACKUP_STATUS"
    command rm -rf -- "$1"
}

# The outer config/firewall transaction owns only inbounds.json. Subscription
# publication has its own canonical lock and atomic rollback, so restoring an
# outer snapshot must not overwrite a newer base/served/cfy-sub generation.
reset_fixture
subscription_files=(
    "$client_dir"
    "${work_dir}/base-sub.txt"
    "$combined_client_dir"
    "${work_dir}/all-sub.txt"
    "${work_dir}/sub.txt"
    "${work_dir}/cfy-sub.txt"
)
for subscription_file in "${subscription_files[@]}"; do
    printf '%s\n' outer-old-generation > "$subscription_file"
done
backup_extra_protocol_transaction "$inbounds_file" || \
    fail 'could not create extra-protocol ownership backup'
ownership_backup="$EXTRA_PROTOCOL_BACKUP_DIR"
printf '%s\n' changed-config > "$inbounds_file"
for subscription_file in "${subscription_files[@]}"; do
    printf '%s\n' concurrent-publisher-generation > "$subscription_file"
done
restore_extra_protocol_files "$ownership_backup" "$inbounds_file" || \
    fail 'could not restore extra-protocol ownership backup'
[ "$(<"$inbounds_file")" = old-config ] || \
    fail 'extra-protocol rollback did not restore its owned inbounds config'
for subscription_file in "${subscription_files[@]}"; do
    [ "$(<"$subscription_file")" = concurrent-publisher-generation ] || \
        fail "extra-protocol rollback overwrote concurrent subscription state: ${subscription_file}"
done
command rm -rf -- "$ownership_backup"

# Exercise the production tag/port readers before replacing them with
# transaction-order mocks below.
helper_inbounds="${tmp_root}/helper-inbounds.json"
printf '%s\n' '{"inbounds":[]}' > "$helper_inbounds"
if extra_protocol_tag_exists "$helper_inbounds" socks-tag; then
    fail 'missing extra-protocol tag was reported present'
elif [ "$?" -ne 1 ]; then
    fail 'missing extra-protocol tag was not a clean rc 1'
fi
printf '%s\n' '{"inbounds":[{"tag":"socks-tag","listen_port":24000},{"tag":"socks-tag-ipv6","listen_port":24000}]}' > "$helper_inbounds"
extra_protocol_tag_exists "$helper_inbounds" socks-tag || fail 'existing base/twin tags were not found'
[ "$(get_extra_protocol_uniform_port "$helper_inbounds" socks-tag)" = 24000 ] || \
    fail 'uniform base/twin port was not read'
printf '%s\n' '{"inbounds":[{"tag":"socks-tag","listen_port":24000},{"tag":"socks-tag-ipv6","listen_port":25000}]}' > "$helper_inbounds"
if get_extra_protocol_uniform_port "$helper_inbounds" socks-tag >/dev/null; then
    fail 'inconsistent base/twin ports were accepted'
elif [ "$?" -ne 2 ]; then
    fail 'inconsistent base/twin ports were not a fatal rc 2'
fi
printf '%s\n' '{broken' > "$helper_inbounds"
if extra_protocol_tag_exists "$helper_inbounds" socks-tag; then
    fail 'damaged inbounds JSON was accepted by tag lookup'
elif [ "$?" -ne 2 ]; then
    fail 'damaged inbounds JSON was not a fatal rc 2'
fi

cat > "$client_dir" <<'URLS'
socks://first


anytls://second
ss://third
vless://keep
socks://fourth

URLS
remove_url_by_tag socks || fail 'production URL removal helper failed'
expected_urls=$'anytls://second\nss://third\nvless://keep\n'
[ "$(cat "$client_dir"; printf x)" = "${expected_urls}x" ] || \
    fail 'production URL removal did not remove only the requested scheme and normalize blanks'
before_invalid="$(cat "$client_dir")"
if remove_url_by_tag 'socks|.*'; then
    fail 'unsafe URL scheme was accepted'
fi
[ "$(cat "$client_dir")" = "$before_invalid" ] || fail 'unsafe scheme changed the client file'

extra_protocol_tag_exists() {
    printf 'tag-check:%s\n' "$2" >> "$call_log"
    return "$TAG_EXISTS_STATUS"
}
get_extra_protocol_uniform_port() {
    printf 'port-read:%s\n' "$2" >> "$call_log"
    [ "$CURRENT_EXTRA_PORT_STATUS" -eq 0 ] || return "$CURRENT_EXTRA_PORT_STATUS"
    printf '%s\n' "$CURRENT_EXTRA_PORT"
}

mutation_add() {
    local target_file="$1"
    shift
    printf 'mutate-add:%s\n' "$*" >> "$call_log"
    printf 'new-config:%s\n' "$*" > "$target_file"
    [ "$MUTATION_STATUS" -eq 0 ] || return "$MUTATION_STATUS"
}
mutation_remove() {
    local target_file="$1"
    shift
    printf 'mutate-remove:%s\n' "$*" >> "$call_log"
    printf 'removed-config:%s\n' "$*" > "$target_file"
}
remove_url_by_tag() {
    printf 'remove-url:%s\n' "$1" >> "$call_log"
    update_sub || return $?
    printf 'client-without:%s\n' "$1" > "$client_dir"
}

apply_jq_config() {
    local target_file="$1"
    shift
    local tmp_file="${target_file}.tmp"
    jq "$@" "$target_file" > "$tmp_file" || return 1
    mv -f "$tmp_file" "$target_file"
}

HAS_IPV4=1
HAS_IPV6=1
BINDV6ONLY=0
REALIP_VALUE='198.51.100.10'
REALIP_STATUS=0
purple=''
green=''
re=''
PORT_INPUTS=()
PORT_INPUT_INDEX=0
reading() {
    local _prompt="$1" target_name="$2"
    printf -v "$target_name" '%s' "${PORT_INPUTS[$PORT_INPUT_INDEX]:-}"
    PORT_INPUT_INDEX=$((PORT_INPUT_INDEX + 1))
}
green() { :; }
yellow() { :; }
shuf() { printf '%s\n' 24000; }
ipv4_stack_available() { [ "$HAS_IPV4" -eq 1 ]; }
ipv6_stack_available() { [ "$HAS_IPV6" -eq 1 ]; }
get_bindv6only() { printf '%s\n' "$BINDV6ONLY"; }
get_realip() {
    [ "$REALIP_STATUS" -eq 0 ] || return "$REALIP_STATUS"
    printf '%s\n' "$REALIP_VALUE"
}

PORT_INPUTS=(24000 25000)
PORT_INPUT_INDEX=0
read_extra_protocol_ports Socks5 || fail 'NAT port split input was rejected'
[ "$EXTRA_PROTOCOL_LISTEN_PORT,$EXTRA_PROTOCOL_PUBLIC_PORT" = '24000,25000' ] || \
    fail 'NAT public port was not kept separate from listen port'
PORT_INPUTS=(24000 '')
PORT_INPUT_INDEX=0
read_extra_protocol_ports AnyTLS || fail 'default public port input was rejected'
[ "$EXTRA_PROTOCOL_LISTEN_PORT,$EXTRA_PROTOCOL_PUBLIC_PORT" = '24000,24000' ] || \
    fail 'empty public port did not default to the listen port'

HAS_IPV4=1
HAS_IPV6=0
BINDV6ONLY=0
resolve_extra_protocol_listeners || fail 'IPv4-only listener resolution failed'
[ "$EXTRA_PROTOCOL_HAS_IPV4,$EXTRA_PROTOCOL_HAS_IPV6" = '1,0' ] || \
    fail 'IPv4-only family flags are incorrect'
[ "${EXTRA_PROTOCOL_LISTENERS[*]}" = '0.0.0.0' ] || \
    fail 'IPv4-only extra protocol did not bind 0.0.0.0'

HAS_IPV4=1
HAS_IPV6=1
BINDV6ONLY=1
resolve_extra_protocol_listeners || fail 'bindv6only dual-stack listener resolution failed'
[ "$EXTRA_PROTOCOL_HAS_IPV4,$EXTRA_PROTOCOL_HAS_IPV6" = '1,1' ] || \
    fail 'dual-stack family flags are incorrect'
[ "${EXTRA_PROTOCOL_LISTENERS[*]}" = '0.0.0.0 ::' ] || \
    fail 'bindv6only dual-stack extra protocol did not create both listeners'

REALIP_STATUS=1
if resolve_extra_protocol_server_host; then
    fail 'real-IP lookup failure produced a publishable host'
fi
REALIP_STATUS=0
REALIP_VALUE=''
if resolve_extra_protocol_server_host; then
    fail 'empty real-IP lookup produced a publishable host'
fi
REALIP_VALUE='2001:db8::10'
resolve_extra_protocol_server_host || fail 'valid IPv6 server host was rejected'
[ "$EXTRA_PROTOCOL_SERVER_HOST" = '[2001:db8::10]' ] || \
    fail 'IPv6 server host was not bracketed for publication'

printf '%s\n' '{"inbounds":[]}' > "$inbounds_file"
mutate_socks5_inbound_add "$inbounds_file" socks5-in 24000 user pass 0.0.0.0 '' || \
    fail 'IPv4-only Socks5 inbound mutation failed'
[ "$(jq -r '.inbounds | length' "$inbounds_file")" -eq 1 ] || \
    fail 'IPv4-only Socks5 mutation created the wrong inbound count'
[ "$(jq -r '.inbounds[0].listen' "$inbounds_file")" = 0.0.0.0 ] || \
    fail 'IPv4-only Socks5 mutation retained an IPv6 wildcard listener'

printf '%s\n' '{"inbounds":[]}' > "$inbounds_file"
mutate_anytls_inbound_add "$inbounds_file" anytls 24001 pass cert key 0.0.0.0 :: || \
    fail 'bindv6only AnyTLS inbound mutation failed'
[ "$(jq -r '.inbounds | length' "$inbounds_file")" -eq 2 ] || \
    fail 'bindv6only AnyTLS mutation did not create both family listeners'
[ "$(jq -r '[.inbounds[].listen] | join(",")' "$inbounds_file")" = '0.0.0.0,::' ] || \
    fail 'bindv6only AnyTLS mutation created incorrect listeners'
[ "$(jq -r '[.inbounds[].tag] | join(",")' "$inbounds_file")" = 'anytls,anytls-ipv6' ] || \
    fail 'bindv6only AnyTLS mutation did not create unique family tags'
mutate_extra_protocol_inbound_remove "$inbounds_file" anytls || \
    fail 'bindv6only AnyTLS twin removal failed'
[ "$(jq -r '.inbounds | length' "$inbounds_file")" -eq 0 ] || \
    fail 'bindv6only AnyTLS twin removal left an IPv6 tag behind'

reset_fixture
add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag || fail 'add transaction did not commit'
expected_add=$'lock\ntag-check:socks-tag\nconflict:24000/tcp\nnginx-conflict:24000/tcp\nlisten-check:24000/tcp\nconflict:24000/udp\nlisten-check:24000/udp\nallow:--families 1 1 24000/tcp 24000/udp\nmutate-add:socks-tag\nvalidate\nrestart\nsubscription\nunlock'
[ "$(cat "$call_log")" = "$expected_add" ] || fail 'add transaction order is unsafe'
grep -Fxq 'new-client' "$client_dir" || fail 'add transaction did not publish the client line'

reset_fixture
DURABLE_HOOK_LOG=1
add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag || \
    fail 'durable extra-protocol add did not commit'
durable_stages="$(grep '^durable:' "$call_log")"
[ "$durable_stages" = $'durable:firewall-mutating\ndurable:precommit\ndurable:config-mutated\ndurable:publishing\ndurable:committed' ] || \
    fail "extra-protocol durable checkpoints are incomplete or unsafe: ${durable_stages}"

reset_fixture
DURABLE_HOOK_FAIL_STAGE=committed
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    committed_checkpoint_status=0
else
    committed_checkpoint_status=$?
fi
[ "$committed_checkpoint_status" -eq 2 ] || \
    fail "post-publish committed checkpoint failure returned ${committed_checkpoint_status} instead of 2"
grep -Fxq 'new-client' "$client_dir" || \
    fail 'post-publish committed checkpoint failure rolled back the committed subscription'
grep -Fxq 'new-config:socks-tag' "$inbounds_file" || \
    fail 'post-publish committed checkpoint failure rolled back the committed config'

reset_fixture
LOCK_SET_TAG_PRESENT=1
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 25000/tcp 25000/udp -- socks-tag; then
    fail 'same tag added again after it appeared while waiting for the config lock'
fi
[ "$(head -n 2 "$call_log")" = $'lock\ntag-check:socks-tag' ] || \
    fail 'tag absence was not revalidated inside the config lock'
if grep -Eq '^(conflict|allow|mutate-add):' "$call_log"; then
    fail 'duplicate-tag rejection happened after live mutation'
fi

reset_fixture
LOCK_SET_CONFLICT=1
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    fail 'lock-time extra-protocol conflict was accepted'
fi
[ "$(head -n 3 "$call_log")" = $'lock\ntag-check:socks-tag\nconflict:24000/tcp' ] || \
    fail 'extra-protocol conflict precheck did not run under the config lock'
grep -Fxq 'unlock' "$call_log" || fail 'config lock was not released after precheck rejection'

reset_fixture
NGINX_CONFLICT_STATUS=0
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    fail 'inactive Nginx TCP config conflict was accepted by extra protocol add'
fi
if grep -q '^allow:' "$call_log"; then
    fail 'firewall changed after inactive Nginx TCP config conflict'
fi

reset_fixture
NGINX_CONFLICT_STATUS=2
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    nginx_conflict_status=0
else
    nginx_conflict_status=$?
fi
[ "$nginx_conflict_status" -eq 2 ] || fail 'Nginx config query error was downgraded'

reset_fixture
SERVICE_ACTIVE=0
add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag || \
    fail 'inactive-service add transaction did not commit'
[ "$SERVICE_ACTIVE" -eq 0 ] || fail 'successful add started an initially inactive sing-box service'
if grep -q '^restart$' "$call_log"; then
    fail 'successful inactive-service add restarted sing-box'
fi
grep -Fxq 'validate' "$call_log" || fail 'inactive-service add skipped config validation'

reset_fixture
SERVICE_ACTIVE=0
UPDATE_FAILURES=1
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    fail 'inactive-service subscription failure was reported as success'
fi
[ "$SERVICE_ACTIVE" -eq 0 ] || fail 'inactive-service rollback started sing-box'
[ "$(<"$inbounds_file")" = old-config ] || fail 'inactive-service rollback did not restore config'
[ "$(<"$client_dir")" = old-client ] || fail 'inactive-service rollback did not restore client'

reset_fixture
VALIDATE_FAILURES=1
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    fail 'strict config validation failure was reported as successful add'
fi
if grep -Eq '^(restart|subscription)$' "$call_log"; then
    fail 'strict config validation failure restarted or published the service'
fi
[ "$(<"$inbounds_file")" = old-config ] || fail 'strict validation failure did not restore config'
[ "$(<"$client_dir")" = old-client ] || fail 'strict validation failure did not restore client'

reset_fixture
CONFIG_CONFLICT_STATUS=0
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    fail 'configured but inactive extra-protocol port conflict was accepted'
fi
if grep -q '^allow:' "$call_log"; then
    fail 'firewall changed after configured extra-protocol conflict'
fi

reset_fixture
CONFIG_CONFLICT_STATUS=2
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    conflict_status=0
else
    conflict_status=$?
fi
[ "$conflict_status" -eq 2 ] || fail 'extra-protocol conflict query error was downgraded'

reset_fixture
LISTENER_OCCUPIED=1
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    fail 'live extra-protocol listener conflict was accepted'
fi
if grep -q '^allow:' "$call_log"; then
    fail 'firewall changed after live extra-protocol listener conflict'
fi

reset_fixture
ALLOW_STATUS=2
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    add_status=0
else
    add_status=$?
fi
[ "$add_status" -eq 2 ] || fail 'fatal allow status was not propagated by add transaction'
[ "$(<"$inbounds_file")" = old-config ] || fail 'config changed after firewall failure'
[ -d "$EXTRA_PROTOCOL_RECOVERY_PATH" ] || fail 'fatal allow did not preserve a recovery backup path'
if grep -q '^mutate-add:' "$call_log"; then
    fail 'config mutation ran after firewall failure'
fi

reset_fixture
ALLOW_STATUS=1
CLEANUP_BACKUP_STATUS=1
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    cleanup_status=0
else
    cleanup_status=$?
fi
[ "$cleanup_status" -eq 2 ] || fail 'failed add with uncleared backup was not reported unresolved'
[ -d "$EXTRA_PROTOCOL_RECOVERY_PATH" ] || fail 'failed add cleanup did not expose its backup path'

reset_fixture
UPDATE_FAILURES=1
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    fail 'subscription failure was reported as successful add'
fi
[ "$(<"$inbounds_file")" = old-config ] || fail 'failed add did not restore config'
[ "$(<"$client_dir")" = old-client ] || fail 'failed add did not restore client'
grep -Fq 'remove-exact:ufw|4|24000|tcp ufw|4|24000|udp' "$call_log" || \
    fail 'failed add leaked new firewall ownership records'

reset_fixture
UPDATE_STATUS=2
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    add_status=0
else
    add_status=$?
fi
[ "$add_status" -eq 2 ] || \
    fail "unresolved subscription publisher status was downgraded to rc ${add_status} during add"

reset_fixture
UPDATE_STATUS=3
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    add_status=0
else
    add_status=$?
fi
[ "$add_status" -eq 3 ] || fail 'subscription generation conflict was downgraded during add rollback'
[ "$(<"$inbounds_file")" = old-config ] || fail 'generation-conflict add did not restore config'
[ "$(<"$client_dir")" = old-client ] || fail 'generation-conflict add did not restore client'

reset_fixture
MUTATION_STATUS=2
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    fail 'fatal mutation was reported as successful add'
else
    add_status=$?
fi
[ "$add_status" -eq 1 ] || fail 'fully rolled-back fatal mutation was not normalized to rc 1'
[ "$(<"$inbounds_file")" = old-config ] || fail 'fatal mutation rollback did not restore config'
[ -z "$EXTRA_PROTOCOL_RECOVERY_PATH" ] || fail 'complete mutation rollback retained a false recovery path'

reset_fixture
CLEANUP_BACKUP_STATUS=1
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    cleanup_status=0
else
    cleanup_status=$?
fi
[ "$cleanup_status" -eq 3 ] || fail 'healthy add with only backup residue did not return rc 3'
[ -d "$EXTRA_PROTOCOL_RECOVERY_PATH" ] || fail 'healthy add cleanup residue did not expose its path'
grep -Fxq 'new-client' "$client_dir" || fail 'backup residue incorrectly rolled back a healthy add'

reset_fixture
UPDATE_FAILURES=1
REMOVE_EXACT_FAIL=1
if add_extra_protocol_transaction "$inbounds_file" 'new-client' mutation_add \
    --families 1 1 24000/tcp 24000/udp -- socks-tag; then
    fatal_status=0
else
    fatal_status=$?
fi
[ "$fatal_status" -eq 2 ] || fail 'incomplete add rollback did not return status 2'
[ -d "$EXTRA_PROTOCOL_RECOVERY_PATH" ] || fail 'incomplete add rollback did not preserve recovery backup'

reset_fixture
printf 'new-config:socks-tag\n' > "$inbounds_file"
printf 'old-client\nnew-client\n' > "$client_dir"
remove_extra_protocol_transaction "$inbounds_file" socks mutation_remove \
    24000/tcp 24000/udp -- socks-tag || fail 'remove transaction did not commit'
expected_remove=$'lock\nport-read:socks-tag\nmutate-remove:socks-tag\nvalidate\nrestart\nremove-url:socks\nsubscription\nremove-ports:'"${inbounds_file} 24000/tcp 24000/udp"$'\nunlock'
[ "$(cat "$call_log")" = "$expected_remove" ] || fail 'remove transaction order is unsafe'

reset_fixture
printf 'new-config:socks-tag\n' > "$inbounds_file"
printf 'old-client\nnew-client\n' > "$client_dir"
LOCK_SET_REMOVE_PORT=25000
remove_extra_protocol_transaction "$inbounds_file" socks mutation_remove \
    24000/tcp 24000/udp -- socks-tag || \
    fail 'remove transaction rejected a valid lock-time port refresh'
grep -Fqx "remove-ports:${inbounds_file} 25000/tcp 25000/udp" "$call_log" || \
    fail 'remove transaction cleaned stale pre-lock firewall ports'
if grep -Fq "remove-ports:${inbounds_file} 24000/tcp 24000/udp" "$call_log"; then
    fail 'remove transaction retained stale pre-lock firewall ports'
fi

reset_fixture
SERVICE_ACTIVE=0
printf 'new-config:socks-tag\n' > "$inbounds_file"
printf 'old-client\nnew-client\n' > "$client_dir"
remove_extra_protocol_transaction "$inbounds_file" socks mutation_remove \
    24000/tcp 24000/udp -- socks-tag || \
    fail 'inactive-service remove transaction did not commit'
[ "$SERVICE_ACTIVE" -eq 0 ] || fail 'successful remove started an initially inactive sing-box service'
if grep -q '^restart$' "$call_log"; then
    fail 'successful inactive-service remove restarted sing-box'
fi
grep -Fxq 'validate' "$call_log" || fail 'inactive-service remove skipped config validation'

reset_fixture
printf 'new-config:socks-tag\n' > "$inbounds_file"
printf 'old-client\nnew-client\n' > "$client_dir"
before_config="$(<"$inbounds_file")"
before_client="$(<"$client_dir")"
UPDATE_FAILURES=1
if remove_extra_protocol_transaction "$inbounds_file" socks mutation_remove \
    24000/tcp 24000/udp -- socks-tag; then
    fail 'subscription failure was reported as successful remove'
fi
[ "$(<"$inbounds_file")" = "$before_config" ] || fail 'failed remove did not restore config'
[ "$(<"$client_dir")" = "$before_client" ] || fail 'failed remove did not restore client'
if grep -q '^remove-ports:' "$call_log"; then
    fail 'firewall cleanup ran before config/subscription remove committed'
fi

reset_fixture
printf 'new-config:socks-tag\n' > "$inbounds_file"
printf 'old-client\nnew-client\n' > "$client_dir"
UPDATE_STATUS=2
if remove_extra_protocol_transaction "$inbounds_file" socks mutation_remove \
    24000/tcp 24000/udp -- socks-tag; then
    remove_status=0
else
    remove_status=$?
fi
[ "$remove_status" -eq 2 ] || \
    fail "unresolved subscription publisher status was downgraded to rc ${remove_status} during remove"

reset_fixture
printf 'new-config:socks-tag\n' > "$inbounds_file"
printf 'old-client\nnew-client\n' > "$client_dir"
before_config="$(<"$inbounds_file")"
before_client="$(<"$client_dir")"
UPDATE_STATUS=3
if remove_extra_protocol_transaction "$inbounds_file" socks mutation_remove \
    24000/tcp 24000/udp -- socks-tag; then
    remove_status=0
else
    remove_status=$?
fi
[ "$remove_status" -eq 3 ] || fail 'subscription generation conflict was downgraded during remove rollback'
[ "$(<"$inbounds_file")" = "$before_config" ] || fail 'generation-conflict remove did not restore config'
[ "$(<"$client_dir")" = "$before_client" ] || fail 'generation-conflict remove did not restore client'

reset_fixture
printf 'new-config:socks-tag\n' > "$inbounds_file"
printf 'old-client\nnew-client\n' > "$client_dir"
REMOVE_PORTS_STATUS=1
if remove_extra_protocol_transaction "$inbounds_file" socks mutation_remove \
    24000/tcp 24000/udp -- socks-tag; then
    remove_cleanup_status=0
else
    remove_cleanup_status=$?
fi
[ "$remove_cleanup_status" -eq 3 ] || \
    fail "clean firewall residue returned ${remove_cleanup_status} instead of committed rc 3"
[ -d "$EXTRA_PROTOCOL_RECOVERY_PATH" ] || \
    fail 'committed firewall cleanup rc 1 discarded durable recovery evidence'
[ -f "${conf_dir}/.durable-transaction.pending" ] && \
    [ "$(<"${conf_dir}/.durable-transaction.pending")" = "$EXTRA_PROTOCOL_RECOVERY_PATH" ] || \
    fail 'committed firewall cleanup rc 1 discarded its pending durable registry'
grep -Fxq 'stage=firewall-mutating' "$EXTRA_PROTOCOL_RECOVERY_PATH/manifest" || \
    fail 'committed firewall cleanup rc 1 lost its cleanup-stage manifest'
grep -Fxq 'removed-config:socks-tag' "$inbounds_file" || \
    fail 'clean firewall residue rolled back the committed config removal'
grep -Fxq 'client-without:socks' "$client_dir" || \
    fail 'clean firewall residue rolled back the committed subscription removal'

reset_fixture
printf 'new-config:socks-tag\n' > "$inbounds_file"
printf 'old-client\nnew-client\n' > "$client_dir"
REMOVE_PORTS_STATUS=2
REMOVE_EXACT_FAIL=1
if remove_extra_protocol_transaction "$inbounds_file" socks mutation_remove \
    24000/tcp 24000/udp -- socks-tag; then
    fatal_status=0
else
    fatal_status=$?
fi
[ "$fatal_status" -eq 2 ] || fail 'fatal firewall cleanup was downgraded during remove rollback'
[ -d "$EXTRA_PROTOCOL_RECOVERY_PATH" ] || fail 'fatal remove did not preserve recovery backup'
grep -Fxq 'removed-config:socks-tag' "$inbounds_file" || \
    fail 'uncertain post-publish firewall cleanup rolled back the committed config removal'
grep -Fxq 'client-without:socks' "$client_dir" || \
    fail 'uncertain post-publish firewall cleanup rolled back the committed subscription removal'

reset_fixture
printf 'new-config:socks-tag\n' > "$inbounds_file"
printf 'old-client\nnew-client\n' > "$client_dir"
CLEANUP_BACKUP_STATUS=1
if remove_extra_protocol_transaction "$inbounds_file" socks mutation_remove \
    24000/tcp 24000/udp -- socks-tag; then
    cleanup_status=0
else
    cleanup_status=$?
fi
[ "$cleanup_status" -eq 3 ] || fail 'healthy remove with only backup residue did not return rc 3'
[ -d "$EXTRA_PROTOCOL_RECOVERY_PATH" ] || fail 'healthy remove cleanup residue did not expose its path'
grep -Fxq 'removed-config:socks-tag' "$inbounds_file" || \
    fail 'remove backup cleanup residue rolled back the committed config removal'
grep -Fxq 'client-without:socks' "$client_dir" || \
    fail 'remove backup cleanup residue rolled back the committed subscription removal'

# One real interactive wrapper path: NAT maps public 25000 to local 24000.
# The generated inbound/firewall use 24000, publication uses 25000, and remove
# cleans ownership for 24000.
source <(printf '%s\n' "$(extract_function add_socks5_inbound)")
source <(printf '%s\n' "$(extract_function remove_socks5_inbound)")
proto_exists() {
    jq -e --arg tag "$1" '.inbounds[] | select(.tag == $tag)' "$inbounds_file" >/dev/null 2>&1
}
get_current_uuid() { printf '%s\n' '12345678-1234-1234-1234-123456789abc'; }
curl() { printf '%s\n' '{"country_code":"US","isp":"Example"}'; }
render_terminal_qr() { :; }
sleep() { :; }
reset_fixture
printf '%s\n' '{"inbounds":[]}' > "$inbounds_file"
SERVICE_ACTIVE=0
HAS_IPV4=1
HAS_IPV6=1
BINDV6ONLY=0
REALIP_VALUE='198.51.100.10'
PORT_INPUTS=(24000 25000 natuser natpass)
PORT_INPUT_INDEX=0
add_socks5_inbound || fail 'real Socks5 NAT wrapper add failed'
[ "$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .listen_port' "$inbounds_file")" = 24000 ] || \
    fail 'real NAT wrapper configured the public port as its listener'
grep -Fq '@198.51.100.10:25000#' "$client_dir" || \
    fail 'real NAT wrapper did not publish the mapped public port'
grep -Fq 'allow:--families 1 1 24000/tcp 24000/udp' "$call_log" || \
    fail 'real NAT wrapper did not open the local listener port'
: > "$call_log"
CURRENT_EXTRA_PORT=24000
remove_socks5_inbound || fail 'real Socks5 NAT wrapper remove failed'
grep -Fq "remove-ports:${inbounds_file} 24000/tcp 24000/udp" "$call_log" || \
    fail 'real NAT wrapper remove did not clean the local listener port'

printf 'Extra protocol transaction tests passed.\n'
