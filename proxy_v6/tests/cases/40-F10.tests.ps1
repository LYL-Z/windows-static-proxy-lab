#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'ReproHelpers.ps1')

$cases = @(
  @{ id='F10-01'; pre='restore and log both fail'; fault='restore throws; log throws'; exp='returns 40 without throwing; all recovery steps attempted' },
  @{ id='F10-02'; pre='restore ok; start and log fail'; fault='start throws; log throws'; exp='returns 40 without throwing' },
  @{ id='F10-03'; pre='restore and start ok; log fails'; fault='log throws'; exp='original code kept; no throw' },
  @{ id='F10-04'; pre='restore fails; log works'; fault='restore throws'; exp='returns 40' },
  @{ id='F10-05'; pre='restore fails'; fault='restore throws'; exp='process reconciliation still attempted' },
  @{ id='F10-06'; pre='all recovery steps succeed'; fault='none'; exp='original code preserved' },
  @{ id='F10-07'; pre='app was not running before'; fault='failure with snapshot'; exp='stop only; never start' },
  @{ id='F10-08'; pre='file restore ok; proxy restore fails'; fault='proxy delegate throws'; exp='returns 40' },
  @{ id='F10-09'; pre='process state unknown with snapshot'; fault='AppWasRunning=null'; exp='returns 40; no false success' },
  @{ id='F10-10'; pre='owner record restore fails'; fault='owner delegate throws'; exp='returns 40' }
)
foreach ($c in $cases) {
  $id = [string]$c.id
  $body = { Invoke-ReproCase -Suite 'F10' -Id $id | Out-Null }.GetNewClosure()
  Register-Test -Id $id -Requirement 'F10' -Precondition ([string]$c.pre) -InjectedFault ([string]$c.fault) -Expected ([string]$c.exp) -Body $body
}
