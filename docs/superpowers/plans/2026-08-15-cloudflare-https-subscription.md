# Cloudflare HTTPS 订阅公开版 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Sing-box-Pre 的单文件 Bash 脚本中增加用户自有域名的可选 Cloudflare HTTPS 订阅，同时保持默认 HTTP、现有节点链路、NAT/单双栈兼容和当前首页不变。

**Architecture:** `sing-box.sh` 继续作为可独立下载运行的单文件入口；新增的状态、URL、Nginx、Tunnel 和 Cloudflare API 逻辑都以边界清晰的函数组留在该文件。`/etc/sing-box/sub.txt` 仍是唯一原始订阅内容，Nginx 负责精确路径发布，现有 cloudflared 固定 Tunnel 只为订阅增加一条 ingress；纯函数和外部调用通过 shell fixture 测试，不依赖真实 Cloudflare 账户。

**Tech Stack:** Bash、Nginx、cloudflared、curl、jq、awk/sed、Git Bash 测试。

---

## 文件结构

- Modify: `sing-box.sh` — 全部运行时代码；仓库以远程 one-liner 执行该文件，不能拆成安装时不可获取的外部 shell 库。
- Modify: `README.md` — 用户流程、域名模式、权限、NAT 和隐私说明。
- Create: `tests/test_subscription_state.sh` — 密钥、白名单状态解析、域名和路径校验。
- Create: `tests/test_subscription_urls_qr.sh` — HTTPS 优先、HTTP 回退、空值保护和 QR 调用。
- Create: `tests/test_subscription_nginx.sh` — Nginx 精确路径与安全头渲染。
- Create: `tests/test_subscription_tunnel_local.sh` — 本地 YAML ingress 顺序、幂等和保留规则。
- Create: `tests/test_subscription_tunnel_remote.sh` — 远程 JSON ingress 变换、DNS 回滚数据与未知字段保留。
- Create: `tests/test_subscription_menu.sh` — 首页不变、二级菜单和无私有 VPS 特例。
- Modify: `docs/superpowers/specs/2026-08-15-cloudflare-https-subscription-design.md` — 实现完成后把状态改为“已实现”，不改变已批准范围。

## 约束

- 不修改 `Pre-cfy`。
- 不包含当前自用 VPS 的 Python 服务、8081、专用状态文件、域名或密钥。
- 不新增常驻服务或第二个 cloudflared。
- 每一任务先写失败测试，再写最小实现，再提交。
- 所有外部文件替换必须临时文件 + 校验 + 原子移动；所有 Tunnel/Nginx 修改必须可回滚。
- Cloudflare API token 只用 `read -r -s` 进入内存变量，curl 使用临时 header 文件或函数参数，完成后 `unset`，不进入状态文件和日志。

### Task 1: 订阅密钥、状态和输入校验

**Files:**
- Create: `tests/test_subscription_state.sh`
- Modify: `sing-box.sh:24-48`
- Modify: `sing-box.sh:52-107`

- [ ] **Step 1: 写失败测试**

创建 `tests/test_subscription_state.sh`。测试只提取函数，不执行脚本顶层 root/install 逻辑：

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"

