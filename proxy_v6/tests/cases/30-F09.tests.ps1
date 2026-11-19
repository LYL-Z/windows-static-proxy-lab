#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'ReproHelpers.ps1')

# The three F09 checks are stateful (one holds the winner lock for the next), so
# they are registered as one isolated suite run rather than independent cases.
Register-Test -Id 'F09-SUITE' -Requirement 'F09' -Precondition 'isolated V4 test root; a winner lock is held by the parent' -InjectedFault 'Init runs while another process holds the lock; loser exits' -Expected 'no settings write before lock; winner lock survives; illegal Init+DryRun exits 11' -Body {
  Invoke-ReproCase -Suite 'F09' -Id '*' | Out-Null
}
