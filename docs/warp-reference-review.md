# WARP 状态检测实现对照

2026-09-05 针对状态页长时间空白、平台检测失败及候选切换提示进行了源码对照。以下链接固定到当日检查的提交。

| 项目 | 查到的实现 | 对本项目的取舍 |
|---|---|---|
| [老王 ssh_tool](https://github.com/eooce/ssh_tool/blob/0b634c2aa7437cb3d4fd2fb0550f2c8573b499bc/ssh_tool.sh#L1367) | WARP 菜单调用 fscarmen；仓库还保存了一份 [WARP 实现](https://github.com/eooce/ssh_tool/blob/0b634c2aa7437cb3d4fd2fb0550f2c8573b499bc/menu.sh)，使用持续运行的接口、Client 或 WireProxy，并设置等待、超时和重试 | 参考复用连接、等待就绪和有界探测的流程，保留 sing-box 内置 endpoint 分流架构 |
| [科技狮](https://github.com/kejilion/sh/blob/a74495cc3ea4bac1b0b42bf572f0f122ba9e2cf1/kejilion.sh#L30086) | WARP 入口同样调用 fscarmen | 该入口没有另一套独立的解锁判定可直接替换 |
| [甬哥 warp-yg](https://github.com/yonggekkk/warp-yg/blob/f2f634ba79452a0ffadcd93a6e6524cf4b7b84df/CFwarp.sh#L410) | 按地址族或 SOCKS 代理检测；此快照中 ChatGPT 判断依赖响应是否含 `VPN` 或 `Request` | 保留分地址族探测思路；不复用宽泛的成功判定，拒绝响应也可能包含 `Request` |
| [233boy sing-box](https://github.com/233boy/sing-box/blob/2d78583b5aecccb0da0148a816bc1495a284509f/src/dns.sh) | 独立 DNS 模块，支持多种传输及新旧内核配置格式；检查的核心和帮助模块未发现四平台 WARP 优选器 | 参考把 DNS 故障与平台拒绝分开诊断的方式；不移植整个管理器 |

本次没有复制第三方实现代码或安装其系统级 WARP 组件。实际修复包括：

- 状态页立即输出握手进度，先展示连接结果，再逐项显示平台检测结果。
- 状态检测和提交后验证均复用已经完成握手的临时代理，统一清理；避免再次冷启动引发误判或回滚。
- Gemini 请求超时仍返回未确认状态，并明确显示超时；ChatGPT 明确拒绝仍视为受限。
- 自动优选只在全部所选平台通过并提交配置后显示已启用，候选阶段只说明正在测试。

在授权测试 VPS 的真实终端中，`sb → 8 → 5 → 返回 → 退出` 已走通；一次记录中首条反馈为 0.01 秒，全部结果约 25.6 秒后完成。另一次握手失败也能显示失败原因并返回菜单。耗时和外站结果会随网络及平台策略变化。

原生 DNS 与临时 HTTPS DNS 的对照未证明后者能稳定消除所有平台失败，因此本轮未更改系统 DNS。用户截图中的注册域名解析超时，以及平台拒绝/检测超时，不构成已解锁的证据；自动优选继续保留严格的成功条件。