extract() {
    sed -n "/^$1() {/,/^}/p" "$script"
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
subscription_state_file="$work_dir/subscription.conf"

source <(extract is_valid_subscription_token)
source <(extract generate_subscription_token)
source <(extract is_valid_subscription_domain)
source <(extract is_valid_subscription_path)
source <(extract atomic_write_file)
source <(extract reset_subscription_state)
source <(extract load_subscription_state)
source <(extract save_subscription_state)

for _ in {1..40}; do
    token="$(generate_subscription_token)"
    [[ "$token" =~ ^[0123456789abcdefghjkmnpqrstvwxyz]{32}$ ]]
done

is_valid_subscription_domain 'sub.example.com'
! is_valid_subscription_domain 'https://sub.example.com/path'
! is_valid_subscription_domain '*.example.com'
! is_valid_subscription_domain '-bad.example.com'
is_valid_subscription_path '/sub/0123456789abcdefghjkmnpqrstvwxyz'
! is_valid_subscription_path '/../etc/passwd'

cat > "$subscription_state_file" <<'STATE'
SUB_TOKEN=0123456789abcdefghjkmnpqrstvwxyz
SUB_HTTP_PATH=/0123456789abcdefghjkmnpqrstvwxyz
SUB_HTTPS_ENABLED=1
SUB_HTTPS_DOMAIN=Sub.Example.com
SUB_HTTPS_DOMAIN_MODE=separate
SUB_HTTPS_PATH=/0123456789abcdefghjkmnpqrstvwxyz
SUB_TUNNEL_MODE=remote
SUB_HTTPS_VERIFIED_AT=2026-08-15T00:00:00Z
EVIL=$(touch /tmp/subscription-state-pwned)
STATE

load_subscription_state
[[ "$SUB_HTTPS_DOMAIN" == 'sub.example.com' ]]
[[ "$SUB_HTTPS_ENABLED" == 1 ]]
[[ ! -e /tmp/subscription-state-pwned ]]

save_subscription_state
[[ "$(stat -c '%a' "$subscription_state_file")" == 600 ]]
! grep -q '^EVIL=' "$subscription_state_file"

echo 'Subscription state tests passed.'
```

- [ ] **Step 2: 运行测试并确认失败**

Run:

```bash
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_state.sh
```

Expected: FAIL，提示 `generate_subscription_token` 或其他目标函数未实现。

- [ ] **Step 3: 增加常量和完整状态 helper**

在 `work_dir` 常量后增加：

```bash
subscription_state_file="${work_dir}/subscription.conf"
subscription_token_alphabet='0123456789abcdefghjkmnpqrstvwxyz'
```

在 `atomic_write_file` 后实现：

```bash
is_valid_subscription_token() {
    [[ "${1:-}" =~ ^[0123456789abcdefghjkmnpqrstvwxyz]{32}$ ]]
}

generate_subscription_token() {
    od -An -N32 -tu1 /dev/urandom | awk \
        -v alphabet='0123456789abcdefghjkmnpqrstvwxyz' '
        {
            for (i = 1; i <= NF; i++) {
                printf "%s", substr(alphabet, ($i % 32) + 1, 1)
            }
        }
        END { print "" }
    '
}

is_valid_subscription_domain() {
    local domain label
    domain="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$domain" == *.* && "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" != -* && "$label" != *- ]] || return 1
    done
}

is_valid_subscription_path() {
    [[ "${1:-}" =~ ^/(sub/)?[0123456789abcdefghjkmnpqrstvwxyz]{32}$ ]]
}

reset_subscription_state() {
    SUB_TOKEN=''
    SUB_HTTP_PATH=''
    SUB_HTTPS_ENABLED=0
    SUB_HTTPS_DOMAIN=''
    SUB_HTTPS_DOMAIN_MODE=''
    SUB_HTTPS_PATH=''
    SUB_TUNNEL_MODE=''
    SUB_HTTPS_VERIFIED_AT=''
}

load_subscription_state() {
    local key value
    reset_subscription_state
    [ -r "$subscription_state_file" ] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
            SUB_TOKEN) is_valid_subscription_token "$value" && SUB_TOKEN="$value" ;;
            SUB_HTTP_PATH) is_valid_subscription_path "$value" && SUB_HTTP_PATH="$value" ;;
            SUB_HTTPS_ENABLED) [[ "$value" == 0 || "$value" == 1 ]] && SUB_HTTPS_ENABLED="$value" ;;
            SUB_HTTPS_DOMAIN)
                value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
                is_valid_subscription_domain "$value" && SUB_HTTPS_DOMAIN="$value"
                ;;
            SUB_HTTPS_DOMAIN_MODE) [[ "$value" == reuse || "$value" == separate ]] && SUB_HTTPS_DOMAIN_MODE="$value" ;;
            SUB_HTTPS_PATH) is_valid_subscription_path "$value" && SUB_HTTPS_PATH="$value" ;;
            SUB_TUNNEL_MODE) [[ "$value" == local || "$value" == remote ]] && SUB_TUNNEL_MODE="$value" ;;
            SUB_HTTPS_VERIFIED_AT) [[ "$value" =~ ^[0-9T:Z+.-]+$ ]] && SUB_HTTPS_VERIFIED_AT="$value" ;;
        esac
    done < "$subscription_state_file"
    [ "$SUB_HTTPS_ENABLED" = 1 ] &&
        is_valid_subscription_domain "$SUB_HTTPS_DOMAIN" &&
        is_valid_subscription_path "$SUB_HTTPS_PATH" &&
        [ -n "$SUB_HTTPS_VERIFIED_AT" ] || SUB_HTTPS_ENABLED=0
}

