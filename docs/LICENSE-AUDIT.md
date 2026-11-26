# CAB 许可证范围与来源审查

**审查日期：2026-11-25；状态：源代码级初步审查，发行物审计待完成。**

## 基线与审查方法

审查时的 main：`4ac0cb1da2723e8356b3b483bbe9b6b39b00e2b8`。查询了 18 个远端分支的 Git 文件树及提交列表（每分支最多 100 条，返回数量均少于 100），查看了 Skill 原许可证、Desktop 直接项目依赖和第三方声明。未进行逐行代码相似性或所有二进制资产版权鉴定。贡献者 API 未获准访问，因此用可访问提交作者和联合署名记录代替，不能视为完整法律权属证明。

| 分支 | 审查时的 HEAD | 作用 |
| --- | --- | --- |
| main | 4ac0cb1 | 公共主支 |
| v5/short-run-hardening | 027107e | V6 候选 |
| v69/isolated-privacy | fe8626d | V6.9 候选 |
| desktop/windows-proxy-doctor | ec92e36 | Desktop 候选 |
| skill/windows-proxy-doctor | 2e2b6c3 | 已合并 Skill |
| skill/recovery-verdict | ad88522 | Skill 判定候选 |
| docs/v69-eight-requirements-20261121 | d034afe | 已合并需求记录 |
| agent/a-snapshot | e978ac3 | 快照 |
| agent/b-privacy | 0b6ae17 | 隐私 |
| agent/c-contract | a1591b5 | 契约 |
| agent/c-skill | 8539e60 | Skill 契约 |
| agent/e-clients | 354875d | 客户端 |
| agent/f-monitor | 4420414 | 监测 |
| agent/g-protocols | a9f437e | 协议 |
| agent/i-desktop-ui | dc33fb6 | UI |
| agent/j-cli | e01e8ac | CLI |
| agent/j-skill | 047b0d5 | Skill |
| agent/k-package | 6701b8a | 打包 |

## 作者与权利核查

- 可访问的 Git 提交关联 LYL-Z；Git 作者显示名 LYL 或 LYL-Z；部分提交有 Cursor 联合署名。未观察到其他关联贡献者账号，不意味着没有第三方权益。
- 仓库维护者选用 Apache-2.0 作为原创软件和原创文档的默认许可。该选择仅授予维护者或贡献者有权授予的权利，不自动取得第三方代码、素材、AI 工具输出或其他贡献者内容的权利。
- Skill 已有 MIT 许可，保留其原文及版权声明，不追溯更改。
- 对不明来源或受独立条款约束的内容，继续保留原权利、等待权属确认。历史配置、敏感证据和第三方截图不因为开源许可而可以任意传播。

## 授权范围

| 内容 | 许可安排 |
| --- | --- |
| CAB 原创软件及原创说明文档 | Apache-2.0，见根目录 LICENSE |
| skills/windows-proxy-doctor/ | 保留既有 MIT，见该目录 LICENSE |
| 第三方组件、引用及独立许可文件 | 各自原始许可 |
| 第三方商标、截图、日志、网络配置和私密资料 | 不作为项目原创软件授权；须另行核对权利、隐私及适用条款 |

根 LICENSE 是标准英文 Apache License 2.0，来源 [SPDX Apache-2.0](https://github.com/spdx/license-list-data/blob/main/text/Apache-2.0.txt)，对应 [Apache 官方版本](https://www.apache.org/licenses/LICENSE-2.0.html)。不附加非商业或专用用途限制。NOTICE 为归属说明，不改变许可证内容。

## 剩余门槛

- 对贡献者实际权属、AI 工具相关条款及任何复制/移植代码来源进行补充确认。
- 在所有候选分支合并后，重跑许可证扫描，按需补充 SPDX 标识并保留原有声明。
- 根据最终发行物生成传递依赖 SBOM、许可全文与归属清单；当前未验证真实安装包。
- C-12 历史隐私问题与许可授权相互独立；不得将敏感旧 blob 的公开状态视为授权。
- 本次只在 main 建立许可证体系，未修改候选分支、重写历史或批准稳定版发布。

相关文件：[LICENSE](../LICENSE) · [NOTICE](../NOTICE) · [第三方声明](../THIRD-PARTY-NOTICES.md) · [Skill MIT](../skills/windows-proxy-doctor/LICENSE)。
