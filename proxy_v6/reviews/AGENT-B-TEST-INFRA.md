# AGENT-B-TEST-INFRA — V6 测试基础设施交付报告

- 执行者：Agent B（test-infra，独立子代理）
- 日期：2026-11-18（America/Los_Angeles）
- 基线：分支 `v5/short-run-hardening`，HEAD `36222c92c829a2ef08b71af2a3a3ff9a3c44b396`
- 结论：测试框架与自验套件交付完成；META-01..META-07 在 Windows PowerShell 5.1 下 7/7 通过；自验运行器自身退出码 0/1/2/3/4 均经负控验证。**未执行 F07-F10 场景体**，只做了只读注册检查（29 项，0 注册错误），因此不声称产品正确性。

> 工作树说明：本轮 `git status` 显示 `proxy_v4/**` 与 `.gitignore` 有并发修改（由其他代理产生），且 `proxy_v6/` 为未跟踪新目录；HEAD 未变。Agent B 未对 `proxy_v4/**` 做任何写操作，未提交、未推送、未改写历史。因此证据 JSON 中 `git.dirty=true` 是真实的，不是本框架的误报。

## 1. 交付文件

| 文件 | 大小/行数 | 作用 |
|---|---|---|
| `proxy_v6/tests/Harness.ps1` | 26,746 B / 629 行 | 框架：`Register-Test`、`Invoke-TestRun`、断言、逐用例证据、最终 JSON、退出码 |
| `proxy_v6/tests/Run-Tests.ps1` | 2,435 B / 55 行 | 入口：加载 Harness + TestSupport，按名称加载 `cases\*.tests.ps1`，运行一次并传递退出码 |
| `proxy_v6/tests/lib/TestSupport.ps1` | 5,325 B / 138 行 | TEMP 隔离、文件/哈希助手、子 `powershell.exe` 运行器 |
| `proxy_v6/tests/self/SelfTest.ps1` | 31,702 B / 653 行 | META-01..07 自验运行器；用子进程 fixture 验证退出码/消息/证据 |
| `proxy_v6/tests/self/fixtures/*.ps1` | 9 个 fixture | pass / fail / fail-then-pass / harness-error / zero / skip / skip-all / runtime-skip / evidence-fail |
| `proxy_v6/tests/cases/README.md` | 2,452 B / 44 行 | F07-F10 场景文件接入约定（不含场景实现） |
| `proxy_v6/tests/README.md` | 2,558 B / 40 行 | 快速开始、退出码、证据结构、为何不用 Pester |
| `proxy_v6/evidence/selftest/canonical/` | 11 个文件 | 最终自验证据：`selftest.json`、`console.txt`、负控输出、空跑输出、注册检查 |
| `proxy_v6/evidence/selftest/negative-exit1,2,3/` | — | 负控原始子证据（exit 1/2 有 `selftest.json`；exit 3 无最终证据，符合设计） |

`proxy_v6/tests/cases/20-F08.tests.ps1`、`30-F09.tests.ps1`、`40-F10.tests.ps1`、`50-F07.tests.ps1` 由 lead/其他代理并发加入。Agent B 只读它们做注册检查（见第 5.4 节），未修改、未执行其测试体。

## 2. 契约实现（由代码强制，不是文档约定）

### 2.1 退出码与优先级

| 退出码 | 条件 | 实现位置 |
|---|---|---|
| 0 | 至少执行 1 个测试；所有已执行测试通过；无 harness 错误；最终证据写成功 | `Get-HarnessExitCode` + `Invoke-TestRun` |
| 1 | 任一已执行测试失败（断言失败或测试体抛出） | 同上 |
| 2 | 执行 0 个测试：未注册、Filter 未命中、或全部被跳过 | 同上 |
| 3 | 框架/运行器异常（含显式故障注入、注册表重复 ID 等） | `catch` + `Add-HarnessError` |
| 4 | 证据写入失败（最终 JSON 或逐用例证据无法写入） | `Add-EvidenceError` + 重算退出码 |

固定优先级：**3 > 4 > 1 > 2 > 0**。例如测试失败同时最终证据也写失败时，退出 4 而不是 1；框架异常同时证据失败时退出 3。所有非 0 情况都不会被误报为绿色。

### 2.2 计数语义

