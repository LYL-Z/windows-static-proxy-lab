#Requires -Version 5.1
<#
  Copies a prepared folder and removes only the files listed in its hash manifest.
  Refuses a destination outside the allowed root, a reparse point, or a Startup folder.
  Does not write logon entries or WinINET proxy settings.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$Source,
    [Parameter(Mandatory = $true)][string]$AllowedRoot
)
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path is required' }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-StrictChild([string]$Parent, [string]$Child) {
    $parentFull = Get-NormalizedPath $Parent
    $childFull = Get-NormalizedPath $Child
    $prefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar
    return $childFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NotReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'reparse point is not allowed'
    }
}

function Assert-PathChainHasNoReparsePoint([string]$Path) {
    $cursor = Get-NormalizedPath $Path
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            Assert-NotReparse $cursor
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-NotStartupDestination([string]$DestinationPath) {
    $folders = @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )
    $dest = Get-NormalizedPath $DestinationPath
    foreach ($folder in $folders) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        $full = Get-NormalizedPath $folder
        if ($dest.Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'destination must not be a startup folder'
        }
        $prefix = $full + [System.IO.Path]::DirectorySeparatorChar
        if ($dest.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'destination must not be a startup folder'
        }
    }
}

function Assert-SafeRelativePath([string]$Relative, [string]$ErrorMessage) {
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw $ErrorMessage }
    if ($Relative.Contains(':') -or $Relative.StartsWith('\') -or $Relative.StartsWith('/')) {
        throw $ErrorMessage
    }
    if ([System.IO.Path]::IsPathRooted($Relative)) { throw $ErrorMessage }
    foreach ($segment in ($Relative -split '[\\/]+')) {
        if ($segment -match '[. ]$' -or $segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw $ErrorMessage }
    }
}

function Get-PackageFiles([string]$Root) {
    $pending = New-Object System.Collections.Generic.Queue[string]
    $pending.Enqueue((Get-NormalizedPath $Root))
    while ($pending.Count -gt 0) {
        $dir = $pending.Dequeue()
        Assert-NotReparse $dir
        $children = @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $null -ne $_ })
        foreach ($child in $children) {
            Assert-NotReparse $child.FullName
            if ($child.PSIsContainer) {
                $pending.Enqueue($child.FullName)
            } else {
                Write-Output $child
            }
        }
    }
}

function Get-JsonString([string]$Value) {
    $escaped = ''
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -eq 34) { $escaped += '\"' }
        elseif ($code -eq 92) { $escaped += '\\' }
        elseif ($code -lt 32) { $escaped += ('\u{0:x4}' -f $code) }
        else { $escaped += [string]$ch }
    }
    return '"' + $escaped + '"'
}

function Write-HashManifest([string]$Path, $Entries) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Entries) {
        $part = '{"path":' + (Get-JsonString ([string]$entry.path)) + ',"sha256":' + (Get-JsonString ([string]$entry.sha256)) + '}'
        [void]$parts.Add($part)
    }
    $json = '{"algorithm":"SHA256","files":[' + ($parts -join ',') + ']}'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Read-HashManifest([string]$Path) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $json = [System.IO.File]::ReadAllText($Path, $utf8)
    return ($json | ConvertFrom-Json)
}

function Install-Package([string]$DestinationPath, [string]$SourcePath) {
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw 'install requires a source' }
    $sourceFull = Get-NormalizedPath $SourcePath
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Container)) {
        throw 'install requires a source directory'
    }
    if ($sourceFull.Equals($DestinationPath, [StringComparison]::OrdinalIgnoreCase) -or
        (Test-StrictChild $sourceFull $DestinationPath) -or
        (Test-StrictChild $DestinationPath $sourceFull)) {
        throw 'source and destination must be separate'
    }
    Assert-PathChainHasNoReparsePoint $sourceFull
    $packageFiles = @(Get-PackageFiles $sourceFull)
    $sourcePrefix = $sourceFull + '\'
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($file in $packageFiles) {
        if (-not $file.FullName.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'file is outside the source'
        }
        $relative = $file.FullName.Substring($sourcePrefix.Length)
        Assert-SafeRelativePath $relative 'relative path is not safe'
        if ([string]::Equals($relative, 'install-manifest.json', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'source must not contain install-manifest.json'
        }
        $target = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $relative))
        if (-not (Test-StrictChild $DestinationPath $target)) { throw 'copy target escapes the destination' }
        $plan.Add([pscustomobject]@{ Source = $file.FullName; Relative = $relative; Target = $target }) | Out-Null
    }

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) { throw 'destination is a file' }
    $manifestPath = Join-Path $DestinationPath 'install-manifest.json'
    if (Test-Path -LiteralPath $manifestPath) { throw 'destination already has an install-manifest; use a separate version folder' }
    foreach ($item in $plan) {
        Assert-PathChainHasNoReparsePoint $item.Target
        if (Test-Path -LiteralPath $item.Target) { throw 'package would overwrite an existing file; use a separate version folder' }
    }
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    Assert-NotReparse $DestinationPath

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($plan | Sort-Object Relative)) {
        $parent = Split-Path -Parent $item.Target
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Assert-PathChainHasNoReparsePoint $item.Target
        [System.IO.File]::Copy($item.Source, $item.Target, $false)
        $hash = (Get-FileHash -LiteralPath $item.Target -Algorithm SHA256).Hash.ToUpperInvariant()
        $entries.Add([ordered]@{ path = $item.Relative; sha256 = $hash }) | Out-Null
    }
    Write-HashManifest $manifestPath $entries
}

