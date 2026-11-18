# LONG-RUN-RESULTS

| 项目 | 要求 | 实际 | 状态 |
|---|---|---|---|
| 24h 连续观察 | 24h | 0h | **PENDING** |
| 72h 扩展观察 | 72h | 0h | **PENDING** |
| 首试成功率 | ≥99% | 无 24h 窗口数据 | **PENDING** |

历史（不计入本轮）：V2 300 次/13.6min 100%；V3 冒烟 10/10。

工具：`proxy_v3\tools\monitor-longrun.py`（区分首试/重试、失败不删、未满时长报 PENDING）。

```powershell
python D:\claude防封\proxy_v3\tools\monitor-longrun.py --hours 24 --interval 60 --retry 2 --out D:\claude防封\proxy_v4\evidence\soak-24h.jsonl
```