#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
load_function() {
    local source_text
    source_text="$(sed -n "/^${1}() {/,/^}/p" "$script")"
    [[ -n "$source_text" ]] || fail "$1 is not implemented"
    source <(printf '%s\n' "$source_text")
}

for function_name in report_node_change_transaction_result change_config; do
    load_function "$function_name"
done

work_dir="${tmp_dir}/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
purple=''
re=''
mkdir -p "$conf_dir"
printf '%s\n' 'vless://x@[2001:db8::1]:443?flow=xtls-rprx-vision#node' > "$client_dir"

clear() { :; }
sleep() { :; }
check_singbox() { printf '%s\n' running; return "$CHECK_STATUS"; }
menu() { MENU_CALLS=$((MENU_CALLS + 1)); }
skyblue() { :; }
purple() { :; }
green() { printf '%s\n' "$*" >> "$GREEN_LOG"; }
yellow() { printf '%s\n' "$*" >> "$YELLOW_LOG"; }
red() { printf '%s\n' "$*" >> "$RED_LOG"; }
check_nodes() { :; }
is_valid_subscription_domain() { [[ -n "${1:-}" ]]; }

reading() {
    local variable_name="$2"
    printf -v "$variable_name" '%s' "${READ_VALUES[$READ_INDEX]}"
    READ_INDEX=$((READ_INDEX + 1))
}

change_public_inbound_port_transaction() {
    [[ "$1" == "${conf_dir}/inbounds.json" ]] || return 2
    LAST_CALL="public:$2:$3:$4"
    return "$TX_STATUS"
}
change_argo_port_transaction() {
    LAST_CALL="argo:$1"
    return "$TX_STATUS"
}
change_uuid_transaction() {
    LAST_CALL="uuid:$1"
    return "$TX_STATUS"
}
change_reality_sni_transaction() {
    LAST_CALL="sni:$1"
    return "$TX_STATUS"
}
change_client_ip_transaction() {
    LAST_CALL="ip:$1:$2"
    return "$TX_STATUS"
}
curl() {
    case "${*: -1}" in
        ip.sb)
            case " $* " in
                *' -6 '*) printf '%s\n' '2001:db8::9' ;;
                *) printf '%s\n' '198.51.100.9' ;;
            esac
            ;;
        */org) printf '%s\n' 'Example Transit' ;;
        *) return 1 ;;
    esac
}

reset_case() {
    READ_VALUES=("$@")
    READ_INDEX=0
    LAST_CALL=''
    MENU_CALLS=0
    GREEN_LOG="${tmp_dir}/green.log"
    YELLOW_LOG="${tmp_dir}/yellow.log"
    RED_LOG="${tmp_dir}/red.log"
    : > "$GREEN_LOG"
    : > "$YELLOW_LOG"
    : > "$RED_LOG"
}

CHECK_STATUS=2
TX_STATUS=0
reset_case 1 1 12000
change_config >/dev/null 2>&1 || true
[[ "$MENU_CALLS" -eq 1 && -z "$LAST_CALL" ]] || \
    fail 'uninstalled check_singbox rc2 entered the modification menu'

CHECK_STATUS=0
TX_STATUS=2
reset_case 1 1 12001
if change_config >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 2 && "$LAST_CALL" == public:reality:12001:tcp ]] || \
    fail 'Reality menu swallowed rc2 or bypassed the transaction wrapper'
! grep -Fq 'vless-reality端口已修改成' "$GREEN_LOG" || fail 'Reality rc2 printed a false success message'

TX_STATUS=3
reset_case 1 4 8011
if change_config >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 3 && "$LAST_CALL" == argo:8011 ]] || \
    fail 'Argo menu swallowed rc3 or bypassed the transaction wrapper'
! grep -Fq 'vless-ws-tls-argo端口已修改为' "$GREEN_LOG" || fail 'Argo rc3 printed an unconditional green success'

TX_STATUS=3
reset_case 2 22222222-2222-4222-8222-222222222222
if change_config >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 3 && "$LAST_CALL" == uuid:22222222-2222-4222-8222-222222222222 ]] || \
    fail 'UUID menu swallowed rc3 or bypassed the transaction wrapper'

TX_STATUS=1
reset_case 3 2
if change_config >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 1 && "$LAST_CALL" == sni:www.stengg.com ]] || \
    fail 'SNI menu swallowed rc1 or bypassed the transaction wrapper'

TX_STATUS=2
reset_case 7
if change_config >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 2 && "$LAST_CALL" == ip:ipv4:198.51.100.9 ]] || \
    fail 'IPv4 menu swallowed rc2 or bypassed the transaction wrapper'

printf '%s\n' 'vless://x@198.51.100.2:443?flow=xtls-rprx-vision#node' > "$client_dir"
TX_STATUS=3
reset_case 8
if change_config >/dev/null 2>&1; then status=0; else status=$?; fi
[[ "$status" -eq 3 && "$LAST_CALL" == ip:ipv6:2001:db8::9 ]] || \
    fail 'IPv6 menu swallowed rc3 or bypassed the transaction wrapper'

TX_STATUS=0
reset_case 1 2 12002
change_config >/dev/null 2>&1 || fail 'successful Hysteria2 menu transaction failed'
[[ "$LAST_CALL" == public:hysteria2:12002:udp ]] || fail 'Hysteria2 menu bypassed the transaction wrapper'
grep -Fq 'hysteria2端口已修改为' "$GREEN_LOG" || fail 'successful menu transaction omitted its success message'

printf 'Change-config menu transaction tests passed.\n'
