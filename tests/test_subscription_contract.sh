#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_root="$(mktemp -d)"
original_path="$PATH"
real_flock="$(type -P flock 2>/dev/null || true)"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

load_function() {
    local source
    source="$(extract_function "$1")"
    [[ -n "$source" ]] || fail "$1 is not implemented"
    source /dev/stdin <<< "$source"
}

for function_name in \
    command_exists \
    transaction_root_path \
    transaction_expected_dir_mode \
    transaction_expected_file_mode \
    transaction_expected_gid \
    validate_transaction_path_components \
    validate_transaction_directory \
    ensure_transaction_directory \
    validate_transaction_regular_file \
    ensure_transaction_regular_file \
    write_transaction_schema_file \
    ensure_stable_transaction_root \
    stable_transaction_lock_path \
    stable_transaction_lock_rank \
    stable_transaction_lock_is_held \
    stable_transaction_highest_rank \
    stable_transaction_lock_hook \
    legacy_transaction_lock_hook \
    reset_stable_transaction_lock_state \
    acquire_stable_transaction_lock \
    release_stable_transaction_lock \
    with_stable_transaction_lock \
    validate_safe_legacy_lock \
    acquire_safe_legacy_lock \
    release_safe_legacy_lock \
    acquire_transaction_lock_with_legacy \
    release_transaction_lock_with_legacy \
    with_transaction_lock_with_legacy \
    with_subscription_lock \
    encode_subscription_source \
    read_strict_subscription_generation_file \
    select_cfy_subscription_source_locked \
    publish_subscriptions_locked \
    mutate_base_subscription_locked \
    mutate_base_subscription \
    get_base_subscription_generation_locked \
    get_base_subscription_generation \
    publish_tracked_argo_transition_subscription_locked \
    restore_argo_transition_subscription_locked \
    restore_argo_transition_subscription \
    verify_base_subscription_generation_locked \
    publish_generated_base_locked \
    publish_generated_base \
    stage_hy2_client_file \
    update_subscription_uuid_file \
    update_vless_argo_domain_file \
    append_base_subscription_url_file \
    append_base_subscription_url \
    remove_url_by_tag \
    update_sub \
    get_info; do
    load_function "$function_name"
done

work_dir="${tmp_root}/sing-box"
SING_BOX_TRANSACTION_ROOT="${tmp_root}/transactions"
client_dir="${work_dir}/url.txt"
combined_client_dir="${work_dir}/all-url.txt"
CFY_SOURCE_GENERATION_FILE="${work_dir}/cfy-source.generation"
mkdir -p "$work_dir"
: > "${work_dir}/.subscription.lock"
chmod 600 "${work_dir}/.subscription.lock"

printf '%s\n' \
    'vless://base-a' \
    'vless://shared' \
    'vless://same-fields#one' > "$client_dir"
printf '%s\r\n' \
    'vless://shared' \
    'vless://cfy-b' \
    'vless://same-fields#two' \
    'vless://cfy-b' > "${work_dir}/cfy-url.txt"
chmod 600 "${work_dir}/cfy-url.txt"
initial_base_digest="$(sha256sum "$client_dir")"
initial_base_digest="${initial_base_digest%%[[:space:]]*}"
initial_base_bytes="$(wc -c < "$client_dir")"
initial_base_bytes="${initial_base_bytes//[[:space:]]/}"
printf '%s:%s\n' "$initial_base_digest" "$initial_base_bytes" > "$CFY_SOURCE_GENERATION_FILE"
chmod 600 "$CFY_SOURCE_GENERATION_FILE"
cfy_source_checksum="$(cksum < "${work_dir}/cfy-url.txt")"
cfy_generation_checksum="$(cksum < "$CFY_SOURCE_GENERATION_FILE")"

# The functional publication checks use a harmless lock shim. A real
# cross-process exclusion check runs below whenever util-linux flock exists.
flock() { return 0; }

update_sub || fail 'subscription publication failed'

expected=$'vless://base-a\nvless://shared\nvless://same-fields#one\nvless://cfy-b\nvless://same-fields#two'
actual="$(cat "$combined_client_dir")"
[[ "$actual" == "$expected" ]] || fail 'combined URLs were not deduplicated in first-seen order'
cmp -s "$combined_client_dir" <(base64 -d "${work_dir}/all-sub.txt") || \
    fail 'all-sub.txt was not generated from all-url.txt'
