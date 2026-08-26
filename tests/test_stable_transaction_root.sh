#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

for function_name in \
    clear_inherited_transaction_lock_state \
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
    dispatch_cli_action; do
    function_source="$(extract_function "$function_name")"
    [ -n "$function_source" ] || fail "${function_name} is not implemented"
    source <(printf '%s\n' "$function_source")
done

assert_mode() {
    local expected="$1" path="$2" actual

    actual=$(stat -c '%a' -- "$path") || fail "could not stat mode for ${path}"
    [ "$actual" = "$expected" ] || fail "${path} mode is ${actual}, expected ${expected}"
}

assert_regular_single_link() {
    local path="$1"

    [ -f "$path" ] && [ ! -L "$path" ] || fail "${path} is not a regular non-symlink file"
    [ "$(stat -c '%h' -- "$path")" = 1 ] || fail "${path} is hard-linked"
}

SING_BOX_TRANSACTION_ROOT="${tmp_root}/root"
unset SING_BOX_TRANSACTION_GROUP
ensure_stable_transaction_root || fail 'could not initialize the stable transaction root'

[ "$(cat "$SING_BOX_TRANSACTION_ROOT/schema-version")" = 1 ] || \
    fail 'schema-version is not exactly version 1'
assert_mode 700 "$SING_BOX_TRANSACTION_ROOT"
assert_mode 700 "$SING_BOX_TRANSACTION_ROOT/pending"
assert_mode 700 "$SING_BOX_TRANSACTION_ROOT/recoveries"
assert_mode 600 "$SING_BOX_TRANSACTION_ROOT/schema-version"
assert_regular_single_link "$SING_BOX_TRANSACTION_ROOT/schema-version"

for kind in mutation subscription firewall; do
    expected_path="$SING_BOX_TRANSACTION_ROOT/${kind}.lock"
    actual_path=$(stable_transaction_lock_path "$kind") || fail "could not resolve ${kind} lock"
    [ "$actual_path" = "$expected_path" ] || \
        fail "${kind} lock resolved to ${actual_path}, expected ${expected_path}"
    assert_regular_single_link "$expected_path"
    assert_mode 600 "$expected_path"
done

if stable_transaction_lock_path unknown >/dev/null 2>&1; then
    fail 'unknown lock kind was accepted'
fi

# Initialization is idempotent and must never replace or truncate lock files.
for kind in mutation subscription firewall; do
    lock_path="$SING_BOX_TRANSACTION_ROOT/${kind}.lock"
    printf -v "${kind}_identity" '%s' "$(stat -c '%d:%i:%s' -- "$lock_path")"
done
ensure_stable_transaction_root || fail 'repeat initialization failed'
for kind in mutation subscription firewall; do
    lock_path="$SING_BOX_TRANSACTION_ROOT/${kind}.lock"
    expected_identity="${kind}_identity"
    [ "$(stat -c '%d:%i:%s' -- "$lock_path")" = "${!expected_identity}" ] || \
        fail "repeat initialization replaced or truncated ${kind}.lock"
done

# Safe, current-owner permission drift is repaired without replacing objects.
chmod 755 "$SING_BOX_TRANSACTION_ROOT"
chmod 777 "$SING_BOX_TRANSACTION_ROOT/pending"
chmod 666 "$SING_BOX_TRANSACTION_ROOT/mutation.lock"
root_inode=$(stat -c '%d:%i' -- "$SING_BOX_TRANSACTION_ROOT")
lock_inode=$(stat -c '%d:%i' -- "$SING_BOX_TRANSACTION_ROOT/mutation.lock")
ensure_stable_transaction_root || fail 'safe permission repair failed'
assert_mode 700 "$SING_BOX_TRANSACTION_ROOT"
assert_mode 700 "$SING_BOX_TRANSACTION_ROOT/pending"
assert_mode 600 "$SING_BOX_TRANSACTION_ROOT/mutation.lock"
[ "$(stat -c '%d:%i' -- "$SING_BOX_TRANSACTION_ROOT")" = "$root_inode" ] || \
    fail 'permission repair replaced the root directory'
[ "$(stat -c '%d:%i' -- "$SING_BOX_TRANSACTION_ROOT/mutation.lock")" = "$lock_inode" ] || \
    fail 'permission repair replaced mutation.lock'

