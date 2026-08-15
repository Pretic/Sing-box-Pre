# Cloudflare HTTPS 订阅公开版设计

日期：2026-08-15

状态：已批准并实现

适用仓库：`Pretic/Sing-box-Pre`

不适用仓库：`Pretic/Pre-cfy`（本方案不修改 cfy）

## 1. 目标

在不改变一键安装的轻量体验、不影响节点数据面性能、兼容普通 VPS、IPv4/IPv6 单栈与双栈 VPS、NAT VPS 的前提下，为公开版脚本增加可选的 Cloudflare HTTPS 订阅。

默认安装继续直接生成原有 HTTP 原始订阅；只有用户主动进入二级菜单配置后，脚本才启用 HTTPS。公开版中的域名、Tunnel、凭据和密钥全部属于脚本使用者，不使用作者的 `988600.xyz` 或任何集中式服务。

本功能只改变“订阅文件如何发布”，不改变 VLESS Reality、VLESS WS Argo、cfy 优选节点的生成方式，也不把 Nginx 插入代理节点的数据通路。

## 2. 明确隔离边界

当前自用 VPS 上已有的特殊实现是单机修复，不属于公开方案。公开仓库不得包含或依赖以下内容：

- `sing-box-subscription.service`
- `/usr/local/libexec/sing-box-subscription.py`
- 本机的 8081 端口约定
- `/etc/sing-box/subscription-path`
- 当前自用 VPS 的域名、路径、Tunnel token 或 API token
- 为当前 VPS 编写的兼容性补丁或状态识别特例

公开版只复用仓库已经具备的 Nginx、单个 `cloudflared` 进程和 `/etc/sing-box/sub.txt`。当前自用 VPS 不因公开版提交而自动同步、重装或迁移。

## 3. 方案选择

### 3.1 采用：Nginx 原始订阅 + 现有固定 Tunnel 终止 HTTPS

数据流如下：

```text
订阅客户端
  -> HTTPS / 随机密钥
  -> Cloudflare
  -> 已有 cloudflared 固定 Tunnel
  -> http://127.0.0.1:<nginx_port>
  -> Nginx 精确路径
  -> /etc/sing-box/sub.txt
```

选择原因：

- 不新增常驻 Python、Node.js 或订阅转换服务。
- 不新增第二个 `cloudflared`，复用已有固定 Tunnel。
- TLS 在 Cloudflare 终止，VPS 不需要申请、续签和加载证书。
- Tunnel 由 VPS 主动向外连接，不要求 NAT VPS 映射订阅端口。
- cfy 仍只负责更新订阅内容，发布层无需感知节点数量和运营商筛选策略。
- 订阅访问量很低，Nginx 读取一个小文本文件的 CPU、内存和流量成本可以忽略。

### 3.2 不采用：公开版常驻 Python HTTPS 服务

该方案能快速适配单机，但会引入新的服务、端口、日志、权限和升级状态，且容易与脚本已有的 Nginx 管理语义冲突。它只保留在当前自用 VPS，不进入公开脚本。

### 3.3 不采用：脚本自建多格式订阅转换器

公开版不在 VPS 本机动态生成 Clash/Mihomo、Sing-box、Surge 等格式。这会扩大协议兼容、版本更新和安全维护范围。第一条链接继续由 VPS 提供 Base64 原始订阅，其余格式继续沿用原作者的 `sublink.eooce.com` 转换链接。

### 3.4 暂不采用：ACME 证书 + VPS 直出 HTTPS

`acme-yg` 对需要公网直连 HTTPS 的场景有借鉴意义，但不是本功能的默认依赖。直出 HTTPS 需要域名解析、80/443 或 DNS API、证书续签、Web 服务器 TLS 配置和 NAT 端口映射；固定 Tunnel 已经负责公网 HTTPS，重复申请源站证书的收益很低。未来如增加“无 Cloudflare 直出 HTTPS”模式，应作为独立功能设计。

## 4. 用户体验与菜单

### 4.1 首页保持不变

首页只保留当前的 Argo、Nginx、sing-box 状态和原菜单编号，不增加 HTTPS、域名、密钥或 Tunnel 类型等长状态，避免破坏一键脚本的简洁性和终端颜色布局。

### 4.2 `管理节点订阅` 二级菜单

保留现有四个常用入口，并追加 HTTPS 相关入口：

```text
1. 关闭节点订阅
2. 开启节点订阅
3. 更换订阅端口
4. 重启订阅服务
5. 查看订阅链接与详细状态
6. 配置 Cloudflare HTTPS 订阅
7. 关闭 Cloudflare HTTPS 订阅
8. 重新生成订阅密钥
0. 返回主菜单
```