`counts` 包含：`registered`（Filter 选中的测试数）、`executed`（passed + failed）、`passed`、`failed`、`skipped`、`available`（运行前注册总数）。跳过项计入 `registered`，但**不**计入 `executed`/`passed`。全跳过时 `executed=0`，退出 2。

### 2.3 失败不可覆盖

结果列表是追加式（append-only）；汇总每次都从全部用例记录重新扫描。后续通过不会删除前面的失败记录，也不会降低 `failed` 计数。META-07 用“先失败、后通过”的 fixture 验证退出 1 且两条记录都保留。

### 2.4 逐用例记录

每个用例写入 `<evidenceDir>\<NNNN>-<safe-id>.json`，字段如下：

| 字段 | 说明 |
|---|---|
| `id` | 测试 ID |
| `requirement` | 需求/场景编号（如 F07、META-01） |
| `precondition` | 前置条件 |
| `injectedFault` | 注入的故障；正常路径写 `none` |
| `expected` | 预期结果 |
| `actual` | 实际结果（断言默认值或测试通过 `Set-TestActual` 设置） |
| `status` | `pass` / `fail` / `skip` |
| `passed` | 仅 `status=pass` 时为 true；`skip` 为 false |
| `detail` | 断言/异常详情（含期望值与实际值） |
| `durationMs` | 该用例耗时 |
| `assertions` | 已执行断言数 |
| `startedAt` / `finishedAt` | 时间戳 |
| `evidenceFile` | 该用例证据文件路径；写入失败时为空并计入 `evidenceErrors` |
| `testOutput` | 测试体输出（截断到 8000 字符，含通用脱敏） |

### 2.5 最终 JSON 与 stdout

最终 JSON 包含：`schemaVersion`、`tool`、`harnessVersion`、`runId`、`host`（PowerShell/OS/CLR 版本）、`git`（`head`/`branch`/`dirty`/`available`）、`repoRoot`、`filter`、`startedAt`、`finishedAt`、`durationMs`、`counts`、`exitCode`、`outcome`、`harnessErrors`、`evidenceErrors`、`cases`。stdout 输出逐用例 `[PASS]/[FAIL]/[SKIP]`、计数、证据路径和 `RESULT: <outcome> EXIT <n>`。

### 2.6 错误分类

- 测试体断言失败或抛出普通异常 ⇒ 该用例 `fail`（退出 1），不会被当作框架异常。
- 运行器内部异常（含自验专用 `-FaultStage`）⇒ `harnessErrors` + 退出 3；仍尝试写最终证据。
- 逐用例证据目录不可用 ⇒ 测试照常执行，`evidenceErrors` 非空，退出 4；若最终证据可写，仍会写出最终 JSON。
- 最终 JSON 写失败（例如父路径被普通文件占用）⇒ 无最终 JSON、stdout 明确 `[EVIDENCE-ERROR]` 与 `Evidence: NOT WRITTEN`、退出 4。

### 2.7 隔离与清理

- 自验工作目录：`$env:TEMP\v6-tests\<prefix>-<stamp>-<guid>`，由 `TestSupport.ps1` 的 `New-TestTempRoot` 创建。
- `SelfTest.ps1` 用外层 `try/catch/finally` 保证 `Remove-TestTempRoot` 执行；验证完成后临时根已不存在（见第 5 节）。
- 场景测试约定：在 TEMP 根下工作，`finally` 中调用 `Remove-TestTempRoot`；不得指向真实 `proxy_v4\config`、appdata、HKCU、Clash 进程或网络。
- `Run-Tests.ps1` 目前不加载 `repro/*.ps1`，只加载 `cases/*.tests.ps1`。

### 2.8 秘密脱敏

框架在写入证据与 stdout 详情前，对常见的 `password/passwd/pwd/secret/token`、`username/user` 键值和 `Basic <base64>` 做通用掩码。这是防御性措施，**不替代**生产日志脱敏测试（SEC-03）；场景测试仍不得打印真实凭据。Agent B 未读取或输出任何真实密码/用户名/DPAPI 密文。

## 3. 为什么不用 Pester 3.4 作为主运行器

