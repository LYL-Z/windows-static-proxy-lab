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
| `proxy_v4/` | Round 4: JSON settings source (no YAML parsing), DPAPI credential, lock, verified process exit, ownership record |
| `proxy_v6/` | V6: independent takeover, transaction recovery, lock ownership, transaction journal, 92 isolated tests, security review, F11 incident record |

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

V6 (commits d5f2134 / evidence b9bb9a0): 92/92 isolated tests, 7/7 harness self-tests, Gitleaks 0 findings.
`PENDING` on real production apply/rollback/boot/sleep/Wi-Fi, 24h/72h soak, and credential rotation.
**F11 incident:** a lead test probe wrote `ProxyServer=x` to the real HKCU during V6 work and briefly broke browser networking on 2026-11-18. It is recorded in `proxy_v6/INCIDENT-2026-11-18.md`; the production-write latch and FT16–FT21 regression tests are in place.
Claude service eligibility is `NOT_READY`: Anthropic's Supported Regions Policy tests **physical
location of the person**, not IP address. A US IP is not an eligibility criterion.

## What is deliberately NOT in this repo

See `SECURITY-NOTES.md`. In short: no credentials, no config backups, no shell history.