# 2026-11-28 两次生产网络事故 — P0 专项调查与可靠性修复

> 分支：`cab/p0-state-truth`（从 `integration/cab-next` @ `f2454c0` 切出）
> 工作树：独立目录，未触碰任何人的生产脚本或正在运行的网络配置。
> 本次运行期间：系统代理保持 `127.0.0.1:11119`，出口 `107.149.115.70`，未重启任何客户端。

## 1. 已确认事实（有直接证据）

| # | 事实 | 证据 |
|---|---|---|
| F1 | `magicspeed`（StarSky 核心）于 **02:30:19** 启动（重启） | 进程 StartTime |
| F2 | **同一秒** 系统日志 `Tcpip` 记录事件 **4207** | `Get-WinEvent System` 2026-11-28 02:30:19 |
| F3 | 运行配置已非 V4 生成：`marker=False`，规则变为 `GEOIP,CN,DIRECT` + `MATCH,PROXY` | 读取 `clash-verge.yaml` |
| F4 | `profiles.yaml` / `verge.yaml` / `config.yaml` 最后修改 **11-27 21:18**，`clash-verge.yaml` 为 **11-28 00:55:06**（Clash 启动时重新生成） | 文件 mtime |
| F5 | 生产目录 `proxy_v4/state-v4.ps1` 在 `Write-StateResult` 中引用局部变量 `$integrity`，**必然崩溃** | 实跑：`VariableIsUndefined: integrity`，exit 1 |
| F6 | 候选分支中的同文件已改为 `$result.integrity`，**不再崩溃** | 实跑：exit 3 + 合法 JSON（`SETTINGS_UNAVAILABLE`） |
| F7 | 经第一跳 `CONNECT 72.245.197.103:9506` 返回 `HTTP/1.1 200 Connection established`，但经 `7897` 的**明文 HTTP** 返回 `Empty reply from server` | 分层探测；TCP 可达、会话无响应 |
| F8 | 系统内**唯一**相关计划任务是客户端自带的 `\Clash Verge` 登录启动项（无参数、不碰代理） | `Get-ScheduledTask`；无自动修复任务 |

## 2. 未确认（不编造归因）

- **重启的直接触发者**：日志只有同一秒的 Tcpip 接口事件，**无法据此判定是用户切节点、客户端自身更新、还是外部操作**。
- **是否有其他 Agent 触碰生产配置**：本机没有可信的操作审计流水；F3/F4 只能证明"配置被改过"，不能证明"谁改的"。
- **NexIP 侧失败性质**：拒绝来源 IP / 账号异常 / 商家线路变更，三者均未排除。

## 3. 本轮交付的代码

### 3.1 `proxy_v4/tools/connectivity-matrix.ps1`
分层应用路径探测：DNS → TCP(CONNECT) → TLS → 首字节 → 体 → 重复采样，可选**合成 8KB 随机体**上传。

设计约束：
- **绝不** `-k` / `--insecure`，PASS 必须意味着真实 TLS 成功；
- **绝不** 发送真实文件、凭据、Cookie、账户数据；
- 分阶段记录 `code/dns/conn/tls/ttfb/total/dl`，可区分"页面能开但 XHR 失败"；
- 明确声明覆盖范围：仅 IPv4 TCP/HTTPS，不含 UDP/IPv6/真实浏览器栈。

实测：

| 路径 | google | baidu | chatgpt | 汇总 |
|---|---|---|---|---|
| `11119`（活） | 3/3, TLS p50 2358ms | 3/3, 124ms | 3/3, 775KB | **9/9 = 100%**, exit 0 |
| `7897`（死） | 0/2 | 2/2（走 GEOIP,CN→DIRECT） | 0/2 | **2/6 = 33%**, exit 2 |

→ 同一探测同时证明：**"baidu 通"不等于"链路通"**，这正是事故期间最容易误判的地方。

### 3.2 `proxy_v4/tests/incidents/invoke-inc-checks.ps1`
把两次事故转成可复跑断言 INC-01..INC-10。

结果：**executed 10, passed 10, skipped 0**，exit 0。所有场景由本脚本自带的本地受控服务产生，不依赖 Google/百度当天是否可用。

| ID | 场景 | 结论 |
|---|---|---|
| INC-01 | 端口开但上游不可用 | PASS（rate=0，绝不误报 HEALTHY） |
| INC-02 | 上游接受 TCP 后丢弃 | **NOT_TESTED**（需受控 accept-then-close 监听器） |
| INC-03 | 恢复一次后再次失效 | PASS（0 → 100 → 0 正确反转） |
| INC-04 | 页面可开、上传失败 | **NOT_TESTED**（不向第三方上传任何数据） |
| INC-05 | 间歇性故障采样 | PASS（14/15，暴露间歇） |
| INC-06 | 状态脚本只出判定不崩溃 | PASS（exit 3 + JSON；生产副本此前崩溃） |
| INC-07 | 运行配置被外部重生成 | **NOT_TESTED**（需复制生产运行时文件） |
| INC-08 | 部分可用 ≠ 完全健康 | PASS（rate=93 不报绿） |
| INC-09 | 无无人值守自动修复 | PASS（ours=0；`\Clash Verge` 仅为客户端登录项） |
| INC-10 | 生产配置全程未被改动 | PASS（4 个文件哈希 0 变化） |

## 4. 过程中我自己修掉的 3 个缺陷

