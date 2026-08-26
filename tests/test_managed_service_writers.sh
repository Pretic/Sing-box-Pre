#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

failures=0

record_failure() {
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

load_if_present() {
    local function_source

    function_source="$(extract_function "$1")"
    [ -n "$function_source" ] || return 1
    source <(printf '%s\n' "$function_source")
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
    reset_stable_transaction_lock_state \
    acquire_stable_transaction_lock \
    release_stable_transaction_lock \
    with_stable_transaction_lock \
    atomic_write_secret_file \
    render_singbox_systemd_service \
    render_singbox_openrc_service \
    render_argo_systemd_service \
    render_argo_openrc_service \
    managed_service_definition_is_canonical \
    managed_service_target_fingerprint \
    managed_service_writer_hook \
    write_guarded_managed_service_definition_locked \
    write_guarded_managed_service_definition \
    write_singbox_systemd_service \
    write_singbox_openrc_service \
    write_argo_systemd_service \
    write_argo_openrc_service \
    main_systemd_services \
    alpine_openrc_services \
    run_install_flow \
    activate_argo_service_mode; do
    load_if_present "$function_name" || true
done

ARGO_PORT=18001
argo_port=18001
SING_BOX_TRANSACTION_ROOT="${tmp_root}/transaction-root"

RACE_ACTION=''
RACE_TARGET=''
RACE_EXPECTED=''
RACE_HOOK_CALLS=0
RACE_HOOK_LOCK_HELD=0
RACE_HOOK_STATUS=0
RACE_BEFORE_IDENTITY=''
RACE_AFTER_IDENTITY=''
RACE_BEFORE_SIZE=''
RACE_AFTER_SIZE=''
RACE_BEFORE_MODE=''
RACE_AFTER_MODE=''
RACE_BEFORE_NLINK=''
RACE_AFTER_NLINK=''
RACE_HARDLINK_PATH=''
RACE_SYMLINK_REFERENT=''
RACE_SYMLINK_VALUE=''

managed_service_writer_hook() {
    local event="${1:-}"

    [ "$event" = before-final-cas ] || return 0
    RACE_HOOK_CALLS=$((RACE_HOOK_CALLS + 1))
    if stable_transaction_lock_is_held mutation; then
        RACE_HOOK_LOCK_HELD=1
    fi
    case "$RACE_ACTION" in
        existing-replaced)
            printf '%s\n' 'foreign replacement created during writer CAS' > "${RACE_TARGET}.replacement"
            mv -f -- "${RACE_TARGET}.replacement" "$RACE_TARGET"
            cp -p -- "$RACE_TARGET" "$RACE_EXPECTED"
            ;;
        absent-appears)
            printf '%s\n' 'foreign target created during writer CAS' > "$RACE_TARGET"
            cp -p -- "$RACE_TARGET" "$RACE_EXPECTED"
            ;;
        same-inode-same-size)
            RACE_BEFORE_IDENTITY=$(stat -c '%d:%i' -- "$RACE_TARGET")
            RACE_BEFORE_SIZE=$(stat -c '%s' -- "$RACE_TARGET")
            printf '!' | dd of="$RACE_TARGET" bs=1 seek=0 conv=notrunc status=none
            RACE_AFTER_IDENTITY=$(stat -c '%d:%i' -- "$RACE_TARGET")
            RACE_AFTER_SIZE=$(stat -c '%s' -- "$RACE_TARGET")
            cp -p -- "$RACE_TARGET" "$RACE_EXPECTED"
            ;;
        identical-new-inode)
            RACE_BEFORE_IDENTITY=$(stat -c '%d:%i' -- "$RACE_TARGET")
            cp -p -- "$RACE_TARGET" "${RACE_TARGET}.replacement"
            mv -f -- "${RACE_TARGET}.replacement" "$RACE_TARGET"
            RACE_AFTER_IDENTITY=$(stat -c '%d:%i' -- "$RACE_TARGET")
            cp -p -- "$RACE_TARGET" "$RACE_EXPECTED"
            ;;
        mode-changed)
            RACE_BEFORE_IDENTITY=$(stat -c '%d:%i' -- "$RACE_TARGET")
            RACE_BEFORE_MODE=$(stat -c '%a' -- "$RACE_TARGET")
            chmod 600 "$RACE_TARGET"
            RACE_AFTER_IDENTITY=$(stat -c '%d:%i' -- "$RACE_TARGET")
            RACE_AFTER_MODE=$(stat -c '%a' -- "$RACE_TARGET")
            cp -p -- "$RACE_TARGET" "$RACE_EXPECTED"
            ;;
        hardlink-added)
            RACE_BEFORE_IDENTITY=$(stat -c '%d:%i' -- "$RACE_TARGET")
            RACE_BEFORE_NLINK=$(stat -c '%h' -- "$RACE_TARGET")
            ln "$RACE_TARGET" "$RACE_HARDLINK_PATH"
            RACE_AFTER_IDENTITY=$(stat -c '%d:%i' -- "$RACE_TARGET")
            RACE_AFTER_NLINK=$(stat -c '%h' -- "$RACE_TARGET")
            cp -p -- "$RACE_TARGET" "$RACE_EXPECTED"
            ;;
        target-becomes-symlink)
            printf '%s\n' 'foreign symlink referent created during writer CAS' > \
                "$RACE_SYMLINK_REFERENT"
            cp -p -- "$RACE_SYMLINK_REFERENT" "$RACE_EXPECTED"
            rm -f -- "$RACE_TARGET"
            ln -s "$RACE_SYMLINK_REFERENT" "$RACE_TARGET"
            RACE_SYMLINK_VALUE=$(readlink "$RACE_TARGET")
            ;;
    esac
    return "$RACE_HOOK_STATUS"
}

