#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'ReproHelpers.ps1')

$cases = @(
  @{ id='F07-01'; pre='snapshot stops app then throws'; fault='snapshot failure'; exp='app state restored; files untouched' },
  @{ id='F07-02'; pre='snapshot ok'; fault='first write fails'; exp='files unchanged; restore attempted; app restarted' },
  @{ id='F07-03'; pre='first write ok'; fault='second write fails'; exp='first write rolled back' },
  @{ id='F07-04'; pre='first two writes ok'; fault='third write fails'; exp='both writes rolled back' },
  @{ id='F07-05'; pre='writes ok; start ok'; fault='chain exit mismatch'; exp='system proxy restored' },
  @{ id='F07-06'; pre='second write fails'; fault='restore and log fail'; exp='exit 40 without throw' },
  @{ id='F07-07'; pre='second write fails'; fault='restore fails'; exp='app reconciliation still attempted' },
  @{ id='F07-08'; pre='clean fixture'; fault='none'; exp='all targets written; proxy owned; owner recorded' },
  @{ id='F07-09'; pre='app was not running before'; fault='second write fails'; exp='app remains stopped' },
  @{ id='F07-10'; pre='writes/start/proxy ok'; fault='owner write fails'; exp='system proxy restored' },
  @{ id='F07-11'; pre='chain verification fails'; fault='wrong exit ip'; exp='exit code 31 preserved' },
  @{ id='F07-12'; pre='clean fixture'; fault='none'; exp='journal cleared after success' },
  @{ id='F07-13'; pre='second write fails'; fault='recovery succeeds'; exp='journal cleared after recovery' },
  @{ id='F07-14'; pre='second write fails'; fault='recovery fails'; exp='journal retained for the next run' },
  @{ id='F07-15'; pre='journal writer fails'; fault='journal disk full'; exp='exit 34 before the first live write' }
)
foreach ($c in $cases) {
  $id = [string]$c.id
  $body = { Invoke-ReproCase -Suite 'F07' -Id $id | Out-Null }.GetNewClosure()
  Register-Test -Id $id -Requirement 'F07' -Precondition ([string]$c.pre) -InjectedFault ([string]$c.fault) -Expected ([string]$c.exp) -Body $body
}
