# CAB 九分支接管台账（只读审计）

- 审计日期：2026-11-28
- 仓库：`D:\claude防封\publish`（git）
- 统一基线：`f2454c0`（`integration/cab-next` 的 HEAD，`git rev-parse` 已确认）
- 范围：`cab/a-engine`、`cab/b-actions`、`cab/c-protocol`、`cab/d-protect`、`cab/e-clients`、`cab/f-monitor`、`cab/g-desktop`、`cab/h-skill`、`cab/i-package`
- 方法：`git merge-base` / `git rev-list --count` / `git diff --stat` / `git diff --name-status` / `git diff` / `git show <branch>:<path>` / `git grep`；全部为只读命令。9 个分支的 merge-base 都是 `f2454c0`，即都是基线之上的线性增量，彼此不包含。
- 限制（重要）：**没有合并、没有 rebase、没有 reset、没有 checkout 分支、没有改动任何代码文件**；**没有执行任何测试脚本**（含 dotnet test、分支内 PowerShell/Python 脚本、安装器）；没有触发 GitHub Actions；没有改注册表、系统代理、防火墙、计划任务，没有重启任何客户端。文中标注“未验证”的结论只来自静态阅读。

---

## 一、结论总表

| 分支名 | 提交数 | 改动文件数 | 真实功能 | 是否接入产品 | 测试有效性 | 生产写入风险 | 结论 | 理由 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| cab/a-engine | 2 | 3（+257） | 文档消歧：15 项跨进程恢复与 19 项 preparation 断言是两份清单；新增 1 个合成“损坏 preparation journal”用例 | 否（只在 tests/repro 与文档） | 1 个自隔离 PS1，10 条断言，需 Windows PowerShell 5.1；未执行，无 CI | 低-中：以 `V4_TEST_MODE=1` 驱动真实仓库的 apply/rollback，写入限 TEMP | 部分保留 | 损坏 journal 用例补了此前未覆盖的盲区，值得留；两份 59 行说明约 2/3 重复，合并成一份即可 |
| cab/b-actions | 4 | 3（+191） | 新增 Windows CI：Core 的 dotnet test、Skill 三个测试脚本（WinPS 5.1 与 pwsh 各一遍）、PRIVATE KEY 扫描；另加 workflow_dispatch 的 V69 密封工作流 | 否（仓库 CI 基础设施，属测试入口） | 引用的 5 个脚本在基线均存在；技能测试头注释声明 temp root + fixtures；未在 GitHub 实跑（未验证） | 无宿主写入；不读 secrets，`permissions: contents: read` | 保留 | 零产品改动、与其它 8 个分支零文件重叠，却让 c/e/f 的 xUnit 与技能测试在合并后真正被执行 |
| cab/c-protocol | 2 | 6（+1119/-4） | 产品证据文案收紧：DNS 有答案≠路径证明、DoH HTTP 状态≠浏览器 DoH、IPv6 loopback 加“非公网 IPv6 路径”；加 4 个 xUnit 与 loopback 自检探针 | 是（`ProtocolEvidence` 经 `Checks.cs` 进入 UI/CLI 证据文本） | 4 个用例与新文案一致，可达分支已逐个核对；由 b-actions 的 core-tests 覆盖；未执行。探针需 Python，CI 未覆盖 | 无写：只读 HKCU 代理项与网卡 DNS、一次 example.com 解析、回环套接字 | 保留（探针标可选） | 唯一改到产品可见证据文本的分支，行为不变、可被 CI 验证；836 行探针是第二条同域维护线，建议不接 CI |
| cab/d-protect | 2 | 1（+81） | 纯文档：记录 failclose.py 一次本地重跑（退出码 2、汇总 UNKNOWN、四个作业场景 PASS、AppContainer UNKNOWN），写明 job object 覆盖范围与“生产防火墙规则未获授权” | 否 | 无新增测试；文中数据来自作者重跑，本次未复跑（未验证） | 无。文中提到的 program_block.py 会建删防火墙规则，但未运行，分支也未改该脚本 | 部分保留 | 重跑结论（尤其“不能写成整机断网开关”）有记录价值，但不宜再新增第 4 份边界文档，应并入既有验收/操作文档 |
| cab/e-clients | 2 | 4（+126） | `ClientLifecycle.ManualSteps(state)` 按状态返回 1–4 条固定人工步骤（StarSky 已停、Clash 仍监听场景），配 `CLIENT-STEPS.md` 与手动清单 | 否（只接了一半：`Classify` 已用于 ShellViewModel:433，`ManualSteps` 无任何调用方） | 1 个 xUnit 覆盖 7 个状态与非法枚举，只断言字符串常量；dotnet test 可跑，未执行 | 无（纯字符串，不启动进程、不连端口、不调 external-controller） | 修复后保留 | 语义保守正确，但当前是死代码 + 与 CLIENT-LIMITS/USER-GUIDE 重复的文档；先接到“客户端”页再合 |
| cab/f-monitor | 2 | 2（+225） | `MonitorEngine.SaveEvents/LoadEvents`：把内存事件窗口（≤200 条）以 JSONL 原子替换写入调用方指定文件，读回只取最新 200 行并恢复 sequence、不恢复采样状态 | 否（MonitorEngine 已用于 UI，但 Save/Load 无调用方；UI 持久化仍走 `EventLog`） | 3 个 xUnit（本地心跳不刷新上游、250 事件突发、250 行文件重载截断），期望值可手算复现；未执行 | 低但需约束：接受任意路径，会建目录并覆盖目标文件；若指向 EventLog 的 events.jsonl 会破坏事件页格式 | 修复后保留 | 持久化是真需求，但必须先把与 `EventLog` 的文件/职责分离，并补调用方，否则两个 200 行 JSONL 写者互相踩 |
| cab/g-desktop | 1 | 3（+68/-29） | 右侧改为固定页头（“当前页面” + 中文标题）、导航高亮从模板 DataTrigger 移到 Style.Triggers、概览页合并“进程/监听/建议”卡；附截图 | 是（`MainWindow.xaml`/`.xaml.cs`；绑定的 `Section`/`Advice` 基线已存在） | 无自动化测试；截图是唯一渲染证据（已查看，确为新版页头与高亮） | 无 | 保留 | 单文件 UI 改动加一个 converter，风险最低、用户可见；合入时顺手更新 README 截图引用并把截图归位 |
| cab/h-skill | 1 | 3（+21） | 新增 `references/operator-boundary.md`（变更被接受前只读、no-modify 优先、不承诺解封、StarSky 重启≠加速），SKILL.md 索引一行，加 1 个内容断言测试 | 是（技能入口 SKILL.md 的参考表新增一行） | 1 个 Check 只做文件存在 + 子串断言，属同义反复；会被 b-actions 的 skill-tests 执行；未执行 | 无 | 保留（可去重） | 21 行、零代码风险、补的是 agent 行为约束；长期应并入 safety.md，否则同义表述会漂移 |
| cab/i-package | 1 | 2（+262/-23） | 安装失败回滚：逐文件记录已写文件与新建目录，失败时按 SHA-256 校验后删除本次写入、删空目录、必要时留 `install-failed.json`，不动其它版本目录；加 `-FaultAfterCopiedFiles` 失败注入 | 是（`desktop/packaging` 安装器） | 测试扩 98 行，覆盖失败注入、上一版本 TreeStamp 不变、mixed 目录预存文件不丢；未执行，且不在 CI | 低：只写 AllowedRoot 下版本目录；测试只写 TEMP；仅读取 HKCU Run 与 WinINET 做前后不变比较 | 修复后保留 | 直接关闭 HANDOFF.md 明列的“自动回退未获证实”缺口，文件面孤立、零重叠；把测试开关限定为测试参数并补 CI 即可合 |