writer_function() {
    case "$1" in
        systemd-singbox) printf 'write_singbox_systemd_service\n' ;;
        openrc-singbox) printf 'write_singbox_openrc_service\n' ;;
        systemd-argo) printf 'write_argo_systemd_service\n' ;;
        openrc-argo) printf 'write_argo_openrc_service\n' ;;
        *) return 1 ;;
    esac
}

target_path() {
    local kind="$1" root="$2"

    case "$kind" in
        systemd-singbox) printf '%s/etc/systemd/system/sing-box.service\n' "$root" ;;
        systemd-argo) printf '%s/etc/systemd/system/argo.service\n' "$root" ;;
        openrc-singbox) printf '%s/etc/init.d/sing-box\n' "$root" ;;
        openrc-argo) printf '%s/etc/init.d/argo\n' "$root" ;;
        *) return 1 ;;
    esac
}

render_expected() {
    local kind="$1" output_file="$2"

    case "$kind" in
        systemd-singbox) render_singbox_systemd_service > "$output_file" ;;
        openrc-singbox) render_singbox_openrc_service > "$output_file" ;;
        systemd-argo) render_argo_systemd_service quick > "$output_file" ;;
        openrc-argo) render_argo_openrc_service quick > "$output_file" ;;
        *) return 1 ;;
    esac
}

invoke_writer() {
    local kind="$1" root="$2" writer

    writer=$(writer_function "$kind") || return 1
    declare -F "$writer" >/dev/null || return 127
    case "$kind" in
        systemd-singbox|openrc-singbox) "$writer" "$root" ;;
        systemd-argo|openrc-argo) "$writer" quick "$root" ;;
        *) return 1 ;;
    esac
}

expected_mode() {
    case "$1" in
        systemd-*) printf '644\n' ;;
        openrc-*) printf '700\n' ;;
        *) return 1 ;;
    esac
}

capture_writer_status() {
    local kind="$1" root="$2"

    set +e
    invoke_writer "$kind" "$root"
    WRITER_STATUS=$?
    set -e
}

assert_no_writer_temp_files() {
    local target_dir="$1"

    if find "$target_dir" -maxdepth 1 -type f -name '.*managed-service*' -print -quit | grep -q .; then
        record_failure "managed service writer left a temporary file in ${target_dir}"
    fi
}

run_writer_contract() {
    local kind="$1" writer root target expected preimage mode link_target link_value

    writer=$(writer_function "$kind") || {
        record_failure "unknown writer kind ${kind}"
        return
    }
    if ! declare -F "$writer" >/dev/null; then
        record_failure "${writer} is not implemented"
        return
    fi

    root="${tmp_root}/${kind}/missing"
    target=$(target_path "$kind" "$root")
    mkdir -p "$(dirname "$target")"
    expected="${root}/expected"
    render_expected "$kind" "$expected" || record_failure "${kind} expected renderer failed"
    capture_writer_status "$kind" "$root"
    [ "$WRITER_STATUS" -eq 0 ] || record_failure "${kind} missing target returned rc=${WRITER_STATUS}"
    [ -f "$target" ] && [ ! -L "$target" ] || record_failure "${kind} missing target was not created as a regular file"
    cmp -s "$expected" "$target" || record_failure "${kind} missing target is not canonical"
    mode=$(stat -c '%a' "$target" 2>/dev/null || true)
    [ "$mode" = "$(expected_mode "$kind")" ] || record_failure "${kind} missing target mode is ${mode}"
    assert_no_writer_temp_files "$(dirname "$target")"

    root="${tmp_root}/${kind}/exact"
    target=$(target_path "$kind" "$root")
    mkdir -p "$(dirname "$target")"
    expected="${root}/expected"
    render_expected "$kind" "$expected" || record_failure "${kind} exact renderer failed"
    cp "$expected" "$target"
    chmod "$(expected_mode "$kind")" "$target"
    capture_writer_status "$kind" "$root"
    [ "$WRITER_STATUS" -eq 0 ] || record_failure "${kind} exact managed target returned rc=${WRITER_STATUS}"
    cmp -s "$expected" "$target" || record_failure "${kind} idempotent write changed canonical bytes"
    [ "$(stat -c '%a' "$target")" = "$(expected_mode "$kind")" ] || \
        record_failure "${kind} idempotent write has the wrong mode"

    root="${tmp_root}/${kind}/foreign"
    target=$(target_path "$kind" "$root")
    mkdir -p "$(dirname "$target")"
    printf 'foreign service bytes for %s\n' "$kind" > "$target"
    chmod 640 "$target"
    preimage="${root}/preimage"
    cp -p "$target" "$preimage"
    capture_writer_status "$kind" "$root"
    [ "$WRITER_STATUS" -eq 1 ] || record_failure "${kind} foreign target returned rc=${WRITER_STATUS}, expected rc=1"
    cmp -s "$preimage" "$target" || record_failure "${kind} foreign target bytes were overwritten"
    [ "$(stat -c '%a' "$target")" = 640 ] || record_failure "${kind} foreign target mode changed"

    root="${tmp_root}/${kind}/symlink"
    target=$(target_path "$kind" "$root")
    mkdir -p "$(dirname "$target")"
    link_target="${root}/foreign-link-target"
    printf 'foreign link target bytes for %s\n' "$kind" > "$link_target"
    preimage="${root}/link-preimage"
    cp -p "$link_target" "$preimage"
    ln -s "$link_target" "$target"
    link_value=$(readlink "$target")
    capture_writer_status "$kind" "$root"
    [ "$WRITER_STATUS" -eq 1 ] || record_failure "${kind} symlink target returned rc=${WRITER_STATUS}, expected rc=1"
    [ -L "$target" ] || record_failure "${kind} symlink was replaced"
    [ "$(readlink "$target" 2>/dev/null || true)" = "$link_value" ] || record_failure "${kind} symlink destination changed"
    cmp -s "$preimage" "$link_target" || record_failure "${kind} symlink referent bytes were overwritten"
}

