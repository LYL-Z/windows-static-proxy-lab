# Portable recovery engine (F69/F70)

The recovery engine now ships **inside the application folder**, so an unpacked
release can diagnose and run isolated recovery without a source checkout.

## Layout

Both `ProxyDoctor` (WPF) and `proxy-doctor` (CLI) publish this fixed subtree:

```
engine\
  engine-manifest.json
  proxy_v4\rollback-v4.ps1
  proxy_v4\lib\V4.ps1
  scripts\Invoke-IsolatedRecovery.ps1
```

The `proxy_v4\` nesting is required: the hash-pinned wrapper loads
`Join-Path $EngineRoot 'proxy_v4\rollback-v4.ps1'`. The wrapper, `rollback-v4.ps1`
and `V4.ps1` are copied byte-for-byte from the reviewed sources; only the C#
locator changed.

## Whitelist

Exactly three files, each named individually in the csproj `Content` items
(`desktop/src/ProxyDoctor.Desktop/ProxyDoctor.Desktop.csproj`,
`desktop/src/ProxyDoctor.Cli/ProxyDoctor.Cli.csproj`). A folder is never copied.

| File | Reviewed SHA-256 source |
| --- | --- |
| `proxy_v4\rollback-v4.ps1` | `RecoveryTrust.RollbackSha256` |
| `proxy_v4\lib\V4.ps1` | `RecoveryTrust.LibrarySha256` |
| `scripts\Invoke-IsolatedRecovery.ps1` | `RecoveryTrust.ScriptSha256` (LF-normalised) |

Never packaged: `settings.json`, `owner.json`, `backup\`, `logs\`, `evidence\`,
or any credential or private configuration.

## Manifest

`desktop/packaging/engine-manifest.targets` generates `engine-manifest.json` from
the files that were just copied, so the manifest cannot describe a different
build than the one shipped:

```json
{"schemaVersion":1,"engineVersion":"v4.0","files":[{"path":"proxy_v4/rollback-v4.ps1","sha256":"..."}, ...]}
```

`engineVersion` must equal `EnginePackage.RequiredEngineVersion`; the two values
are kept in sync manually and a mismatch is a refusal.

## Resolution and refusal

`EnginePackage.Resolve()` (ProxyDoctor.Core\EnginePackage.cs):

1. Look at `AppContext.BaseDirectory\engine\` and verify the manifest plus every file.
2. In a **Release** build that is the only location. `AllowRepositorySearch` is a
   compile-time constant, so a published binary never walks up parent directories
   and a stray source checkout can never satisfy an installed app.
3. In a **Debug** build a source checkout above the binary may still be used.

Recovery is refused, with a readable message and no script started, when a file is
missing, a SHA-256 does not match the manifest, a file does not match the reviewed
hash compiled into the build, or `engineVersion` is incompatible. Trust requires
both the manifest hash and the reviewed hash to agree.

`--engine-check` inspects the engine folder and starts nothing; it exits `0` only
when the package validates.

## Authorization (F72)

The program never supplies its own authorization. Both surfaces require a grant that
is bound to the operation and to the target read at the moment of the request:

- `--recovery-brief` prints the canonical consent text (operation, target, scope,
  affected resources, system-proxy answer, rollback) as JSON plus `lines`.
- `--isolated-recovery` prints that same text to stderr and then reads one line from
  stdin. Only the exact phrase `RECOVER-ISOLATED <target>` (surrounding whitespace
  ignored) is a grant. A different target, different case, an extra word, an empty
  line or a one-key `--yes`/`-y`/`--always` flag is refused with
  `AuthorizationRefused=true`, `ScriptStarted=false` and exit `2`.
- The desktop window shows a modal dialog with the same fields; its confirm button
  creates the grant, and cancelling grants nothing. There is no default grant path:
  the view model refuses when no dialog host is wired.
- The grant is re-checked at execution time: if the target changed between the grant
  and the run, the run is refused instead of proceeding on a stale approval.

The Skill entry `skills/windows-proxy-doctor/recovery/Invoke-Recovery.ps1` shows the
same text, verifies the manifest plus the reviewed hashes, then runs
`engine\scripts\Invoke-IsolatedRecovery.ps1` and passes the result through
`skills/windows-proxy-doctor/scripts/RecoveryVerdict.ps1`. It implements no recovery
logic of its own.

## Not verified

- Starting the WPF window from a published folder.
- Real recovery writes to the live user proxy: `--isolated-recovery` still runs the
  fixed `V4_TEST_MODE` fixture under a temporary root, which writes no live state.
  A production write path is **not implemented**; every surface says so.