---

## 二、逐分支关键证据

### cab/a-engine（2 提交，3 新增文件，+257）
- 提交：`0366ad4`（记录 15 与 19 两份清单）、`f615e2c`（点名恢复行与 preparation 检查对应的文件）。
- 新增：`proxy_v6/tests/repro/CAB-COUNT-NOTE.md`、`proxy_v6/tests/repro/CAB-F35.md`、`proxy_v6/tests/repro/CAB-CorruptPreparationJournal.ps1`。
- 两份 md 都是 59 行，逐行比较只有约 20 行不同，结论完全一致。
- PS1 的行为：在 `%TEMP%\cab-f35-<guid>` 下以 `V4_TEST_MODE=1` 构造 journal，断言 `Get-V4Journal` 标记 `corrupt` 且仍 `preparation`，`rollback-v4.ps1 -ResolvePreparation ResumeClient` 与 `apply-v4.ps1 -DryRun` 都以 34 退出、journal 字节不变、无 client start 记录、锁被释放；结束时恢复环境变量并删除 TEMP 根。
- 基线已有相邻覆盖但都不是这一条：`V69PreparationCrash.ps1`（19 个 Check）、`V69SnapshotHardening.ps1`（快照重解析点/部分恢复）、`V69SnapshotSeal.ps1`（密文损坏）。
- 结论：**部分保留**，只留 PS1 + 合并后的一份说明。

