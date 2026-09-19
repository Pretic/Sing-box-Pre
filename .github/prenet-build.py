from pathlib import Path
import hashlib
p=Path('sing-box.sh')
s=p.read_text()
assert hashlib.sha256(p.read_bytes()).hexdigest() == 'c291e7c8f075945fc60932a3a4d47e937672b554ebedbb2b3202276284cc2fee'
h=Path('.github/prenet-active-health.sh')
assert hashlib.sha256(h.read_bytes()).hexdigest() == 'c330a0b0e6dac68c55e3dc3928463b7820ebddbc5fc7cbb0a2734dc5e947bb8c'
a=s.index('probe_active_warp() {')
s=s[:a]+h.read_text()+'\n'+s[a:]
a=s.index('probe_active_warp() {');b=s.index('\n}\n',a)+3
s=s[:a]+'''probe_active_warp() {
    local family="${1:-}" rc=0
    [ -n "$family" ] || family=$(get_warp_preferred_family)
    case "$family" in 4|6) ;; *) return 1 ;; esac
    start_warp_active_proxy "$family" || return $?
    probe_warp_trace "$WARP_PROBE_PROXY" || rc=$?
    stop_warp_candidate_proxy
    return "$rc"
}
'''+s[b:]
for name in ['verify_activated_warp','show_warp_status_and_unlocks']:
    a=s.index(name+'() {');b=s.index('\n}\n',a)+3;f=s[a:b]
    assert 'start_warp_candidate_proxy "$endpoint" "$family"' in f
    f=f.replace('start_warp_candidate_proxy "$endpoint" "$family"','start_warp_active_proxy "$family"')
    f=f.replace('无法启动内置 WARP 临时探测代理。','无法使用正式服务的 WARP 健康入口。')
    f=f.replace('正在检测内置 WARP 连通性（握手最多等待 30 秒）...','正在通过正式服务检测 WARP（首次准备本机健康入口时会重启一次核心）...')
    s=s[:a]+f+s[b:]
s=s.replace('unset WARP_PROBE_PID WARP_PROBE_DIR WARP_PROBE_PROXY WARP_PROBE_PORT WARP_PROBE_FAMILY WARP_PROBE_BINARY','unset WARP_PROBE_PID WARP_PROBE_DIR WARP_PROBE_PROXY WARP_PROBE_PORT WARP_PROBE_FAMILY WARP_PROBE_BINARY WARP_PROBE_MODE WARP_PROBE_CURL_ARGS')
s=s.replace('    curl "$@" || rc=$?', '    curl -q "${WARP_PROBE_CURL_ARGS[@]}" --noproxy \'\' "$@" || rc=$?')
s=s.replace('if trace=$(curl -fsS --connect-timeout 5', 'if trace=$(curl -q "${WARP_PROBE_CURL_ARGS[@]}" --noproxy \'\' -fsS --connect-timeout 5')
s=s.replace('        --cfy) manage_cfy ;;', '        --cfy) manage_cfy ;;\n        --warp-health) show_warp_health ;;')
s=s.replace('            green "      --cfy         进入 Cloudflare优选 菜单"','            green "      --cfy         进入 Cloudflare优选 菜单"\n            green "      --warp-health 正式服务 WARP 双栈检查（首次会准备本机健康入口）"')
p.write_text(s)
assert hashlib.sha256(p.read_bytes()).hexdigest() == '748583831715430e1759f408df9c53b896b7f93b88eba5bea83b8d88d94530df'
for name in ['test_warp_ipv6_activation_verification.sh','test_warp_status_progress.sh']:
    p=Path('tests')/name
    p.write_text(p.read_text().replace('start_warp_candidate_proxy','start_warp_active_proxy'))
