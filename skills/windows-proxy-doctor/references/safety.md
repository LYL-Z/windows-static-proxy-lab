# Safety, authorization, and publication rules

## Authorization

- Default read-only.
- Separate authorization is required for system proxy, WinHTTP, routes, TUN,
  DNS, adapters, firewall, Defender, certificates, proxy client configs,
  credentials, and startup entries.
- A user authorization to deploy does not authorize unrelated changes.

## Backup and rollback

- Take a backup before a change; hash it; verify the copy.
- Keep the only valid backup; never delete it to clean up.
- Test restore/rollback where authorized; a hash-verified copy is not a restore test.
- On failure, restore the previous usable network first, then diagnose.

## Test isolation

- Use temporary roots and synthetic fixtures.
- Never read/write real HKCU, WinHTTP, credentials, or network in tests.
- A test that writes must be gated by an explicit flag and a separate test root.
- Zero executed tests / zero assertions must fail, not pass.

## Credentials and public material

- No passwords/tokens in argv, shell history, logs, examples, or public files.
- Use DPAPI or a protected credential store; document the residual exposure.
- Public material: redact public IPs, private paths, usernames, device IDs,
  account identifiers, and credentials. Use RFC 5737 documentation addresses
  (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and localhost.
- Do not rewrite Git history without explicit owner authorization.

## Prohibited scope

- Platform-account evasion, identity spoofing, CAPTCHA optimization, or
  region/account restriction bypass.
- Disabling firewall, Defender, or certificate validation.
- Using a third-party IP score as an account-safety guarantee.

## Reporting

State what was measured, when, from which layer, and what was not tested.
Report UNKNOWN when evidence is missing. Keep automated test results separate
from production deployment and user acceptance.
