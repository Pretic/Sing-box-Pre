#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${SCRIPT_UNDER_TEST:-${repo_root}/sing-box.sh}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

source_text="$(sed -n '/^nft_input_filter_status() {/,/^}/p' "$script")"
[[ -n "$source_text" ]] || fail 'nft_input_filter_status is not implemented'
source <(printf '%s\n' "$source_text")

command_exists() {
    [[ "$1" == nft ]]
}

nft() {
    [[ "$*" == '-j list ruleset' ]] || return 1
    printf '%s\n' "$MOCK_RULESET"
}

assert_status() {
    local expected="$1"
    shift
    local actual=0
    "$@" || actual=$?
    [[ "$actual" -eq "$expected" ]] ||
        fail "expected status ${expected}, got ${actual}: $*"
}

MOCK_RULESET='{"nftables":[]}'
assert_status 1 nft_input_filter_status 0 0

MOCK_RULESET='{"nftables":[{"chain":{"family":"inet","table":"filter","name":"input","type":"filter","hook":"input","prio":0,"policy":"drop"}}]}'
assert_status 0 nft_input_filter_status 0 0

# A provider-created empty base chain with an explicit accept policy is not an
# effective local firewall and must not block first installation.
MOCK_RULESET='{"nftables":[{"chain":{"family":"inet","table":"filter","name":"input","type":"filter","hook":"input","prio":0,"policy":"accept"}}]}'
assert_status 1 nft_input_filter_status 0 0

# Any rule in that chain makes its effect unknown to this script, even when its
# base policy is accept, so it remains a manual-firewall case.
MOCK_RULESET='{"nftables":[{"chain":{"family":"inet","table":"filter","name":"input","type":"filter","hook":"input","prio":0,"policy":"accept"}},{"rule":{"family":"inet","table":"filter","chain":"input","expr":[{"counter":{"packets":0,"bytes":0}}]}}]}'
assert_status 0 nft_input_filter_status 0 0

# iptables-nft compatibility chains are ignored only for the corresponding
# family; their rules must not be mistaken for a separate native firewall.
MOCK_RULESET='{"nftables":[{"chain":{"family":"ip","table":"filter","name":"INPUT","type":"filter","hook":"input","prio":0,"policy":"accept"}},{"rule":{"family":"ip","table":"filter","chain":"INPUT","expr":[{"counter":{"packets":0,"bytes":0}}]}}]}'
assert_status 1 nft_input_filter_status 1 0
assert_status 0 nft_input_filter_status 0 0

MOCK_RULESET='not-json'
assert_status 2 nft_input_filter_status 0 0

printf 'PASS: nftables INPUT classification\n'
