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

for function_name in perform_singbox_uninstall; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    source <(printf '%s\n' "$function_source")
done

# Even after the sing-box/Argo unit files have disappeared, an explicit Nginx
# purge must stop Nginx through a verified init system before any configuration
# or recovery material is removed.
uninstall_root="${tmp_dir}/purge-stop-fail"
mkdir -p "${uninstall_root}/etc/nginx/conf.d" \
         "${uninstall_root}/etc/sing-box" \
         "${uninstall_root}/lib/systemd/system"
printf '%s\n' 'events {}' > "${uninstall_root}/etc/nginx/nginx.conf"
printf '%s\n' 'server {}' > "${uninstall_root}/etc/nginx/conf.d/sing-box.conf"
printf '%s\n' recovery > "${uninstall_root}/etc/sing-box/recovery.state"
printf '%s\n' unit > "${uninstall_root}/lib/systemd/system/nginx.service"

uninstall_log="${tmp_dir}/uninstall.log"
work_dir='/etc/sing-box'
detect_usable_init_system() { printf 'systemd\n'; }
command_exists() { [[ "$1" == nginx || "$1" == systemctl ]]; }
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$uninstall_log"
    [[ "$1 $2" != 'stop nginx' ]]
}
remove_hy2_port_hopping() { printf '%s\n' hy2-clean >> "$uninstall_log"; }
remove_managed_nginx_include() { printf '%s\n' nginx-main-clean >> "$uninstall_log"; }
remove_managed_singbox_link() { printf '%s\n' links-clean >> "$uninstall_log"; }
purge_nginx_package() { printf '%s\n' nginx-purge >> "$uninstall_log"; }
restart_nginx() { printf '%s\n' nginx-restart >> "$uninstall_log"; }
red() { :; }

if perform_singbox_uninstall "$uninstall_root" 1 >/dev/null 2>&1; then
    fail 'Nginx purge continued after stop failure'
fi
grep -Fqx 'systemctl stop nginx' "$uninstall_log" || \
    fail 'Nginx purge did not attempt an init-managed stop'
if grep -Eq 'hy2-clean|nginx-main-clean|links-clean|nginx-purge' "$uninstall_log"; then
    fail 'destructive cleanup ran after the Nginx stop failure'
fi
[[ -f "${uninstall_root}/etc/nginx/conf.d/sing-box.conf" ]] || \
    fail 'Nginx configuration was removed after stop failure'
[[ -f "${uninstall_root}/etc/sing-box/recovery.state" ]] || \
    fail 'recovery material was removed after stop failure'

printf 'Nginx purge safety tests passed.\n'
