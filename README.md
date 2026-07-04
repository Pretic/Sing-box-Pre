<div align="center">

# sing-box 多协议代理工具

![Debian](https://img.shields.io/badge/Debian-A81D33?logo=debian&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white)
![Fedora](https://img.shields.io/badge/Fedora-294172?logo=fedora&logoColor=white)
![Alpine](https://img.shields.io/badge/Alpine-0D597F?logo=alpinelinux&logoColor=white)
![Red Hat](https://img.shields.io/badge/Red%20Hat-EE0000?logo=redhat&logoColor=white)

基于原项目二次修改的 VPS 一键脚本，当前 README 只保留 `sing-box.sh` 主脚本说明。

原作者交流反馈群组：https://t.me/eooceu

</div>

## 项目说明

本仓库基于原作者 [eooce/Sing-box](https://github.com/eooce/Sing-box) 二次修改，保留原作者信息、原项目说明和免责声明。感谢 eooce 及原项目贡献者提供的脚本基础。

本仓库主要用于个人 VPS 节点部署与 Cloudflare Tunnel / 优选入口链路测试，不代表上游项目。二改重点集中在 VPS 一键脚本 `sing-box.sh`：

- 默认订阅输出 `VLESS-Reality` 与 `VLESS-WS-TLS-Argo`，不再默认依赖旧 `VMess-WS-TLS-Argo`。
- 适配 Xray-core 新版本移除旧 TLS `allowInsecure` 后，部分客户端导入或连接 VMess 节点报错的问题。
- Argo 本地入口改为 VLESS + WebSocket，并限制监听 `127.0.0.1:${ARGO_PORT}`，由 `cloudflared` 本机转发。
- 默认订阅不输出 HY2/TUIC 等 UDP 系节点；如需输出，可设置 `INCLUDE_UDP_LINKS=1`。

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
| `CFIP` | `cdns.doon.eu.org` | VLESS-WS-TLS-Argo 的 Cloudflare 入口地址。 |
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

## 订阅与 cfy 联动

- 对外订阅地址默认使用 IPv4 公网地址生成，避免 VPS 没有 IPv6 时订阅 URL 不可访问；默认等同 `SUB_ADDR_FAMILY=ipv4`。
- 如需指定订阅地址主机名或 IP，可在安装前设置 `SUB_HOST=你的域名或IP`；如需优先 IPv6，可设置 `SUB_ADDR_FAMILY=ipv6`；如需自动探测可设置 `SUB_ADDR_FAMILY=auto`。
- `/etc/sing-box/url.txt` 保留基础节点明文，`/etc/sing-box/base-sub.txt` 保留基础节点 Base64 订阅。
- 基础节点默认包含 `vless-reality-ipv4`；如果 VPS 检测到 IPv6，会额外输出 `vless-reality-ipv6`；Argo 模板节点保留为 `vless-ws-tls-argo`。
- `/etc/sing-box/cfy-url.txt` 保存 cfy 最近一次优选结果；`/etc/sing-box/all-url.txt` 合并基础节点和 cfy 优选节点。
- Nginx 对外仍服务 `/etc/sing-box/sub.txt`，该文件由 `/etc/sing-box/all-sub.txt` 同步而来；未运行 cfy 时等同基础订阅，运行 cfy 后会包含优选节点。

查看当前节点与订阅信息：

```bash
sb -c
```

## 快捷命令

安装完成后可直接使用 `sb`：

```text
用法: sb [参数]

  -i, --install     无交互安装 sing-box
      --update      仅更新 sb 快捷命令，不修改已有节点
  -c, --check       查看节点信息和订阅链接
  -r, --restart     重新获取 Argo 临时隧道并更新到订阅
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

## 原作者信息

- 原项目：[eooce/Sing-box](https://github.com/eooce/Sing-box)
- Telegram 交流反馈群组：https://t.me/eooceu

## ⚠️ 免责声明

- 本程序仅供学习了解，非盈利目的，请于下载后 24 小时内删除，不得用作任何商业用途；文字、数据及图片均有所属版权，如转载须注明来源。
- 使用本程序必须遵守部署服务器所在地、所在国家和用户所在国家的法律法规，程序作者不对使用者任何不当行为负责。
