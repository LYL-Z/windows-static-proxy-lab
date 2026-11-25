#Requires -Version 5.1
<#
  Copies a prepared Proxy Doctor folder and removes only the files it wrote.
  It does not change startup entries, system proxy, firewall, DNS, or clients.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$Source,
    [Parameter(Mandatory = $true)][string]$AllowedRoot
)
$ErrorActionPreference = 'Stop'

function Test-StrictChild([string]$Parent, [string]$Child) {
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $childFull = [System.IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $prefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar
    return $childFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

$destination = [System.IO.Path]::GetFullPath($Destination)
$allowed = [System.IO.Path]::GetFullPath($AllowedRoot)
if (-not (Test-StrictChild $allowed $destination)) { throw 'destination is outside the allowed root' }
$manifestPath = Join-Path $destination 'install-manifest.json'

if ($Action -eq 'Install') {
    if (-not $Source) { throw 'install requires a source' }
    $source = [System.IO.Path]::GetFullPath($Source)
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $entries = @()
    Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($source.Length).TrimStart('\')
        $target = Join-Path $destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        $entries += [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash }
    }
    [System.IO.File]::WriteAllText($manifestPath, (@{ files = $entries } | ConvertTo-Json -Depth 4))
    return
}

if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'manifest is missing' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
foreach ($entry in @($manifest.files)) {
    $target = [System.IO.Path]::GetFullPath((Join-Path $destination $entry.path))
    if (-not (Test-StrictChild $destination $target)) { throw 'manifest path escapes the destination' }
    if (Test-Path -LiteralPath $target) {
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($actual -ne $entry.sha256) { throw 'file hash changed; not deleting it' }
        Remove-Item -LiteralPath $target -Force
    }
}
Remove-Item -LiteralPath $manifestPath -Force
Get-ChildItem -LiteralPath $destination -Recurse -Directory | Sort-Object FullName -Descending | ForEach-Object {
    if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName -Force }
}
if (-not (Get-ChildItem -LiteralPath $destination -Force)) { Remove-Item -LiteralPath $destination -Force }