# Trusted-group mode is explicit and uses the caller's requested gid.
SING_BOX_TRANSACTION_GROUP="$(id -g)"
ensure_stable_transaction_root || fail 'trusted-group initialization failed'
assert_mode 750 "$SING_BOX_TRANSACTION_ROOT"
assert_mode 750 "$SING_BOX_TRANSACTION_ROOT/pending"
assert_mode 640 "$SING_BOX_TRANSACTION_ROOT/subscription.lock"
[ "$(stat -c '%g' -- "$SING_BOX_TRANSACTION_ROOT/subscription.lock")" = "$(id -g)" ] || \
    fail 'trusted-group lock gid was not applied'
unset SING_BOX_TRANSACTION_GROUP
ensure_stable_transaction_root || fail 'returning to private mode failed'

# A relative or newline-bearing override is never accepted.
saved_root="$SING_BOX_TRANSACTION_ROOT"
SING_BOX_TRANSACTION_ROOT='relative/transaction-root'
if ensure_stable_transaction_root >/dev/null 2>&1; then
    fail 'relative transaction root was accepted'
fi
SING_BOX_TRANSACTION_ROOT=$'bad\nroot'
if ensure_stable_transaction_root >/dev/null 2>&1; then
    fail 'newline-bearing transaction root was accepted'
fi
SING_BOX_TRANSACTION_ROOT="$saved_root"

# Existing symlinks and hard links fail closed and are not repaired in place.
unsafe_root="${tmp_root}/unsafe-root"
real_root="${tmp_root}/real-root"
mkdir -p "$real_root"
ln -s "$real_root" "$unsafe_root"
SING_BOX_TRANSACTION_ROOT="$unsafe_root"
if ensure_stable_transaction_root >/dev/null 2>&1; then
    fail 'symlink transaction root was accepted'
fi
[ -L "$unsafe_root" ] || fail 'symlink transaction root was mutated'

mkdir -p "${tmp_root}/parent-real"
ln -s "${tmp_root}/parent-real" "${tmp_root}/parent-link"
SING_BOX_TRANSACTION_ROOT="${tmp_root}/parent-link/root"
if ensure_stable_transaction_root >/dev/null 2>&1; then
    fail 'transaction root below a symlink parent was accepted'
fi
[ ! -e "${tmp_root}/parent-real/root" ] || fail 'symlink parent was followed during initialization'

SING_BOX_TRANSACTION_ROOT="${tmp_root}/unsafe-object-root"
ensure_stable_transaction_root || fail 'could not create unsafe-object fixture root'
printf 'backing\n' > "$SING_BOX_TRANSACTION_ROOT/backing"
rm -f -- "$SING_BOX_TRANSACTION_ROOT/firewall.lock"
ln "$SING_BOX_TRANSACTION_ROOT/backing" "$SING_BOX_TRANSACTION_ROOT/firewall.lock"
if ensure_stable_transaction_root >/dev/null 2>&1; then
    fail 'hard-linked lock file was accepted'
fi
[ "$(cat "$SING_BOX_TRANSACTION_ROOT/backing")" = backing ] || \
    fail 'hard-linked lock referent was modified'

rm -f -- "$SING_BOX_TRANSACTION_ROOT/firewall.lock"
ln -s "$SING_BOX_TRANSACTION_ROOT/backing" "$SING_BOX_TRANSACTION_ROOT/firewall.lock"
if ensure_stable_transaction_root >/dev/null 2>&1; then
    fail 'symlink lock file was accepted'
fi
[ -L "$SING_BOX_TRANSACTION_ROOT/firewall.lock" ] || fail 'symlink lock was replaced'

# A foreign schema version is evidence, not a file to overwrite.
SING_BOX_TRANSACTION_ROOT="${tmp_root}/bad-schema-root"
ensure_stable_transaction_root || fail 'could not create schema fixture root'
printf '2\n' > "$SING_BOX_TRANSACTION_ROOT/schema-version"
chmod 600 "$SING_BOX_TRANSACTION_ROOT/schema-version"
if ensure_stable_transaction_root >/dev/null 2>&1; then
    fail 'foreign transaction schema was accepted'
