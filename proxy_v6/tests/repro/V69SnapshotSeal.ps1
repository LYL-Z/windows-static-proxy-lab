#Requires -Version 5.1
<#
  Synthetic DPAPI snapshot seal. Does not read production snapshots or live credentials.
#>
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ('v69seal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$env:V4_TEST_MODE = '1'
$env:V4_TEST_ROOT = $root
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $repo 'proxy_v4\lib\V4.ps1')
$failed = New-Object System.Collections.Generic.List[string]
function Check([string]$Name, [bool]$Condition) {
    if ($Condition) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name"; $script:failed.Add($Name) }
}
$secret = 'SYNTHETIC-C01-SECRET-7f3a9c'
$app = Join-Path $root 'app'
New-Item -ItemType Directory -Path (Join-Path $app 'profiles') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $app 'profiles.yaml'), ("marker: " + $secret + "`n"))
$snap = Join-Path $root 'snap'
$null = New-V4SnapshotFiles -AppData $app -ProfilesDir (Join-Path $app 'profiles') -Dir $snap -SystemProxy $null -ClashRunningBefore $false -Reason 'seal'
$raw = [IO.File]::ReadAllText((Join-Path $snap 'profiles.yaml'))
$manifest = Get-Content (Join-Path $snap 'manifest.json') -Raw -Encoding UTF8
Check 'ciphertext hides the synthetic secret' ((-not $raw.Contains($secret)) -and (-not $manifest.Contains($secret)))
Check 'manifest is schema 3' ($manifest.Contains('"schema":  3') -or $manifest.Contains('"schema": 3'))
[IO.File]::WriteAllText((Join-Path $app 'profiles.yaml'), "changed`n")
$restored = Restore-V4Files -SnapshotDir $snap -AppData $app -ProfilesDir (Join-Path $app 'profiles')
$after = [IO.File]::ReadAllText((Join-Path $app 'profiles.yaml'))
Check 'restore returns the synthetic secret' ($restored.ok -and $after.Contains($secret))
$live = [IO.File]::ReadAllText((Join-Path $app 'profiles.yaml'))
$bytes = [IO.File]::ReadAllBytes((Join-Path $snap 'profiles.yaml'))
$bytes[$bytes.Length - 1] = [byte](($bytes[$bytes.Length - 1] + 1) % 255)
[IO.File]::WriteAllBytes((Join-Path $snap 'profiles.yaml'), $bytes)
$threw = $false
try { Test-V4SnapshotManifest -SnapshotDir $snap | Out-Null } catch { $threw = $true }
Check 'corrupt ciphertext is refused' $threw
Check 'corrupt snapshot did not rewrite the live file' (([IO.File]::ReadAllText((Join-Path $app 'profiles.yaml'))) -eq $live)

$legacyDir = Join-Path $root 'legacy'
New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
$plain = [Text.Encoding]::UTF8.GetBytes("legacy-plain`n")
[IO.File]::WriteAllBytes((Join-Path $legacyDir 'profiles.yaml'), $plain)
$hash = (Get-FileHash (Join-Path $legacyDir 'profiles.yaml') -Algorithm SHA256).Hash
$legacy = @{
    schema = 2
    createdAt = (Get-Date).ToString('s')
    reason = 'legacy'
    files = @(@{ name = 'profiles.yaml'; sha256 = $hash })
    absent = @('clash-verge.yaml','config.yaml','verge.yaml','profiles\v4-managed.yaml')
} | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path $legacyDir 'manifest.json'), $legacy)
[IO.File]::WriteAllText((Join-Path $app 'profiles.yaml'), "before-legacy`n")
$legacyRestore = Restore-V4Files -SnapshotDir $legacyDir -AppData $app -ProfilesDir (Join-Path $app 'profiles')
Check 'legacy plaintext snapshot still restores' ($legacyRestore.ok -and ([IO.File]::ReadAllText((Join-Path $app 'profiles.yaml'))) -eq "legacy-plain`n")

$old = Join-Path $root 'backup\old'
New-Item -ItemType Directory -Path $old -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $old 'manifest.json'), (@{ createdAt = (Get-Date).AddDays(-30).ToString('s'); files = @() } | ConvertTo-Json))
$kept = Join-Path $root 'backup\new'
New-Item -ItemType Directory -Path $kept -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $kept 'manifest.json'), (@{ createdAt = (Get-Date).ToString('s'); files = @() } | ConvertTo-Json))
$removed = @(Remove-V4ExpiredSnapshots -BackupRoot (Join-Path $root 'backup') -OlderThanDays 14 -Confirm)
Check 'only the expired test snapshot was removed' (($removed -contains 'old') -and (Test-Path $kept) -and -not (Test-Path $old))

if ($failed.Count) { Write-Host ('FAILED ' + $failed.Count); exit 1 }
Write-Host 'SEAL OK'
exit 0
