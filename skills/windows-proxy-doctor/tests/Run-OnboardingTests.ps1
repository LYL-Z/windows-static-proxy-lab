#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$wizard = Join-Path $root 'scripts\Start-ProxyDoctor.ps1'
$installer = Join-Path $root 'scripts\Test-ProxyDoctorInstaller.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w p doctor ' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tmp)
$checkpoint = Join-Path $tmp 'windows-proxy-doctor-checkpoint.json'
$fixtures = Join-Path $tmp 'environment.json'
$cases = 0
$failed = 0

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Case([string]$Name, [scriptblock]$Work) {
    $script:cases++
    try { & $Work; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name $($_.Exception.Message)" }
}
function Facts {
    @{
        windows = @{ family = 'WINDOWS_11'; architecture = 'X64'; supported = $true }
        installedApps = @()
        processes = @()
        listeners = @()
        proxy = @{ proxyEnabled = $false; pacConfigured = $false }
        registryQueryOk = $true
        processQueryOk = $true
        listenerQueryOk = $true
        winHttp = 'DIRECT'
    }
}
function Run([hashtable]$Facts, [hashtable]$Options = @{}) {
    $Facts | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtures -Encoding UTF8
    & $wizard -TestFixture $fixtures -Json @Options | ConvertFrom-Json
}
$star = @{ name = 'StarSky'; version = '4.9'; scope = 'CURRENT_USER' }
$clash = @{ name = 'Clash Verge Rev'; version = '2.5.10'; scope = 'MACHINE' }

try {
    Case 'no-clients' {
        $r = Run (Facts) @{ Goal = 'Setup' }
        Assert-True ($r.audience -eq 'UNCONFIRMED' -and $r.action.step -eq 'software') 'Missing software guidance'
        $f = Facts
        $f.windows.supported = $false
        $r = Run $f @{ Goal = 'Setup' }
        Assert-True ($r.state -eq 'BLOCKED' -and $r.action.step -eq 'unsupported-environment') 'Unsupported hosts must not be guided to install Windows software'
    }
    Case 'one-client' {
        $f = Facts
        $f.installedApps = @($star)
        $r = Run $f
        Assert-True ($r.audience -eq 'PARTIAL_INSTALLATION' -and $r.environment.clients.clashVerge.installation -eq 'UNKNOWN') 'Expected one detected client'
    }
    Case 'different-install-location-and-port' {
        $f = Facts
        $f.installedApps = @($star, ($clash + @{ installLocation = 'X:\Alternative Program Files' }))
        $f.processes = @(@{ name = 'verge-mihomo'; id = 921 })
        $f.listeners = @(@{ port = 18321; pid = 921; address = '127.0.0.1' })
        $f.proxy.proxyEnabled = $true
        $f.proxy.proxyServer = '127.0.0.1:18321'
        $r = Run $f
        Assert-True ($r.environment.clients.clashVerge.installation -eq 'REGISTERED' -and $r.environment.proxy.targetClient -eq 'mihomo') 'Independent path or port not recognized'
        Assert-True (($r | ConvertTo-Json -Depth 10) -notmatch 'Alternative Program Files') 'Installation path was emitted'
    }
    Case 'portable-client' {
        $f = Facts
        $f.processes = @(@{ name = 'StarSky.exe'; id = 902; version = '4.9' })
        $r = Run $f
        Assert-True ($r.environment.clients.starsky.installation -eq 'PORTABLE_OR_UNREGISTERED' -and $r.environment.clients.starsky.running) 'Portable process not observed'
    }
    Case 'foreign-listener' {
        $f = Facts
        $f.processes = @(@{ name = 'other-fixture-process'; id = 12 })
        $f.listeners = @(@{port = 18321; pid = 12; address = '127.0.0.1'})
        $f.proxy = @{ proxyEnabled = $true; proxyServer = '127.0.0.1:18321'; uiEnabled = $true }
        $r = Run $f
        Assert-True ($r.diagnostic.code -eq 'POSSIBLE_OWNER_MISMATCH' -and $r.environment.listeners.entries[0].owner -eq 'OTHER_PROCESS') 'Foreign listener outcome is missing'
    }
    Case 'decline-installation' {
        $r = Run (Facts) @{ Goal = 'Setup'; Decision = 'InstallationDeclined' }
        Assert-True ($r.state -eq 'PARTIAL' -and $r.action.step -eq 'diagnose') 'Declining installation should permit diagnosis'
    }
    Case 'decline-system-change' {
        $r = Run (Facts) @{ Goal = 'Setup'; Decision = 'ConfigurationDeclined' }
        Assert-True ($r.action.step -eq 'diagnose' -and $r.authorization -eq 'NEVER_PERSISTED') 'A refusal should preserve read-only diagnosis'
    }
    Case 'existing-third-party-service' {
        $r = Run (Facts) @{Goal = 'Setup'; Decision = 'UseCurrentSoftware'; CheckpointPath = $checkpoint}
        Assert-True ($r.action.step -eq 'service') 'Cannot proceed with existing software'
        $r = Run (Facts) @{Decision = 'UseExistingService'; CheckpointPath = $checkpoint}
        Assert-True ($r.state -eq 'READY_FOR_REVIEW') 'An existing service should reach configuration review'
    }
    Case 'interrupted-and-resumed' {
        $null = Run (Facts) @{Goal = 'Setup'; Decision = 'UseExistingService'; CheckpointPath = $checkpoint}
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $r = & $powershell -NoProfile -ExecutionPolicy Bypass -File $wizard -TestFixture $fixtures -CheckpointPath $checkpoint -Json | ConvertFrom-Json
        Assert-True ($LASTEXITCODE -eq 0 -and $r.mode -eq 'Setup' -and $r.state -eq 'READY_FOR_REVIEW') 'Progress must survive a new process'
    }
    Case 'no-desktop-or-browser-tool' {
        $r = Run (Facts) @{BrowserTool = 'UNAVAILABLE'; DesktopTool = 'UNAVAILABLE'}
        Assert-True ($r.action.step -eq 'software' -and $r.environment.tools.browser -eq 'UNAVAILABLE' -and $r.environment.tools.desktop -eq 'UNAVAILABLE') 'Manual handoff missing'
    }
    Case 'unverified-installer' {
        $sample = Join-Path $tmp 'test sample.exe'
        [IO.File]::WriteAllText($sample, 'Synthetic sample. This file is not executable.')
        $official = 'https://example.com/release'
        $r = & $installer -InstallerPath $sample -SourceUrl $official -Json | ConvertFrom-Json
        Assert-True ($r.status -eq 'UNVERIFIED' -and $r.installerExecution -eq 'NOT_RUN') 'An asserted source cannot validate its installer'
        $r = & $installer -InstallerPath $sample -SourceUrl $official -ExpectedSha256 ('0' * 64) -Json | ConvertFrom-Json
        Assert-True ($r.status -eq 'REJECTED') 'Digest mismatch must reject'
        $r = & $installer -InstallerPath $sample -SourceUrl $official -ExpectedSignerThumbprint ('0' * 40) -Json | ConvertFrom-Json
        Assert-True ($r.status -eq 'REJECTED') 'Unmatched or invalid signer must reject'
        $sha256 = (Get-FileHash -LiteralPath $sample).Hash
        $r = & $installer -InstallerPath $sample -SourceUrl $official -ExpectedSha256 $sha256 -Json | ConvertFrom-Json
        Assert-True ($r.status -eq 'MATCHES_EXPECTED' -and $r.installerExecution -eq 'NOT_RUN') 'Expected digest should match without execution'
    }
    Case 'diagnostic-only' {
        $f = Facts
        $f.installedApps = @($star, $clash)
        $r = Run $f
        Assert-True ($r.mode -eq 'Diagnose' -and $r.action.step -eq 'diagnose' -and -not $r.checkpointSaved) 'Configured users should enter diagnosis without persistence'
    }
    Case 'rollback-requires-real-verification' {
        $opts = @{ Goal = 'Setup'; Decision = 'ChangeReported'; CheckpointPath = $checkpoint }
        $r = Run (Facts) $opts
        Assert-True ($r.state -eq 'VERIFYING') 'User report alone cannot verify application health'
        $opts.Decision = 'RollbackRequested'
        $r = Run (Facts) $opts
        Assert-True ($r.state -eq 'ROLLBACK_REQUIRED') 'Rollback milestone missing'
        $opts.Goal = 'Diagnose'
        $opts.Decision = 'None'
        $r = Run (Facts) $opts
        Assert-True ($r.state -eq 'ROLLBACK_REQUIRED') 'On resumption, diagnosis must preserve pending rollback'
        $opts.Decision = 'RollbackReported'
        $r = Run (Facts) $opts
        Assert-True ($r.state -eq 'VERIFYING' -and $r.verification.status -eq 'NOT_TESTED') 'Rollback report must not impersonate network evidence'
        $rejected = $false
        try { $null = Run (Facts) @{ VerifyUrl = @('https://example.com/') } } catch { $rejected = $true }
        Assert-True $rejected 'Fixture mode must not reach a real endpoint'
    }
    Case 'checkpoint-allowlist-and-redaction' {
        $f = Facts
        $f.proxy.proxyServer = 'private-fixture.example:17321'
        $progress = Get-Content -LiteralPath $checkpoint -Raw | ConvertFrom-Json
        $progress | Add-Member -NotePropertyName 'extraData' -NotePropertyValue 'fixture-private-note'
        $progress | ConvertTo-Json | Set-Content -LiteralPath $checkpoint -Encoding UTF8
        $r = Run $f @{CheckpointPath = $checkpoint}
        $report = $r | ConvertTo-Json -Depth 10
        $saved = Get-Content -LiteralPath $checkpoint -Raw
        Assert-True ($report -notmatch 'fixture-private-note|private-fixture\.example' -and $saved -notmatch 'fixture-private-note|private-fixture\.example') 'Private markers escaped into saved or shareable output'
        $progress.change = 'AUTHORIZED'
        $progress | ConvertTo-Json | Set-Content -LiteralPath $checkpoint -Encoding UTF8
        $before = (Get-FileHash -LiteralPath $checkpoint).Hash
        $rejected = $false
        try { $null = Run $f @{CheckpointPath = $checkpoint} } catch { $rejected = $true }
        Assert-True ($rejected -and (Get-FileHash -LiteralPath $checkpoint).Hash -eq $before) 'Forged authorization must be rejected and the file preserved'
    }
    Case 'fixture-evidence-boundary' {
        $r = Run (Facts)
        Assert-True ($r.source -eq 'test-fixture' -and $r.verification.status -eq 'NOT_TESTED') 'Synthetic tests cannot assert production verification'
        $observations = Get-Content -LiteralPath (Join-Path $root 'references\lifecycle-observations.md') -Raw -Encoding UTF8
        Assert-True ($observations -match 'NOT_TESTED') 'Historical observations must distinguish untested lifecycle outcomes'
    }
    Case 'optional-referral-disclosure' {
        $path = Join-Path $root 'references\providers.md'
        $contents = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $otherLinks = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.md' | Where-Object FullName -ne $path |
            Select-String -Pattern 's\.smartdeer\.top|auth/register\?ref=')
        $firstOffer = $contents.IndexOf('https://s.smartdeer.top/')
        Assert-True ($firstOffer -gt $contents.IndexOf('https://skystars.top/') -and $contents -match 'https://user\.nexip\.net/#/auth/register\?ref=' -and $otherLinks.Count -eq 0) 'Optional links must follow the ordinary links and remain in the dedicated reference'
        Assert-True ($contents -match '\u6d41\u91cf\u5956\u52b1' -and $contents -match '\u73b0\u91d1\u8fd4\u4f63') 'Reward and cash commission disclosures are required'
    }
    Case 'backup-literal-names-and-exclusive-manifest' {
        $source = Join-Path $tmp 'snapshot[a]'
        $other = Join-Path $tmp 'snapshota'
        [void][IO.Directory]::CreateDirectory($source)
        [void][IO.Directory]::CreateDirectory($other)
        $hidden = Join-Path $source 'hidden.txt'
        [IO.File]::WriteAllText($hidden, 'literal hidden fixture')
        [IO.File]::SetAttributes($hidden, [IO.FileAttributes]::Hidden)
        [IO.File]::WriteAllText((Join-Path $other 'wrong.txt'), 'neighbor fixture')
        $output = Join-Path $tmp 'backup.dpapi'
        $manifest = "$output.json"
        [IO.File]::WriteAllText($manifest, 'keep existing metadata')
        $rejected = $false
        try { $null = & (Join-Path $root 'scripts\Protect-Backup.ps1') -Path $source -OutFile $output -Apply } catch { $rejected = $true }
        Assert-True ($rejected -and -not (Test-Path -LiteralPath $output) -and [IO.File]::ReadAllText($manifest) -eq 'keep existing metadata') 'Existing manifest must be preserved'
        [IO.File]::Delete($manifest)
        $null = & (Join-Path $root 'scripts\Protect-Backup.ps1') -Path $source -OutFile $output -Apply
        $restore = Join-Path $tmp 'restored.zip'
        $null = & (Join-Path $root 'scripts\Unprotect-Backup.ps1') -InFile $output -OutFile $restore
        $zip = [IO.Compression.ZipFile]::OpenRead($restore)
        try {
            Assert-True (($zip.Entries.FullName -contains 'hidden.txt') -and ($zip.Entries.FullName -notcontains 'wrong.txt')) 'The snapshot must include hidden files from the literal directory only'
        } finally { $zip.Dispose() }
    }
} finally {
    if ([IO.Directory]::Exists($tmp)) {
        $resolved = (Get-Item -LiteralPath $tmp).FullName
        $expected = [IO.Path]::GetFullPath($tmp)
        if ($resolved -ne $expected -or [IO.Path]::GetFileName($resolved) -notmatch '^w p doctor [0-9a-f]{32}$') {
            throw 'Unexpected test directory; cleanup stopped.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host ('Onboarding tests {0}/{1} passed' -f ($cases - $failed), $cases)
if ($failed -or -not $cases) { exit 1 }