cmp -s "$combined_client_dir" <(base64 -d "${work_dir}/sub.txt") || \
    fail 'served sub.txt was not generated from all-url.txt'
[[ "$(cksum < "${work_dir}/cfy-url.txt")" == "$cfy_source_checksum" ]] || \
    fail 'Sing-box rewrote the cfy-owned source file'
[[ "$(cksum < "$CFY_SOURCE_GENERATION_FILE")" == "$cfy_generation_checksum" ]] || \
    fail 'Sing-box rewrote the cfy-owned source-generation sidecar'
[[ -f "${work_dir}/.subscription.lock" ]] || fail 'the canonical subscription lock was not used'

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
        for internal in url.txt base-sub.txt cfy-url.txt cfy-source.generation cfy-sub.txt all-url.txt all-sub.txt; do
            [[ "$(stat -c '%a' "${work_dir}/${internal}")" == 600 ]] || \
                fail "${internal} is not mode 600"
        done
        [[ "$(stat -c '%a' "${work_dir}/sub.txt")" == 644 ]] || fail 'sub.txt is not mode 644'
        [[ "$(stat -c '%a' "${work_dir}/.subscription.lock")" == 600 ]] || \
            fail 'subscription lock is not mode 600'
        ;;
esac

assert_base_only_publication() {
    local expected_base="$1"

    [[ "$(cat "$combined_client_dir")" == "$expected_base" ]] || \
        fail 'an untrusted cfy generation leaked into all-url.txt'
    [[ "$(base64 -d "${work_dir}/sub.txt")" == "$expected_base" ]] || \
        fail 'an untrusted cfy generation leaked into the served subscription'
    [[ "$(cksum < "${work_dir}/cfy-url.txt")" == "$cfy_source_checksum" ]] || \
        fail 'Sing-box changed cfy-url.txt while ignoring an untrusted generation'
}

printf '%s\n' 'vless://base-after-generation-change' > "$client_dir"
update_sub || fail 'base mutation with stale cfy metadata did not publish safely'
assert_base_only_publication 'vless://base-after-generation-change'
[[ "$(cksum < "$CFY_SOURCE_GENERATION_FILE")" == "$cfy_generation_checksum" ]] || \
    fail 'Sing-box changed the stale cfy generation sidecar'

rm -f "$CFY_SOURCE_GENERATION_FILE"
update_sub || fail 'missing cfy generation sidecar did not degrade to base-only publication'
assert_base_only_publication 'vless://base-after-generation-change'

printf '%s\n' 'not-a-generation' > "$CFY_SOURCE_GENERATION_FILE"
chmod 600 "$CFY_SOURCE_GENERATION_FILE"
update_sub || fail 'malformed cfy generation sidecar did not degrade to base-only publication'
assert_base_only_publication 'vless://base-after-generation-change'

current_base_generation="$(get_base_subscription_generation)" || fail 'could not fingerprint the current base'
[[ "$current_base_generation" =~ ^[0-9a-f]{64}:[0-9]+$ ]] || \
    fail 'Sing-box base generation is not canonical digest:bytes'
printf '%s\n' "$current_base_generation" > "$CFY_SOURCE_GENERATION_FILE"
chmod 644 "$CFY_SOURCE_GENERATION_FILE"
generation_mode_checksum="$(cksum < "$CFY_SOURCE_GENERATION_FILE")"
update_sub || fail 'wrong-mode cfy generation sidecar did not degrade safely'
assert_base_only_publication 'vless://base-after-generation-change'
[[ "$(stat -c '%a' "$CFY_SOURCE_GENERATION_FILE")" == 644 ]] || \
    fail 'Sing-box changed the mode of the cfy-owned generation sidecar'
[[ "$(cksum < "$CFY_SOURCE_GENERATION_FILE")" == "$generation_mode_checksum" ]] || \
    fail 'Sing-box changed a wrong-mode cfy generation sidecar'

generation_target="${work_dir}/generation-target"
printf '%s\n' "$current_base_generation" > "$generation_target"
chmod 600 "$generation_target"
rm -f "$CFY_SOURCE_GENERATION_FILE"
ln -s "$generation_target" "$CFY_SOURCE_GENERATION_FILE"
update_sub || fail 'symlink cfy generation sidecar did not degrade safely'
assert_base_only_publication 'vless://base-after-generation-change'
[[ -L "$CFY_SOURCE_GENERATION_FILE" ]] || fail 'Sing-box replaced the cfy-owned generation symlink'

