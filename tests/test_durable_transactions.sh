#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

for function_name in \
    finish_transaction_release \
    reset_durable_transaction_state \
    assert_no_pending_durable_transaction \
    write_durable_transaction_registry \
    cleanup_durable_transaction_registry \
    proxy_transaction_reaper_hook \
    reap_stale_proxy_transaction_lock \
    write_durable_transaction_manifest \
    restore_durable_transaction_traps \
    arm_durable_transaction \
    durable_transaction_checkpoint \
    durable_transaction_set_owned_records \
    durable_transaction_trap_handler \
    disarm_durable_transaction; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || {
        echo "FAIL: ${function_name} is not implemented" >&2
        exit 1
    }
    source <(printf '%s\n' "$function_source")
done

release_proxy_transaction_lock() {
    printf 'release-lock\n' >> "$DURABLE_TEST_LOG"
}
red() { :; }

test_arm_permissions_and_manifest() {
    local case_dir="${tmp_dir}/arm"
    mkdir -p "$case_dir"
    printf 'secret-backup\n' > "$case_dir/backup"
    chmod 600 "$case_dir/backup"
    DURABLE_TEST_LOG="$case_dir/calls.log"
    : > "$DURABLE_TEST_LOG"
    rollback_mock() { :; }

    arm_durable_transaction public-port "$case_dir" "$case_dir/backup" \
        TEST_RECOVERY_PATH rollback_mock 1 21000 22000 || return 1
    [[ "$(stat -c '%a' "$DURABLE_TX_RECOVERY_DIR")" == 700 ]] || {
        echo 'FAIL: durable recovery directory is not mode 0700' >&2
        return 1
    }
    [[ "$(stat -c '%a' "$DURABLE_TX_MANIFEST")" == 600 ]] || {
        echo 'FAIL: durable recovery manifest is not mode 0600' >&2
        return 1
    }
    [[ "$(stat -c '%a' "$DURABLE_TX_REGISTRY")" == 600 ]] || {
        echo 'FAIL: durable pending registry is not mode 0600' >&2
        return 1
    }
    [[ "$(<"$DURABLE_TX_REGISTRY")" == "$DURABLE_TX_RECOVERY_DIR" ]] || {
        echo 'FAIL: durable pending registry does not point at its evidence' >&2
        return 1
    }
    grep -Fqx 'kind=public-port' "$DURABLE_TX_MANIFEST"
    grep -Fqx 'stage=precommit' "$DURABLE_TX_MANIFEST"
    grep -Fqx 'service_was_active=1' "$DURABLE_TX_MANIFEST"
    grep -Fqx 'old_port=21000' "$DURABLE_TX_MANIFEST"
    grep -Fqx 'new_port=22000' "$DURABLE_TX_MANIFEST"
    durable_transaction_set_owned_records 'ufw|4|22000|tcp' 'raw|6|22000|tcp'
    grep -Fqx 'owned_record=ufw|4|22000|tcp' "$DURABLE_TX_MANIFEST"
    grep -Fqx 'owned_record=raw|6|22000|tcp' "$DURABLE_TX_MANIFEST"
    disarm_durable_transaction keep
    [[ -d "$TEST_RECOVERY_PATH" ]] || {
        echo 'FAIL: keeping durable evidence did not expose its recovery path' >&2
        return 1
    }
    if assert_no_pending_durable_transaction "$case_dir"; then
        echo 'FAIL: kept durable evidence was not detected as pending' >&2
        return 1
    elif [ "$?" -ne 2 ]; then
        echo 'FAIL: pending durable evidence did not return fatal rc 2' >&2
        return 1
    fi
}