### cab/b-actions（4 提交，3 新增文件，+191）
- 提交：`4f61d58`、`ccc1c51`、`4018c29`（移除本分支内先前添加的、缺所需检查的重叠工作流）、`4703752`（修版本检查丢引号）。净差异只有 3 个文件，历史中间态不会带到基线。
- 新增：`.github/workflows/cab-windows.yml`、`.github/workflows/cab-v69-seal.yml`、`docs/CAB-CI.md`。基线 `f2454c0` 没有 `.github` 目录。
- 引用的路径均已确认存在：`desktop/tests/ProxyDoctor.Core.Tests/...csproj`、`skills/windows-proxy-doctor/tests/Run-Tests.ps1`、`Run-FaultClassTests.ps1`、`Run-OnboardingTests.ps1`、`proxy_v6/tests/repro/V69SnapshotSeal.ps1`。
- 三个技能测试脚本均声明临时根 + 合成 fixture（`Run-Tests.ps1` 头注释：“No real HKCU, WinHTTP, network, proxy client, or credentials are touched”）；`V69SnapshotSeal.ps1` 用 `V4_TEST_MODE=1` + TEMP。
- 结论：**保留**，建议第一个合。

### cab/c-protocol（2 提交，6 文件，+1119/-4）
- 提交：`6f692fa`（写下协议限制）、`97957d4`（记录有计数的回环交换，未计数的解析路径保持未知）。
- 产品改动只有 `ProtocolEvidence.cs` 三处字符串：DNS 无接收端计数 → “A DNS answer is not a path proof…”，DoH 无接收端计数 → “…is not browser DoH…”，`Sentence()` 对 `protocol == "IPv6 loopback"` 追加 “…is not a public IPv6 path”。`Finish()` 的 `PathKnown`/`protected` 拒绝逻辑未改。
- 全仓 grep 确认基线没有别处断言旧文案，改词不会踩到其它测试。
- 4 个新用例的期望分支我逐个核对过：`Ipv6Loopback(exchanged:true,hits:1)` → `Available` 且 coverage 含“not production protection / not a public IPv6 path”；`10013` → `Rejected`；`timedOut` → `TimedOut`；DoH 200/204/403 无接收端 → `PathUnknown` 且含 “not browser DoH”。
- `CabProtocolLocal.ps1` 只读 `HKCU:\...\Internet Settings` 与 `Get-DnsClientServerAddress`，做一次 `example.com` 系统解析、一次回环 HTTP 204、一次 `[::1]` 交换，并对比前后指纹；`protocol_probe.py` 只绑 `127.0.0.1`/`::1`，`--self-test` 无公网/浏览器模式。
- 结论：**保留**（核心改动 + 测试），探针标为可选证据工具。

