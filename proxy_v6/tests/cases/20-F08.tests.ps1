#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'ReproHelpers.ps1')

$cases = @(
  @{ id='F08-01'; pre='target profile has updated; foreign profile exists'; fault='none'; exp='only target updated changes' },
  @{ id='F08-02'; pre='target has no updated; next profile has updated'; fault='target block without updated'; exp='next profile updated unchanged; target gains updated' },
  @{ id='F08-03'; pre='similar UID V4Mngd00010 before target'; fault='prefix-similar uid'; exp='similar profile untouched' },
  @{ id='F08-04'; pre='duplicate exact target UID'; fault='duplicate uid'; exp='fail closed' },
  @{ id='F08-05'; pre='target updated has an inline comment'; fault='inline comment'; exp='target refreshed; comment preserved; foreign unchanged' },
  @{ id='F08-06'; pre='target is the last block and has no updated'; fault='last block without updated'; exp='target gains updated' },
  @{ id='F08-07'; pre='uid appears under metadata, not as a list item'; fault='non-list-item uid'; exp='fail closed, no blind append' },
  @{ id='F08-08'; pre='target absent; foreign profiles exist'; fault='missing target'; exp='append target; current set; existing blocks unchanged' },
  @{ id='F08-09'; pre='CRLF registry; target has no updated'; fault='CRLF line endings'; exp='foreign untouched; target updated; CRLF preserved' },
  @{ id='F08-10'; pre='current line is after the profile block'; fault='insertion shifts current index'; exp='current updated; no duplicate; updated not corrupted' }
)
foreach ($c in $cases) {
  $id = [string]$c.id
  $body = { Invoke-ReproCase -Suite 'F08' -Id $id | Out-Null }.GetNewClosure()
  Register-Test -Id $id -Requirement 'F08' -Precondition ([string]$c.pre) -InjectedFault ([string]$c.fault) -Expected ([string]$c.exp) -Body $body
}
