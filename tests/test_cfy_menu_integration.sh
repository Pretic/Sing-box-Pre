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

load_function() {
    local function_source
    function_source="$(extract_function "$1")"
    [[ -n "$function_source" ]] || fail "$1 is not implemented"
    source <(printf '%s\n' "$function_source")
}

assert_equal() {
    [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"
}

for function_name in \
    cfy_executable_path \
    cfy_download_url \
    cfy_expected_download_sha256 \
    validate_cfy_target_path \
    validate_cfy_script \
    validate_cfy_executable \
    install_cfy \
    run_cfy_existing \
    run_cfy \
    manage_cfy \
    menu \
    dispatch_cli_action; do
    load_function "$function_name"
done

green() { printf '%s\n' "$*"; }
yellow() { printf '%s\n' "$*"; }
red() { printf '%s\n' "$*" >&2; }
purple() { printf '%s\n' "$*"; }
skyblue() { printf '%s\n' "$*"; }
purple=''
re=''
clear() { :; }
export MOCK_READING_LOG="${tmp_dir}/reading.log"
reading() {
    printf '%s\n' "$1" >> "$MOCK_READING_LOG"
    IFS= read -r "$2"
}

make_compatible_cfy() {
    cat > "$1" <<'CFY'
#!/usr/bin/env bash
CFY_SOURCE_GENERATION_FILE="${CFY_SOURCE_GENERATION_FILE:-/etc/sing-box/cfy-source.generation}"
ensure_stable_transaction_root() { :; }
with_subscription_lock() { "$@"; }
publish_subscriptions_locked() { :; }
printf '%s\n' "$*" >> "${MOCK_CFY_RUN_LOG:?}"
exit "${MOCK_CFY_EXIT_STATUS:-0}"
CFY
    chmod 755 "$1"
}

mock_bin="${tmp_dir}/bin"
mkdir -p "$mock_bin"
cat > "${mock_bin}/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" > "${MOCK_CURL_LOG:?}"
output=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        --connect-timeout|--max-time) shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$output" ] || exit 90
[ "${MOCK_CURL_FAIL:-0}" = 0 ] || exit 22
case "${MOCK_CURL_MODE:-copy}" in
    copy)
        cp "${MOCK_CFY_SOURCE:?}" "$output"
        ;;
    empty)
        : > "$output"
        ;;
    race)
        cp "${MOCK_CFY_SOURCE:?}" "$output"
        printf 'competitor\n' > "${MOCK_CFY_TARGET:?}"
        /usr/bin/chmod 755 "$MOCK_CFY_TARGET"
        ;;
    race-directory)
        cp "${MOCK_CFY_SOURCE:?}" "$output"
        mkdir "${MOCK_CFY_TARGET:?}"
        printf 'directory competitor\n' > "${MOCK_CFY_TARGET}/sentinel"
        ;;
    race-directory-symlink)
        cp "${MOCK_CFY_SOURCE:?}" "$output"
        mkdir "${MOCK_CFY_RACE_DIRECTORY:?}"
        ln -s "$MOCK_CFY_RACE_DIRECTORY" "${MOCK_CFY_TARGET:?}"
        ;;
    *)
        exit 91
        ;;
esac
MOCK
chmod 755 "${mock_bin}/curl"
export PATH="${mock_bin}:$PATH"
export MOCK_CURL_LOG="${tmp_dir}/curl.log"
export MOCK_CFY_RUN_LOG="${tmp_dir}/run.log"
export MOCK_CFY_EXIT_STATUS=0
export MOCK_CURL_MODE=copy

source_cfy="${tmp_dir}/source-cfy"
make_compatible_cfy "$source_cfy"
source_sha="$(sha256sum "$source_cfy" | awk '{print $1}')"

# Production defaults stay immutable: future edits must deliberately update
# both the full commit URL and its reviewed content digest.
assert_equal \
    'https://raw.githubusercontent.com/Pretic/Pre-cfy/2eb6b4611986d1fd0939c7dcf90aeb9e0704d202/cfy.sh' \
    "$(cfy_download_url)" \
    'default cfy download URL pin'
assert_equal \
    '959cdeb10a205332825ccdc9ac7cd9fb9f6220de63fb3fed1ec061cbc2ee9ee6' \
    "$(cfy_expected_download_sha256)" \
    'default cfy download SHA-256 pin'

