# Windows Proxy Doctor 2.0.0 RC2 发布门槛

候选可在隔离项目试用。查看 RC2 原始集成与严格恢复契约的变更记录。当前候选以自身的提交与验收结果为准。 [RC2 PR #2](https://github.com/LYL-Z/windows-static-proxy-lab/pull/2) · [恢复契约 PR #6](https://github.com/LYL-Z/windows-static-proxy-lab/pull/6)

| 门槛 | 通过所需证据 |
| --- | --- |
| CODE_READY | 原有 31 组和 RC2 定向回归通过。独立源码复审核对流程状态、未知证据及 Windows 兼容性。 |
| AGENT_INTEGRATION | Codex 从干净目录发现完整 Skill，并实际用五种自然语言场景检验适用参考、下一步和权限选择。目录发现与实际对话执行分别记录。 |
| CLEAN_INSTALLATION | 候选 SHA-256 和提交文件一致。验证隔离目录安装、移除和换回上一候选。另记录任何真实客户端安装。 |
| USER_ONBOARDING | 新设备上的首次用户从准备到实际应用验收。现有电脑、合成状态及指导文本各自保留证据范围。 |
| SECURITY | 核对许可、公开图片、来源与邀请披露、秘密扫描、独立验收和配置改动授权。 |
| PRODUCTION_UNCHANGED | 对比本轮操作前后的现有生产指纹和日常网络路径。运行态自行变化时记录时间及已知范围。 |
| RELEASE_READY | 真实新设备与首次用户验收待完成时保留 RC2，稳定版保持待验收。生命周期通过需来自实际对应事件。 |
