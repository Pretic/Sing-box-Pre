# Public README Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the Sing-box-Pre and Pre-cfy README files as concise public documentation for independently maintained deep forks while preserving upstream attribution and disclaimers and removing promotional links.

**Architecture:** Each repository keeps one self-contained README. Sing-box-Pre documents deployment, routing, subscriptions, and the cfy entry point; Pre-cfy documents candidate generation and the shared subscription contract without duplicating Sing-box-Pre internals. Existing scripts are the source of truth, and no runtime file changes are permitted.

**Tech Stack:** GitHub-flavored Markdown, Bash source inspection with `rg`, Git diff validation.

---

## File map

- Modify `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/sing-box-integration/README.md`: public Sing-box-Pre installation and operations guide.
- Modify `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/cfy-generation-sidecar/README.md`: public Pre-cfy installation, generation, and integration guide.
- Do not modify either project script, the Sing-box-Pre `LICENSE`, VPS state, or the six pre-existing unrelated dirty files in the Sing-box-Pre worktree.

### Task 1: Rewrite the Sing-box-Pre README

**Files:**
- Modify: `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/sing-box-integration/README.md`
- Reference: `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/sing-box-integration/sing-box.sh`
- Reference: `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/sing-box-integration/docs/superpowers/specs/2026-08-27-readme-rewrite-design.md`

- [ ] **Step 1: Record the current documentation failures**

Run:

```powershell
rg -n "img\.shields|t\.me|保留原作者信息|自用二改|只保留.*主脚本说明" README.md
```

Expected: matches for the badge wall, Telegram promotion, and temporary fork-positioning text.

- [ ] **Step 2: Replace the README with the approved information hierarchy**

Use this exact top-level order:

```markdown
# Sing-box-Pre

由 Pretic 独立维护的 sing-box 多协议 VPS 部署与管理脚本，面向普通 VPS、端口受限 NAT、IPv4/IPv6 单栈和双栈环境。

## 核心能力
## 支持环境
## 快速开始
## 端口与节点规则
## 菜单与快捷命令
## WARP 分流
## 订阅与 cfy 联动
## Cloudflare HTTPS 订阅（可选）
## 常用变量
## 文件与服务边界
## 更新与卸载
## 上游项目与致谢
## 免责声明
```

The text under those headings must state all of the following explicitly:

- Default subscription includes VLESS Reality and VLESS WS TLS Argo; UDP protocols are optional.
- NAT `PORT` allocation is Reality, subscription, TUIC, and Hysteria2 at offsets 0 through 3; one-port NAT users should prefer Argo/cfy.
- IPv4/IPv6 output follows actual stack availability and does not invent unavailable nodes.
- WARP is an internal sing-box endpoint for selected services, leaves unmatched traffic on the VPS address, and cannot promise a country, IP, or unlock result.
- WARP identity rotation is bounded to five verified candidates and preserves the old identity on failure.
- cfy is a separate project installed and called from menu item 11 or `sb --cfy`; failure does not restart or reconfigure existing services.
- HTTP subscription remains the default; Cloudflare HTTPS publication is optional and uses the user's own domain/tunnel.
- Existing node, subscription, port, and service state is not changed by `--update`.
- The upstream attribution is `eooce/Sing-box`, the author is eooce, and contributors are thanked without linking Telegram.
- The existing two disclaimer bullets are retained verbatim.

Remove the badge wall, Telegram links, advertising language, the sentence claiming that author information is retained, and duplicated update hints.

- [ ] **Step 3: Validate the Sing-box-Pre README**

Run:

```powershell
rg -n "t\.me|img\.shields|保留原作者信息|强大且易于使用" README.md
rg -n "eooce/Sing-box|## 免责声明|sb --cfy|最多尝试 5|PORT\+3" README.md
```

Expected: the first command prints nothing; the second command finds every required fact.

- [ ] **Step 4: Check Markdown structure and diff scope**

Run in WSL:

```bash
awk '/^```/{count++} END{exit count % 2}' README.md
sed -n 's/^## /## /p' README.md | sort | uniq -d
git diff --check -- README.md
git diff --name-only
```

Expected: all commands exit 0; duplicate-heading output is empty; changed files are `README.md` plus the six known pre-existing unrelated files only.

- [ ] **Step 5: Commit only the Sing-box-Pre README**

```bash
git add -- README.md
git diff --cached --check
git commit -m "docs: rewrite public project guide"
```

Expected: one commit containing only `README.md`.

### Task 2: Rewrite the Pre-cfy README

**Files:**
- Modify: `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/cfy-generation-sidecar/README.md`
- Reference: `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/cfy-generation-sidecar/cfy.sh`
- Reference: `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/sing-box-integration/docs/superpowers/specs/2026-08-27-readme-rewrite-design.md`

- [ ] **Step 1: Record the current duplication and promotions**

Run:

```powershell
rg -n "自用二改|强大且易于使用|个人博客|Telegram|联系与支持|已安装后如何更新|一键新装与运行" README.md
```

Expected: matches for promotional links and duplicated installation/update sections.

- [ ] **Step 2: Replace the README with the approved information hierarchy**

Use this exact top-level order:

```markdown
# Pre-cfy