save_subscription_state() {
    {
        printf 'SUB_TOKEN=%s\n' "$SUB_TOKEN"
        printf 'SUB_HTTP_PATH=%s\n' "$SUB_HTTP_PATH"
        printf 'SUB_HTTPS_ENABLED=%s\n' "$SUB_HTTPS_ENABLED"
        printf 'SUB_HTTPS_DOMAIN=%s\n' "$SUB_HTTPS_DOMAIN"
        printf 'SUB_HTTPS_DOMAIN_MODE=%s\n' "$SUB_HTTPS_DOMAIN_MODE"
        printf 'SUB_HTTPS_PATH=%s\n' "$SUB_HTTPS_PATH"
        printf 'SUB_TUNNEL_MODE=%s\n' "$SUB_TUNNEL_MODE"
        printf 'SUB_HTTPS_VERIFIED_AT=%s\n' "$SUB_HTTPS_VERIFIED_AT"
    } | atomic_write_file "$subscription_state_file" 600
}
```

`generate_subscription_token` 必须在 GNU awk 与 BusyBox awk 下都只使用 POSIX awk 语法；状态 helper 必须在 Bash 4+ 下通过上述原样测试，不得通过放宽校验来绕过失败。

- [ ] **Step 4: 运行状态测试和语法检查**

Run:

```bash
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_state.sh
"C:/Program Files/Git/bin/bash.exe" -n sing-box.sh
```

Expected: `Subscription state tests passed.`，语法检查退出码 0。

- [ ] **Step 5: 提交**

```bash
git add sing-box.sh tests/test_subscription_state.sh
git commit -m "feat: add safe subscription state helpers"
```

### Task 2: 共享 URL 解析和终端二维码

**Files:**
- Create: `tests/test_subscription_urls_qr.sh`
- Modify: `sing-box.sh:237-291`
- Modify: `sing-box.sh:842-963`
- Modify: `sing-box.sh:1851-1909`
- Modify: `sing-box.sh:2498,2592,2694`

- [ ] **Step 1: 写 URL 与 QR 失败测试**

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/sing-box.sh"
extract() { sed -n "/^$1() {/,/^}/p" "$script"; }

source <(extract is_valid_subscription_domain)
source <(extract is_valid_subscription_path)
source <(extract build_http_subscription_url)
source <(extract build_https_subscription_url)
source <(extract resolve_subscription_source_url)
source <(extract render_terminal_qr)

url="$(build_http_subscription_url '2001:db8::1' 8080 '/0123456789abcdefghjkmnpqrstvwxyz')"
[[ "$url" == 'http://[2001:db8::1]:8080/0123456789abcdefghjkmnpqrstvwxyz' ]]
! build_http_subscription_url '203.0.113.10' '' '/0123456789abcdefghjkmnpqrstvwxyz'
! build_http_subscription_url '' 8080 '/0123456789abcdefghjkmnpqrstvwxyz'

SUB_HTTPS_ENABLED=1
SUB_HTTPS_DOMAIN='sub.example.com'
SUB_HTTPS_PATH='/0123456789abcdefghjkmnpqrstvwxyz'
SUB_HTTPS_VERIFIED_AT='2026-08-15T00:00:00Z'
[[ "$(resolve_subscription_source_url '203.0.113.10' 8080 '/0123456789abcdefghjkmnpqrstvwxyz')" == \
   'https://sub.example.com/0123456789abcdefghjkmnpqrstvwxyz' ]]

SUB_HTTPS_ENABLED=0
[[ "$(resolve_subscription_source_url '203.0.113.10' 8080 '/0123456789abcdefghjkmnpqrstvwxyz')" == \
   'http://203.0.113.10:8080/0123456789abcdefghjkmnpqrstvwxyz' ]]

! resolve_subscription_source_url '203.0.113.10' '' ''
! grep -Eq 'qrencode" +"\$' "$script"
grep -q 'qrencode -t ANSIUTF8 -m 1 --' "$script"

echo 'Subscription URL and QR tests passed.'
```

- [ ] **Step 2: 运行并确认失败**

Run: `"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_urls_qr.sh`

Expected: FAIL，提示 URL helper 缺失。

- [ ] **Step 3: 实现 URL 与 QR helper**

```bash
build_http_subscription_url() {
    local host="${1:-}" port="${2:-}" path="${3:-}"
    [ -n "$host" ] && [[ "$port" =~ ^[0-9]+$ ]] &&
        [ "$port" -ge 1 ] && [ "$port" -le 65535 ] &&
        is_valid_subscription_path "$path" || return 1
    host="$(format_url_host "$host")"
    [ "$port" = 80 ] && printf 'http://%s%s\n' "$host" "$path" ||
        printf 'http://%s:%s%s\n' "$host" "$port" "$path"
}

build_https_subscription_url() {
    local domain="${1:-}" path="${2:-}"
    is_valid_subscription_domain "$domain" &&
        is_valid_subscription_path "$path" || return 1
    printf 'https://%s%s\n' "$domain" "$path"
}

resolve_subscription_source_url() {
    local host="${1:-}" port="${2:-}" path="${3:-}" url
    if [ "${SUB_HTTPS_ENABLED:-0}" = 1 ] && [ -n "${SUB_HTTPS_VERIFIED_AT:-}" ]; then
        url="$(build_https_subscription_url "$SUB_HTTPS_DOMAIN" "$SUB_HTTPS_PATH" 2>/dev/null)" &&
            { printf '%s\n' "$url"; return 0; }
    fi
    build_http_subscription_url "$host" "$port" "$path"
}

render_terminal_qr() {
    local url="${1:-}" encoder="${QR_ENCODER:-${work_dir}/qrencode}"
    [ -n "$url" ] && [ -t 1 ] && [ -x "$encoder" ] || return 0
    "$encoder" -t ANSIUTF8 -m 1 -- "$url" 2>/dev/null || true
}
```

