#Requires -Version 5.1
<#
  Run-FT-Case.ps1 - FT16..FT21 production-state safety checks.
  Every case is isolated under TEMP and uses the test registry writer; no case
  writes the real HKCU system proxy. Real HKCU is read only for before/after
  comparison. Invoked by cases/70-ft.tests.ps1.
#>
param(
    [Parameter(Mandatory = $true)][string]$Case,
    [Parameter(Mandatory = $true)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = [System.IO.Path]::GetFullPath((Join-Path $here '..\..\..\..'))
$root = Join-Path $env:TEMP ('v6ft-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
Copy-Item (Join-Path $repo 'proxy_v4\lib\V4.ps1') (Join-Path $root 'lib\V4.ps1') -Force
$env:V4_TEST_MODE = '1'
$env:V4_TEST_ROOT = $root
. (Join-Path $root 'lib\V4.ps1')
$script:Actual = ''
$script:Pass = $false
$script:Detail = ''

function Get-RealProxySnapshot {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $v = Get-ItemProperty $k -ErrorAction SilentlyContinue
    return [ordered]@{
        ProxyEnable = [int]$v.ProxyEnable
        ProxyServer = [string]$v.ProxyServer
        AutoConfigURL = [string]$v.AutoConfigURL
        ProxyOverride = [string]$v.ProxyOverride
    }
}
function Get-WinHttpSnapshot {
    try { return ((& netsh winhttp show proxy 2>&1) -join [Environment]::NewLine) } catch { return '' }
}
function Assert-FT {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Snapshot-Equal {
    param($A, $B)
    foreach ($k in @('ProxyEnable','ProxyServer','AutoConfigURL','ProxyOverride')) {
        if ([string]$A[$k] -ne [string]$B[$k]) { return $false }
    }
    return $true
}
function New-ChildScript {
    param([string]$Name, [string]$ReadyFile, [string]$Mode = 'wait')
    $path = Join-Path $root ($Name + '.ps1')
    $body = @'
$env:V4_TEST_MODE = '1'
$env:V4_TEST_ROOT = "ROOTPATH"
. "LIBPATH"
if ("MODE" -eq 'throw') {
    Set-V4TestRegistryWriter { param($e, $s) throw 'mock registry failure' }
    try { Set-V4SystemProxy -Server 'x'; exit 9 } catch { exit 0 }
}
if ("MODE" -eq 'nowriter') {
    try { Set-V4SystemProxy -Server 'x'; exit 9 } catch { exit 0 }
}
Set-V4TestRegistryWriter {
    param($e, $s)
    [System.IO.File]::WriteAllText("READYPATH", [string]$s)
}
Set-V4SystemProxy -Server 'x'
Start-Sleep -Seconds 30
'@
    $body = $body.Replace('ROOTPATH', $root).Replace('LIBPATH', (Join-Path $root 'lib\V4.ps1')).Replace('READYPATH', $ReadyFile).Replace('"MODE"', ('"' + $Mode + '"'))
    [System.IO.File]::WriteAllText($path, $body, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

try {
    $before = Get-RealProxySnapshot
    $beforeWinHttp = Get-WinHttpSnapshot
    switch ($Case) {
        'FT16' {
            $global:MockProxy = [ordered]@{ Enabled = $null; Server = $null }
            Set-V4TestRegistryWriter {
                param($enabled, $server)
                $global:MockProxy.Enabled = $enabled
                $global:MockProxy.Server = $server
            }
            Set-V4SystemProxy -Server 'x'
            Assert-FT ($global:MockProxy.Server -eq 'x') 'mock registry did not receive x'
            Assert-FT (Snapshot-Equal $before (Get-RealProxySnapshot)) 'real HKCU changed during a mocked x write'
            $script:Actual = 'x was written only to the mock registry; real HKCU unchanged'
        }
        'FT17' {
            Set-V4TestRegistryWriter { param($enabled, $server) throw 'mock registry deliberately failed' }
            $threw = $false
            try { Set-V4SystemProxy -Server 'x' } catch { $threw = $true }
            Assert-FT $threw 'mock failure did not abort the write'
            Assert-FT (Snapshot-Equal $before (Get-RealProxySnapshot)) 'real HKCU changed while the mock failed'
            $script:Actual = 'mock failure aborted the operation; real HKCU unchanged'
        }
        'FT18' {
            $ready = Join-Path $root 'child.ready'
            $child = New-ChildScript -Name 'child18' -ReadyFile $ready -Mode 'wait'
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$child) -PassThru -WindowStyle Hidden
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $ready)) { Start-Sleep -Milliseconds 100 }
            Assert-FT (Test-Path -LiteralPath $ready) 'child never performed the mocked write'
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
            Assert-FT (Snapshot-Equal $before (Get-RealProxySnapshot)) 'real HKCU changed after an abnormal child termination'
            $script:Actual = 'child wrote only the mock then was killed; real HKCU unchanged'
        }
        'FT19' {
            $children = @()
            try {
                for ($i = 1; $i -le 2; $i++) {
                    $ready = Join-Path $root ('parallel' + $i + '.ready')
                    $child = New-ChildScript -Name ('child19-' + $i) -ReadyFile $ready -Mode 'wait'
                    $children += [pscustomobject]@{ Proc = (Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$child) -PassThru -WindowStyle Hidden); Ready = $ready }
                }
                foreach ($c in $children) {
                    $deadline = (Get-Date).AddSeconds(10)
                    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $c.Ready)) { Start-Sleep -Milliseconds 100 }
                    Assert-FT (Test-Path -LiteralPath $c.Ready) ('parallel child did not write its mock: ' + $c.Ready)
                }
            }
            finally {
                foreach ($c in $children) { try { Stop-Process -Id $c.Proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
            }
            Assert-FT (Snapshot-Equal $before (Get-RealProxySnapshot)) 'real HKCU changed by parallel mocked tests'
            $script:Actual = 'two parallel mocked tests did not touch real HKCU'
        }
        'FT20' {
            $settings = [pscustomobject]@{ host='203.0.113.10'; mixedPort=7897; hopPort=11119 }
            $badProxy = [pscustomobject]@{ enabled=$true; server='x' }
            $goodProxy = [pscustomobject]@{ enabled=$true; server='127.0.0.1:7897' }
            $hop = [pscustomobject]@{ ok=$true; detail='200' }
            $exitOk = { param($p) '203.0.113.10' }
            $exitBad = { param($p) '198.51.100.9' }
            $a = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $badProxy -AppPids @(1) -MixedPortOpen $true -FirstHop $hop -GetExitIp $exitOk -SettingsError ''
            $b = Get-V4StateCore -Settings $settings -Owner $null -SystemProxy $goodProxy -AppPids @(1) -MixedPortOpen $true -FirstHop $hop -GetExitIp $exitBad -SettingsError ''
            Assert-FT ($a.state -eq 'DEGRADED') ('x proxy was reported as ' + $a.state)
            Assert-FT ($a.state -ne 'HEALTHY') 'x proxy was reported HEALTHY'
            Assert-FT ($b.state -eq 'DEGRADED') ('wrong exit IP was reported as ' + $b.state)
            Assert-FT ($b.state -ne 'HEALTHY') 'wrong exit IP was reported HEALTHY'
            $script:Actual = 'x proxy and wrong exit IP are DEGRADED, never HEALTHY'
        }
        'FT21' {
            $child = New-ChildScript -Name 'child21' -ReadyFile (Join-Path $root 'never.ready') -Mode 'nowriter'
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$child) -PassThru -WindowStyle Hidden
            if (-not $p.WaitForExit(15000)) { try { Stop-Process -Id $p.Id -Force } catch { }; throw 'nowriter child timed out' }
            Assert-FT ($p.ExitCode -eq 0) ('nowriter child exit=' + $p.ExitCode)
            Assert-FT (Snapshot-Equal $before (Get-RealProxySnapshot)) 'real HKCU changed after a no-writer test'
            Assert-FT ((Get-WinHttpSnapshot) -eq $beforeWinHttp) 'WinHTTP proxy changed during the test'
            $script:Actual = 'test without a writer was refused; HKCU/WinHTTP identical before and after'
        }
        default { throw ('unknown FT case: ' + $Case) }
    }
    $script:Pass = $true
}
catch {
    $script:Pass = $false
    $script:Detail = $_.Exception.Message
    if (-not $script:Actual) { $script:Actual = 'exception: ' + $script:Detail }
}
$payload = [ordered]@{ id = $Case; pass = $script:Pass; detail = $script:Detail; actual = $script:Actual; ts = (Get-Date).ToString('s') }
[System.IO.File]::WriteAllText($OutFile, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
if ($script:Pass) { exit 0 } else { exit 1 }
