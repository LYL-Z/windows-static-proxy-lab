# =====================================================================
#  VALIDATE: 20 次 / 约 10 分钟的验收测试 (经由 Clash 7897 全链路)
#  每轮: TCP -> SOCKS5 -> CONNECT -> TLS -> HTTPS 取出口IP
#  输出: 控制台表格 + D:\claude防封\proxy_diag\validate-result.jsonl
# =====================================================================
$ErrorActionPreference = 'Continue'
$env:PYTHONIOENCODING = 'utf-8'
$env:PX_HOST = '127.0.0.1'     # 走 Clash, 不直连静态IP
$env:PX_PORT = '7897'

Write-Host ''
Write-Host '=== pre-check ==='
$pr = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Write-Host ("system proxy : enable=" + $pr.ProxyEnable + " server=" + $pr.ProxyServer)
$hop = (Get-NetTCPConnection -LocalPort 11119 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host ("first hop 11119: " + $(if ($hop) { "listening (pid $hop)" } else { "NOT LISTENING  <-- open StarSky" }))
Write-Host ''

& python.exe 'D:\claude防封\proxy_diag\monitor.py' --runs 20 --interval 30 `
    --out 'D:\claude防封\proxy_diag\validate-result.jsonl'

Write-Host ''
Write-Host 'PASS 标准: success=20/20 且 所有 exit_ip 均为 72.245.197.103'
