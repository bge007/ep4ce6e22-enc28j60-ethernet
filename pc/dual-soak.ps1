# Soak both nodes from a single foreground process.
#
# Deliberately not two background jobs: launching those has repeatedly produced
# empty logs (the port ends up held by a leftover process, or the child exits
# before sampling), and a silent logger is worse than no logger -- it looks
# like a wedged node.

param([int]$Seconds = 480)

function Parse($line) {
    if (-not $line) { return $null }
    # A line still arriving is a partial line: every field must be present
    # before any of it is trusted, or ToInt32 throws on an empty capture.
    foreach ($k in 'F','A','X','R') {
        if (-not ([regex]("$k=(\w{4})")).Match($line).Success) { return $null }
    }
    [pscustomobject]@{
        F = [Convert]::ToInt32(([regex]'F=(\w{4})').Match($line).Groups[1].Value, 16)
        A = [Convert]::ToInt32(([regex]'A=(\w{4})').Match($line).Groups[1].Value, 16)
        X = [Convert]::ToInt32(([regex]'X=(\w{4})').Match($line).Groups[1].Value, 16)
        R = [Convert]::ToInt32(([regex]'R=(\w{4})').Match($line).Groups[1].Value, 16)
    }
}

$pa = New-Object System.IO.Ports.SerialPort COM5,115200,None,8,one
$pb = New-Object System.IO.Ports.SerialPort COM6,115200,None,8,one
$pa.Open(); $pb.Open()
Start-Sleep -Milliseconds 700
$pa.ReadExisting() | Out-Null; $pb.ReadExisting() | Out-Null

$sa = New-Object System.Text.StringBuilder
$sb = New-Object System.Text.StringBuilder
$firstA = $null; $firstB = $null
$stallA = 0; $stallB = 0; $lastFA = -1; $lastFB = -1
$t0 = Get-Date
$nextPing = $t0
$nextMark = $t0.AddSeconds(120)

try {
    while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
        if ((Get-Date) -ge $nextPing) {
            Start-Job { ping -n 2 192.168.1.60 | Out-Null; ping -n 2 192.168.1.61 | Out-Null } | Out-Null
            $nextPing = (Get-Date).AddSeconds(6)
            Get-Job -State Completed | Remove-Job -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 400
        if ($pa.BytesToRead -gt 0) { [void]$sa.Append($pa.ReadExisting()) }
        if ($pb.BytesToRead -gt 0) { [void]$sb.Append($pb.ReadExisting()) }

        $la = @(($sa.ToString() -split "[`r`n]+") | Where-Object { $_ -match 'NET F=' })
        $lb = @(($sb.ToString() -split "[`r`n]+") | Where-Object { $_ -match 'NET F=' })
        if ($la.Count -and -not $firstA) { $firstA = Parse $la[-1] }
        if ($lb.Count -and -not $firstB) { $firstB = Parse $lb[-1] }

        # track the longest run with no new frame, which is what a stall looks like
        $pa_ = if ($la.Count) { Parse $la[-1] } else { $null }
        if ($pa_) { $f = $pa_.F; if ($f -ne $lastFA) { $lastFA = $f; $stallA = 0 } else { $stallA += 0.4 } }
        $pb_ = if ($lb.Count) { Parse $lb[-1] } else { $null }
        if ($pb_) { $f = $pb_.F; if ($f -ne $lastFB) { $lastFB = $f; $stallB = 0 } else { $stallB += 0.4 } }
        if (-not $script:worstA -or $stallA -gt $script:worstA) { $script:worstA = $stallA }
        if (-not $script:worstB -or $stallB -gt $script:worstB) { $script:worstB = $stallB }

        if ((Get-Date) -ge $nextMark) {
            $el = [int]((Get-Date) - $t0).TotalSeconds
            "  t+{0,3}s  A: {1}   B: {2}" -f $el, $la[-1], $lb[-1]
            $nextMark = (Get-Date).AddSeconds(120)
        }
    }

    $lastA = Parse (@(($sa.ToString() -split "[`r`n]+") | Where-Object { $_ -match 'NET F=' })[-1])
    $lastB = Parse (@(($sb.ToString() -split "[`r`n]+") | Where-Object { $_ -match 'NET F=' })[-1])
    ""
    "{0,-8} {1,8} {2,8} {3,9} {4,10} {5,12}" -f "node","frames","arp","replies","re-inits","longest gap"
    "{0,-8} {1,8} {2,8} {3,9} {4,10} {5,11:N1}s" -f "Host A", ($lastA.F-$firstA.F), ($lastA.A-$firstA.A), ($lastA.R-$firstA.R), ($lastA.X-$firstA.X), $script:worstA
    "{0,-8} {1,8} {2,8} {3,9} {4,10} {5,11:N1}s" -f "Host B", ($lastB.F-$firstB.F), ($lastB.A-$firstB.A), ($lastB.R-$firstB.R), ($lastB.X-$firstB.X), $script:worstB
} finally {
    if ($pa.IsOpen) { $pa.Close() }
    if ($pb.IsOpen) { $pb.Close() }
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
}