rm -f "$CFY_SOURCE_GENERATION_FILE"
printf '%s\n' "$current_base_generation" > "$CFY_SOURCE_GENERATION_FILE"
chmod 600 "$CFY_SOURCE_GENERATION_FILE"
update_sub || fail 'matching cfy generation sidecar was rejected'
expected=$'vless://base-after-generation-change\nvless://shared\nvless://cfy-b\nvless://same-fields#two'
[[ "$(cat "$combined_client_dir")" == "$expected" ]] || \
    fail 'matching cfy generation was not merged'
matching_generation_checksum="$(cksum < "$CFY_SOURCE_GENERATION_FILE")"
update_sub || fail 'repeat matching cfy publication failed'
[[ "$(cksum < "$CFY_SOURCE_GENERATION_FILE")" == "$matching_generation_checksum" ]] || \
    fail 'Sing-box rewrote a matching cfy generation sidecar'

printf '%s\n' 'old-served-generation' > "${work_dir}/sub.txt"
base64() { return 1; }
if update_sub >/dev/null 2>&1; then
    fail 'publication succeeded after both base64 encoders failed'
fi
unset -f base64
[[ "$(cat "${work_dir}/sub.txt")" == old-served-generation ]] || \
    fail 'a staging failure replaced the old served subscription'

printf '%s\n' 'vless://old-base' > "$client_dir"
printf '%s\n' 'old-served-generation' > "${work_dir}/sub.txt"
staged_base="${work_dir}/.tmp.url.txt.staged"
printf '%s\n' 'vless://new-base' > "$staged_base"
base64() { return 1; }
if update_sub "$staged_base" >/dev/null 2>&1; then
    fail 'staged-base publication succeeded after base64 failure'
fi
unset -f base64
[[ "$(cat "$client_dir")" == 'vless://old-base' ]] || \
    fail 'a staging failure committed the new base source before the served generation'
[[ "$(cat "${work_dir}/sub.txt")" == old-served-generation ]] || \
    fail 'a staged-base failure replaced the old served generation'

rm -f "${work_dir}/cfy-url.txt"
printf '%s\n' 'vless://base-without-cfy' > "$client_dir"
update_sub || fail 'a missing optional cfy source was not treated as empty'
[[ "$(cat "$combined_client_dir")" == 'vless://base-without-cfy' ]] || \
    fail 'missing cfy source produced an unexpected combined publication'

rm -f "$client_dir"
initial_staged_base="${work_dir}/.tmp.url.txt.initial"
printf '%s\n' 'vless://first-install' > "$initial_staged_base"
update_sub "$initial_staged_base" || fail 'first installation required a pre-existing url.txt'
[[ "$(cat "$client_dir")" == 'vless://first-install' ]] || \
    fail 'first installation did not commit its staged base source'
[[ "$(base64 -d "${work_dir}/sub.txt")" == 'vless://first-install' ]] || \
    fail 'first installation did not publish its staged base source'

replace_base_fixture() {
    local staged_file="$1"
    printf '%s\n' 'vless://mutated-one' 'vless://mutated-two' > "$staged_file"
}
mutate_base_subscription replace_base_fixture || fail 'locked base mutation failed'
[[ "$(cat "$client_dir")" == $'vless://mutated-one\nvless://mutated-two' ]] || \
    fail 'locked base mutation did not commit the complete staged source'
cmp -s "$client_dir" <(base64 -d "${work_dir}/sub.txt") || \
    fail 'locked base mutation left source and served generations inconsistent'

old_client_checksum="$(cksum < "$client_dir")"
old_served_checksum="$(cksum < "${work_dir}/sub.txt")"
fail_base_fixture() {
    local staged_file="$1"
    printf '%s\n' 'vless://must-not-commit' > "$staged_file"
    return 1
}
if mutate_base_subscription fail_base_fixture >/dev/null 2>&1; then
    fail 'a failed base mutation callback was published'
fi
[[ "$(cksum < "$client_dir")" == "$old_client_checksum" ]] || \
    fail 'a failed base mutation callback changed url.txt'
