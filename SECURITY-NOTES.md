# What was removed before publication

The working tree contained live secrets. They were **excluded, not merely ignored**, before the first commit:

| Removed | Why |
|---|---|
| `*/backup/**` (all snapshots) | Each snapshot contains generated Clash YAML with the proxy password in plaintext |
| `proxy_v4/config/settings.json` | Holds the DPAPI-encrypted password plus the account username |
| `proxy_v3/evidence/ConsoleHost_history.backup-*.txt` | 238 KB copy of the operator's PowerShell history (personal data, and it had contained the password) |
| `*.bak`, `*.lock`, `*.log` run artifacts | Transient; logs embed local paths |

Three remaining files still matched the account identifiers; those occurrences were replaced with
`<REDACTED>` and the tree was rescanned until **0** files matched the password or the username.

## Residual considerations

- Scripts reference absolute paths (`D:\claude防封\...`) and a Windows 11 host; they are published as-run.
- The static endpoint IP and first-hop exit IP appear in reports and evidence. They are network facts,
  not secrets — but they do describe one specific rented endpoint.
- Commit identity uses a GitHub noreply address, not a personal mail.

## If you reuse this

Rebuild `config/settings.json` yourself (`apply-v4.ps1 -Init`), set your own endpoint, and rotate any
credential that was ever written to disk in plaintext. Treat every snapshot directory as secret.