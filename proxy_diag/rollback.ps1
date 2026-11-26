# =====================================================================
#  ROLLBACK: 恢复到本任务开始前的状态 (2026-11-18 01:16 快照)
#  作用: 还原 Clash Verge 全部配置 + 关闭系统代理 + 重启客户端
#  说明: 还原后静态IP仍会因"中国大陆来源IP被拒"而不可用,
#        但这正是任务开始前的原始状态; 日常上网仍由 StarSky 正常提供。
# =====================================================================
$ErrorActionPreference = 'Stop'

$bak  = 'C:\CAB-Lab\proxy_diag\backup\20261118-011610'
$base = 'C:\CAB-Lab\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev'
$exe  = 'C:\Program Files\Clash Verge\clash-verge.exe'

if (-not (Test-Path $bak)) { throw "backup dir not found: $bak" }

Write-Host '[1/4] restoring yaml files ...'
Get-ChildItem $bak -File -Filter *.yaml | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $base $_.Name) -Force
    Write-Host ("   restored " + $_.Name)
}
Copy-Item (Join-Path $bak 'profiles') (Join-Path $base 'profiles') -Recurse -Force
Write-Host '   restored profiles\'

Write-Host '[2/4] disabling system proxy ...'
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty $k -Name ProxyEnable -Value 0
# 保留任务开始前的 ProxyServer 值, 便于其它软件按原样接管
Set-ItemProperty $k -Name ProxyServer -Value '127.0.0.1:11119'
$sig = '[DllImport("wininet.dll",SetLastError=true)]public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);'
$w = Add-Type -MemberDefinition $sig -Name W2 -Namespace N2 -PassThru
[void]$w::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
[void]$w::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)

Write-Host '[3/4] restarting Clash Verge ...'
Get-Process verge-mihomo, clash-verge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Start-Process $exe
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 1500
    if (Get-NetTCPConnection -LocalPort 7897 -State Listen -ErrorAction SilentlyContinue) { break }
}

Write-Host '[4/4] done. current state:'
$pr = Get-ItemProperty $k
Write-Host ("   ProxyEnable = " + $pr.ProxyEnable + "  ProxyServer = " + $pr.ProxyServer)
Write-Host '   NOTE: mihomo 档位已还原为 mode: direct (原始状态).'
