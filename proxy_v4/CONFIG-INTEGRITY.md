# CONFIG-INTEGRITY

## 模型

- **唯一真源**：`config\settings.json`（JSON；密码为 DPAPI 密文）。
- **生成物**：`profiles\v4-managed.yaml`（带 marker 注释）与 `clash-verge.yaml`（运行时）。
- **不解析 YAML**：V4 不再把手写正则当作配置读取器。

## 不变量

1. 任何写入前，内容必须先通过 `mihomo -t`。
2. 替换使用"临时文件 → 校验 → 重命名"，备份名为 per-run 唯一，成功后删除。
3. 快照在任何修改**之前**创建，且创建前应用必须已停止。
4. 还原前逐文件校验 SHA256；缺失或不匹配即拒绝。
5. 生成物首位必须是 `# proxy_v4 managed`；丢失即视为被订阅/应用覆盖（state 报 DEGRADED）。

## 已知边界

- Clash Verge 会用当前 profile 重新生成 `clash-verge.yaml`，因此运行时的 marker 会消失；state 改用**链路签名**（`dialer-proxy: "STAR-FIRSTHOP"`）判定。
- `profiles.yaml` 的注入是本项目唯一仍以文本方式修改的 YAML（结构极简、单行 `current:` + 一个 item 块），并受 `mihomo -t` 之外的应用启动验证兜底。