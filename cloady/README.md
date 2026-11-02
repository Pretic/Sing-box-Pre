# Cloady 容器适配（Sing-box-Pre）

此目录专为 Cloady 托管容器而写，**不会运行原仓库面向 VPS 的 `sing-box.sh`**。为了兼容 HTTP 入口，只提供 VLESS + WebSocket + Cloady 自动 HTTPS，另提供可选的 SSH 公钥登录。不含 Reality / HY2 / TUIC / WARP / `sb` 交互菜单。原有 VPS 脚本及主分支完全不变。

## 部署

1. 打开 Cloady，选择 GitHub 仓库 `Pretic/Sing-box-Pre`，分支 `deploy/cloady-node-20261102`。
2. **Build → Root directory 设置为 `cloady`**，使平台识别该目录中的 `compose.yaml` 和 `Dockerfile`。建议应用名 `pre-node`，地区选择目前可用的新加坡 `sin1` 或日本 `jpn1`。
3. 资源限制已设为 0.5 vCPU、768 MB RAM，且使用一个 `node-data` 持久卷。**部署前必须检查卷大小加已占用资源不超过免费额度（0.5 vCPU、1 GB RAM、5 GB SSD），确认账单预览为 $0；如显示付费，不要确认。**
4. `VLESS_UUID` 留空即可；初次启动生成强随机 UUID 并保存在卷的 `/data/vless_uuid`。也可在 Cloady → Settings → Environment 设置一个自己生成的固定 UUID（Secret）。
5. 部署成功后，在应用的 **Terminal** 执行：

```sh
python3 /opt/cloady/show_node.py
```

6. 将输出的 `vless://` 链接导入客户端。访问 `https://你的应用主机名.cloady.io/` 应返回 `ok`，再实测代理流量。网页健康检查成功不代表代理已实际验证。

## SSH（可选）

- 在 Settings → Environment 设置自己的 `SSH_PUBLIC_KEY`（SSH 公钥，形如 `ssh-ed25519 AAAA...`），**不要上传私钥**。
- 保存后 Redeploy；登录用户 `nodeadmin`，容器端口 2222，禁用密码和 root 登录。SSH 主机密钥保存在持久卷，避免每次容器重启改变指纹。
- Cloady 官方文档说明：HTTP 与 raw TCP 同时发布时，SSH 应使用应用详情展示的 **IPv6 和实际公网 TCP 端口**；用户侧须具备 IPv6 网络，不能直接假定普通 `ssh` 通过 `*.cloady.io:22` 工作。

```sh
ssh -6 -p <平台显示的公网TCP端口> nodeadmin@<平台显示的IPv6>
```

如平台限制公网 TCP 发布，先使用 Cloady 自带终端。这里 SSH 只能登录容器，不能管理宿主机。默认未提供公钥时 SSH 端口仍接受 TCP 连接，但拒绝登录。如不需要 SSH，可删掉 Compose 中的 `2222:2222/tcp` 映射。

## 不需要 Cloudflare Tunnel

Cloady 自带 HTTPS，入口 3000 经 nginx 转发到仅监听回环地址 10000 的 sing-box WebSocket 入口 `/node`，因此无需临时 Argo，也无需 Cloudflare Access。使用临时 Argo 反而增加进程与不稳定性。

## 维护与验证边界

- 镜像固定为上游 `ghcr.io/sagernet/sing-box:v1.14.2`。升级前需要审查兼容性。
- `node-data` 必须是持久卷，切勿随意删除，否则自动生成的 UUID 和 SSH 主机密钥将丢失。
- Cloady 官方文档仅明确免费层 **200 GB/月 HTTP 出站**；普通代理流量的政策、计量与限制未获实际账号验证。请观察资源使用与官方条款。
- 目前此版本通过了代码语法及配置生成静态检查，但**尚未在 Cloady 账户真实创建服务，也未通过公网 WebSocket、代理、SSH 连通性测试**。部署后需要实际验证。
- API Key、UUID、SSH 私钥均不应提交到仓库。

## 官方 CLI（已安装 Node 20+ 时）

```sh
npm install -g cloady
cloady login
cloady deploy github.com/Pretic/Sing-box-Pre --type git --branch deploy/cloady-node-20261102 --subdir cloady --region sin1 --name pre-node
```

CLI 文档：https://cloady.com/docs/cli 。如果平台暂不支持所选地区或已有应用，应据实际部署页面调整，不能假设部署成功。
