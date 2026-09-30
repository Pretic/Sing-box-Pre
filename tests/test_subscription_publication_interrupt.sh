#!/usr/bin/env bash
set -euo pipefail
SB=${SB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh}
for name in $(sed -n '/^for function_name in \\/,/^    load_function /p' "$(dirname "$SB")/tests/test_subscription_contract.sh" | sed '1d;$d' | tr -d '\\' | sed 's/; do//'); do
 source <(sed -n "/^${name}() {/,/^}/p" "$SB")
done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
work_dir="$d" client_dir="$d/url.txt" combined_client_dir="$d/all-url.txt" SING_BOX_TRANSACTION_ROOT="$d/transactions"
RED='' GREEN='' NC=''; red() { printf '%s\n' "$*" >&2; }
printf 'vless://base-old\n' > "$client_dir"
update_sub
cp "$client_dir" "$d/base.before"; cp "$d/sub.txt" "$d/served.before"
replace_base() { printf 'vless://base-new\n' > "$1"; }
for fault_return in 0 143; do
rm -f "$d/interrupted"
rc=0
(
 trap - EXIT
 mv() {
  command mv "$@" || return $?
  if [[ "${*: -1}" == "$client_dir" && ! -e "$d/interrupted" ]]; then
    : > "$d/interrupted"; kill -TERM "$BASHPID"; return "$fault_return"
  fi
 }
 mutate_base_subscription replace_base
) || rc=$?
[[ "$rc" != 0 ]]
base_ok=0;served_ok=0
cmp -s "$client_dir" "$d/base.before" && base_ok=1
cmp -s "$d/sub.txt" "$d/served.before" && served_ok=1
printf 'TERM status=%s; prior base restored=%s; prior served preserved=%s\n' "$rc" "$base_ok" "$served_ok"
[[ "$base_ok" == 1 && "$served_ok" == 1 ]] || { echo 'FAIL interrupted sb commit leaves a mixed-generation file set'; exit 1; }

done
update_sub
echo "Subscription lock is usable after interrupted rollback."