1. 环境只有 2015 年的 Pester 3.4.0；其 `Invoke-Pester` 退出码/结果对象无法直接表达本任务的“零执行不得判通过”“证据写失败必须非零”“逐用例 requirement/fault 元数据”契约。
2. Pester 3.4 没有内建最终 JSON 证据、逐用例证据文件、跳过原因强制记录、harness 异常与测试失败分层。
3. 安装 Pester 5 会修改用户全局模块，未经授权；任务明确禁止安装模块。
4. 本框架只有 ~630 行、无外部依赖，并且被自验套件用真实 `powershell.exe` 子进程反向验证；比黑盒依赖一个过旧版本更可证明。
5. 仍使用 PowerShell 自带 Parser 做语法校验；未使用 Pester，未安装任何模块。`proxy_v6/tests/**` 中 grep 不到 Pester 引用。

## 4. 自验设计（META-01..07）

`SelfTest.ps1` 为每个 META 用例启动一个**独立** `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File` 子进程，传入临时 `-OutFile/-EvidenceDir/-Filter`，然后断言：

- 子进程退出码是否等于预期；
- stdout 是否包含 `RESULT:` / `[FAIL]` / `[SKIP]` / `[NO-TESTS]` / `[EVIDENCE-ERROR]` / `[HARNESS-ERROR]` 标记；
- 最终 JSON 的 `outcome`、`exitCode`、`counts`、`git.head`、时间戳格式、逐用例字段、`evidenceFile` 是否存在；
- META-06 还检查“最终证据不可写但逐用例证据仍写出”与“逐用例证据不可写但最终证据写出”两个方向；
- META-07 检查 `[FAIL]` 与 `[PASS]` 行同时存在、失败计数保留。

自验运行器自身也实现同一退出码契约，并用四个负控证明聚合逻辑不是恒 0：

| 负控 | 命令参数 | 观察退出码 | 证据 |
|---|---|---|---|
| 强制一个 META 检查失败 | `-InjectCheckFailure META-01` | 1 | `canonical/negative-exit1-console.txt`；`negative-exit1/selftest.json` |
| 不选任何检查 | `-Filter META-99` | 2 | `canonical/negative-exit2-console.txt`；`negative-exit2/selftest.json` |
| 运行器内部抛异常 | `-InjectHarnessError` | 3 | `canonical/negative-exit3-console.txt` |
| 证据目录被文件占用 | `-OutDir <blocked>\out` | 4 | `canonical/negative-exit4-console.txt` |

另有一个内部 sanity check：在跑 META 前用 `Add-Mismatch` 验证“1 vs 2 必须记录差异、same vs same 必须不记录”，防止自验本身的比较器失效导致所有 META 空洞通过。

## 5. 实际运行结果（原始输出与退出码）

### 5.1 最终自验（canonical）

命令（原始）：

```text
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "D:\claude防封\publish\proxy_v6\tests\self\SelfTest.ps1" -OutDir "D:\claude防封\publish\proxy_v6\evidence\selftest\canonical"
```

stdout（原文见 `canonical/console.txt`）：

```text
== V6 TEST HARNESS SELF-TEST ==
Repo: D:\claude防封\publish
Filter: META-*; selected: 7 of 7 META checks
--------------------------------------------------------------
[PASS] META-01 all valid tests pass -> exit 0 and evidence written
       child exit=0 expected=0
[PASS] META-02 any executed test fails -> exit 1
       child exit=1 expected=1
[PASS] META-03 framework exception -> exit 3, not pass/fail
       child exit=3 expected=3
[PASS] META-04 zero executed tests -> exit 2 even with a filter
       child exit=2 expected=2
[PASS] META-05 skips recorded separately; all-skip -> exit 2
       child exit=0 expected=0 mixed / 2 all-skip / 2 runtime
[PASS] META-06 final evidence write failure -> exit 4
       child exit=4 expected=4
[PASS] META-07 later pass never overwrites an earlier failure
       child exit=1 expected=1
--------------------------------------------------------------
SELFTEST COUNTS: selected=7 checks=7 passed=7 failed=0
SELFTEST EVIDENCE: D:\claude防封\publish\proxy_v6\evidence\selftest\canonical\selftest.json
SELFTEST RESULT: SELFTEST_PASS EXIT 0
```

实际退出码：**0**。`canonical/selftest.json` 中 `outcome=SELFTEST_PASS`、`exitCode=0`、`checks=7`、`passed=7`、`failed=0`；`git.head=36222c92c829a2ef08b71af2a3a3ff9a3c44b396`，`git.dirty=true`（并发修改 + 本交付未跟踪目录）。

