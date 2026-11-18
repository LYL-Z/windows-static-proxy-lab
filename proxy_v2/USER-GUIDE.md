# 使用指南（USER-GUIDE）

## 0. 先看这里：你现在的状态

```powershell
cd D:\claude防封\proxy_v2
powershell -ExecutionPolicy Bypass -File .\status.ps1
```

| `verdict` | 含义 | 该做什么 |
|---|---|---|
| `OK` | 实际模式与预期一致且健康 | 无 |
| `MISMATCH` | 有人在抢系统代理（通常是 StarSky 或 Clash 启动时的行为） | 重跑 `apply-v2.ps1 -Mode NEXIP ...` |
| `DEGRADED` | 链路降级（第一跳挂了 / 核心崩了） | 看 `reasons`，先修 StarSky 或重启 Clash |

`status.ps1` 一定同时显示 **exit (system)** 与 **exit (direct)** 两个真实出口 IP —— 这就是"我到底用哪个 IP 在上网"的唯一可信答案。

---

## 1. 三种模式的切换

### 1.1 切到 NexIP 静态代理（默认目标）

前提：**StarSky 已点"开始加速"**（本地 `127.0.0.1:11119` 在监听）。

```powershell
powershell -ExecutionPolicy Bypass -File .\apply-v2.ps1 -Mode NEXIP -AcknowledgeCredentialAccess
```

该命令会：发现路径 → 验证第一跳真的能代理 → 快照 → 生成配置 → `mihomo -t` 校验 → 原子替换 → 重启 → **验证真实出口 IP** → 才接管系统代理。

预期出口：`72.245.197.103`。

想先只看不写：

```powershell
powershell -ExecutionPolicy Bypass -File .\apply-v2.ps1 -Mode NEXIP -DryRun -AcknowledgeCredentialAccess
```

### 1.2 切到 StarSky 普通代理

```powershell
powershell -ExecutionPolicy Bypass -File .\apply-v2.ps1 -Mode STARSKY
```
停止 Clash，系统代理指向 `127.0.0.1:11119`。预期出口：StarSky 节点（当前 `142.111.173.93`）。

### 1.3 切回原始网络

```powershell
powershell -ExecutionPolicy Bypass -File .\apply-v2.ps1 -Mode RAW
```
停止 Clash 并清空系统代理。**然后手动在 StarSky 点"停止加速"**——脚本不会替你操作别的软件界面；停掉 TUN 后出口才会回到本地 ISP。

---

## 2. 回滚

```powershell
# 看有哪些快照
powershell -ExecutionPolicy Bypass -File .\rollback-v2.ps1 -List

# 回滚到最近一次 apply 之前
powershell -ExecutionPolicy Bypass -File .\rollback-v2.ps1

# 回滚到指定快照
powershell -ExecutionPolicy Bypass -File .\rollback-v2.ps1 -SnapshotDir "D:\claude防封\proxy_v2\backup\20261118-021020"
```

回滚会：停进程 → 还原文件 → **逐文件 SHA256 校验** → 还原系统代理 → 仅当快照记录"当时 Clash 在运行"才重启 Clash（避免它一启动又把系统代理改回去）。

---

## 3. 验收与测量

```powershell
# 快速自检（12 次）
powershell -ExecutionPolicy Bypass -File .\validate-v2.ps1 -Runs 12 -Interval 2 -Tag quick

# 正式验收（300 次）
powershell -ExecutionPolicy Bypass -File .\validate-v2.ps1 -Runs 300 -Interval 0.2 -Tag acceptance300

# 分阶段延迟（看时间到底花在哪）
python .\benchmark.py --proxy 127.0.0.1:7897 --samples 20 --label chain
python .\benchmark.py --proxy 127.0.0.1:11119 --http --samples 20 --label firsthop
python .\benchmark.py --direct --samples 20 --label direct

# 24 小时稳定性（可随时 Ctrl+C，重跑会接着写）
python .\monitor-v2.py --hours 24 --interval 60 --out test-results\soak-24h.jsonl
```

退出码约定：

| 脚本 | 0 | 非 0 |
|---|---|---|
| `apply-v2` | 成功 | 10 路径/依赖缺失，11 未确认凭据访问，12 凭据/目标缺失，20 第一跳不可用，30 未能在 45s 内监听 7897，31 链路验证失败（已回滚），32 系统代理设置失败 |
| `rollback-v2` | 成功 | 40 回滚失败 |
| `status` | `OK` | 2 `MISMATCH`/`DEGRADED`，3 无法判定 |
| `validate-v2` | 达标 | 5 成功率低于目标，6 参数/环境错误 |

---

## 4. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 浏览器出口变成 `142.111.173.93` | Clash 没在跑，StarSky 占了系统代理 | `apply-v2 -Mode NEXIP ...` |
| 出口变成中国 IP | 第一跳挂了，`resilient` 降级到 DIRECT | 检查 StarSky 是否"加速中"；或改用 `-Profile strict` |
| 全部网站打不开，`status` 报 `MISMATCH` | 系统代理指向了一个没在跑的程序 | 重新 `apply-v2` 或 `raw` |
| `apply-v2` 报 `20` | StarSky 未加速 / 11119 无监听 | 打开 StarSky 点开始加速 |
| `apply-v2` 报 `31` | 链路验证失败（多半是 StarSky 刚重启） | 等 10 秒重试；脚本已自动回滚，不会留下坏配置 |
| 打开网页很慢（2–4 s） | 双跳 + 住宅最后一公里，TLS 握手被放大 | 见 REPORT-V2 §5.2；换更快的 StarSky 节点或更快的境外第一跳 |
| Clash 界面显示"系统代理已关闭"但实际生效 | 系统代理被脚本或第三方改写 | 以 `status.ps1` 为准，不看 UI 文案 |

---

## 5. 不要同时做的事

- 不要同时开 Clash 的 TUN 和 StarSky 的 TUN（都抢 `utun119`/默认路由）；
- 不要在 StarSky 与 Clash 之间反复手动切换系统代理——用 `apply-v2` 走流程；
- 不要把 `proxy_v2` 目录放到共享盘或同步盘（里面有明文代理密码的备份副本）。
