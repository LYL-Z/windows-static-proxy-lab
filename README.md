# Windows Static Proxy Lab — diagnostics, transactional config engine, evidence

Two-hop static proxy on Windows 11: an app-level chain (Clash Verge Rev / Mihomo `dialer-proxy`)
through a first-hop tunnel to a paid static SOCKS5 endpoint.

This repository is the **evidence and tooling** from a multi-round engineering effort, published so the
reasoning can be audited independently. It is **not** a "how to evade platform restrictions" guide.

## What is here

| Path | Contents |
|---|---|
| `proxy_diag/` | Round 1: staged protocol probes, 1×RTT "who closed the socket" test, control experiments, raw probe JSON |
| `proxy_v2/` | Round 2: transactional apply/rollback/status, 300-request acceptance run, benchmark + soak tools |
| `proxy_v3/` | Round 3: five-state machine, fault-injection bench, STUN/UDP egress probes, network matrix, IP due diligence |
| `proxy_v4/` | Round 4: JSON settings source (no YAML parsing), DPAPI credential, lock, verified process exit, ownership record, FT01–FT15 bench |

## Key technical findings

1. **The static endpoint refuses mainland-China source IPs at the session layer.** TCP handshake
   succeeds (~250 ms RTT), then the peer sends FIN roughly one RTT later without emitting a single
   protocol byte — for SOCKS5, HTTP CONNECT and TLS alike. From a US source IP the same credentials
   authenticate and CONNECT succeeds. Control probes prove the local path is fine.
2. **The static IP only carries TCP.** UDP/STUN exits via the first hop on every path tested, including
   through Clash's own UDP relay. This is why two reputation sites disagreed — they measured
   different protocols.
3. **System-proxy ownership is a three-way race** (Clash on start, tunnel client on start, scripts).
   The observed "wrong exit IP" incident was Clash not running while the tunnel client owned HKCU.
4. **A native-stderr + `$ErrorActionPreference='Stop'` interaction made an entire auto-rollback path
   unreachable** — found by an independent reviewer, not by the code's own tests.

## Honest status

`PASS` on config integrity, concurrency, fault injection (13/13), credential redaction.
`PENDING` on boot/sleep/Wi-Fi lifecycle, 24h/72h soak, and credential rotation.
Claude service eligibility is `NOT_READY`: Anthropic's Supported Regions Policy tests **physical
location of the person**, not IP address. A US IP is not an eligibility criterion.

## What is deliberately NOT in this repo

See `SECURITY-NOTES.md`. In short: no credentials, no config backups, no shell history.
## V6.9 用户需求与安全验收边界（研究记录）

[八项用户原始要求（逐字）与可验证工程验收矩阵](docs/V6.9-EIGHT-REQUIREMENTS.md) 已收录在独立文档中。此处是需求追踪，**不表示已经实现、不保证任何账号或地区使用资格**；通用网络隐私、安全和可靠性研究须经过隔离故障注入、真实应用验证与授权回滚。
