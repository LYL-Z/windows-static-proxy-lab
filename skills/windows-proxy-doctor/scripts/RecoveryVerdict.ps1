#Requires -Version 5.1
<#
  Judges an isolated recovery result. A transaction exit code alone is not success.
  This does not run rollback and does not read the live Windows proxy.
#>
function Test-RecoveryBool {
    param($Result, [string]$Name, $Reasons)
    $property = $Result.PSObject.Properties[$Name]
    if (-not $property) { $Reasons.Add('missing ' + $Name); return $false }
    if ($property.Value -isnot [bool]) { $Reasons.Add('bad type ' + $Name); return $false }
    return [bool]$property.Value
}

function Test-RecoveryInt {
    param($Result, [string]$Name, $Reasons)
    $property = $Result.PSObject.Properties[$Name]
    if (-not $property) { $Reasons.Add('missing ' + $Name); return $null }
    $value = $property.Value
    $parsed = $null
    $integral = $false
    if ($value -is [int]) {
        $parsed = $value
        $integral = $true
    }
    elseif ($value -is [long]) {
        if ($value -ge [int64][int]::MinValue -and $value -le [int64][int]::MaxValue) {
            $parsed = [int]$value
            $integral = $true
        }
    }
    if (-not $integral) { $Reasons.Add('bad type ' + $Name); return $null }
    return $parsed
}

function Test-ProxyDoctorRecoveryWrites {
    param([string]$Writes)
    if ([string]::IsNullOrEmpty($Writes)) { return $false }
    $lines = @($Writes -split "`r`n|`n|`r" | Where-Object { $_ -ne '' })
    return ($lines.Count -eq 1 -and $lines[0].Trim() -eq 'enabled=0 server=old:8080')
}

function Test-ProxyDoctorRecoveryResult {
    param($Result)
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Result) { $reasons.Add('missing result') }
    else {
        $started = Test-RecoveryBool $Result 'ScriptStarted' $reasons
        $cancelled = Test-RecoveryBool $Result 'Cancelled' $reasons
        $timedOut = Test-RecoveryBool $Result 'TimedOut' $reasons
        $profile = Test-RecoveryBool $Result 'ProfileRestored' $reasons
        $writes = Test-RecoveryBool $Result 'WritesMatch' $reasons
        $journal = Test-RecoveryBool $Result 'JournalClear' $reasons
        $live = Test-RecoveryBool $Result 'LiveUnchanged' $reasons
        $process = Test-RecoveryInt $Result 'ProcessExit' $reasons
        $transaction = Test-RecoveryInt $Result 'TransactionExit' $reasons
        $expected = Test-RecoveryInt $Result 'ExpectedTransactionExit' $reasons
        if ($reasons.Count -eq 0) {
            if (-not $started) { $reasons.Add('script did not start') }
            if ($cancelled) { $reasons.Add('cancelled') }
            if ($timedOut) { $reasons.Add('timed out') }
            if ($process -ne 0) { $reasons.Add('wrapper exit') }
            if (($expected -notin @(0, 32, 33, 34, 40, 41)) -or ($transaction -ne $expected)) { $reasons.Add('transaction exit') }
            if (-not $profile) { $reasons.Add('profile hash') }
            if (-not $writes) { $reasons.Add('writes') }
            $writesProperty = $Result.PSObject.Properties['Writes']
            if ($writesProperty) {
                $rawWrites = $writesProperty.Value
                if ($rawWrites -isnot [string] -or -not (Test-ProxyDoctorRecoveryWrites $rawWrites)) {
                    $reasons.Add('raw writes')
                }
            }
            if (-not $journal) { $reasons.Add('journal') }
            if (-not $live) { $reasons.Add('live proxy') }
        }
    }
    [pscustomobject]@{
        CompleteSuccess = ($reasons.Count -eq 0)
        Reasons = @($reasons)
        EvidenceScope = 'LiveUnchanged compares the proxy selection at the start and end only.'
    }
}