增加 `show_subscription_links`，集中输出原始、Clash/Mihomo、Sing-box、Surge 四组 URL；`source_url` 为空时只显示“订阅未配置”，不得调用二维码。所有旧直接调用改为 `render_terminal_qr`。

- [ ] **Step 4: 运行测试**

Run:

```bash
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_urls_qr.sh
"C:/Program Files/Git/bin/bash.exe" -n sing-box.sh
```

Expected: PASS；`rg -n 'qrencode" "' sing-box.sh` 无输出。

- [ ] **Step 5: 提交**

```bash
git add sing-box.sh tests/test_subscription_urls_qr.sh
git commit -m "fix: centralize subscription links and terminal QR output"
```

### Task 3: Nginx 精确路径、安全头和旧配置迁移

**Files:**
- Create: `tests/test_subscription_nginx.sh`
- Modify: `sing-box.sh:966-1044`
- Modify: `sing-box.sh:1545-1620`

- [ ] **Step 1: 写 Nginx 渲染失败测试**

测试提取 `render_nginx_subscription_server`，传入端口、HTTP 路径和可选 HTTPS 路径，断言：

```bash
config="$(render_nginx_subscription_server 8080 \
  '/0123456789abcdefghjkmnpqrstvwxyz' \
  '/sub/0123456789abcdefghjkmnpqrstvwxyz')"

grep -q 'listen 8080;' <<< "$config"
grep -q 'listen \[::\]:8080;' <<< "$config"
[[ "$(grep -c 'alias /etc/sing-box/sub.txt;' <<< "$config")" == 2 ]]
grep -q 'location = /0123456789abcdefghjkmnpqrstvwxyz {' <<< "$config"
grep -q 'location = /sub/0123456789abcdefghjkmnpqrstvwxyz {' <<< "$config"
grep -q 'Cache-Control "private, no-store"' <<< "$config"
grep -q 'access_log off;' <<< "$config"
grep -q 'location / { return 404; }' <<< "$config"
! grep -q 'autoindex on' <<< "$config"
```

另测 HTTP/HTTPS 路径相同只生成一个 location，非法端口/路径返回失败。

- [ ] **Step 2: 运行并确认失败**

Run: `"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_nginx.sh`

Expected: FAIL，函数未实现。

- [ ] **Step 3: 实现纯渲染和事务应用**

`render_nginx_subscription_server` 只向 stdout 生成配置；内部 helper `render_nginx_subscription_location` 生成：

```nginx
location = /<validated-path> {
    alias /etc/sing-box/sub.txt;
    default_type 'text/plain; charset=utf-8';
    add_header Cache-Control "private, no-store";
    add_header X-Content-Type-Options nosniff;
    access_log off;
    log_not_found off;
}
```

`apply_nginx_subscription_config` 的顺序固定为：

1. 校验端口和路径。
2. 在同目录创建临时文件，渲染配置。
3. 备份现有 `sing-box.conf` 为权限 600 的单次事务备份。
4. 原子替换后执行 `nginx -t`。
5. 成功时 reload/start；失败时恢复备份并再次 `nginx -t`。
6. 不先 `pkill nginx`，避免无必要中断。
7. 订阅文件保持 root 可写、Nginx worker 可读；沿用 644，README 解释原因。

重写 `add_nginx_conf` 调用该事务 helper。重写订阅菜单 1-4：

- 1 停止 Nginx，明确 HTTP/HTTPS 都停止。
- 2 若 Nginx 配置存在则启动；不存在时使用当前安装变量或新 32 字符密钥创建。
- 3 校验 1-65535、占用、备份和回滚；复用现有两个路径。
- 4 只重启 Nginx。

- [ ] **Step 4: 运行测试**

Run:

```bash
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_nginx.sh
"C:/Program Files/Git/bin/bash.exe" -n sing-box.sh
```

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add sing-box.sh tests/test_subscription_nginx.sh
git commit -m "feat: harden nginx subscription publishing"
```

### Task 4: 本地管理 Tunnel ingress 变换

**Files:**
- Create: `tests/test_subscription_tunnel_local.sh`
- Modify: `sing-box.sh:338-396`
- Modify: `sing-box.sh:1648-1748`

- [ ] **Step 1: 写 YAML fixture 失败测试**

fixture 包含节点规则、`originRequest`、另一个应用和最终 404。测试 `render_local_tunnel_with_subscription INPUT OUTPUT DOMAIN REGEX PORT`：

- 复用域名的订阅规则位于相同 hostname 的无 path 节点规则之前。
- 独立域名规则位于最终 catch-all 之前。
- 最后一条仍为 `http_status:404`。
- 重复执行只保留一个 `# sing-box-subscription:start`。
- `originRequest` 和无关应用逐字保留。
- 删除 helper 只删除标记块。
- 非法或缺失 catch-all 返回非零且不写输出文件。

核心断言：

```bash
render_local_tunnel_with_subscription \
  "$fixture" "$out" 'argo.example.com' \
  '^/sub/0123456789abcdefghjkmnpqrstvwxyz$' 8080

sub_line="$(grep -n 'sing-box-subscription:start' "$out" | cut -d: -f1)"
node_line="$(grep -n 'hostname: argo.example.com' "$out" | tail -1 | cut -d: -f1)"
[[ "$sub_line" -lt "$node_line" ]]
[[ "$(grep -c 'sing-box-subscription:start' "$out")" == 1 ]]
tail -n 1 "$out" | grep -q 'service: http_status:404'
```

- [ ] **Step 2: 运行并确认失败**

Run: `"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_tunnel_local.sh`

Expected: FAIL，YAML helper 缺失。

- [ ] **Step 3: 实现受控标记块变换**

新增：

- `detect_argo_tunnel_mode`：读取 systemd/OpenRC 服务；`--url` => quick，`--config` 且配置存在 => local，`--token` => remote。
- `remove_managed_subscription_yaml_block`：只删除两个固定 marker 之间内容，缺失配对 marker 时失败。
- `render_local_tunnel_with_subscription`：用 awk 保留原行；复用域名时在首个同 hostname 无 path 规则前插入，独立域名时在 catch-all 前插入。
- `apply_local_tunnel_subscription_rule`：权限 600 备份、原子替换、执行：

```bash
"${work_dir}/argo" tunnel --config "$tunnel_config" ingress validate
"${work_dir}/argo" tunnel --config "$tunnel_config" ingress rule "https://${domain}${public_path}"
```

两项均成功才重启 Argo。重启或验证失败恢复备份；回滚后再次启动原配置。

Managed block 格式固定为：

```yaml
  # sing-box-subscription:start
  - hostname: sub.example.com
    path: ^/0123456789abcdefghjkmnpqrstvwxyz$
    service: http://127.0.0.1:8080
  # sing-box-subscription:end
```

- [ ] **Step 4: 运行本地 Tunnel 与现有 Argo 测试**

Run:

```bash
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_tunnel_local.sh
"C:/Program Files/Git/bin/bash.exe" tests/test_fixed_argo_client_address.sh
"C:/Program Files/Git/bin/bash.exe" tests/test_dual_argo_client_addresses.sh
```

Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add sing-box.sh tests/test_subscription_tunnel_local.sh
git commit -m "feat: manage local tunnel subscription ingress"
```

### Task 5: 远程 Tunnel API 变换、DNS 与回滚

**Files:**
- Create: `tests/test_subscription_tunnel_remote.sh`
- Modify: `sing-box.sh`（紧随本地 Tunnel helper）

- [ ] **Step 1: 写 JSON fixture 失败测试**

测试纯函数 `build_remote_tunnel_config`。输入 Cloudflare `result.config` fixture，包含未知顶层字段、两个 ingress、`originRequest` 和 catch-all。断言：

```bash
updated="$(build_remote_tunnel_config \
  "$fixture" 'argo.example.com' \
  '^/sub/0123456789abcdefghjkmnpqrstvwxyz$' \
  'http://127.0.0.1:8080' reuse '' '')"

jq -e '.warpRouting.enabled == true' <<< "$updated"
jq -e '.ingress[-1].service == "http_status:404"' <<< "$updated"
jq -e '.ingress[0].hostname == "argo.example.com"
       and .ingress[0].path == "^/sub/0123456789abcdefghjkmnpqrstvwxyz$"' <<< "$updated"