[[ "$(cksum < "${work_dir}/sub.txt")" == "$old_served_checksum" ]] || \
    fail 'a failed base mutation callback changed the served subscription'

printf '%s\n' 'vless://old-core' 'socks://preserved-extra' > "$client_dir"
generated_core="${work_dir}/.tmp.generated-core"
printf '%s\n' 'vless://new-core' > "$generated_core"
generated_source_generation=$(get_base_subscription_generation) || fail 'could not capture generated-core source generation'
publish_generated_base "$generated_core" "$generated_source_generation" || fail 'get_info-style locked merge failed'
[[ "$(head -n 1 "$client_dir")" == 'vless://new-core' ]] || \
    fail 'get_info-style merge did not commit its generated core URL'
grep -Fxq 'socks://preserved-extra' "$client_dir" || \
    fail 'get_info-style merge lost an existing extra protocol URL'

rollback_staged_base="${work_dir}/.tmp.url.txt.rollback-test"
rollback_log="${tmp_root}/sing-rollback.log"
printf '%s\n' 'vless://rollback-test' > "$rollback_staged_base"
mv() {
    local source_arg="${@: -2:1}"
    local target_arg="${@: -1}"
    if [[ "$target_arg" == "$combined_sub_file" && \
          "$source_arg" == "${work_dir}/.tmp.all-sub.txt."* ]]; then
        return 1
    fi
    if [[ "$target_arg" == "$client_dir" && \
          "$source_arg" == "${work_dir}/.tmp.url.txt.rollback."* ]]; then
        return 1
    fi
    command mv "$@"
}
set +e
update_sub "$rollback_staged_base" 2> "$rollback_log"
rollback_status=$?
set -e
unset -f mv
[[ "$rollback_status" -eq 2 ]] || \
    fail "rollback restoration failure returned ${rollback_status}, expected fatal status 2"
compgen -G "${work_dir}/.tmp.url.txt.rollback.*" >/dev/null || \
    fail 'rollback restoration failure deleted the unrecovered backup'
grep -Fq 'rollback' "$rollback_log" || \
    fail 'rollback restoration failure did not report preserved recovery material'

rm -f "${work_dir}/base-sub.txt"
mkdir "${work_dir}/base-sub.txt"
if update_sub >/dev/null 2>&1; then
    fail 'publisher accepted a non-regular existing target'
fi
rmdir "${work_dir}/base-sub.txt"

rm -f "${work_dir}/.subscription.lock"
mkdir "${work_dir}/.subscription.lock"
if with_subscription_lock true >/dev/null 2>&1; then
    fail 'publisher accepted a non-regular existing lock path'
fi
rmdir "${work_dir}/.subscription.lock"

FLOCK_ACQUIRE_CALLS=0
flock() {
    if [[ "${1:-}" == -x ]]; then
        FLOCK_ACQUIRE_CALLS=$((FLOCK_ACQUIRE_CALLS + 1))
    fi
    return 0
}
nested_subscription_callback() { with_subscription_lock true; }
with_subscription_lock nested_subscription_callback || fail 'nested lock callback failed'
[[ "$FLOCK_ACQUIRE_CALLS" -eq 1 ]] || fail 'a lock-held callback attempted to acquire the lock again'

unset -f flock
no_flock_path="${tmp_root}/no-flock"
mkdir -p "$no_flock_path"
PATH="$no_flock_path"
if with_subscription_lock true >/dev/null 2>&1; then
    fail 'the publisher did not fail closed when flock was unavailable'
fi
PATH="$original_path"

