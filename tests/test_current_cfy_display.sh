#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for name in change_argo_domain change_argo_transition_subscription check_nodes \
    show_current_cfy_results show_current_cfy_results_locked \
    select_cfy_subscription_source_locked get_base_subscription_generation_locked \
    read_strict_subscription_generation_file; do
    source /dev/stdin <<< "$(sed -n "/^${name}() {/,/^}/p" "$script")"
done
work_dir="$tmp_root"
client_dir="$work_dir/url.txt"
CFY_SOURCE_GENERATION_FILE="$work_dir/cfy-source.generation"
ArgoDomain=new.example.com
purple=''; re=''
green() { printf '%b\n' "$*"; }
yellow() { printf '%b\n' "$*"; }
red() { printf '%b\n' "$*"; }
purple() { printf '%b\n' "$*"; }
clear() { :; }
with_subscription_lock() { local SUBSCRIPTION_LOCK_HELD=1; "$@"; }
mutate_base_subscription() { :; }
publish_tracked_argo_transition_subscription_locked() { :; }
get_latest_argo_domain() { :; }
get_subscription_host() { printf 'server.example.com\n'; }
resolve_installed_subscription_source_url() { printf 'https://sub.example.com/sub\n'; }
show_subscription_links() { :; }
base='vless://fixture@edge.example.com:443?host=new.example.com&path=%2Fvless-argo#base'
old='vless://fixture@192.0.2.1:443?host=old.example.com&path=%2Fvless-argo#optimized'
printf '%s\n' "$old" > "$client_dir"
with_subscription_lock get_base_subscription_generation_locked > "$CFY_SOURCE_GENERATION_FILE"
chmod 600 "$CFY_SOURCE_GENERATION_FILE"
printf '%s\n' "$old" > "$work_dir/cfy-url.txt"
printf '%s\n' "$base" > "$client_dir"
before=$(sha256sum "$work_dir/cfy-url.txt" "$CFY_SOURCE_GENERATION_FILE")
for entry in refresh transition nodes; do
    case "$entry" in
        refresh) output=$(change_argo_domain) ;;
        transition) output=$(change_argo_transition_subscription fixed new.example.com edge.example.com 443 1) ;;
        nodes) output=$(check_nodes) ;;
    esac
    [[ "$output" != *"$old"* ]] || fail "$entry printed an obsolete optimized URL"
    [[ "$output" == *cfy* && "$output" == *过期* ]] || fail "$entry omitted the regeneration instruction"
    [[ "$output" == *"$base"* ]] || fail "$entry hid the current base URL"
done
[[ "$before" = "$(sha256sum "$work_dir/cfy-url.txt" "$CFY_SOURCE_GENERATION_FILE")" ]] || fail 'display changed cfy-owned files'
with_subscription_lock get_base_subscription_generation_locked > "$CFY_SOURCE_GENERATION_FILE"
output=$(change_argo_domain)
[[ "$output" == *"$old"* ]] || fail 'matching generation was not displayed'
rm "$CFY_SOURCE_GENERATION_FILE"
output=$(check_nodes)
[[ "$output" != *"$old"* ]] || fail 'missing generation exposed unverified links'
with_subscription_lock get_base_subscription_generation_locked > "$CFY_SOURCE_GENERATION_FILE"
chmod 600 "$CFY_SOURCE_GENERATION_FILE"
mv "$work_dir/cfy-url.txt" "$work_dir/history.txt"
ln -s "$work_dir/history.txt" "$work_dir/cfy-url.txt"
output=$(check_nodes)
[[ "$output" != *"$old"* ]] || fail 'symlink result was displayed'
rm "$work_dir/cfy-url.txt"
change_argo_domain >/dev/null || fail 'missing optional results failed a committed refresh'
show_current_cfy_results() { return 1; }
change_argo_domain >/dev/null || fail 'display failure failed a committed refresh'
change_argo_transition_subscription fixed new.example.com edge.example.com 443 1 >/dev/null || fail 'display failure failed a committed transition'
printf 'Current cfy display tests passed.\n'