for writer_kind in systemd-singbox openrc-singbox systemd-argo openrc-argo; do
    run_writer_contract "$writer_kind"
done

run_writer_race_case() {
    local race_action="$1" race_root target

    race_root="${tmp_root}/writer-race-${race_action}"
    target=$(target_path systemd-singbox "$race_root")
    mkdir -p "$(dirname "$target")"
    if [ "$race_action" != absent-appears ]; then
        render_singbox_systemd_service > "$target"
    fi
    if [ "$race_action" = mode-changed ]; then
        chmod 644 "$target"
    fi

    RACE_ACTION="$race_action"
    RACE_TARGET="$target"
    RACE_EXPECTED="${race_root}/expected-foreign"
    RACE_HOOK_CALLS=0
    RACE_HOOK_LOCK_HELD=0
    RACE_BEFORE_IDENTITY=''
    RACE_AFTER_IDENTITY=''
    RACE_BEFORE_SIZE=''
    RACE_AFTER_SIZE=''
    RACE_BEFORE_MODE=''
    RACE_AFTER_MODE=''
    RACE_BEFORE_NLINK=''
    RACE_AFTER_NLINK=''
    RACE_HARDLINK_PATH="${race_root}/foreign-hardlink"
    RACE_HOOK_STATUS=0
    if [ "$race_action" = hook-fails ]; then
        cp -p -- "$target" "$RACE_EXPECTED"
        RACE_HOOK_STATUS=2
    fi
    capture_writer_status systemd-singbox "$race_root"

    [ "$WRITER_STATUS" -eq 2 ] || \
        record_failure "${race_action} returned rc=${WRITER_STATUS}, expected rc=2"
    [ "$RACE_HOOK_CALLS" -eq 1 ] || \
        record_failure "${race_action} did not reach the before-final-cas hook exactly once"
    [ "$RACE_HOOK_LOCK_HELD" -eq 1 ] || \
        record_failure "${race_action} hook ran without the mutation lock"
    [ -f "$RACE_EXPECTED" ] && cmp -s -- "$RACE_EXPECTED" "$target" || \
        record_failure "${race_action} did not preserve the exact foreign target"
    case "$race_action" in
        same-inode-same-size)
            [ -n "$RACE_BEFORE_IDENTITY" ] && \
                [ "$RACE_BEFORE_IDENTITY" = "$RACE_AFTER_IDENTITY" ] || \
                record_failure 'same-inode race did not preserve the target inode'
            [ -n "$RACE_BEFORE_SIZE" ] && [ "$RACE_BEFORE_SIZE" = "$RACE_AFTER_SIZE" ] || \
                record_failure 'same-size race did not preserve the target size'
            ;;
        identical-new-inode)
            [ -n "$RACE_BEFORE_IDENTITY" ] && [ -n "$RACE_AFTER_IDENTITY" ] && \
                [ "$RACE_BEFORE_IDENTITY" != "$RACE_AFTER_IDENTITY" ] || \
                record_failure 'identical-byte replacement did not use a new inode'
            [ "$(stat -c '%d:%i' -- "$target" 2>/dev/null || true)" = \
                "$RACE_AFTER_IDENTITY" ] || \
                record_failure 'identical-byte replacement inode was overwritten'
            ;;
        mode-changed)
            [ "$RACE_BEFORE_IDENTITY" = "$RACE_AFTER_IDENTITY" ] || \
                record_failure 'mode race unexpectedly changed the target inode'
            [ "$RACE_BEFORE_MODE" = 644 ] && [ "$RACE_AFTER_MODE" = 600 ] || \
                record_failure 'mode race did not perform the expected chmod'
            [ "$(stat -c '%a' -- "$target" 2>/dev/null || true)" = \
                "$RACE_AFTER_MODE" ] || \
                record_failure 'mode race external mode was overwritten'
            ;;
        hardlink-added)
            [ "$RACE_BEFORE_IDENTITY" = "$RACE_AFTER_IDENTITY" ] || \
                record_failure 'hardlink race unexpectedly changed the target inode'
            [ "$RACE_BEFORE_NLINK" = 1 ] && [ "$RACE_AFTER_NLINK" = 2 ] || \
                record_failure 'hardlink race did not change nlink from one to two'
            [ -f "$RACE_HARDLINK_PATH" ] && \
                [ "$(stat -c '%d:%i' -- "$target" 2>/dev/null || true)" = \
                    "$(stat -c '%d:%i' -- "$RACE_HARDLINK_PATH" 2>/dev/null || true)" ] && \
                [ "$(stat -c '%h' -- "$target" 2>/dev/null || true)" = 2 ] || \
                record_failure 'hardlink race external link state was overwritten'
            cmp -s -- "$RACE_EXPECTED" "$RACE_HARDLINK_PATH" || \
                record_failure 'hardlink race changed the external hardlink bytes'
            ;;
    esac
    assert_no_writer_temp_files "$(dirname "$target")"

    RACE_ACTION=''
    RACE_TARGET=''
    RACE_EXPECTED=''
    RACE_HARDLINK_PATH=''
    RACE_HOOK_STATUS=0
}