run_signal_case() {
    local stage="$1" expected_status="$2" expect_rollback="$3" expect_evidence="$4"
    local case_dir="${tmp_dir}/${stage}"
    local status=0
    mkdir -p "$case_dir"
    printf 'secret-backup\n' > "$case_dir/backup"
    chmod 600 "$case_dir/backup"
    : > "$case_dir/calls.log"

    (
        trap - EXIT
        DURABLE_TEST_LOG="$case_dir/calls.log"
        rollback_mock() {
            printf 'rollback\n' >> "$DURABLE_TEST_LOG"
            command rm -f -- "$case_dir/backup"
        }
        durable_transaction_hook() {
            [ "$1" = "$stage" ] && kill -TERM "$BASHPID"
        }
        arm_durable_transaction test-kind "$case_dir" "$case_dir/backup" \
            TEST_RECOVERY_PATH rollback_mock 0 10000 10001
        durable_transaction_checkpoint "$stage"
        echo 'FAIL: signal hook returned to transaction body' >&2
        exit 99
    ) || status=$?

    [[ "$status" -eq "$expected_status" ]] || {
        echo "FAIL: ${stage} signal returned ${status}, expected ${expected_status}" >&2
        return 1
    }
    grep -Fqx 'release-lock' "$case_dir/calls.log" || {
        echo "FAIL: ${stage} signal did not release the shared config lock" >&2
        return 1
    }
    if [ "$expect_rollback" -eq 1 ]; then
        grep -Fqx 'rollback' "$case_dir/calls.log" || {
            echo "FAIL: ${stage} signal did not run the safe rollback callback" >&2
            return 1
        }
    elif grep -Fqx 'rollback' "$case_dir/calls.log"; then
        echo "FAIL: ${stage} signal re-entered rollback in an unsafe stage" >&2
        return 1
    fi
    if [ "$expect_evidence" -eq 1 ]; then
        evidence_dir=$(find "$case_dir" -maxdepth 1 -type d -name '.durable-transaction.*' -print -quit)
        [[ -n "$evidence_dir" && -f "$evidence_dir/manifest" ]] || {
            echo "FAIL: ${stage} signal did not preserve durable recovery evidence" >&2
            return 1
        }
        grep -Fqx "stage=${stage}" "$evidence_dir/manifest"
    elif find "$case_dir" -maxdepth 1 -type d -name '.durable-transaction.*' -print -quit | grep -q .; then
        echo "FAIL: ${stage} clean rollback left stale durable evidence" >&2
        return 1
    fi
}

test_arm_permissions_and_manifest
run_signal_case precommit 143 1 0
run_signal_case firewall-mutating 2 0 1
run_signal_case config-mutated 143 1 0
run_signal_case publishing 2 0 1
run_signal_case committed 3 0 1

kill_dir="${tmp_dir}/kill-recovery"
mkdir -p "$kill_dir"
conf_dir="$kill_dir"
SING_BOX_TRANSACTION_ROOT="${tmp_dir}/transactions"
command_exists() { command -v "$1" >/dev/null 2>&1; }
for function_name in \
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
    with_transaction_lock_with_legacy; do
    source <(extract_function "$function_name")
done
source <(extract_function acquire_proxy_transaction_lock)
source <(extract_function release_proxy_transaction_lock)
kill_status=0
(
    trap - EXIT
    rollback_mock() { :; }
    acquire_proxy_transaction_lock "$kill_dir" || exit 90
    arm_durable_transaction kill-test "$kill_dir" "$kill_dir/backup" \
        TEST_RECOVERY_PATH rollback_mock 0 10000 10001 || exit 91
    kill -KILL "$BASHPID"
) >/dev/null 2>&1 || kill_status=$?
[[ "$kill_status" -eq 137 ]] || {
    echo "FAIL: KILL fixture returned ${kill_status}, expected 137" >&2
    exit 1
}
if acquire_proxy_transaction_lock "$kill_dir"; then
    release_proxy_transaction_lock
    echo 'FAIL: new config transaction ignored KILL recovery evidence' >&2
    exit 1
elif [ "$?" -ne 2 ]; then
    echo 'FAIL: KILL recovery evidence did not fail closed with rc 2' >&2
    exit 1
fi

