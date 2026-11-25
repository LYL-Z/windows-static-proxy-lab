#Requires -Version 5.1
<#
  Installs and uninstalls under a TEMP allowed root.
  Reads startup and WinINET proxy values only to prove they do not change.
#>
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'Install-ProxyDoctor.ps1'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$sandbox = Join-Path $tempRoot ('proxydoctor-packaging-' + [guid]::NewGuid().ToString('n'))
$junctions = New-Object System.Collections.Generic.List[string]
$startupDest = $null
$exitCode = 0

function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try {
        & $Action
    } catch {
        $message = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$_ }
        if ($message.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "expected '$Pattern' but got '$message'"
        }
        return
    }
    throw "expected '$Pattern' but no error was thrown"
}

function Invoke-Install([string]$DestinationPath, [string]$SourcePath, [string]$Allowed) {
    & $installer -Action Install -Destination $DestinationPath -Source $SourcePath -AllowedRoot $Allowed
}

function Invoke-Uninstall([string]$DestinationPath, [string]$Allowed) {
    & $installer -Action Uninstall -Destination $DestinationPath -AllowedRoot $Allowed
}

function Read-Manifest([string]$DestinationPath) {
    $path = Join-Path $DestinationPath 'install-manifest.json'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    return ([System.IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json)
}

function New-Junction([string]$Link, [string]$Target) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    $output = & cmd.exe /c "mklink /J `"$Link`" `"$Target`""
    if ($LASTEXITCODE -ne 0) { throw "mklink failed ($LASTEXITCODE): $output" }
    $junctions.Add($Link) | Out-Null
}

function Remove-TestJunction([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw "refusing to remove a non-junction: $Path"
    }
    [System.IO.Directory]::Delete($item.FullName)
}

function Read-RegValue($Item, [string]$Name) {
    if ($null -eq $Item) { return '' }
    if (@($Item.GetValueNames()) -notcontains $Name) { return '' }
    return [string]$Item.GetValue($Name)
}

