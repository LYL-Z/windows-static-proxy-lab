#Requires -Version 5.1
<#
  Synthetic snapshot hardening. Uses TEMP fixtures only.
  Does not read production snapshots, live credentials, or real backups.
#>
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ('v69harden-' + [guid]::NewGuid().ToString('N'))
$outside = Join-Path $env:LOCALAPPDATA ('v69-outside-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$env:V4_TEST_MODE = '1'
$env:V4_TEST_ROOT = $root
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $repo 'proxy_v4\lib\V4.ps1')

$script:hidden = @('SYNTHETIC-V69-HARDEN-a1b2', 'legacy-clash-synthetic')
$failed = New-Object System.Collections.Generic.List[string]
function Scrub([string]$Text) {
    if (-not $Text) { return '' }
    foreach ($h in $script:hidden) { if ($h -and $Text.Contains($h)) { $Text = $Text.Replace($h, '***') } }
    if ($Text.Length -gt 240) { return $Text.Substring(0, 240) }
    return $Text
}
function Check([string]$Name, [bool]$Condition, [string]$Detail) {
    if ($Condition) { Write-Host "PASS $Name" }
    else {
        $extra = ''
        if ($Detail) { $extra = ' :: ' + (Scrub $Detail) }
        Write-Host ("FAIL $Name" + $extra)
        $script:failed.Add($Name)
    }
}
function Test-BytesEqual([byte[]]$Left, [byte[]]$Right) {
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) { if ($Left[$i] -ne $Right[$i]) { return $false } }
    return $true
}
function Read-Bytes([string]$Path) { return [IO.File]::ReadAllBytes($Path) }
function Write-Bytes([string]$Path, [byte[]]$Bytes) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllBytes($Path, $Bytes)
}
function Copy-Snapshot([string]$Src, [string]$Dst) {
    New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath $Src -Recurse -File)) {
        $rel = $file.FullName.Substring($Src.Length).TrimStart('\')
        Write-Bytes (Join-Path $Dst $rel) (Read-Bytes $file.FullName)
    }
}
function Read-Manifest([string]$Dir) {
    return (Get-Content -LiteralPath (Join-Path $Dir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Write-Manifest([string]$Dir, $Manifest) {
    $json = $Manifest | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $Dir 'manifest.json'), $json, (New-Object Text.UTF8Encoding $false))
}
function Get-Stamp([string]$Dir) {
    $acc = ''
    foreach ($file in @(Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object FullName)) {
        $acc += $file.Name + ':' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash + ';'
    }
    return $acc
}

$lock = $null
try {
    $secret = 'SYNTHETIC-V69-HARDEN-a1b2'
    $plainClash = [Text.Encoding]::UTF8.GetBytes('marker: ' + $secret + "`n")
    $plainProfiles = [Text.Encoding]::UTF8.GetBytes("profile-marker: synthetic-second`n")
    $sentinelClash = [Text.Encoding]::UTF8.GetBytes("sentinel-clash`n")
    $sentinelProfiles = [Text.Encoding]::UTF8.GetBytes("sentinel-profiles`n")
    $app = Join-Path $root 'app'
    $profilesDir = Join-Path $app 'profiles'
    New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null
    $clashTarget = Join-Path $app 'clash-verge.yaml'
    $profilesTarget = Join-Path $app 'profiles.yaml'
    Write-Bytes $clashTarget $plainClash
    Write-Bytes $profilesTarget $plainProfiles
    $snap = Join-Path $root 'snap'
    $null = New-V4SnapshotFiles -AppData $app -ProfilesDir $profilesDir -Dir $snap -SystemProxy $null -ClashRunningBefore $false -Reason 'harden'
    $snapManifest = Read-Manifest $snap
    $snapFiles = @($snapManifest.files)
    Check 'sealed fixture has two files' ($snapFiles.Count -ge 2) ([string]($snapFiles.Count))
    Check 'first sealed entry is clash-verge.yaml' ([string]($snapFiles[0].name) -eq 'clash-verge.yaml') ([string]($snapFiles[0].name))
    Check 'second sealed entry is profiles.yaml' ([string]($snapFiles[1].name) -eq 'profiles.yaml') ([string]($snapFiles[1].name))

    Write-Bytes $clashTarget $sentinelClash
    Write-Bytes $profilesTarget $sentinelProfiles
    $good = $null
    $goodDetail = ''
    try { $good = Restore-V4Files -SnapshotDir $snap -AppData $app -ProfilesDir $profilesDir }
    catch { $goodDetail = [string]$_.Exception.Message }
    $goodBytes = $false
    if ($good -and $good.ok -eq $true) {
        $goodBytes = (Test-BytesEqual $plainClash (Read-Bytes $clashTarget)) -and (Test-BytesEqual $plainProfiles (Read-Bytes $profilesTarget))
    }
    Check 'sealed snapshot restores exact bytes' (($null -ne $good) -and ($good.ok -eq $true) -and $goodBytes) $goodDetail

    function Set-Sentinels {
        Write-Bytes $clashTarget $sentinelClash
        Write-Bytes $profilesTarget $sentinelProfiles
    }
    function Test-Sentinels {
        return (Test-BytesEqual $sentinelClash (Read-Bytes $clashTarget)) -and (Test-BytesEqual $sentinelProfiles (Read-Bytes $profilesTarget))
    }
    function Invoke-Refused([string]$Name, [scriptblock]$Action) {
        Set-Sentinels
        $threw = $false
        $detail = ''
        try { & $Action | Out-Null } catch { $threw = $true; $detail = [string]$_.Exception.Message }
        Check ($Name + ' refused') $threw $detail
        Check ($Name + ' wrote no target') (Test-Sentinels) ''
    }
    Set-Sentinels

    $copyIndex = 0
    function New-Copy {
        $script:copyIndex++
        $dest = Join-Path $root ('copy-' + $script:copyIndex)
        Copy-Snapshot $snap $dest
        return $dest
    }
    function Corrupt-Entry([string]$Dir, [string]$Name, [switch]$RetargetCipherHash) {
        $path = Join-Path $Dir $Name
        $bytes = Read-Bytes $path
        $last = $bytes.Length - 1
        $bytes[$last] = [byte]((([int]$bytes[$last] + 1) % 256))
        Write-Bytes $path $bytes
        if ($RetargetCipherHash) {
            $manifest = Read-Manifest $Dir
            foreach ($entry in @($manifest.files)) {
                if (([string]$entry.name) -eq $Name) { $entry.cipherSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
            }
            Write-Manifest $Dir $manifest
        }
    }

    $tamper = New-Copy
    Corrupt-Entry $tamper 'clash-verge.yaml'
    Invoke-Refused 'tampered first ciphertext' { Restore-V4Files -SnapshotDir $tamper -AppData $app -ProfilesDir $profilesDir }
    Check 'second target unchanged when the first ciphertext is corrupt' (Test-BytesEqual $sentinelProfiles (Read-Bytes $profilesTarget)) ''

    $decryptFail = New-Copy
    Corrupt-Entry $decryptFail 'clash-verge.yaml' -RetargetCipherHash
    Invoke-Refused 'decrypt failure of the first ciphertext' { Restore-V4Files -SnapshotDir $decryptFail -AppData $app -ProfilesDir $profilesDir }
    Check 'second target unchanged when the first ciphertext cannot be decrypted' (Test-BytesEqual $sentinelProfiles (Read-Bytes $profilesTarget)) ''

    $missingBoth = New-Copy
    $missingManifest = Read-Manifest $missingBoth
    foreach ($entry in @($missingManifest.files)) {
        if (([string]$entry.name) -eq 'clash-verge.yaml') {
            [void]$entry.PSObject.Properties.Remove('cipherSha256')
            [void]$entry.PSObject.Properties.Remove('sealed')
        }
    }
    Write-Manifest $missingBoth $missingManifest
    Write-Bytes (Join-Path $missingBoth 'clash-verge.yaml') $plainClash
    Invoke-Refused 'schema 3 entry missing cipherSha256' { Restore-V4Files -SnapshotDir $missingBoth -AppData $app -ProfilesDir $profilesDir }

    $missingHash = New-Copy
    $hashManifest = Read-Manifest $missingHash
    foreach ($entry in @($hashManifest.files)) {
        if (([string]$entry.name) -eq 'clash-verge.yaml') {
            [void]$entry.PSObject.Properties.Remove('cipherSha256')
        }
    }
    Write-Manifest $missingHash $hashManifest
    Invoke-Refused 'sealed entry missing cipherSha256' { Restore-V4Files -SnapshotDir $missingHash -AppData $app -ProfilesDir $profilesDir }

    $badPlain = New-Copy
    $plainManifest = Read-Manifest $badPlain
    foreach ($entry in @($plainManifest.files)) {
        if (([string]$entry.name) -eq 'profiles.yaml') { $entry.sha256 = ('ab' * 32) }
    }
    Write-Manifest $badPlain $plainManifest
    Invoke-Refused 'plaintext hash mismatch' { Restore-V4Files -SnapshotDir $badPlain -AppData $app -ProfilesDir $profilesDir }

    foreach ($unsafeName in @('..\evil.yaml', 'profiles\..\escape.yaml', 'C:\Windows\evil.yaml')) {
        $unsafeDir = New-Copy
        $unsafeManifest = Read-Manifest $unsafeDir
        @($unsafeManifest.files)[0].name = $unsafeName
        Write-Manifest $unsafeDir $unsafeManifest
        Invoke-Refused ('unsafe path ' + $unsafeName) { Restore-V4Files -SnapshotDir $unsafeDir -AppData $app -ProfilesDir $profilesDir }
    }
    $unsafeAbsent = New-Copy
    $absentManifest = Read-Manifest $unsafeAbsent
    $absentManifest.absent = @('profiles\..\absent.yaml')
    Write-Manifest $unsafeAbsent $absentManifest
    Invoke-Refused 'unsafe absent path' { Restore-V4Files -SnapshotDir $unsafeAbsent -AppData $app -ProfilesDir $profilesDir }

    $legacyProfiles = [byte[]](0, 255, 254, 1, 2, 3, 10, 13, 239, 187, 191, 65, 0, 66)
    $legacyClash = [Text.Encoding]::UTF8.GetBytes("legacy-clash-synthetic`n")
    $legacy = Join-Path $root 'legacy'
    New-Item -ItemType Directory -Path $legacy -Force | Out-Null
    Write-Bytes (Join-Path $legacy 'profiles.yaml') $legacyProfiles
    Write-Bytes (Join-Path $legacy 'clash-verge.yaml') $legacyClash
    $legacyManifest = [ordered]@{
        schema = 2
        createdAt = (Get-Date).ToString('s')
        reason = 'legacy'
        files = @(
            [ordered]@{ name = 'clash-verge.yaml'; sha256 = (Get-FileHash -LiteralPath (Join-Path $legacy 'clash-verge.yaml') -Algorithm SHA256).Hash }
            [ordered]@{ name = 'profiles.yaml'; sha256 = (Get-FileHash -LiteralPath (Join-Path $legacy 'profiles.yaml') -Algorithm SHA256).Hash }
        )
        absent = @('config.yaml', 'verge.yaml', 'profiles\v4-managed.yaml')
    }
    Write-Bytes (Join-Path $legacy 'manifest.json') ([Text.Encoding]::UTF8.GetBytes(($legacyManifest | ConvertTo-Json -Depth 6)))
    $legacyApp = Join-Path $root 'legacy-app'
    $legacyProfilesDir = Join-Path $legacyApp 'profiles'
    New-Item -ItemType Directory -Path $legacyProfilesDir -Force | Out-Null
    Write-Bytes (Join-Path $legacyApp 'clash-verge.yaml') $sentinelClash
    Write-Bytes (Join-Path $legacyApp 'profiles.yaml') $sentinelProfiles
    $legacyResult = $null
    $legacyDetail = ''
    try { $legacyResult = Restore-V4Files -SnapshotDir $legacy -AppData $legacyApp -ProfilesDir $legacyProfilesDir }
    catch { $legacyDetail = [string]$_.Exception.Message }
    $legacyExact = $false
    if ($legacyResult -and $legacyResult.ok -eq $true) {
        $legacyExact = (Test-BytesEqual $legacyClash (Read-Bytes (Join-Path $legacyApp 'clash-verge.yaml'))) -and (Test-BytesEqual $legacyProfiles (Read-Bytes (Join-Path $legacyApp 'profiles.yaml')))
    }
    Check 'schema 2 fixture restores exact bytes' (($null -ne $legacyResult) -and ($legacyResult.ok -eq $true) -and $legacyExact) $legacyDetail

    $legacyStamp = Get-Stamp $legacy
    function Assert-MigrationRefused([string]$Name, [scriptblock]$Action, [string]$Pattern) {
        $threw = $false
        $detail = ''
        try { & $Action | Out-Null } catch { $threw = $true; $detail = [string]$_.Exception.Message }
        $ok = $threw -and ($detail -match $Pattern)
        Check $Name $ok $detail
    }
    Assert-MigrationRefused 'migration without Confirm is refused' { ConvertTo-V4SealedSnapshot -SnapshotDir $legacy -TestRoot $root } 'Confirm'
    Assert-MigrationRefused 'migration refuses TestRoot equal to TEMP' { ConvertTo-V4SealedSnapshot -SnapshotDir $legacy -TestRoot $env:TEMP -Confirm } 'outside TEMP'
    Assert-MigrationRefused 'migration refuses TestRoot outside TEMP' { ConvertTo-V4SealedSnapshot -SnapshotDir $legacy -TestRoot $outside -Confirm } 'outside TEMP'
    Assert-MigrationRefused 'migration refuses a snapshot outside TEMP' { ConvertTo-V4SealedSnapshot -SnapshotDir $outside -TestRoot $root -Confirm } 'outside TEMP'
    $sibling = Join-Path $root 'other-root'
    New-Item -ItemType Directory -Path $sibling -Force | Out-Null
    Assert-MigrationRefused 'migration refuses a snapshot outside TestRoot' { ConvertTo-V4SealedSnapshot -SnapshotDir $legacy -TestRoot $sibling -Confirm } 'outside TestRoot'
    Check 'refused migration left the schema 2 snapshot unchanged' ((Get-Stamp $legacy) -eq $legacyStamp) ''
    Check 'refused migration did not create an outside path' (-not (Test-Path -LiteralPath $outside)) $outside

    $legacySeal = Join-Path $root 'legacy-seal'
    Copy-Snapshot $legacy $legacySeal
    $migrated = $null
    $migrateDetail = ''
    try { $migrated = ConvertTo-V4SealedSnapshot -SnapshotDir $legacySeal -TestRoot $root -Confirm }
    catch { $migrateDetail = [string]$_.Exception.Message }
    $sealedManifest = $null
    if (-not $migrateDetail) { $sealedManifest = Read-Manifest $legacySeal }
    $sealOk = ($migrated -and $migrated.schema -eq 3 -and $sealedManifest -and [int]$sealedManifest.schema -eq 3)
    Check 'confirmed TEMP migration seals schema 2' $sealOk $migrateDetail
    $cipherRaw = ''
    $manifestRaw = ''
    if (Test-Path -LiteralPath (Join-Path $legacySeal 'clash-verge.yaml')) {
        $cipherRaw = [Text.Encoding]::UTF8.GetString((Read-Bytes (Join-Path $legacySeal 'clash-verge.yaml')))
        $manifestRaw = [IO.File]::ReadAllText((Join-Path $legacySeal 'manifest.json'))
    }
    Check 'migrated ciphertext hides the synthetic marker' ((-not $cipherRaw.Contains('legacy-clash-synthetic')) -and (-not $manifestRaw.Contains('legacy-clash-synthetic'))) ''
    $everyCipher = $true
    if ($sealedManifest) {
        foreach ($entry in @($sealedManifest.files)) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.cipherSha256)) { $everyCipher = $false }
        }
    } else { $everyCipher = $false }
    Check 'migrated manifest stores ciphertext hashes' $everyCipher ''
    Write-Bytes (Join-Path $legacyApp 'clash-verge.yaml') $sentinelClash
    Write-Bytes (Join-Path $legacyApp 'profiles.yaml') $sentinelProfiles
    $afterSeal = $null
    $afterDetail = ''
    try { $afterSeal = Restore-V4Files -SnapshotDir $legacySeal -AppData $legacyApp -ProfilesDir $legacyProfilesDir }
    catch { $afterDetail = [string]$_.Exception.Message }
    $afterExact = $false
    if ($afterSeal -and $afterSeal.ok -eq $true) {
        $afterExact = (Test-BytesEqual $legacyClash (Read-Bytes (Join-Path $legacyApp 'clash-verge.yaml'))) -and (Test-BytesEqual $legacyProfiles (Read-Bytes (Join-Path $legacyApp 'profiles.yaml')))
    }
    Check 'migrated schema 3 snapshot restores exact bytes' (($null -ne $afterSeal) -and ($afterSeal.ok -eq $true) -and $afterExact) $afterDetail
    Assert-MigrationRefused 'migration refuses an already sealed snapshot' { ConvertTo-V4SealedSnapshot -SnapshotDir $legacySeal -TestRoot $root -Confirm } 'schema 2'

    Set-Sentinels
    $held = Read-Bytes $clashTarget
    $partial = $null
    $partialThrew = $false
    $partialDetail = ''
    try {
        $lock = [IO.File]::Open($clashTarget, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $partial = Restore-V4Files -SnapshotDir $snap -AppData $app -ProfilesDir $profilesDir }
        catch { $partialThrew = $true; $partialDetail = [string]$_.Exception.Message }
    }
    finally {
        if ($lock) { $lock.Dispose(); $lock = $null }
    }
    $failureNames = @()
    if ($partial) { $failureNames = @($partial.failures | ForEach-Object { [string]$_.name }) }
    $reported = $false
    if ($partial) {
        foreach ($item in @($partial.failures)) { if ($item.error -and [string]$item.error.Length -gt 0) { $reported = $true } }
    }
    Check 'partial restore returns failure instead of throwing' ((-not $partialThrew) -and ($null -ne $partial)) $partialDetail
    Check 'partial restore does not claim full success' ($partial -and $partial.ok -eq $false) ''
    Check 'partial restore reports the locked target' (($failureNames -contains 'clash-verge.yaml') -and $reported) ''
    Check 'partial restore does not mark the locked target restored' ($partial -and -not (@($partial.restored) -contains 'clash-verge.yaml')) ''
    Check 'locked target bytes stayed unchanged' (Test-BytesEqual $held (Read-Bytes $clashTarget)) ''
}
catch {
    Check 'unhandled exception' $false ([string]$_.Exception.Message)
}
finally {
    if ($lock) { $lock.Dispose() }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $outside) { Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failed.Count) { Write-Host ('FAILED ' + $failed.Count); exit 1 }
Write-Host 'HARDEN OK'
exit 0