jq -e '.ingress[1].originRequest.noTLSVerify == true' <<< "$updated"
[[ "$(jq '[.ingress[] | select(.path == "^/sub/0123456789abcdefghjkmnpqrstvwxyz$")] | length' <<< "$updated")" == 1 ]]
```

再传旧 domain/path，断言只替换旧订阅规则；无 catch-all、非法 JSON 或目标节点规则缺失时返回失败。DNS fixture 测试 `build_dns_change_plan` 区分 create/update/noop，并保留旧 record 供回滚。

- [ ] **Step 2: 运行并确认失败**

Run: `"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_tunnel_remote.sh`

Expected: FAIL，远程 helper 缺失。

- [ ] **Step 3: 实现纯 jq 变换**

`build_remote_tunnel_config` 接收当前 config、目标 host/path/service、模式和旧 host/path：

1. 验证 `.ingress` 是数组且最后为 catch-all。
2. 若旧 host/path 都有效，只删除完全匹配旧 host/path 的规则。
3. 删除完全匹配新 host/path/service 的重复项。
4. reuse 模式在同 host 且无 path 的第一条规则前插入。
5. separate 模式在最终 catch-all 前插入。
6. 其他字段和规则原样保留。

不要给 Cloudflare JSON 添加自定义 marker 字段；本功能的 ownership 由 `subscription.conf` 中的旧 host/path 识别。

- [ ] **Step 4: 实现 API/DNS 事务函数**

新增：

```bash
cloudflare_api() {
    local method="$1" url="$2" body_file="${3:-}"
    local args=(-fsS -X "$method" "$url"
        -H "Authorization: Bearer $CF_API_TOKEN"
        -H 'Content-Type: application/json')
    [ -n "$body_file" ] && args+=(--data-binary "@$body_file")
    curl "${args[@]}"
}
```

`apply_remote_tunnel_subscription_rule`：

- `read -r` Account ID/Tunnel ID；`read -r -s` API token。
- GET `/accounts/<account>/cfd_tunnel/<tunnel>/configurations`。
- 验证 `.success == true`，只保存 `.result.config` 到权限 600 临时文件。
- 用纯函数生成新 config，再包装为 `{"config": ...}` PUT。
- separate 模式询问 Zone ID，GET 同名 DNS；已有正确 CNAME 为 noop，否则 update/create。
- 任何后续步骤失败：PUT 旧 config；DNS update 恢复旧 record，DNS create 删除新 record。
- 无论成功失败都 `unset CF_API_TOKEN` 并删除权限 600 临时目录。
- API response、token、完整 curl 命令不输出。

手动模式打印准确 Hostname、锚定 Path、HTTP、`http://localhost:<port>`，等待用户确认后进入公网验证。

- [ ] **Step 5: 运行远程 fixture 测试**

Run:

```bash
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_tunnel_remote.sh
"C:/Program Files/Git/bin/bash.exe" -n sing-box.sh
```

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add sing-box.sh tests/test_subscription_tunnel_remote.sh
git commit -m "feat: configure remote tunnel subscriptions safely"
```

### Task 6: HTTPS 配置编排、验证、关闭和轮换

**Files:**
- Create: `tests/test_subscription_menu.sh`
- Modify: `sing-box.sh:1545-1620`
- Modify: `sing-box.sh:1648-1748`

- [ ] **Step 1: 写菜单与隔离失败测试**

静态/函数测试断言：

```bash
for item in \
  '5. 查看订阅链接与详细状态' \
  '6. 配置 Cloudflare HTTPS 订阅' \
  '7. 关闭 Cloudflare HTTPS 订阅' \
  '8. 重新生成订阅密钥'; do
    grep -Fq "$item" "$script"
done

menu_source="$(sed -n '/^menu() {/,/^}/p' "$script")"
! grep -q 'HTTPS 订阅' <<< "$menu_source"
grep -q -- '--Nginx 状态:' <<< "$menu_source"

! rg -n 'sing-box-subscription\.service|sing-box-subscription\.py|subscription-path|988600\.xyz|localhost:8081' \
  sing-box.sh README.md
```

另外测试 `verify_https_subscription` 使用本地 mock curl：内容相同返回 0，内容不同返回非零且不写 `SUB_HTTPS_VERIFIED_AT`。

- [ ] **Step 2: 运行并确认失败**

Run: `"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_menu.sh`

Expected: FAIL，二级菜单项缺失。

- [ ] **Step 3: 实现公网验证**

`verify_https_subscription URL`：

- 创建权限 600 临时目录。
- `curl -fsS --compressed --retry 2 --connect-timeout 10 --max-time 30` GET URL。
- 本地与远端内容先严格 `cmp`；若只差最终换行，再比较去除 CR/LF 的内容。
- 成功返回 0；失败返回 1；不直接写状态。
- 调用者只有在 Nginx、本地/API/手动 Tunnel 与公网内容全部成功后，才设置 UTC `SUB_HTTPS_VERIFIED_AT`、`SUB_HTTPS_ENABLED=1` 并保存。