if [[ -n "$real_flock" ]]; then
    lock_log="${tmp_root}/lock.log"
    : > "$lock_log"
    subscription_probe() {
        printf 'start-%s\n' "$1" >> "$lock_log"
        sleep 0.2
        printf 'end-%s\n' "$1" >> "$lock_log"
    }
    with_subscription_lock subscription_probe one & first_pid=$!
    with_subscription_lock subscription_probe two & second_pid=$!
    wait "$first_pid"
    wait "$second_pid"
    lock_order="$(paste -sd, "$lock_log")"
    case "$lock_order" in
        start-one,end-one,start-two,end-two|start-two,end-two,start-one,end-one) ;;
        *) fail "concurrent publishers overlapped: ${lock_order}" ;;
    esac

    printf '%s\n' 'vless://old-visible-generation' > "$client_dir"
    update_sub
    mutation_ready="${tmp_root}/mutation.ready"
    reader_output="${tmp_root}/reader.out"
    slow_base_mutation() {
        local staged_file="$1"
        printf '%s\n' 'vless://new-first-half' > "$staged_file"
        : > "$mutation_ready"
        sleep 0.3
        printf '%s\n' 'vless://new-second-half' >> "$staged_file"
    }
    mutate_base_subscription slow_base_mutation & mutation_pid=$!
    for _ in {1..100}; do
        [[ -e "$mutation_ready" ]] && break
        sleep 0.01
    done
    [[ -e "$mutation_ready" ]] || fail 'concurrent mutation did not reach its staging point'
    [[ "$(cat "$client_dir")" == 'vless://old-visible-generation' ]] || \
        fail 'a concurrent reader observed a half-written base source'
    with_subscription_lock cat "$client_dir" > "$reader_output" & reader_pid=$!
    wait "$mutation_pid"
    wait "$reader_pid"
    [[ "$(cat "$reader_output")" == $'vless://new-first-half\nvless://new-second-half' ]] || \
        fail 'a cfy-style locked reader observed a partial base generation'
    cmp -s "$client_dir" <(base64 -d "${work_dir}/sub.txt") || \
        fail 'concurrent base mutation committed mismatched source and served generations'

    printf '%s\n' \
        'vless://old-uuid@old.example:443?security=tls&sni=old.example&type=ws&host=old.example&path=%2Fvless-argo#argo' \
        'hysteria2://old-uuid@198.51.100.1:443?peer=x&mport=443,50000-50100#hy2' > "$client_dir"
    update_sub
    hy2_ready="${tmp_root}/hy2.ready"
    hy2_disable_and_publish_locked() {
        stage_hy2_client_file disable || return 1
        : > "$hy2_ready"
        sleep 0.3
        publish_subscriptions_locked "$HY2_STAGED_CLIENT_FILE"
    }
    with_subscription_lock hy2_disable_and_publish_locked & hy2_pid=$!
    for _ in {1..100}; do
        [[ -e "$hy2_ready" ]] && break
        sleep 0.01
    done
    [[ -e "$hy2_ready" ]] || fail 'HY2 interleave fixture did not reach its staged point'
    mutate_base_subscription update_subscription_uuid_file 'new-uuid' & uuid_pid=$!
    mutate_base_subscription update_vless_argo_domain_file 'new.example' & argo_pid=$!
    append_base_subscription_url 'socks://concurrent-protocol' & protocol_pid=$!
    wait "$hy2_pid" "$uuid_pid" "$argo_pid" "$protocol_pid"
    grep -Fq 'hysteria2://new-uuid@' "$client_dir" || fail 'HY2/UUID interleave lost the UUID update'
    if grep -Fq 'mport=' "$client_dir"; then
        fail 'HY2/UUID interleave lost the HY2 disable mutation'
    fi
    grep -Fq 'sni=new.example' "$client_dir" || fail 'HY2/Argo interleave lost the Argo update'
    grep -Fq 'socks://concurrent-protocol' "$client_dir" || fail 'HY2/protocol interleave lost the protocol append'

    generated_core="${work_dir}/.tmp.generated-core.concurrent"
    printf '%s\n' 'vless://fresh-generated-core' > "$generated_core"
    generated_ready="${tmp_root}/generated.ready"
    add_extra_before_generation_merge() {
        local staged_file="$1"
        printf '%s\n' 'anytls://concurrent-extra' >> "$staged_file"
        : > "$generated_ready"
        sleep 0.3
    }
    mutate_base_subscription add_extra_before_generation_merge & extra_pid=$!
    for _ in {1..100}; do
        [[ -e "$generated_ready" ]] && break
        sleep 0.01
    done
    publish_generated_after_extra() {
        local generation
        generation=$(get_base_subscription_generation) || return 1
        publish_generated_base "$generated_core" "$generation"
    }
    publish_generated_after_extra & generated_pid=$!
    wait "$extra_pid" "$generated_pid"
    grep -Fq 'vless://fresh-generated-core' "$client_dir" || fail 'get_info merge did not publish its new core generation'
    grep -Fq 'anytls://concurrent-extra' "$client_dir" || fail 'get_info merge overwrote a concurrent extra protocol update'

    old_uuid='11111111-1111-4111-8111-111111111111'
    new_uuid='22222222-2222-4222-8222-222222222222'
    printf '%s\n' \
        "vless://${old_uuid}@198.51.100.10:443?security=reality#reality" \
        "vless://${old_uuid}@cdn.old.test:443?security=tls&sni=old.example&type=ws&host=old.example&path=%2Fvless-argo#argo" \
        "hysteria2://${old_uuid}@198.51.100.10:443?peer=x#hy2" \
        "tuic://${old_uuid}:${old_uuid}@198.51.100.10:443?sni=x#tuic" \
        "anytls://${old_uuid}@198.51.100.10:443#extra" > "$client_dir"
    update_sub

    core_probe_ready="${tmp_root}/get-info-core.ready"
    core_probe_release="${tmp_root}/get-info-core.release"
    core_mutation_done="${tmp_root}/get-info-core.mutated"
    core_info_output="${tmp_root}/get-info-core.out"
    get_public_ipv4() {
        : > "$core_probe_ready"
        while [[ ! -e "$core_probe_release" ]]; do sleep 0.01; done
        printf '%s\n' '198.51.100.10'
    }
    get_public_ipv6() { return 1; }
    get_realip() { return 1; }
    get_subscription_host() { printf '%s\n' '198.51.100.10'; }
    get_country_code() { printf '%s\n' 'US'; }
    sanitize_node_name() { printf '%s\n' "$1"; }
    get_default_node_name() { printf '%s\n' 'fixture'; }
    format_node_name_prefix() { printf '%s-%s\n' "$1" "$2"; }
    list_argo_client_addresses() { printf '%s\t%s\n' 'cdn.old.test' stable; }
    resolve_installed_subscription_source_url() { return 1; }
    build_http_subscription_url() { printf '%s\n' 'http://198.51.100.10:23001/sub'; }
    show_subscription_links() { :; }
    clear() { :; }
    yellow() { :; }
    purple() { :; }
    green() { :; }
    red() { :; }

    uuid="$old_uuid"
    public_key='test-public-key'
    vless_port=443
    nginx_port=23001
    hy2_port=23005
    tuic_port=23003
    password='test-password'
    fingerprint='test-fingerprint'
    NODE_NAME='fixture'
    SKIP_NODE_NAME_PROMPT=1
    ARGO_FIXED_READY=1
    ARGO_DOMAIN='old.example'
    CFIP='cdn.old.test'
    CFPORT=443
    INCLUDE_UDP_LINKS=1
    purple=''
    re=''
    get_info > "$core_info_output" 2>&1 & core_info_pid=$!
    for _ in {1..100}; do
        [[ -e "$core_probe_ready" ]] && break
        sleep 0.01
    done
    [[ -e "$core_probe_ready" ]] || fail 'get_info did not reach the long network-probe fixture'

    mutate_concurrent_core() {
        local staged_file="$1"
        update_subscription_uuid_file "$staged_file" "$new_uuid" &&
            update_vless_argo_domain_file "$staged_file" 'new.example'
    }
    mutate_base_subscription mutate_concurrent_core && : > "$core_mutation_done" & core_mutation_pid=$!
    for _ in {1..100}; do
        [[ -e "$core_mutation_done" ]] && break
        sleep 0.01
    done
    if [[ ! -e "$core_mutation_done" ]]; then
        kill "$core_info_pid" "$core_mutation_pid" 2>/dev/null || true
        wait "$core_info_pid" "$core_mutation_pid" 2>/dev/null || true
        fail 'get_info held the subscription lock across its network probe'
    fi
    wait "$core_mutation_pid"
    concurrent_core_checksum="$(cksum < "$client_dir")"
    concurrent_served_checksum="$(cksum < "${work_dir}/sub.txt")"
    : > "$core_probe_release"
    set +e
    wait "$core_info_pid"
    core_info_status=$?
    set -e
    [[ "$core_info_status" -ne 0 ]] || fail 'stale get_info core generation overwrote a concurrent UUID/Argo update'
    if ! grep -Fq 'base subscription generation changed' "$core_info_output"; then
        command cat "$core_info_output" >&2
        fail 'get_info did not identify the stale core generation before refusing publication'
    fi
    [[ "$(cksum < "$client_dir")" == "$concurrent_core_checksum" ]] || \
        fail 'get_info changed url.txt after its captured core generation became stale'
    [[ "$(cksum < "${work_dir}/sub.txt")" == "$concurrent_served_checksum" ]] || \
        fail 'get_info changed served content after its captured core generation became stale'
    grep -Fq "vless://${new_uuid}@" "$client_dir" || fail 'get_info lost the concurrent UUID update'
    grep -Fq 'sni=new.example' "$client_dir" || fail 'get_info lost the concurrent Argo update'
    grep -Fq "anytls://${new_uuid}@" "$client_dir" || fail 'get_info lost the concurrent extra protocol update'
