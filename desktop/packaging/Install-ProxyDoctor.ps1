#Requires -Version 5.1
<#
  Copies a prepared folder and removes only the files listed in its hash manifest.
  Refuses a destination outside the allowed root, a reparse point, or a Startup folder.
  Does not write logon entries or WinINET proxy settings.
  If a file copy fails, files written by that attempt are removed. A version directory
  created by that attempt is removed when nothing else remains; otherwise install-failed.json
  is left. Another version directory is not modified. Stopping the process mid-copy can
  still leave a partial directory.
  This script has no fault-injection switch on purpose: the failure path is reached by a real
  copy error, and tests provoke one from the outside (an exclusive lock on a source file).
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

function Write-HashManifest([string]$Path, $Entries, $Directories, [bool]$RootCreated) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Entries) {
        $part = '{"path":' + (Get-JsonString ([string]$entry.path)) + ',"sha256":' + (Get-JsonString ([string]$entry.sha256)) + '}'
        [void]$parts.Add($part)
    }
    $dirParts = @($Directories | ForEach-Object { Get-JsonString $_ })
    $json = '{"algorithm":"SHA256","files":[' + ($parts -join ',') + '],"directories":[' +
        ($dirParts -join ',') + '],"rootCreated":' + $RootCreated.ToString().ToLowerInvariant() + '}'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $stage = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($stage, $json, $utf8)
        [System.IO.File]::Move($stage, $Path)
    } finally {
        if ([System.IO.File]::Exists($stage)) { [System.IO.File]::Delete($stage) }
    }
}

function Read-HashManifest([string]$Path) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $json = [System.IO.File]::ReadAllText($Path, $utf8)
    return ($json | ConvertFrom-Json)
}

function Copy-VersionFile([string]$Source, [string]$Target, [int]$AlreadyCopied) {
    # A locked or unreadable source is the real-world failure this rollback exists for, so the
    # count of files already copied is reported instead of the raw I/O text only.
    try {
        [System.IO.File]::Copy($Source, $Target, $false)
    } catch {
        $reason = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = [string]$_ }
        throw ("file copy failed after {0} file(s): {1}" -f $AlreadyCopied, $reason)
    }
}

function Write-FailedInstallMarker([string]$DestinationPath) {
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) { return }
    Assert-PathChainHasNoReparsePoint $DestinationPath
    Assert-NotReparse $DestinationPath
    $marker = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath 'install-failed.json'))
    if (-not (Test-StrictChild $DestinationPath $marker)) { throw 'failed marker escapes the destination' }
    Assert-NotStartupDestination $marker
    $json = '{"status":"failed"}'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $stage = $marker + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($stage, $json, $utf8)
        if ([System.IO.File]::Exists($marker)) { [System.IO.File]::Delete($marker) }
        [System.IO.File]::Move($stage, $marker)
    } finally {
        if ([System.IO.File]::Exists($stage)) { [System.IO.File]::Delete($stage) }
    }
}

function Remove-OwnedFile([string]$DestinationPath, [string]$Target, [string]$Sha256) {
    if (-not (Test-StrictChild $DestinationPath $Target)) { throw 'rollback target escapes the destination' }
    Assert-NotStartupDestination $Target
    Assert-PathChainHasNoReparsePoint $Target
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { return }
    Assert-NotReparse $Target
    if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
        $actual = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $Sha256.ToUpperInvariant()) { throw 'rollback file hash changed' }
    }
    [System.IO.File]::Delete($Target)
}

