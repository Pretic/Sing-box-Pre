#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

extract_function() {
    sed -n "/^${1}() {/,/^}/p" "$script"
}

for function_name in ensure_nginx_conf_d_include remove_managed_nginx_include add_nginx_conf; do
    function_source="$(extract_function "$function_name")"
    [[ -n "$function_source" ]] || fail "$function_name is not implemented"
    source <(printf '%s\n' "$function_source")
done

green() { :; }
red() { :; }
command_exists() { [[ "$1" == nginx ]]; }
nginx_port=18080
password=0123456789abcdefghjkmnpqrstvwxyz
apply_status=0
apply_nginx_subscription_config() { return "$apply_status"; }

new_fixture() {
    fixture="${tmp_dir}/$1"
    mkdir -p "${fixture}/conf.d"
    NGINX_MAIN_CONF="${fixture}/nginx.conf"
    NGINX_CONF_DIR="${fixture}/conf.d"
}

new_fixture insert
cat > "$NGINX_MAIN_CONF" <<'EOF'
events {}
http {
    server_tokens off;
}
EOF
original="$(command cat "$NGINX_MAIN_CONF")"
add_nginx_conf || fail 'safe conf.d include insertion failed'
grep -Fq '# sing-box-pre:conf.d:start' "$NGINX_MAIN_CONF" || \
    fail 'managed include start marker is missing'
grep -Fq "include ${NGINX_CONF_DIR}/*.conf;" "$NGINX_MAIN_CONF" || \
    fail 'managed conf.d include is missing'
grep -Fq 'server_tokens off;' "$NGINX_MAIN_CONF" || \
    fail 'existing nginx content was overwritten'

# A failed subscription config must restore the exact prior main config.
new_fixture rollback
printf '%s\n' "$original" > "$NGINX_MAIN_CONF"
before="$(command cat "$NGINX_MAIN_CONF")"
apply_status=1
if add_nginx_conf; then
    fail 'nginx setup succeeded after subscription config failure'
fi
[[ "$(command cat "$NGINX_MAIN_CONF")" == "$before" ]] || \
    fail 'failed nginx setup did not restore the exact main config'
apply_status=0

# Existing shared includes are adopted without adding ownership markers.
new_fixture shared
cat > "$NGINX_MAIN_CONF" <<EOF
events {}
http {
    include ${NGINX_CONF_DIR}/*.conf;
}
EOF
add_nginx_conf || fail 'existing shared conf.d include was rejected'
if grep -Fq '# sing-box-pre:conf.d:start' "$NGINX_MAIN_CONF"; then
    fail 'script claimed ownership of a pre-existing conf.d include'
fi

# Unknown or malformed main configs fail closed instead of being replaced.
new_fixture malformed
printf '%s\n' 'events {}' > "$NGINX_MAIN_CONF"
before="$(command cat "$NGINX_MAIN_CONF")"
if add_nginx_conf; then
    fail 'nginx setup accepted a main config without an http block'
fi
[[ "$(command cat "$NGINX_MAIN_CONF")" == "$before" ]] || \
    fail 'malformed nginx config was overwritten'

# Cleanup removes only our exact marker block and preserves later user edits.
new_fixture cleanup
cat > "$NGINX_MAIN_CONF" <<EOF
events {}
http {
    # sing-box-pre:conf.d:start
    include ${NGINX_CONF_DIR}/*.conf;
    # sing-box-pre:conf.d:end
    server_tokens off;
}
EOF
remove_managed_nginx_include "$NGINX_MAIN_CONF" || fail 'managed include cleanup failed'
if grep -Fq '# sing-box-pre:conf.d:' "$NGINX_MAIN_CONF"; then
    fail 'managed include marker survived cleanup'
fi
grep -Fq 'server_tokens off;' "$NGINX_MAIN_CONF" || \
    fail 'cleanup reverted unrelated nginx edits'

# If another application later starts using the directory, keep the include:
# removing it would break that application even though the marker is ours.
new_fixture shared-after-install
cat > "$NGINX_MAIN_CONF" <<EOF
events {}
http {
    # sing-box-pre:conf.d:start
    include ${NGINX_CONF_DIR}/*.conf;
    # sing-box-pre:conf.d:end
}
EOF
printf '%s\n' 'server { listen 19090; }' > "${NGINX_CONF_DIR}/other-app.conf"
remove_managed_nginx_include "$NGINX_MAIN_CONF" "$NGINX_CONF_DIR" || \
    fail 'shared-directory cleanup check failed'
grep -Fq '# sing-box-pre:conf.d:start' "$NGINX_MAIN_CONF" || \
    fail 'cleanup removed an include now shared by another application'

# Marker-looking substrings in user comments are not owned markers and must
# never cause adjacent user content to be deleted.
new_fixture marker-substring
cat > "$NGINX_MAIN_CONF" <<'EOF'
events {}
http {
    # documentation: # sing-box-pre:conf.d:start is reserved
    server_tokens off;
    # documentation: # sing-box-pre:conf.d:end is reserved
}
EOF
before="$(command cat "$NGINX_MAIN_CONF")"
remove_managed_nginx_include "$NGINX_MAIN_CONF" "$NGINX_CONF_DIR" || \
    fail 'marker substring should be treated as user content'
[[ "$(command cat "$NGINX_MAIN_CONF")" == "$before" ]] || \
    fail 'marker substring caused user content deletion'

# Even exact boundary markers are not enough: only the exact three-line block
# created by this script is removable. User edits inside it fail closed and
# preserve the full file for manual recovery.
new_fixture edited-marker-block
cat > "$NGINX_MAIN_CONF" <<EOF
events {}
http {
    # sing-box-pre:conf.d:start
    include ${NGINX_CONF_DIR}/*.conf;
    server_tokens off;
    # sing-box-pre:conf.d:end
}
EOF
before="$(command cat "$NGINX_MAIN_CONF")"
if remove_managed_nginx_include "$NGINX_MAIN_CONF" "$NGINX_CONF_DIR"; then
    fail 'edited managed marker block was removed'
fi
[[ "$(command cat "$NGINX_MAIN_CONF")" == "$before" ]] || \
    fail 'edited managed marker block was changed despite fail-close'

uninstall_source="$(extract_function perform_singbox_uninstall)"
[[ -n "$uninstall_source" ]] || fail 'shared uninstall implementation is missing'
grep -Fq 'remove_managed_nginx_include' <<< "$uninstall_source" || \
    fail 'shared uninstall does not perform ownership-aware Nginx cleanup'
if grep -Fq 'nginx.conf.bak.sb' <<< "$uninstall_source"; then
    fail 'shared uninstall can overwrite later user edits with a legacy whole-file backup'
fi
for function_name in auto_uninstall uninstall_singbox; do
    function_source="$(extract_function "$function_name")"
    grep -Fq 'perform_singbox_uninstall' <<< "$function_source" || \
        fail "$function_name bypasses the shared fail-close uninstall"
done

printf 'Nginx ownership tests passed.\n'
