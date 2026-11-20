# Security and authorization

## Default

The default guide and inventory read local state with current permissions. The snapshot reads the current user's Internet Settings, process and listener metadata, and the saved Clash Verge system-proxy setting. `-IncludeWriterEvidence` reads existing event logs. Reports omit raw event values, full executable paths and command lines. Active HTTPS or DNS probes are explicit. A checkpoint writes only to an explicitly selected local path. Backup protection and extraction also write files when invoked for that purpose. Stop foreground sampling with Ctrl+C.

## Production writes

Production changes to system proxy, WinHTTP, proxy client configs, routes, TUN, DNS, adapters, credentials or startup entries require separate, current authorization. The guide plans changes and records outcomes. An authorized operator uses native client controls or another user-approved implementation. A checkpoint or decision flag records workflow state and cannot authorize a change. Preserve firewall, Defender, SmartScreen and certificate protections.

## Installers and services

Use verified official sources. Check HTTPS through redirects, the expected publisher on a valid digital signature or the official SHA-256 for those exact bytes. Stop and review if provenance or integrity is uncertain. Ask for permission at the actual download or installation step. Users handle account registration, fees, identity verification and local credential entry. Neutral official entry points come first. Optional referral benefits and terms are disclosed before the user chooses a link. [Interaction details](references/user-interaction.md)

## Backups

- Protect-Backup.ps1 creates a DPAPI CurrentUser encrypted copy. Use a small, approved configuration snapshot and keep the output in a private local directory. The archive is built in memory and linked items are rejected. Plaintext originals and extracted files require restrictive ACLs and their own retention decision.
- Unprotect-Backup.ps1 verifies the encrypted and decrypted hashes before creating the requested plaintext file. Use a private output directory. An interrupted write can leave a partial output at that path.
- Keep the encrypted file and adjacent manifest together. The manifest holds hashes and scope, without the original source path. An interrupted write can leave an incomplete pair. Keep the last verified backup until the new pair has passed a private restore test.
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