### cab/d-protect（2 提交，1 文件，+81）
- 提交：`e73ef64`（陈述 job object 覆盖范围、生产防火墙规则未授权）、`0b4089f`（用本地 fail-close 重跑替换未运行的覆盖声明）。
- 只新增 `docs/CAB-PROTECT.md`；引用的 `CAB-INTEGRATION.md`、`V69-CONTAINER.md`、`V69-ACCEPTANCE.md`、`V69-OPERATOR.md` 与 `proxy_v6/tests/repro/v69-failclose/failclose.py` 都在基线。
- 文档中的重跑数据（退出码 2、UNKNOWN、四场景 PASS、AppContainer 10060/UNKNOWN）本次未复跑，标“未验证”。
- 结论：**部分保留**，增量并入既有验收/操作文档。

### cab/e-clients（2 提交，4 文件，+126）
- 提交：`32d652c`（记录手动恢复清单、不改分类器）、`83291b7`（记录 StarSky 停止而 Clash 仍监听时的步骤）。
- `ClientLifecycle.ManualSteps` 在 `desktop/` 内只出现在自身定义、`CLIENT-STEPS.md` 与测试文件中；产品侧只有 `ShellViewModel.cs:433` 调 `Classify`，没有消费 `ManualSteps`。
- 测试覆盖：7 个枚举值各自非空且稳定、必含“重启不是加速已经恢复的证明”、`ListenerUpstreamUnknown` 恰好 3 条、`ListenerUpstreamFailed` = 前 3 条 + 1 条、非法枚举走默认分支。
- 基线 `CLIENT-LIMITS.md` 已写“重启进程…都不是加速已经恢复”，本分支又新增“手动恢复清单”，`USER-GUIDE.md:5` 再说一次。
- 结论：**修复后保留**（先接线）。

### cab/f-monitor（2 提交，2 文件，+225）
- 提交：`983c7b1`（250 事件突发下锁定最新 200 条）、`c9f26c5`（把事件窗口持久化到调用方指定文件）。
- `SaveEvents`：`Directory.CreateDirectory` → 写 `.tmp` → `File.Move(overwrite:true)`；`LoadEvents`：读全部行、反序列化 `MonitorEvent`、只保留最新 200 条、重算 `_sequence`，不恢复 `_runState` 与采样。
- 我按 sequence 手算过测试期望：`Running()` 先产生 1 条 start；文件用例 1 start + 1 本地心跳 + 250 失败 = 252 条 → 保留 seq 53–252，首条正是 `NewFailure f50`；再记一条心跳后首条变 `f51`，与断言一致。
- 与 `Runtime.cs` 的 `EventLog`（`%LOCALAPPDATA%\ProxyDoctor\events.jsonl`，JSONL、上限 200、`.tmp` 替换）是同一模式、不同语义，且文件名相同。
- 结论：**修复后保留**（先定文件与调用方边界）。

### cab/g-desktop（1 提交，3 文件，+68/-29）
- 提交：`62ea32d`（让当前页面在壳里显眼）。
- XAML：新增 `SectionTitleConverter`（overview/checks/monitor/privacy/clients/recovery/events/guide → 中文）；右侧改为 `Grid`（固定页头 + 独立 ScrollViewer）；NavButton 模板用 `TextBlock Text="{TemplateBinding Content}"` 取代 `ContentPresenter`；hover/选中触发器从模板移到 `Style.Triggers`（选中 Accent 底 + OnAccent 字 + SemiBold，hover AccentSoft）；概览页把进程/监听合成一张卡并加“建议”。
- 截图 `shots/overview.png` 为 1180x760，我提取后查看：页头“当前页面 / 概览”、左侧“概览”高亮、概览卡含进程/监听/建议，与改动一致；截图内含本机端口与客户端进程名（非凭据）。
- 结论：**保留**。