- [ ] **Step 4: 实现配置编排**

`configure_cf_https_subscription`：

1. `load_subscription_state` 并检测 Tunnel；quick 直接拒绝。
2. 让用户选“复用当前 Argo 域名（推荐）/独立域名”。
3. 校验用户域名；reuse 必须等于当前固定 Argo hostname。
4. 现有 token 非 32 字符时提示旧 URL 会失效；明确确认后生成新 token。
5. 计算 HTTP path 与 HTTPS path，先事务更新 Nginx。
6. local 调本地 YAML 事务；remote 让用户选 API/手动。
7. 公网验证成功后一次性保存状态。
8. 任何失败恢复 Nginx、Tunnel/API/DNS 和旧状态，HTTP 原链接仍可用。

`disable_cf_https_subscription`：

- local 删除 managed YAML block、validate、restart。
- remote API 模式按旧 host/path 删除精确规则并保留其他配置。
- remote manual 打印删除值并要求用户确认。
- 成功后只清空 HTTPS enabled/domain/mode/path/verified 字段，保留 HTTP path 和 Nginx。

`rotate_subscription_token`：

- 先生成新 token，显示旧 URL 将失效。
- 以旧状态作为回滚数据，依次更新 Nginx、Tunnel、验证、状态。
- remote manual 必须让用户完成新 route 后才删除旧 route；验证失败恢复旧 Nginx/状态。
- 不修改节点 UUID 和 `sub.txt` 内容。

- [ ] **Step 5: 接入二级菜单与固定 Tunnel 提示**

扩展 `disable_open_sub` 到 0-8 菜单。选项 5 调详细状态，6/7/8 调上述编排。

固定 Tunnel 添加成功后仅在交互终端提示：

```bash
if [ -t 0 ]; then
    reading '是否同时配置 Cloudflare HTTPS 订阅？[y/N]: ' enable_https
    [[ "$enable_https" =~ ^[Yy]$ ]] && configure_cf_https_subscription
fi
```

默认 N，不影响无交互安装和旧用户更新。

- [ ] **Step 6: 运行测试**

Run:

```bash
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_menu.sh
"C:/Program Files/Git/bin/bash.exe" -n sing-box.sh
```

Expected: PASS；首页函数中无 HTTPS 详情。

- [ ] **Step 7: 提交**

```bash
git add sing-box.sh tests/test_subscription_menu.sh
git commit -m "feat: add optional HTTPS subscription workflow"
```

### Task 7: 安装、查看节点和 NAT 回退集成

**Files:**
- Modify: `sing-box.sh:842-963`
- Modify: `sing-box.sh:1213-1242`
- Modify: `sing-box.sh:1851-1909`
- Modify: `tests/test_subscription_urls_qr.sh`
- Modify: `tests/test_subscription_menu.sh`

- [ ] **Step 1: 扩充失败测试**

增加 fixture 覆盖：

- 新装尚无 Nginx 文件时，安装变量 `sub_host/nginx_port/password` 能生成 HTTP URL。
- 已安装 HTTPS verified 时 `check_nodes` 选择 HTTPS。
- HTTPS state 非法或未验证时回退 Nginx HTTP。
- Nginx 配置缺失端口或路径时显示“订阅未配置”，不出现 `http://IP:/` 或 `config=`。
- NAT 场景只要求本机 Nginx origin；不调用公网 HTTP 可达探测。
- IPv6 host 正确加方括号。

- [ ] **Step 2: 运行并确认新增断言失败**

Run:

```bash
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_urls_qr.sh
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_menu.sh
```

Expected: 至少一项新增断言 FAIL。

- [ ] **Step 3: 集成共享 resolver**

- `get_info` 在输出链接前 `load_subscription_state`，使用安装期有效端口/路径调用 `resolve_subscription_source_url` 和 `show_subscription_links`。
- `check_nodes` 从 Nginx 精确解析有效 port/path，再调用相同 resolver。
- 增加 `get_nginx_subscription_port` 和 `get_nginx_http_subscription_path`；只接受校验通过的值。
- `check_nodes` 的节点与 cfy 显示保持原样。
- 转换链接继续使用 `sublink.eooce.com`，详细页输出第三方会看到原始 URL/密钥的提示。
- `auto_install` 和交互安装不询问 HTTPS，顺序确保 `sub.txt` 与 Nginx 都建立后输出正确链接。
- `--update` 仍只更新快捷脚本，不改状态或 Tunnel。

