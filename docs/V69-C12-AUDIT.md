# C-12 current-tree audit

Date: 2026-11-25. Scope is the current `v69/isolated-privacy` tree. Git history was not rewritten, force-pushed, or deleted.

The scan printed counts and paths only. Matched values were not copied into this file.

| Class | Current tree | Handling |
| --- | --- | --- |
| Private key blocks | 0 files | None found |
| Long credential-like assignments | 5 files under `proxy_diag` | Replaced on this branch tip with a removal notice. History still contains the old blobs. Treat the proxy password as exposed and rotate it before any production use. |
| Password-like text in code, tests, and reviews | Several | Treated as synthetic or discussion text. Not reprinted. |
| Windows user-directory paths | 43 files in the content scan | Left in place. They are mostly historical notes. Removing them from history was not authorized. |
| Non-reserved public addresses | 40 files | Left in place. Many are historical observations. Not reprinted. |
| Mail-shaped strings | 6 files | Not reprinted. No private-key material was attached. |

Deleting a file on the branch tip is not the same as purging it from Git history. The old blobs remain reachable from older commits until a separately authorized history rewrite.

C-01 is a different change: new snapshots are DPAPI-sealed. That does not remove secrets already stored in Git.