### cab/h-skill（1 提交，3 文件，+21）
- 提交：`fb183b2`（记录弱 agent 必须守的操作边界）。
- 新增 `operator-boundary.md` 11 行 + SKILL.md 索引 1 行 + `Run-FaultClassTests.ps1` 中 9 行 Check（断言 4 句短语存在）。
- 其中“read-only until a specific change is accepted”“no-modify”与 `scripts/ProxyFaultClass.ps1:208`、`SKILL.md:18`、`troubleshooting.md`、`safety.md` 重复；真正新增的是“do not promise unban”与“StarSky restart is not acceleration”。基线 skills 全文 grep 不到 `unban`。
- 结论：**保留（可去重）**。

### cab/i-package（1 提交，2 文件，+262/-23）
- 提交：`dfdd260`（复制失败时回退未完成的版本）。
- `Install-Package` 现在记录 `copied`（目标 + SHA-256）与 `created`（新建相对目录）；失败进入 `Undo-IncompleteInstall`：逐个 `Remove-OwnedFile`（路径必须严格子路径、非 Startup、非重解析点、哈希未变才删）、按深度删空目录、根目录本轮创建且为空则删，否则写 `install-failed.json`。复制前已有“目标不得已有 manifest / 不得覆盖已有文件”的前置校验，因此回退删 manifest 不会误删旧版本。
- 前置 helper 均存在：`Test-StrictChild`、`Assert-SafeRelativePath`、`Assert-NotStartupDestination`、`Assert-PathChainHasNoReparsePoint`、`Write-HashManifest`。
- 测试新增：`version-kept` 与 `version-partial` 两个并排版本；失败注入 1；断言上一版本 `Get-TreeStamp` 不变、失败目录被删或只剩 marker、`version-mixed` 里预存文件不被删、失败版本因缺 manifest 被拒卸载；结尾仍比较启动项/系统代理指纹。
- 结论：**修复后保留**。

---

## 三、接管建议顺序

先合“零产品风险、能放大其它分支验证能力”的，再合“有产品改动但要先决策”的，最后合“只有文档增量”的。

1. **cab/b-actions**（第 1）
   - 原因：仓库当前没有任何 CI；合入后 `dotnet test` 与 Skill 三套测试成为事实，c-protocol/e-clients/f-monitor 的 xUnit 才有被执行的机会。
   - 冲突面：只新增 `.github/` 与 1 个 doc，与其余 8 个分支零重叠。
   - 合入前：在真实仓库触发一次 `workflow_dispatch` 确认 runner 行为（待执行，本审计未触发）。
2. **cab/i-package**（第 2）
   - 原因：直接关闭 `HANDOFF.md` 里“自动回退未获证实”的已知缺口；只动 2 个 packaging 文件，与其它分支零重叠，回归面可控。
   - 合入前：把 `-FaultAfterCopiedFiles` 限定为测试参数（或在脚本头声明仅测试使用），并考虑把 `Test-InstallProxyDoctor.ps1` 纳入 CI（待执行）。
3. **cab/g-desktop**（第 3）
   - 原因：单文件 UI + 1 个 converter，用户可见；截图已能证明渲染结果。
   - 顺手：更新 `README.md:74` 的截图引用，把 `shots/overview.png` 与 `desktop/overview.png` 合成一套。
4. **cab/c-protocol**（第 4）
   - 原因：唯一改到产品证据文本的分支，改动很小；合入后由第 1 步的 CI 跑 4 个新用例。
   - 保留意见：`protocol_probe.py` 作可选证据工具，不接 CI，避免与 V69 三套探针并行维护。
5. **cab/f-monitor**（第 5）
   - 前置决策：`SaveEvents` 的目标文件必须是独立路径（例如 `monitor-events.jsonl`），不能与 `EventLog` 的 `events.jsonl` 混用；并补一个 UI/CLI 调用方，否则是死代码。
6. **cab/e-clients**（第 6）
   - 前置决策：把 `ManualSteps` 渲染到“客户端”页（`ShellViewModel` 已算出 `State`，接线成本低）；否则仅合文档没有产品价值。