# Executable overrides are an explicit test seam, but remain root execution
# targets: relative, traversal, directory-style, and CR/LF paths fail closed.
validate_cfy_target_path "${tmp_dir}/absolute-cfy" ||
    fail 'absolute cfy target path was rejected'
for unsafe_target in \
    './cfy' \
    "${tmp_dir}/../cfy" \
    "${tmp_dir}/./cfy" \
    "${tmp_dir}/cfy/" \
    "${tmp_dir}/cfy"$'\nbad' \
    "${tmp_dir}/cfy"$'\rbad'; do
    if validate_cfy_target_path "$unsafe_target"; then
        fail "unsafe cfy target path was accepted: ${unsafe_target}"
    fi
done

# Existing compatible cfy runs in the foreground and never downloads.
installed="${tmp_dir}/installed-cfy"
make_compatible_cfy "$installed"
export SB_CFY_EXECUTABLE="$installed"
export MOCK_CURL_FAIL=1
: > "$MOCK_CURL_LOG"
: > "$MOCK_CFY_RUN_LOG"
run_cfy_existing -c || fail 'installed cfy -c did not run'
assert_equal '-c' "$(cat "$MOCK_CFY_RUN_LOG")" 'installed cfy arguments'
[[ ! -s "$MOCK_CURL_LOG" ]] || fail 'installed cfy unexpectedly downloaded'

# Missing cfy downloads to a same-directory temporary file, validates, safely
# publishes, and then runs. The test URL and checksum are explicit overrides.
install_dir="${tmp_dir}/install"
mkdir -p "$install_dir"
export SB_CFY_EXECUTABLE="${install_dir}/cfy"
export SB_CFY_DOWNLOAD_URL='https://fixture.invalid/cfy.sh'
export SB_CFY_DOWNLOAD_SHA256="$source_sha"
export SB_CFY_CONNECT_TIMEOUT=3
export SB_CFY_MAX_TIME=9
export MOCK_CFY_SOURCE="$source_cfy"
export MOCK_CURL_FAIL=0
: > "$MOCK_CURL_LOG"
: > "$MOCK_CFY_RUN_LOG"
run_cfy || fail 'missing cfy was not installed and run'
[[ -f "$SB_CFY_EXECUTABLE" && ! -L "$SB_CFY_EXECUTABLE" && -x "$SB_CFY_EXECUTABLE" ]] ||
    fail 'installed cfy is not a regular executable'
[[ "$(stat -c '%a' "$SB_CFY_EXECUTABLE")" = 755 ]] || fail 'installed cfy mode is not 755'
[[ -z "$(find "$install_dir" -maxdepth 1 -name '.cfy.install.*' -print -quit)" ]] ||
    fail 'successful install leaked a temporary file'
for expected in -fsSL --connect-timeout 3 --max-time 9 -o \
    'https://fixture.invalid/cfy.sh'; do
    grep -Fxq -- "$expected" "$MOCK_CURL_LOG" || fail "curl omitted $expected"
done

# Download failure leaves no target and no staged file.
failure_dir="${tmp_dir}/failure"
mkdir -p "$failure_dir"
export SB_CFY_EXECUTABLE="${failure_dir}/cfy"
export MOCK_CURL_FAIL=1
set +e
install_cfy >/dev/null 2>&1
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]] || fail 'failed download unexpectedly installed cfy'
[[ ! -e "$SB_CFY_EXECUTABLE" && ! -L "$SB_CFY_EXECUTABLE" ]] ||
    fail 'failed download created the target'
[[ -z "$(find "$failure_dir" -maxdepth 1 -name '.cfy.install.*' -print -quit)" ]] ||
    fail 'failed download leaked a temporary file'

assert_rejected_download() {
    local label="$1"
    local candidate="$2"
    local expected_sha="$3"
    local mode="${4:-copy}"
    local fixture_dir="${tmp_dir}/rejected-${label}"
    local status

    mkdir -p "$fixture_dir"
    export SB_CFY_EXECUTABLE="${fixture_dir}/cfy"
    export SB_CFY_DOWNLOAD_URL="https://fixture.invalid/${label}.sh"
    export SB_CFY_DOWNLOAD_SHA256="$expected_sha"
    export MOCK_CFY_SOURCE="$candidate"
    export MOCK_CFY_TARGET="$SB_CFY_EXECUTABLE"
    export MOCK_CURL_FAIL=0
    export MOCK_CURL_MODE="$mode"
    set +e
    install_cfy >/dev/null 2>&1
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "${label} download unexpectedly installed"
    [[ ! -e "$SB_CFY_EXECUTABLE" && ! -L "$SB_CFY_EXECUTABLE" ]] ||
        fail "${label} download published a target"
    [[ -z "$(find "$fixture_dir" -maxdepth 1 -name '.cfy.install.*' -print -quit)" ]] ||
        fail "${label} download leaked a temporary file"
}

