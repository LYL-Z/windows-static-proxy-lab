param([string]$Only = '*', [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path
$bench = Join-Path $env:TEMP ('v4f08-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $bench 'lib') -Force | Out-Null
Copy-Item (Join-Path $repo 'proxy_v4\lib\V4.ps1') (Join-Path $bench 'lib\V4.ps1') -Force
. (Join-Path $bench 'lib\V4.ps1')

$uid = 'V4Mngd0001'
$epoch = 999999
$results = New-Object System.Collections.ArrayList
function Check([string]$id, [string]$name, [scriptblock]$body) {
    if ($id -notlike $Only) { return }
    try {
        $detail = & $body
        [void]$results.Add([pscustomobject]@{ id=$id; name=$name; pass=$true; detail=$detail })
        Write-Host ("  [PASS] {0} {1}" -f $id, $name) -ForegroundColor Green
    } catch {
        [void]$results.Add([pscustomobject]@{ id=$id; name=$name; pass=$false; detail=$_.Exception.Message })
        Write-Host ("  [FAIL] {0} {1}: {2}" -f $id, $name, $_.Exception.Message) -ForegroundColor Red
    }
}
function AssertTrue($cond, $msg) { if (-not $cond) { throw $msg } }

$base = @"
current: AAA
items:
- uid: V4Mngd0001
  type: local
  name: V4-Managed
  file: v4-managed.yaml
  updated: 111111
- uid: SUB0002
  type: remote
  name: Other
  file: other.yaml
  updated: 222222
"@

Check 'F08-01' 'target has updated: only target changes' {
    $out = Update-V4ProfileText -Text $base -Uid $uid -Epoch $epoch
    AssertTrue ($out -match ('uid: ' + $uid + '[\s\S]*updated: ' + $epoch)) 'target updated not refreshed'
    AssertTrue ($out -match 'uid: SUB0002[\s\S]*updated: 222222') 'foreign updated changed'
    'target refreshed, foreign 222222 kept'
}

Check 'F08-02' 'target has NO updated: next profile must not change' {
    $t = @"
current: AAA
- uid: V4Mngd0001
  type: local
  name: V4-Managed
  file: v4-managed.yaml
- uid: SUB0002
  type: remote
  name: Other
  file: other.yaml
  updated: 222222
"@
    $out = Update-V4ProfileText -Text $t -Uid $uid -Epoch $epoch
    AssertTrue ($out -match 'uid: SUB0002[\s\S]*updated: 222222') 'non-target profile updated was modified'
    AssertTrue ($out -match ('uid: ' + $uid + '[\s\S]*?updated: ' + $epoch)) 'target did not get an updated field'
    'foreign 222222 kept, target got updated'
}

Check 'F08-03' 'similar UID before target must not be selected' {
    $t = @"
current: AAA
- uid: V4Mngd00010
  type: local
  name: Similar
  file: similar.yaml
  updated: 333333
- uid: V4Mngd0001
  type: local
  name: V4-Managed
  file: v4-managed.yaml
"@
    $out = Update-V4ProfileText -Text $t -Uid $uid -Epoch $epoch
    AssertTrue ($out -match 'uid: V4Mngd00010[\s\S]*updated: 333333') 'similar UID profile was modified'
    AssertTrue ($out -match ('uid: ' + $uid + '[\s\S]*?updated: ' + $epoch)) 'target did not get updated'
    'similar 333333 kept'
}

Check 'F08-04' 'duplicate target UID must fail closed' {
    $t = @"
current: AAA
- uid: V4Mngd0001
  type: local
  name: One
  file: one.yaml
  updated: 111111
- uid: V4Mngd0001
  type: local
  name: Two
  file: two.yaml
  updated: 222222
"@
    $threw = $false
    try { Update-V4ProfileText -Text $t -Uid $uid -Epoch $epoch | Out-Null } catch { $threw = $true }
    AssertTrue $threw 'duplicate UID was silently accepted'
    'duplicate rejected'
}

Check 'F08-05' 'target updated with inline comment must still refresh' {
    $t = @"
current: AAA
- uid: V4Mngd0001
  type: local
  name: V4-Managed
  file: v4-managed.yaml
  updated: 111111 # last edited
- uid: SUB0002
  type: remote
  name: Other
  file: other.yaml
  updated: 222222
"@
    $out = Update-V4ProfileText -Text $t -Uid $uid -Epoch $epoch
    AssertTrue ($out -match ('updated: ' + $epoch)) 'target with inline comment not refreshed'
    AssertTrue ($out -match 'uid: SUB0002[\s\S]*updated: 222222') 'foreign updated changed'
    'target refreshed, comment case handled'
}

Check 'F08-06' 'target last without updated must gain updated' {
    $t = @"
current: AAA
- uid: SUB0002
  type: remote
  name: Other
  file: other.yaml
  updated: 222222
- uid: V4Mngd0001
  type: local
  name: V4-Managed
  file: v4-managed.yaml
"@
    $out = Update-V4ProfileText -Text $t -Uid $uid -Epoch $epoch
    AssertTrue ($out -match ('uid: ' + $uid + '[\s\S]*updated: ' + $epoch)) 'last target did not gain updated'
    'last target gained updated'
}

Check 'F08-07' 'target line not a list item must fail closed' {
    $t = @"
current: AAA
metadata:
  uid: V4Mngd0001
  note: not a profile entry
- uid: SUB0002
  type: remote
  name: Other
  file: other.yaml
  updated: 222222
"@
    $threw = $false
    try { Update-V4ProfileText -Text $t -Uid $uid -Epoch $epoch | Out-Null } catch { $threw = $true }
    AssertTrue $threw 'non-entry uid was treated as a profile'
    'non-entry rejected'
}

Check 'F08-08' 'append new target leaves all existing blocks intact' {
    $t = @"
current: AAA
- uid: SUB0002
  type: remote
  name: Other
  file: other.yaml
  updated: 222222
"@
    $out = Update-V4ProfileText -Text $t -Uid $uid -Epoch $epoch
    AssertTrue ($out -match 'uid: SUB0002[\s\S]*updated: 222222') 'existing block changed on append'
    AssertTrue ($out -match ('uid: ' + $uid)) 'target not appended'
    AssertTrue ($out -match ('current: ' + $uid)) 'current not set'
    'appended, existing intact'
}

Check 'F08-09' 'CRLF file: foreign block untouched and line endings preserved' {
    $crlf = [string][char]13 + [string][char]10
    $t = 'current: AAA' + $crlf + '- uid: V4Mngd0001' + $crlf + '  type: local' + $crlf + '  name: V4-Managed' + $crlf + '  file: v4-managed.yaml' + $crlf + '- uid: SUB0002' + $crlf + '  type: remote' + $crlf + '  name: Other' + $crlf + '  file: other.yaml' + $crlf + '  updated: 222222' + $crlf
    $out = Update-V4ProfileText -Text $t -Uid $uid -Epoch $epoch
    AssertTrue ($out.Contains($crlf)) 'CRLF line endings were not preserved'
    AssertTrue ($out -match 'uid: SUB0002[\s\S]*updated: 222222') 'foreign updated changed in a CRLF file'
    AssertTrue ($out -match ('uid: ' + $uid + '[\s\S]*?updated: ' + $epoch)) 'target did not get updated in a CRLF file'
    'CRLF preserved; foreign 222222 kept'
}

Check 'F08-10' 'current line after the profile block: update must hit current, not updated' {
    $t = @"
- uid: V4Mngd0001
  type: local
  name: V4-Managed
  file: v4-managed.yaml
- uid: SUB0002
  type: remote
  name: Other
  file: other.yaml
  updated: 222222
current: AAA
"@
    $out = Update-V4ProfileText -Text $t -Uid $uid -Epoch $epoch
    AssertTrue ($out -match ('current: ' + $uid)) 'current line was not rewritten'
    AssertTrue ($out -notmatch 'updated: current:') 'updated line was corrupted with current text'
    AssertTrue (([regex]::Matches($out, '(?m)^current:')).Count -eq 1) 'duplicate current line'
    AssertTrue ($out -match 'uid: SUB0002[\s\S]*updated: 222222') 'foreign updated changed'
    'current updated after insertion; no duplicate'
}

$passed = @($results | Where-Object { $_.pass }).Count
if ($OutFile) {
    $payload = [ordered]@{ ts = (Get-Date).ToString('s'); only = $Only; passed = $passed; total = $results.Count; cases = @($results) }
    [System.IO.File]::WriteAllText($OutFile, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}
Write-Host ''
Write-Host ("RESULT {0}/{1}" -f $passed, $results.Count)
Remove-Item $bench -Recurse -Force -ErrorAction SilentlyContinue
if ($results.Count -gt 0 -and $passed -eq $results.Count) { exit 0 } else { exit 1 }
