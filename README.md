<div align="center">

# sing-box多协议代理工具

![Debian](https://img.shields.io/badge/Debian-A81D33?logo=debian&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white)
![Fedora](https://img.shields.io/badge/Fedora-294172?logo=fedora&logoColor=white)
![Alpine](https://img.shields.io/badge/Alpine-0D597F?logo=alpinelinux&logoColor=white)
![Red Hat](https://img.shields.io/badge/Red%20Hat-EE0000?logo=redhat&logoColor=white)
[![npm](https://img.shields.io/badge/npm-CB3837?logo=npm&logoColor=white)](https://www.npmjs.com/package/node-sbx)
[![PyPI](https://img.shields.io/badge/PyPI-3775A9?logo=pypi&logoColor=white)](https://pypi.org/project/singbox)
[![Docker](https://img.shields.io/badge/Docker-2496ED?&logo=docker&logoColor=white)](https://hub.docker.com/r/eooce/sbx)

sing-box是一个强大的代理脚本，多种环境下使用。它支持多种代理协议（VLESS-reality-version、VLESS-WS-TLS(Argo)、Hysteria2、Tuic），并集成了哪吒(v0/v1)探针功能。

---

Telegram交流反馈群组：https://t.me/eooceu

</div>

## 本仓库说明（PreNet 自用二改）

本仓库基于原作者 [eooce/Sing-box](https://github.com/eooce/Sing-box) 二次修改，保留原作者信息、原项目说明和免责声明。感谢 eooce 及原项目贡献者提供的脚本基础。

本仓库主要用于个人 VPS 节点部署与 Cloudflare Tunnel/优选入口链路测试，不代表上游项目。二改重点集中在 VPS 一键脚本 `sing-box.sh`：

* 默认订阅改为输出 `VLESS-Reality` 与 `VLESS-WS-TLS-Argo`，不再默认依赖旧 `VMess-WS-TLS-Argo`。
* 适配 Xray-core 新版本移除旧 TLS `allowInsecure` 后，部分客户端导入/连接 VMess 节点报错的问题。
* Argo 本地入口改为 VLESS + WebSocket，并限制监听 `127.0.0.1:${ARGO_PORT}`，由 `cloudflared` 本机转发。
* 默认订阅不输出 HY2/TUIC 等 UDP 系节点；如需输出，可设置 `INCLUDE_UDP_LINKS=1`。


## PreNet 订阅与 cfy 同步说明

* 对外订阅地址默认使用 IPv4 公网地址生成，避免 VPS 没有 IPv6 时订阅 URL 不可访问；默认等同 `SUB_ADDR_FAMILY=ipv4`。
* 如需指定订阅地址主机名或 IP，可在安装前设置 `SUB_HOST=你的域名或IP`；如需优先 IPv6，可设置 `SUB_ADDR_FAMILY=ipv6`，如需自动探测可设置 `SUB_ADDR_FAMILY=auto`。
* `/etc/sing-box/url.txt` 保留基础节点明文，`/etc/sing-box/base-sub.txt` 保留基础节点 Base64 订阅。
* `/etc/sing-box/cfy-url.txt` 保存 cfy 最近一次优选结果；`/etc/sing-box/all-url.txt` 合并基础节点和 cfy 优选节点。
* Nginx 对外仍服务 `/etc/sing-box/sub.txt`，该文件会由 `/etc/sing-box/all-sub.txt` 同步而来；未运行 cfy 时等同基础订阅，运行 cfy 后会包含优选节点。
# 1：VPS 一键命令

## 命令速查

### Sing-box 新装（交互式）
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh)
```

### Sing-box 新装（无交互）
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) -i
```

### NAT 机新装（无交互）
```bash
PORT=你的端口 bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) -i
```

### NAT 机新装（自动安装并询问 VPS 名称）
```bash
PORT=你的端口 PROMPT_NODE_NAME=1 bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) -i
```

### 已安装环境更新（普通 VPS 和 NAT 机通用）
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) --update
```

## 命令说明

* NAT 机只有新装/重装生成节点时需要带 `PORT=你的端口`，并确保后续 3 个端口也在服务商开放范围内。
* NAT 机如果想在 `-i` 自动安装流程中手动输入 VPS 名称，可加 `PROMPT_NODE_NAME=1`；如果想完全无交互固定名称，可加 `NODE_NAME=完整名称`。
* README 保留更新命令，是给已经安装过、只想刷新本机 `sb` 快捷命令的环境使用；新装/重装仍使用上面的新装命令。
* 更新命令只刷新 `/usr/bin/sb` 指向本仓库脚本，不修改已有节点、订阅、端口、sing-box 服务或 Argo 配置，普通 VPS 和 NAT 机通用，不需要单独的 NAT 更新命令。
* 本仓库命令统一使用 `curl -fsSL`，下载失败时会显示错误，避免 `curl -Ls` 失败后 Bash 静默执行空脚本。
* 可选环境变量：`PORT`、`ARGO_PORT`、`CFIP`、`CFPORT`、`INCLUDE_UDP_LINKS`、`NODE_NAME`、`PROMPT_NODE_NAME`。
* 默认订阅只输出 TCP 系节点（VLESS-Reality、VLESS-WS-TLS-Argo）；如需同时输出 HY2/TUIC，可在运行脚本前添加 `INCLUDE_UDP_LINKS=1`。
* 默认节点名前缀保持原来的 `国家代码-ISP`，例如 `US-HostPapa`；交互生成节点时可手动输入 VPS 名，将中间 ISP 部分替换为自定义 VPS 名，例如 `US-MyVPS`。
* 无交互安装如需固定完整节点名，可设置 `NODE_NAME=完整名称`，例如：
```bash
NODE_NAME=US-PreNet bash <(curl -fsSL https://raw.githubusercontent.com/Pretic/Sing-box-Pre/main/sing-box.sh) -i
```


## 快捷指令和命令行参数
快捷指令：sb
```
用法: [sb或脚本] [参数], 示例: sb -c(查看节点信息)

  -i  --install     无交互安装sing-box
      --update      仅更新 sb 快捷命令，不修改已有节点
  -c  --check       查看节点信息和订阅链接
  -r  --restart     重新获取argo临时隧道并更新到订阅
  -u  --uninstall   无交互卸载sing-box（含 nginx)
  -h  --help        显示此帮助信息
```

`sb -c` 会显示 `/etc/sing-box/url.txt` 中的基础节点；如果已经运行过 cfy 并生成过优选节点，也会显示 `/etc/sing-box/cfy-url.txt` 中最近一次优选结果。

# 2：Serv00|CT8一键安装脚本,集成哪吒探针,全自动安装
* 官方更新的[ToS](https://forum.serv00.com/d/2787-april-cleaning-and-new-tos),自行斟酌是否安装
* 一键四协议安装脚本，vmess-ws|vmess-ws-tls(argo)|hy2|tuic5默认解锁GPT和奈飞
* 支持自定义哪吒参数、Argo等参数随脚本一起运行
* 列如：UUID=123456 ARGO_DOMAIN=2go.admin.com ARGO_AUTH=abc123 UPLOAD_URL=https://merge.serv00.net
* v0哪吒变量形式:NEZHA_SERVER=nezha.abc.com  v1哪吒变量形式:NEZHA_SERVER=nezha.abc.com:8008,v1不需要NEZHA_PORT变量
* 需要订阅自动上传到汇聚订阅器，需先部署Merge-sub项目，部署时填写UPLOAD_URL环境变量为部署的首页地址,例如：UPLOAD_URL=https://merge.serv00.net
* 客户端跳过证书验证需设置为true，否则hy2和tuic不通

## Serv00|CT8一键四协议安装脚本vmess-ws|vmess-ws-tls(argo)|hy2|tuic5
* 交互式4合1中加入全自动保活服务,只安装1没有保活，安装1和2或者直接安装2
```
bash <(curl -Ls https://raw.githubusercontent.com/eooce/sing-box/main/sb_serv00.sh)
```

## Serv00|CT8一键四协议无交互安装脚本vmess-ws|vmess-ws-tls(argo)|hy2|tuic5，全自动安装节点+全自动保活
* 默认不安装哪吒和TG提醒，如需要，在脚本前添加环境变量随脚本一起运行即可
* 可选环境变量：CHAT_ID BOT_TOKEN UUID NEZHA_SERVER NEZHA_PORT NEZHA_KEY ARGO_DOMAIN ARGO_AUTH CFIP CFPORT SUB_TOKEN
* v0哪吒变量形式:NEZHA_SERVER=nezha.abc.com  v1哪吒变量形式:NEZHA_SERVER=nezha.abc.com:8008,v1不需要NEZHA_PORT变量
* 需要订阅自动上传到汇聚订阅器，需先部署Merge-sub项目，部署时填写UPLOAD_URL环境变量为部署的首页地址,例如：UPLOAD_URL=https://merge.serv00.net
* ARGO_AUTH变量使用json时，ARGO_AUTH=‘json’  需用英文输入状态下的单引号包裹，例如：ARGO_AUTH='{"AccountTag":"123","TunnelSecret":"123","TunnelID":"123"}'
```
bash <(curl -Ls https://raw.githubusercontent.com/eooce/sing-box/main/sb4.sh)
```

* 带TG提醒、哪吒v1、argo固定隧道运行示列,里面的参数替换为自己的，不需要的变量直接删除,固定隧道密钥可以为token或json
```
CHAT_ID=12345 BOT_TOKEN=5678:AA812jqIA NEZHA_SERVER=nezha.abc.com:8008 NEZHA_KEY=abc123 ARGO_DOMAIN=abc.2go.com ARGO_AUTH='{"AccountTag":"123","TunnelSecret":"123","TunnelID":"123"}' bash <(curl -Ls https://github.com/eooce/Sing-box/releases/download/00/sb4.sh)
```


## Serv00|CT8一键三协议安装脚本vless-reality|hy2|tuic5
```
bash <(curl -Ls https://raw.githubusercontent.com/eooce/sing-box/test/sb_00.sh)
```

## Serv00|CT8 hysteria2无交互一键安装脚本
* 复制脚本回车全自动安装节点+全自动保活
* 默认不安装哪吒和TG提醒，如需要，在脚本前添加环境变量随脚本一起运行即可,v1不需要NEZHA_PORT变量
* v0哪吒变量形式:NEZHA_SERVER=nezha.abc.com  v1哪吒变量形式:NEZHA_SERVER=nezha.abc.com:8008
* 可选变量：CHAT_ID BOT_TOKEN UUID NEZHA_SERVER NEZHA_PORT NEZHA_KEY SUB_TOKEN
```
bash <(curl -Ls https://github.com/eooce/Sing-box/releases/download/00/2.sh)
```

## Serv00|CT8 tuic无交互一键安装脚本
* 复制脚本回车全自动安装节点+全自动保活
* 默认不安装哪吒和TG提醒，如需要，在脚本前添加环境变量随脚本一起运行即可,v1不需要NEZHA_PORT变量
* v0哪吒变量形式:NEZHA_SERVER=nezha.abc.com  v1哪吒变量形式:NEZHA_SERVER=nezha.abc.com:8008
* 可选变量：CHAT_ID BOT_TOKEN UUID NEZHA_SERVER NEZHA_PORT NEZHA_KEY SUB_TOKEN

```
bash <(curl -Ls https://github.com/eooce/Sing-box/releases/download/00/tu.sh)
```

## Serv00|CT8 vmess-ws-tls(argo)一键脚本
* 复制脚本回车全自动安装节点+全自动保活
* 默认不安装哪吒和TG提醒，如需要，在脚本前添加环境变量随脚本一起运行即可,v1不需要NEZHA_PORT变量
* v0哪吒变量形式:NEZHA_SERVER=nezha.abc.com  v1哪吒变量形式:NEZHA_SERVER=nezha.abc.com:8008
* 可选变量：CHAT_ID BOT_TOKEN UUID ARGO_DOMAIN ARGO_AUTH NEZHA_SERVER NEZHA_PORT NEZHA_KEY CFIP CFPORT SUB_TOKEN

```
bash <(curl -Ls https://github.com/eooce/Sing-box/releases/download/00/00_vm.sh)
```




# 3：游戏机hosting
## sing-box玩具四合一，默认解锁GPT和奈飞
* node,python,java,go环境的游戏玩具搭建singbox节点，集成哪吒探针服务
* 玩具默认vmess-argo ，支持多端口的玩具可自行添加端口变量同时开启4协议节点
* 对应文件夹即对应环境请下载对应文件夹里的文件上传并赋予权限，修改变量后运行
* ARGO_DOMAIN和ARGO_AUTH两个变量其中之一为空即启用临时隧道，反之则使用固定隧道
* 无需设置NEZHA_TLS,当哪吒端口为{443,8443,2096,2087,2083,2053}其中之一时，自动开启tls

## 游戏机hosting可选变量
  | 变量名        | 是否必须 | 默认值 | 备注 |
  | ------------ | ------ | ------ | ------ |
  | PORT         | 否 |  3000  |http订阅端口，对应的主运行文件中修改，列如：index.js,app.py中 |
  | ARGO_PORT    | 否 |  8001  |argo隧道端口，固定隧道token需和cloudflare后台设置的一致      |
  | UUID         | 否 | bc97f674-c578-4940-9234-0a1da46041b9|节点UUID和哪吒v1的UUID      |
  | NEZHA_SERVER | 否 |        | 哪吒服务端域名，v0:nz.aaa.com  v1: nz.aaa.com:8008       |
  | NEZHA_PORT   | 否 |  5555  | 哪吒端口为{443,8443,2096,2087,2083,2053}其中之一时，开启tls|
  | NEZHA_KEY    | 否 |        | 哪吒客户端KEY 或v1的NZ_CLIENT_SECRET                     |
  | ARGO_DOMAIN  | 否 |        | argo固定隧道域名，留空即启用临时隧道                        |
  | ARGO_AUTH    | 否 |        | argo固定隧道json或token，留空即启用临时隧道                 |
  | CFIP         | 否 |skk.moe | 节点优选域名或ip                                         |
  | CFPORT       | 否 |  8443  |节点端口                                                 |
  | INCLUDE_UDP_LINKS | 否 | 0 | 是否在默认订阅中输出 HY2/TUIC；默认不输出，设置为 1 时输出 |
  | HY2_PORT     | 否 |        | hy2端口,支持多端口的玩具可以填写，不填写该节点不通             |
  | REALITY_PORT | 否 |        | vless-reality端口，支持多端口的玩具可以填写，不填写该节点不通   |
  | TUIC_PORT    | 否 |        | tuic-v5端口，支持多端口的玩具可以填写，不填写该节点不通         |

## 游戏机hostong节点输出
* 输出sub.txt节点文件，可直接导入V2ray，nekbox，小火箭等代理软中
* 订阅：默认不开启，多端口玩具可开启：分配的域名:http端口/sub,前缀不是https，而是http，例如http://www.google.com:1234/sub

## ⚠️ 免责声明
* 本程序仅供学习了解, 非盈利目的，请于下载后 24 小时内删除, 不得用作任何商业用途, 文字、数据及图片均有所属版权, 如转载须注明来源。
* 使用本程序必循遵守部署免责声明，使用本程序必循遵守部署服务器所在地、所在国家和用户所在国家的法律法规, 程序作者不对使用者任何不当行为负责。
