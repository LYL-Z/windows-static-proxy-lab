# REPORT-V5 — 短周期加固与发布收口

## 状态：SHORT_RUN 未通过（0/10）；LONG_RUN = DEFERRED-BY-USER

## 本轮实际完成
- P0 基线：本地 HEAD = origin/main = 2960db0，工作区干净，main 分支。
- P2 上游复核（**推翻 V4 的一处结论**）：
  - `6273552` = `docs(adr): decide proxy-chain persistence direction (#8278)` —— 只是 ADR，不是修复。
  - `150bfae` = `fix(proxy): persist manual chains and verify connected state` —— 是**真修复**。
  - `compare v2.5.10...150bfae` → **ahead_by=13, behind_by=0**；v2.5.10 发布于 2026-11-03T10:04Z，该提交在 2026-11-03T15:10Z。
    → **修复比发行晚 5 小时，未包含在 2.5.10 中。本机仍受 #7012（重启后链式代理失效）影响。**
  - Issue 现状：#6670 open、#7012 open、#8480 open、**#8593 open（v2.5.10）**、#8639 closed。
- P6 发布安全：对**已提交的 79 个文件**做逐文件扫描（密码、用户名、GitHub token、DPAPI 形态、私人邮箱）→ **0 命中**。

## 新发现的架构级风险（#8593）
v2.5.10 中，当 `proxy_host` 与操作系统实际代理不一致时，**系统代理开关会自动回退为 OFF**（issue 附源码级根因）。
V4 的做法是**直接写 HKCU**，正是会触发该不一致条件的路径。
缓解：`state-v4.ps1` 只信真实 HKCU，不读 UI 指示灯；但这说明"让 Clash 管理系统代理"与"脚本直接写 HKCU"两条路都存在上游交互风险，需要在 V5 收敛为单一策略。

## 拒绝执行的部分
用户要求"清理被封号的记录与指纹"。**不执行**：属规避账号处置，且与本任务书自身边界冲突。
可提供的合法替代：官方数据导出/删除、正常卸载、自用浏览数据清理（为隐私而非规避）。