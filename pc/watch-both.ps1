<#
.SYNOPSIS
    Watch both nodes' serial consoles at once and summarise their health.

.DESCRIPTION
    Opens two CH340 ports simultaneously, generates traffic to both nodes, and
    reports the last NET telemetry line from each plus whether each is still
    answering ARP.

    Watching one node at a time was a real handicap while debugging the RX
    pointer-chain drift: the node that failed was invariably the one whose
    console was unplugged, and several wrong conclusions came from inferring a
    board's state from the far end instead of reading it directly.

.PARAMETER Rounds
    How many measurement rounds. Each round pings both nodes and samples both
    consoles.

.PARAMETER PortA / PortB
    COM ports for Host A and Host B. Which is which is confirmed from the
    banner ("node A"/"node B") if a board resets during the run.

.EXAMPLE
    .\watch-both.ps1 -Rounds 10
#>
[CmdletBinding()]
param(
    [int]    $Rounds = 6,
    [string] $PortA  = "COM5",
    [string] $PortB  = "COM4",
    [string] $IpA    = "192.168.1.60",
    [string] $IpB    = "192.168.1.61"
)

$ErrorActionPreference = "Stop"

function Open-Port([string]$name) {
    try {
        $p = New-Object System.IO.Ports.SerialPort $name,115200,None,8,one
        $p.Open(); Start-Sleep -Milliseconds 200; $p.ReadExisting() | Out-Null
        return $p
    } catch {
        Write-Warning "could not open ${name}: $($_.Exception.Message)"
        return $null
    }
}

# Last NET line wins: it carries the running counters, so the most recent
# sample is the current state. Older lines are just history.
function Last-Net([System.Text.StringBuilder]$sb) {
    # @() forces an array: a single match would otherwise stay a bare string,
    # and $l[-1] would index its last CHARACTER instead of the line.
    $l = @(($sb.ToString() -split "`r`n") | Where-Object { $_ -match '^NET ' })
    # Silence is meaningful, not missing data: the console only emits a NET
    # line when a counter CHANGES, so no line in the sample window means the
    # counters are frozen -- i.e. the node is wedged and processing nothing.
    if ($l) { return $l[-1] } else { return "counters frozen (wedged)" }
}

$pa = Open-Port $PortA
$pb = Open-Port $PortB

try {
    Write-Host ("{0,-6} {1,-9} {2,-52} {3,-9} {4}" -f "round","A-ping","A-telemetry","B-ping","B-telemetry") -ForegroundColor Cyan

    for ($i = 1; $i -le $Rounds; $i++) {
        $sa = New-Object System.Text.StringBuilder
        $sb = New-Object System.Text.StringBuilder

        $ja = Start-Job -ArgumentList $IpA { param($ip) (ping -n 3 $ip) -join "`n" }
        $jb = Start-Job -ArgumentList $IpB { param($ip) (ping -n 3 $ip) -join "`n" }

        $end = (Get-Date).AddSeconds(6)
        while ((Get-Date) -lt $end) {
            Start-Sleep -Milliseconds 150
            if ($pa -and $pa.BytesToRead -gt 0) { [void]$sa.Append($pa.ReadExisting()) }
            if ($pb -and $pb.BytesToRead -gt 0) { [void]$sb.Append($pb.ReadExisting()) }
        }

        $ra = (Receive-Job $ja -Wait); Remove-Job $ja -Force
        $rb = (Receive-Job $jb -Wait); Remove-Job $jb -Force

        # "unreachable" means ARP never resolved; "timed out" means ARP worked
        # and only the ICMP reply is missing, which is the expected M3 state.
        $statA = if ($ra -match 'unreachable') { "DEGRADED" } elseif ($ra -match 'timed out') { "ok" } else { "?" }
        $statB = if ($rb -match 'unreachable') { "DEGRADED" } elseif ($rb -match 'timed out') { "ok" } else { "?" }

        $colour = if ($statA -eq "ok" -and $statB -eq "ok") { "Green" } else { "Yellow" }
        Write-Host ("{0,-6} {1,-9} {2,-52} {3,-9} {4}" -f `
            $i, $statA, (Last-Net $sa), $statB, (Last-Net $sb)) -ForegroundColor $colour
    }
} finally {
    if ($pa) { $pa.Close() }
    if ($pb) { $pb.Close() }
}