语义约束：

- “关闭节点订阅”停止 Nginx，HTTP 与经 Tunnel 转发到 Nginx 的 HTTPS 都不可用。
- “关闭 Cloudflare HTTPS 订阅”只删除或停用 HTTPS 路由及其首选状态，保留 Nginx 和 HTTP 订阅。
- “重启订阅服务”只重启 Nginx，不重启 sing-box；仅在 Tunnel 路由异常且需要时单独处理 Argo。
- “查看订阅链接与详细状态”显示 HTTP/HTTPS URL、首选 URL、Tunnel 类型、验证结果和转换链接；首页不展示这些详情。

### 4.3 安装与固定 Tunnel 流程

- 默认安装不询问 Cloudflare 域名或 API token，继续输出 HTTP 订阅。
- 添加固定 Tunnel 成功后，可提示“是否同时配置 HTTPS 订阅 `[y/N]`”，默认值为 `N`。
- 临时 `trycloudflare.com` Tunnel 只用于临时节点，不作为稳定 HTTPS 订阅入口。
- 已安装用户执行 `--update` 只更新脚本，不自动创建路由、改变订阅 URL 或轮换密钥。

## 5. 域名模式

### 5.1 推荐：复用现有固定 Argo 主机名

示例：

```text
节点：wss://argo.example.com/vless-argo
订阅：https://argo.example.com/sub/<32字符密钥>
```

优点：不需要新增 DNS 记录，配置步骤最少。Tunnel 规则必须按顺序放置：精确订阅路径规则在 Argo 主机名的节点规则之前，否则主机名规则会先匹配并把订阅请求送到节点端口。

### 5.2 可选：使用独立订阅主机名

示例：

```text
订阅：https://sub.example.com/<32字符密钥>
```

优点：职责清楚、可单独更换或停用；代价是需要新增 Cloudflare Published Application/DNS 记录。它仍复用同一个 Tunnel 和同一个 Nginx，不增加 VPS 常驻进程。

### 5.3 域名归属

- 用户必须输入并使用自己 Cloudflare 账户内的域名。
- 脚本不提供共享域名、共享 Worker、共享 KV 或作者托管的转换服务。
- 输入规范化为小写 FQDN，拒绝协议、路径、端口、空格、通配符及明显非法字符。

## 6. 密钥与 URL

### 6.1 密钥格式

- 固定长度：32 个字符。
- 字符表：`0123456789abcdefghjkmnpqrstvwxyz`。
- 排除 `i`、`l`、`o`、`u`，降低手工输入时的混淆。
- 字符表大小为 32，每个字符 5 bit，总熵为 160 bit。
- 从 `/dev/urandom` 均匀抽取，不使用时间戳、主机名、IP、节点 UUID 或 shell `$RANDOM`。
- 密钥独立于节点 UUID，轮换订阅密钥不重建节点。

HTTP 和 HTTPS 使用同一个随机密钥。为避免与复用主机名上的节点路径冲突，URL 模板允许不同的固定前缀：

```text
HTTP：http://<订阅主机>:<nginx_port>/<密钥>
复用域名 HTTPS：https://<argo域名>/sub/<密钥>
独立域名 HTTPS：https://<订阅域名>/<密钥>
```

Nginx 只注册当前需要的精确路径。轮换后同时更新 HTTP、HTTPS、Nginx 和 Tunnel 路由；旧地址立即失效。执行前必须明确提示用户更新客户端订阅。

### 6.2 旧安装迁移

- 升级脚本本身不改变现有路径。
- 用户首次主动启用 HTTPS 时，如果现有路径不是新的 32 字符格式，脚本说明旧 URL 会失效并要求确认后再轮换。
- 用户取消确认时不修改 Nginx、Tunnel 或已有 HTTP URL。
- 不在后台保留无限期的旧密钥兼容路径，避免多个泄露入口长期有效。

## 7. Tunnel 类型与配置策略

脚本从已安装服务的实际启动参数和配置文件识别 Tunnel 类型，不根据用户输入猜测：

- 临时 Tunnel：启动参数含 `tunnel --url`，无稳定用户域名。
- 本地管理固定 Tunnel：服务使用 `/etc/sing-box/tunnel.yml` 等本地配置和凭据 JSON。
- 远程管理固定 Tunnel：服务使用 `tunnel run --token ...`。

### 7.1 临时 Tunnel