run_writer_race_case existing-replaced
run_writer_race_case absent-appears
run_writer_race_case same-inode-same-size
run_writer_race_case identical-new-inode
run_writer_race_case mode-changed
run_writer_race_case hardlink-added
run_writer_race_case hook-fails

run_symlink_race_test() {
    local race_root="${tmp_root}/writer-race-target-becomes-symlink"
    local target

    target=$(target_path systemd-singbox "$race_root")
    mkdir -p "$(dirname "$target")"
    render_singbox_systemd_service > "$target"
    RACE_ACTION=target-becomes-symlink
    RACE_TARGET="$target"
    RACE_EXPECTED="${race_root}/expected-referent"
    RACE_SYMLINK_REFERENT="${race_root}/foreign-referent"
    RACE_SYMLINK_VALUE=''
    RACE_HOOK_CALLS=0
    RACE_HOOK_LOCK_HELD=0
    RACE_HOOK_STATUS=0

    capture_writer_status systemd-singbox "$race_root"

    [ "$WRITER_STATUS" -eq 2 ] || \
        record_failure "symlink race returned rc=${WRITER_STATUS}, expected rc=2"
    [ "$RACE_HOOK_CALLS" -eq 1 ] && [ "$RACE_HOOK_LOCK_HELD" -eq 1 ] || \
        record_failure 'symlink race hook did not run once under the mutation lock'
    [ -L "$target" ] || record_failure 'symlink race target was overwritten'
    [ "$(readlink "$target" 2>/dev/null || true)" = "$RACE_SYMLINK_VALUE" ] || \
        record_failure 'symlink race changed the foreign link destination'
    [ -f "$RACE_EXPECTED" ] && \
        cmp -s -- "$RACE_EXPECTED" "$RACE_SYMLINK_REFERENT" || \
        record_failure 'symlink race changed the foreign referent bytes'
    assert_no_writer_temp_files "$(dirname "$target")"

    RACE_ACTION=''
    RACE_TARGET=''
    RACE_EXPECTED=''
    RACE_SYMLINK_REFERENT=''
    RACE_SYMLINK_VALUE=''
}

run_symlink_race_test

run_canonical_validation_race_test() {
    local race_root="${tmp_root}/canonical-validation-race"
    local target expected original_validator_source status
    local replacement_identity='' validator_calls=0

    target=$(target_path systemd-singbox "$race_root")
    mkdir -p "$(dirname "$target")"
    render_singbox_systemd_service > "$target"
    expected="${race_root}/expected"
    printf '%s\n' 'foreign replacement during canonical validation' > "$expected"
    original_validator_source=$(declare -f managed_service_definition_is_canonical)
    eval "$(printf '%s\n' "$original_validator_source" | \
        sed '1s/managed_service_definition_is_canonical/managed_service_definition_is_canonical_original/')"
    managed_service_definition_is_canonical() {
        validator_calls=$((validator_calls + 1))
        if [ "$1" = "$target" ] && [ "$validator_calls" -eq 1 ]; then
            cp -p -- "$expected" "${target}.replacement"
            mv -f -- "${target}.replacement" "$target"
            replacement_identity=$(stat -c '%d:%i' -- "$target")
            return 1
        fi
        managed_service_definition_is_canonical_original "$@"
    }
    RACE_ACTION=''
    RACE_HOOK_CALLS=0
    set +e
    write_singbox_systemd_service "$race_root"
    status=$?
    set -e
    unset -f managed_service_definition_is_canonical
    eval "$original_validator_source"
    unset -f managed_service_definition_is_canonical_original

    [ "$status" -eq 2 ] || \
        record_failure "canonical-validation race returned rc=${status}, expected rc=2"
    [ -n "$replacement_identity" ] && \
        [ "$(stat -c '%d:%i' -- "$target" 2>/dev/null || true)" = "$replacement_identity" ] || \
        record_failure 'canonical-validation race replacement inode was overwritten'
    cmp -s -- "$expected" "$target" || \
        record_failure 'canonical-validation race changed foreign bytes'
    [ "$RACE_HOOK_CALLS" -eq 0 ] || \
        record_failure 'canonical-validation race continued to the final CAS hook'
    assert_no_writer_temp_files "$(dirname "$target")"
}