function Undo-IncompleteInstall($State) {
    # One argument: PowerShell otherwise enumerates the copied-file list into later parameters.
    $DestinationPath = [string]$State.DestinationPath
    $CopiedItems = @($State.CopiedItems)
    $CreatedRelative = @($State.CreatedRelative)
    $RootCreated = [bool]$State.RootCreated
    $leftover = $false
    $manifest = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath 'install-manifest.json'))
    $files = New-Object System.Collections.Generic.List[object]
    $files.Add([pscustomobject]@{ Target = $manifest; Sha256 = '' }) | Out-Null
    foreach ($item in @($CopiedItems)) {
        if ($null -eq $item) { continue }
        $files.Add($item) | Out-Null
    }
    foreach ($item in $files) {
        try {
            Remove-OwnedFile $DestinationPath ([string]$item.Target) ([string]$item.Sha256)
        } catch {
            $leftover = $true
        }
    }
    $relativeDirs = @($CreatedRelative | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    foreach ($relative in @($relativeDirs | Sort-Object { $_.Length } -Descending)) {
        try {
            Assert-SafeRelativePath $relative 'rollback directory escapes the destination'
            $dir = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $relative))
            if (-not (Test-StrictChild $DestinationPath $dir)) { throw 'rollback directory escapes the destination' }
            Assert-NotStartupDestination $dir
            Assert-PathChainHasNoReparsePoint $dir
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            Assert-NotReparse $dir
            if (-not (Get-ChildItem -LiteralPath $dir -Force)) {
                [System.IO.Directory]::Delete($dir)
            } else {
                $leftover = $true
            }
        } catch {
            $leftover = $true
        }
    }
    $stillThere = Test-Path -LiteralPath $DestinationPath -PathType Container
    if ($RootCreated -and $stillThere) {
        try {
            Assert-NotReparse $DestinationPath
            Assert-PathChainHasNoReparsePoint $DestinationPath
            if (-not (Get-ChildItem -LiteralPath $DestinationPath -Force)) {
                [System.IO.Directory]::Delete($DestinationPath)
                $stillThere = $false
            } else {
                $leftover = $true
            }
        } catch {
            $leftover = $true
        }
    }
    if ($stillThere -and ($RootCreated -or $leftover)) {
        try { Write-FailedInstallMarker $DestinationPath } catch { }
    }
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
        Assert-NotStartupDestination $target
        $plan.Add([pscustomobject]@{ Source = $file.FullName; Relative = $relative; Target = $target }) | Out-Null
    }

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) { throw 'destination is a file' }
    $manifestPath = Join-Path $DestinationPath 'install-manifest.json'
    if (Test-Path -LiteralPath $manifestPath) { throw 'destination already has an install-manifest; use a separate version folder' }
    foreach ($item in $plan) {
        Assert-PathChainHasNoReparsePoint $item.Target
        if (Test-Path -LiteralPath $item.Target) { throw 'package would overwrite an existing file; use a separate version folder' }
    }
    $rootCreated = -not (Test-Path -LiteralPath $DestinationPath)
    $entries = New-Object System.Collections.Generic.List[object]
    $created = New-Object System.Collections.Generic.List[string]
    $copied = New-Object System.Collections.Generic.List[object]
    try {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        Assert-NotReparse $DestinationPath
        $destinationPrefix = $DestinationPath + '\'
        foreach ($item in @($plan | Sort-Object Relative)) {
            $parent = Split-Path -Parent $item.Target
            if (-not (Test-Path -LiteralPath $parent)) {
                $dir = $parent
                while ((Test-StrictChild $DestinationPath $dir) -and -not (Test-Path -LiteralPath $dir)) {
                    $created.Add($dir.Substring($destinationPrefix.Length)) | Out-Null
                    $dir = Split-Path -Parent $dir
                }
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Assert-PathChainHasNoReparsePoint $item.Target
            try {
                Copy-VersionFile $item.Source $item.Target $copied.Count
            } catch {
                if (Test-Path -LiteralPath $item.Target -PathType Leaf) {
                    $copied.Add([pscustomobject]@{ Target = $item.Target; Sha256 = '' }) | Out-Null
                }
                throw
            }
            $record = [pscustomobject]@{ Target = $item.Target; Sha256 = '' }
            $copied.Add($record) | Out-Null
            $hash = (Get-FileHash -LiteralPath $item.Target -Algorithm SHA256).Hash.ToUpperInvariant()
            $record.Sha256 = $hash
            $entries.Add([ordered]@{ path = $item.Relative; sha256 = $hash }) | Out-Null
        }
        Write-HashManifest $manifestPath $entries $created $rootCreated
    } catch {
        $copyError = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($copyError)) { $copyError = [string]$_ }
        try {
            $undoState = [pscustomobject]@{
                DestinationPath = $DestinationPath
                CopiedItems = $copied.ToArray()
                CreatedRelative = $created.ToArray()
                RootCreated = [bool]$rootCreated
            }
            Undo-IncompleteInstall $undoState
        } catch {
            try { Write-FailedInstallMarker $DestinationPath } catch { }
        }
        throw $copyError
    }
}

function Remove-EmptyDirectories($Directories) {
    foreach ($dir in @($Directories | Sort-Object Length -Descending)) {
        Assert-PathChainHasNoReparsePoint $dir
        if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Get-ChildItem -LiteralPath $dir -Force)) {
            [System.IO.Directory]::Delete($dir)
        }
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
    $plannedDirs = New-Object System.Collections.Generic.List[string]
    foreach ($relative in $manifest.directories) {
        Assert-SafeRelativePath $relative 'manifest directory escapes the destination'
        $directory = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $relative))
        if (-not (Test-StrictChild $DestinationPath $directory)) { throw 'manifest directory escapes the destination' }
        Assert-NotStartupDestination $directory
        Assert-PathChainHasNoReparsePoint $directory
        $plannedDirs.Add($directory)
    }
    if ($manifest.rootCreated -is [bool] -and $manifest.rootCreated) { $plannedDirs.Add($DestinationPath) }
    foreach ($entry in $rawFiles) {
        if ($null -eq $entry) { throw 'manifest entry is invalid' }
        $relative = [string]$entry.path
        $expected = [string]$entry.sha256
        if ($expected -notmatch '^[a-fA-F0-9]{64}$') { throw 'manifest entry is invalid' }
        Assert-SafeRelativePath $relative 'manifest path escapes the destination'
        $target = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $relative))
        if (-not (Test-StrictChild $DestinationPath $target)) { throw 'manifest path escapes the destination' }
        Assert-NotStartupDestination $target
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
    Remove-EmptyDirectories $plannedDirs
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
