#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_root}/sing-box.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

dispatch_block=$(sed -n '/^dispatch_warp_rotation_menu_action() {/,/^}/p' "$script")
[[ -n "$dispatch_block" ]] || fail 'dispatch_warp_rotation_menu_action could not be extracted'
source /dev/stdin <<< "$dispatch_block"

LOG=''
ROTATE_RESULT=0
red() { LOG+="red:$*"$'\n'; }
green() { LOG+="green:$*"$'\n'; }
yellow() { LOG+="yellow:$*"$'\n'; }
rotate_warp_identity_until_new() { return "$ROTATE_RESULT"; }

ROTATE_RESULT=0
LOG=''
dispatch_warp_rotation_menu_action || fail 'successful rotation dispatch returned failure'
[[ "$LOG" != *'失败'* ]] || fail 'successful rotation dispatch printed a failure conclusion'

ROTATE_RESULT=1
LOG=''
if dispatch_warp_rotation_menu_action; then rc1=0; else rc1=$?; fi
[ "$rc1" -eq 1 ] || fail "normal rotation failure dispatch returned ${rc1}, expected 1"
[[ "$LOG" == *'原配置保持不变'* ]] || fail 'rc=1 dispatch omitted the unchanged-config conclusion'
[[ "$LOG" != *'回滚或状态不完整'* ]] || fail 'rc=1 dispatch printed the rc=2 recovery warning'

ROTATE_RESULT=2
LOG=''
if dispatch_warp_rotation_menu_action; then rc2=0; else rc2=$?; fi
[ "$rc2" -eq 2 ] || fail "incomplete rotation dispatch returned ${rc2}, expected 2"
[[ "$LOG" == *'回滚或状态不完整'* ]] || fail 'rc=2 dispatch omitted the incomplete-state warning'
[[ "$LOG" == *'恢复目录'* ]] || fail 'rc=2 dispatch omitted recovery-directory guidance'
[[ "$LOG" == *'停止使用自动结论'* ]] || fail 'rc=2 dispatch did not reject automatic conclusions'
[[ "$LOG" != *'原配置保持不变'* ]] || fail 'rc=2 dispatch falsely claimed the original config was unchanged'

menu_block=$(sed -n '/^warp_manage() {/,/^}/p' "$script")
grep -Fq 'dispatch_warp_rotation_menu_action' <<< "$menu_block" || \
  fail 'WARP menu option does not use the status-aware rotation dispatcher'
grep -Fq 'rotate_warp_identity_until_new' <<< "$dispatch_block" || \
  fail 'WARP rotation dispatcher does not use the bounded multi-batch controller'

echo 'WARP menu dispatch tests passed.'
