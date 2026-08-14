#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

function_source="$(sed -n '/^select_argo_client_address() {/,/^}/p' "${script}")"
if [[ -z "${function_source}" ]]; then
    echo 'FAIL: select_argo_client_address is not implemented' >&2
    exit 1
fi
source <(printf '%s\n' "${function_source}")

actual="$(select_argo_client_address 'cdns.doon.eu.org' 'dm-cnt.example.com' 1 0)"
[[ "${actual}" == 'dm-cnt.example.com' ]] || {
    echo "FAIL: fixed Tunnel without explicit CFIP must use ARGO_DOMAIN, got ${actual}" >&2
    exit 1
}

actual="$(select_argo_client_address 'custom.cf.example' 'dm-cnt.example.com' 1 1)"
[[ "${actual}" == 'custom.cf.example' ]] || {
    echo "FAIL: explicit CFIP must be preserved, got ${actual}" >&2
    exit 1
}

actual="$(select_argo_client_address 'cdns.doon.eu.org' '' 0 0)"
[[ "${actual}" == 'cdns.doon.eu.org' ]] || {
    echo "FAIL: quick Tunnel must retain the fallback CFIP, got ${actual}" >&2
    exit 1
}

echo 'Fixed Argo client address tests passed.'
