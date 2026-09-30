# Sing-box-Pre

VPS 节点安装与管理脚本，支持 Reality、Argo 隧道、Hysteria2、TUIC、WARP 分流和订阅管理，并可调用 [Pre-cfy](https://github.com/Pretic/Pre-cfy) 优选 Cloudflare 节点。

## 安装

使用 root 用户执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh)
```

安装后输入 `sb` 打开菜单。NAT VPS 可指定服务商分配的端口：

```bash
PORT=你的端口 bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh)
```

Reality 使用 `PORT`，HTTP 订阅使用 `PORT+1`，TUIC / HY2 使用 `PORT+2` / `PORT+3`。按实际启用的功能准备端口映射；Argo 无需额外开放入站端口。

## 更新

```bash
sb --update
```

更新管理脚本和配套 WARP 组件，保留节点配置。组件按架构下载，并校验固定版本的 SHA-256；小机无需安装 Go 或现场编译。注意：`--update` 是更新，`-u` 是卸载。

## 常用入口

| 命令 | 用途 |
| --- | --- |
| `sb` | 主菜单 |
| `sb -i` | 无交互安装 |
| `sb -c` | 查看节点和订阅 |
| `sb -r` | 刷新临时 Argo 隧道 |
| `sb --cfy` | Cloudflare 节点优选 |
| `sb --warp-health` | 检查 WARP IPv4 / IPv6 |
| `sb -h` | 帮助 |

WARP 在主菜单 `8` 中管理：

- `8 → 6`：持续尝试更换 IPv4，确认出口改变才算成功，Ctrl-C 取消
- `8 → 8`：当前身份切换为 IPv4，不申请新身份、不更换 IP

## 订阅

默认提供 HTTP 订阅。进入 `sb → 7`，选择“查看订阅链接与详细状态”；有自己的 Cloudflare 域名时，可“配置 Cloudflare HTTPS 订阅”。

“关闭节点订阅”关闭全部订阅；“关闭 Cloudflare HTTPS 订阅”仅关闭 HTTPS；“重新生成订阅密钥”使旧地址失效。

## 使用注意

- 128 / 256 MB 主机自动采用串行检测，避免两个核心同时运行；检测及部分配置修改会中断代理，单个候选可能持续数十秒或更久，等待重试时恢复服务
- Cloudflare 决定出口地址，脚本不能保证一定获得新 IP；限流会等待，明确拒绝或恢复失败会停止
- WARP 默认仅作用于命中分流规则的节点流量，不修改 VPS 系统默认路由
- 小机能否承载完整功能仍取决于系统、nginx、cloudflared 和实际负载；不保证所有 128 MB 环境都可用

更多设置与故障处理见 [WARP 使用说明](docs/WARP.md)。

## 致谢

基于 [eooce/Sing-box](https://github.com/eooce/Sing-box)；WARP 注册传输参考 [ViRb3/wgcf](https://github.com/ViRb3/wgcf)。相关许可见 [组件说明](warp-adapter/README.md)。