fi
[ "$(cat "$SING_BOX_TRANSACTION_ROOT/schema-version")" = 2 ] || \
    fail 'foreign transaction schema was overwritten'

printf '1\n\n' > "$SING_BOX_TRANSACTION_ROOT/schema-version"
chmod 600 "$SING_BOX_TRANSACTION_ROOT/schema-version"
if ensure_stable_transaction_root >/dev/null 2>&1; then
    fail 'schema with trailing blank data was accepted'
fi
[ "$(wc -c < "$SING_BOX_TRANSACTION_ROOT/schema-version" | tr -d '[:space:]')" = 3 ] || \
    fail 'malformed transaction schema was overwritten'

# Ordered stable locks serialize upgraded writers without changing the inode
# anchors.  Lock order is mutation -> subscription -> firewall.
SING_BOX_TRANSACTION_ROOT="${tmp_root}/lock-root"
unset SING_BOX_TRANSACTION_GROUP
ensure_stable_transaction_root || fail 'could not create ordered-lock fixture root'
reset_stable_transaction_lock_state

# FD identity checks must use the current Bash process, not the parent PID.
# This reproduces callers that acquire locks from a parenthesized worker.
(
    reset_stable_transaction_lock_state
    acquire_stable_transaction_lock mutation 1
    release_stable_transaction_lock mutation
) || fail 'stable lock could not be acquired and released inside a subshell'

acquire_stable_transaction_lock mutation 1 || fail 'could not acquire mutation lock'
stable_transaction_lock_is_held mutation || fail 'mutation lock state was not recorded'
acquire_stable_transaction_lock subscription 1 || fail 'could not acquire subscription after mutation'
acquire_stable_transaction_lock firewall 1 || fail 'could not acquire firewall after subscription'
if release_stable_transaction_lock mutation >/dev/null 2>&1; then
    fail 'mutation lock was released before higher-ranked locks'
fi
stable_transaction_lock_is_held mutation || fail 'invalid release leaked mutation lock state'
release_stable_transaction_lock firewall || fail 'could not release firewall lock'
release_stable_transaction_lock subscription || fail 'could not release subscription lock'
release_stable_transaction_lock mutation || fail 'could not release mutation lock'

# Same-kind re-entry is allowed only while that kind remains the highest rank.
# Re-entering mutation after subscription would violate global lock order.
mutation_path=$(stable_transaction_lock_path mutation)
subscription_path=$(stable_transaction_lock_path subscription)
acquire_stable_transaction_lock mutation 1 || fail 'could not acquire mutation for cross-rank re-entry test'
acquire_stable_transaction_lock subscription 1 || fail 'could not acquire subscription for cross-rank re-entry test'
mutation_depth_before=${STABLE_TX_MUTATION_DEPTH:-}
mutation_fd_before=${STABLE_TX_MUTATION_FD:-}
subscription_depth_before=${STABLE_TX_SUBSCRIPTION_DEPTH:-}
subscription_fd_before=${STABLE_TX_SUBSCRIPTION_FD:-}
set +e
acquire_stable_transaction_lock mutation 1
order_status=$?
set -e
[ "$order_status" -eq 2 ] || \
    fail "mutation re-entry below subscription returned ${order_status}, expected 2"
[ "${STABLE_TX_MUTATION_DEPTH:-}" = "$mutation_depth_before" ] && \
    [ "${STABLE_TX_MUTATION_FD:-}" = "$mutation_fd_before" ] || \
    fail 'rejected mutation re-entry changed mutation state'
[ "${STABLE_TX_SUBSCRIPTION_DEPTH:-}" = "$subscription_depth_before" ] && \
    [ "${STABLE_TX_SUBSCRIPTION_FD:-}" = "$subscription_fd_before" ] || \
    fail 'rejected mutation re-entry changed subscription state'
release_stable_transaction_lock subscription || fail 'could not release subscription after rejected re-entry'
release_stable_transaction_lock mutation || fail 'could not release mutation after rejected re-entry'
flock -n "$subscription_path" -c true || fail 'rejected re-entry leaked subscription kernel lock'
flock -n "$mutation_path" -c true || fail 'rejected re-entry leaked mutation kernel lock'

