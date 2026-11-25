#Requires -Version 5.1
<#
  V4.ps1 - proxy_v4 engine (PowerShell 5.1, non-elevated, ASCII-only source).

  Design decisions that close the V3 review findings:
    * settings are JSON (native parser) -> no hand-written YAML parsing (M5/M6)
    * the proxy password is DPAPI-encrypted at rest in our own store
    * a single lock file serialises apply/rollback (M9)
    * "stopped" means verified absence of process + free port (M10)
    * snapshots are taken with the app stopped and are hashed from the COPIES (M3)
    * an owner record makes system-proxy ownership explicit (H4)
    * generated configs carry a marker so an overwrite is detectable (M8)
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# V6 test isolation: only an explicit env switch may redirect the mutable root.
# Production runs (no V4_TEST_MODE) keep the historical layout next to lib.
$script:TestMode = ($env:V4_TEST_MODE -eq '1')
if ($script:TestMode) {
    $testRoot = $env:V4_TEST_ROOT
    if (-not $testRoot) { $testRoot = Join-Path $env:TEMP ('v4-test-' + $PID) }
    $script:Root = [System.IO.Path]::GetFullPath($testRoot)
}
else { $script:Root = Split-Path -Parent $PSScriptRoot }
$script:ConfigDir   = Join-Path $script:Root 'config'
$script:BackupDir   = Join-Path $script:Root 'backup'
$script:SettingsPath = Join-Path $script:ConfigDir 'settings.json'
$script:OwnerPath    = Join-Path $script:ConfigDir 'owner.json'
$script:LockPath     = Join-Path $script:ConfigDir '.lock'
$script:Marker       = '# proxy_v4 managed - do not edit by hand'
$script:Secrets      = New-Object System.Collections.Generic.List[string]
$script:LogFile      = $null

# S07: nothing is created at dot-source time. DryRun must not leave config/backup
# directories behind; each writer creates exactly what it needs.
$script:ProductionWritesEnabled = $false
$script:TestRegistryWriter = $null

function Enable-V4ProductionWrites {
    if ($script:TestMode) { return $false }
    $script:ProductionWritesEnabled = $true
    return $true
}

function Set-V4TestRegistryWriter {
    param([scriptblock]$Writer)
    if (-not $script:TestMode) { throw 'Set-V4TestRegistryWriter is test-mode only' }
    $script:TestRegistryWriter = $Writer
}

function Assert-V4ProductionOperation {
    param([string]$Name)
    if ($script:TestMode) { throw ('V4 test mode blocks real operation: ' + $Name) }
    if (-not $script:ProductionWritesEnabled) { throw ('V4 production write blocked (call Enable-V4ProductionWrites in apply/rollback first): ' + $Name) }
}
function Ensure-V4Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# ------------------------------------------------------------------ logging --
function Register-V4Secret { param([string]$Value) if ($Value -and -not $script:Secrets.Contains($Value)) { $script:Secrets.Add($Value) } }

function Get-V4Redacted {
    param([string]$Text)
    if (-not $Text) { return $Text }
    foreach ($s in $script:Secrets) { if ($s -and $s.Length -ge 3) { $Text = $Text.Replace($s, '***') } }
    # URL userinfo first, otherwise "user:pass@" can be mistaken for a key/value pair.
    $Text = [regex]::Replace($Text, '(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@', '$1***@')
    # Covers quoted JSON keys, quoted values with spaces, and unquoted key: value lines.
    $Text = [regex]::Replace($Text, '(?i)("?(?:password|passwd|pwd|pass|secret|token|username|user|authorization|cookie|x-api-key|api[_-]?key|apikey)"?\s*[:=]\s*)("[^"]*"|''[^'']*''|[^\r\n]+)', '$1"***"')
    $Text = [regex]::Replace($Text, '(?i)(Basic\s+)([A-Za-z0-9+/=]{4,})', '$1***')
    $Text = [regex]::Replace($Text, '(?i)(Bearer\s+)([A-Za-z0-9._~+/=-]{4,})', '$1***')
    $Text = [regex]::Replace($Text, '(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@', '$1***@')
    return $Text
}

function Write-V4Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level = 'INFO')
    $m = Get-V4Redacted $Message
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $m
    $color = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
    try { Write-Host $line -ForegroundColor $color } catch { }
    if ($script:LogFile) { try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { } }
}

function Start-V4Log {
    param([string]$Name)
    try {
        $dir = Join-Path $script:Root 'evidence'
        Ensure-V4Dir $dir
        if (-not (Protect-V4Acl -Path $dir)) { $script:LogFile = $null; return $false }
        $script:LogFile = Join-Path $dir ('{0}-{1}-{2}.log' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), ([guid]::NewGuid().ToString('N').Substring(0,6)))
        Add-Content -LiteralPath $script:LogFile -Value ('# proxy_v4 ' + (Get-Date -Format 's')) -Encoding UTF8
        if (-not (Protect-V4Acl -Path $script:LogFile)) {
            Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
            $script:LogFile = $null
            return $false
        }
        return $true
    }
    catch {
        $script:LogFile = $null
        return $false
    }
}

# ------------------------------------------------------- recovery orchestration --
function Write-V4RecoveryNote {
    param($Log, [string]$Message, [string]$Level = 'WARN')
    if ($Log) { try { & $Log $Message $Level } catch { } }
}

function Invoke-V4Recovery {
    param(
        [string]$SnapshotDir,
        [int]$Code,
        [object]$AppWasRunning,
        [scriptblock]$StopApp,
        [scriptblock]$Restore,
        [scriptblock]$RestoreProxy,
        [scriptblock]$VerifyProxy,
        [scriptblock]$RestoreOwner,
        [scriptblock]$StartApp,
        [scriptblock]$Log
    )
    $restoreOk = $true
    $processOk = $true
    $proxyOk = $true
    try {
        Write-V4RecoveryNote $Log 'mid-transaction failure; starting recovery' 'WARN'
        if ($null -eq $AppWasRunning -and $SnapshotDir) {
            $processOk = $false
            Write-V4RecoveryNote $Log 'recovery: process state is unknown; cannot prove restoration' 'ERROR'
        }
        # Stop before copying so the app cannot regenerate a file mid-restore.
        if ($SnapshotDir -and $StopApp) {
            try { & $StopApp | Out-Null }
            catch { $processOk = $false; Write-V4RecoveryNote $Log ('recovery stop failed: ' + $_.Exception.Message) 'ERROR' }
        }
        if ($SnapshotDir -and $Restore) {
            try { & $Restore $SnapshotDir | Out-Null }
            catch { $restoreOk = $false; Write-V4RecoveryNote $Log ('recovery restore failed: ' + $_.Exception.Message) 'ERROR' }
        }
        if ($RestoreProxy) {
            try { & $RestoreProxy | Out-Null }
            catch { $proxyOk = $false; Write-V4RecoveryNote $Log ('recovery proxy restore failed: ' + $_.Exception.Message) 'ERROR' }
        }
        if ($RestoreOwner) {
            try { & $RestoreOwner | Out-Null }
            catch { $restoreOk = $false; Write-V4RecoveryNote $Log ('recovery owner restore failed: ' + $_.Exception.Message) 'ERROR' }
        }
        if ($null -ne $AppWasRunning) {
            try {
                if ($AppWasRunning) {
                    if ($StartApp) {
                        if (-not (& $StartApp)) { $processOk = $false; Write-V4RecoveryNote $Log 'recovery: app did not restart' 'ERROR' }
                    }
                    else { $processOk = $false }
                }
                else {
                    if ($StopApp) { & $StopApp | Out-Null }
                }
            }
            catch { $processOk = $false; Write-V4RecoveryNote $Log ('recovery process step failed: ' + $_.Exception.Message) 'ERROR' }
        }
        if ($VerifyProxy) {
            try { $proxyOk = [bool](& $VerifyProxy) -and $proxyOk }
            catch { $proxyOk = $false }
            if (-not $proxyOk) { Write-V4RecoveryNote $Log 'recovery: Windows proxy did not retain its previous state after the process step' 'ERROR' }
        }
        if ($restoreOk -and $processOk -and $proxyOk) { return $Code }
        return 40
    }
    catch {
        Write-V4RecoveryNote $Log ('recovery aborted unexpectedly: ' + $_.Exception.Message) 'ERROR'
        return 40
    }
}

# ---------------------------------------------------- transaction journal --
function Get-V4JournalPath { return (Join-Path $script:ConfigDir 'transaction.json') }

function Get-V4RepairDirectory {
    if ($script:TestMode) { return (Join-Path $script:Root 'repair-state') }
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WindowsStaticProxyLab-Recovery')
}

function Get-V4RepairReceipt {
    # Stored per user so a second candidate checkout also sees interrupted work.
    $dir = Get-V4RepairDirectory
    try {
        $directory = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
        $allowed = Get-V4AllowedSidSet
        if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not (Test-V4AclHardened -Path $dir -Allowed $allowed)) { throw 'unsafe recovery directory' }
        $path = Join-Path $dir 'pending.json'
        $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $file.Length -gt 2048 -or -not (Test-V4AclHardened -Path $path -Allowed $allowed)) { throw 'unsafe recovery receipt' }
        $entry = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        $schema = $entry.schema
        if ($schema -is [System.Array] -or $schema -is [string] -or $schema -is [bool] -or $schema -isnot [System.ValueType] -or [int]$schema -ne 1) { throw 'invalid record' }
        if ($entry.id -isnot [string] -or $entry.previous -isnot [string] -or $entry.target -isnot [string]) { throw 'invalid record' }
        if ($entry.id -notmatch '\A[a-f0-9]{32}\z' -or $entry.previous -eq $entry.target) { throw 'invalid record' }
        foreach ($server in @($entry.previous, $entry.target)) {
            if ($server -notmatch '\A127\.0\.0\.1:([1-9]\d{0,4})\z' -or [int]$Matches[1] -gt 65535) { throw 'invalid local proxy target' }
        }
        return $entry
    } catch [System.Management.Automation.ItemNotFoundException] { return $null }
    catch { return [pscustomobject]@{ invalid=$true } }
}

