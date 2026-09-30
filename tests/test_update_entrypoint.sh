#!/usr/bin/env bash
set -euo pipefail
warp_use_serial_probe() { return 1; }
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
# Exercise the startup migration gate alone. Updating the manager is a recovery
# operation and must never be blocked by (or rewrite) a customized route.
sed -n '/^# Decommission the old built-in query route/,/^# 捕获 Ctrl+C/p' "$script" > "$d/gate.sh"
cat > "$d/runner.sh" <<'SH'
migrate_retired_warp_routes() { printf 'called\n' >> "$CALL_LOG"; return 1; }
red() { :; }
source "$GATE" "$@"
SH
for action in --update --upgrade --help --uninstall; do
    CALL_LOG="$d/calls" GATE="$d/gate.sh" bash "$d/runner.sh" "$action"
    [[ ! -e "$d/calls" ]]
done
if CALL_LOG="$d/calls" GATE="$d/gate.sh" bash "$d/runner.sh"; then
    echo 'normal entry silently ignored a migration failure' >&2; exit 1
fi
[[ -s "$d/calls" ]]
echo 'Update recovery entry-point tests passed.'
