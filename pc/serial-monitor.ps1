<#
.SYNOPSIS
    Terminal for the EP4CE6E22 node's serial console over the onboard CH340.

.DESCRIPTION
    Opens the board's COM port at 115200 8N1 and shows what the FPGA sends:
    a banner at reset, a "KEYS ...." line every time a button changes, and an
    "MSG: ..." echo of anything you type. Whatever you type is delivered to the
    OLED's bottom line.

    The FPGA does not echo characters back, so this script echoes locally.

.PARAMETER Port
    COM port, e.g. COM5. Auto-detected from the CH340 if omitted.

.PARAMETER Baud
    Bit rate. Default 115200, which is what the RTL is built for.

.PARAMETER Send
    Send one line and exit, instead of opening an interactive terminal.
    Useful from scripts: .\serial-monitor.ps1 -Send "Hello World"

.PARAMETER List
    List candidate serial ports and exit.

.EXAMPLE
    .\serial-monitor.ps1
    Interactive. Type a line, press Enter, watch it appear on the OLED.
    Esc quits.

.EXAMPLE
    .\serial-monitor.ps1 -Port COM5 -Send "Hello World"
#>
[CmdletBinding()]
param(
    [string] $Port,
    [int]    $Baud = 115200,
    [string] $Send,
    [switch] $List
)

$ErrorActionPreference = "Stop"

function Get-BoardPorts {
    # CH340 shows up with a name like "USB-SERIAL CH340 (COM5)".
    $all = @()
    try {
        $all = Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
               Where-Object { $_.Name -match '\(COM\d+\)' } |
               ForEach-Object {
                   [pscustomobject]@{
                       Port = ([regex]::Match($_.Name, '\((COM\d+)\)')).Groups[1].Value
                       Name = $_.Name
                       IsCH340 = ($_.Name -match 'CH340|CH9102|USB-SERIAL')
                   }
               }
    } catch {
        # Fall back to the raw port list if WMI is unavailable.
        $all = [System.IO.Ports.SerialPort]::GetPortNames() |
               ForEach-Object { [pscustomobject]@{ Port = $_; Name = $_; IsCH340 = $false } }
    }
    return $all
}

if ($List) {
    $ports = Get-BoardPorts
    if (-not $ports) { Write-Host "No serial ports found." -ForegroundColor Yellow; return }
    $ports | Sort-Object -Property @{E={-not $_.IsCH340}}, Port |
        Format-Table @{L='Port';E={$_.Port}},
                     @{L='Likely board';E={ if ($_.IsCH340) {'yes'} else {''} }},
                     @{L='Description';E={$_.Name}} -AutoSize
    return
}

if (-not $Port) {
    $cands = @(Get-BoardPorts | Where-Object IsCH340)
    if ($cands.Count -eq 1) {
        $Port = $cands[0].Port
        Write-Host "Using $Port  ($($cands[0].Name))" -ForegroundColor DarkGray
    } elseif ($cands.Count -gt 1) {
        # Two boards plugged in is the normal case for this project, so name them.
        Write-Host "More than one CH340 found - pass -Port to choose:" -ForegroundColor Yellow
        $cands | Format-Table Port, Name -AutoSize
        return
    } else {
        throw "No CH340 serial port found. Plug the board in, or run with -List to see all ports, or pass -Port COMn."
    }
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout  = 200
$sp.WriteTimeout = 500
# The CH340 does not need flow control here and the FPGA ignores it, but DTR/RTS
# are asserted anyway because some drivers hold the line in reset otherwise.
$sp.DtrEnable = $true
$sp.RtsEnable = $true

try {
    $sp.Open()
} catch {
    throw "Could not open ${Port}: $($_.Exception.Message)`nIs another terminal already holding the port?"
}

try {
    if ($Send) {
        $sp.Write($Send + "`r")
        Start-Sleep -Milliseconds 300
        if ($sp.BytesToRead) { Write-Host $sp.ReadExisting().TrimEnd() }
        Write-Host "Sent to ${Port}: $Send" -ForegroundColor Green
        return
    }

    Write-Host ""
    Write-Host "  $Port at $Baud 8N1. Type a line and press Enter to put it on the OLED." -ForegroundColor Cyan
    Write-Host "  Press the board's buttons to see KEYS lines. Esc quits." -ForegroundColor Cyan
    Write-Host ""

    while ($true) {
        if ($sp.BytesToRead -gt 0) {
            Write-Host -NoNewline $sp.ReadExisting()
        }

        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'Escape'    { Write-Host "`nClosed." -ForegroundColor DarkGray; return }
                'Enter'     { $sp.Write("`r"); Write-Host "" }
                'Backspace' { $sp.Write([char]8);  Write-Host -NoNewline "`b `b" }
                default {
                    $c = $k.KeyChar
                    if ($c -and [int]$c -ge 32 -and [int]$c -le 126) {
                        $sp.Write([string]$c)
                        Write-Host -NoNewline $c      # the FPGA does not echo
                    }
                }
            }
        }

        Start-Sleep -Milliseconds 10
    }
} finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