7. **cab/h-skill**（第 7）
   - 原因：21 行、零代码风险。合入前建议把“不承诺解封”“StarSky 重启≠加速”并入 `safety.md`，再删除重复表述，避免第 5 份同义边界文档。
8. **cab/a-engine**（第 8）
   - 只合 `CAB-CorruptPreparationJournal.ps1` + 合并后的一份说明；两份 md 选一。
9. **cab/d-protect**（第 9）
   - 只把 fail-close 重跑结论并入 `docs/V69-ACCEPTANCE.md` / `docs/V69-OPERATOR.md`，不新增独立文档。

---

## 四、发现的重复实现

### A. cab/a-engine 内部两份文档重复
`CAB-COUNT-NOTE.md` 与 `CAB-F35.md` 都是 59 行、同一结论（15 项恢复 vs 19 项 preparation 断言不是同一份清单，不能相加），逐行比较只有约 20 行不同。建议只留一份，或把 15/19 两段并入 `docs/CAB-INTEGRATION.md`。

### B. cab/e-clients：代码字符串与两份文档三重重复
`CLIENT-STEPS.md`（全文）≈ `CLIENT-LIMITS.md` 新增的“手动恢复清单”≈ `USER-GUIDE.md:5` 的“重启不表示恢复”；`ClientLifecycle.ManualSteps` 的返回字符串又逐字复述这些条款。三处任一改动都会漂移。

### C. cab/f-monitor：`SaveEvents` 与既有 `EventLog` 重复
`desktop/src/ProxyDoctor.Core/Runtime.cs` 的 `EventLog` 已经是“JSONL + 上限 200 行 + `.tmp` 原子替换”，路径 `%LOCALAPPDATA%\ProxyDoctor\events.jsonl`；`MonitorEngine.SaveEvents` 复制了同一套写盘模式，且同样叫 events，但序列化对象不同。若将来指向同一文件，事件页会显示成 `MonitorEvent` JSON 或丢失 `{at,message}` 行。

### D. cab/c-protocol：探针与既有三套协议复现脚本重叠
`protocol_probe.py`（836 行）与基线 `V69Protocols.py`（432 行）、`V69SocketStages.py`（386 行）、`Run-V68Loopback.py`（167 行）测的是同一批 loopback DNS/TCP/UDP/IPv6；`CabProtocolLocal.ps1` 的 DoH 观察与 `V69DohCache.py`（102 行）部分重叠。新探针的增量是“按 `ProtocolEvidence` 的判定规则自检”，测量手法本身重复。

### E. cab/h-skill：授权边界四处重复
`operator-boundary.md` 与 `references/safety.md`（Default read-only、逐项授权）、`references/troubleshooting.md`（no-modify）、`SKILL.md:18`、`scripts/ProxyFaultClass.ps1:208`（`authorization = 'read-only until the user accepts one specific change'`）表达同一约束；仅“不承诺解封”“StarSky 重启≠加速”是新增。

### F. cab/d-protect：与既有验收/操作文档重复
`docs/V69-ACCEPTANCE.md` 的 `PRODUCTION_GATE`、`docs/V69-OPERATOR.md` 的逐项授权、`docs/V69-CONTAINER.md` 的 AppContainer 结论已覆盖该文档的大部分边界表述。

### G. 分支家族层面：`agent/*` 与 `cab/*` 同域并行
`agent/k-package`（3 文件，+609/-38）、`agent/e-clients`（3 文件，+274）、`agent/f-monitor`（2 文件，+547）、`agent/g-protocols`（2 文件，+630）、`agent/i-desktop-ui`（4 文件，+322/-52）等与本次 9 个分支覆盖同一批模块，但 `agent/*` 多为**整文件新增**（例如把 `ClientLifecycle.cs`/`MonitorEngine.cs`/`ProtocolEvidence.cs` 当新文件加入），而基线 `f2454c0` 已含这些文件；`cab/*` 才是在基线上的增量。另外 `agent/i-desktop-ui` 与 `cab/g-desktop` 都带一张 `shots/overview.png`，但 blob 不同（两张不同截图）。
- 证据：`cab/f-monitor` 只改 2 个已存在文件（+225），`agent/f-monitor` 新增同名 2 个文件（+547）；`cab/e-clients` 改 4 个已存在文件，`agent/e-clients` 新增 3 个文件。
- 结论：接管只走 `cab/*`；`agent/*` 作为历史参考，不合、不 rebase，避免整文件覆盖基线。
- 说明：`agent/*` 仅按 `git diff --stat`/`--name-status` 与关键字 grep 做了范围确认，未逐行审计。