# Every content gate fails closed and cleans its same-directory stage.
assert_rejected_download empty "$source_cfy" "$source_sha" empty

bad_bash="${tmp_dir}/bad-bash"
printf '#!/usr/bin/env bash\nif then\n' > "$bad_bash"
bad_bash_sha="$(sha256sum "$bad_bash" | awk '{print $1}')"
assert_rejected_download bad-bash "$bad_bash" "$bad_bash_sha"

for marker in \
    'CFY_SOURCE_GENERATION_FILE=' \
    'ensure_stable_transaction_root()' \
    'with_subscription_lock()' \
    'publish_subscriptions_locked()'; do
    marker_key="$(printf '%s' "$marker" | tr -cd '[:alnum:]_' | cut -c1-24)"
    missing_marker="${tmp_dir}/missing-${marker_key}"
    grep -Fv "$marker" "$source_cfy" > "$missing_marker"
    missing_marker_sha="$(sha256sum "$missing_marker" | awk '{print $1}')"
    assert_rejected_download "missing-${marker_key}" "$missing_marker" "$missing_marker_sha"
done

assert_rejected_download sha-mismatch "$source_cfy" \
    0000000000000000000000000000000000000000000000000000000000000000

assert_existing_rejected_and_preserved() {
    local label="$1"
    local target="$2"
    local before="$3"
    local after_command="$4"
    local status after

    export SB_CFY_EXECUTABLE="$target"
    export MOCK_CURL_FAIL=1
    : > "$MOCK_CURL_LOG"
    set +e
    run_cfy >/dev/null 2>&1
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "${label} existing object was accepted"
    [[ ! -s "$MOCK_CURL_LOG" ]] || fail "${label} existing object triggered a download"
    after="$(eval "$after_command")"
    assert_equal "$before" "$after" "${label} existing object preservation"
}

# Existing unsafe objects are never replaced or modified.
existing_dir="${tmp_dir}/existing"
mkdir -p "$existing_dir"
symlink_target="${existing_dir}/compatible"
make_compatible_cfy "$symlink_target"
ln -s "$symlink_target" "${existing_dir}/symlink"
assert_existing_rejected_and_preserved symlink "${existing_dir}/symlink" \
    "$symlink_target" "readlink '${existing_dir}/symlink'"

mkdir "${existing_dir}/directory"
printf 'directory sentinel\n' > "${existing_dir}/directory/sentinel"
directory_before="$(sha256sum "${existing_dir}/directory/sentinel" | awk '{print $1}')"
assert_existing_rejected_and_preserved directory "${existing_dir}/directory" \
    "$directory_before" "sha256sum '${existing_dir}/directory/sentinel' | awk '{print \$1}'"

cp "$source_cfy" "${existing_dir}/nonexec"
chmod 644 "${existing_dir}/nonexec"
nonexec_before="$(sha256sum "${existing_dir}/nonexec" | awk '{print $1}')|$(stat -c '%a' "${existing_dir}/nonexec")"
assert_existing_rejected_and_preserved nonexec "${existing_dir}/nonexec" \
    "$nonexec_before" "printf '%s|%s' \"\$(sha256sum '${existing_dir}/nonexec' | awk '{print \$1}')\" \"\$(stat -c '%a' '${existing_dir}/nonexec')\""


