#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
source <(grep '^reading() {' "$script")
source <(sed -n '/^reading_secret() {/,/^}/p' "$script")
red() { printf %s "$1"; }
for func in reading reading_secret; do
    if ( "$func" prompt value </dev/null; echo unexpected ) >/dev/null 2>&1; then
        echo "$func did not stop at EOF" >&2; exit 1
    fi
    result=$(printf 'test-value\n' | ( "$func" prompt value; printf '%s' "$value" ))
    [[ "$result" == *test-value ]]
done
echo 'Menu and secret prompt EOF safety tests passed.'