### 5.2 META 覆盖对照

| META | fixture | 预期 | 实测 |
|---|---|---|---|
| META-01 | `pass.ps1` | exit 0；2 用例通过；证据存在 | exit 0，executed=2/passed=2，逐用例证据存在 |
| META-02 | `fail.ps1` | exit 1；失败记录保留 | exit 1，failed=2，`[FAIL]` 行存在 |
| META-03 | `harness-error.ps1`（`-FaultStage before-summary`） | exit 3；harnessErrors 非空 | exit 3，`HARNESS_ERROR`，错误含 `injected harness fault` |
| META-04 | `zero.ps1`；`pass.ps1 -Filter NO-SUCH-TEST-*` | exit 2；executed=0 | 两次均 exit 2，executed=0，`[NO-TESTS]` |
| META-05 | `skip.ps1` / `skip-all.ps1` / `runtime-skip.ps1` | 混合 0；全跳过 2；运行时跳过记录 | 0 / 2 / 2；skipped 单独计数，未计为 pass |
| META-06 | `evidence-fail.ps1` 最终路径被文件阻塞；逐用例目录被文件阻塞 | exit 4 | 两次均 exit 4；最终写失败时逐用例证据仍在；逐用例失败时最终 JSON 仍在且 `evidenceErrors` 非空 |
| META-07 | `fail-then-pass.ps1` | exit 1；失败不被后续通过擦除 | exit 1，passed=1/failed=1，失败记录在前且保留 |

### 5.3 入口零测试行为