# Public/work, Nginx subscription and extra/conf evidence all use the same
# fail-closed registry contract.
for registry_case in public subscription extra; do
    registry_dir="${tmp_dir}/registry-${registry_case}"
    evidence_dir="${tmp_dir}/evidence-${registry_case}/.durable-transaction.case"
    mkdir -p "$registry_dir" "$evidence_dir"
    printf 'kind=%s\nstage=unknown\n' "$registry_case" > "$evidence_dir/manifest"
    chmod 600 "$evidence_dir/manifest"
    printf '%s\n' "$evidence_dir" > "$registry_dir/.durable-transaction.pending"
    chmod 600 "$registry_dir/.durable-transaction.pending"
    if acquire_proxy_transaction_lock "$registry_dir"; then
        release_proxy_transaction_lock
        echo "FAIL: ${registry_case} pending evidence did not block a new transaction" >&2
        exit 1
    elif [ "$?" -ne 2 ]; then
        echo "FAIL: ${registry_case} pending evidence did not return rc 2" >&2
        exit 1
    fi
done

# Registry, evidence and manifest links are never followed.
symlink_root="${tmp_dir}/symlink-cases"
mkdir -p "$symlink_root/real-evidence" "$symlink_root/registry-link" \
    "$symlink_root/evidence-link" "$symlink_root/manifest-link/evidence"
printf 'kind=test\nstage=unknown\n' > "$symlink_root/real-evidence/manifest"
chmod 600 "$symlink_root/real-evidence/manifest"
printf '%s\n' "$symlink_root/real-evidence" > "$symlink_root/real-registry"
chmod 600 "$symlink_root/real-registry"
ln -s "$symlink_root/real-registry" "$symlink_root/registry-link/.durable-transaction.pending"
if assert_no_pending_durable_transaction "$symlink_root/registry-link"; then
    echo 'FAIL: registry symlink was accepted' >&2
    exit 1
elif [ "$?" -ne 2 ]; then
    echo 'FAIL: registry symlink did not return rc 2' >&2
    exit 1
fi

ln -s "$symlink_root/real-evidence" "$symlink_root/evidence-link/evidence"
printf '%s\n' "$symlink_root/evidence-link/evidence" > \
    "$symlink_root/evidence-link/.durable-transaction.pending"
chmod 600 "$symlink_root/evidence-link/.durable-transaction.pending"
if assert_no_pending_durable_transaction "$symlink_root/evidence-link"; then
    echo 'FAIL: evidence symlink was accepted' >&2
    exit 1
elif [ "$?" -ne 2 ]; then
    echo 'FAIL: evidence symlink did not return rc 2' >&2
    exit 1
fi

ln -s "$symlink_root/real-evidence/manifest" \
    "$symlink_root/manifest-link/evidence/manifest"
printf '%s\n' "$symlink_root/manifest-link/evidence" > \
    "$symlink_root/manifest-link/.durable-transaction.pending"
chmod 600 "$symlink_root/manifest-link/.durable-transaction.pending"
if assert_no_pending_durable_transaction "$symlink_root/manifest-link"; then
    echo 'FAIL: manifest symlink was accepted' >&2
    exit 1
elif [ "$?" -ne 2 ]; then
    echo 'FAIL: manifest symlink did not return rc 2' >&2
    exit 1
fi

# Upgraded transactions require util-linux flock.  The old mkdir-lock reaper
# remains testable below for recovery of legacy artifacts, but normal lock
# acquisition must fail closed instead of silently downgrading guarantees.
fallback_root="${tmp_dir}/fallback-main-lock"
mkdir -p "$fallback_root"
command_exists() {
    [ "$1" != flock ] && command -v "$1" >/dev/null 2>&1
}
fallback_status=0
acquire_proxy_transaction_lock "$fallback_root" || fallback_status=$?
[[ "$fallback_status" -eq 1 ]] || {
    echo "FAIL: missing flock returned ${fallback_status}, expected 1" >&2
    exit 1
}
[[ ! -e "${fallback_root}/.proxy-transaction.lock.d" ]] || {
    echo 'FAIL: upgraded acquisition created a legacy mkdir lock' >&2
    exit 1
}
command_exists() { command -v "$1" >/dev/null 2>&1; }