- [ ] **Step 4: 运行全部测试**

Run:

```bash
for test_file in tests/*.sh; do
  "C:/Program Files/Git/bin/bash.exe" "$test_file"
done
"C:/Program Files/Git/bin/bash.exe" -n sing-box.sh
```

Expected: 所有测试 PASS，语法检查退出 0。

- [ ] **Step 5: 提交**

```bash
git add sing-box.sh tests
git commit -m "fix: integrate verified subscription source selection"
```

### Task 8: README、规格状态和安全回归

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-15-cloudflare-https-subscription-design.md`
- Modify: `tests/test_subscription_menu.sh`

- [ ] **Step 1: 写文档静态失败测试**

增加断言 README 必须包含：

- “默认 HTTP”
- “Cloudflare HTTPS 订阅”
- “复用固定 Argo 域名”
- “独立订阅域名”
- “Cloudflare Tunnel/Connector Write”
- “DNS Write”
- “NAT”
- “第三方转换”
- “32”
- “轮换”

并确认没有作者域名或当前 VPS 特例。

- [ ] **Step 2: 运行并确认失败**

Run: `"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_menu.sh`

Expected: FAIL，README 新章节缺失。

- [ ] **Step 3: 更新 README**

新增“可选 Cloudflare HTTPS 订阅”章节，准确说明：

- 默认安装和 `--update` 不启用、不修改 HTTPS。
- 两种域名模式和推荐顺序。
- 临时 Tunnel 不支持稳定 HTTPS。
- local JSON 自动改 ingress；remote token 支持 API 或 Dashboard。
- API 最小权限及 token 不保存。
- NAT/IPv6-only 无需公网订阅端口。
- 原始订阅的客户端范围与三种第三方转换链接。
- 第三方转换可见原始 URL/密钥。
- 关闭 Nginx、关闭 HTTPS、轮换密钥的不同影响。
- HTTPS 失败回退 HTTP，不影响节点。
- 无 ACME 依赖和无额外常驻进程。

把设计规格状态从“待用户审阅”改为“已批准并实现”，仅在全部测试已通过后执行。

- [ ] **Step 4: 运行安全与文档测试**

Run:

```bash
"C:/Program Files/Git/bin/bash.exe" tests/test_subscription_menu.sh
rg -n 'cfut_|988600\.xyz|sing-box-subscription\.py|subscription-path|localhost:8081' \
  sing-box.sh README.md tests docs/superpowers
```

Expected: 测试 PASS；`rg` 只允许设计文档“禁止包含”说明中的占位名称，不得出现真实 token/域名或运行时代码引用。

- [ ] **Step 5: 提交**

```bash
git add README.md tests/test_subscription_menu.sh \
  docs/superpowers/specs/2026-08-15-cloudflare-https-subscription-design.md
git commit -m "docs: explain optional HTTPS subscriptions"
```

### Task 9: 最终验证、主分支整合和推送

**Files:**
- Verify only; no planned product edits.

- [ ] **Step 1: 使用 verification-before-completion 检查工作树**

Run:

```bash
git status --short
git diff main...HEAD --check
"C:/Program Files/Git/bin/bash.exe" -n sing-box.sh
for test_file in tests/*.sh; do
  "C:/Program Files/Git/bin/bash.exe" "$test_file"
done
```

Expected: 状态干净、diff check 退出 0、全部测试 PASS。

- [ ] **Step 2: 检查范围和秘密**

Run:

```bash
git diff --stat main...HEAD
git log --oneline main..HEAD
git diff main...HEAD -- cfy
rg -n 'cfut_|988600\.xyz|sing-box-subscription\.service|sing-box-subscription\.py|subscription-path|localhost:8081' \
  sing-box.sh README.md tests
```

Expected: 只修改 Sing-box-Pre 计划文件；cfy diff 为空；无当前 VPS 私有实现或 token。

- [ ] **Step 3: 使用 finishing-a-development-branch 完成分支**

在原仓库执行：

```bash
git checkout main
git merge --ff-only feature/cloudflare-https-subscriptions
```

Expected: 快进成功，不产生 merge commit；`main` 包含原先领先的设计提交和全部实现提交。

- [ ] **Step 4: 推送并验证远端一致**

```bash
git push origin main
git fetch origin
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

Expected: push 成功；状态为 `## main...origin/main`，两个 commit ID 完全相同，不再显示 `ahead 1`。

- [ ] **Step 5: 不部署当前自用 VPS**

本任务结束时明确报告：公开 GitHub 已更新，`Pre-cfy` 未改，当前自用 VPS 未同步通用脚本。只有用户另行要求并确认迁移策略时，才评估该 VPS 是否需要吸收公开功能。