# Existing ordinary executables remain backward-compatible: marker checks are
# for newly downloaded candidates, not a gate on an already installed cfy.
legacy_executable="${existing_dir}/legacy-cfy"
cat > "$legacy_executable" <<'LEGACY'
#!/usr/bin/env bash
printf 'legacy:%s\n' "$*" >> "${MOCK_CFY_RUN_LOG:?}"
LEGACY
chmod 755 "$legacy_executable"
legacy_before="$(sha256sum "$legacy_executable" | awk '{print $1}')"
export SB_CFY_EXECUTABLE="$legacy_executable"
export MOCK_CURL_FAIL=1
: > "$MOCK_CURL_LOG"
: > "$MOCK_CFY_RUN_LOG"
run_cfy_existing legacy-arg || fail 'existing legacy executable was rejected'
assert_equal 'legacy:legacy-arg' "$(cat "$MOCK_CFY_RUN_LOG")" \
    'existing legacy executable argv'
[[ ! -s "$MOCK_CURL_LOG" ]] || fail 'existing legacy executable triggered a download'
assert_equal "$legacy_before" "$(sha256sum "$legacy_executable" | awk '{print $1}')" \
    'existing legacy executable preservation'

# A relative executable override must never be resolved against root's current
# working directory and executed.
relative_dir="${tmp_dir}/relative-target"
mkdir -p "$relative_dir"
make_compatible_cfy "${relative_dir}/cfy"
: > "$MOCK_CFY_RUN_LOG"
set +e
(
    cd "$relative_dir"
    export SB_CFY_EXECUTABLE='./cfy'
    run_cfy_existing relative-arg >/dev/null 2>&1
)
relative_status=$?
set -e
[[ "$relative_status" -ne 0 ]] || fail 'relative cfy executable was run'
[[ ! -s "$MOCK_CFY_RUN_LOG" ]] || fail 'relative cfy executable produced side effects'

# A target created after download wins the publication race byte-for-byte.
race_dir="${tmp_dir}/race"
mkdir -p "$race_dir"
export SB_CFY_EXECUTABLE="${race_dir}/cfy"
export SB_CFY_DOWNLOAD_URL='https://fixture.invalid/race.sh'
export SB_CFY_DOWNLOAD_SHA256="$source_sha"
export MOCK_CFY_SOURCE="$source_cfy"
export MOCK_CFY_TARGET="$SB_CFY_EXECUTABLE"
export MOCK_CURL_FAIL=0
export MOCK_CURL_MODE=race
set +e
install_cfy >/dev/null 2>&1
race_status=$?
set -e
[[ "$race_status" -ne 0 ]] || fail 'publication race unexpectedly succeeded'
assert_equal competitor "$(cat "$SB_CFY_EXECUTABLE")" 'publication race winner'
[[ -z "$(find "$race_dir" -maxdepth 1 -name '.cfy.install.*' -print -quit)" ]] ||
    fail 'publication race leaked a temporary file'

# A directory or directory symlink created after download must remain intact,
# and publication must not follow it or leave the staged script inside it.
race_directory_dir="${tmp_dir}/race-directory"
mkdir -p "$race_directory_dir"
export SB_CFY_EXECUTABLE="${race_directory_dir}/cfy"
export MOCK_CFY_TARGET="$SB_CFY_EXECUTABLE"
export MOCK_CURL_MODE=race-directory
set +e
install_cfy >/dev/null 2>&1
race_directory_status=$?
set -e
[[ "$race_directory_status" -ne 0 ]] || fail 'directory publication race unexpectedly succeeded'
assert_equal 'directory competitor' "$(cat "${SB_CFY_EXECUTABLE}/sentinel")" \
    'directory publication race winner'
[[ -z "$(find "$SB_CFY_EXECUTABLE" -maxdepth 1 -name '.cfy.install.*' -print -quit)" ]] ||
    fail 'directory publication race leaked the staged script into the target'
[[ -z "$(find "$race_directory_dir" -maxdepth 1 -name '.cfy.install.*' -print -quit)" ]] ||
    fail 'directory publication race leaked a temporary file'

race_symlink_dir="${tmp_dir}/race-directory-symlink"
race_symlink_destination="${tmp_dir}/race-directory-symlink-destination"
mkdir -p "$race_symlink_dir"
export SB_CFY_EXECUTABLE="${race_symlink_dir}/cfy"
export MOCK_CFY_TARGET="$SB_CFY_EXECUTABLE"
export MOCK_CFY_RACE_DIRECTORY="$race_symlink_destination"
export MOCK_CURL_MODE=race-directory-symlink
set +e
install_cfy >/dev/null 2>&1
race_symlink_status=$?
set -e
[[ "$race_symlink_status" -ne 0 ]] || fail 'directory symlink publication race unexpectedly succeeded'
[[ -L "$SB_CFY_EXECUTABLE" ]] || fail 'directory symlink publication race replaced the competitor'
assert_equal "$race_symlink_destination" "$(readlink "$SB_CFY_EXECUTABLE")" \
    'directory symlink publication race winner'