reaper_root="${tmp_dir}/reaper"
mkdir -p "$reaper_root"
reaper_lock="${reaper_root}/lock.d"
mkdir "$reaper_lock"
printf '%s\n' 99999999 > "$reaper_lock/owner"
reap_stale_proxy_transaction_lock "$reaper_lock" || {
    echo 'FAIL: a confirmed stale mkdir lock was not reaped' >&2
    exit 1
}
[[ ! -e "$reaper_lock" && ! -e "${reaper_lock}.reaper" ]] || {
    echo 'FAIL: stale-lock reaper left lock artifacts behind' >&2
    exit 1
}

mkdir "$reaper_lock"
printf '%s\n' "$BASHPID" > "$reaper_lock/owner"
if reap_stale_proxy_transaction_lock "$reaper_lock"; then
    echo 'FAIL: live mkdir lock owner was reaped' >&2
    exit 1
fi
[[ -d "$reaper_lock" ]] || {
    echo 'FAIL: live mkdir lock disappeared during reaper check' >&2
    exit 1
}
rm -rf -- "$reaper_lock"

# A reaper killed in the guard-initialization window leaves a directory with
# no owner.  After the short initialization grace expires, the next reaper
# must reclaim that orphan and continue with the stale main lock.
mkdir "$reaper_lock"
printf '%s\n' 99999999 > "$reaper_lock/owner"
guard_created_pause="${reaper_root}/guard-created-paused"
proxy_transaction_reaper_hook() {
    if [ "$1" = guard-created ]; then
        : > "$guard_created_pause"
        while :; do :; done
    fi
}
( PROXY_TX_REAPER_STALE_SECONDS=1 reap_stale_proxy_transaction_lock "$reaper_lock" ) &
guard_created_reaper=$!
for _ in $(seq 1 100); do
    [ -e "$guard_created_pause" ] && break
    sleep 0.01
done
[[ -e "$guard_created_pause" ]] || {
    echo 'FAIL: reaper did not reach the guard-created KILL boundary' >&2
    exit 1
}
kill -KILL "$guard_created_reaper"
guard_created_status=0
wait "$guard_created_reaper" || guard_created_status=$?
[[ "$guard_created_status" -eq 137 ]] || {
    echo "FAIL: guard-created KILL fixture returned ${guard_created_status}, expected 137" >&2
    exit 1
}
[[ -d "${reaper_lock}.reaper" && ! -e "${reaper_lock}.reaper/owner" ]] || {
    echo 'FAIL: guard-created KILL fixture did not leave the expected ownerless guard' >&2
    exit 1
}
sleep 1.1
proxy_transaction_reaper_hook() { :; }
PROXY_TX_REAPER_STALE_SECONDS=1 reap_stale_proxy_transaction_lock "$reaper_lock" || {
    echo 'FAIL: ownerless stale reaper guard was not recovered' >&2
    exit 1
}
[[ ! -e "$reaper_lock" && ! -e "${reaper_lock}.reaper" ]] || {
    echo 'FAIL: ownerless guard recovery left lock artifacts behind' >&2
    exit 1
}

# A reaper killed after publishing its owner must be recoverable immediately
# once that owner is confirmed dead.
mkdir "$reaper_lock"
printf '%s\n' 99999999 > "$reaper_lock/owner"
guard_owned_pause="${reaper_root}/guard-owned-paused"
proxy_transaction_reaper_hook() {
    if [ "$1" = acquired ]; then
        : > "$guard_owned_pause"
        while :; do :; done
    fi
}
( reap_stale_proxy_transaction_lock "$reaper_lock" ) & guard_owned_reaper=$!
for _ in $(seq 1 100); do
    [ -e "$guard_owned_pause" ] && break
    sleep 0.01
