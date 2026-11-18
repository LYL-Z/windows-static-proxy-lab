# NEXT-ACTIONS — V6.0

最后更新：2026-11-18T05:55-08:00

## 已完成（本轮）
1. F11 根因定位与网络恢复（系统代理当前关闭；Baidu/Google/ipify 200）。
2. 生产写门闩、test registry writer、test-mode Start/Stop no-op。
3. FT16–FT21、F07 16、F08 10、F10 10、INF 49、回滚 4 例；全量 92/92。
4. R2A-01/02/03/04/05/07/09、R2C-03/04/08 修复。
5. repo/proxy_v4/proxy_v6/.git ACL 加固。
6. 零断言判失败；父用例断言；92 用例 assertions 全部 >0。

## 立即执行
1. 运行最终全量 92 + META 7/7；保存 final.json/final.cases（干净树）。
2. 提交当前修复；推送 v5/short-run-hardening；保持 Draft PR，不合并 main。
3. 请 round2-transaction/round2-security/Agent E 对新提交做最终复核；确认 F11/R2A-01 关闭。
4. 若复审无新增 HIGH，更新 RELEASE-GATE-V6 为 SHORT_RUN_ACCEPTED（仍披露真实生产测试/长稳未执行）。
5. 若复审发现 HIGH，继续修复并保持 NOT_READY。

## 用户侧
- C-12 公开 IP/路径/用户名范围：WAITING-USER。
- C-01 快照明文凭据长期留存：需用户接受或后续加密/保留策略。
- NexIP 密码轮换：BLOCKED-USER。
- 真实 apply/rollback/boot/睡眠/Wi-Fi：**WAITING-USER**（需生产授权）；24h/72h：DEFERRED-BY-USER。
- Clash 国内直连规则（可选 B）：WAITING-USER；当前系统代理关闭，先不修改。