# Security and authorization

## Default

The default snapshot reads the current user's Internet Settings, process and listener metadata, and the saved Clash Verge system-proxy setting. `-IncludeWriterEvidence` reads existing event logs with the current shell's permissions. Output excludes raw registry values from events, full executable paths, and command lines. There is no extension, service, or driver to install with the Skill. `Test-NetworkPath.ps1` sends active HTTP(S) or DNS probes when requested. Backup protection and extraction write output files when explicitly invoked.

## Production writes

Any change to system proxy, WinHTTP, proxy client configs, routes, TUN, DNS, adapters, firewall, Defender, certificates, credentials, or startup entries requires separate explicit user authorization. The Skill must not perform such writes autonomously.

## Backups

- Protect-Backup.ps1 creates a DPAPI CurrentUser encrypted copy. Plaintext originals and extracted files require restrictive ACLs, local storage, and a separate retention decision.
- Unprotect-Backup.ps1 verifies the encrypted and decrypted hashes before creating the requested plaintext file. Use a private output directory. An interrupted write can leave a partial output at that path.
- Protect-Backup.ps1 still creates a temporary plaintext ZIP during encryption. Normal cleanup removes it. If protection is interrupted, check the private Windows temporary directory for the residual `wpdoctor-*.zip` and verify the correct copy before any cleanup.
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
- Verify recovery under the original Windows user on the same machine. The Skill package is portable. Treat its DPAPI recovery payload as tied to the originating Windows profile and machine.