acquire_stable_transaction_lock subscription 1 || fail 'could not acquire standalone subscription lock'
set +e
acquire_stable_transaction_lock mutation 1
order_status=$?
set -e
[ "$order_status" -eq 2 ] || fail "subscription -> mutation returned ${order_status}, expected 2"
release_stable_transaction_lock subscription || fail 'could not release standalone subscription lock'

acquire_stable_transaction_lock firewall 1 || fail 'could not acquire standalone firewall lock'
set +e
acquire_stable_transaction_lock subscription 1
order_status=$?
set -e
[ "$order_status" -eq 2 ] || fail "firewall -> subscription returned ${order_status}, expected 2"
release_stable_transaction_lock firewall || fail 'could not release standalone firewall lock'

# Same-kind nesting keeps the kernel lock until the final release.
mutation_path=$(stable_transaction_lock_path mutation)
mutation_identity=$(stat -c '%d:%i:%s' -- "$mutation_path")
acquire_stable_transaction_lock mutation 1 || fail 'could not acquire nested mutation lock level 1'
acquire_stable_transaction_lock mutation 1 || fail 'could not acquire nested mutation lock level 2'
release_stable_transaction_lock mutation || fail 'could not release nested mutation lock level 2'
stable_transaction_lock_is_held mutation || fail 'nested release unlocked mutation too early'
if flock -n "$mutation_path" -c true; then
    fail 'another process acquired mutation while nested owner still held it'
fi
release_stable_transaction_lock mutation || fail 'could not release final nested mutation lock'
if ! flock -n "$mutation_path" -c true; then
    fail 'mutation lock remained held after final release'
fi
[ "$(stat -c '%d:%i:%s' -- "$mutation_path")" = "$mutation_identity" ] || \
    fail 'lock acquisition replaced or wrote mutation.lock'

# A path replacement after the fd is opened is corruption, not contention.
real_flock=$(command -v flock)
race_lock_path="$mutation_path"
race_replaced_path="${mutation_path}.external-replacement"
race_flock_once=1
flock() {
    if [ "$race_flock_once" -eq 1 ] && [ "${1:-}" = -x ]; then
        race_flock_once=0
        mv -- "$race_lock_path" "$race_replaced_path"
        : > "$race_lock_path"
        chmod 600 "$race_lock_path"
    fi
    "$real_flock" "$@"
}
set +e
acquire_stable_transaction_lock mutation 1
race_status=$?
set -e
unset -f flock
[ "$race_status" -eq 2 ] || \
    fail "stable lock path replacement returned ${race_status}, expected 2"
stable_transaction_lock_is_held mutation && fail 'path replacement leaked stable lock state'
rm -f -- "$race_replaced_path"
ensure_stable_transaction_root || fail 'could not restore stable root after replacement race'

# Callback rc is preserved and the lock is released on every callback result.
callback_rc_two() { return 2; }
set +e
with_stable_transaction_lock subscription callback_rc_two
callback_status=$?
set -e
[ "$callback_status" -eq 2 ] || fail "locked callback rc changed to ${callback_status}"
stable_transaction_lock_is_held subscription && fail 'locked callback leaked subscription state'
flock -n "$(stable_transaction_lock_path subscription)" -c true || \
    fail 'locked callback leaked the kernel subscription lock'

# Exported in-process bookkeeping is untrusted at a fresh script boundary. A
# real CLI dispatch must clear it and contend on the kernel lock, not execute
# its management callback under a forged held-lock flag.
grep -Fq 'clear_inherited_transaction_lock_state || exit 2' "$script" || \
    fail 'top-level Sing-box entry does not clear inherited transaction state'
polluted_dispatch_ready="${tmp_root}/polluted-dispatch.ready"
polluted_dispatch_marker="${tmp_root}/polluted-dispatch.callback"
polluted_subscription_path=$(stable_transaction_lock_path subscription)
(
    exec 9>>"$polluted_subscription_path"
    flock -x 9
    : > "$polluted_dispatch_ready"
    sleep 1
) & polluted_holder_pid=$!
for _ in {1..100}; do
    [ -e "$polluted_dispatch_ready" ] && break
    sleep 0.01