function Get-KeyStamp([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    $item = Get-Item -LiteralPath $Path
    $lines = @(
        foreach ($name in @($item.GetValueNames() | Sort-Object)) {
            '{0}={1}' -f $name, [string]$item.GetValue($name)
        }
    )
    return ($lines -join "`n")
}

function Get-ProxyStamp {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    $item = Get-Item -LiteralPath $path
    $lines = foreach ($name in @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL')) {
        '{0}={1}' -f $name, (Read-RegValue $item $name)
    }
    return ($lines -join "`n")
}

function Get-FolderStamp([string]$Folder) {
    if ([string]::IsNullOrWhiteSpace($Folder)) { return 'missing' }
    if (-not (Test-Path -LiteralPath $Folder)) { return 'missing' }
    try {
        $names = @(Get-ChildItem -LiteralPath $Folder -Force -ErrorAction Stop | Sort-Object Name | ForEach-Object {
            '{0}|{1}|{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks
        })
        return ($names -join "`n")
    } catch {
        return 'denied'
    }
}

function Get-SafetyStamp {
    $text = @(
        (Get-KeyStamp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'),
        (Get-KeyStamp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'),
        (Get-ProxyStamp),
        (Get-FolderStamp ([Environment]::GetFolderPath('Startup'))),
        (Get-FolderStamp ([Environment]::GetFolderPath('CommonStartup')))
    ) -join "`n---`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Assert-InstallerHasNoProxyOrStartupWrites([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path)
    $text = [regex]::Replace($text, '(?s)<#.*?#>', '')
    $kept = foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim().StartsWith('#')) { continue }
        $line
    }
    $code = $kept -join "`n"
    $forbidden = @(
        'Set-ItemProperty',
        'New-ItemProperty',
        'Remove-ItemProperty',
        'netsh',
        'schtasks',
        'reg.exe',
        'reg add',
        'ProxyEnable',
        'ProxyServer',
        'AutoConfigURL',
        'CurrentVersion\Run',
        'Start-Process',
        'StartupApproved'
    )
    foreach ($pattern in $forbidden) {
        if ($code -match [regex]::Escape($pattern)) {
            throw "installer contains forbidden text: $pattern"
        }
    }
}

try {
    if (-not $sandbox.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'test sandbox is not under TEMP'
    }
    Assert-InstallerHasNoProxyOrStartupWrites $installer
    $stampBefore = Get-SafetyStamp
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Write-Output "SANDBOX:$sandbox"

    $source = Join-Path $sandbox 'source'
    $sourceSub = Join-Path $source 'sub'
    New-Item -ItemType Directory -Path $sourceSub -Force | Out-Null
    $chineseName = ([char]0x8BF4).ToString() + ([char]0x660E).ToString() + '.txt'
    [System.IO.File]::WriteAllText((Join-Path $source 'readme.txt'), 'alpha')
    [System.IO.File]::WriteAllText((Join-Path $source 'my note.txt'), 'beta')
    [System.IO.File]::WriteAllText((Join-Path $sourceSub 'note.txt'), 'gamma')
    [System.IO.File]::WriteAllText((Join-Path $source $chineseName), 'delta')

    $allowed = Join-Path $sandbox 'allowed'
    New-Item -ItemType Directory -Path $allowed -Force | Out-Null

    Assert-Throws { Invoke-Install $allowed $source $allowed } 'outside the allowed root'
    if (Test-Path -LiteralPath (Join-Path $allowed 'readme.txt')) { throw 'copied into the allowed root itself' }
    if (Test-Path -LiteralPath (Join-Path $allowed 'install-manifest.json')) { throw 'manifest written on the allowed root' }

    $outsideParent = Join-Path $sandbox 'outside'
    $outside = Join-Path $outsideParent 'app'
    Assert-Throws { Invoke-Install $outside $source $allowed } 'outside the allowed root'
    if (Test-Path -LiteralPath $outside) { throw 'outside destination was created' }

    $escaped = Join-Path $allowed '..\escaped-app'
    Assert-Throws { Invoke-Install $escaped $source $allowed } 'outside the allowed root'
    $escapedFull = [System.IO.Path]::GetFullPath($escaped)
    if (Test-Path -LiteralPath $escapedFull) { throw 'escaped destination was created' }

    $startup = [Environment]::GetFolderPath('Startup')
    if ([string]::IsNullOrWhiteSpace($startup)) { throw 'startup folder is unavailable' }
    $startupDest = Join-Path $startup ('ProxyDoctorPackagingTest-' + [guid]::NewGuid().ToString('n'))
    Assert-Throws { Invoke-Install $startupDest $source (Split-Path -Parent $startup) } 'startup folder'
    if (Test-Path -LiteralPath $startupDest) { throw 'startup destination was created' }
    Assert-Throws { Invoke-Uninstall $startupDest (Split-Path -Parent $startup) } 'startup folder'

    $rootTarget = Join-Path $sandbox 'allowed-target'
    $rootLink = Join-Path $sandbox 'allowed-link'
    New-Junction $rootLink $rootTarget
    $throughRoot = Join-Path $rootLink 'app'
    Assert-Throws { Invoke-Install $throughRoot $source $rootLink } 'reparse point'
    if (Test-Path -LiteralPath (Join-Path $rootTarget 'app')) { throw 'installer wrote through the allowed-root junction' }

    $childTarget = Join-Path $sandbox 'child-target'
    $childLink = Join-Path $allowed 'link'
    New-Junction $childLink $childTarget
    [System.IO.File]::WriteAllText((Join-Path $childTarget 'secret.txt'), 'secret')
    $throughChild = Join-Path $childLink 'payload'
    Assert-Throws { Invoke-Install $throughChild $source $allowed } 'reparse point'
    if (Test-Path -LiteralPath (Join-Path $childTarget 'readme.txt')) { throw 'installer wrote through a child junction' }
    if (-not (Test-Path -LiteralPath (Join-Path $childTarget 'secret.txt'))) { throw 'junction target was modified' }

    $sourceTarget = Join-Path $sandbox 'source-target'
    $sourceLink = Join-Path $source 'linked'
    New-Junction $sourceLink $sourceTarget
    [System.IO.File]::WriteAllText((Join-Path $sourceTarget 'secret.txt'), 'secret')
    $fromLinked = Join-Path $allowed 'from-linked-source'
    Assert-Throws { Invoke-Install $fromLinked $source $allowed } 'reparse point'
    if (Test-Path -LiteralPath $fromLinked) { throw 'linked source created a destination' }
    Remove-TestJunction $sourceLink
    $junctions.Remove($sourceLink) | Out-Null

    $badSource = Join-Path $sandbox 'bad-source'
    New-Item -ItemType Directory -Path $badSource -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $badSource 'install-manifest.json'), '{}')
    [System.IO.File]::WriteAllText((Join-Path $badSource 'ok.txt'), 'ok')
    $badDest = Join-Path $allowed 'bad-dest'
    Assert-Throws { Invoke-Install $badDest $badSource $allowed } 'install-manifest'
    if (Test-Path -LiteralPath $badDest) { throw 'bad source created a destination' }

    $dest = Join-Path $allowed 'app'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dest 'keep.txt'), 'keep')
    Invoke-Install $dest $source $allowed
    $manifest = Read-Manifest $dest
    if ([string]$manifest.algorithm -ne 'SHA256') { throw 'manifest algorithm is not SHA256' }
    $manifestFiles = @($manifest.files)
    if ($manifestFiles.Count -ne 4) { throw "expected 4 manifest files, got $($manifestFiles.Count)" }
    if (@($manifestFiles.path) -contains 'keep.txt') { throw 'manifest includes a pre-existing file' }
    foreach ($entry in $manifestFiles) {
        $target = Join-Path $dest $entry.path
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "missing installed file $($entry.path)" }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($actual -ne $entry.sha256) { throw "hash mismatch $($entry.path)" }
    }
    if ([System.IO.File]::ReadAllText((Join-Path $dest 'keep.txt')) -ne 'keep') { throw 'pre-existing file changed' }
    Invoke-Uninstall $dest $allowed
    foreach ($name in @('readme.txt', 'my note.txt', $chineseName, 'install-manifest.json')) {
        if (Test-Path -LiteralPath (Join-Path $dest $name)) { throw "uninstall left $name" }
    }
    if (Test-Path -LiteralPath (Join-Path $dest 'sub')) { throw 'empty directory was left behind' }
    if ([System.IO.File]::ReadAllText((Join-Path $dest 'keep.txt')) -ne 'keep') { throw 'uninstall changed a pre-existing file' }
    if (-not (Test-Path -LiteralPath $dest)) { throw 'uninstall removed a directory that still had a file' }

    $clean = Join-Path $allowed 'clean'
    Invoke-Install $clean $source $allowed
    Invoke-Uninstall $clean $allowed
    if (Test-Path -LiteralPath $clean) { throw 'uninstall left the destination' }

    $oneSource = Join-Path $sandbox 'one-source'
    New-Item -ItemType Directory -Path $oneSource -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $oneSource 'only.txt'), 'one')
    $oneDest = Join-Path $allowed 'one'
    Invoke-Install $oneDest $oneSource $allowed
    Invoke-Uninstall $oneDest $allowed
    if (Test-Path -LiteralPath $oneDest) { throw 'single-file uninstall left the destination' }

    $emptySource = Join-Path $sandbox 'empty-source'
    New-Item -ItemType Directory -Path $emptySource -Force | Out-Null
    $emptyDest = Join-Path $allowed 'empty'
    Invoke-Install $emptyDest $emptySource $allowed
    $emptyRaw = [System.IO.File]::ReadAllText((Join-Path $emptyDest 'install-manifest.json'))
    if ($emptyRaw -notmatch '"files":\[\]') { throw "empty manifest was $emptyRaw" }
    Invoke-Uninstall $emptyDest $allowed
    if (Test-Path -LiteralPath $emptyDest) { throw 'empty uninstall left the destination' }

    $tamper = Join-Path $allowed 'tamper'
    Invoke-Install $tamper $source $allowed
    $tamperManifest = Read-Manifest $tamper
    $tamperEntries = @($tamperManifest.files)
    $tamperFile = Join-Path $tamper $tamperEntries[0].path
    [System.IO.File]::AppendAllText($tamperFile, 'x')
    Assert-Throws { Invoke-Uninstall $tamper $allowed } 'file hash changed'
    if (-not (Test-Path -LiteralPath $tamperFile)) { throw 'tampered file was deleted' }
    if (-not (Test-Path -LiteralPath (Join-Path $tamper 'install-manifest.json'))) { throw 'manifest removed after refused uninstall' }
    if ($tamperEntries.Count -gt 1) {
        $otherPath = Join-Path $tamper $tamperEntries[1].path
        if (-not (Test-Path -LiteralPath $otherPath)) { throw 'uninstall deleted files after a hash mismatch' }
    }

    $escapeDest = Join-Path $allowed 'escape-app'
    New-Item -ItemType Directory -Path $escapeDest -Force | Out-Null
    $secret = Join-Path $sandbox 'secret.txt'
    [System.IO.File]::WriteAllText($secret, 'secret')
    $secretHash = (Get-FileHash -LiteralPath $secret -Algorithm SHA256).Hash
    $escapeJson = '{"algorithm":"SHA256","files":[{"path":"..\\..\\secret.txt","sha256":"' + $secretHash + '"}]}'
    [System.IO.File]::WriteAllText((Join-Path $escapeDest 'install-manifest.json'), $escapeJson)
    Assert-Throws { Invoke-Uninstall $escapeDest $allowed } 'manifest path escapes the destination'
    if (-not (Test-Path -LiteralPath $secret)) { throw 'manifest path deleted a file outside the destination' }

    $outsideDest = Join-Path $sandbox 'outside-dest'
    New-Item -ItemType Directory -Path $outsideDest -Force | Out-Null
    $outsideFile = Join-Path $outsideDest 'local.txt'
    [System.IO.File]::WriteAllText($outsideFile, 'safe')
    $outsideHash = (Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash
    $outsideJson = '{"algorithm":"SHA256","files":[{"path":"local.txt","sha256":"' + $outsideHash + '"}]}'
    [System.IO.File]::WriteAllText((Join-Path $outsideDest 'install-manifest.json'), $outsideJson)
    Assert-Throws { Invoke-Uninstall $outsideDest $allowed } 'outside the allowed root'
    if (-not (Test-Path -LiteralPath $outsideFile)) { throw 'uninstaller deleted a file outside the allowed root' }

    $missing = Join-Path $allowed 'no-manifest'
    New-Item -ItemType Directory -Path $missing -Force | Out-Null
    Assert-Throws { Invoke-Uninstall $missing $allowed } 'manifest is missing'

    $stampAfter = Get-SafetyStamp
    if ($stampBefore -ne $stampAfter) { throw 'startup or system proxy snapshot changed' }
    Write-Output 'PASS: temp install, hash manifest, outside-root refusal, uninstall, startup and proxy unchanged'
} catch {
    $exitCode = 1
    [Console]::Error.WriteLine($_.Exception.Message)
    [Console]::Error.WriteLine($_.InvocationInfo.PositionMessage)
    [Console]::Error.WriteLine($_.ScriptStackTrace)
} finally {
    $junctionLeft = $false
    foreach ($junction in @($junctions.ToArray())) {
        try {
            Remove-TestJunction $junction
        } catch {
            $junctionLeft = $true
            [Console]::Error.WriteLine($_.Exception.Message)
        }
    }
    if ($startupDest) {
        try {
            if (Test-Path -LiteralPath $startupDest) {
                $item = Get-Item -LiteralPath $startupDest -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    Remove-Item -LiteralPath $startupDest -Recurse -Force
                }
            }
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
        }
    }
    if (-not $junctionLeft -and (Test-Path -LiteralPath $sandbox)) {
        try {
            Remove-Item -LiteralPath $sandbox -Recurse -Force
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
        }
    }
}

exit $exitCode
