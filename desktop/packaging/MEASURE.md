# Packaging measurement

Worktree: `D:\claude防封\wt-k`  
Branch: `agent/k-package`  
Date: 2026-11-25

## Authenticode

There is no Authenticode signature. This packaging step does not sign `ProxyDoctor.exe` or any other file. `Get-AuthenticodeSignature` on the published `ProxyDoctor.exe` returned `NotSigned`. Check the publish with the SHA-256 below.

## Publish win-x64 self-contained

Publish the Desktop project to a separate folder. Do not write `D:\claude防封\outputs\2026-11-25-desktop\portable`.

From `D:\claude防封\wt-k\desktop`:

```powershell
dotnet publish .\src\ProxyDoctor.Desktop\ProxyDoctor.Desktop.csproj -c Release -r win-x64 --self-contained true -o "D:\claude防封\outputs\2026-11-25-desktop\wt-k-portable"
```

## This publish

- Output: `D:\claude防封\outputs\2026-11-25-desktop\wt-k-portable`
- File count: 468
- `ProxyDoctor.exe` SHA-256: `8D29733CC159AEAE9E26BB404606CD909D857AB86313AE0E88B02EDCB0168A09`
- Authenticode: none (`NotSigned`)
- Self-contained runtime files present: `hostfxr.dll`, `coreclr.dll`

## TEMP install and uninstall

- Command: `powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\Test-InstallProxyDoctor.ps1`
- Result: PASS
- The test runs under the user TEMP directory.
- Install writes `install-manifest.json` with a SHA-256 for each copied file.
- Uninstall deletes only those manifest files and refuses a file whose hash changed.
- A destination outside the allowed root is refused, including a path that escapes through `..` or a directory junction.
- The installer does not write startup entries or the system proxy. The test compared those locations before and after.

## Blockers

None.
