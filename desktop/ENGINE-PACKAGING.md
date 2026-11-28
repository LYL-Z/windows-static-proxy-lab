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
when the package validates. `--isolated-recovery` refuses (exit `2`,
`ScriptStarted=false`) on the same conditions.

## Not verified

- Starting the WPF window from a published folder.
- Real recovery writes to the live user proxy: `--isolated-recovery` still runs the
  fixed `V4_TEST_MODE` fixture under a temporary root, which writes no live state.
