#!/usr/bin/env bash
set -euo pipefail
script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sing-box.sh"
for f in render_argo_systemd_service render_argo_openrc_service managed_service_definition_is_canonical partial_install_service_definition_is_managed partial_install_argo_service_mode; do
    source <(sed -n "/^${f}() {/,/^}/p" "$script")
done
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
ARGO_PORT=8001
for kind in systemd openrc; do
    for mode in quick token local; do
        for format in current legacy; do
            f="$d/${kind}-${mode}-${format}"
            "render_argo_${kind}_service" "$mode" "$format" > "$f"
            managed_service_definition_is_canonical "$f" "${kind}-argo"
            if [[ "$format" == current || "$mode" == quick ]]; then
                grep -Fq -- '--edge-ip-version auto --protocol http2' "$f"
            fi
            printf '\nExecStartPost=/bin/true\n' >> "$f"
            if managed_service_definition_is_canonical "$f" "${kind}-argo"; then exit 1; fi
        done
    done
done
echo 'Argo explicit transport and exact legacy recognition tests passed.'