function Remove-EmptyDirectories([string]$Root) {
    $dirs = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Queue[string]
    $pending.Enqueue((Get-NormalizedPath $Root))
    while ($pending.Count -gt 0) {
        $dir = $pending.Dequeue()
        Assert-NotReparse $dir
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Force -Directory)) {
            Assert-NotReparse $child.FullName
            $dirs.Add($child.FullName) | Out-Null
            $pending.Enqueue($child.FullName)
        }
    }
    foreach ($dir in @($dirs.ToArray() | Sort-Object -Descending)) {
        if (-not (Get-ChildItem -LiteralPath $dir -Force)) {
            [System.IO.Directory]::Delete($dir)
        }
    }
    if ((Test-Path -LiteralPath $Root) -and -not (Get-ChildItem -LiteralPath $Root -Force)) {
        Assert-NotReparse $Root
        [System.IO.Directory]::Delete((Get-NormalizedPath $Root))
    }
}

function Uninstall-Package([string]$DestinationPath) {
    Assert-PathChainHasNoReparsePoint $DestinationPath
    $manifestPath = Join-Path $DestinationPath 'install-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'manifest is missing' }
    Assert-NotReparse $manifestPath
    $manifest = Read-HashManifest $manifestPath
    if ($manifest.PSObject.Properties.Name -contains 'algorithm' -and [string]$manifest.algorithm -ne 'SHA256') {
        throw 'manifest hash algorithm is not SHA256'
    }
    $rawFiles = @($manifest.files)
    if ($rawFiles.Count -eq 1 -and $null -eq $rawFiles[0]) { $rawFiles = @() }

    $planned = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $rawFiles) {
        if ($null -eq $entry) { throw 'manifest entry is invalid' }
        $relative = [string]$entry.path
        $expected = [string]$entry.sha256
        if ($expected -notmatch '^[a-fA-F0-9]{64}$') { throw 'manifest entry is invalid' }
        Assert-SafeRelativePath $relative 'manifest path escapes the destination'
        $target = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $relative))
        if (-not (Test-StrictChild $DestinationPath $target)) { throw 'manifest path escapes the destination' }
        Assert-PathChainHasNoReparsePoint $target
        if (Test-Path -LiteralPath $target -PathType Container) { throw 'manifest path is a directory' }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actual -ne $expected.ToUpperInvariant()) { throw 'file hash changed; not deleting it' }
            $planned.Add([pscustomobject]@{ Target = $target; Sha256 = $expected.ToUpperInvariant() }) | Out-Null
        }
    }
    foreach ($item in $planned) {
        Assert-PathChainHasNoReparsePoint $item.Target
        if (-not (Test-Path -LiteralPath $item.Target -PathType Leaf)) { continue }
        $actual = (Get-FileHash -LiteralPath $item.Target -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $item.Sha256) { throw 'file hash changed; not deleting it' }
        Remove-Item -LiteralPath $item.Target -Force
    }
    Remove-Item -LiteralPath $manifestPath -Force
    Remove-EmptyDirectories $DestinationPath
}

$destination = Get-NormalizedPath $Destination
$allowed = Get-NormalizedPath $AllowedRoot
if (-not (Test-StrictChild $allowed $destination)) { throw 'destination is outside the allowed root' }
Assert-NotStartupDestination $destination
Assert-PathChainHasNoReparsePoint $allowed
Assert-PathChainHasNoReparsePoint $destination

if ($Action -eq 'Install') {
    Install-Package $destination $Source
} else {
    Uninstall-Package $destination
}
