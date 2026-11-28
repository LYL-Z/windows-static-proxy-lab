# CAB count note

`docs/CAB-INTEGRATION.md` lists 15 independent cross-process recovery cases. GitHub PR #7, checked at `f2454c05f1bd3bca9cefc8b2a8e40889d71bddf0`, lists 19 preparation-transaction assertions. `HANDOFF.md` describes the preparation journal and gives it no count. These are two inventories. This note keeps each one intact and does not combine them.

The Engine 114-case harness and the Skill basic suite are further inventories. The Skill basic suite is the 15 `Check` calls in `skills/windows-proxy-doctor/tests/Run-Tests.ps1`.

## 15 cross-process recoveries

Source: the `results` rows built by `run` in `proxy_v6/tests/repro/V69Recovery.py`. The runner prints `passed <number> / <len(results)>`. That list has 15 rows. Each row is one fresh Windows PowerShell 5.1 process, or one grouped result from such processes, against a file-backed selection.

`proxy_v6/tests/repro/V69RecoveryFixture.ps1` is appended only to the temporary copy of `proxy_v4/lib/V4.ps1` used by that driver.

1. `user-off`
2. `user-other-target`
3. `unknown-image`
4. `already-correct`
5. `ambiguous-probe`
6. `eligible-drift`
7. `post-exit-mismatch`
8. `partial-setter`
9. `external-disable`
10. `rollback-error`
11. `interrupted-on-RestorePrevious`
12. `interrupted-on-KeepCurrent`
13. `interrupted-user-off-RestorePrevious`
14. `competing-process`
15. `provider-evidence`

Rows 1–10 and row 14 each call `apply-v4.ps1 -Repair` once. Rows 11–13 each drive a crashed repair, a guarded apply, a guarded rollback, a state read, and a resolve; each of those groups is still one row. Row 15 is the process exit of `proxy_v6/tests/repro/V69RecoveryReaders.ps1` (malformed enable values, a missing core image, and a competing listener owner). The checks inside that reader script stay inside this one row.

## 19 preparation-transaction assertions

Source: the `Check` labels in `proxy_v6/tests/repro/V69PreparationCrash.ps1`, in source order. PR #7 is describing this file. The assertions reproduce an older engine that stops the isolated listener before a journal exists, then cover resume, a user-off selection, and a changed proxy target on the candidate.

1. `fixture client initially listens`
2. `baseline stops the real isolated listener before a journal exists`
3. `fixture listener restarted for candidate tests`
4. `unprotected journal directory prevents stopping the listener`
5. `candidate stops real isolated listener and retains durable journal after process exit`
6. `retained journal distinguishes snapshot preparation from completed backup`
7. `independent state detects interrupted preparation`
8. `ordinary apply refuses pending preparation`
9. `ordinary rollback refuses rather than restoring a different snapshot`
10. `user-off is preserved with no restart`
11. `new proxy selection is preserved with no restart`
12. `refusals leave the pre-stop record unchanged`
13. `interrupted resume retains preparation after client starts`
14. `resumed resolution verifies the real listener and does not start twice`
15. `second interruption leaves pending preparation`
16. `explicit KeepCurrent retires preparation without launching`
17. `preparation-only handling preserved the configuration file bytes`
18. `completed snapshot is verified while preparation is still pending`
19. `snapshot journal promotion preserves the existing rollback format`

Labels 2 and 3 run when `-LegacyRoot` is passed. A run without that switch executes the other 17 labels. The 19 in PR #7 is the full list above, including that legacy pair.

## Outside both lists

`proxy_v6/tests/repro/CAB-CorruptPreparationJournal.ps1` plants one parseable `apply-preparation` journal with `wasAligned` true and `wasRunning` false. `Get-V4Journal` marks that record corrupt and still preparation. The script is one synthetic check beside the 15 rows and beside the 19 labels. Rollback `-ResolvePreparation ResumeClient` and `apply-v4.ps1 -DryRun` both exit 34, the journal bytes stay, and no client start is recorded. `proxy_v4/lib/V4.ps1` already contains that refusal.
