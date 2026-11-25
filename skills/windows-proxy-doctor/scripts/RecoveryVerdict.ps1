#Requires -Version 5.1
<#
  Judges an isolated recovery result. A transaction exit code alone is not success.
  This does not run rollback and does not read the live Windows proxy.
#>
function Test-ProxyDoctorRecoveryResult {
    param($Result)
    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $Result.ScriptStarted) { $reasons.Add('script did not start') }
    if ($Result.Cancelled) { $reasons.Add('cancelled') }
    if ($Result.TimedOut) { $reasons.Add('timed out') }
    if ([int]$Result.ProcessExit -ne 0) { $reasons.Add('wrapper exit') }
    if ([int]$Result.TransactionExit -ne [int]$Result.ExpectedTransactionExit) { $reasons.Add('transaction exit') }
    if (-not $Result.ProfileRestored) { $reasons.Add('profile hash') }
    if (-not $Result.WritesMatch) { $reasons.Add('writes') }
    if (-not $Result.JournalClear) { $reasons.Add('journal') }
    if (-not $Result.LiveUnchanged) { $reasons.Add('live proxy') }
    [pscustomobject]@{
        CompleteSuccess = ($reasons.Count -eq 0)
        Reasons = @($reasons)
    }
}