[[ -z "$(find "$race_symlink_destination" -maxdepth 1 -name '.cfy.install.*' -print -quit)" ]] ||
    fail 'directory symlink publication race leaked the staged script through the symlink'
[[ -z "$(find "$race_symlink_dir" -maxdepth 1 -name '.cfy.install.*' -print -quit)" ]] ||
    fail 'directory symlink publication race leaked a temporary file'

# An isolated ln failure leaves both destination and staging area empty.
ln_bin="${tmp_dir}/ln-bin"
ln_dir="${tmp_dir}/ln-failure"
mkdir -p "$ln_bin" "$ln_dir"
cat > "${ln_bin}/ln" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod 755 "${ln_bin}/ln"
export SB_CFY_EXECUTABLE="${ln_dir}/cfy"
export MOCK_CFY_TARGET="$SB_CFY_EXECUTABLE"
export MOCK_CURL_MODE=copy
set +e
PATH="${ln_bin}:$PATH" install_cfy >/dev/null 2>&1
ln_status=$?
set -e
[[ "$ln_status" -ne 0 ]] || fail 'ln failure unexpectedly published cfy'
[[ ! -e "$SB_CFY_EXECUTABLE" && ! -L "$SB_CFY_EXECUTABLE" ]] ||
    fail 'ln failure created the destination'
[[ -z "$(find "$ln_dir" -maxdepth 1 -name '.cfy.install.*' -print -quit)" ]] ||
    fail 'ln failure leaked a temporary file'

# A child failure returns to the same loop; option 4 and EOF return cleanly.
export SB_CFY_EXECUTABLE="$installed"
export MOCK_CFY_EXIT_STATUS=37
: > "$MOCK_READING_LOG"
set +e
loop_output="$(printf '1\n\n4\n' | manage_cfy 2>&1)"
loop_status=$?
set -e
assert_equal 0 "$loop_status" 'submenu return after cfy rc37'
[[ "$(grep -Fc 'Cloudflare优选' <<< "$loop_output")" -ge 2 ]] ||
    fail 'cfy child did not return to the submenu loop'
assert_equal 1 "$(grep -Fc '按回车返回 cfy 菜单' "$MOCK_READING_LOG")" \
    'submenu pause after cfy child'
manage_cfy </dev/null >/dev/null 2>&1 || fail 'submenu EOF did not return'
export MOCK_CFY_EXIT_STATUS=0

# Options 2/3 never install. Once installed, they forward exact argv.
missing_menu_dir="${tmp_dir}/missing-menu"
mkdir -p "$missing_menu_dir"
export SB_CFY_EXECUTABLE="${missing_menu_dir}/cfy"
export MOCK_CURL_FAIL=1
: > "$MOCK_CURL_LOG"
: > "$MOCK_READING_LOG"
set +e
missing_menu_output="$(printf '2\n\n3\n\n4\n' | manage_cfy 2>&1)"
missing_menu_status=$?
set -e
assert_equal 0 "$missing_menu_status" 'missing cfy options 2/3 return'
[[ ! -e "$SB_CFY_EXECUTABLE" && ! -L "$SB_CFY_EXECUTABLE" ]] ||
    fail 'options 2/3 installed missing cfy'
[[ ! -s "$MOCK_CURL_LOG" ]] || fail 'options 2/3 attempted a download'
[[ "$(grep -Fc '请先选择' <<< "$missing_menu_output")" -ge 2 ]] ||
    fail 'missing cfy options 2/3 lack installation guidance'
assert_equal 2 "$(grep -Fc '按回车返回 cfy 菜单' "$MOCK_READING_LOG")" \
    'submenu pause after missing options 2/3'

export SB_CFY_EXECUTABLE="$installed"
: > "$MOCK_CFY_RUN_LOG"
printf '2\n\n3\n\n4\n' | manage_cfy >/dev/null 2>&1 ||
    fail 'installed cfy options 2/3 did not return'
assert_equal $'-c\n--update' "$(cat "$MOCK_CFY_RUN_LOG")" \
    'installed cfy options 2/3 argv'

