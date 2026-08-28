<div align="center">

# Sing-box-Pre 多协议代理脚本

![Debian](https://img.shields.io/badge/Debian-A81D33?logo=debian&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white)
![Fedora](https://img.shields.io/badge/Fedora-294172?logo=fedora&logoColor=white)
![Alpine](https://img.shields.io/badge/Alpine-0D597F?logo=alpinelinux&logoColor=white)
![Red Hat](https://img.shields.io/badge/Red%20Hat-EE0000?logo=redhat&logoColor=white)

面向普通 VPS、端口受限 NAT VPS 以及 IPv4/IPv6 单栈、双栈环境的深度维护版一键脚本。

</div>

## 项目说明

本仓库从 [eooce/Sing-box](https://github.com/eooce/Sing-box) 演进而来，现由本仓库独立维护，不代表上游项目。当前实现以 `sing-box.sh` 为主，重点是让安装、订阅、Cloudflare Tunnel、WARP 分流和 cfy 优选在不同 VPS 网络条件下保持可用、可回滚、便于更新。

当前主要能力：

- 默认订阅输出 `VLESS-Reality` 与 `VLESS-WS-TLS-Argo`，不再默认依赖旧 `VMess-WS-TLS-Argo`。
- 适配 Xray-core 新版本移除旧 TLS `allowInsecure` 后，部分客户端导入或连接 VMess 节点报错的问题。
- Argo 本地入口改为 VLESS + WebSocket，并限制监听 `127.0.0.1:${ARGO_PORT}`，由 `cloudflared` 本机转发。
- 默认订阅不输出 HY2/TUIC 等 UDP 系节点；如需输出，可设置 `INCLUDE_UDP_LINKS=1`。
- 内置 WARP 采用每台 VPS 独立注册的 sing-box WireGuard endpoint，只接管用户选择的服务，不修改系统默认路由。
- 支持 HTTP 原始订阅和用户主动配置的 Cloudflare Tunnel HTTPS 订阅；订阅发布失败不会影响代理服务。
- 主菜单可安全安装和调用独立项目 cfy，cfy 失败不会覆盖最近一次成功结果或基础节点。
- 关键配置变更采用临时文件、校验、原子替换和事务回滚，避免出现半更新状态。

## 快速开始

### 交互式安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh)
```

### 无交互安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) -i
```

### NAT 机安装

```bash
PORT=你的端口 bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) -i
```

### NAT 机安装并手动输入节点名

```bash
PORT=你的端口 PROMPT_NODE_NAME=1 bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) -i
```

### NAT 机端口说明

脚本安装时会把 `PORT` 当作起始端口使用：

- `PORT`：VLESS-Reality TCP 入口。
- `PORT+1`：Nginx 订阅 TCP 端口。
- `PORT+2`：TUIC UDP 端口。
- `PORT+3`：Hysteria2 UDP 端口。

端口受限 NAT 机如果只有一个公网映射端口，建议优先使用 `VLESS-WS-TLS-Argo` 和 cfy 生成的优选节点。这条链路走 Cloudflare Tunnel，VPS 侧只监听 `127.0.0.1:${ARGO_PORT}`，不要求服务商额外开放 `ARGO_PORT`。Reality、TUIC、Hysteria2 和 Nginx 订阅只有在对应公网映射端口开放时才可靠。

## 已安装后如何更新

以前已经安装过本脚本时，只想同步最新 `sb` 菜单和脚本逻辑，执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) --update
```

更新命令只刷新 `/usr/bin/sb` 指向本仓库脚本，不会重装 sing-box，不修改已有节点、订阅、端口、sing-box 服务或 Argo 配置。更新后继续使用 `sb` 打开菜单，或使用 `sb -c` 查看当前节点和订阅信息。

## 常用变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | 随机 | Reality 入口端口；安装时还会派生 `PORT+1`、`PORT+2`、`PORT+3`。NAT 机新装时建议显式指定。 |
| `ARGO_PORT` | `8001` | 本机 Argo WebSocket 入口端口，仅监听本机回环地址。 |
| `CFIP` | `cdns.doon.eu.org` | VLESS-WS-TLS-Argo 的优选 Cloudflare 入口地址。固定隧道会同时输出 `ARGO_DOMAIN` 稳定入口和该优选入口；临时隧道只输出该入口。 |
| `CFPORT` | `443` | VLESS-WS-TLS-Argo 的入口端口。 |
| `INCLUDE_UDP_LINKS` | `0` | 是否在默认订阅中输出 HY2/TUIC；设为 `1` 时输出。 |
| `NODE_NAME` | 空 | 高级用法：固定完整节点名前缀，例如 `NODE_NAME=US-PreNet`。未设置时使用“国家码-VPS主机名”，交互输入时使用“国家码-输入名”。 |
| `PROMPT_NODE_NAME` | `0` | 无交互安装时是否提示输入 VPS 名称；设为 `1` 时提示。 |
| `SUB_HOST` | 空 | 指定订阅地址使用的主机名或 IP。 |
| `SUB_ADDR_FAMILY` | `ipv4` | 订阅地址主机选择：`ipv4`、`ipv6` 或 `auto`。 |
| `ARGO_DOMAIN` | 空 | 高级 Argo 参数；留空时按脚本默认流程处理。 |
| `ARGO_AUTH` | 空 | 高级 Argo 参数；支持 token 或 JSON。 |

完整节点名示例：

```bash
NODE_NAME=US-PreNet bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) -i
```

## WARP 分流

进入 `sb → WARP分流管理 → 设置分流服务`，可以把 OpenAI、Claude、Gemini、Google、TikTok、Twitter、YouTube、Netflix、Telegram或常见流媒体聚合规则交给指定出站：

- 没有添加 Socks5/HTTP 出站时，脚本自动使用 sing-box 内置的 `wireguard-out`。
- 已添加其他代理时，菜单仍会把“内置 WARP”列为第一个选项，也可以选择已有代理。
- 未匹配服务继续使用服务器原 IP，脚本不会安装系统级 WARP、创建系统 WireGuard 网卡或修改宿主机默认路由。
- 所选服务的 IPv4/IPv6 均使用选定出站；选择 `wireguard-out` 时，其 A/AAAA 流量都走内置 WARP，未选服务继续使用服务器原 IP。
- 首次启用内置 WARP 时，脚本在本机生成密钥并直接向 Cloudflare 注册免费设备（即接受 Cloudflare WARP 服务条款）；私钥与账户信息只以 `600` 权限保存在 `/etc/sing-box/conf/warp/`，不会使用所有 VPS 共用的公开身份。旧共享身份会在下次设置分流时自动迁移。
- 内置 WARP peer 每 25 秒发送持久保活，避免空闲后 UDP/NAT 映射失效；NAT 机不需要增加入站映射，但服务商必须允许 VPS 向 Cloudflare WARP endpoint 发起出站 UDP 连接。

菜单会显示 `wireguard-out` 是否就绪。首次设置规则时会自动补齐缺失的 endpoint、规则集和 `direct` 出站；修改前后执行完整配置校验，校验或重启失败会恢复原路由。全局代理与恢复直连会清空选择性分流规则并显式调整 `route.final`，不再删除 `route.json`、`endpoints.json` 或 `direct` 出站。

`WARP分流管理` 还提供三个内置身份操作：

- `查看内置 WARP 状态及解锁情况`：脱敏显示设备 ID、出口 IP、地区、Cloudflare 机房及 Netflix、Disney+、ChatGPT、Gemini 检测结果，不显示令牌、私钥、client ID 或 reserved bytes。
- `更换内置 WARP 身份/IP`：先注册并隔离探测候选身份。IPv4 出口确实变化时继续使用 IPv4；如果 Cloudflare 将当前 POP 的 IPv4 固定为共享出口，则提交新身份并让已选择的 WARP 分流规则优先使用 IPv6。验证或服务重启失败会恢复旧身份。
- `自动优选 WARP IP（多平台解锁）`：用户可多选上述四个平台，默认全选；候选必须满足 WARP 在线且所选项目全部通过。IPv4 被 POP 固定时同样可以使用 IPv6 优先路径，不会因重复注册相同 IPv4 而无限循环。

Cloudflare WARP 的 IPv4 常由 POP 共享 NAT，重新注册身份并不保证立即得到不同 IPv4。公网 IPv6 也可能随连接变化，因此脚本对 IPv4 使用严格地址对比，对 IPv6 验证 WARP 状态和地址族，不把某一次临时 IPv6 当作永久设备标识。每批候选、总批次和总耗时均有上限；未提交候选会清理云端注册和本地临时文件。

首页的 `WARP 状态` 指 sing-box 内置端点而非系统网卡：`running` 表示最近探测正常，`not configured` 表示尚未初始化，`degraded` 表示端点存在但最近探测失败。状态结果短暂缓存，避免每次重绘菜单都重复测速。上述操作只启动临时的 localhost 探测代理，不安装系统 WARP、Cloudflare Client、WireProxy、定时任务或守护进程；公网 IP 和地区由 Cloudflare Anycast 调度，脚本无法保证得到指定国家或指定 IP。

## 订阅与 cfy 联动

- cfy 仍是独立项目、独立命令和独立更新周期，Sing-box 不复制或改写其节点生成逻辑。可从主菜单 `11. Cloudflare优选` 或 `sb --cfy` 进入；子菜单可运行 cfy、查看最近结果、调用 `cfy --update`，退出后返回 sb。
- 首次运行且 `/usr/local/bin/cfy` 不存在时，sb 才会自动安装。安装内容固定到已验证的 cfy 提交与 SHA-256，使用带超时的 `curl -fsSL` 下载到目标同目录临时文件，依次通过非空、Bash 语法、功能标识及摘要校验后无覆盖发布；不会执行空脚本或直接使用 `curl | bash`。
- cfy 下载、安装或运行失败不会重启 sing-box、Argo、Nginx，不会更改端口、基础节点或已有服务配置；cfy 自身仍通过原有事务发布规则保留最近一次成功结果。成功运行后才更新 cfy 优选结果及综合订阅。
- 对外订阅地址默认使用 IPv4 公网地址生成，避免 VPS 没有 IPv6 时订阅 URL 不可访问；默认等同 `SUB_ADDR_FAMILY=ipv4`。
- 如需指定订阅地址主机名或 IP，可在安装前设置 `SUB_HOST=你的域名或IP`；如需优先 IPv6，可设置 `SUB_ADDR_FAMILY=ipv6`；如需自动探测可设置 `SUB_ADDR_FAMILY=auto`。
- `/etc/sing-box/url.txt` 保留基础节点明文，`/etc/sing-box/base-sub.txt` 保留基础节点 Base64 订阅。
- 基础节点默认包含 `vless-reality-ipv4`；如果 VPS 检测到 IPv6，会额外输出 `vless-reality-ipv6`。固定隧道同时输出以 `ARGO_DOMAIN` 连接的稳定 Argo 节点，以及以 `CFIP` 连接、后缀为 `argo-preferred` 的优选 Argo 节点；两者地址相同时自动去重。临时隧道仍只输出一个 Argo 节点。
- `/etc/sing-box/cfy-url.txt` 保存 cfy 最近一次优选结果；`/etc/sing-box/all-url.txt` 合并基础节点和 cfy 优选节点。
- cfy 会用 `/etc/sing-box/cfy-source.generation` 将优选结果绑定到生成时的基础订阅；基础节点、UUID、Argo 域名或入口发生变化后，旧优选结果会自动退出公开订阅，重新运行 cfy 后再安全并入。Sing-box 只读取、不会改写这两个 cfy-owned 文件。
- Nginx 对外仍服务 `/etc/sing-box/sub.txt`，该文件由 `/etc/sing-box/all-sub.txt` 同步而来；未运行 cfy 时等同基础订阅，运行 cfy 后会包含优选节点。

查看当前节点与订阅信息：

```bash
sb -c
```

## 可选的 Cloudflare HTTPS 订阅

脚本默认仍生成 HTTP 原始订阅，不会在一键安装时强制询问域名、Cloudflare API token，也不会自动改变旧安装的订阅地址。HTTPS 是用户主动启用的可选发布方式，只改变订阅文件的访问入口，不改变节点协议、cfy 优选结果或代理数据通路。

### 适用条件与资源开销

- HTTPS 订阅复用脚本已有的 Nginx、`/etc/sing-box/sub.txt`、`cloudflared` 固定 Tunnel，不安装额外常驻转换服务，也不依赖 ACME 证书。
- 必须使用用户自己的 Cloudflare 域名和固定 Tunnel；临时 `trycloudflare.com` Tunnel 的域名会变化，不适合作为稳定订阅入口。
- Tunnel 到 Nginx 的源站地址使用 `http://localhost:<订阅端口>`。因此 NAT 机不需要新增公网端口映射，IPv4 单栈、IPv6 单栈和双栈 VPS 都可以使用。
- 订阅访问只是按需传输一个小文本文件，不把 Nginx 或订阅转换放进节点转发链路，对节点网速和 VPS 负载的影响通常可以忽略。

### 域名模式

推荐复用现有固定 Argo 主机名：

```text
节点入口：https://argo.example.com/<节点路径>
订阅入口：https://argo.example.com/sub/<32字符密钥>
```

这样不需要新增 DNS 记录，脚本会让精确订阅路径规则排在同主机名的节点规则之前。也可使用独立订阅主机名，例如 `https://sub.example.com/<32字符密钥>`；职责更清楚，但需要新增 Published Application，并可能需要创建 DNS 记录。两种模式都复用同一个 Tunnel 和 Nginx。

### 配置方式

添加固定 Tunnel 成功后，脚本会询问是否同时配置 HTTPS 订阅，默认回答为 `N`。也可稍后进入：

```text
sb → 管理节点订阅 → 配置 Cloudflare HTTPS 订阅
```

- 本地 JSON 凭据管理的固定 Tunnel：脚本备份本地配置、插入精确路径规则、执行 `cloudflared tunnel ingress validate`，验证失败时自动回滚。
- token 方式运行的远程管理 Tunnel：可选择 Cloudflare API 自动配置，或按脚本给出的 Hostname、Path、Type 和 URL 在 Dashboard 手动添加后再验证。
- API token 最小权限为 `Cloudflare Tunnel/Connector Write`；只有独立域名需要脚本自动创建或修改 DNS 时，才额外需要 `DNS Write`。
- API token 由终端静默读取，只用于本次请求，不写入磁盘、不写入脚本状态文件，也不作为 `curl` 命令行参数显示。Tunnel 启动 token 与 Cloudflare API token 不是同一种凭据。

HTTPS 只有在脚本从公网取得的内容与本机 `/etc/sing-box/sub.txt` 一致后才会成为首选订阅地址。API、DNS、Tunnel、Nginx 或内容验证失败时，脚本回滚本次改动，已有节点不受影响；只要 Nginx 原配置有效，订阅输出会继续回退到 HTTP。

### 密钥、兼容性与菜单语义

- 新密钥固定为 32 个易辨认字符，使用系统随机源生成，与节点 UUID 相互独立；Nginx 只开放对应的精确路径，关闭该路径的访问日志，并返回 `no-store`。
- V2rayN、Shadowrocket、Nekobox、Loon、Karing、Streisand 直接使用 VPS 发布的 Base64 原始订阅。Clash/Mihomo、Sing-box、Surge 链接仍由 `sublink.eooce.com` 转换；使用第三方转换地址意味着原始订阅 URL 会发送给该服务，请自行评估隐私和可用性。
- `关闭节点订阅` 会停止 Nginx，因此 HTTP 和经 Tunnel 回源的 HTTPS 都会停止。
- `关闭 Cloudflare HTTPS 订阅` 只移除 HTTPS 路由和首选状态，保留 HTTP 订阅与节点。
- `重新生成订阅密钥` 会同步更新 Nginx 与 Tunnel 路由，旧 HTTP/HTTPS 地址随即失效，需要在客户端更新订阅。
- 首页继续只显示简洁的 Argo、WARP、Nginx、sing-box 状态；完整 URL、Tunnel 类型和验证时间在“查看订阅链接与详细状态”二级菜单中显示。

## 快捷命令

安装完成后可直接使用 `sb`：

```text
用法: sb [参数]

  -i, --install     无交互安装 sing-box
      --update      仅更新 sb 快捷命令，不修改已有节点
  -c, --check       查看节点信息和订阅链接
  -r, --restart     重新获取 Argo 临时隧道并更新到订阅
      --cfy         进入 Cloudflare优选 菜单
  -u, --uninstall   无交互卸载 sing-box（保留 nginx）
      --purge-nginx  卸载 sing-box 并同时卸载 nginx
  -h, --help        显示帮助信息
```

`sb -c` 会显示 `/etc/sing-box/url.txt` 中的基础节点；如果已经运行过 cfy 并生成过优选节点，也会显示 `/etc/sing-box/cfy-url.txt` 中最近一次优选结果。

## 使用提示

- 本仓库命令统一使用 `curl -fsSL`，下载失败时会显示错误，避免 Bash 静默执行空脚本。
- 新装或重装使用上方安装命令；已安装环境只想刷新 `sb` 快捷命令时再使用 `--update`。
- NAT 机只有新装或重装生成节点时需要带 `PORT=你的端口`，并确认 `PORT+1`、`PORT+2`、`PORT+3` 是否也在服务商开放范围内；如果只有单个端口，优先使用 Argo/cfy 节点。
- 默认节点名前缀使用 `国家代码-VPS名称`，未手动输入时取 VPS 主机名；交互生成节点时可手动输入 VPS 名称替换主机名部分。

## 上游与鸣谢

- 上游项目：[eooce/Sing-box](https://github.com/eooce/Sing-box)
- 感谢 eooce 及上游贡献者提供早期脚本基础。

## ⚠️ 免责声明

- 本程序仅供学习了解，非盈利目的，请于下载后 24 小时内删除，不得用作任何商业用途；文字、数据及图片均有所属版权，如转载须注明来源。
- 使用本程序必须遵守部署服务器所在地、所在国家和用户所在国家的法律法规，程序作者不对使用者任何不当行为负责。