由 Pretic 独立维护的 Cloudflare 节点优选生成器，为 Sing-box-Pre 的 VLESS WS TLS Argo 节点生成质量优先的候选入口。

## 核心能力
## 与 Sing-box-Pre 的关系
## 候选选择规则
## 快速开始
## NAT 与单双栈说明
## 常用变量
## 订阅文件与发布安全
## 依赖
## 更新与卸载
## 上游项目与致谢
## 免责声明
```

The text under those headings must state all of the following explicitly:

- VLESS WS TLS Argo is preferred; VMess is a compatibility fallback only when no VLESS template exists.
- Only the Cloudflare entry address and port change; UUID, Host, SNI, path, TLS, and other connection fields remain unchanged.
- Dual-stack output is at most three IPv4 plus three IPv6 candidates per carrier with IPv4 first; single-stack output is at most five; valid candidates are never padded.
- RTT ordering is quality-first within carrier and address-family groups.
- VPS stack detection controls the default scope; `CFY_IP_VERSION_SCOPE=both` is a client-oriented override.
- `CFY_HEALTH_PROBE=1` is optional and best used on the actual client network, not as a default VPS filter.
- cfy has its own repository, command, update lifecycle, and recent-result command; Sing-box-Pre only installs and invokes it.
- Generation and combined-subscription publication use generation binding, stable locks, atomic replacement, permission validation, and rollback.
- cfy does not add an inbound port or enter the normal proxy data path.
- The upstream attribution is `byJoey/cfy`, the author is byJoey, and the script foundation is acknowledged without blog or Telegram links.
- The existing three disclaimer bullets are retained verbatim.

Merge the three current installation/update sections into one `快速开始` section and one `更新与卸载` section. Remove the contact/support block, blog, Telegram, advertising language, and the sentence claiming that author information is retained.

- [ ] **Step 3: Validate the Pre-cfy README**

Run:

```powershell
rg -n "t\.me|joeyblog|Telegram|联系与支持|强大且易于使用|保留原作者信息" README.md
rg -n "byJoey/cfy|## 免责声明|3 个 IPv4|3 个 IPv6|最多 5 个|不补齐|CFY_HEALTH_PROBE|cfy-source\.generation" README.md
```

Expected: the first command prints nothing; the second command finds every required fact.

- [ ] **Step 4: Check Markdown structure and diff scope**

Run in WSL:

```bash
awk '/^```/{count++} END{exit count % 2}' README.md
sed -n 's/^## /## /p' README.md | sort | uniq -d
git diff --check -- README.md
git status --short --branch
```

Expected: all commands exit 0; duplicate-heading output is empty; only `README.md` is changed in this worktree.

- [ ] **Step 5: Commit only the Pre-cfy README**

```bash
git add -- README.md
git diff --cached --check
git commit -m "docs: rewrite public project guide"
```

Expected: one commit containing only `README.md`.

### Task 3: Cross-project factual and publication review

**Files:**
- Review: `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/sing-box-integration/README.md`
- Review: `C:/Users/Home/Documents/Codex/2026-08-14/new-chat/worktrees/cfy-generation-sidecar/README.md`

- [ ] **Step 1: Verify commands and menu claims against scripts**

Run:

```powershell
rg -n -- "--cfy|--update|--purge-nginx|Cloudflare 节点优选" sing-box.sh
rg -n "CFY_IP_VERSION_SCOPE|CFY_PER_ISP_LIMIT|CFY_HEALTH_PROBE|cfy-source\.generation|cfy-url\.txt" cfy.sh
```

Expected: every documented command, variable, and contract path has a source match.

- [ ] **Step 2: Verify forbidden and required content across both files**

Run from the parent worktree directory:

```powershell
rg -n "t\.me|joeyblog|交流群|联系与支持|强大且易于使用|保留原作者信息" sing-box-integration/README.md cfy-generation-sidecar/README.md
rg -n "eooce/Sing-box|byJoey/cfy|## 免责声明" sing-box-integration/README.md cfy-generation-sidecar/README.md
```

Expected: the first command prints nothing; the second reports attribution and disclaimer matches in both files.

- [ ] **Step 3: Confirm runtime and license files are unchanged**

Run:

```powershell
git -C sing-box-integration diff HEAD^ --name-only
git -C cfy-generation-sidecar diff HEAD^ --name-only
git -C sing-box-integration diff origin/main -- LICENSE
```

Expected: each first command reports only `README.md`; the LICENSE diff is empty.

- [ ] **Step 4: Report state without pushing**

Run:

```powershell
git -C sing-box-integration status --short --branch
git -C cfy-generation-sidecar status --short --branch
git -C sing-box-integration log -1 --oneline
git -C cfy-generation-sidecar log -1 --oneline
```

Expected: both README commits are present locally, Sing-box-Pre still lists only the six pre-existing unrelated dirty files, Pre-cfy is clean, and neither repository is pushed without explicit authorization.