else
    printf 'SKIP: util-linux flock is unavailable; real concurrency check requires Linux CI.\n'
fi

# Quick-mode rollback owns only the exact generation it published. A newer base
# generation must survive the short-lock CAS, while an unchanged published
# generation can be restored from the independent 0600 preimage.
printf '%s\n' argo-old-generation > "$client_dir"
update_sub || fail 'could not publish the Argo CAS baseline'
argo_rollback_file="$(mktemp "${work_dir}/.argo-subscription-rollback.XXXXXX")"
cp -p -- "$client_dir" "$argo_rollback_file"
chmod 600 "$argo_rollback_file"
argo_old_generation="$(get_base_subscription_generation)"
printf '%s\n' argo-published-generation > "$client_dir"
update_sub || fail 'could not publish the Argo CAS candidate'
argo_new_generation="$(get_base_subscription_generation)"
printf '%s\n' concurrent-newer-generation > "$client_dir"
update_sub || fail 'could not publish the concurrent Argo generation'
if restore_argo_transition_subscription "$argo_rollback_file" \
    "$argo_old_generation" "$argo_new_generation"; then
    fail 'Argo CAS rollback overwrote a newer base generation'
else
    argo_cas_status=$?
fi
[[ "$argo_cas_status" -eq 2 ]] || \
    fail "Argo CAS generation conflict returned ${argo_cas_status} instead of rc 2"