run_fingerprint_failure_test() {
    local fingerprint_root="${tmp_root}/fingerprint-failure"
    local target expected fake_bin status

    target=$(target_path systemd-singbox "$fingerprint_root")
    mkdir -p "$(dirname "$target")"
    render_singbox_systemd_service > "$target"
    expected="${fingerprint_root}/expected"
    cp -p -- "$target" "$expected"
    fake_bin="${fingerprint_root}/bin"
    mkdir -p "$fake_bin"
    printf '%s\n' '#!/bin/sh' 'exit 1' > "${fake_bin}/sha256sum"
    chmod 700 "${fake_bin}/sha256sum"
    RACE_ACTION=''
    RACE_HOOK_CALLS=0
    set +e
    PATH="${fake_bin}:$PATH" write_singbox_systemd_service "$fingerprint_root"
    status=$?
    set -e

    [ "$status" -eq 2 ] || \
        record_failure "fingerprint command failure returned rc=${status}, expected rc=2"
    cmp -s -- "$expected" "$target" || \
        record_failure 'fingerprint command failure changed the target'
    [ "$RACE_HOOK_CALLS" -eq 0 ] || \
        record_failure 'fingerprint command failure continued to the final CAS hook'
    assert_no_writer_temp_files "$(dirname "$target")"
}

run_all_writer_rc2_test() {
    local kind writer_root target expected status

    for kind in systemd-singbox openrc-singbox systemd-argo openrc-argo; do
        writer_root="${tmp_root}/all-writer-race-${kind}"
        target=$(target_path "$kind" "$writer_root")
        mkdir -p "$(dirname "$target")"
        expected="${writer_root}/expected-foreign"
        RACE_ACTION=absent-appears
        RACE_TARGET="$target"
        RACE_EXPECTED="$expected"
        RACE_HOOK_CALLS=0
        RACE_HOOK_LOCK_HELD=0
        RACE_HOOK_STATUS=0
        capture_writer_status "$kind" "$writer_root"
        status=$WRITER_STATUS
        [ "$status" -eq 2 ] || \
            record_failure "${kind} CAS conflict returned rc=${status}, expected rc=2"
        [ "$RACE_HOOK_CALLS" -eq 1 ] && [ "$RACE_HOOK_LOCK_HELD" -eq 1 ] || \
            record_failure "${kind} CAS hook did not run once under the mutation lock"
        [ -f "$expected" ] && cmp -s -- "$expected" "$target" || \
            record_failure "${kind} CAS conflict did not preserve foreign bytes"
        [ "${STABLE_TX_MUTATION_DEPTH:-0}" -eq 0 ] && \
            [ -z "${STABLE_TX_MUTATION_FD:-}" ] || \
            record_failure "${kind} CAS conflict leaked the mutation lock"
        assert_no_writer_temp_files "$(dirname "$target")"
    done
    RACE_ACTION=''
    RACE_TARGET=''
    RACE_EXPECTED=''
}

run_writer_release_failure_test() {
    local release_root="${tmp_root}/writer-release-failure"
    local committed_target="${release_root}/committed.service"
    local failed_target="${release_root}/failed.service"
    local expected status original_lock_hook_source

    mkdir -p "$release_root"
    expected="${release_root}/expected"
    render_singbox_systemd_service > "$expected"
    original_lock_hook_source=$(declare -f stable_transaction_lock_hook)
    stable_transaction_lock_hook() {
        if [ "${1:-}" = released ] && [ "${2:-}" = mutation ]; then
            return 2
        fi
        return 0
    }
    RACE_ACTION=''
    set +e
    write_guarded_managed_service_definition "$committed_target" 644 \
        systemd-singbox render_singbox_systemd_service
    status=$?
    set -e
    [ "$status" -eq 2 ] || \
        record_failure "committed writer release failure returned rc=${status}, expected rc=2"
    cmp -s -- "$expected" "$committed_target" || \
        record_failure 'writer release failure lost the already committed definition'
    [ "${STABLE_TX_MUTATION_DEPTH:-0}" -eq 0 ] && \
        [ -z "${STABLE_TX_MUTATION_FD:-}" ] || \
        record_failure 'committed writer release failure leaked the mutation lock'
    assert_no_writer_temp_files "$release_root"

    release_failure_renderer() { printf '%s\n' partial; return 1; }
    set +e
    write_guarded_managed_service_definition "$failed_target" 644 \
        systemd-singbox release_failure_renderer
    status=$?
    set -e
    [ "$status" -eq 2 ] || \
        record_failure "failed writer plus release failure returned rc=${status}, expected rc=2"
    [ ! -e "$failed_target" ] && [ ! -L "$failed_target" ] || \
        record_failure 'failed writer plus release failure created a target'
    [ "${STABLE_TX_MUTATION_DEPTH:-0}" -eq 0 ] && \
        [ -z "${STABLE_TX_MUTATION_FD:-}" ] || \
        record_failure 'failed writer release failure leaked the mutation lock'
    assert_no_writer_temp_files "$release_root"

    unset -f stable_transaction_lock_hook
    eval "$original_lock_hook_source"
    reset_stable_transaction_lock_state || \
        record_failure 'could not reset lock state after writer release failure test'
}

