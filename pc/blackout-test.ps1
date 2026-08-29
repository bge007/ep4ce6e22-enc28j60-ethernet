# Prove the receive-stall watchdog on real hardware.
#
# The watchdog fires after ~30 s without a single frame. On this LAN broadcast
# traffic arrives every second or so, so the only way to create that condition
# deliberately is to take the link away -- done here by shutting the node's
# switch port over SSH, so no cable has to be touched.

param(
    [string]$Port   = "COM5",
    [string]$Iface  = "GigabitEthernet1/0/13",
    [string]$Switch = "SWaccess1@192.168.1.250"
)

$sshOpts = @("-o","BatchMode=yes","-o","StrictHostKeyChecking=no","-o","ConnectTimeout=15","-T",$Switch)

function Set-Port([string]$state) {
    $cmds = "configure terminal`ninterface $Iface`n$state`nend`nexit`n"
    $cmds | & ssh @sshOpts 2>&1 | Out-Null
}

function Sample([System.IO.Ports.SerialPort]$p, [int]$seconds) {
    $sb  = New-Object System.Text.StringBuilder
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 250
        if ($p.BytesToRead -gt 0) { [void]$sb.Append($p.ReadExisting()) }
    }
    $n = @(($sb.ToString() -split "[`r`n]+") | Where-Object { $_ -match 'NET F=' })
    if (-not $n.Count) { return $null }
    $last = $n[-1]
    $f = if ($last -match 'F=(\w{4})') { [Convert]::ToInt32($Matches[1],16) } else { -1 }
    $x = if ($last -match 'X=(\w{4})') { [Convert]::ToInt32($Matches[1],16) } else { -1 }
    $a = if ($last -match 'A=(\w{4})') { [Convert]::ToInt32($Matches[1],16) } else { -1 }
    return [pscustomobject]@{ F=$f; X=$x; A=$a; Line=$last; Count=$n.Count }
}

$p = New-Object System.IO.Ports.SerialPort $Port,115200,None,8,one
$p.Open()
Start-Sleep -Milliseconds 600
$p.ReadExisting() | Out-Null

try {
    $b = Sample $p 12
    "baseline          : F=$($b.F) A=$($b.A) X=$($b.X)"

    Set-Port "shutdown"
    "  >>> port shut. 60 s of genuine silence begins."
    $d = Sample $p 60
    if ($d) { "during blackout   : F=$($d.F) A=$($d.A) X=$($d.X)   (X should have risen)" }
    else    { "during blackout   : no telemetry" }

    Set-Port "no shutdown"
    "  >>> port restored."
    $r = Sample $p 50
    if ($r) { "after restore     : F=$($r.F) A=$($r.A) X=$($r.X)" }

    ""
    if ($d -and $d.X -gt $b.X) {
        "WATCHDOG FIRED on hardware: X $($b.X) -> $($d.X) during the blackout"
    } else {
        "watchdog did NOT fire (X unchanged at $($b.X))"
    }
    if ($r -and $r.F -gt $d.F) {
        "RECOVERED: frames resumed after the link returned ($($d.F) -> $($r.F))"
    } else {
        "did NOT resume receiving after the link returned"
    }
} finally {
    if ($p.IsOpen) { $p.Close() }
    Set-Port "no shutdown"      # never leave the port down
}
