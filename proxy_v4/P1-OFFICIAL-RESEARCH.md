# P1 — 官方资料研究结果（含对 V4 的修正）

检索时间 2026-11-18。强度：**OD** 官方文档 / **OS** 官方源码 / **OI** 官方 Issue / **TP** 第三方。
未安装任何东西、未登录、未修改本机。

## 1. Clash Verge Rev 已知缺陷（与你当前 2.5.10 的关系）

| Issue | 状态 | 内容 | 对本项目的影响 |
|---|---|---|---|
| **#7012** | **OPEN** | Win11 上开启链式代理后，**每次重启电脑都要断开再启用一次**才生效。社区给出的原因是：`clash-verge.yaml` 每次启动都从 `profiles\*` 重新生成，手改的 `dialer-proxy` 会被覆盖 → **必须把链式配置写进源 profile** | **V4 已经这样做**（写 `v4-managed.yaml` 源 profile，不靠改运行时文件）。这条正好解释了 V1/V2 为什么"重启后失效" |
| **#8639** | CLOSED（报告者自行关闭，0 评论） | **v2.5.10 + Win11**：系统代理自己关掉、托盘仍显示开启、只有 TUN 可用。日志：`Refreshing system proxy guard… Updating system proxy with duration: 30 seconds… Starting system proxy guard` 之后 `System proxy is disabled.` | **就是你的版本。** 这是对"让 Clash 拥有系统代理"这一设计的**现实威胁**（见 §3） |
| **#8480** | **OPEN** | 服务模式首次启动 `core IPC pipe did not become ready within 15s`，自动重试第 2 次成功；另有"第二个核心被拒绝"竞态 | V4 的 45s 等待可覆盖重试窗口；单实例由 Clash 自身兜底 |
| **#7696** | CLOSED | 右键"更新/通过代理更新"会把 `allow_auto_update: false` 静默改回 `true` | 属"选项被覆盖"同类问题，本项目不依赖该字段 |
| **#7942** | CLOSED | 订阅更新时 `Configuration validation is already running`，校验占用导致配置应用失败 | 别在校验进行中并发 apply（V4 已有锁） |

**未找到任何关联修复 PR/commit。** #8480/#7012 仍 OPEN，其在 2.5.10 上的表现属**推断**。

## 2. 官方机制（直接决定架构选择）

- **扩展配置/扩展脚本**是官方增强机制（旧称 Merge/Script），执行顺序：订阅原文 → 应用设置 → 全局扩展 → 订阅扩展 → 应用设置回写。
- **应用自管字段不允许扩展覆盖**（会被静默丢弃）：`external-controller(-cors)`、`secret`、`mixed-port`、`socks-port`、`port`、`mode`、`allow-lan`、`log-level`、`ipv6`、`unified-delay`、`tun.enable`、`dns.ipv6`。
- **`prepend/append` 已废弃**；节点/代理组的用户修改改为"每订阅右键 → 编辑规则/节点/代理组"，官方明确这种修改**不会**随订阅更新失效。
- **`dialer-proxy`**：必须写在 **proxy 条目**上；"proxy groups do not directly support dialer-proxy"（V4 写法正确）。
- **mihomo 不拒绝未知顶层键**（源码 `config/config.go` 无 strict 解码）→ 广泛流传的 `field … not found in type conf.RawConfig` 报错**与 v1.19.x 源码矛盾**，本案按"不会发生"处理。

## 3. 对 V4 的直接影响（重要）

### 3.1 #8639：我们依赖的"Clash 拥有系统代理"在 2.5.10 上并不完全可靠
症状与我们的设计冲突：系统代理可能被 guard 关掉而托盘仍显示开启。
**V4 的缓解**：`state-v4.ps1` 每次读取**真实 HKCU 值**并与 owner 记录比对，一旦不一致即报 DEGRADED，不信任任何 UI 状态。
**建议**（未执行）：保持 `enable_proxy_guard: false`；必要时由用户手动确认系统代理，而不是依赖 guard。

### 3.2 #7012 验证了 V4 的 profile 策略
"把链式配置写进源 profile"正是 V4 的做法（注册独立本地 profile）。这也意味着：**任何"只改 clash-verge.yaml"的方案在重启后都会失效**——V1/V2 的失败不是偶然。

### 3.3 M8 的官方解法比我实现得更"原生"
官方推荐用**每订阅的节点编辑**或**扩展配置**，而不是自行改 `profiles.yaml`。
V4 目前是"自建本地 profile + 改 profiles.yaml 的 current"：**可用，但不是官方路径**，属已知技术债（PROVIDER/架构层面记录）。

## 4. 任务计划：属性名与取值已核对

- 真实属性：COM/脚本 `MultipleInstances`，XML `MultipleInstancesPolicy`；取值 **0=Parallel、1=Queue、2=IgnoreNew、3=StopExisting**。
- 你机器上的 Clash Verge 登录任务当前是 **Parallel(0)** → 建议改 **IgnoreNew(2)**（未执行，待批准）。

## 5. Windows 行为核对

- `Wait-Process` **无输出、无退出码**，`-Timeout` 到期是**非终止错误**；要拿退出码需 `Start-Process -Wait -PassThru` 读 `.ExitCode`。
- V4 用的是"启动后轮询端口 + 校验 PID 消失"，不依赖 `Wait-Process` 的语义 → 结论不变。

## 6. 检测指标的官方定义（纠正此前的解读）

| 指标 | 官方事实 | 含义边界 |
|---|---|---|
| **Cloudflare Bot Score** | **每请求** 1–99（99≈人类，1≈机器人）；**0 = 未计算**；**细粒度分数仅企业版可见**，免费/普通用户只看到分组（1 / 2–29 / 30–99）；空 UA 强制为 1 | IPPure 的 `89/100 极度风险` **不是** Cloudflare 官方分数，是第三方自己的算法 |
| **Turnstile** | 必须服务端 Siteverify；**token 可被伪造**；有效期 300s、一次性；重放检测"最终一致" | "4/4 PASS" 只证明"取得并兑换了一个有效 token"，**不证明**是人类、更不证明账号安全 |
| **reCAPTCHA v3** | **每请求**打分 0.0–1.0，**按 action 区分**，阈值由站点自选（默认 0.5）；页面已标记 deprecated | `0.9/1.0` 不是"账号安全率"，也不跨站通用 |

## 7. 权限语义（用于扩展审查）

- `debugger`：可经 CDP **附加到标签页**，读写网络、调试 JS、改 DOM；DevTools 打开时会自动 detach；企业策略可禁。
- `nativeMessaging`：可与**本机原生程序**通信（安装时提示"Communicate with cooperating native applications"）。
- Chrome 商店政策要求**最小必要权限**，禁止"为未来功能预留权限"。

→ 此前对 7 个扩展的定性成立：持 `debugger + nativeMessaging` 者属最高权限档，应逐个核对来源与必要性。

## 8. 无法证实的部分

- 5 个 issue 均**未找到**关联修复 PR；#7942 的 3 条评论未读。
- #7012/#8480 在 2.5.10 上的具体表现是推断。
- GitHub API 被限流，issue 正文经 `r.jina.ai` 读取（返回的是同一份 JSON）。
- 未能取得 Cloudflare 关于"Turnstile 不证明什么"的正式措辞（是依据文档缺失做结论）。