run_writer_cleanup_failure_tests() {
    local injected_stage='' injected_rm_failure=0 injected_target=''
    local injected_target_dir=''

    chmod() {
        if [ "$#" -eq 2 ] && \
           [[ "$2" == "${injected_target_dir}/.managed-service.sing-box.service."* ]]; then
            if [ "$injected_stage" = initial-chmod ] && [ "$1" = 600 ]; then
                return 1
            fi
            if [ "$injected_stage" = final-chmod ] && [ "$1" = 644 ]; then
                return 1
            fi
        fi
        command chmod "$@"
    }
    mv() {
        if [ "$injected_stage" = mv ] && [ "$#" -eq 4 ] && \
           [[ "$3" == "${injected_target_dir}/.managed-service.sing-box.service."* ]] && \
           [ "$4" = "$injected_target" ]; then
            return 1
        fi
        command mv "$@"
    }
    rm() {
        if [ "$injected_rm_failure" -eq 1 ] && [ "$#" -eq 3 ] && \
           [[ "$3" == "${injected_target_dir}/.managed-service.sing-box.service."* ]]; then
            return 1
        fi
        command rm "$@"
    }

    run_writer_cleanup_failure_case() {
        local stage="$1" cleanup_failure="$2"
        local cleanup_root="${tmp_root}/writer-cleanup-${stage}-${cleanup_failure}"
        local expected_status=1 status neighbor
        local -a residue=()

        injected_stage="$stage"
        injected_rm_failure="$cleanup_failure"
        injected_target=$(target_path systemd-singbox "$cleanup_root")
        injected_target_dir=$(dirname "$injected_target")
        mkdir -p "$injected_target_dir"
        neighbor="${injected_target_dir}/foreign-neighbor"
        printf '%s\n' 'foreign neighbor must survive writer cleanup' > "$neighbor"
        [ "$cleanup_failure" -eq 0 ] || expected_status=2

        set +e
        write_singbox_systemd_service "$cleanup_root"
        status=$?
        set -e

        [ "$status" -eq "$expected_status" ] || \
            record_failure "${stage} with rm-failure=${cleanup_failure} returned rc=${status}, expected rc=${expected_status}"
        [ ! -e "$injected_target" ] && [ ! -L "$injected_target" ] || \
            record_failure "${stage} failure created the canonical target"
        grep -Fqx 'foreign neighbor must survive writer cleanup' "$neighbor" || \
            record_failure "${stage} cleanup changed a foreign neighbor"
        mapfile -t residue < <(
            find "$injected_target_dir" -maxdepth 1 -type f \
                -name '.managed-service.sing-box.service.*' -print
        )
        if [ "$cleanup_failure" -eq 0 ]; then
            [ "${#residue[@]}" -eq 0 ] || \
                record_failure "${stage} normal cleanup left a writer temporary file"
        else
            [ "${#residue[@]}" -eq 1 ] || \
                record_failure "${stage} injected rm failure did not retain exactly one writer temporary file"
            if [ "${#residue[@]}" -eq 1 ]; then
                command rm -f -- "${residue[0]}"
            fi
        fi
        [ "${STABLE_TX_MUTATION_DEPTH:-0}" -eq 0 ] && \
            [ -z "${STABLE_TX_MUTATION_FD:-}" ] || \
            record_failure "${stage} cleanup failure leaked the mutation lock"
    }

    for injected_stage in initial-chmod final-chmod mv; do
        run_writer_cleanup_failure_case "$injected_stage" 0
        run_writer_cleanup_failure_case "$injected_stage" 1
    done
    unset -f chmod mv rm run_writer_cleanup_failure_case
}

run_canonical_validation_race_test
run_fingerprint_failure_test
run_all_writer_rc2_test
run_writer_release_failure_test
run_writer_cleanup_failure_tests

if ! declare -F write_guarded_managed_service_definition_locked >/dev/null; then
    record_failure 'write_guarded_managed_service_definition_locked is not implemented'
else
    unlocked_root="${tmp_root}/unlocked-helper"
    unlocked_target="${unlocked_root}/sing-box.service"
    mkdir -p "$unlocked_root"
    set +e
    write_guarded_managed_service_definition_locked "$unlocked_target" 644 \
        systemd-singbox render_singbox_systemd_service
    unlocked_status=$?
    set -e
    [ "$unlocked_status" -eq 2 ] || \
        record_failure "locked writer without mutation lock returned rc=${unlocked_status}, expected rc=2"
    [ ! -e "$unlocked_target" ] && [ ! -L "$unlocked_target" ] || \
        record_failure 'locked writer without mutation lock changed its target'
    assert_no_writer_temp_files "$unlocked_root"
fi

run_nested_mutation_writer_test() {
    local nested_root="${tmp_root}/nested-mutation"
    local nested_status release_status=0

    reset_stable_transaction_lock_state || {
        record_failure 'could not reset stable lock state before nested writer test'
        return
    }
    acquire_stable_transaction_lock mutation 1 || {
        record_failure 'could not acquire outer mutation lock for nested writer test'
        return
    }
    RACE_ACTION=observe-only
    RACE_HOOK_CALLS=0
    RACE_HOOK_LOCK_HELD=0
    capture_writer_status systemd-singbox "$nested_root"
    nested_status=$WRITER_STATUS
    [ "$nested_status" -eq 0 ] || \
        record_failure "nested mutation writer returned rc=${nested_status}"
    [ "$RACE_HOOK_CALLS" -eq 1 ] && [ "$RACE_HOOK_LOCK_HELD" -eq 1 ] || \
        record_failure 'nested mutation writer did not run its hook under the held lock'
    [ "${STABLE_TX_MUTATION_DEPTH:-0}" -eq 1 ] || \
        record_failure 'nested mutation writer did not restore the outer lock depth'
    release_stable_transaction_lock mutation || release_status=$?
    [ "$release_status" -eq 0 ] && [ "${STABLE_TX_MUTATION_DEPTH:-0}" -eq 0 ] || \
        record_failure 'nested mutation writer leaked the outer mutation lock'
    RACE_ACTION=''
}