done
[[ -e "$guard_owned_pause" ]] || {
    echo 'FAIL: reaper did not reach the owned-guard KILL boundary' >&2
    exit 1
}
kill -KILL "$guard_owned_reaper"
guard_owned_status=0
wait "$guard_owned_reaper" || guard_owned_status=$?
[[ "$guard_owned_status" -eq 137 ]] || {
    echo "FAIL: owned-guard KILL fixture returned ${guard_owned_status}, expected 137" >&2
    exit 1
}
proxy_transaction_reaper_hook() { :; }
reap_stale_proxy_transaction_lock "$reaper_lock" || {
    echo 'FAIL: dead-owner reaper guard was not recovered' >&2
    exit 1
}
[[ ! -e "$reaper_lock" && ! -e "${reaper_lock}.reaper" ]] || {
    echo 'FAIL: dead-owner guard recovery left lock artifacts behind' >&2
    exit 1
}

# If KILL lands after deleting the stale main lock, the orphan guard must be
# reclaimed later without deleting a newly acquired live main lock.
mkdir "$reaper_lock"
printf '%s\n' 99999999 > "$reaper_lock/owner"
after_delete_kill_pause="${reaper_root}/after-delete-kill-paused"
proxy_transaction_reaper_hook() {
    if [ "$1" = after-delete ]; then
        : > "$after_delete_kill_pause"
        while :; do :; done
    fi
}
( reap_stale_proxy_transaction_lock "$reaper_lock" ) & after_delete_reaper=$!
for _ in $(seq 1 100); do
    [ -e "$after_delete_kill_pause" ] && break
    sleep 0.01
done
[[ -e "$after_delete_kill_pause" ]] || {
    echo 'FAIL: reaper did not reach the after-delete KILL boundary' >&2
    exit 1
}
kill -KILL "$after_delete_reaper"
after_delete_status=0
wait "$after_delete_reaper" || after_delete_status=$?
[[ "$after_delete_status" -eq 137 ]] || {
    echo "FAIL: after-delete KILL fixture returned ${after_delete_status}, expected 137" >&2
    exit 1
}
mkdir "$reaper_lock"
printf '%s\n' "$BASHPID" > "$reaper_lock/owner"
proxy_transaction_reaper_hook() { :; }
if reap_stale_proxy_transaction_lock "$reaper_lock"; then
    echo 'FAIL: guard recovery deleted a newly acquired live main lock' >&2
    exit 1
fi
[[ -d "$reaper_lock" && "$(<"$reaper_lock/owner")" = "$BASHPID" ]] || {
    echo 'FAIL: live main lock was damaged while recovering an orphan guard' >&2
    exit 1
}
[[ ! -e "${reaper_lock}.reaper" ]] || {
    echo 'FAIL: after-delete KILL recovery left the guard behind' >&2
    exit 1
}
rm -rf -- "$reaper_lock"

mkdir "$reaper_lock"
printf '%s\n' 99999999 > "$reaper_lock/owner"
reaper_pause="${reaper_root}/paused"
proxy_transaction_reaper_hook() {
    if [ "$1" = after-delete ] && [ ! -e "$reaper_pause" ]; then
        : > "$reaper_pause"
        sleep 0.2
    fi
}
( reap_stale_proxy_transaction_lock "$reaper_lock" ) & first_reaper=$!
for _ in $(seq 1 100); do
    [ -e "$reaper_pause" ] && break
    sleep 0.01
done
[[ -e "$reaper_pause" ]] || {
    echo 'FAIL: first reaper did not reach the deletion boundary' >&2
    exit 1
}
# A new owner may acquire the main lock while the independent reaper guard is
# still held.  A later reaper must re-read this live owner and leave it alone.
mkdir "$reaper_lock"
printf '%s\n' "$BASHPID" > "$reaper_lock/owner"
wait "$first_reaper" || {
    echo 'FAIL: first stale-lock reaper failed' >&2
    exit 1
}
if reap_stale_proxy_transaction_lock "$reaper_lock"; then
    echo 'FAIL: second reaper deleted a newly acquired live lock' >&2
    exit 1
fi
[[ -d "$reaper_lock" && "$(<"$reaper_lock/owner")" = "$BASHPID" ]] || {
    echo 'FAIL: new mkdir lock owner was lost in the double-reaper race' >&2
    exit 1
}
rm -rf -- "$reaper_lock"

echo 'Durable transaction signal tests passed.'