function New-V4RepairReceipt {
    param([string]$Previous, [string]$Target)
    $dir = Get-V4RepairDirectory
    $id = [guid]::NewGuid().ToString('N')
    if (-not (Test-Path -LiteralPath $dir -ErrorAction Stop)) {
        $stage = $dir + '-stage-' + $id
        $null = New-Item -ItemType Directory -Path $stage -ErrorAction Stop
        try {
            if (-not (Protect-V4Acl -Path $stage)) { throw (New-V4Fault 12 'could not protect recovery directory') }
            [IO.Directory]::Move($stage, $dir)
        } finally { if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage) } }
    }
    if (Get-V4RepairReceipt) { throw (New-V4Fault 34 'pending or unreadable repair receipt') }
    $entry = [ordered]@{schema=1; id=$id; previous=$Previous; target=$Target}
    $temp = Join-Path $dir ($id + '.tmp')
    $stream = [IO.File]::Open($temp, 'CreateNew', 'Write', 'None')
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($entry | ConvertTo-Json -Compress))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    try {
        if (-not (Protect-V4Acl -Path $temp)) { throw (New-V4Fault 12 'could not protect recovery receipt') }
        [IO.File]::Move($temp, (Join-Path $dir 'pending.json'))
        $saved = Get-V4RepairReceipt
        if (-not $saved -or $saved.id -ne $id) { throw (New-V4Fault 34 'could not verify recovery receipt') }
        return $saved
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Complete-V4RepairReceipt {
    param($Receipt)
    $current = Get-V4RepairReceipt
    if (-not $current -or -not $Receipt.id -or $current.id -ne $Receipt.id) { throw (New-V4Fault 40 'recovery receipt changed; inspect before continuing') }
    [IO.File]::Delete((Join-Path (Get-V4RepairDirectory) 'pending.json'))
    if (Get-V4RepairReceipt) { throw (New-V4Fault 40 'recovery receipt could not be retired') }
}

function Get-V4Journal {
    $p = Get-V4JournalPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j -or -not $j.snapshot) { return [pscustomobject]@{ corrupt = $true; data = $null } }
        return [pscustomobject]@{ corrupt = $false; data = $j }
    }
    catch { return [pscustomobject]@{ corrupt = $true; data = $null } }
}

function Write-V4Journal {
    param([string]$SnapshotDir, [string]$Reason = 'apply', [switch]$KeepSystemProxy, [switch]$PreserveUserOff, $KeptProxy)
    Ensure-V4Dir $script:ConfigDir
    $o = [ordered]@{
        schema = 1
        snapshot = $SnapshotDir
        reason = $Reason
        started = (Get-Date).ToString('o')
        pid = $PID
    }
    if ($Reason -eq 'rollback') {
        $o['keepSystemProxy'] = [bool]$KeepSystemProxy
        $o['preserveUserOff'] = [bool]$PreserveUserOff
        if ($KeepSystemProxy) {
            if ($null -eq $KeptProxy) { throw 'KeepSystemProxy rollback requires the proxy selection to record' }
            $o['keptEnabled'] = [bool]$KeptProxy.enabled
            $o['keptServer'] = [string]$KeptProxy.server
        }
    }
    Set-V4Atomic -TargetPath (Get-V4JournalPath) -Content ($o | ConvertTo-Json -Depth 4) | Out-Null
}

function Clear-V4Journal {
    param([switch]$WhatIf)
    $p = Get-V4JournalPath
    if (-not (Test-Path -LiteralPath $p)) { return $true }
    if ($WhatIf) { return $false }
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    return (-not (Test-Path -LiteralPath $p))
}

# ------------------------------------------------------- transaction engine --
function Invoke-V4ApplyTransaction {
    param([object]$Context)
    $ops = $Context.Ops
    $snap = $null
    $applied = $false
    $journalWritten = $false
    $wasRunning = $null
    $beforeProxy = $null
    $ownerBefore = $null
    $ownerKnown = $false
    $code = 0
    $msg = ''
    try {
        # Capture the state we may have to put back. These are read-only probes.
        if ($ops.GetSystemProxy) { $beforeProxy = & $ops.GetSystemProxy }
        if ($ops.GetOwnerText) {
            try { $ownerBefore = & $ops.GetOwnerText; $ownerKnown = $true } catch { }
        }
        if ($ops.IsAppRunning) { $wasRunning = [bool](& $ops.IsAppRunning) }
        $snap = & $ops.Snapshot $Context.Reason
        # R2A-05: read profiles.yaml AFTER the app is stopped (snapshot), so a
        # desktop-app flush during shutdown cannot be overwritten with stale text.
        if ($Context.ProfileTextBuilder) { $Context.ProfileText = [string](& $Context.ProfileTextBuilder) }
        if ($ops.WriteJournal) {
            try { & $ops.WriteJournal $snap $Context.Reason | Out-Null; $journalWritten = $true }
            catch { throw [pscustomobject]@{ code = 34; msg = ('cannot write transaction journal: ' + $_.Exception.Message) } }
        }
        # F07: dirty immediately before the FIRST live write.
        $applied = $true
        & $ops.WriteAtomic $Context.Paths.ProfilesFile $Context.ProfileText $Context.ProfileValidator | Out-Null
        & $ops.WriteAtomic $Context.Paths.ProfileFile $Context.ProfileYaml $Context.RuntimeValidator | Out-Null
        & $ops.WriteAtomic $Context.Paths.RuntimeFile $Context.RuntimeYaml $Context.RuntimeValidator | Out-Null
        if (-not (& $ops.StartApp 45 $Context.Settings.mixedPort)) {
            throw [pscustomobject]@{ code = 30; msg = 'app did not listen in time' }
        }
        $got = & $ops.GetExitIp ('socks5h://127.0.0.1:' + $Context.Settings.mixedPort)
        if ($got -ne $Context.Settings.host) {
            throw [pscustomobject]@{ code = 31; msg = ('chain exit ' + $got) }
        }
        & $ops.SetSystemProxy ('127.0.0.1:' + $Context.Settings.mixedPort)
        $px = & $ops.GetSystemProxy
        if (-not $px.enabled -or $px.server -ne ('127.0.0.1:' + $Context.Settings.mixedPort)) {
            throw [pscustomobject]@{ code = 32; msg = 'system proxy not set' }
        }
        foreach ($target in @($Context.Paths.ProfileFile, $Context.Paths.RuntimeFile)) {
            $aclOk = & $ops.ProtectAcl $target
            if ($aclOk -eq $false) { throw [pscustomobject]@{ code = 12; msg = ('ACL hardening failed: ' + $target) } }
        }
        & $ops.SetOwner ('127.0.0.1:' + $Context.Settings.mixedPort) ('mode=' + $Context.Mode)
        if ($journalWritten -and $ops.ClearJournal) {
            $cleared = $false
            try { $cleared = [bool](& $ops.ClearJournal) } catch { $cleared = $false }
            if (-not $cleared) {
                Write-V4RecoveryNote $ops.Log 'transaction writes are in place but the journal could not be cleared; do not roll them back until that journal is understood' 'ERROR'
                return [pscustomobject]@{ ok = $false; exitCode = 40; error = 'transaction writes are in place but the journal could not be cleared'; snapshot = $snap; applied = $applied; restored = $false; journalWritten = $journalWritten }
            }
        }
        return [pscustomobject]@{ ok = $true; exitCode = 0; error = ''; snapshot = $snap; applied = $applied; restored = $false; journalWritten = $journalWritten }
    }
    catch {
        $fault = $_.TargetObject
        if ($fault -and $fault.code) { $code = [int]$fault.code; $msg = [string]$fault.msg }
        else { $code = 1; $msg = $_.Exception.Message }
        if (-not $msg) { $msg = $_.Exception.Message }
        if ($Context.Redact) { try { $msg = & $Context.Redact $msg } catch { } }
        if ($snap -or $applied -or ($null -ne $wasRunning)) {
            $restoreProxy = $null
            $verifyProxy = $null
            if ($beforeProxy) {
                $bp = $beforeProxy
                $intent = @{ preserveOff = $false }
                $restoreProxy = {
                    $now = & $ops.GetSystemProxy
                    if ($bp.enabled -and $now -and -not $now.enabled) {
                        $intent.preserveOff = $true
                        return
                    }
                    if ($bp.enabled) { & $ops.SetSystemProxy $bp.server }
                    elseif ($ops.ClearSystemProxy) { & $ops.ClearSystemProxy }
                }.GetNewClosure()
                $verifyProxy = {
                    $now = & $ops.GetSystemProxy
                    if ($intent.preserveOff) { return [bool]($now -and -not $now.enabled) }
                    Test-V4SystemProxyMatch -Expected $bp -Actual $now
                }.GetNewClosure()
            }
            $recoverStart = { & $ops.StartApp 30 $Context.Settings.mixedPort }
            $recoverStop = { & $ops.StopApp $Context.Settings.mixedPort }
            $recoverOwner = $null
            if ($ownerKnown -and $ops.RestoreOwner) {
                $ob = $ownerBefore
                $recoverOwner = { & $ops.RestoreOwner $ob }
            }
            $recoverCode = Invoke-V4Recovery -SnapshotDir $snap -Code $code -AppWasRunning $wasRunning -StopApp $recoverStop -Restore $ops.Restore -RestoreProxy $restoreProxy -VerifyProxy $verifyProxy -RestoreOwner $recoverOwner -StartApp $recoverStart -Log $ops.Log
            $code = $recoverCode
            if ($journalWritten -and $code -ne 40 -and $ops.ClearJournal) {
                try { if (-not (& $ops.ClearJournal)) { Write-V4RecoveryNote $ops.Log 'recovery succeeded but the journal could not be cleared' 'WARN' } }
                catch { Write-V4RecoveryNote $ops.Log ('recovery journal clear failed: ' + $_.Exception.Message) 'WARN' }
            }
        }
        return [pscustomobject]@{ ok = $false; exitCode = $code; error = $msg; snapshot = $snap; applied = $applied; restored = ($code -ne 40) }
    }
}

# --------------------------------------------------------------- primitives --
function Write-V4File { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false))) }
function Read-V4File  { param([string]$Path) if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } return $null }

function Protect-V4Secret {
    param([string]$Plain)
    $s = ConvertTo-SecureString -String $Plain -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $s)
}