拒绝配置稳定 HTTPS 订阅，并提示先在 Argo 管理菜单添加固定 Tunnel。HTTP 订阅保持不变。

### 7.2 本地管理固定 Tunnel（JSON 凭据）

脚本可以安全修改本地 ingress：

1. 以权限 `600` 备份配置。
2. 读取并保留 tunnel ID、credentials-file、已有节点规则、其他规则及最终 catch-all。
3. 复用域名时，在对应节点主机名规则之前插入“主机名 + 精确路径”订阅规则。
4. 独立域名时，在最终 catch-all 之前插入独立主机名规则。
5. 保证最后一条仍是 catch-all，且重复执行不会产生重复规则。
6. 使用 `cloudflared tunnel ingress validate` 和具体 URL 的 `cloudflared tunnel ingress rule` 校验顺序。
7. 校验通过后才重启 Argo 服务；失败则恢复备份并保持原进程/配置可用。

Tunnel 的 `path` 字段按 Cloudflare 的正则语义生成锚定表达式，例如 `^/sub/<密钥>$` 或 `^/<密钥>$`，不能使用会匹配前缀、后缀或任意相似路径的宽泛规则。

独立域名还需要 DNS CNAME 指向 `<tunnel-id>.cfargotunnel.com`。无 API token 时输出精确的 Dashboard/CNAME 操作说明；用户选择 API 自动化时再创建记录。

### 7.3 远程管理固定 Tunnel（token）

Tunnel token 只能启动 connector，不能可靠代表修改远程 ingress 的权限。因此提供两种方式：

1. Cloudflare API token 自动配置。
2. Cloudflare Dashboard 手动配置后由脚本验证。

自动方式：

- 静默读取 API token，不写入磁盘、不显示、不进入命令历史，并在调用完成后清空变量。
- 请求或让用户确认 Account ID、Tunnel ID；独立主机名还需要 Zone ID。
- API token 最小权限为 Cloudflare Tunnel/Connector Write；自动创建独立 DNS 时额外需要 DNS Write。
- 先 GET 并保存完整远程配置，保留所有未知字段、`originRequest` 和无关 ingress。
- 仅插入或更新本功能拥有的订阅规则，再 PUT 完整配置。
- API 失败、返回结构异常或公网验证失败时，用保存的 JSON 回滚远程配置；如果本次新建或修改了 DNS 记录，也恢复原记录或删除本次新建记录。
- 不尝试从未公开保证格式的 token 字符串中解析账户或 Tunnel 元数据。

手动方式输出用户应填的精确值：

```text
Hostname: <用户选择的域名>
Path:     ^/sub/<密钥>$（复用域名）或 ^/<密钥>$（独立域名）
Type:     HTTP
URL:      http://localhost:<nginx_port>
```

脚本只有在用户完成 Dashboard 配置并通过公网验证后，才把 HTTPS 标记为可用和首选。

## 8. 状态文件与解析

新增 `/etc/sing-box/subscription.conf`，权限为 `600`。只保存公开版订阅状态，不保存 Cloudflare API token：

```text
SUB_TOKEN=<32字符密钥>
SUB_HTTP_PATH=/<密钥>
SUB_HTTPS_ENABLED=0|1
SUB_HTTPS_DOMAIN=<用户域名>
SUB_HTTPS_DOMAIN_MODE=reuse|separate
SUB_HTTPS_PATH=/sub/<密钥>|/<密钥>
SUB_TUNNEL_MODE=local|remote
SUB_HTTPS_VERIFIED_AT=<UTC时间>
```

实现不得直接 `source` 不可信文件。只逐行解析白名单键，并对每个值按其类型验证。未知键忽略，非法值使 HTTPS 状态降级为“未验证”，不能拼进 shell 命令。

如果状态文件不存在，脚本可从现有 `/etc/nginx/conf.d/sing-box.conf` 读取旧 HTTP 端口和路径用于显示/迁移，但不得读取当前自用 VPS 的专用状态文件或服务。

## 9. Nginx 发布层

- 继续服务 `/etc/sing-box/sub.txt`；cfy 更新 `/etc/sing-box/cfy-url.txt`、`all-sub.txt` 后，现有同步逻辑自然更新订阅内容。
- 仅精确匹配当前 HTTP/HTTPS 路径，其他路径返回 404，不开放目录索引。
- 返回 `Cache-Control: private, no-store` 与 `X-Content-Type-Options: nosniff`。
- 关闭密钥路径的 access log，避免 URL 中的密钥落入 Nginx 访问日志。
- Nginx 只需绑定本机可访问的端口；现有直连 HTTP 模式继续按原行为监听 IPv4/IPv6。
- 订阅文件使用“仅 root 可写、Nginx worker 可读”的最小权限，不盲目设为 Nginx 无法读取的 `600`。
- 修改前备份，运行 `nginx -t`，通过后 reload；失败恢复备份，不能中断原订阅。

