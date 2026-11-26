# 使用指南 V3（USER-GUIDE-V3）

V3 不替代 V2 的日常操作，而是在其上加了三样东西：**状态机**、**故障注入自证**、**长稳（含首试成功率）**。

工具位置：`C:\CAB-Lab\proxy_v3\`（操作类脚本仍在 `proxy_v2\`，V3 直接复用，不改动）

---

## 1. 每天只用两条命令

```powershell
# 看状态（只读，2 秒）
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v3\state.ps1

# 如果不是 HEALTHY，重新应用
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v2\apply-v2.ps1 -Mode NEXIP -AcknowledgeCredentialAccess
```

`state.ps1` 输出的五态含义：

| 状态 | 含义 | 该做什么 |
|---|---|---|
| **HEALTHY** | 预期模式生效且出口正确 | 无 |
| **DEGRADED** | 可用但不符合预期（第一跳挂了→回落直连 / 系统代理被抢 / 出口不对） | 看 `reasons`；多半是 StarSky 掉了 |
| **FAILED** | 目标路径完全不可用（核心没起 / 7897 无监听） | 重启 Clash Verge |
| **RECOVERING** | 刚重启不到 25 秒，验证未稳定 | 等 30 秒再看 |
| **UNKNOWN** | 无法判定（配置缺失 / 探测全失败） | 先跑 `status.ps1` 看细节 |

退出码：`0` = HEALTHY/RECOVERING，`2` = DEGRADED，`3` = FAILED/UNKNOWN。

---

## 2. 三种模式（沿用 V2）

```powershell
# NexIP 静态代理（默认目标；需 StarSky 已加速）
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v2\apply-v2.ps1 -Mode NEXIP -AcknowledgeCredentialAccess

# StarSky 普通代理
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v2\apply-v2.ps1 -Mode STARSKY

# 回到原始网络（之后需手动在 StarSky 点"停止加速"）
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v2\apply-v2.ps1 -Mode RAW
```

回滚：

```powershell
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v2\rollback-v2.ps1 -List
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v2\rollback-v2.ps1
```

---

## 3. 自检：故障注入

```powershell
powershell -ExecutionPolicy Bypass -File C:\CAB-Lab\proxy_v3\invoke-faultinjection.ps1 -OutFile C:\CAB-Lab\proxy_v3\evidence\fault-injection.json
```

它会**真的**制造 5 种故障并断言系统反应，全程只读或可自动还原：

| 编号 | 注入 | 断言 |
|---|---|---|
| FI1 | 写入一份非法配置 | `mihomo -t` 必须拒绝 |
| FI2 | 用独占句柄锁住目标文件 | 原子替换必须失败且原文件完好 |
| FI3 | 调用 `state.ps1` | 必须给出状态而不是抛异常 |
| FI4 | 核心缺失检测路径 | 必须落到已定义状态 |
| FI5 | 探测一个关闭的端口 | 第一跳必须判 DOWN |

---

## 4. 长稳测试（按需启动，不自动跑）

```powershell
# 24 小时（推荐先跑这个）
python C:\CAB-Lab\proxy_v3\tools\monitor-longrun.py --hours 24 --interval 60 --retry 2 --out C:\CAB-Lab\proxy_v3\evidence\soak-24h.jsonl

# 72 小时扩展
python C:\CAB-Lab\proxy_v3\tools\monitor-longrun.py --hours 72 --interval 120 --retry 2 --out C:\CAB-Lab\proxy_v3\evidence\soak-72h.jsonl
```

**它和你以前看到的监测工具的区别**：

- **首试成功率**与**重试后成功率**分开统计，绝不混算；
- 记录**最长连续首试失败次数**和**按小时失败分布**；
- 失败样本一条不删；
- 中途 Ctrl+C 或断电，重跑会**接着写**（同目录 JSONL 追加）；
- 如果实际覆盖时长不足设定时长，结束时会报 **PENDING**，不会报 PASS。

查看现有结果：

```powershell
python C:\CAB-Lab\proxy_v3\tools\monitor-longrun.py --hours 0 --out C:\CAB-Lab\proxy_v3\evidence\soak-24h.jsonl
```
（`--hours 0` = 只做聚合，不新发请求）

---

## 5. 常用诊断

```powershell
# 出口对照：TCP 走静态 IP，UDP 走 StarSky —— 这是当前架构的边界
python C:\CAB-Lab\proxy_v3\tools\stun_probe.py
python C:\CAB-Lab\proxy_v3\tools\udp_relay_test.py
python C:\CAB-Lab\proxy_v3\tools\proto_probe.py

# 分阶段延迟
python C:\CAB-Lab\proxy_v2\benchmark.py --proxy 127.0.0.1:7897 --samples 20
```

---

## 6. 你必须知道的三个边界

1. **静态 IP 只覆盖 TCP。** UDP（WebRTC、QUIC、语音）走 StarSky，出口是另一个 IP。想让浏览器也统一，需要在浏览器里关掉 QUIC / 限制 WebRTC（`NETWORK-MATRIX.md` §5）。
2. **只用 WinHTTP 的程序不走代理。** 系统 WinHTTP 是 `Direct access`。
3. **StarSky 必须"加速中"。** 它是第一跳；它一退出，`state.ps1` 会变 DEGRADED，此时流量会回落到本地出口（`resilient` 档的行为）。

## 7. 出问题时的顺序

1. `state.ps1` → 看状态与 `reasons`
2. StarSky 是否"加速中"？（`Test-NetConnection 127.0.0.1 -Port 11119`）
3. 重跑 `apply-v2 -Mode NEXIP ...`
4. 还不行 → `rollback-v2.ps1` 回到上一个快照
5. 仍然异常 → `invoke-faultinjection.ps1` 看是哪一层坏了，并把 `evidence\` 下的 JSON 一并发给支持方