function Unprotect-V4Secret {
    param([string]$Enc)
    $s = ConvertTo-SecureString -String $Enc
    $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Get-V4Paths {
    $r = @{ InstallDir=$null; Exe=$null; Core=$null; AppData=$null; ProfilesDir=$null; RuntimeFile=$null; ProfileFile=$null }
    if ($script:TestMode) {
        # Test mode NEVER falls back to the real installation/appdata.
        $ad = $env:V4_TEST_APPDATA
        if ($ad) {
            $r.AppData = [System.IO.Path]::GetFullPath($ad)
            $r.ProfilesDir = Join-Path $r.AppData 'profiles'
            $r.RuntimeFile = if ($env:V4_TEST_RUNTIME) { [System.IO.Path]::GetFullPath($env:V4_TEST_RUNTIME) } else { Join-Path $r.AppData 'clash-verge.yaml' }
        }
        $inst = $env:V4_TEST_INSTALL
        if ($inst) {
            $r.InstallDir = [System.IO.Path]::GetFullPath($inst)
            $r.Exe = if ($env:V4_TEST_EXE) { $env:V4_TEST_EXE } else { Join-Path $r.InstallDir 'clash-verge.exe' }
        }
        if ($env:V4_TEST_CORE) { $r.Core = $env:V4_TEST_CORE }
        elseif ($r.InstallDir) { $r.Core = Join-Path $r.InstallDir 'verge-mihomo.exe' }
        return $r
    }
    foreach ($c in @("$env:ProgramFiles\Clash Verge", "${env:ProgramFiles(x86)}\Clash Verge")) {
        if (Test-Path (Join-Path $c 'clash-verge.exe')) { $r.InstallDir = $c; break }
    }
    $app = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($app -and $app.Path) { $r.InstallDir = Split-Path -Parent $app.Path }
    if ($r.InstallDir) {
        $r.Exe = Join-Path $r.InstallDir 'clash-verge.exe'
        foreach ($n in @('verge-mihomo.exe','mihomo.exe')) { if (Test-Path (Join-Path $r.InstallDir $n)) { $r.Core = Join-Path $r.InstallDir $n; break } }
    }
    $ad = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
    if (Test-Path (Join-Path $ad 'profiles.yaml')) { $r.AppData = $ad; $r.ProfilesDir = Join-Path $ad 'profiles'; $r.RuntimeFile = Join-Path $ad 'clash-verge.yaml' }
    return $r
}

# ------------------------------------------------------------------- settings --
function Get-V4FaultMessage {
    param($ErrorRecord)
    if ($ErrorRecord -and $ErrorRecord.TargetObject -and $ErrorRecord.TargetObject.code -and $ErrorRecord.TargetObject.msg) { return [string]$ErrorRecord.TargetObject.msg }
    if ($ErrorRecord -and $ErrorRecord.Exception) { return [string]$ErrorRecord.Exception.Message }
    return 'unknown error'
}

function New-V4Fault {
    param([int]$Code, [string]$Message)
    return [pscustomobject]@{ code = $Code; msg = $Message }
}

function Assert-V4SettingsInput {
    param([string]$Host_, [int]$Port, [string]$Username, [string]$Password, [string]$HopHost, [int]$HopPort, [int]$MixedPort)
    if (-not $Host_ -or $Host_ -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw (New-V4Fault 11 'static host must be IPv4') }
    foreach ($p in @($Port, $HopPort, $MixedPort)) { if ($p -lt 1 -or $p -gt 65535) { throw (New-V4Fault 11 'port out of range') } }
    if (-not $Username) { throw (New-V4Fault 11 'username is empty') }
    if (-not $Password) { throw (New-V4Fault 11 'password is empty') }
    if (-not $HopHost) { throw (New-V4Fault 11 'first-hop host is empty') }
}

function Get-V4Settings {
    param([switch]$StatusOnly)
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { throw (New-V4Fault 11 'settings.json missing; run with -Init first') }
    if (-not (Test-V4AclHardened -Path $script:ConfigDir -Allowed (Get-V4AllowedSidSet))) { throw (New-V4Fault 12 'config directory ACL is not hardened; re-run -Init under the lock') }
    if (-not (Test-V4AclHardened -Path $script:SettingsPath -Allowed (Get-V4AllowedSidSet))) { throw (New-V4Fault 12 'settings.json ACL is not hardened; re-run -Init under the lock') }
    try { $j = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw (New-V4Fault 11 'settings.json is not valid JSON') }
    if (-not $j -or -not $j.staticProxy -or -not $j.firstHop) { throw (New-V4Fault 11 'settings.json structure is invalid') }
    try { Assert-V4SettingsInput -Host_ $j.staticProxy.host -Port ([int]$j.staticProxy.port) -Username $j.staticProxy.username -Password 'present' -HopHost $j.firstHop.host -HopPort ([int]$j.firstHop.port) -MixedPort ([int]$j.mixedPort) }
    catch { throw (New-V4Fault 11 ('settings.json values invalid: ' + $_.Exception.Message)) }
    if (-not $j.staticProxy.passwordDpapi) { throw (New-V4Fault 11 'settings.json has no DPAPI credential') }
    if ($StatusOnly) {
        return [pscustomobject]@{
            host = $j.staticProxy.host
            hopPort = [int]$j.firstHop.port
            mixedPort = [int]$j.mixedPort
        }
    }
    try { $pw = Unprotect-V4Secret $j.staticProxy.passwordDpapi }
    catch { throw (New-V4Fault 11 'stored credential cannot be decrypted for this user') }
    Register-V4Secret $pw
    Register-V4Secret $j.staticProxy.username
    return [pscustomobject]@{
        host = $j.staticProxy.host; port = [int]$j.staticProxy.port
        username = $j.staticProxy.username; password = $pw
        hopHost = $j.firstHop.host; hopPort = [int]$j.firstHop.port
        mixedPort = [int]$j.mixedPort
    }
}

function Save-V4SettingsObject {
    param([object]$Value)
    Ensure-V4Dir $script:ConfigDir
    if (-not (Protect-V4Acl -Path $script:ConfigDir)) { throw (New-V4Fault 12 'cannot harden config directory ACL') }
    $json = $Value | ConvertTo-Json -Depth 5
    $validator = { param($f)
        $x = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $x.staticProxy.passwordDpapi) { throw 'settings.json lost its DPAPI credential' }
        if (-not $x.staticProxy.host) { throw 'settings.json lost its host' }
    }
    Set-V4Atomic -TargetPath $script:SettingsPath -Content $json -Validator $validator | Out-Null
    if (-not (Protect-V4Acl -Path $script:SettingsPath)) { throw (New-V4Fault 12 'cannot harden settings.json ACL') }
    Write-V4Log 'settings written (credential stored DPAPI-encrypted)' -Level OK
}

function Save-V4Settings {
    param([string]$Host_, [int]$Port, [string]$Username, [string]$Password, [string]$HopHost, [int]$HopPort, [int]$MixedPort)
    Assert-V4SettingsInput -Host_ $Host_ -Port $Port -Username $Username -Password $Password -HopHost $HopHost -HopPort $HopPort -MixedPort $MixedPort
    $obj = [ordered]@{
        schema = 1
        generatedBy = 'proxy_v4'
        staticProxy = [ordered]@{ host = $Host_; port = $Port; username = $Username; passwordDpapi = (Protect-V4Secret $Password) }
        firstHop = [ordered]@{ host = $HopHost; port = $HopPort }
        mixedPort = $MixedPort
    }
    Save-V4SettingsObject -Value $obj
}