## 10. 订阅链接生成

实现一个共享的 `source_url` 解析器，供安装完成页、`sb -c`、菜单“查看订阅链接”及所有转换链接共同调用：

1. HTTPS 已启用、配置完整且最近一次公网内容验证成功：返回 HTTPS URL。
2. 否则 Nginx 的 HTTP 端口和路径有效：返回 HTTP URL。
3. 两者都无效：明确显示“订阅未配置”，不生成链接和二维码。

严禁再生成 `http://IP:/`、空 `config=` 或只包含协议头的 URL。

输出兼容策略：

- V2rayN/Shadowrocket/Nekobox/Loon/Karing/Streisand：直接使用 VPS 的 Base64 原始 `source_url`。
- Clash/Mihomo：`https://sublink.eooce.com/clash?config=<source_url>`。
- Sing-box：`https://sublink.eooce.com/singbox?config=<source_url>`。
- Surge：`https://sublink.eooce.com/surge?config=<source_url>`。

脚本不承诺一个原始 Base64 URL 被所有客户端原生识别；不同格式仍通过上述原作者转换端点适配。详细状态页应提示：使用第三方转换链接会把原始订阅 URL（包括随机密钥）发送给转换服务。

## 11. 二维码修复

新增共享 helper，例如 `render_terminal_qr`：

- URL 为空时不调用。
- 只在交互式终端中输出，避免把 ANSI 图形写进日志。
- 调用统一为 `qrencode -t ANSIUTF8 -m 1 -- "$url"`，不再触发 `No output filename is given.`。
- 二维码失败是非致命错误，不影响文本链接和安装结果。
- 替换订阅、Socks5、AnyTLS、Shadowsocks 等位置的直接 `qrencode` 调用，避免同类问题残留。
- 不生成 PNG 临时文件。

## 12. 验证、降级与回滚

HTTPS 只有同时满足以下条件才成为首选：

1. Nginx 配置测试通过且本机精确路径返回订阅。
2. Tunnel ingress 校验通过或远程配置更新成功。
3. 公网 HTTPS URL 返回成功状态。
4. 公网响应去除可接受的末尾换行后，与本地 `/etc/sing-box/sub.txt` 内容一致（使用哈希或严格内容比较）。

失败策略：

- 不停止 sing-box，不改变节点 UUID，不影响 Reality/Argo 节点配置。
- 不把失败的 HTTPS URL写成首选；继续输出原 HTTP URL。
- 本地 Nginx、Tunnel 配置分别恢复各自备份。
- 远程 API 配置使用操作前 GET 的完整 JSON 回滚。
- 重复配置相同域名和路径必须幂等，不增加重复 ingress。
- 从固定 Tunnel 切换为临时 Tunnel 时，将 HTTPS 标记为“暂停/未验证”，HTTP 保持可用；恢复固定 Tunnel 后由用户确认重新应用，不静默暴露路径。

## 13. NAT、IPv4 与 IPv6 兼容

- Cloudflare HTTPS 订阅依赖 connector 的出站连接，不依赖 VPS 公网 IPv4、IPv6 或公网订阅端口映射。
- NAT VPS 即使 `PORT+1` 没有公网映射，固定 Tunnel 仍可访问 `127.0.0.1:<nginx_port>`；此时 HTTP URL可以保留显示，但详细状态应标注“外网可达性未保证”。
- IPv6-only VPS 不需要为了 Tunnel origin 使用 IPv6 literal，优先使用 `127.0.0.1`/`localhost`，避免地址格式和路由差异。
- 双栈与单栈只影响直连 HTTP 主机选择，不改变 HTTPS 域名逻辑。
- 不用一次公网 HTTP 探测失败来判断 Nginx 不可用，因为 NAT 机的本地 origin 可能正常但公网端口未映射。

## 14. 性能与资源影响

- 不新增进程：仍为 sing-box、Nginx、单个 cloudflared。
- 节点数据流不经过 Nginx，优选节点测速与代理吞吐不受本功能影响。
- 每次订阅更新只传输一个小型文本文件；对 1 GB 内存和 NAT 小鸡的 CPU/内存影响接近不可感知。
- VPS 双向流量会增加“订阅文件大小 × 拉取次数”以及少量 Tunnel/TLS 协议开销；不会把节点代理流量重复计算一遍。
- 复用主机名和独立主机名的性能基本相同，主要差异是 DNS/配置维护成本。