done
[ -e "$polluted_dispatch_ready" ] || fail 'polluted dispatch holder did not start'
set +e
(
    export SUBSCRIPTION_LOCK_HELD=1
    export STABLE_TX_MUTATION_DEPTH=9 STABLE_TX_MUTATION_FD=91
    export STABLE_TX_SUBSCRIPTION_DEPTH=9 STABLE_TX_SUBSCRIPTION_FD=92
    export STABLE_TX_FIREWALL_DEPTH=9 STABLE_TX_FIREWALL_FD=93
    export LEGACY_TX_MUTATION_DEPTH=9 LEGACY_TX_MUTATION_FD=94 LEGACY_TX_MUTATION_PATH=/tmp/forged-mutation
    export LEGACY_TX_SUBSCRIPTION_DEPTH=9 LEGACY_TX_SUBSCRIPTION_FD=95 LEGACY_TX_SUBSCRIPTION_PATH=/tmp/forged-subscription
    export LEGACY_TX_FIREWALL_DEPTH=9 LEGACY_TX_FIREWALL_FD=96 LEGACY_TX_FIREWALL_PATH=/tmp/forged-firewall
    SUBSCRIPTION_LOCK_FILE="${tmp_root}/absent-polluted-legacy.lock"
    SUBSCRIPTION_LOCK_TIMEOUT_SECONDS=0
    polluted_dispatch_callback() { : > "$polluted_dispatch_marker"; }
    check_nodes() { with_subscription_lock polluted_dispatch_callback; }
    clear_inherited_transaction_lock_state || exit 90
    dispatch_cli_action -c
)
polluted_dispatch_status=$?
set -e
wait "$polluted_holder_pid"
[ "$polluted_dispatch_status" -eq 1 ] || \
    fail "polluted real dispatch returned ${polluted_dispatch_status}, expected stable contention rc=1"
[ ! -e "$polluted_dispatch_marker" ] || fail 'polluted real dispatch bypassed the stable lock'

# Safe legacy bridging is stable-first, never creates an absent old path, and
# holds both locks until reverse-order release.
legacy_dir="${tmp_root}/legacy"
mkdir -p "$legacy_dir"
legacy_subscription="$legacy_dir/.subscription.lock"
: > "$legacy_subscription"
chmod 600 "$legacy_subscription"
bridge_log="${tmp_root}/bridge.log"
: > "$bridge_log"
stable_transaction_lock_hook() {
    printf 'stable:%s:%s\n' "$1" "$2" >> "$bridge_log"
}
legacy_transaction_lock_hook() {
    printf 'legacy:%s:%s\n' "$1" "$2" >> "$bridge_log"
}
acquire_transaction_lock_with_legacy subscription "$legacy_subscription" 1 || \
    fail 'could not acquire stable plus legacy subscription locks'
[ "$(sed -n '1p' "$bridge_log")" = "stable:acquired:subscription" ] || \
    fail 'stable subscription lock was not acquired first'
[ "$(sed -n '2p' "$bridge_log")" = "legacy:acquired:subscription" ] || \
    fail 'legacy subscription lock was not acquired second'
if flock -n "$legacy_subscription" -c true; then
    fail 'another process acquired the bridged legacy lock'
fi
release_transaction_lock_with_legacy subscription || fail 'could not release bridged subscription locks'
flock -n "$legacy_subscription" -c true || fail 'legacy lock remained held after bridge release'

absent_legacy="$legacy_dir/.absent.lock"
acquire_transaction_lock_with_legacy subscription "$absent_legacy" 1 || \
    fail 'missing legacy path blocked the stable lock'
[ ! -e "$absent_legacy" ] && [ ! -L "$absent_legacy" ] || \
    fail 'legacy compatibility layer created an absent lock file'
release_transaction_lock_with_legacy subscription || fail 'could not release absent-legacy bridge'

# A direct legacy lock cannot be erased from the in-process registry while it
# is held, even if no stable wrapper was involved.
set +e
(
    reset_stable_transaction_lock_state
    acquire_safe_legacy_lock subscription "$legacy_subscription" 1 || exit 90
    reset_stable_transaction_lock_state
)
legacy_reset_status=$?
set -e
[ "$legacy_reset_status" -eq 2 ] || \
    fail "reset while a legacy lock was held returned ${legacy_reset_status}, expected 2"

