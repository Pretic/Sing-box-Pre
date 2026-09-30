#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(sed -n '/^warp_manage() {/,/^}/p' "$script")
source <(sed -n '/^prompt_warp_target_family() {/,/^}/p' "$script")
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
conf_dir="$d"; printf '{"outbounds":[]}' > "$d/outbounds.json"
check_singbox() { return 0; }
extract_warp_endpoint() { :; }
list_enabled_warp_route_mappings() { :; }
clear() { :; }
green() { printf '%s\n' "$*"; }
yellow() { printf '%s\n' "$*"; }
red() { printf '%s\n' "$*"; }
skyblue=''; re=''
skyblue() { :; }; purple() { :; }
reading() {
    case "$2" in
        choice) printf -v "$2" '%s' 7 ;;
        warp_unlock_selection|warp_family_choice) printf -v "$2" '%s' '' ;;
    esac
}
read() { if [[ "${1:-}" == -r ]]; then builtin read "$@"; else :; fi; }
auto_select_warp_candidate() {
    printf '%s:%s\n' "$1" "$2" > "$d/selection"
    # End the subsequent menu return without starting another action.
    warp_manage() { :; }
}
warp_manage > "$d/output"
[[ "$(cat "$d/selection")" == 3:4 ]]
grep -Fq '不保证登录、对话或播放可用' "$d/output"
! grep -Fq '严格解锁' "$d/output"
echo 'Platform selection defaults and evidence-scope wording tests passed.'