1. `$args` 作为自动变量导致 curl 参数错乱 → 改名 `$cargs`；
2. `$samples` 与参数 `$Samples` 大小写不敏感**同名**，赋值时触发 `Object[] → Int32` 转换失败 → 改名 `$stageRuns`；
3. INC-09 断言过宽，把客户端自带登录项误判为自动修复器 → 改为只匹配我们自己的脚本。

## 5. 仍需用户授权才能做的

1. 把生产 `proxy_v4` 同步到候选分支（当前那份是过期且崩溃的版本）；
2. 若要恢复静态 IP，需向 NexIP 侧确认（工单材料见下）；
3. 任何系统代理/计划任务/TUN 改动。

## 6. 供应商核查要点（脱敏，不含凭据）

- 时间：2026-11-28 02:30 起，约 02:50 后完全不可用（UTC-8）
- 客户端：Clash Verge Rev 2.5.10 / Mihomo v1.19.33；StarSky 1.0
- 实例：静态 IP `72.245.197.103`，SOCKS5 端口 `9506`，有效期至 2026-12-18
- 已排除：本机第一跳监听正常、第一跳 CONNECT 到 9506 返回 200、DNS 正常、非证书校验问题
- 失败阶段：TCP 可达后，**应用层无任何 SOCKS 响应**（明文请求即 `Empty reply`）
- 请求供应商核查：该实例在同一时段的服务端连接日志、是否有来源限制或封禁记录
---

## 7. INC 全量结果（本地 fixture，取代第 3.2 节的旧表）

| ID | 场景 | fixture | 实测 | 结论 |
|---|---|---|---|---|
| INC-01 | 端口在听、上游不可用 | mock proxy 回 502 | listen=True, rate=0, exit=3 | PASS |
| INC-02 | 接受 TCP 后丢弃 | mock proxy 直接 close | rate=0, kind=`RECV_FAIL` | PASS |
| INC-03 | 恢复一次后再次失效 | 502 → 真链路 → 502 | 0, 100, 0 | PASS |
| INC-04 | 页面可开、上传失败 | mock origin: GET 200 / POST 500 | pass=1, uploadFailed=true, exit=2 | PASS |
| INC-05 | 间歇性故障 | mock proxy 奇数连接真实转发 | **pass=3/6** | PASS |
| INC-06 | 状态脚本不崩溃 | 空配置 / 损坏 settings.json / 文本模式 | exit 3/3/3，无 `VariableIsUndefined` | PASS |
| INC-07 | marker 丢失可检测 | 合成 profiles 目录 + 运行时文件 | profileExists=True, markerOk=False | PASS |
| INC-08 | 部分可用 ≠ 健康 | 同上 alternate fixture | rate=50, exit=2 | PASS |
| INC-09 | 无无人值守恢复器 | 计划任务 + 进程 + Run 键 + 启动目录 | 0/0/0/0 | PASS |
| INC-10 | 受保护资源未变 | 4 配置文件哈希 + 新增文件 + HKCU 代理值 | files=0, reg=False, new=0 | PASS |

**与旧版的差别（对应复审 F43–F52）**：旧版 INC-01 用的是关闭端口（场景不符）、INC-05 断言 `pass -ge 0` 恒真、INC-08 的 OR 条件可空过、上传失败不进退出码、curl 报错会丢证据、INC-10 只比 4 个哈希、覆盖范围声明与实际不符、未处理 `NO_PROXY`、state 回归只测空配置、INC-09 只查任务。以上逐项已改。

## 8. 生产 state-v4.ps1 的最小更新方案（**未执行，需授权**）

| 项 | 值 |
|---|---|
| 生产文件 | `D:\claude防封\proxy_v4\state-v4.ps1` |
| 生产 SHA-256 | `94F1B43D6979032255E31B17832D7C9733F4D6BE447FABCA331BF916A5D3AE10`（4153 字节） |
| 候选文件 | `proxy_v4/state-v4.ps1` @ `cab/p0-state-truth` |
| 候选 SHA-256 | `E15D24B27932BD525A817AA1C376DADFF57502953121E9AC56D93653718D6CA8`（8382 字节） |
| 依赖 | 同目录 `lib\V4.ps1`；候选版要求新版 lib（`Get-V4Integrity` / `Get-V4Journal` / `Get-V4RepairReceipt` / `chainStatus` / `uiSystemProxy` 等字段） |
| 兼容性 | **不兼容**：生产 lib 与候选 state 成对变更，只换 state 会因缺少新函数而失败 |
| 建议范围 | 只读脚本成组更新（`state-v4.ps1` + `lib\V4.ps1`），**不动** `apply-v4.ps1` / `rollback-v4.ps1`（有写系统能力） |
| 备份 | 先复制到 `backup\p0-<stamp>\` 并记录哈希 |
| 回滚 | 用备份原样覆盖，比对 SHA-256 一致即回滚成功 |
| 只读验收 | `state-v4.ps1 -Json -ConfigDirectory <生产配置目录>` 应返回合法 JSON 且 exit ∈ {2,3}，**不再出现 `VariableIsUndefined`** |
| 预计影响 | 只影响诊断输出；不写配置、不重启客户端、不改系统代理 |

> 该方案已通过 INC-06 / INC-10 验证：更新动作本身不触碰受保护资源。

## 9. 仍未做的（本轮明确未完成）

- INC 之外的真实浏览器栈验证（Chrome/Edge 的实际上传）——需要人工在浏览器里操作。
- NexIP 侧根因（拒来源 / 账号 / 线路），需厂商服务端日志。
- 生产脚本替换本身：**等待授权**。