---

## 五、未验证项（明确标注）

- 未执行任何测试：`dotnet test`、`Test-InstallProxyDoctor.ps1`、`CAB-CorruptPreparationJournal.ps1`、`Run-SelfTest.ps1`、`CabProtocolLocal.ps1`、三个 skill 测试脚本。
- 未在 GitHub Actions 上触发 `cab-windows.yml` / `cab-v69-seal.yml`，YAML 语义与 runner 行为未验证。
- 未在 Windows 真机运行 WPF 验证 cab/g-desktop 的 XAML 加载与触发器；只查看了分支提交的截图（1180x760，内容与改动一致）。
- cab/d-protect 引用的 fail-close 重跑数据、`check_offline.py --self-test` 退出码均为文档陈述，本次未复跑。
- cab/e-clients / cab/f-monitor 的 xUnit 未编译执行；只核对了用例断言与源码可达分支、手算了 sequence 期望值。
- cab/i-package 的失败回滚未实际执行；只核对了路径校验、哈希校验、前置 manifest 校验与测试断言的一致性。

---

## 六、接管结果（2026-11-28 收口）

本节由收口实际执行记录，不是审计推断。基线 `134ebf0`（`integration/cab-next`，已含 `7303ccd` 的 cab/b-actions）。全部 8 个 `cab/*` 分支都用 `git merge --no-ff` 合入；**没有删除分支、没有 rebase、没有强推、没有 push**。合并后按本节"落地提交"栏做小改，改动都进新的普通提交，不改写合并历史。

| 分支 | 结论 | 落地提交 | 合入后做了什么 |
| --- | --- | --- | --- |
| cab/i-package | MERGED（修复后） | `e20a077` 合并 + `4af0d5c` 修复 + `4d90dff` CI | 删掉生产安装器上的 `-FaultAfterCopiedFiles` 参数；失败注入改为测试从外部用 `FileShare.None` 锁住一个源文件，安装器本身回到零测试开关。`Test-InstallProxyDoctor.ps1` 新增独立的 `packaging-tests` job。本地跑通（`ROLLBACK: removed incomplete version`）。 |
| cab/c-protocol | MERGED | `c2d7f09` 合并 + `4211640` | 产品文案与 4 个 xUnit 原样保留；`CAB-PROTOCOL.md` 与 `docs/CAB-CI.md` 明确 836 行 `protocol_probe.py` 与两个 PS1 探针是可选证据、不进 CI、不作门禁。 |
| cab/e-clients | MERGED（修复后） | `5492415` 合并 + `f36e297` | `ManualSteps` 接到「客户端」页：`ShellViewModel.RenderClientLine` 按 Clash 核心状态取 `ManualSteps`，上游取监测 `upstream` 通道（无新鲜采样按未知）；新增 `ClientSteps` 与卡片。`CLIENT-LIMITS.md` 的手动清单改为指针，句子只留 `CLIENT-STEPS.md` 一处。 |
| cab/f-monitor | MERGED（修复后） | `255f91d` 合并 + `6b03434` | `MonitorEngine` 独占 `monitor-events.jsonl`（新增 `EventFileName` / `DefaultEventPath`），并在 `SaveEvents`/`LoadEvents` 里拒绝 `EventLog.FileName`；`EventLog.FileName` 公开为 `events.jsonl`。壳层在 `StopMonitor` 存、`StartMonitor` 恢复、「监测」页渲染窗口。新增 1 个 xUnit 锁住文件名分离。 |
| cab/g-desktop | MERGED | `d60c1fe` 合并 + `913b356` | XAML/converter 原样保留；`shots/overview.png` 归位为 `desktop/overview.png`，README 的截图引用改成本仓库相对路径（原来钉在旧提交的绝对 raw URL，指向没有页头的旧界面）。 |
| cab/h-skill | MERGED（去重） | `2649780` 合并 + `f6bc02a` | `operator-boundary.md` 只留两条新增规则（不承诺解封、StarSky 重启≠加速），read-only 与 no-modify 改为指向 `safety.md` 与 `Resolve-ProxyDoctorUserRequest`；`safety.md` 加一行指针。四条断言串仍全部存在，`Run-FaultClassTests.ps1` 22/22 本地通过。 |
| cab/a-engine | MERGED（部分保留） | `158c762` 合并 + `d839174` | 保留 `CAB-CorruptPreparationJournal.ps1`（本地 10/10 PASS，已进 `engine-tests`）。两份 59 行说明合成一份：`CAB-COUNT-NOTE.md` 删除，独有句子并入 `CAB-F35.md`。 |
| cab/d-protect | MERGED（部分保留） | `7564a94` 合并 + `03d92c0` | 不新增第 4 份边界文档：`docs/CAB-PROTECT.md` 删除，重跑数据、作业对象覆盖、未覆盖范围与三件事区分并入 `docs/V69-ACCEPTANCE.md` 的「进程失败关闭的本地重跑」。 |

