#Requires -Version 5.1

function Get-ProxyDoctorListeners {
    param([int[]]$Ports)

    try {
        # Enumerate once so an empty result for a watched port is distinguishable
        # from failure to query the Windows TCP table.
        $rows = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
            $_.LocalPort -in $Ports -and ($_.LocalAddress -in @('0.0.0.0', '::') -or
                [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($_.LocalAddress)))
        })
        [pscustomobject]@{ queryOk = $true; rows = $rows }
    } catch {
        [pscustomobject]@{ queryOk = $false; rows = @() }
    }
}
