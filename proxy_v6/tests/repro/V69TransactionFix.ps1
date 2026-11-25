#Requires -Version 5.1
<#
  Isolated checks for receipt parsing, the recorded keep-proxy selection,
  and a completed apply whose journal cannot be cleared.
  Does not read or write the live Windows proxy.
#>
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ('v69tx-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$env:V4_TEST_MODE = '1'
$env:V4_TEST_ROOT = $root
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $repo 'proxy_v4\lib\V4.ps1')
$failed = New-Object System.Collections.Generic.List[string]

function Check([string]$Name, [bool]$Condition) {
    if ($Condition) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name"; $script:failed.Add($Name) }
}

function Put-Receipt([string]$Json) {
    $dir = Get-V4RepairDirectory
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (-not (Protect-V4Acl -Path $dir)) { throw 'recovery directory ACL was not hardened' }
    $path = Join-Path $dir 'pending.json'
    [IO.File]::WriteAllText($path, $Json)
    if (-not (Protect-V4Acl -Path $path)) { throw 'recovery receipt ACL was not hardened' }
}

$id = '0123456789abcdef0123456789abcdef'
$valid = '{"schema":1,"id":"' + $id + '","previous":"127.0.0.1:11119","target":"127.0.0.1:7897"}'
Put-Receipt $valid
$receipt = Get-V4RepairReceipt
Check 'valid receipt' ($receipt.id -eq $id -and -not $receipt.invalid)

$malformed = New-Object System.Collections.Generic.List[string]
$malformed.Add(('{"schema":[1],"id":"' + $id + '","previous":"127.0.0.1:11119","target":"127.0.0.1:7897"}'))
$malformed.Add(('{"schema":1,"id":["' + $id + '"],"previous":"127.0.0.1:11119","target":"127.0.0.1:7897"}'))
$malformed.Add(('{"schema":1,"id":"' + $id + '","previous":"127.0.0.1:2222' + [char]10 + '","target":"127.0.0.1:7897"}'))
$malformed.Add(('{"schema":1,"id":"' + $id + '","previous":"127.0.0.1:7897","target":"127.0.0.1:7897"}'))
Check 'malformed case count' ($malformed.Count -eq 4)
for ($i = 0; $i -lt $malformed.Count; $i++) {
    Put-Receipt $malformed[$i]
    $parsed = Get-V4RepairReceipt
    Check ('rejected malformed receipt ' + $i) ($null -ne $parsed -and $parsed.invalid -eq $true)
}

$kept = [pscustomobject]@{ enabled = $true; server = '127.0.0.1:7897' }
Write-V4Journal -SnapshotDir 'C:\fixture-snapshot' -Reason 'rollback' -KeepSystemProxy -KeptProxy $kept
$journal = Get-V4Journal
Check 'journal records keep-proxy selection' ($journal.data.keepSystemProxy -eq $true -and $journal.data.keptEnabled -eq $true -and $journal.data.keptServer -eq '127.0.0.1:7897')

$stage = Join-Path $root 'files'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$proxy = @{ enabled = $true; server = '127.0.0.1:1' }
$ctx = [pscustomobject]@{
    Reason = 'apply-test'
    Mode = 'strict'
    Settings = [pscustomobject]@{ host = '203.0.113.10'; mixedPort = 7897 }
    Paths = [pscustomobject]@{
        ProfilesFile = (Join-Path $stage 'profiles.yaml')
        ProfileFile = (Join-Path $stage 'profile.yaml')
        RuntimeFile = (Join-Path $stage 'runtime.yaml')
    }
    ProfileText = 'profile'
    ProfileTextBuilder = { 'profile' }
    ProfileValidator = { }
    RuntimeValidator = { }
    Redact = { param($Message) $Message }
    Ops = [pscustomobject]@{
        Snapshot = { param($Reason) Join-Path $root 'snap' }
        WriteJournal = { param($Snap, $Reason) Write-V4Journal -SnapshotDir $Snap -Reason $Reason }
        WriteAtomic = { param($Target, $Content, $Validator) Set-Content -LiteralPath $Target -Value $Content -Encoding ascii }
        StartApp = { param($Timeout, $Port) $true }
        GetExitIp = { param($Proxy) '203.0.113.10' }
        SetSystemProxy = { param($Server) $proxy.server = $Server }
        GetSystemProxy = { [pscustomobject]$proxy }
        ProtectAcl = { param($Path) $true }
        SetOwner = { param($Server, $Note) }
        GetOwnerText = { 'previous-owner' }
        IsAppRunning = { $false }
        ClearJournal = { $false }
        Log = { param($Message, $Level) }
    }
}
$result = Invoke-V4ApplyTransaction -Context $ctx
Check 'uncleared journal is not success' ((-not $result.ok) -and $result.exitCode -eq 40 -and $result.restored -eq $false)
Check 'journal remains after failed clear' ($null -ne (Get-V4Journal))

$reads = 0
$enableWrites = 0
$recover = [pscustomobject]@{
    Reason = 'apply-test'
    Mode = 'strict'
    Settings = [pscustomobject]@{ host = '203.0.113.10'; mixedPort = 7897 }
    Paths = [pscustomobject]@{
        ProfilesFile = (Join-Path $stage 'profiles.yaml')
        ProfileFile = (Join-Path $stage 'profile.yaml')
        RuntimeFile = (Join-Path $stage 'runtime.yaml')
    }
    ProfileText = 'profile'
    ProfileTextBuilder = { 'profile' }
    ProfileValidator = { }
    RuntimeValidator = { }
    Redact = { param($Message) $Message }
    Ops = [pscustomobject]@{
        Snapshot = { param($Reason) Join-Path $root 'snap' }
        WriteJournal = { param($Snap, $Reason) Write-V4Journal -SnapshotDir $Snap -Reason $Reason }
        WriteAtomic = { throw [pscustomobject]@{ code = 12; msg = 'disk full' } }
        StartApp = { param($Timeout, $Port) $true }
        StopApp = { param($Port) }
        Restore = { param($Dir) }
        GetExitIp = { param($Proxy) '203.0.113.10' }
        SetSystemProxy = { param($Server) $script:enableWrites++ }
        GetSystemProxy = {
            $script:reads++
            if ($script:reads -le 1) { return [pscustomobject]@{ enabled = $true; server = '127.0.0.1:7897' } }
            return [pscustomobject]@{ enabled = $false; server = '127.0.0.1:7897' }
        }
        ProtectAcl = { param($Path) $true }
        SetOwner = { param($Server, $Note) }
        GetOwnerText = { 'previous-owner' }
        RestoreOwner = { param($Text) }
        IsAppRunning = { $false }
        ClearJournal = { Clear-V4Journal }
        Log = { param($Message, $Level) }
    }
}
$recovered = Invoke-V4ApplyTransaction -Context $recover
Check 'recovery does not re-enable a proxy the user turned off' ($enableWrites -eq 0 -and $recovered.exitCode -eq 12)

if ($failed.Count) {
    Write-Host ("FAILED " + $failed.Count)
    exit 1
}
Write-Host 'RESULT PASS'
exit 0