# ------------------------------------------------------------------------ init --
function Get-V4YamlScalar {
    param([string]$Rest)
    $s = ([string]$Rest).Trim()
    if (-not $s) { return '' }
    $dq = [char]34
    $sq = [char]39
    $bs = [char]92
    if ($s[0] -eq $dq) {
        $sb = New-Object System.Text.StringBuilder
        $i = 1
        while ($i -lt $s.Length) {
            $ch = $s[$i]
            if ($ch -eq $bs -and ($i + 1) -lt $s.Length) {
                $n = $s[$i + 1]
                if ($n -eq 'n') { [void]$sb.Append([char]10) }
                elseif ($n -eq 'r') { [void]$sb.Append([char]13) }
                elseif ($n -eq 't') { [void]$sb.Append([char]9) }
                elseif ($n -eq '"') { [void]$sb.Append('"') }
                elseif ($n -eq '\') { [void]$sb.Append('\') }
                else { [void]$sb.Append($n) }
                $i += 2
                continue
            }
            if ($ch -eq $dq) { break }
            [void]$sb.Append($ch)
            $i++
        }
        return $sb.ToString()
    }
    if ($s[0] -eq $sq) {
        $sb = New-Object System.Text.StringBuilder
        $i = 1
        while ($i -lt $s.Length) {
            $ch = $s[$i]
            if ($ch -eq $sq) {
                if (($i + 1) -lt $s.Length -and $s[$i + 1] -eq $sq) { [void]$sb.Append($sq); $i += 2; continue }
                break
            }
            [void]$sb.Append($ch)
            $i++
        }
        return $sb.ToString()
    }
    $m = [regex]::Match($s, '^(?<v>.*?)(?:[ \t]+#.*)?$')
    return $m.Groups['v'].Value.Trim()
}

function Get-V4Socks5Candidates {
    param([string]$Text)
    if (-not $Text) { return @() }
    $blocks = [regex]::Matches($Text, '(?ms)^[ \t]*-\s+name:\s*(?<name>[^\r\n]+)(?<body>.*?)(?=^[ \t]*-\s+name:|\z)')
    $cands = @()
    foreach ($b in $blocks) {
        $body = $b.Groups['body'].Value
        $get = {
            param($k)
            $m = [regex]::Match($body, ('(?m)^\s*' + [regex]::Escape($k) + ':\s*(?<rest>[^\r\n]*)$'))
            if ($m.Success) { return (Get-V4YamlScalar $m.Groups['rest'].Value) }
            return $null
        }
        if ((& $get 'type') -ne 'socks5') { continue }
        $cands += [pscustomobject]@{
            name = $b.Groups['name'].Value.Trim()
            host = (& $get 'server')
            port = (& $get 'port')
            user = (& $get 'username')
            pass = (& $get 'password')
            dialer = (& $get 'dialer-proxy')
            udp = (& $get 'udp')
        }
    }
    return $cands
}

function Invoke-V4Init {
    param(
        [object]$Paths,
        [hashtable]$Explicit,
        [scriptblock]$Save,
        [scriptblock]$Log
    )
    $host_ = $null; $port = 0; $user = $null; $pass = $null
    $hopHost = '127.0.0.1'; $hopPort = 11119; $mixedPort = 7897
    $hasExplicit = $false
    if ($Explicit) {
        foreach ($k in @('host','port','user','pass','hopHost','hopPort','mixedPort')) {
            if ($Explicit.ContainsKey($k) -and $Explicit[$k]) { $hasExplicit = $true }
        }
        if ($Explicit.ContainsKey('hopHost') -and $Explicit['hopHost']) { $hopHost = [string]$Explicit['hopHost'] }
        if ($Explicit.ContainsKey('hopPort') -and $Explicit['hopPort']) { $hopPort = [int]$Explicit['hopPort'] }
        if ($Explicit.ContainsKey('mixedPort') -and $Explicit['mixedPort']) { $mixedPort = [int]$Explicit['mixedPort'] }
    }
    $source = ''
    if ($hasExplicit) {
        $host_ = [string]$Explicit['host']; $port = [int]$Explicit['port']
        $user = [string]$Explicit['user']; $pass = [string]$Explicit['pass']
        if (-not $host_ -or -not $user -or -not $pass) { throw (New-V4Fault 11 'explicit init requires -StaticHost, -StaticUser and -CredentialFile') }
        if ($port -eq 0) { $port = 9506 }
        $source = 'explicit parameters'
    }
    else {
        if (-not $Paths -or -not $Paths.RuntimeFile -or -not (Test-Path -LiteralPath $Paths.RuntimeFile)) { throw (New-V4Fault 11 'no clash runtime config to migrate from') }
        $t = Read-V4File $Paths.RuntimeFile
        $cands = @(Get-V4Socks5Candidates -Text $t)
        if ($cands.Count -ne 1) { throw (New-V4Fault 11 ('expected exactly 1 socks5 node, found {0}; pass -StaticHost/-StaticUser/-CredentialFile explicitly' -f $cands.Count)) }
        $c = $cands[0]
        $host_ = $c.host; $port = if ($c.port) { [int]$c.port } else { 0 }
        $user = $c.user; $pass = $c.pass
        $source = 'runtime profile migration'
    }
    Assert-V4SettingsInput -Host_ $host_ -Port $port -Username $user -Password $pass -HopHost $hopHost -HopPort $hopPort -MixedPort $mixedPort
    if (-not $Save) { throw (New-V4Fault 11 'init has no settings writer') }
    & $Save $host_ $port $user $pass $hopHost $hopPort $mixedPort
    if ($Log) { try { & $Log ('settings created from ' + $source + ' (credential length-verified only)') 'OK' } catch { } }
    return [pscustomobject]@{ source = $source; host = $host_; port = $port }
}

# ------------------------------------------------------------------------ ACL --
function Get-V4AllowedSidSet {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $list = New-Object System.Collections.ArrayList
    if ($me) { [void]$list.Add($me.Value) }
    [void]$list.Add('S-1-5-18')
    [void]$list.Add('S-1-5-32-544')
    return $list
}

function Test-V4AclHardened {
    param([string]$Path, $Allowed)
    try {
        $acl = Get-Acl -LiteralPath $Path
        if (-not $acl.AreAccessRulesProtected) { return $false }
        try {
            $ownerSid = (New-Object System.Security.Principal.NTAccount([string]$acl.Owner)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            if ($Allowed -notcontains $ownerSid) { return $false }
        } catch { return $false }
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $hasMe = $false
        foreach ($r in @($acl.Access)) {
            if ($r.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { return $false }
            $sid = $null
            try { $sid = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return $false }
            if ($Allowed -notcontains $sid) { return $false }
            $full = [System.Security.AccessControl.FileSystemRights]::FullControl
            if (($r.FileSystemRights -band $full) -ne $full) { return $false }
            if ($sid -eq $me) { $hasMe = $true }
        }
        return $hasMe
    }
    catch { return $false }
}

function Protect-V4Acl {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $allowed = Get-V4AllowedSidSet
        if (Test-V4AclHardened -Path $Path -Allowed $allowed) { return $true }   # idempotent AND verified
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if (-not $me) { return $false }
        $isDir = Test-Path -LiteralPath $Path -PathType Container
        $inherit = if ($isDir) { [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [System.Security.AccessControl.InheritanceFlags]::None }
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        foreach ($sid in $allowed) {
            try {
                $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
                [void]$acl.AddAccessRule($rule)
            } catch { }
        }
        if ($isDir) { [System.IO.Directory]::SetAccessControl($Path, $acl) }
        else { [System.IO.File]::SetAccessControl($Path, $acl) }
        return (Test-V4AclHardened -Path $Path -Allowed $allowed)
    }
    catch { return $false }
}

# ----------------------------------------------------------------------- lock --
function Get-V4ProcessStartToken {
    param([int]$ProcessId)
    try { return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') }
    catch { return $null }
}

function Remove-V4StaleLock {
    param([AllowNull()][string]$Observed)
    # Serialize stale-file removal. The lock file itself is still acquired
    # with CreateNew, so live owners and legacy lock files remain recognized.
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $pathBytes = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($script:LockPath).ToUpperInvariant())
        $name = 'Global\V4LockReap-' + [BitConverter]::ToString($sha.ComputeHash($pathBytes)).Replace('-','')
    }
    finally { $sha.Dispose() }
    $mutex = $null
    $ownsMutex = $false
    try {
        $mutex = [Threading.Mutex]::new($false, $name)
        try { $ownsMutex = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if ($ownsMutex -and (Read-V4File $script:LockPath) -ceq $Observed) {
            Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction Stop
        }
    }
    catch { }  # A busy or unreadable lock is never reaped.
    finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Enter-V4UserMutationLock {
    # HKCU proxy values are shared by all installations for a Windows user.
    # Fixture processes coordinate only within their temporary test root.
    $scope = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($script:TestMode) {
        $hash = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($script:Root.ToUpperInvariant())
            $scope = 'Test-' + [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-', '')
        } finally { $hash.Dispose() }
    }
    $mutex = [Threading.Mutex]::new($false, ('Global\V4ProxyMutation-' + $scope))
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) { return $mutex }
    } finally { if (-not $owned) { $mutex.Dispose() } }
    return $null
}

function Enter-V4Lock {
    param([int]$TimeoutSec = 20)
    Ensure-V4Dir $script:ConfigDir
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $token = [guid]::NewGuid().ToString('N')
    $startToken = Get-V4ProcessStartToken -ProcessId $PID
    $payload = [ordered]@{
        pid = $PID
        token = $token
        processStart = $startToken
        created = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress
    while ((Get-Date) -lt $deadline) {
        try {
            $fs = [System.IO.File]::Open($script:LockPath, 'CreateNew', 'Write', 'None')
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush($true)
            }
            finally { $fs.Close() }
            return [pscustomobject]@{ token = $token; path = $script:LockPath; pid = $PID }
        }
        catch {
            try { $txt = Read-V4File $script:LockPath }
            catch { Start-Sleep -Milliseconds 400; continue }
            $stale = $false
            if (-not $txt -or -not $txt.Trim()) {
                try {
                    $age = (Get-Date) - (Get-Item -LiteralPath $script:LockPath -ErrorAction Stop).LastWriteTime
                    if ($age.TotalSeconds -gt 2) { $stale = $true }
                } catch { }
            }
            elseif ($txt) {
                try {
                    $j = $txt | ConvertFrom-Json
                    if ($j.pid -and $j.token) {
                        $proc = Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue
                        if (-not $proc) { $stale = $true }
                        elseif ($j.processStart) {
                            $seenStart = Get-V4ProcessStartToken -ProcessId ([int]$j.pid)
                            if ($seenStart -and $seenStart -ne $j.processStart) { $stale = $true }
                        }
                    }
                    else { $stale = $true }
                }
                catch {
                    if ($txt -match 'pid=(\d+)') {
                        if (-not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)) { $stale = $true }
                    }
                    else {
                        try {
                            $age = (Get-Date) - (Get-Item -LiteralPath $script:LockPath -ErrorAction Stop).LastWriteTime
                            if ($age.TotalMinutes -gt 10) { $stale = $true }
                        } catch { }
                    }
                }
            }
            if ($stale) {
                Remove-V4StaleLock -Observed $txt
                if (-not (Test-Path -LiteralPath $script:LockPath)) { continue }
            }
            Start-Sleep -Milliseconds 400
        }
    }
    return $null
}

function Exit-V4Lock {
    param([object]$Token)
    if (-not $Token) { return $false }   # V6: never delete a lock we do not own
    $want = $null
    if ($Token -is [string]) { $want = $Token }
    elseif ($Token.token) { $want = [string]$Token.token }
    if (-not $want) { return $false }
    try {
        $txt = Read-V4File $script:LockPath
        if (-not $txt) { return $false }
        $j = $txt | ConvertFrom-Json
        if ([string]$j.token -ne $want) { return $false }
        $again = Read-V4File $script:LockPath
        if ($again -ne $txt) { return $false }
        Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction Stop
        return (-not (Test-Path -LiteralPath $script:LockPath))
    }
    catch { return $false }
}

# ------------------------------------------------------------- process control --
function Get-V4AppPids {
    if ($script:TestMode) { return @() }
    @(Get-Process -Name 'clash-verge','verge-mihomo' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
}

function Test-V4Port {
    param([int]$Port, [string]$Target = '127.0.0.1', [int]$TimeoutMs = 1200)
    $c = New-Object System.Net.Sockets.TcpClient
    try { $t = $c.ConnectAsync($Target, $Port); if ($t.Wait($TimeoutMs) -and $c.Connected) { return $true }; return $false }
    catch { return $false }
    finally { $c.Close() }
}

function Stop-V4Clash {
    param([int]$TimeoutSec = 25, [int]$Port = 7897)
    if ($script:TestMode) { return $true }   # test mode: never stop a real process
    Assert-V4ProductionOperation 'Stop-V4Clash'
    $pids = Get-V4AppPids
    if ($pids.Count -gt 0) {
        Write-V4Log ('stopping clash processes: ' + ($pids -join ','))
        foreach ($p in $pids) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ((Get-V4AppPids).Count -eq 0) { break }
            Start-Sleep -Milliseconds 300
        }
    }
    $left = Get-V4AppPids
    if ($left.Count -gt 0) { throw ('processes still alive after {0}s: {1}' -f $TimeoutSec, ($left -join ',')) }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-V4Port -Port $Port)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    if (Test-V4Port -Port $Port) { throw ('port {0} still listening after stopping the app' -f $Port) }
    return $true
}

function Start-V4ClashCore {
    param(
        [int]$TimeoutSec = 45,
        [int]$Port = 7897,
        [scriptblock]$IsListening,
        [scriptblock]$IsRunning,
        [scriptblock]$Launch,
        [scriptblock]$Sleep
    )
    if (& $IsListening) { return $true }
    $alreadyRunning = $false
    if ($IsRunning) { $alreadyRunning = [bool](& $IsRunning) }
    if (-not $alreadyRunning) { & $Launch }
    # S09: never spawn a duplicate instance; if the app is already up, only wait.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        & $Sleep 600
        if (& $IsListening) {
            & $Sleep 2000
            if (& $IsListening) { return $true }
        }
    }
    return $false
}

function Start-V4Clash {
    param([int]$TimeoutSec = 45, [int]$Port = 7897)
    if ($script:TestMode) {
        if ($env:V4_TEST_START_LOG) {
            try { Add-Content -LiteralPath $env:V4_TEST_START_LOG -Value ('start|' + $TimeoutSec + '|' + $Port) } catch { }
        }
        return $true   # test mode: never launch a real process
    }
    Assert-V4ProductionOperation 'Start-V4Clash'
    $p = Get-V4Paths
    if (-not $p.Exe) { throw 'clash-verge.exe not found' }
    $exe = $p.Exe
    return Start-V4ClashCore -TimeoutSec $TimeoutSec -Port $Port -IsListening { Test-V4ClashListener -Port $Port -ExpectedCore $p.Core } -IsRunning { (Get-V4AppPids).Count -gt 0 } -Launch { Start-Process -FilePath $exe | Out-Null } -Sleep { param($ms) Start-Sleep -Milliseconds $ms }
}

