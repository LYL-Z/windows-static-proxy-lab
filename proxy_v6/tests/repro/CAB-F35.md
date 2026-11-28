# F35 — the 15 and the 19 are different lists

`docs/CAB-INTEGRATION.md` counts 15 independent cross-process recovery cases. GitHub PR #7 (the CAB integration draft) counts 19 preparation-transaction assertions. `HANDOFF.md` describes the preparation behavior and does not use the number 19. These are two inventories. They are not added together, and neither number is the Engine 114-case suite.

## 15 cross-process recovery cases

Source: the `results` rows built by `run` in `proxy_v6/tests/repro/V69Recovery.py`. Each row is one fresh Windows PowerShell process against a file-backed selection. The fixture appended only to that temporary library copy is `proxy_v6/tests/repro/V69RecoveryFixture.ps1`. The runner prints `passed N / 15`.

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

`provider-evidence` is one row. It is the process exit of `proxy_v6/tests/repro/V69RecoveryReaders.ps1` (malformed enable values, a missing core image, and a competing listener owner). Those reader checks are not 15 extra cases. Rows 11–13 each drive more than one process, and each row is still one case.

## 19 preparation-transaction assertions

Source: the `Check` labels in `proxy_v6/tests/repro/V69PreparationCrash.ps1`, in source order. PR #7 is describing this file: the assertions reproduce an older engine that stops the isolated listener before a journal exists, then cover resume, user-off, and a changed proxy target on the candidate.

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

Assertions 2 and 3 run only when `-LegacyRoot` is passed. A run without that switch executes the other 17 labels. The PR’s 19 is the full list above, including that legacy pair.

## Outside both lists

Partial restore of a locked snapshot file, and refusal of a reparse point on a snapshot directory, are already in `proxy_v6/tests/repro/V69SnapshotHardening.ps1`. Resolve-time user-off is assertion 10 above. None of those is repeated here.

What neither list plants is a preparation journal that parses, carries `reason=apply-preparation`, and fails the engine rule that `wasAligned` cannot be true when `wasRunning` is false. `Get-V4Journal` marks that record corrupt and still preparation. `CAB-CorruptPreparationJournal.ps1` is that one synthetic check. Windows PowerShell 5.1 ran it in an isolated TEMP root: `ResumeClient` and `apply -DryRun` both exited 34, the journal bytes stayed in place, and no client start was recorded. It is not an addition to 15 or to 19, and it is not a rerun of the 114-case suite.

`state-v4.ps1` still selects `REVIEW_INTERRUPTED_PREPARATION` from the preparation flag alone, including when `corrupt` is true. Rollback then refuses `ResumeClient`. That state script was left unchanged because this pass only adds the note and the synthetic check.