# Bounded contention on a valid legacy file is operational (rc=1), while an
# unsafe object remains a contract violation (rc=2).
flock -x "$legacy_subscription" -c 'sleep 2' &
legacy_holder_pid=$!
sleep 0.1
set +e
acquire_safe_legacy_lock subscription "$legacy_subscription" 0
legacy_contention_status=$?
set -e
wait "$legacy_holder_pid"
[ "$legacy_contention_status" -eq 1 ] || \
    fail "legacy lock contention returned ${legacy_contention_status}, expected 1"

# If the legacy acquire is merely contended but cleanup of the already-held
# stable lock becomes uncertain, the cleanup failure must dominate as rc=2.
flock -x "$legacy_subscription" -c 'sleep 2' &
legacy_holder_pid=$!
sleep 0.1
stable_transaction_lock_hook() {
    [ "${1:-}" != released ]
}
set +e
acquire_transaction_lock_with_legacy subscription "$legacy_subscription" 0
legacy_cleanup_status=$?
set -e
stable_transaction_lock_hook() {
    :
}
wait "$legacy_holder_pid"
[ "$legacy_cleanup_status" -eq 2 ] || \
    fail "legacy contention plus stable release failure returned ${legacy_cleanup_status}, expected 2"
[ "${STABLE_TX_SUBSCRIPTION_DEPTH:-0}" -eq 0 ] && \
    [ -z "${STABLE_TX_SUBSCRIPTION_FD:-}" ] || \
    fail 'failed bridge cleanup leaked stable subscription state'
[ "${LEGACY_TX_SUBSCRIPTION_DEPTH:-0}" -eq 0 ] && \
    [ -z "${LEGACY_TX_SUBSCRIPTION_FD:-}" ] || \
    fail 'failed bridge cleanup leaked legacy subscription state'
flock -n "$(stable_transaction_lock_path subscription)" -c true || \
    fail 'failed bridge cleanup leaked the stable kernel lock'

legacy_transaction_lock_hook() {
    [ "${1:-}" != skipped ]
}
set +e
acquire_safe_legacy_lock subscription "$absent_legacy" 1
legacy_hook_status=$?
set -e
[ "$legacy_hook_status" -eq 2 ] || \
    fail "failed skipped-legacy hook returned ${legacy_hook_status}, expected 2"
[ "${LEGACY_TX_SUBSCRIPTION_DEPTH:-0}" -eq 0 ] || \
    fail 'failed skipped-legacy hook leaked lock depth'
[ -z "${LEGACY_TX_SUBSCRIPTION_FD:-}" ] || \
    fail 'failed skipped-legacy hook leaked lock fd state'
legacy_transaction_lock_hook() {
    :
}

assert_unsafe_legacy_rejected() {
    local label="$1" path="$2" status

    set +e
    acquire_transaction_lock_with_legacy subscription "$path" 1
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "${label} legacy lock returned ${status}, expected 2"
    stable_transaction_lock_is_held subscription && fail "${label} legacy failure leaked stable state"
    flock -n "$(stable_transaction_lock_path subscription)" -c true || \
        fail "${label} legacy failure leaked stable kernel lock"
}

unsafe_legacy_target="$legacy_dir/unsafe-target"
: > "$unsafe_legacy_target"
chmod 600 "$unsafe_legacy_target"
ln -s "$unsafe_legacy_target" "$legacy_dir/symlink.lock"
assert_unsafe_legacy_rejected symlink "$legacy_dir/symlink.lock"

mkdir "$legacy_dir/directory.lock"
assert_unsafe_legacy_rejected directory "$legacy_dir/directory.lock"

ln "$unsafe_legacy_target" "$legacy_dir/hardlink.lock"
assert_unsafe_legacy_rejected hardlink "$legacy_dir/hardlink.lock"

: > "$legacy_dir/wide-mode.lock"
chmod 666 "$legacy_dir/wide-mode.lock"
assert_unsafe_legacy_rejected wide-mode "$legacy_dir/wide-mode.lock"

printf 'Stable transaction root tests passed.\n'