无 REJECTED / BLOCKED / SUPERSEDED。

### 收口的本地实测（同一台机器，Windows PowerShell 5.1，非管理员）

| 项 | 命令 | 结果 |
| --- | --- | --- |
| Core xUnit | `dotnet test desktop/tests/ProxyDoctor.Core.Tests -c Release` | 94 passed / 0 failed（含 c-protocol 4 个与 f-monitor 新增用例） |
| Desktop 编译 | `dotnet build desktop/src/ProxyDoctor.Desktop -c Release` | 0 warning / 0 error |
| CLI 编译 | `dotnet build desktop/src/ProxyDoctor.Cli -c Release` | 0 warning / 0 error |
| 引擎套件 | `proxy_v6/tests/Run-Tests.ps1` | registered=114 executed=114 passed=114 failed=0 skipped=0，退出码 0，213.7 秒 |
| 损坏 preparation 探针 | `proxy_v6/tests/repro/CAB-CorruptPreparationJournal.ps1` | 10 条断言 PASS，退出码 0 |
| 安装器回滚 | `desktop/packaging/Test-InstallProxyDoctor.ps1` | PASS，退出码 0，29.9 秒 |
| Skill 三套 | `Run-Tests.ps1` / `Run-FaultClassTests.ps1` / `Run-OnboardingTests.ps1` | 15/15、22/22、24/24，退出码 0 |

### F77 / F53 的关闭方式

`.github/workflows/cab-windows.yml` 新增 `engine-tests`（`windows-latest`，40 分钟）：先确认 `Run-Tests.ps1`、`Harness.ps1`、`lib/TestSupport.ps1` 存在，再用 Windows PowerShell 5.1 实际执行 114 项套件，证据写 `$env:RUNNER_TEMP\v6-evidence\evidence.json`，失败时打印计数、非 PASS 用例与 harness/evidence 错误并以套件退出码失败；同 job 再跑 `CAB-CorruptPreparationJournal.ps1`。`core-tests`、`skill-tests`、`secret-scan` 未改坏；`pwsh` 缺失仍然 fail（`4aa4333` 的逻辑保留）。

**未在 runner 上验证**：本轮没有 push，也没有触发 GitHub Actions，因此上述 job 的真实 runner 行为（checkout、runner 自带 5.1、40 分钟是否够用）都还是本地证据，不是 CI 通过结论。