[[ "$(<"$client_dir")" == concurrent-newer-generation ]] || \
    fail 'Argo CAS generation conflict changed the concurrent base source'
[[ -f "$argo_rollback_file" ]] || \
    fail 'Argo CAS generation conflict discarded its recovery preimage'
printf '%s\n' argo-published-generation > "$client_dir"
update_sub || fail 'could not reset the Argo CAS candidate'
restore_argo_transition_subscription "$argo_rollback_file" \
    "$argo_old_generation" "$argo_new_generation" || \
    fail 'Argo CAS could not restore its unchanged published generation'
[[ "$(<"$client_dir")" == argo-old-generation ]] || \
    fail 'Argo CAS restored the wrong base preimage'
[[ ! -e "$argo_rollback_file" ]] || \
    fail 'successful Argo CAS retained a stale recovery preimage'

# A publisher rc=2 means its own atomic rollback is unresolved. The tracked
# publisher must retain the old preimage even though no trustworthy new
# generation exists for an automatic CAS.
saved_mutate_base_subscription_locked="$(declare -f mutate_base_subscription_locked)"
mutate_base_subscription_locked() { return 2; }
ArgoDomain=quick.trycloudflare.com
ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE=''
ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION=''
ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION=''
SUBSCRIPTION_LOCK_HELD=1
if publish_tracked_argo_transition_subscription_locked quick quick.trycloudflare.com \
    preferred.example.com 443; then
    tracked_publish_status=0
else
    tracked_publish_status=$?
fi
unset SUBSCRIPTION_LOCK_HELD
eval "$saved_mutate_base_subscription_locked"
[[ "$tracked_publish_status" -eq 2 ]] || \
    fail "tracked Argo publisher rc 2 became ${tracked_publish_status}"
[[ -f "$ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE" ]] || \
    fail 'tracked Argo publisher rc 2 discarded its base preimage evidence'
[[ -n "$ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION" && \
   -z "$ARGO_TRANSITION_SUBSCRIPTION_NEW_GENERATION" ]] || \
    fail 'tracked Argo publisher rc 2 exposed invalid rollback generations'
rm -f -- "$ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE"
ARGO_TRANSITION_SUBSCRIPTION_ROLLBACK_FILE=''
ARGO_TRANSITION_SUBSCRIPTION_OLD_GENERATION=''