run_lock_contention_writer_test() {
    local contention_root="${tmp_root}/writer-lock-contention"
    local contention_target="${contention_root}/sing-box.service"
    local lock_path ready_file release_file holder_pid status renderer_calls=0 attempt

    ensure_stable_transaction_root || {
        record_failure 'could not initialize the stable lock root for contention test'
        return
    }
    lock_path=$(stable_transaction_lock_path mutation) || {
        record_failure 'could not resolve the mutation lock path for contention test'
        return
    }
    mkdir -p "$contention_root"
    ready_file="${contention_root}/holder.ready"
    release_file="${contention_root}/holder.release"
    (
        exec 9>>"$lock_path"
        flock -x 9
        : > "$ready_file"
        while [ ! -e "$release_file" ]; do sleep 0.01; done
    ) &
    holder_pid=$!
    for ((attempt=0; attempt < 500; attempt++)); do
        [ -e "$ready_file" ] && break
        sleep 0.01
    done
    if [ ! -e "$ready_file" ]; then
        record_failure 'mutation lock holder did not become ready'
        : > "$release_file"
        wait "$holder_pid" || true
        return
    fi

    contention_renderer() {
        renderer_calls=$((renderer_calls + 1))
        render_singbox_systemd_service
    }
    STABLE_TRANSACTION_LOCK_TIMEOUT_SECONDS=0
    set +e
    write_guarded_managed_service_definition "$contention_target" 644 \
        systemd-singbox contention_renderer
    status=$?
    set -e
    unset STABLE_TRANSACTION_LOCK_TIMEOUT_SECONDS
    : > "$release_file"
    wait "$holder_pid" || record_failure 'mutation lock holder exited unexpectedly'

    [ "$status" -eq 1 ] || \
        record_failure "contended public writer returned rc=${status}, expected rc=1"
    [ "$renderer_calls" -eq 0 ] || \
        record_failure 'contended public writer invoked the renderer without the lock'
    [ ! -e "$contention_target" ] && [ ! -L "$contention_target" ] || \
        record_failure 'contended public writer changed its target'
    assert_no_writer_temp_files "$contention_root"
}

run_service_builder_rc2_case() (
    local backend="$1" fail_at="$2" status actual_log
    local case_log="${tmp_root}/builder-${backend}-${fail_at}.log"

    : > "$case_log"
    ARGO_DOMAIN=''
    ARGO_AUTH=''
    ARGO_FIXED_READY=0
    write_singbox_systemd_service() {
        printf '%s\n' singbox >> "$case_log"
        [ "$fail_at" != singbox ] || return 2
    }
    write_singbox_openrc_service() { write_singbox_systemd_service; }
    write_argo_systemd_service() {
        printf '%s\n' argo >> "$case_log"
        [ "$fail_at" != argo ] || return 2
    }
    write_argo_openrc_service() { write_argo_systemd_service "$@"; }
    yellow() { :; }

    if [ "$backend" = systemd ]; then
        if main_systemd_services; then status=0; else status=$?; fi
    else
        if alpine_openrc_services; then status=0; else status=$?; fi
    fi
    actual_log=$(paste -sd, -- "$case_log")
    [ "$status" -eq 2 ] || return 1
    if [ "$fail_at" = singbox ]; then
        [ "$actual_log" = singbox ]
    else
        [ "$actual_log" = singbox,argo ]
    fi
)

run_activate_rc2_case() (
    local backend="$1" status actual_log
    local case_log="${tmp_root}/activate-${backend}.log"

    : > "$case_log"
    write_argo_systemd_service() { printf '%s\n' writer >> "$case_log"; return 2; }
    write_argo_openrc_service() { printf '%s\n' writer >> "$case_log"; return 2; }
    systemctl() { printf 'systemctl %s\n' "$*" >> "$case_log"; }
    chmod() { printf 'chmod %s\n' "$*" >> "$case_log"; }
    rc-update() { printf 'rc-update %s\n' "$*" >> "$case_log"; }
    restart_argo() { printf '%s\n' restart >> "$case_log"; }

    if activate_argo_service_mode quick "$backend" "${tmp_root}/activate-root"; then
        status=0
    else
        status=$?
    fi
    actual_log=$(paste -sd, -- "$case_log")
    [ "$status" -eq 2 ] && [ "$actual_log" = writer ]
)

