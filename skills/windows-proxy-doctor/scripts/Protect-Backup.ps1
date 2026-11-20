#Requires -Version 5.1
<#
Create a DPAPI (CurrentUser) encrypted copy of a backup directory.
Default is a dry run. -Apply is required to write.
Plaintext originals are not deleted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$OutFile,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-Error 'backup directory not found'; exit 3 }
if (-not $Apply) {
    Write-Host ('DRY RUN: would zip ' + $Path + ' and encrypt to ' + $OutFile)
    Write-Host 'Re-run with -Apply. No files changed.'
    exit 0
}
if ((Test-Path -LiteralPath $OutFile) -or (Test-Path -LiteralPath ($OutFile + '.json'))) {
    throw 'backup output or manifest already exists; choose a new name'
}
Add-Type -AssemblyName System.Security, System.IO.Compression, System.IO.Compression.FileSystem
$source = [IO.DirectoryInfo]::new((Get-Item -LiteralPath $Path).FullName)
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
$sidecar = $destination + '.json'

function Add-BackupEntries($Directory, $Archive, [string]$Prefix) {
    if ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'backup input contains a linked directory' }
    foreach ($item in $Directory.EnumerateFileSystemInfos()) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'backup input contains a linked item' }
        $name = $Prefix + $item.Name
        if ($item -is [IO.DirectoryInfo]) {
            [void]$Archive.CreateEntry($name + '/')
            Add-BackupEntries $item $Archive ($name + '/')
        } else {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive, $item.FullName, $name, [IO.Compression.CompressionLevel]::Optimal)
        }
    }
}

$memory = [IO.MemoryStream]::new()
try {
    $archive = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Create, $true)
    try { Add-BackupEntries $source $archive '' } finally { $archive.Dispose() }
    $bytes = $memory.ToArray()
} finally { $memory.Dispose() }
$enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $zipHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    $encryptedHash = [BitConverter]::ToString($sha.ComputeHash($enc)).Replace('-', '')
} finally { $sha.Dispose() }
$manifest = [ordered]@{
    schema = 1; ts = (Get-Date).ToString('o'); zipSha256 = $zipHash
    encryptedSha256 = $encryptedHash; scope = 'CurrentUser-DPAPI'
}
$metadata = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 3))
$archiveFile = $null
$manifestFile = $null
try {
    try {
        $archiveFile = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $manifestFile = [IO.File]::Open($sidecar, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $archiveFile.Write($enc, 0, $enc.Length)
        $archiveFile.Flush()
        $manifestFile.Write($metadata, 0, $metadata.Length)
        $manifestFile.Flush()
    } finally {
        try { if ($manifestFile) { $manifestFile.Dispose() } }
        finally { if ($archiveFile) { $archiveFile.Dispose() } }
    }
} catch {
    if ($manifestFile) { Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue }
    if ($archiveFile) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
    throw
}
Write-Host ('ENCRYPTED zipSha256=' + $zipHash)
exit 0