if grep -Eq 'sed[[:space:]].*-i.*\$\{?client_dir|echo.*>>.*\$\{?client_dir|mv.*\$\{?client_dir|rm.*\$\{?client_dir' "$script"; then
    fail 'Sing-box still directly mutates url.txt outside the shared subscription transaction'
fi
if grep -Fq 'atomic_replace_hy2_client "$staged_file" "$client_dir"' "$script"; then
    fail 'Hysteria2 still commits url.txt before acquiring the shared subscription lock'
fi
hy2_enable_source="$(extract_function _enable_hy2_port_hopping_transaction_locked)"
hy2_disable_source="$(extract_function _disable_hy2_port_hopping_transaction_locked)"
grep -Fq 'with_subscription_lock enable_hy2_port_hopping_transaction_locked' <<< "$hy2_enable_source" || \
    fail 'HY2 enable does not take the shared subscription lock inside the outer proxy transaction'
grep -Fq 'with_subscription_lock disable_hy2_port_hopping_transaction_locked' <<< "$hy2_disable_source" || \
    fail 'HY2 disable does not take the shared subscription lock inside the outer proxy transaction'
get_info_source="$(extract_function get_info)"
grep -Fq 'publish_generated_base "$tmp_url_file"' <<< "$get_info_source" || \
    fail 'get_info does not merge existing extra URLs inside the shared lock'

install_source="$(extract_function run_install_flow)"
grep -Fq 'util-linux' <<< "$install_source" || fail 'Sing-box installation does not request util-linux/flock'

change_source="$(sed -n '/^change_config() {/,/^configure_cf_https_subscription() {/p' "$script")"
if grep -Fq 'update_uuid_file "${work_dir}/cfy-url.txt"' <<< "$change_source"; then
    fail 'Sing-box UUID changes still rewrite the cfy-owned source file'
fi
argo_source="$(extract_function change_argo_domain)"
if grep -Fq 'update_vless_argo_domain_file "${work_dir}/cfy-url.txt"' <<< "$argo_source"; then
    fail 'Sing-box Argo changes still rewrite the cfy-owned source file'
fi

for transition_name in transition_to_quick_argo transition_to_fixed_argo; do
    transition_source="$(extract_function "$transition_name")"
    grep -Fq 'acquire_proxy_transaction_lock_checked' <<< "$transition_source" || \
        fail "${transition_name} does not fail-close under the canonical proxy lock"
    locked_transition_name="_${transition_name}_locked"
    grep -Fq "$locked_transition_name" <<< "$transition_source" || \
        fail "${transition_name} does not delegate to a non-nesting locked implementation"
    locked_transition_source="$(extract_function "$locked_transition_name")"
    [[ -n "$locked_transition_source" ]] || \
        fail "${locked_transition_name} is not implemented"
    if grep -Fq 'rebuild_argo_client_address_set_file "$client_dir"' <<< "$transition_source"; then
        fail "${transition_name} rebuilds live url.txt outside the canonical subscription lock"
    fi
    grep -Fq 'change_argo_transition_subscription' <<< "$locked_transition_source" || \
        fail "${transition_name} bypasses the locked Argo subscription transition"
done
quick_locked_source="$(extract_function _transition_to_quick_argo_locked)"
grep -Fq '_disable_cf_https_subscription_locked' <<< "$quick_locked_source" || \
    fail 'quick Argo locked implementation reacquires the proxy lock through the public HTTPS wrapper'
argo_transition_source="$(extract_function change_argo_transition_subscription)"
grep -Fq 'mutate_base_subscription rebuild_argo_transition_subscription_file' \
    <<< "$argo_transition_source" || \
    fail 'Argo address/domain transition does not mutate and publish under the canonical subscription lock'

extra_add_source="$(extract_function _add_extra_protocol_transaction_locked)"
if grep -Fq '>> "$client_dir"' <<< "$extra_add_source"; then
    fail 'extra-protocol add writes live url.txt outside the canonical subscription lock'
fi
grep -Fq 'append_base_subscription_url "$client_line"' <<< "$extra_add_source" || \
    fail 'extra-protocol add bypasses the locked base-subscription append helper'

printf 'Sing-box subscription contract tests passed.\n'