run_install_flow_rc2_case() (
    local backend="$1" status
    local case_log="${tmp_root}/install-flow-${backend}.log"

    : > "$case_log"
    detect_usable_init_system() { printf '%s\n' "$backend"; }
    clear_install_complete_marker() { :; }
    manage_packages() { :; }
    prepare_partial_install_resume() { return 1; }
    install_singbox() { FIREWALL_LAST_ADDED_RECORDS=(); }
    validate_singbox_config() { :; }
    main_systemd_services() { printf '%s\n' service >> "$case_log"; return 2; }
    alpine_openrc_services() { printf '%s\n' service >> "$case_log"; return 2; }
    persist_partial_install_resume_state() { printf '%s\n' persist >> "$case_log"; }
    enable_install_services() { printf '%s\n' enable >> "$case_log"; }
    start_pending_install_services() { printf '%s\n' start >> "$case_log"; }
    change_hosts() { printf '%s\n' hosts >> "$case_log"; }
    sleep() { printf '%s\n' sleep >> "$case_log"; }
    add_nginx_conf() { printf '%s\n' nginx >> "$case_log"; }
    get_info() { printf '%s\n' info >> "$case_log"; }
    create_shortcut() { printf '%s\n' shortcut >> "$case_log"; }
    mark_install_complete() { printf '%s\n' complete >> "$case_log"; }
    red() { :; }
    yellow() { :; }
    FIREWALL_LAST_ADDED_RECORDS=()

    if run_install_flow; then status=0; else status=$?; fi
    [ "$status" -eq 2 ] || return 1
    [ "$(cat "$case_log")" = service ]
)

run_nested_mutation_writer_test
run_lock_contention_writer_test
for backend in systemd openrc; do
    for fail_at in singbox argo; do
        run_service_builder_rc2_case "$backend" "$fail_at" || \
            record_failure "${backend} service builder did not preserve ${fail_at} writer rc=2"
    done
    run_activate_rc2_case "$backend" || \
        record_failure "${backend} Argo activation did not stop and preserve writer rc=2"
    run_install_flow_rc2_case "$backend" || \
        record_failure "${backend} install flow did not stop and preserve service-builder rc=2"
done

# Managed Argo definitions must remain switchable between canonical modes.
for writer_kind in systemd-argo openrc-argo; do
    transition_root="${tmp_root}/${writer_kind}/managed-transition"
    transition_target=$(target_path "$writer_kind" "$transition_root")
    mkdir -p "$(dirname "$transition_target")"
    if [ "$writer_kind" = systemd-argo ]; then
        render_argo_systemd_service token > "$transition_target"
    else
        render_argo_openrc_service token > "$transition_target"
        chmod 700 "$transition_target"
    fi
    capture_writer_status "$writer_kind" "$transition_root"
    [ "$WRITER_STATUS" -eq 0 ] || record_failure "${writer_kind} rejected a canonical mode transition"
done

# A renderer that emits partial bytes and fails must not truncate an existing
# managed target or leave a new/temporary target behind.
if ! declare -F write_guarded_managed_service_definition >/dev/null; then
    record_failure 'write_guarded_managed_service_definition is not implemented'
else
    partial_renderer() { printf 'partial service bytes\n'; return 1; }
    guarded_root="${tmp_root}/guarded-renderer-failure"
    guarded_target="${guarded_root}/sing-box.service"
    mkdir -p "$guarded_root"
    render_singbox_systemd_service > "$guarded_target"
    cp -p "$guarded_target" "${guarded_root}/preimage"
    set +e
    write_guarded_managed_service_definition "$guarded_target" 644 \
        systemd-singbox partial_renderer
    guarded_status=$?
    set -e
    [ "$guarded_status" -eq 1 ] || record_failure "guarded renderer failure returned rc=${guarded_status}, expected rc=1"
    cmp -s "${guarded_root}/preimage" "$guarded_target" || \
        record_failure 'guarded renderer failure truncated the existing target'
    assert_no_writer_temp_files "$guarded_root"

    missing_guarded_target="${guarded_root}/missing.service"
    set +e
    write_guarded_managed_service_definition "$missing_guarded_target" 644 \
        systemd-singbox partial_renderer
    guarded_status=$?
    set -e
    [ "$guarded_status" -eq 1 ] || record_failure "missing guarded renderer failure returned rc=${guarded_status}, expected rc=1"
    [ ! -e "$missing_guarded_target" ] && [ ! -L "$missing_guarded_target" ] || \
        record_failure 'guarded renderer failure left a partial target'
    assert_no_writer_temp_files "$guarded_root"
fi

main_systemd_source="$(extract_function main_systemd_services)"
alpine_openrc_source="$(extract_function alpine_openrc_services)"
grep -Fq 'write_singbox_systemd_service' <<< "$main_systemd_source" || \
    record_failure 'main_systemd_services bypasses the guarded sing-box writer'
grep -Fq 'write_singbox_openrc_service' <<< "$alpine_openrc_source" || \
    record_failure 'alpine_openrc_services bypasses the guarded sing-box writer'
if grep -Fq 'render_singbox_systemd_service > /etc/systemd/system/sing-box.service' <<< "$main_systemd_source"; then
    record_failure 'main_systemd_services still truncates the sing-box unit directly'
fi
if grep -Fq 'render_singbox_openrc_service > /etc/init.d/sing-box' <<< "$alpine_openrc_source"; then
    record_failure 'alpine_openrc_services still truncates the sing-box init script directly'
fi

[ "$failures" -eq 0 ] || exit 1
printf 'Managed service writer tests passed.\n'
