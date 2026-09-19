# Sing-box-Pre

基于 sing-box 的 VPS 节点安装与管理脚本，支持 Argo 隧道、WARP 分流和订阅管理。

## 功能

- 支持 VLESS-Reality、VLESS-WS-TLS、Hysteria2、TUIC，可通过菜单管理附加协议。
- 支持 Argo 临时隧道与固定隧道、WARP 分流及出口检测。
- 支持 HTTP / HTTPS 订阅、节点配置修改，并可直接调用 [Pre-cfy](https://github.com/Pretic/Pre-cfy) 生成 Cloudflare 优选节点。

默认输出 Reality 和 Argo 节点；HY2 / TUIC 按需开启。

## 一键安装

使用 root 用户执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh)
```

安装后输入 `sb` 打开菜单。

### NAT VPS

指定服务商分配的端口：

```bash
PORT=你的端口 bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh)
```

Reality 使用 `PORT`，HTTP 订阅使用 `PORT+1`，TUIC / HY2 使用 `PORT+2` / `PORT+3`。公网映射以服务商提供的范围为准；Argo 不需要额外开放入站端口。

## 常用命令

| 命令 | 功能 |
| --- | --- |
| `sb` | 主菜单 |
| `sb -i` | 无交互安装 |
| `sb -c` | 查看节点与订阅 |
| `sb -r` | 重新获取临时 Argo 隧道 |
| `sb --warp-health` | 检查 WARP IPv4 / IPv6 |
| `sb --cfy` | Cloudflare 优选菜单 |
| `sb --update` | 更新管理脚本 |
| `sb -h` | 查看帮助 |

WARP 在主菜单 `8` 中设置，默认只影响命中规则的节点流量，不改变 VPS 系统默认路由。Argo 隧道在主菜单 `4` 中管理，固定隧道需要自己的 Cloudflare 域名和凭据。

## 订阅

默认提供 HTTP 订阅。进入 `sb → 7`，选择“查看订阅链接与详细状态”获取地址；使用固定隧道时，可选择“配置 Cloudflare HTTPS 订阅”。

“关闭节点订阅”关闭全部订阅；“关闭 Cloudflare HTTPS 订阅”仅关闭 HTTPS；“重新生成订阅密钥”会使旧地址失效。节点发生变化后，在客户端刷新订阅。

## 更新与卸载

```bash
# 更新管理脚本，不重装节点
sb --update

# 更新配套 cfy
cfy --update

# 卸载 sing-box，保留 nginx
sb -u
```

**`--update` 是更新，`-u` 是卸载。**

## 项目来源

基于 [eooce/Sing-box](https://github.com/eooce/Sing-box) 二次开发，由 Pretic 维护。感谢原作者及贡献者。

配套项目：[Pre-cfy](https://github.com/Pretic/Pre-cfy)。请遵守服务器所在地和使用所在地的法律法规。
