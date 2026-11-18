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

## V6 additions (2026-11-18)

- `-Init` no longer accepts a password on the command line. Explicit migration uses `-CredentialFile <path>` (ACL-hardened); the old `-StaticPass`/`-StaticPassFile` spellings are rejected with a removal message. Prefer migrating from the current Clash profile. Never pass the password in argv or shell history.
- Snapshot/backup directories contain plaintext proxy credentials by design (needed for restore). Their ACL is now hardened before copying, but they are **not encrypted**. Do not upload `backup/` to cloud drives, tickets, or chats.
- `Get-V4Settings` now refuses a config/settings ACL that is not hardened (code 12); re-run `-Init` under the lock to repair.
- Repository/scripts/evidence ACLs were hardened against local `Authenticated Users` modification (see `proxy_v6/evidence/v6/repo-acl.json`).
- F11: a lead test probe wrote `ProxyServer=x` to real HKCU on 2026-11-18. Root cause, recovery and regression tests are in `proxy_v6/INCIDENT-2026-11-18.md` and `proxy_v6/ISSUE-LEDGER.md`.