function Test-V4ClashListener {
    param([int]$Port, [string]$ExpectedCore, [switch]$RequireImagePath)
    if (-not $ExpectedCore) { return $false }
    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    $onLoopback = @($listeners | Where-Object LocalAddress -in @('127.0.0.1','0.0.0.0'))
    if ($RequireImagePath -and @($onLoopback.OwningProcess | Sort-Object -Unique).Count -ne 1) { return $false }
    if (-not $onLoopback -and -not $RequireImagePath) { $onLoopback = @($listeners | Where-Object LocalAddress -eq '::') }
    $expectedName = [IO.Path]::GetFileNameWithoutExtension($ExpectedCore)
    foreach ($listener in $onLoopback) {
        $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if ($process.ProcessName -eq $expectedName -and ($process.Path -eq $ExpectedCore -or (-not $RequireImagePath -and -not $process.Path))) {
            return (Test-V4Port -Port $Port)
        }
    }
    return $false
}

# ------------------------------------------------------------------- snapshot --
$script:V4RootConfigFiles = @('clash-verge.yaml','config.yaml','verge.yaml','profiles.yaml')
$script:V4ManagedProfile = 'v4-managed.yaml'
$script:V4ManagedProfileRel = 'profiles\v4-managed.yaml'

function New-V4SnapshotFiles {
    param(
        [string]$AppData,
        [string]$ProfilesDir,
        [string]$Dir,
        [object]$SystemProxy,
        [object]$ClashRunningBefore,
        [string]$Reason = 'apply'
    )
    if (-not $AppData) { throw 'clash appdata not found' }
    Ensure-V4Dir $Dir
    $profSnap = Join-Path $Dir 'profiles'
    Ensure-V4Dir $profSnap
    # C-01: harden the directory BEFORE plaintext credential-bearing files are copied in.
    if (-not (Protect-V4Acl -Path $Dir)) { throw 'cannot harden snapshot directory ACL before copy' }
    $files = @()
    $absent = @()
    foreach ($f in $script:V4RootConfigFiles) {
        $src = Join-Path $AppData $f
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path $Dir $f
            $srcHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $src -Destination $dst -Force
            $dstHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
            if ($srcHash -ne $dstHash) { throw ('snapshot copy mismatch: ' + $f) }
            $files += [pscustomobject]@{ name = $f; sha256 = $dstHash; bytes = (Get-Item -LiteralPath $dst).Length }
        }
        else { $absent += $f }
    }
    $managedSeen = $false
    if (Test-Path -LiteralPath $ProfilesDir) {
        foreach ($fi in @(Get-ChildItem -LiteralPath $ProfilesDir -File -Filter '*.yaml' -ErrorAction SilentlyContinue)) {
            if ($fi.Name -eq $script:V4ManagedProfile) { $managedSeen = $true }
            $rel = Join-Path 'profiles' $fi.Name
            $dst = Join-Path $profSnap $fi.Name
            $srcHash = (Get-FileHash -LiteralPath $fi.FullName -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $fi.FullName -Destination $dst -Force
            $dstHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
            if ($srcHash -ne $dstHash) { throw ('snapshot copy mismatch: ' + $rel) }
            $files += [pscustomobject]@{ name = $rel; sha256 = $dstHash; bytes = (Get-Item -LiteralPath $dst).Length }
        }
    }
    if (-not $managedSeen) { $absent += $script:V4ManagedProfileRel }
    $manifest = [ordered]@{
        schema = 2
        createdAt = (Get-Date).ToString('s')
        reason = $Reason
        systemProxy = $SystemProxy
        clashRunningBefore = $ClashRunningBefore
        files = $files
        absent = $absent
    }
    $mp = Join-Path $Dir 'manifest.json'
    Write-V4File -Path $mp -Content ($manifest | ConvertTo-Json -Depth 7)
    return [pscustomobject]@{ dir = $Dir; manifest = $manifest; files = $files; absent = $absent }
}

