# C-12 follow-up

Date: 2026-11-25. Scope is the current tip of each named branch. Git history was not rewritten, force-pushed, or deleted. Matched values, public addresses, and home-directory paths were not copied into this file. Value length was used only to separate a confirmed-looking password assignment from weaker hits.

`git grep -l` was limited to filenames. A long credential-key assignment means a `password`, `secret`, `token`, `uuid`, `private-key`, or `psk` field whose following text is at least 12 characters. Blob size and line length come from tree metadata.

## Tips checked

| Tip | Commit | Five-file result |
| --- | --- | --- |
| `main` | `2960db07f1571f69f59193ff3a60476a67c81354` | still-credential-like |
| `v69/isolated-privacy` | `fe8626db729ec1c5fde4df3ea16d4b57a17658f4` | removed-notice |
| `origin/v5/short-run-hardening` (PR #1 head) | `027107eefa41b0bc9aede7ac8743637778836060` | still-credential-like |
| `desktop/windows-proxy-doctor` | `ec92e36422f0cee8f732ada5ee641281ac970502` | removed-notice |
| `skill/recovery-verdict` | `ad88522d51e6bd1f5cf3b6673597d3bcf92e6f55` | still-credential-like |

PR #1 is open. Its head ref is `v5/short-run-hardening` at `027107e`, the same commit as `origin/v5/short-run-hardening`.

Local `main` and `origin/main` (`434a1ad61ab1a7f856252fdca66ea98c5998809d`) are different commits. Both still point at the same five pre-removal diag blobs.

## Five files

`v69/isolated-privacy` already contains `52df351`, which replaced these paths with removal notices. `desktop/windows-proxy-doctor` contains that same commit, so its tip has the same notice blobs: one 198-byte blob for the three yaml names, and one 205-byte blob for the two scripts. Those notices are 4 or 5 lines, with a maximum line length of 57, and the long-assignment search returns no hits.

`main`, `origin/v5/short-run-hardening`, and `skill/recovery-verdict` do not contain `52df351`. Their five paths are the pre-removal blobs, identical to the parent of `52df351`. The long-assignment search hits all five paths there. `skill/recovery-verdict` is timestamped after the removal commit, but that commit is not an ancestor.

| Path | `main` | `v69/isolated-privacy` | `origin/v5/short-run-hardening` | `desktop/windows-proxy-doctor` | `skill/recovery-verdict` |
| --- | --- | --- | --- | --- | --- |
| `proxy_diag/US-Static-fixed.yaml` | still-credential-like | removed-notice | still-credential-like | removed-notice | still-credential-like |
| `proxy_diag/clash-verge.WORKING.yaml` | still-credential-like | removed-notice | still-credential-like | removed-notice | still-credential-like |
| `proxy_diag/profile.WORKING.yaml` | still-credential-like | removed-notice | still-credential-like | removed-notice | still-credential-like |
| `proxy_diag/apply-chain.ps1` | still-credential-like | removed-notice | still-credential-like | removed-notice | still-credential-like |
| `proxy_diag/mihomo_api.ps1` | still-credential-like | removed-notice | still-credential-like | removed-notice | still-credential-like |

On the three still-credential-like tips, the three yaml files carry a password assignment of length 20 with no whitespace and no placeholder marker. That is the confirmed-looking hit. The two scripts match the long-assignment screen as well, but their hits are a length-15 secret assignment that contains a placeholder marker, plus a symbol-heavy password hit with a single alphanumeric character. The length-15 assignment also remains in library source on the cleaned tips, so those two scripts are suspected rather than confirmed.

## Category counts

Counts are files at each tip. Private-key blocks: 0. Common cloud token prefixes: 0.

| Category | `main` | `v69/isolated-privacy` | `origin/v5/short-run-hardening` | `desktop/windows-proxy-doctor` | `skill/recovery-verdict` |
| --- | --- | --- | --- | --- | --- |
| Confirmed-looking credentials | 3 | 0 | 3 | 0 | 3 |
| Suspected | 8 | 9 | 11 | 9 | 8 |
| Personal paths | 2 | 45 | 46 | 45 | 2 |
| Unnecessary public addresses | 34 | 36 | 40 | 37 | 34 |
| Synthetic tests | 1 | 4 | 1 | 4 | 1 |
| Technical parameters | 24 | 36 | 28 | 39 | 30 |

Confirmed-looking credentials, path only. Present on `main`, `origin/main`, `origin/v5/short-run-hardening`, and `skill/recovery-verdict`. Absent from the `v69/isolated-privacy` and `desktop/windows-proxy-doctor` tips:

- `proxy_diag/US-Static-fixed.yaml`
- `proxy_diag/clash-verge.WORKING.yaml`
- `proxy_diag/profile.WORKING.yaml`

Suspected paths are long credential-key hits that did not meet the confirmed-looking bar. They include placeholder-like assignments, review prose, and library code. Values were not copied.

- `proxy_diag/apply-chain.ps1`
- `proxy_diag/mihomo_api.ps1`
- `proxy_v2/SECURITY.md`
- `proxy_v2/apply-v2.ps1`
- `proxy_v2/lib/Common.ps1`
- `proxy_v3/lib/Common.ps1`
- `proxy_v4/SECURITY-AUDIT-V4.md`
- `proxy_v4/lib/V4.ps1`
- `proxy_v6/reviews/AGENT-C-SECURITY-REVIEW.md`
- `proxy_v6/reviews/AGENT-D-CODE-REVIEW.md`
- `proxy_v6/reviews/ROUND2-SECURITY-REVIEW.md`

Not every suspected path exists on every tip. The table counts the files that do.

Personal paths are files that contain a Windows user-profile path or a POSIX home path. Split: Windows profile files are 2, 42, 43, 42, and 2; extra POSIX home files are 0, 3, 3, 3, and 0. The paths themselves are not listed.

Unnecessary public addresses are files that contain at least one non-reserved public IPv4 address. Loopback, private, link-local, shared CGNAT, multicast, reserved, and documentation ranges were excluded. Distinct addresses, counted and discarded, were 18, 19, 19, 19, and 18. Four of the five pre-removal diag files contribute to this count on the dirty tips. `proxy_diag/mihomo_api.ps1` does not. None of the five notice files do. Addresses are not listed.

Synthetic tests are long credential-key hits under test or repro paths, treated as fixtures:

- `main` and `skill/recovery-verdict`: `proxy_v4/tests/faultinject-v4.ps1`
- `origin/v5/short-run-hardening`: `proxy_v6/tests/cases/fixtures/Run-InfraCase.ps1`
- `v69/isolated-privacy` and `desktop/windows-proxy-doctor`: `proxy_v6/tests/cases/fixtures/Run-InfraCase.ps1`, `proxy_v6/tests/repro/V69Lifecycle.ps1`, `proxy_v6/tests/repro/V69Protocols.py`, `proxy_v6/tests/repro/V69SnapshotSeal.ps1`

Technical parameters are files with protocol knobs such as port, cipher, SNI, or TLS settings. Those knobs are not counted as credentials, and the setting values were not copied.

## History plan without a rewrite

Replacing a file on a branch tip does not delete the old blob. The pre-removal diag objects remain reachable from `main`, `origin/main`, `origin/v5/short-run-hardening`, `skill/recovery-verdict`, and from the parent of `52df351` on the privacy and desktop history. Checking out `v69/isolated-privacy` or `desktop/windows-proxy-doctor` does not purge those objects. A fresh clone of a branch that still points at them still receives them.

If the diag files were real, treat the proxy password as exposed and rotate it at the provider before production use. Rotation is a provider-side action. A later history purge would not change the live credential. The old objects are already reachable from origin branches, so assume they have been distributed.

Containment that does not rewrite history:

- Do not force-push, filter the repository, or delete remote branches for this follow-up.
- Do not merge `main`, `v5/short-run-hardening`, or `skill/recovery-verdict` in a way that restores the five pre-removal blobs.
- Further commits on those dirty tips should replace the five paths with the existing notice blobs before more publication.
- A separately authorized history purge can be planned later. It is not part of this change.
- DPAPI sealing of new snapshots does not remove objects already stored in Git.

## Blockers

- Local `main` (`2960db0`) and `origin/main` (`434a1ad`) differ. The five-file classification is the same on both.
- PR #1 remains open at `027107e`, which still has the five pre-removal files.
- `skill/recovery-verdict` (`ad88522`) is newer than the removal commit and does not contain it.
- This pass cannot tell whether the confirmed-looking password was a live provider credential or a lab value. Rotation is the safe assumption if it was real.
- Sibling agent branches were not modified and were not part of the five-file classification.
