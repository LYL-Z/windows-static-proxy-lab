#Requires -Version 5.1
<#
Fixture classification tests. Synthetic JSON and in-memory objects only.
Does not read HKCU, WinHTTP, process lists, or the network.
Exit: 0 pass, 1 failure, 2 zero tests.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$testDir = Split-Path -Parent $PSCommandPath
$root = Split-Path -Parent $testDir
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wpdoctor-fault-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$failures = New-Object System.Collections.Generic.List[string]
$count = 0
$note = 'An alert or UI status is not proof the network was blocked.'
. (Join-Path $root 'scripts\ProxyFaultClass.ps1')

function Assert-True($cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Check([string]$name, [scriptblock]$body) {
    $script:count++
    try { & $body; Write-Host ('PASS ' + $name) }
    catch { $script:failures.Add($name + ': ' + $_.Exception.Message); Write-Host ('FAIL ' + $name + ': ' + $_.Exception.Message) }
}
function Text([int[]]$Codes) { -join ($Codes | ForEach-Object { [char]$_ }) }
function Read-Fault([string]$Name) {
    Get-Content -LiteralPath (Join-Path $testDir ('fixtures\' + $Name)) -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Assert-Class($Result, [string]$Class) {
    Assert-True ($Result.class -eq $Class) ('class=' + $Result.class)
    Assert-True ($Result.recommendRestore -eq $false) 'restore was recommended'
    Assert-True ($Result.applicationSuccess -eq $false) 'application success was reported'
    Assert-True ($Result.note -eq $script:note) 'alert sentence missing or changed'
}
function New-Aligned {
    @{
        proxyEnabled = $true; uiEnabled = $true; pacConfigured = $false; proxyTargetsExpected = $true
        coreRunning = $true; mixedPortOpen = $true; mixedIPv4CoreOwned = $true
        firstHopExpected = $true; firstHopOpen = $true
    }
}

try {
    Check 'fixture-user-off' {
        $result = Get-ProxyDoctorFaultClass -Observation (Read-Fault 'fault-user-off.json')
        Assert-Class $result 'USER_OFF'
        Assert-True ($result.advice -eq 'The user turned the proxy off. Keep the proxy off.') 'user-off advice changed'
        Assert-True ($result.advice -notmatch '(?i)restore|re-enable|reenable|turn it on|enable the proxy') 'user-off advice recommends restoring'
    }
    Check 'fixture-proxy-drift' {
        $result = Get-ProxyDoctorFaultClass -Observation (Read-Fault 'fault-proxy-drift.json')
        Assert-Class $result 'PROXY_DRIFT'
    }
    Check 'fixture-core-down' {
        $result = Get-ProxyDoctorFaultClass -Observation (Read-Fault 'fault-core-down.json')
        Assert-Class $result 'CORE_DOWN'
    }
    Check 'fixture-first-hop-down' {
        $result = Get-ProxyDoctorFaultClass -Observation (Read-Fault 'fault-first-hop-down.json')
        Assert-Class $result 'FIRST_HOP_DOWN'
    }
    Check 'fixture-aligned-is-not-application-success' {
        $observation = Read-Fault 'fault-aligned.json'
        Assert-True ($observation.applicationOk -eq $true) 'aligned fixture lost the positive application flag'
        $result = Get-ProxyDoctorFaultClass -Observation $observation
        Assert-Class $result 'ALIGNED'
        Assert-True ($result.advice -match 'not application success') 'aligned advice reported application success'
        $again = Get-ProxyDoctorFaultClass -Observation $observation
        Assert-True ($again.class -eq $result.class -and $again.applicationSuccess -eq $false) 'repeated classification changed'
    }
    Check 'fixture-unknown' {
        Assert-Class (Get-ProxyDoctorFaultClass -Observation (Read-Fault 'fault-unknown.json')) 'UNKNOWN'
    }
    Check 'both-toggles-off-without-a-record-is-not-confirmed-intent' {
        $result = Get-ProxyDoctorFaultClass -Observation @{ proxyEnabled = $false; uiEnabled = $false; pacConfigured = $false; coreRunning = $false }
        Assert-Class $result 'OBSERVED_OFF'
        Assert-True ($result.recommendRestore -eq $false) 'an unconfirmed off state recommended a restore'
    }
    Check 'explicit-denial-of-user-off-is-drift' {
        $result = Get-ProxyDoctorFaultClass -Observation @{
            userTurnedProxyOff = $false; proxyEnabled = $false; uiEnabled = $false; pacConfigured = $false
        }
        Assert-Class $result 'PROXY_DRIFT'
    }
    Check 'user-off-while-windows-remains-on-is-not-restored' {
        $observation = New-Aligned
        $observation.userTurnedProxyOff = $true
        $result = Get-ProxyDoctorFaultClass -Observation $observation
        Assert-Class $result 'USER_OFF'
        Assert-True ($result.advice -notmatch '(?i)restore|re-enable|reenable|turn it on|enable the proxy') 'enabled snapshot recommended a restore'
    }
    Check 'target-mismatch-is-drift' {
        $observation = New-Aligned
        $observation.proxyTargetsExpected = $false
        Assert-Class (Get-ProxyDoctorFaultClass -Observation $observation) 'PROXY_DRIFT'
    }
    Check 'closed-listener-is-core-down' {
        $observation = New-Aligned
        $observation.mixedPortOpen = $false
        Assert-Class (Get-ProxyDoctorFaultClass -Observation $observation) 'CORE_DOWN'
    }
    Check 'core-down-before-first-hop' {
        $observation = New-Aligned
        $observation.coreRunning = $false
        $observation.firstHopOpen = $false
        Assert-Class (Get-ProxyDoctorFaultClass -Observation $observation) 'CORE_DOWN'
    }
    Check 'unowned-listener-stays-unknown' {
        $observation = New-Aligned
        $observation.mixedIPv4CoreOwned = $false
        Assert-Class (Get-ProxyDoctorFaultClass -Observation $observation) 'UNKNOWN'
    }
    Check 'first-hop-not-in-scope-can-align' {
        $observation = New-Aligned
        $observation.firstHopExpected = $false
        $observation.firstHopOpen = $false
        Assert-Class (Get-ProxyDoctorFaultClass -Observation $observation) 'ALIGNED'
    }
    Check 'missing-or-invalid-evidence-is-unknown' {
        Assert-Class (Get-ProxyDoctorFaultClass -Observation @{ source = 'fixture' }) 'UNKNOWN'
        Assert-Class (Get-ProxyDoctorFaultClass -Observation @{ proxyEnabled = 'yes'; uiEnabled = $true; pacConfigured = $false }) 'UNKNOWN'
        Assert-Class (Get-ProxyDoctorFaultClass -Observation $null) 'UNKNOWN'
    }
    Check 'classification-does-not-echo-inputs' {
        $observation = New-Aligned
        $observation.proxyServer = 'hidden-fixture-value'
        $observation.note = 'caller-supplied-note'
        $result = Get-ProxyDoctorFaultClass -Observation $observation
        $packed = $result | ConvertTo-Json -Compress
        Assert-True ($packed -notmatch 'hidden-fixture-value|caller-supplied-note') 'input values were copied into the result'
        Assert-True ($observation.proxyServer -eq 'hidden-fixture-value') 'input observation was mutated'
    }
    Check 'sentence-maps-to-classify-step' {
        $exact = Text 0x68C0,0x67E5,0x6211,0x7684,0x4EE3,0x7406,0x4E3A,0x4EC0,0x4E48,0x6CA1,0x6709,0x6B63,0x5E38,0x5DE5,0x4F5C
        $equivalent = Text 0x8BF7,0x4EE3,0x7406,0x65E0,0x6CD5,0x6B63,0x5E38,0x5DE5,0x4F5C
        $setup = Text 0x5E2E,0x6211,0x51C6,0x5907,0x4EE3,0x7406,0x8BBE,0x7F6E
        $reopened = 'StarSky' + (Text 0x5DF2,0x7ECF,0x91CD,0x65B0,0x5F00,0x542F) + '，但 Clash ' + (Text 0x6CA1,0x6709,0x6D41,0x91CF)
        $config = (Text 0x68C0,0x67E5,0x6211,0x7684) + (Text 0x7535,0x8111,0x7F51,0x7EDC,0x914D,0x7F6E,0x662F,0x5426,0x6B63,0x5E38)
        $plan = (Text 0x68C0,0x67E5) + (Text 0x7F51,0x7EDC,0x6545,0x969C) + (Text 0x5E76,0x63D0,0x4F9B) + (Text 0x6062,0x590D,0x65B9,0x6848)
        $fullNetwork = Text 0x5168,0x9762,0x68C0,0x67E5,0x6211,0x7684,0x7F51,0x7EDC
        $network = Text 0x68C0,0x67E5,0x6211,0x7684,0x7F51,0x7EDC
        $stopped = 'StarSky ' + (Text 0x505C,0x6B62,0x8FD0,0x884C,0x4E86)
        $clashQuiet = 'Clash ' + (Text 0x6CA1,0x6709,0x6D41,0x91CF)
        $abnormalPlan = (Text 0x68C0,0x67E5,0x5F02,0x5E38,0x5E76,0x63D0,0x4F9B) + (Text 0x6062,0x590D,0x65B9,0x6848)
        foreach ($sample in @($exact, $equivalent, 'why isn''t my proxy working', 'why is my proxy not working', $reopened, $config, $plan, 'StarSky is back but Clash has no traffic', $fullNetwork, $network, 'check my network', $stopped, $clashQuiet.ToUpperInvariant(), $abnormalPlan)) {
            $route = Resolve-ProxyDoctorUserRequest $sample
            Assert-True ($route.goal -eq 'Diagnose' -and $route.intent -eq 'diagnose' -and $route.entry -eq 'scripts/Start-ProxyDoctor.ps1 -Goal Diagnose' -and $route.classify -eq 'Get-ProxyDoctorFaultClass' -and $route.authorization -eq 'read-only until the user accepts one specific change') ('route missed: ' + $sample)
        }
        foreach ($sample in @($setup, 'help me prepare proxy settings', 'why is my proxy working', '')) {
            $route = Resolve-ProxyDoctorUserRequest $sample
            Assert-True ($route.goal -eq 'Unspecified' -and $route.intent -eq 'unspecified' -and $null -eq $route.classify) ('setup or healthy wording was classified: ' + $sample)
        }
        $keep = (Text 0x4FDD,0x6301,0x539F,0x914D,0x7F6E) + '，' + (Text 0x4E0D,0x64C5,0x81EA,0x4FEE,0x6539)
        $held = Resolve-ProxyDoctorUserRequest $keep
        Assert-True ($held.goal -eq 'NoModify' -and $held.intent -eq 'no-modify' -and $held.authorization -eq 'do-not-modify' -and $null -eq $held.entry -and $null -eq $held.classify -and $null -eq $held.script) 'keep-config sentence was not an explicit no-modify route'
        $heldWithCheck = Resolve-ProxyDoctorUserRequest ($fullNetwork + '，' + $keep)
        Assert-True ($heldWithCheck.goal -eq 'NoModify' -and $heldWithCheck.intent -eq 'no-modify' -and $null -eq $heldWithCheck.classify) 'a do-not-modify sentence was routed into diagnosis'
        $doNotChange = Text 0x4E0D,0x8981,0x4FEE,0x6539
        $heldWithCheck = Resolve-ProxyDoctorUserRequest ($network + ', ' + $doNotChange)
        Assert-True ($heldWithCheck.goal -eq 'NoModify' -and $null -eq $heldWithCheck.entry) 'short do-not-modify wording lost its precedence'
        $checkNetwork = Text 0x68C0,0x67E5,0x7F51,0x7EDC
        $keepCurrent = Text 0x4FDD,0x7559,0x73B0,0x6709,0x914D,0x7F6E
        $preserveCurrent = Text 0x4FDD,0x6301,0x73B0,0x6709,0x914D,0x7F6E
        Assert-True ((Resolve-ProxyDoctorUserRequest $checkNetwork).intent -eq 'diagnose') 'plain network check was not routed'
        Assert-True ((Resolve-ProxyDoctorUserRequest ($checkNetwork + ', ' + $keepCurrent)).intent -eq 'no-modify') 'keep current configuration wording lost its precedence'
        Assert-True ((Resolve-ProxyDoctorUserRequest ($checkNetwork + ', ' + $preserveCurrent)).intent -eq 'no-modify') 'preserve current configuration wording lost its precedence'
    }
    Check 'docs-point-at-classifier' {
        $skill = Get-Content -LiteralPath (Join-Path $root 'SKILL.md') -Raw -Encoding UTF8
        $guide = Get-Content -LiteralPath (Join-Path $root 'references\troubleshooting.md') -Raw -Encoding UTF8
        $exact = Text 0x68C0,0x67E5,0x6211,0x7684,0x4EE3,0x7406,0x4E3A,0x4EC0,0x4E48,0x6CA1,0x6709,0x6B63,0x5E38,0x5DE5,0x4F5C
        Assert-True ($skill.Contains($exact) -and $skill.Contains('Get-ProxyDoctorFaultClass') -and $skill.Contains('Start-ProxyDoctor.ps1 -Goal Diagnose')) 'skill entry does not point at the classify step'
        $fullNetwork = Text 0x5168,0x9762,0x68C0,0x67E5,0x6211,0x7684,0x7F51,0x7EDC
        $stopped = 'StarSky ' + (Text 0x505C,0x6B62,0x8FD0,0x884C,0x4E86)
        $clashQuiet = 'Clash ' + (Text 0x6CA1,0x6709,0x6D41,0x91CF)
        $abnormalPlan = Text 0x68C0,0x67E5,0x5F02,0x5E38,0x5E76,0x63D0,0x4F9B,0x6062,0x590D,0x65B9,0x6848
        $keep = (Text 0x4FDD,0x6301,0x539F,0x914D,0x7F6E) + '，' + (Text 0x4E0D,0x64C5,0x81EA,0x4FEE,0x6539)
        foreach ($sample in @($fullNetwork, $stopped, $clashQuiet, $abnormalPlan)) {
            Assert-True ($skill.Contains($sample) -and $guide.Contains($sample)) ('diagnose sentence missing from the guides: ' + $sample)
        }
        Assert-True ($skill.Contains($keep) -and $guide.Contains($keep) -and $skill.Contains('no-modify') -and $guide.Contains((Text 0x4E0D,0x4FEE,0x6539,0x610F,0x56FE))) 'guides omitted the explicit no-modify intent'
        Assert-True ($guide.Contains('Get-ProxyDoctorFaultClass') -and $guide.Contains('USER_OFF') -and $guide.Contains('ALIGNED')) 'troubleshooting guide does not point at the classifier'
        Assert-True ($guide.Contains($note) -and $skill.Contains($note)) 'alert sentence missing from the diagnose guidance'
        Assert-True ($guide.Contains((Text 0x4E0D,0x8981,0x5EFA,0x8BAE,0x6062,0x590D))) 'guide omitted the do-not-restore instruction'
    }
    Check 'classifier-does-not-call-live-state' {
        $src = Get-Content -LiteralPath (Join-Path $root 'scripts\ProxyFaultClass.ps1') -Raw -Encoding UTF8
        Assert-True ($src -notmatch 'HKCU:|Get-ItemProperty|Set-ItemProperty|netsh|Start-Process|RunAs|Invoke-WebRequest|HttpClient') 'classifier gained a live side effect'
    }
    Check 'diagnose-command-classifies-without-registry' {
        $facts = @{
            windows = @{ family = 'WINDOWS_11'; architecture = 'X64'; supported = $true }
            installedApps = @(); processes = @(); listeners = @()
            proxy = @{ proxyEnabled = $false; pacConfigured = $false; uiEnabled = $false }
            registryQueryOk = $true; processQueryOk = $true; listenerQueryOk = $true; winHttp = 'DIRECT'
        }
        $fixture = Join-Path $tmp 'environment.json'
        $facts | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixture -Encoding UTF8
        $wizard = Join-Path $root 'scripts\Start-ProxyDoctor.ps1'
        $result = & $wizard -TestFixture $fixture -Goal Diagnose -Json | ConvertFrom-Json
        Assert-Class $result.faultClass 'OBSERVED_OFF'
        Assert-True ($result.mode -eq 'Diagnose' -and $result.verification.application -eq 'NOT_TESTED') 'diagnose path treated classification as application success'
        $text = (& $wizard -TestFixture $fixture -Goal Diagnose | Out-String)
        Assert-True ($text.Contains('OBSERVED_OFF. ' + $note)) 'text diagnose output omitted the class and alert sentence'
        $setup = & $wizard -TestFixture $fixture -Goal Setup -Json | ConvertFrom-Json
        Assert-True ($null -eq $setup.PSObject.Properties['faultClass']) 'setup goal invented a fault class'
    }
    Check 'environment-fields-map-without-guessing-a-listener' {
        $environment = [pscustomobject]@{
            proxy = [pscustomobject]@{
                manualEnabled = $true; clashSavedEnabled = $true; pacConfigured = $false
                targetIsOtherProcess = $false; targetListenerObserved = $true; targetClient = 'mihomo'
            }
            clients = [pscustomobject]@{
                mihomo = [pscustomobject]@{ running = $true }
                clashVerge = [pscustomobject]@{ running = $false }
            }
        }
        $observation = ConvertTo-ProxyDoctorFaultObservation -Environment $environment
        Assert-True ($observation.proxyTargetsExpected -eq $true -and $observation.coreRunning -eq $true) 'expected listener was not mapped'
        Assert-True ($observation.mixedPortOpen -eq $null -and $observation.firstHopOpen -eq $null) 'unmeasured listener was invented'
        Assert-Class (Get-ProxyDoctorFaultClass -Observation $observation) 'UNKNOWN'
        $environment.proxy.targetIsOtherProcess = $true
        $drift = Get-ProxyDoctorFaultClass -Observation (ConvertTo-ProxyDoctorFaultObservation -Environment $environment)
        Assert-Class $drift 'PROXY_DRIFT'
    }
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ('COUNTS=' + $count + ' failures=' + $failures.Count)
if ($failures.Count) { $failures | ForEach-Object { Write-Host ('  - ' + $_) }; exit 1 }
if ($count -eq 0) { exit 2 }
exit 0
