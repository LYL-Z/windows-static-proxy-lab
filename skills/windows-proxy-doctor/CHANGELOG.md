# Changelog

## 2.1.0 RC3

- Adds `recovery/Invoke-Recovery.ps1`, the only Skill-side recovery entry. It verifies the packaged engine manifest and the reviewed SHA-256 values, shows the shared consent text, runs the packaged `engine\scripts\Invoke-IsolatedRecovery.ps1`, and passes the result through `scripts/RecoveryVerdict.ps1`. It implements no recovery logic of its own.
- Requires an operation-bound phrase (`RECOVER-ISOLATED <target>`) typed by the person. A wrong target, different case, extra word, empty value or `--yes` is a refusal that starts nothing; read-only diagnosis stays available.
- Rewrites `SKILL.md` into three stages with what each one actually does: read-only diagnosis, isolated rehearsal, and real operations that need authorization.
- States in the UI, the CLI and the Skill that the production write is not implemented: the executor is still `V4_TEST_MODE` + stub.
- Adds `tests/Run-RecoveryTests.ps1` (refusal, tampered engine, real isolated rehearsal, reviewed-hash sync with `ProxyDoctor.RecoveryTrust`, and the three-stage documentation).

## 2.0.0 RC2

- Resumes saved setup on explicit Auto and keeps a temporary diagnostic check from replacing the setup goal. Reports the particular client still unconfirmed after each installation.
- Keeps the current workflow usable if Windows declines atomic checkpoint replacement and reports unsaved progress explicitly.
- Separates local diagnosis completion, HTTPS results, actual application observations, configuration or rollback acceptance, and lifecycle results. Unknown or ambiguous loopback routing remains open for verification.
- Adds regressions for staged installation, cross-process resumption, earlier lowercase checkpoints, mixed IPv4/IPv6 mappings, and conflicting evidence.
- Updates installation and recurring first-hop interruption guidance and documents the remaining release gates.

## 2.0.0 Release Candidate

- Adds foreground Windows environment discovery, an onboarding and diagnosis entry point, and human handoff for steps that require user involvement.
- Adds optional restartable checkpoints with fresh discovery on resume and explicit path verification.
- Adds beginner, troubleshooting, service disclosure and lifecycle references, along with reusable user action and evidence templates.
- Builds DPAPI backup archives in memory, rejects linked sources and preserves existing outputs and manifests.
- Retains the 1.6.1 snapshot, watcher, consistency and transport diagnostics. Cross-device installation and complete network lifecycle acceptance are pending.

## 1.6.1

- Brackets each registry read so candidate writer events can be selected from the previous read start through the current read end.

## 1.6.0

- Adds bounded, read-only foreground lifecycle monitoring and optional HTTPS checks, with separate local readiness and endpoint evidence.

## 1.5.0

- Adds opt-in existing registry event queries, PAC and process observations, and backup hash verification before decrypted output.
