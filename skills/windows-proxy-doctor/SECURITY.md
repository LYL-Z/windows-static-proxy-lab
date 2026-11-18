# Security and authorization

## Default

All scripts are read-only unless a script explicitly requires -Apply. The default snapshot reads HKCU, WinHTTP, process/listener metadata, and the Clash Verge UI setting. It does not print passwords, DPAPI blobs, cookies, tokens, or full command lines.

## Production writes

Any change to system proxy, WinHTTP, proxy client configs, routes, TUN, DNS, adapters, firewall, Defender, certificates, credentials, or startup entries requires separate explicit user authorization. The Skill must not perform such writes autonomously.

## Backups

- Protect-Backup.ps1 creates a DPAPI CurrentUser encrypted copy; it does not delete plaintext originals and does not claim plaintext is gone.
- Unprotect-Backup.ps1 refuses to overwrite existing output.
- Verify the SHA-256 of the zip before and after encryption/decryption.
- Never delete the only valid backup.

## Test isolation

- Tests must use synthetic fixtures and a temporary root.
- Tests must not read or write real HKCU, WinHTTP, network adapters, proxy client configs, or credentials.
- A passing isolated test is not evidence of production deployment.

## Credentials and publication

- Do not pass secrets in argv, shell history, logs, examples, or public files.
- Redact public IPs, private paths, usernames, device IDs, and credentials in public material.
- Do not rewrite Git history without the repository owner's explicit authorization.
- Do not include platform-account evasion, identity spoofing, CAPTCHA optimization, or region/account restriction bypass.

## Known residual risks

- UI and OS state can change between reads; capture time and evidence.
- A proxy listener can be alive while the upstream path is down.
- TCP and UDP/WebRTC can legitimately use different paths.
- DPAPI encryption protects at rest for the same Windows user; it does not protect against a compromised user session.
