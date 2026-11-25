# Tests only the read-side evidence gates, using synthetic provider responses.
param([string]$Library)
$ErrorActionPreference = 'Stop'
if ($env:V4_TEST_MODE -ne '1') { throw 'isolated test context required' }
. $Library
function Get-ItemProperty {
    param($LiteralPath)
    if ($LiteralPath -ne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') { throw 'unexpected registry read' }
    [pscustomobject]@{ProxyEnable=$script:flag; ProxyServer='127.0.0.1:19321'}
}
# Select the actual reader; its provider has already been replaced above.
$script:TestMode = $false
foreach ($script:flag in @([int]1, [int]0, [int]2, '0', '1', $null, [int64]1)) {
    $expected = ($script:flag -is [int] -and $script:flag -eq 1)
    if ((Get-V4SystemProxy).enabled -ne $expected) { exit 1 }
}
$script:TestMode = $true
function Get-NetTCPConnection { $script:rows }
function Get-Process { [pscustomobject]@{ProcessName='core'; Path=$script:image} }
function Test-V4Port { $true }
$script:rows = @([pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=100})
$script:image = 'X:\fixture\core.exe'
if (-not (Test-V4ClashListener 19322 'X:\fixture\core.exe' -RequireImagePath)) { exit 2 }
$script:image = $null
if (Test-V4ClashListener 19322 'X:\fixture\core.exe' -RequireImagePath) { exit 3 }
$script:image = 'X:\fixture\core.exe'
$script:rows += [pscustomobject]@{LocalAddress='0.0.0.0';OwningProcess=101}
if (Test-V4ClashListener 19322 'X:\fixture\core.exe' -RequireImagePath) { exit 4 }
exit 0
