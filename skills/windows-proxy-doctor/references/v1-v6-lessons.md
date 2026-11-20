# V1-V6 engineering lessons

This is a distilled, sanitized record of what worked, what failed, and which
assumptions were corrected. It is not a claim that every experiment succeeded.

## Timeline

| Phase | What was built | What failed / was corrected |
|---|---|---|
| V1 | Windows system proxy + WinINet refresh + static proxy first hop | Assumed the OS proxy was the whole path; DNS/UDP/application layers were not separated. |
| V2/V3 | Clash/Mihomo profile and runtime generation; subscription/profile switching | Stale profile markers, overwrite by the client, and UI/OS state drift. |
| V4 | Transactional apply/rollback: lock, snapshot, hash manifest, ACL, DPAPI, journal | Early snapshot/hash checks accepted empty or partial manifests; rollback restarted the client without holding the lock; restored files were not re-hardened. |
| V5 | Short-run hardening and independent review | Some findings were documentation-only or non-falsifiable; a report could be mistaken for a production test. |
| V6 | F07-F12, fault injection, test isolation, F11 incident, production deployment | A lead-owned ad-hoc probe wrote real HKCU because the registry guard was not wired; UI status and actual HKCU diverged; a rollback to proxy-off was overwritten when the client restarted. |

## Failure catalogue

### 1. Test mode is not isolation by itself
- A temporary probe set V4_TEST_MODE and called the system-proxy function.
- At that moment the function had no production-write assertion; it wrote
  HKCU ProxyEnable=1 / ProxyServer=x and temporarily broke browser networking.
- Correction: production-write latch; explicit test registry writer; safe
  no-ops for start/stop in test mode; FT-style fault injection; no ad-hoc probes.

### 2. UI is not the OS
- Clash Verge can keep enable_system_proxy=true while HKCU is off.
- The browser then bypasses Clash; traffic statistics look idle and the IP
  information page shows the direct/StarSky exit.
- Correction: report UI and actual HKCU separately; mismatch is DEGRADED, not
  HEALTHY. Never infer the path from a client toggle or a node latency test.

### 3. A listener is not an upstream path
- A mixed port can listen while the first hop is down, DNS is broken, or the
  upstream credential is rejected.
- TCP and UDP/WebRTC can legitimately take different paths.
- Correction: probe layers separately; a green third-party page is not proof.

### 4. Backups need integrity and a restore test
- Empty/partial manifests, path traversal, hash mismatch, and non-hardened
  restored files were found and fixed.
- A backup that has never been restored is a hypothesis, not a backup.
- Correction: hash-verified manifest, coverage check, ACL re-hardening, and a
  real rollback test where authorized.

### 5. Rollback can be undone by the client
- After restoring a proxy-off snapshot, starting the client reasserted its
  saved system-proxy=on state.
- Correction: after restart, restore the snapshot's proxy state, verify it,
  and fail closed if it cannot be held.

### 6. Credentials must not enter argv
- An explicit password parameter put the secret in the process command line
  and shell history.
- Correction: protected credential file, ACL check, no command-line password,
  and explicit rejection of old spellings. Legacy command-line passwords are
  still visible in history if a user types them; the tool refuses them.

### 7. Isolation tests are not production deployment
- 97/97 isolated tests passed while the real runtime directory was still the
  old baseline.
- Correction: separate CODE_SAFETY, TEST_ISOLATION, CONFIG_INTEGRITY,
  PRODUCTION_DEPLOYMENT, CURRENT_NETWORK_STATE, USER_ACCEPTANCE and
  SERVICE_ELIGIBILITY gates. Deploy and verify separately.

### 8. Do not delete the only valid backup
- Encryption and cleanup must not destroy the restore path.
- Keep a verified plaintext copy until an encrypted restore path is proven, or
  keep both and disclose the residual plaintext risk.

## Reusable rules

1. Record before/after facts; never trust a single status source.
2. Separate UI, OS proxy, listener, first hop, DNS, TCP, UDP and exit path.
3. Default read-only; any production write needs explicit authorization.
4. A test fixture must never read real HKCU, WinHTTP, credentials or network.
5. A report is not a deployment; a deployment is not user acceptance.
6. A static IP or a third-party score is not account/service eligibility.
7. Fail closed on unknown state; do not invent HEALTHY.
8. Do not optimize for a green third-party score at the cost of real usability.