# Both download failure and child failure leave service hooks and sentinel
# node/configuration bytes untouched.
side_effect_log="${tmp_dir}/side-effects"
update_sub() { printf 'update_sub\n' >> "$side_effect_log"; }
restart_singbox() { printf 'restart_singbox\n' >> "$side_effect_log"; }
restart_argo() { printf 'restart_argo\n' >> "$side_effect_log"; }
restart_nginx() { printf 'restart_nginx\n' >> "$side_effect_log"; }

sentinel_dir="${tmp_dir}/sentinels"
mkdir -p "$sentinel_dir"
printf 'vless://sentinel-node\n' > "${sentinel_dir}/url.txt"
printf '{"sentinel":true}\n' > "${sentinel_dir}/config.json"
cp "${sentinel_dir}/url.txt" "${sentinel_dir}/url.before"
cp "${sentinel_dir}/config.json" "${sentinel_dir}/config.before"

download_side_effect_dir="${tmp_dir}/download-side-effect"
mkdir -p "$download_side_effect_dir"
export SB_CFY_EXECUTABLE="${download_side_effect_dir}/cfy"
export MOCK_CURL_FAIL=1
set +e
run_cfy >/dev/null 2>&1
download_side_effect_status=$?
set -e
[[ "$download_side_effect_status" -ne 0 ]] ||
    fail 'download side-effect fixture unexpectedly succeeded'

export SB_CFY_EXECUTABLE="$installed"
export MOCK_CFY_EXIT_STATUS=37
set +e
run_cfy_existing >/dev/null 2>&1
run_side_effect_status=$?
set -e
assert_equal 37 "$run_side_effect_status" 'child side-effect fixture status'
export MOCK_CFY_EXIT_STATUS=0

[[ ! -e "$side_effect_log" ]] || fail 'cfy failures called restart/update_sub hooks'
cmp -s "${sentinel_dir}/url.before" "${sentinel_dir}/url.txt" ||
    fail 'cfy failures changed sentinel nodes'
cmp -s "${sentinel_dir}/config.before" "${sentinel_dir}/config.json" ||
    fail 'cfy failures changed sentinel configuration'

check_singbox() { printf running; }
check_nginx() { printf running; }
check_argo() { printf running; }
get_warp_menu_status() { printf running; }
main_menu_output="$(menu 2>&1)"
for menu_line in \
    '1. 安装sing-box' \
    '2. 卸载sing-box' \
    '3. sing-box管理' \
    '4. Argo隧道管理' \
    '5. 查看节点信息' \
    '6. 修改节点配置' \
    '7. 管理节点订阅' \
    '8. WARP分流管理' \
    '9. 增加/删除协议' \
    '10. ssh综合工具箱' \
    '11. Cloudflare优选' \
    '0. 退出脚本'; do
    grep -Fq "$menu_line" <<< "$main_menu_output" ||
        fail "main menu missing or renumbered: $menu_line"
done
grep -Fq 'purple "11. Cloudflare优选"' "$script" ||
    fail 'main menu option 11 does not use the tools-group purple color'
if grep -Fq 'Cloudflare 节点优选（cfy）' "$script"; then
    fail 'legacy cfy menu wording is still present'
fi
grep -Fq 'reading "请输入选择(0-11): " choice' "$script" ||
    fail 'main menu prompt is not 0-11'
grep -Eq '11\)[[:space:]]+manage_cfy;[[:space:]]+need_pause=false' "$script" ||
    fail 'interactive option 11 does not dispatch to manage_cfy'
grep -Fq -- '--cfy' <<< "$(dispatch_cli_action --help)" ||
    fail 'CLI help omits --cfy'
printf '4\n' | dispatch_cli_action --cfy >/dev/null ||
    fail 'CLI --cfy did not enter and return from the submenu'

integration_source="$(
    for function_name in \
        cfy_executable_path \
        validate_cfy_target_path \
        install_cfy \
        run_cfy_existing \
        run_cfy \
        manage_cfy \
        dispatch_cli_action \
        menu; do
        extract_function "$function_name"
    done
)"
for rename_marker in --rename node-name-prefix '修改统一节点名前缀'; do
    [[ "$integration_source" != *"$rename_marker"* ]] ||
        fail "cfy integration unexpectedly contains rename feature: $rename_marker"
done

printf 'cfy menu integration tests passed.\n'
