#Requires -Version 5.1
<#
Static validation for this Skill: frontmatter, required files, internal links,
synthetic examples, and a narrow secret/PII pattern scan. Read-only.
#>
[CmdletBinding()]
param([switch]$Json)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$issues = New-Object System.Collections.Generic.List[string]
$required = @('SKILL.md','README.md','SECURITY.md','scripts','references','tests','examples')
foreach ($r in $required) { if (-not (Test-Path -LiteralPath (Join-Path $root $r))) { $issues.Add('missing ' + $r) } }
$skill = Join-Path $root 'SKILL.md'
if (Test-Path $skill) {
    $t = Get-Content -LiteralPath $skill -Raw
    if ($t -notmatch '(?s)^---\s*\r?\n(.*?)\r?\n---') { $issues.Add('SKILL.md frontmatter missing') }
    else {
        $fm = $Matches[1]
        if ($fm -notmatch '(?m)^name:\s*windows-proxy-doctor\s*$') { $issues.Add('frontmatter name mismatch') }
        if ($fm -notmatch '(?m)^description:\s*\S') { $issues.Add('frontmatter description missing') }
    }
}
$refs = @()
if (Test-Path $skill) { $refs += [regex]::Matches((Get-Content $skill -Raw), 'references/([A-Za-z0-9_.-]+)') | ForEach-Object { $_.Groups[1].Value } }
foreach ($r in ($refs | Select-Object -Unique)) { if (-not (Test-Path -LiteralPath (Join-Path $root ('references/' + $r)))) { $issues.Add('broken reference: ' + $r) } }
$scan = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notmatch '\\.git\\' }
foreach ($f in $scan) {
    $txt = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $txt) { continue }
    if ($txt -match '(?i)(password|passwd|secret|token)\s*[:=]\s*["''][^"'']{6,}') { $issues.Add('possible secret in ' + $f.Name) }
    if ($txt -match 'D:\\Users\\|C:\\Users\\') { $issues.Add('private user path in ' + $f.Name) }
}
$ok = ($issues.Count -eq 0)
$out = [ordered]@{ ok = $ok; issues = @($issues); checkedFiles = @($scan).Count }
if ($Json) { $out | ConvertTo-Json -Depth 4 } else { Write-Host ('SKILL_VALID=' + $ok); $issues | ForEach-Object { Write-Host ('  - ' + $_) } }
if (-not $ok) { exit 1 }
exit 0