用空临时 cases 目录运行 `Run-Tests.ps1`（显式 `-CasesDir <temp>\empty-cases`，避免执行 lead 的 F07-F10）：

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File D:\claude防封\publish\proxy_v6\tests\Run-Tests.ps1 -CasesDir <temp>\empty-cases -OutFile <temp>\evidence.json -EvidenceDir <temp>\evidence-cases
```


```text
Loaded test files: 0 from <temp>\empty-cases
...
Counts: registered=0 executed=0 passed=0 failed=0 skipped=0 available=0
[NO-TESTS] no test executed; a green result is not permitted (exit 2).
RESULT: NO_TESTS_EXECUTED EXIT 2
```

实际退出码：**2**；最终证据仍写出，`outcome=NO_TESTS_EXECUTED`。原文：`canonical/run-tests-empty-console.txt`。

### 5.4 与 lead 场景文件的注册兼容检查（未执行场景体）

用临时 ASCII probe dot-source `Harness.ps1`、`TestSupport.ps1` 和 `cases\*.tests.ps1`，只注册不运行：

```text
REGISTERED=29
HARNESS_ERRORS=0
DUPES=0
IDS=F08-01,...,F09-SUITE,F10-01,...,F07-01,...（完整列表见 integration-load-console.txt）
```

说明：29 项均来自 lead 并发加入的 `cases/*.tests.ps1`；Agent B 未调用 `Invoke-TestRun`，因此没有执行任何 F07-F10 场景体，没有接触真实系统。原文：`canonical/integration-load-console.txt`。

另用一个临时 fixture 验证了 `.GetNewClosure()` body 在 harness 内可执行（`PROBE-CLOSURE-01`，exit 0），与 lead 用例的循环注册方式兼容；原始输出：`canonical/closure-probe-console.txt`。

### 5.5 负控原始退出码

| 负控 | 实际退出码 | 关键 stdout |
|---|---|---|
| `-InjectCheckFailure META-01` | **1** | `[FAIL] META-01 ...`、`SELFTEST_FAIL EXIT 1` |
| `-Filter META-99` | **2** | `[NO-TESTS] ...`、`NO_TESTS_EXECUTED EXIT 2` |
| `-InjectHarnessError` | **3** | `[SELFTEST-HARNESS-ERROR] injected self-test harness exception...`、`HARNESS_ERROR EXIT 3` |
| 阻塞 `-OutDir` | **4** | `[EVIDENCE-ERROR] ...`、`EVIDENCE_ERROR EXIT 4` |

## 6. 如何运行

```powershell
# 自验（不会加载 cases/ 下的 F07-F10）
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File D:\claude防封\publish\proxy_v6\tests\self\SelfTest.ps1

# 运行场景（注意：当前会执行 lead 的 29 个 F07-F10 用例，需在获授权的隔离环境运行）
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File D:\claude防封\publish\proxy_v6\tests\Run-Tests.ps1

# 只跑某一组
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File D:\claude防封\publish\proxy_v6\tests\Run-Tests.ps1 -Filter 'F08-*'

# 指定证据输出
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File D:\claude防封\publish\proxy_v6\tests\Run-Tests.ps1 -OutFile D:\claude防封\publish\proxy_v6\evidence\v6\f08.json
```

场景文件接入约定（详见 `cases/README.md`）：只注册、不调用 `Invoke-TestRun`、不 `exit`；用 `New-TestTempRoot`/`Remove-TestTempRoot` 且在 `finally` 清理；生产 V4 代码不要在运行器进程内 dot-source，需在隔离子进程中经 `V4_TEST_MODE/V4_TEST_ROOT` 运行。lead 的 29 个用例已符合注册约定；是否通过由 lead 的运行结果决定。

## 7. 明确限制与未覆盖

1. **未执行 F07-F10 场景体**；只验证了 29 个测试能注册、0 重复/0 注册错误。产品行为正确性不在本交付结论内。
2. **未运行真实 apply/rollback/state**；未触碰 HKCU、系统代理、Clash 进程、appdata、注册表、网络、计划任务、用户凭据。未安装模块，未使用 Pester。
3. 自验的 `-InjectCheckFailure` / `-InjectHarnessError` 是测试专用负控开关，生产入口 `Run-Tests.ps1` 不暴露它们。
4. 一次进程只支持一次 `Invoke-TestRun`（注册表不清空）；这是有意的单次运行模型，父子进程隔离可避免污染。
5. `Run-Tests.ps1` 的 `-CasesDir` 不存在时按“零测试”处理（警告 + exit 2），不是框架异常 3；这是为了严格遵守“零执行不得判通过”的契约。
6. 通用秘密掩码不能替代生产日志脱敏测试；SEC-03 仍需独立场景。
7. 工作树是 dirty 的：并发代理修改了 `proxy_v4/**`，本交付新增 `proxy_v6/**`。HEAD 仍是 `36222c9`，未提交/未推送。
8. 自验证据中逐用例的 `evidenceFile` 指向 TEMP 路径；运行结束后 TEMP 被清理，持久副本在 `canonical/META-*/cases/` 下。正常 `Run-Tests` 的证据目录默认在 `proxy_v6/evidence/v6/`，不会随 TEMP 清理。

## 8. 证据索引

- `proxy_v6/evidence/selftest/canonical/selftest.json`：最终自验汇总（7/7，exit 0）
- `proxy_v6/evidence/selftest/canonical/console.txt`：最终自验原始 stdout
- `proxy_v6/evidence/selftest/canonical/commands.txt`：全部命令与观察退出码
- `proxy_v6/evidence/selftest/canonical/negative-exit1-console.txt` … `negative-exit4-console.txt`：负控原始输出
- `proxy_v6/evidence/selftest/negative-exit1/selftest.json`：负控 1 的结构化证据（6/1）
- `proxy_v6/evidence/selftest/negative-exit2/selftest.json`：负控 2 的结构化证据（0 检查）
- `proxy_v6/evidence/selftest/canonical/run-tests-empty-console.txt`：入口零测试 exit 2
- `proxy_v6/evidence/selftest/canonical/integration-load-console.txt`：29 项注册检查（未执行）
- `proxy_v6/evidence/selftest/canonical/closure-probe-console.txt`：`.GetNewClosure()` body 兼容性探针（exit 0）

## 9. 给 lead 的下一步

1. 在获授权的隔离环境中运行 `Run-Tests.ps1` 执行 lead 的 F07-F10 场景；先跑单组 `-Filter 'F08-*'` 降低风险。
2. 依据本报告第 2 节审查框架是否满足 RELEASE-GATE 第 8/9 项（退出码正确、无虚假通过/未声明跳过）。
3. 场景测试若需要 V4 内部函数，请在隔离子进程中使用 `V4_TEST_MODE/V4_TEST_ROOT`，不要在运行器进程内 dot-source `proxy_v4/lib/V4.ps1`（当前生产库加载即创建 config/backup）。
4. 不要用 META 7/7 代替 F07-F10 或真实环境验证；两者证据层级不同。