function New-V4Snapshot {
    param([string]$Reason = 'apply', [int]$Port = 7897)
    $p = Get-V4Paths
    if (-not $p.AppData) { throw 'clash appdata not found' }
    Ensure-V4Dir $script:BackupDir
    if (-not (Protect-V4Acl -Path $script:BackupDir)) { throw 'cannot harden backup root ACL' }
    $beforeProxy = Get-V4SystemProxy
    $wasRunning = ((Get-V4AppPids).Count -gt 0)
    if ($wasRunning) { Stop-V4Clash -Port $Port | Out-Null }
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $dir = Join-Path $script:BackupDir $stamp
    try {
        $r = New-V4SnapshotFiles -AppData $p.AppData -ProfilesDir $p.ProfilesDir -Dir $dir -SystemProxy $beforeProxy -ClashRunningBefore $wasRunning -Reason $Reason
        return $r.dir
    }
    catch {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Test-V4SnapshotManifest {
    param([string]$SnapshotDir)
    if (-not $SnapshotDir) { throw 'snapshot directory is empty' }
    $mp = Join-Path $SnapshotDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $mp)) { throw ('snapshot manifest missing: ' + $SnapshotDir) }
    try { $m = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw 'snapshot manifest is not valid JSON' }
    $entries = @()
    $names = @()
    foreach ($e in @($m.files)) {
        if (-not $e -or -not $e.name -or -not $e.sha256) { throw 'snapshot manifest has an incomplete file entry' }
        $name = ([string]$e.name).Replace('/', '\')
        $parts = $name.Split([char[]]@('\','/'), [System.StringSplitOptions]::RemoveEmptyEntries)
        $okRoot = ($script:V4RootConfigFiles -contains $name)
        $okProfile = ($parts.Length -eq 2 -and $parts[0] -eq 'profiles' -and $parts[1].EndsWith('.yaml'))
        if (-not ($okRoot -or $okProfile)) { throw ('snapshot manifest has an unsafe path: ' + $name) }
        if ($names -contains $name) { throw ('snapshot manifest has a duplicate entry: ' + $name) }
        $src = Join-Path $SnapshotDir $name
        if (-not (Test-Path -LiteralPath $src)) { throw ('snapshot incomplete: missing ' + $name) }
        $hash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        if ($hash.ToLowerInvariant() -ne ([string]$e.sha256).ToLowerInvariant()) { throw ('snapshot hash mismatch: ' + $name) }
        $names += $name
        $entries += [pscustomobject]@{ name = $name; sha256 = $hash }
    }
    $absent = @()
    foreach ($a in @($m.absent)) {
        if (-not $a) { continue }
        $name = ([string]$a).Replace('/', '\')
        $parts = $name.Split([char[]]@('\','/'), [System.StringSplitOptions]::RemoveEmptyEntries)
        $okRoot = ($script:V4RootConfigFiles -contains $name)
        $okProfile = ($parts.Length -eq 2 -and $parts[0] -eq 'profiles' -and $parts[1].EndsWith('.yaml'))
        if (-not ($okRoot -or $okProfile)) { throw ('snapshot manifest has an unsafe absent path: ' + $name) }
        if ($names -contains $name) { throw ('snapshot manifest lists a file as both present and absent: ' + $name) }
        if ($absent -contains $name) { throw ('snapshot manifest has a duplicate absent entry: ' + $name) }
        $absent += $name
    }
    if ($entries.Count -eq 0) { throw 'snapshot manifest has no files' }
    if (-not (($names -contains 'profiles.yaml') -or ($absent -contains 'profiles.yaml'))) { throw 'snapshot manifest does not cover profiles.yaml' }
    return [pscustomobject]@{ manifest = $m; entries = $entries; absent = $absent }
}

function Get-V4SnapshotTarget {
    param([string]$Name, [string]$AppData, [string]$ProfilesDir)
    $name = $Name.Replace('/', '\')
    $parts = $name.Split([char[]]@('\','/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Length -eq 2 -and $parts[0] -eq 'profiles') { return (Join-Path $ProfilesDir $parts[1]) }
    return (Join-Path $AppData $name)
}

function Restore-V4Files {
    param([string]$SnapshotDir, [string]$AppData, [string]$ProfilesDir)
    $v = Test-V4SnapshotManifest -SnapshotDir $SnapshotDir
    $restored = @()
    $failures = @()
    foreach ($e in $v.entries) {
        $target = Get-V4SnapshotTarget -Name $e.name -AppData $AppData -ProfilesDir $ProfilesDir
        try {
            $content = [System.IO.File]::ReadAllBytes((Join-Path $SnapshotDir $e.name))
            $expected = $e.sha256
            $validator = ({ param($f) if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected.ToLowerInvariant()) { throw 'restored hash mismatch' } }).GetNewClosure()
            Set-V4Atomic -TargetPath $target -Bytes $content -Validator $validator | Out-Null
            if (-not (Protect-V4Acl -Path $target)) { throw 'restored file ACL could not be hardened' }
            $restored += $e.name
        }
        catch { $failures += [pscustomobject]@{ name = $e.name; error = $_.Exception.Message } }
    }
    foreach ($name in $v.absent) {
        $target = Get-V4SnapshotTarget -Name $name -AppData $AppData -ProfilesDir $ProfilesDir
        try {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
            $restored += ('absent:' + $name)
        }
        catch { $failures += [pscustomobject]@{ name = $name; error = $_.Exception.Message } }
    }
    return [pscustomobject]@{ ok = ($failures.Count -eq 0); manifest = $v.manifest; restored = $restored; failures = $failures }
}

function Restore-V4Snapshot {
    param([string]$SnapshotDir, [int]$Port = 7897, [switch]$NoProcessControl)
    $p = Get-V4Paths
    if (-not $p.AppData) { throw 'clash appdata not found' }
    Test-V4SnapshotManifest -SnapshotDir $SnapshotDir | Out-Null   # refuse before touching anything
    if (-not $NoProcessControl -and (Get-V4AppPids).Count -gt 0) { Stop-V4Clash -Port $Port | Out-Null }
    $r = Restore-V4Files -SnapshotDir $SnapshotDir -AppData $p.AppData -ProfilesDir $p.ProfilesDir
    if (-not $r.ok) {
        $detail = ($r.failures | ForEach-Object { $_.name + ': ' + $_.error }) -join '; '
        throw ('snapshot restore incomplete: ' + $detail)
    }
    return $r.manifest
}

# ---------------------------------------------------------------- atomic write --
function Set-V4Atomic {
    param([string]$TargetPath, [string]$Content, [scriptblock]$Validator, [byte[]]$Bytes)
    $dir = Split-Path -Parent $TargetPath
    Ensure-V4Dir $dir
    $tmp = Join-Path $dir ('.v4stage-' + [guid]::NewGuid().ToString('N').Substring(0,10) + '.tmp')
    $bak = '{0}.{1}.bak' -f $TargetPath, [guid]::NewGuid().ToString('N').Substring(0,10)
    try {
        if ($PSBoundParameters.ContainsKey('Bytes')) { [IO.File]::WriteAllBytes($tmp, $Bytes) }
        else { Write-V4File -Path $tmp -Content $Content }
        if ($Validator) { & $Validator $tmp }
        if (Test-Path -LiteralPath $TargetPath) {
            [System.IO.File]::Replace($tmp, $TargetPath, $bak, $true)
        }
        else {
            [System.IO.File]::Move($tmp, $TargetPath)
        }
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
        return $true
    }
    catch {
        $original = $_.Exception.Message
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $bak) {
            try {
                if (Test-Path -LiteralPath $TargetPath) { [System.IO.File]::Replace($bak, $TargetPath, $null, $true) }
                else { [System.IO.File]::Move($bak, $TargetPath) }
            }
            catch {
                throw ('atomic write failed: ' + $original + '; backup restore failed: ' + $_.Exception.Message)
            }
        }
        throw
    }
}

function Test-V4MihomoConfig {
    param([string]$ConfigPath, [string]$WorkDir)
    $p = Get-V4Paths
    if (-not $p.Core) { throw 'mihomo core not found' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $p.Core -t -f $ConfigPath -d $WorkDir 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw ('mihomo -t failed (exit {0})' -f $code) }
    return $true
}

# -------------------------------------------------------------------- proxies --
function Get-V4SystemProxy {
    if ($script:TestMode) {
        $enabled = $env:V4_TEST_PROXY_ENABLE -eq '1'
        return [pscustomobject]@{ enabled = $enabled; server = $env:V4_TEST_PROXY_SERVER }
    }
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $v = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
    # Only the native DWORD 1 confirms the user enabled this proxy.
    return [pscustomobject]@{ enabled = ($v.ProxyEnable -is [int] -and $v.ProxyEnable -eq 1); server = $v.ProxyServer }
}

function Get-V4AutomaticProxyStatus {
    if ($script:TestMode) { return 'NOT_OBSERVED' }
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $settings = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        if ($settings.PSObject.Properties['AutoConfigURL'] -and
            -not [string]::IsNullOrWhiteSpace($settings.AutoConfigURL)) { return 'PRESENT' }
        $connections = Get-ItemProperty -LiteralPath "$key\Connections" -ErrorAction Stop
        if (-not $connections.PSObject.Properties['DefaultConnectionSettings']) { return 'UNKNOWN' }
        $bytes = $connections.DefaultConnectionSettings
        if ($bytes -isnot [byte[]] -or $bytes.Length -lt 12) { return 'UNKNOWN' }
        # Default connection flags: 0x04 is an automatic URL and 0x08 is auto-detect.
        $flags = [BitConverter]::ToUInt32($bytes, 8)
        if ($flags -band 12) { return 'PRESENT' }
        if (-not $flags -or ($flags -band 15) -ne $flags) { return 'UNKNOWN' }
        return 'NOT_OBSERVED'
    } catch { return 'UNKNOWN' }
}

function Test-V4SystemProxyMatch {
    param($Expected, $Actual)
    if ($null -eq $Expected -or $null -eq $Actual -or [bool]$Expected.enabled -ne [bool]$Actual.enabled) { return $false }
    return (-not $Expected.enabled -or $Expected.server -eq $Actual.server)
}

function Write-V4SystemProxyRegistry {
    param([bool]$Enabled, [string]$Server)
    if ($script:TestMode) {
        if (-not $script:TestRegistryWriter) { throw 'V4 test mode blocks a real system-proxy write and no test registry writer is installed' }
        & $script:TestRegistryWriter $Enabled $Server
        return
    }
    Assert-V4ProductionOperation 'system proxy registry write'
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $old = Get-ItemProperty $k -ErrorAction SilentlyContinue
    $oldServer = $old.ProxyServer
    $oldEnable = $old.ProxyEnable
    try {
        Set-ItemProperty $k -Name ProxyServer -Value $Server
        Set-ItemProperty $k -Name ProxyEnable -Value $(if ($Enabled) { 1 } else { 0 })
        Update-V4WinInet
    }
    catch {
        try {
            Set-ItemProperty $k -Name ProxyServer -Value $oldServer
            Set-ItemProperty $k -Name ProxyEnable -Value $oldEnable
            Update-V4WinInet
        } catch { }
        throw
    }
}

function Set-V4SystemProxy {
    param([string]$Server)
    Write-V4SystemProxyRegistry -Enabled $true -Server $Server
}

function Clear-V4SystemProxy {
    Write-V4SystemProxyRegistry -Enabled $false -Server ((Get-V4SystemProxy).server)
}

function Set-V4RepairServer {
    param([string]$ExpectedServer, [string]$NewServer, [ref]$WriteAttempted)
    $current = Get-V4SystemProxy
    if (-not $current.enabled -or $current.server -ne $ExpectedServer) {
        throw (New-V4Fault 32 'Windows proxy selection changed before the write')
    }
    if ($script:TestMode) {
        $current = Get-V4SystemProxy
        if (-not $current.enabled -or $current.server -ne $ExpectedServer) {
            throw (New-V4Fault 32 'Windows proxy selection changed before the write')
        }
        if (-not $script:TestRegistryWriter) { throw 'isolated repair writer is missing' }
        if ($WriteAttempted) { $WriteAttempted.Value = $true }
        & $script:TestRegistryWriter $current.enabled $NewServer
        return
    }
    Assert-V4ProductionOperation 'repair enabled proxy target'
    # Never re-enable the proxy, even if a user disables it during this call.
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($WriteAttempted) { $WriteAttempted.Value = $true }
    Set-ItemProperty -LiteralPath $key -Name ProxyServer -Value $NewServer -ErrorAction Stop
    Update-V4WinInet -RequireSuccess
}

function Update-V4WinInet {
    param([switch]$RequireSuccess)
    if (-not ('V4Inet.Refresh' -as [type])) {
        Add-Type -MemberDefinition '[DllImport("wininet.dll",SetLastError=true)]public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);' -Name Refresh -Namespace V4Inet | Out-Null
    }
    $changed = [V4Inet.Refresh]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    $refreshed = [V4Inet.Refresh]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    if ($RequireSuccess -and (-not $changed -or -not $refreshed)) {
        throw 'Windows could not confirm notification of the proxy change'
    }
}

function Get-V4ExitIp {
    param([string]$Proxy = '', [int]$TimeoutSec = 20)
    if ($script:TestMode) { return $null }
    foreach ($t in @('https://api.ipify.org','https://ifconfig.me/ip','https://icanhazip.com')) {
        $a = @('-q','-fsS','-m',"$TimeoutSec")
        if ($Proxy) { $a += @('-x',$Proxy,'--noproxy','no-match.invalid') } else { $a += @('--noproxy','*') }
        $a += $t
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = & curl.exe @a 2>&1; $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
        if ($rc -ne 0) { continue }
        $txt = ($out -join '').Trim()
        [ipaddress]$address = $null
        if ($txt -match '^\d{1,3}(\.\d{1,3}){3}$' -and [ipaddress]::TryParse($txt, [ref]$address)) {
            return $address.ToString()
        }
    }
    return $null
}

function Test-V4FirstHop {
    param([int]$Port, [ValidateRange(1, 60000)][int]$TimeoutMs = 6000)
    $c = New-Object System.Net.Sockets.TcpClient
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $stage = 'TCP'
    try {
        if (-not $c.ConnectAsync('127.0.0.1', $Port).Wait($TimeoutMs)) {
            return [pscustomobject]@{ ok=$false; status='TCP_UNAVAILABLE'; detail="loopback port $Port connection timed out" }
        }
        $stage = 'CONNECT'
        $s = $c.GetStream()
        $s.WriteTimeout = [int][Math]::Max(1, $TimeoutMs - $clock.ElapsedMilliseconds)
        $b = [System.Text.Encoding]::ASCII.GetBytes("CONNECT api.ipify.org:443 HTTP/1.1`r`nHost: api.ipify.org:443`r`n`r`n")
        $s.Write($b, 0, $b.Length)
        $reply = New-Object System.Text.StringBuilder
        $buf = New-Object byte[] 256
        while ($reply.Length -lt 1024) {
            $remaining = $TimeoutMs - $clock.ElapsedMilliseconds
            if ($remaining -le 0) {
                return [pscustomobject]@{ ok=$false; status='CONNECT_TIMEOUT'; detail='timed out waiting for the CONNECT status line' }
            }
            $s.ReadTimeout = [int]$remaining
            $n = $s.Read($buf, 0, $buf.Length)
            if ($n -eq 0) {
                return [pscustomobject]@{ ok=$false; status='INCOMPLETE_REPLY'; detail='closed before a complete CONNECT status line' }
            }
            [void]$reply.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
            $text = $reply.ToString()
            $end = $text.IndexOf("`r`n", [StringComparison]::Ordinal)
            if ($end -lt 0) { continue }
            if ($end -ge 1024 -or $text.Substring(0, $end) -notmatch '^HTTP/\d\.\d[ \t]+(?<status>[1-5][0-9]{2})(?:[ \t]|$)') { break }
            $status = [int]$Matches.status
            return [pscustomobject]@{
                ok = ($status -eq 200)
                status = $(if ($status -eq 200) { 'CONNECT_OK' } else { 'CONNECT_REFUSED' })
                detail = ('HTTP CONNECT ' + $status)
            }
        }
        return [pscustomobject]@{ ok=$false; status='INVALID_REPLY'; detail='invalid or overlong CONNECT status line' }
    }
    catch {
        if ($stage -eq 'TCP') { return [pscustomobject]@{ ok=$false; status='TCP_UNAVAILABLE'; detail="cannot connect to loopback port $Port" } }
        $errorCause = $_.Exception.GetBaseException()
        if ($clock.ElapsedMilliseconds -ge $TimeoutMs -or
            ($errorCause -is [Net.Sockets.SocketException] -and $errorCause.SocketErrorCode -eq 'TimedOut')) {
            return [pscustomobject]@{ ok=$false; status='CONNECT_TIMEOUT'; detail='timed out exchanging the CONNECT request' }
        }
        return [pscustomobject]@{ ok=$false; status='CONNECT_IO_ERROR'; detail='I/O error exchanging the CONNECT request' }
    }
    finally { $c.Close() }
}

# --------------------------------------------------------------------- owner --
function Get-V4Owner {
    if (-not (Test-Path $script:OwnerPath)) { return $null }
    try { return (Get-Content $script:OwnerPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-V4OwnerText {
    if (Test-Path -LiteralPath $script:OwnerPath) { return (Read-V4File $script:OwnerPath) }
    return $null
}

function Restore-V4OwnerText {
    param([object]$Text)
    if ($null -eq $Text) {
        Remove-Item -LiteralPath $script:OwnerPath -Force -ErrorAction SilentlyContinue
        return
    }
    Ensure-V4Dir $script:ConfigDir
    Set-V4Atomic -TargetPath $script:OwnerPath -Content ([string]$Text) | Out-Null
}

function Set-V4Owner {
    param([string]$Owner, [string]$SystemProxy, [string]$Note = '')
    $o = [ordered]@{ owner = $Owner; systemProxy = $SystemProxy; note = $Note; pid = $PID; updatedAt = (Get-Date).ToString('s') }
    Ensure-V4Dir $script:ConfigDir
    Set-V4Atomic -TargetPath $script:OwnerPath -Content ($o | ConvertTo-Json -Depth 4) | Out-Null
}

# ------------------------------------------------------- profile registry text --
# F08: parse the registry as top-level list items. The old IndexOf+global-regex
# approach could edit the NEXT profile when our own block had no updated field,
# and could select a similar UID (V4Mngd00010) by prefix.
function Get-V4ProfileLines {
    param([string]$Text)
    $cr = [string][char]13
    $lf = [string][char]10
    $crlf = $cr + $lf
    $nl = if ($Text.Contains($crlf)) { $crlf } else { $lf }
    $norm = $Text.Replace($crlf, $lf).Replace($cr, $lf)
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in $norm.Split([char]10)) { [void]$lines.Add($l) }
    return [pscustomobject]@{ lines = $lines; nl = $nl }
}

function Get-V4ProfileBlock {
    param([object]$Lines, [string]$Uid)
    $esc = [regex]::Escape($Uid)
    $rxStart = '^-[ \t]+uid:[ \t]*"?' + $esc + '"?[ \t]*$'
    $starts = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match $rxStart) { $starts += $i } }
    if ($starts.Count -gt 1) { throw ('duplicate profile uid in profiles.yaml: ' + $Uid) }
    if ($starts.Count -eq 0) { return $null }
    $s = $starts[0]
    $e = $Lines.Count
    for ($i = $s + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^[^\s]') { $e = $i; break }
    }
    return [pscustomobject]@{ start = $s; end = $e }
}

function Update-V4ProfileText {
    param([string]$Text, [string]$Uid, [int]$Epoch)
    if (-not $Text) { throw 'profiles.yaml unreadable' }
    if (-not $Uid -or $Uid -notmatch '^[A-Za-z0-9._-]+$') { throw 'invalid profile uid' }
    $parsed = Get-V4ProfileLines -Text $Text
    $lines = $parsed.lines
    $nl = $parsed.nl
    $esc = [regex]::Escape($Uid)

    $currentCount = 0
    $currentIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^current:[ \t]*\S') { $currentCount++; $currentIndex = $i }
    }
    if ($currentCount -ne 1) { throw ('profiles.yaml must contain exactly one current entry (found ' + $currentCount + ')') }

    $block = Get-V4ProfileBlock -Lines $lines -Uid $Uid
    if (-not $block) {
        # Refuse to append when the uid appears in a non-list-item position: that is
        # an ambiguous/invalid structure, not a missing profile.
        if ($lines -match ('^[ \t]*uid:[ \t]*"?' + $esc + '"?[ \t]*$')) { throw ('uid ' + $Uid + ' exists but is not a top-level profile list item') }
        while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
        [void]$lines.Add('- uid: ' + $Uid)
        [void]$lines.Add('  type: local')
        [void]$lines.Add('  name: V4-Managed')
        [void]$lines.Add('  file: v4-managed.yaml')
        [void]$lines.Add('  updated: ' + $Epoch)
        $block = Get-V4ProfileBlock -Lines $lines -Uid $Uid
        if (-not $block) { throw 'failed to append managed profile block' }
    }

    $updIndex = -1
    $indent = '  '
    for ($i = $block.start + 1; $i -lt $block.end; $i++) {
        $line = $lines[$i]
        $mIndent = [regex]::Match($line, '^(?<indent>[ \t]+)\S')
        if ($mIndent.Success -and $indent -eq '  ') { $indent = $mIndent.Groups['indent'].Value }
        if ($line -match '^[ \t]+updated:[ \t]*') {
            if ($updIndex -ge 0) { throw ('profile ' + $Uid + ' has multiple updated fields') }
            $updIndex = $i
        }
    }
    if ($updIndex -ge 0) {
        $line = $lines[$updIndex]
        $m = [regex]::Match($line, '^(?<prefix>[ \t]+updated:[ \t]*)(?<rest>.*)$')
        $rest = $m.Groups['rest'].Value
        $hash = $rest.IndexOf('#')
        $comment = ''
        if ($hash -ge 0) { $comment = ' ' + $rest.Substring($hash).TrimStart() }
        $lines[$updIndex] = $m.Groups['prefix'].Value + $Epoch + $comment
    }
    else {
        $insertAt = $block.end
        while ($insertAt -gt $block.start + 1 -and $lines[$insertAt - 1] -eq '') { $insertAt-- }
        $lines.Insert($insertAt, ($indent + 'updated: ' + $Epoch))
    }

    $curAfter = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^current:[ \t]*\S') { $curAfter = $i } }
    if ($curAfter -lt 0) { throw 'profiles.yaml lost its current entry during update' }
    $lines[$curAfter] = 'current: ' + $Uid
    $out = ($lines -join $nl)
    if (-not $out.EndsWith($nl)) { $out += $nl }
    return $out
}

function Test-V4ProfileText {
    param([string]$Text, [string]$Uid)
    if (-not $Text) { throw 'profiles.yaml is empty' }
    $parsed = Get-V4ProfileLines -Text $Text
    $lines = $parsed.lines
    $cur = @()
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^(current:[ \t]*)(\S+)') { $cur += [pscustomobject]@{ index = $i; value = $Matches[2] } } }
    if ($cur.Count -ne 1) { throw 'profiles.yaml must contain exactly one current entry' }
    if ($cur[0].value -ne $Uid) { throw ('profiles.yaml current is ' + $cur[0].value + ', expected ' + $Uid) }
    $block = Get-V4ProfileBlock -Lines $lines -Uid $Uid
    if (-not $block) { throw ('managed profile uid missing: ' + $Uid) }
    $updated = @()
    for ($i = $block.start + 1; $i -lt $block.end; $i++) {
        if ($lines[$i] -match '^[ \t]+updated:[ \t]*(\d+)([ \t]*#.*)?$') { $updated += $Matches[1] }
    }
    if ($updated.Count -ne 1) { throw ('managed profile must have exactly one numeric updated field (found ' + $updated.Count + ')') }
    return $true
}

# ------------------------------------------------------------------ generation --
function ConvertTo-V4YamlDoubleQuoted {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $bs = [string][char]92
    $v = $Value.Replace($bs, ($bs + $bs))
    $v = $v.Replace('"', ('\' + '"'))
    $v = $v.Replace([string][char]13, '\r')
    $v = $v.Replace([string][char]10, '\n')
    $v = $v.Replace([string][char]9, '\t')
    return ('"' + $v + '"')
}

function Build-V4Profile {
    param([object]$S, [string]$Mode = 'strict')
    $hopYaml = ConvertTo-V4YamlDoubleQuoted ([string]$S.hopHost)
    $userYaml = ConvertTo-V4YamlDoubleQuoted ([string]$S.username)
    $passYaml = ConvertTo-V4YamlDoubleQuoted ([string]$S.password)
    $group = if ($Mode -eq 'resilient') {
@"
proxy-groups:
  - name: "PROXY"
    type: fallback
    url: "http://www.gstatic.com/generate_204"
    interval: 300
    lazy: true
    timeout: 5000
    proxies:
      - "US-WA-SOCKS5"
      - "DIRECT"
"@
    } else {
@"
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "US-WA-SOCKS5"
"@
    }
@"
$($script:Marker)
# generated $(Get-Date -Format 's')
mixed-port: $($S.mixedPort)
allow-lan: false
mode: rule
log-level: info
ipv6: false
unified-delay: true
find-process-mode: "off"
tcp-concurrent: true

proxies:
  - name: "STAR-FIRSTHOP"
    type: http
    server: $hopYaml
    port: $($S.hopPort)
  - name: "US-WA-SOCKS5"
    type: socks5
    server: $($S.host)
    port: $($S.port)
    username: $userYaml
    password: $passYaml
    udp: false
    dialer-proxy: "STAR-FIRSTHOP"

$group
rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
"@
}

function Build-V4Runtime {
    param([object]$S, [string]$Mode = 'strict', [string]$Pipe, [string]$Secret)
    $pipeYaml = ConvertTo-V4YamlDoubleQuoted ([string]$Pipe)
    $secretYaml = ConvertTo-V4YamlDoubleQuoted ([string]$Secret)
    $profile = Build-V4Profile -S $S -Mode $Mode
    # keep everything from `proxies:` onward (proxies + groups + rules); the runtime
    # header below replaces the profile-only preamble
    $idx = $profile.IndexOf('proxies:')
    if ($idx -lt 0) { throw 'generated profile has no proxies section' }
    $groupPart = $profile.Substring($idx)
    @"
$($script:Marker)
mode: rule
mixed-port: $($S.mixedPort)
allow-lan: false
log-level: info
ipv6: false
unified-delay: true
find-process-mode: "off"
tcp-concurrent: true
secret: $secretYaml
profile:
  store-selected: true
external-controller-pipe: $pipeYaml
tun:
  enable: false
  stack: mips
  auto-route: true
  strict-route: false
  auto-detect-interface: true
  dns-hijack:
  - any:53
$groupPart
"@
}

function Get-V4Controller {
    $p = Get-V4Paths
    $pipe = $null; $secret = $null
    if (-not $script:TestMode) {
        $mih = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('verge-mihomo.exe','mihomo.exe') } | Select-Object -First 1
        if ($mih -and $mih.CommandLine -match '-ext-ctl-pipe\s+"?([^"]+)"?') { $pipe = $Matches[1].Trim() }
    }
    if ($p.RuntimeFile) {
        $t = Read-V4File $p.RuntimeFile
        if ($t) {
            if (-not $pipe -and $t -match '(?m)^external-controller-pipe:\s*(.+?)\s*$') { $pipe = $Matches[1] }
            if ($t -match '(?m)^secret:\s*(.+?)\s*$') { $secret = $Matches[1] }
        }
    }
    if (-not $secret) { $secret = 'set-your-secret' }
    Register-V4Secret $secret
    return [pscustomobject]@{ pipe = $pipe; secret = $secret }
}

# -------------------------------------------------------------------- state ----
function Read-V4UiSystemProxyFile {
    param([string]$Path)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
        $t = Read-V4File $Path
        if ($t -and $t -match '(?m)^enable_system_proxy:\s*(true|false)') { return ($Matches[1] -eq 'true') }
    } catch { }
    return $null
}

function Get-V4UiSystemProxy {
    if ($script:TestMode) {
        if ($env:V4_TEST_UI_CONFIG) { return (Read-V4UiSystemProxyFile -Path $env:V4_TEST_UI_CONFIG) }
        if ($env:V4_TEST_UI_SYSTEM_PROXY -eq '1') { return $true }
        if ($env:V4_TEST_UI_SYSTEM_PROXY -eq '0') { return $false }
        return $null
    }
    $f = Join-Path (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev') 'verge.yaml'
    return (Read-V4UiSystemProxyFile -Path $f)
}

function Get-V4UdpProxied {
    try {
        $p = Get-V4Paths
        if (-not $p.RuntimeFile -or -not (Test-Path -LiteralPath $p.RuntimeFile)) { return $null }
        $t = Read-V4File $p.RuntimeFile
        if (-not $t) { return $null }
        $section = [regex]::Match($t, '(?ms)^proxies:[ \t]*\r?$\n(?<items>.*?)(?=^[A-Za-z_][\w-]*[ \t]*:|\z)')
        if (-not $section.Success) { return $null }
        $managed = @(Get-V4Socks5Candidates $section.Groups['items'].Value | Where-Object {
            (Get-V4YamlScalar $_.name) -eq 'US-WA-SOCKS5' -and $_.dialer -eq 'STAR-FIRSTHOP'
        })
        if ($managed.Count -eq 1 -and $managed[0].udp -in @('true', 'false')) {
            return ($managed[0].udp -eq 'true')
        }
    } catch { }
    return $null
}

function Get-V4StateCore {
    param(
        [object]$Settings,
        [object]$Owner,
        [object]$SystemProxy,
        [object]$AppPids,
        [bool]$MixedPortOpen,
        [object]$FirstHop,
        [scriptblock]$GetExitIp,
        [string]$SettingsError = '',
        [object]$UiSystemProxy = $null,
        [object]$UdpProxied = $null,
        [ValidateSet('NOT_OBSERVED','PRESENT','UNKNOWN')][string]$AutomaticProxyStatus = 'UNKNOWN'
    )
    $out = [ordered]@{
        ts = (Get-Date).ToString('s')
        state = 'UNKNOWN'; mode = 'UNKNOWN'; reasons = @(); faults = @()
        clashRunning = (@($AppPids | Where-Object { $_ -gt 0 }).Count -gt 0)
        mixedPort = [bool]$MixedPortOpen
        systemProxy = $(if ($null -eq $SystemProxy) { 'unknown' } elseif ($SystemProxy.enabled) { Get-V4Redacted $SystemProxy.server } else { 'off' })
        owner = $(if ($Owner) { $Owner.owner } else { 'none' })
        firstHopOk = $false
        firstHopStatus = 'NOT_PROBED'
        exitViaChain = $null
        chainStatus = 'NOT_PROBED'
        windowsTargetsClash = $false
        windowsTargetsFirstHop = $false
        automaticProxy = $AutomaticProxyStatus
        applicationPath = 'NOT_TESTED'
        uiSystemProxy = $(if ($null -eq $UiSystemProxy) { 'unknown' } elseif ($UiSystemProxy) { 'enabled' } else { 'disabled' })
        udpProxied = $(if ($null -eq $UdpProxied) { 'unknown' } elseif ($UdpProxied) { 'enabled' } else { 'disabled' })
        udpDataPlane = 'not_probed'
        pathScope = $(if ($UdpProxied -eq $false) { 'TCP_ONLY' } else { 'UNKNOWN' })
        warnings = @()
    }
    $actualProxyEnabled = [bool]($SystemProxy -and $SystemProxy.enabled)
    $uiMismatch = ($null -ne $SystemProxy -and $null -ne $UiSystemProxy -and [bool]$UiSystemProxy -ne $actualProxyEnabled)
    if ($uiMismatch) {
        $out.faults += 'PROXY_INTENT_MISMATCH'
        $out.reasons += ('UI reports system proxy ' + $(if ($UiSystemProxy) { 'enabled' } else { 'disabled' }) + ', actual HKCU is ' + $(if ($actualProxyEnabled) { 'enabled' } else { 'disabled' }))
    }
    if ($UdpProxied -eq $false) {
        $out.warnings += 'The managed SOCKS5 node has udp=false. Browser WebRTC may use another path.'
    } elseif ($UdpProxied -eq $true) {
        $out.warnings += 'The managed SOCKS5 node has udp=true. UDP relay and browser coverage require separate measurements.'
    }
    if ($SettingsError) {
        $out.state = 'FAILED'; $out.mode = 'UNKNOWN'
        $out.faults += 'SETTINGS_UNAVAILABLE'
        $out.reasons += ('settings invalid: ' + $SettingsError)
        return $out
    }
    if (-not $Settings) {
        $out.state = 'FAILED'; $out.mode = 'UNKNOWN'
        $out.faults += 'SETTINGS_UNAVAILABLE'
        $out.reasons += 'settings.json missing'
        return $out
    }
    $expectedProxy = '127.0.0.1:' + $Settings.mixedPort
    $out.windowsTargetsClash = ($actualProxyEnabled -and $SystemProxy.server -eq $expectedProxy)
    $out.windowsTargetsFirstHop = ($actualProxyEnabled -and $SystemProxy.server -eq ('127.0.0.1:' + $Settings.hopPort))
    if ($null -eq $SystemProxy) {
        $out.faults += 'SYSTEM_PROXY_UNVERIFIED'
        $out.reasons += 'Windows proxy state could not be read'
    } elseif (-not $out.windowsTargetsClash) {
        $out.faults += 'SYSTEM_PROXY_DRIFT'
        $out.reasons += ('Windows proxy is ' + $out.systemProxy + '; expected ' + $expectedProxy)
    }
    if ($AutomaticProxyStatus -ne 'NOT_OBSERVED') {
        $out.faults += 'AUTOMATIC_PROXY_UNVERIFIED'
        $out.reasons += 'Default LAN automatic proxy is present or could not be read.'
    }
    if ($null -eq $UiSystemProxy) {
        $out.faults += 'CLIENT_INTENT_UNVERIFIED'
        $out.reasons += 'Saved client proxy mode could not be read.'
    }
    if ($FirstHop) {
        $out.firstHopOk = [bool]$FirstHop.ok
        $out.firstHopStatus = if ($FirstHop.PSObject.Properties['status']) { $FirstHop.status }
            elseif ($out.firstHopOk) { 'CONNECT_OK' } else { 'UNAVAILABLE' }
        if (-not $out.firstHopOk) {
            $out.faults += $(if ($out.firstHopStatus -eq 'TCP_UNAVAILABLE') { 'FIRST_HOP_TCP_UNAVAILABLE' } else { 'FIRST_HOP_CONNECT_FAILED' })
            $out.reasons += ('first-hop check failed: ' + $FirstHop.detail)
        }
    }
    else { $out.faults += 'FIRST_HOP_NOT_VERIFIED'; $out.reasons += 'first hop probe unavailable' }
    if (-not $out.clashRunning) {
        $out.mode = 'RAW'; $out.state = 'FAILED'; $out.faults += 'CLASH_PROCESS_NOT_OBSERVED'
        $out.reasons += 'no Clash application or core process observed'
    }
    elseif (-not $out.mixedPort) {
        $out.mode = 'NEXIP'; $out.state = 'FAILED'; $out.faults += 'CORE_LISTENER_UNVERIFIED'
        $out.reasons += 'expected IPv4 core listener could not be verified'
    }
    else {
        $out.mode = 'NEXIP'
        if (-not $out.firstHopOk -or -not $GetExitIp) {
            $out.state = 'DEGRADED'
            if ($out.firstHopOk) { $out.faults += 'CHAIN_EXIT_NOT_TESTED' }
        }
        else {
            try { $out.exitViaChain = & $GetExitIp ('http://' + $expectedProxy) }
            catch { $out.exitViaChain = $null }
            if ($out.exitViaChain -isnot [string]) { $out.exitViaChain = $null }
            if ($out.exitViaChain -and $out.exitViaChain -eq $Settings.host) {
                $out.chainStatus = 'EXPECTED_EXIT'
                $out.state = if ($out.faults.Count -eq 0) { 'CHAIN_VERIFIED' } else { 'DEGRADED' }
            }
            elseif ($out.exitViaChain) {
                $out.chainStatus = 'UNEXPECTED_EXIT'
                $out.faults += 'EXIT_MISMATCH'
                $out.state = 'DEGRADED'; $out.reasons += 'Clash HTTPS exit differs from the configured static IPv4'
            }
            else {
                $out.chainStatus = 'NO_EXIT'
                $out.faults += 'CHAIN_EXIT_UNVERIFIED'
                $out.state = 'FAILED'; $out.reasons += 'Clash HTTPS probe returned no IPv4 exit'
            }
        }
    }
    return $out
}

function Get-V4State {
    $p = Get-V4Paths
    $s = $null
    $settingsError = ''
    try { $s = Get-V4Settings -StatusOnly }
    catch { $settingsError = Get-V4FaultMessage $_ }
    $owner = Get-V4Owner
    try { $px = Get-V4SystemProxy }
    catch { $px = $null }
    $pids = Get-V4AppPids
    $mixed = $false
    $hop = $null
    if ($s -and -not $script:TestMode) {
        $mixed = Test-V4ClashListener -Port $s.mixedPort -ExpectedCore $p.Core
        $hop = Test-V4FirstHop -Port $s.hopPort
    }
    $exitProbe = { param($proxy) Get-V4ExitIp -Proxy $proxy -TimeoutSec 5 }
    $uiProxy = Get-V4UiSystemProxy
    $udpProxy = Get-V4UdpProxied
    return Get-V4StateCore -Settings $s -Owner $owner -SystemProxy $px -AppPids $pids -MixedPortOpen $mixed -FirstHop $hop -GetExitIp $exitProbe -SettingsError $settingsError -UiSystemProxy $uiProxy -UdpProxied $udpProxy -AutomaticProxyStatus (Get-V4AutomaticProxyStatus)
}

function Get-V4Integrity {
    param([object]$Paths)
    $r = [ordered]@{ profileExists = $false; markerOk = $false; runtimeMarkerOk = $false; profileHash = $null; ownerRecord = 'none' }
    try {
        if ($Paths -and $Paths.ProfilesDir) {
            $prof = Join-Path $Paths.ProfilesDir 'v4-managed.yaml'
            if (Test-Path -LiteralPath $prof) {
                $r.profileExists = $true
                $r.profileHash = (Get-FileHash -LiteralPath $prof -Algorithm SHA256).Hash.Substring(0, 16)
                $t = Read-V4File $prof
                if ($t -and $t.StartsWith($script:Marker)) { $r.markerOk = $true }
            }
        }
        if ($Paths -and $Paths.RuntimeFile -and (Test-Path -LiteralPath $Paths.RuntimeFile)) {
            $t = Read-V4File $Paths.RuntimeFile
            if ($t -and $t -match 'dialer-proxy:\s*"?STAR-FIRSTHOP"?') { $r.runtimeMarkerOk = $true }
        }
        $o = Get-V4Owner
        if ($o) { $r.ownerRecord = ('{0} @ {1}' -f $o.owner, $o.updatedAt) }
    }
    catch { }
    return $r
}
