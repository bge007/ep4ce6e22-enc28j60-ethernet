<#
.SYNOPSIS
    Send a text message to the EP4CE6E22 node(s) and have it appear on the OLED.

.DESCRIPTION
    Broadcasts a UDP datagram to port 1234. Every node on the subnet receives
    it and shows the payload on line 3 of its OLED.

    Broadcast is used deliberately rather than addressing a node directly: it
    needs nothing from the board's *transmit* path, only its receive path.
    Receive is confirmed working on real hardware (the ENC28J60's activity LED
    blinks, the console's NET F= counter climbs, EtherTypes decode correctly),
    while the transmit path is still being debugged. So this works today, and
    it drives every node at once without the PC needing an ARP entry for any
    of them.

    The payload is exactly 21 bytes -- the width of one OLED line. Shorter text
    is space-padded, longer text is truncated, which matches what the RTL
    expects (net_stack reads a fixed 21-byte payload).

.PARAMETER Message
    The text to display. Up to 21 characters.

.PARAMETER Broadcast
    Broadcast address to send to. Defaults to 192.168.1.255, the subnet the
    nodes live on (Host A .60, Host B .61).

.PARAMETER Port
    UDP port. Must match UDP_PORT in rtl/net_stack.v. Default 1234.

.PARAMETER Repeat
    Send the message this many times, one second apart. Useful when you want
    time to watch the panel, or to see the activity LED blink.

.EXAMPLE
    .\send-message.ps1 "Hello World"

.EXAMPLE
    .\send-message.ps1 "PING FROM PC" -Repeat 5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Message,
    [string] $Broadcast = "192.168.1.255",
    [int]    $Port      = 1234,
    [int]    $Repeat    = 1
)

$ErrorActionPreference = "Stop"

# net_stack.v reads a fixed-length payload, so pad/truncate to match exactly.
# Anything else would leave stale characters on the panel or overrun the line.
$MSG_LEN = 21
if ($Message.Length -gt $MSG_LEN) {
    Write-Warning "Message is $($Message.Length) chars; truncating to $MSG_LEN."
    $Message = $Message.Substring(0, $MSG_LEN)
}
$payload = $Message.PadRight($MSG_LEN)
$bytes   = [System.Text.Encoding]::ASCII.GetBytes($payload)

$udp = New-Object System.Net.Sockets.UdpClient
try {
    $udp.EnableBroadcast = $true
    $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($Broadcast)), $Port

    for ($i = 1; $i -le $Repeat; $i++) {
        [void]$udp.Send($bytes, $bytes.Length, $ep)
        Write-Host ("[{0}/{1}] sent {2} bytes to {3}:{4}  '{5}'" -f `
                    $i, $Repeat, $bytes.Length, $Broadcast, $Port, $payload) `
                   -ForegroundColor Cyan
        if ($i -lt $Repeat) { Start-Sleep -Seconds 1 }
    }
} finally {
    $udp.Close()
}

Write-Host "Done. The text should now be on line 3 of each node's OLED." -ForegroundColor Green
Write-Host "If it is not, check the serial console: NET F= should be climbing." -ForegroundColor DarkGray