## 15. 文档与测试要求

实现提交至少包含：

- `sing-box.sh`：状态解析、菜单、Nginx、Tunnel、本地/API/手动流程、链接解析和 QR helper。
- `README.md`：默认 HTTP、可选 HTTPS、两种域名模式、API 最小权限、NAT 说明、第三方转换隐私提示、关闭/轮换语义。
- `tests/`：无需真实 Cloudflare 账户即可运行的 shell fixture/静态测试。

必须覆盖的测试：

- 32 字符长度、字符表与多次生成格式。
- 首页状态和原菜单编号/颜色输出不因 HTTPS 详情改变。
- 二级菜单新增项与关闭语义。
- HTTPS 优先、HTTP 回退、完全缺失三种 `source_url` 分支。
- 空端口/空路径时不产生畸形 URL。
- QR helper 参数正确，脚本中不残留旧式直接调用。
- 本地 ingress 的规则顺序、最终 catch-all、幂等和无关规则保留。
- 远程 API fixture 的 GET/PUT 保留未知字段，失败时执行回滚。
- 临时 Tunnel 拒绝稳定 HTTPS。
- 复用域名与独立域名的路径、DNS需求和验证流程。
- HTTPS 失败后 HTTP、Nginx、sing-box 和原 Argo 节点不受影响。
- NAT、IPv4-only、IPv6-only、双栈环境不依赖公网 origin 探测。
- 仓库中不存在当前自用 VPS 的服务名、域名、端口和专用文件。
- `bash -n sing-box.sh` 和现有测试继续通过。

真实端到端 Cloudflare 测试属于可选手工验收，不应成为公开仓库测试的必需条件。

## 16. 安全注意事项

- 32 字符密钥是不可猜测入口，不等同于用户身份认证；拿到 URL 的人可以读取订阅。
- 不在进程参数、日志、Git、README 示例或状态输出中显示 Cloudflare API token。
- API token 只在用户明确选择自动配置时临时读取，并建议使用受限 token，而不是 Global API Key。
- 订阅密钥可能出现在客户端同步、剪贴板和第三方转换服务中；泄露后使用菜单轮换。
- 关闭 Nginx access log 只减少服务端泄露面，不保证 Cloudflare、客户端或第三方转换器不记录 URL。

## 17. 实施顺序

1. 先增加纯函数式状态解析、密钥生成、URL 解析和测试。
2. 修复共享 QR helper 与所有调用点。
3. 重构 Nginx 精确路径配置和旧安装迁移，保持默认 HTTP。
4. 增加本地管理 Tunnel 的规则编辑、验证与回滚。
5. 增加远程管理 Tunnel 的手动模式，再增加可选 API 自动模式。
6. 接入二级菜单和详细状态页，首页保持不变。
7. 更新 README，执行静态、fixture、回归测试。
8. 只提交并推送公开仓库；不自动部署到当前自用 VPS。

## 18. 官方依据

- Cloudflare Published Applications 将公网主机名映射到本地 HTTP 服务；一个 Tunnel 可发布多个应用：<https://developers.cloudflare.com/tunnel/routing/>
- 本地 ingress 从上到下匹配，最后必须有 catch-all，并可按 hostname 与 path 匹配：<https://developers.cloudflare.com/tunnel/advanced/local-management/configuration-file/>
- 远程配置 API、所需 Tunnel/Connector Write 与 DNS Write 权限、HTTP localhost origin 示例：<https://developers.cloudflare.com/tunnel/setup/>
- Quick Tunnel 面向测试，固定发布应使用正式 Tunnel：<https://developers.cloudflare.com/tunnel/setup/>

## 19. 验收结论

达到以下结果即视为公开方案完成：

- 新用户仍可不懂 Cloudflare、直接完成安装并使用 HTTP 订阅。
- 有固定 Tunnel 的用户可选用自己的域名获得带 32 字符密钥的 HTTPS 订阅。
- 原始与转换订阅都基于同一个经过验证的 `source_url`，无空 URL 和二维码报错。
- 普通机、NAT、IPv4-only、IPv6-only、双栈环境都不会因启用或不启用该功能失去原有能力。
- HTTPS 配置失败可安全回退，不影响代理节点和已有 HTTP 订阅。
- 公开仓库不包含当前自用 VPS 的任何专用实现或秘密。
