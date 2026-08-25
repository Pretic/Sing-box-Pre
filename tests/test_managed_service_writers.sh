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
    atomic_write_secret_file \
    render_singbox_systemd_service \
    render_singbox_openrc_service \
    render_argo_systemd_service \
    render_argo_openrc_service \
    managed_service_definition_is_canonical \
    write_guarded_managed_service_definition \
    write_singbox_systemd_service \
    write_singbox_openrc_service \
    write_argo_systemd_service \
    write_argo_openrc_service; do
    load_if_present "$function_name" || true
done

ARGO_PORT=18001
argo_port=18001

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
