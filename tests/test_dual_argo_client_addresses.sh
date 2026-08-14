#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

function_source="$(sed -n '/^list_argo_client_addresses() {/,/^}/p' "${script}")"
if [[ -z "${function_source}" ]]; then
    echo 'FAIL: list_argo_client_addresses is not implemented' >&2
    exit 1
fi
source <(printf '%s\n' "${function_source}")

actual="$(list_argo_client_addresses 'cdns.doon.eu.org' 'dm-cnt.example.com' 1)"
expected=$'dm-cnt.example.com\tstable\ncdns.doon.eu.org\tpreferred'
[[ "${actual}" == "${expected}" ]] || {
    printf 'FAIL: fixed Tunnel must publish stable and preferred addresses\nexpected:\n%s\nactual:\n%s\n' "${expected}" "${actual}" >&2
    exit 1
}

actual="$(list_argo_client_addresses 'dm-cnt.example.com' 'dm-cnt.example.com' 1)"
expected=$'dm-cnt.example.com\tstable'
[[ "${actual}" == "${expected}" ]] || {
    echo 'FAIL: identical stable and preferred addresses must be deduplicated' >&2
    exit 1
}

actual="$(list_argo_client_addresses 'cdns.doon.eu.org' 'temporary.trycloudflare.com' 0)"
expected=$'cdns.doon.eu.org\tstable'
[[ "${actual}" == "${expected}" ]] || {
    echo 'FAIL: quick Tunnel must retain one fallback address' >&2
    exit 1
}

echo 'Dual Argo client address tests passed.'
