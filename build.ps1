# build.ps1 -- compile, simulate, and optionally program the M1 design.
#
#   .\build.ps1             # simulate + compile
#   .\build.ps1 -Sim        # simulate only
#   .\build.ps1 -Prog       # compile + program SRAM (volatile -- lost on
#                           # power-cycle/reset), over USB-Blaster
#   .\build.ps1 -ProgOnly   # program SRAM from the existing .sof, no
#                           # simulate/compile step -- use after a compile
#                           # already succeeded and only the board changed
#                           # (different board plugged in, board power-cycled).
#   .\build.ps1 -Flash      # compile + program the board's config flash
#                           # (non-volatile -- boots the design on its own,
#                           # no USB-Blaster/PC needed after this)
#   .\build.ps1 -FlashOnly  # program the config flash from the existing
#                           # .sof, no simulate/compile step
#   .\build.ps1 -HostB      # target Host B (192.168.1.61, MAC ...:02) instead
#                           # of Host A -- combine with any of the above, e.g.
#                           # .\build.ps1 -HostB -Prog
#   .\build.ps1 -Auto       # ask the board which host it is over its console
#                           # cable and pick -HostB automatically; combine with
#                           # any programming flag, e.g. .\build.ps1 -Auto -Flash
#   .\build.ps1 -Port COM6  # with -Auto, listen on this port only instead of
#                           # scanning every COM port
#
# -Auto exists because the two boards are identical to JTAG -- openFPGALoader
# reports the same EP4CE6 IDCODE for either -- so nothing in the programming
# path can tell them apart, and flashing Host A's bitstream onto Host B gives
# it Host A's IP and MAC. The running design announces "ID HOST=x BLD=yyyy" on
# its console every few seconds, so the console cable can answer the question
# the JTAG cable cannot. After programming, -Auto reads the line back and
# checks the board now reports the build that was just written.
#
# -HostB compiles the *same* RTL through a second Quartus revision
# (enc28j60_eth_hostb.qsf, which only overrides HOST_ID and the output
# directory) rather than a second project -- see plan.md. Its own .sof/.rbf
# live in output_files_hostb so building one host never overwrites the
# other's bitstream; program each board from its own build.
#
# Toolchain paths default to this project's dev machine layout: Quartus Prime
# Lite 25.1 under C:\altera_lite, and openFPGALoader under C:\FPGA\tools.
# Override on the command line or via the QUARTUS_BIN / QUESTA_BIN / OFL_EXE
# environment variables if yours lives elsewhere:
#
#   .\build.ps1 -QuartusBin "D:\intelFPGA_lite\23.1std\quartus\bin64"
#   .\build.ps1 -LoaderExe  "D:\tools\openFPGALoader\openFPGALoader.exe"
#
# -Flash/-FlashOnly need two extra things beyond -Prog/-ProgOnly: the
# "spiOverJtag" bridge bitstream openFPGALoader loads into SRAM first (to
# turn the JTAG link into a passthrough to the board's own config flash chip),
# and the FPGA part name that selects which bridge file to use. Both default
# to this project's dev machine layout -- override via -SojDir/-FpgaPart or
# the OFL_SOJ_DIR / OFL_FPGA_PART environment variables if yours differs.
# The config flash on this board is a Winbond-compatible chip (JEDEC EF 30 13,
# 512 KB) reached through the FPGA's dedicated Active Serial pins -- confirmed
# via `openFPGALoader --detect -f --fpga-part ep4ce622`, 2026-08-23.

param(
    [switch]$Sim,
    [switch]$Prog,
    [switch]$ProgOnly,
    [switch]$Flash,
    [switch]$FlashOnly,
    [switch]$HostB,
    [switch]$Auto,
    [string]$Port,
    [string]$QuartusBin,
    [string]$QuestaBin,
    [string]$LoaderExe,
    [string]$SojDir,
    [string]$FpgaPart
)

$ErrorActionPreference = "Stop"

function Resolve-Tool($param, $envVar, $default) {
    if ($param) { return $param }
    $fromEnv = [Environment]::GetEnvironmentVariable($envVar)
    if ($fromEnv) { return $fromEnv }
    return $default
}

$QUARTUS   = Resolve-Tool $QuartusBin "QUARTUS_BIN"   "C:\altera_lite\25.1std\quartus\bin64"
$QUESTA    = Resolve-Tool $QuestaBin  "QUESTA_BIN"    "C:\altera_lite\25.1std\questa_fse\win64"
$LOADER    = Resolve-Tool $LoaderExe  "OFL_EXE"       "C:\FPGA\tools\openFPGALoader\openFPGALoader.exe"
$SOJ_DIR   = Resolve-Tool $SojDir     "OFL_SOJ_DIR"   "C:\FPGA\tools\share\openFPGALoader"
$FPGA_PART = Resolve-Tool $FpgaPart   "OFL_FPGA_PART" "ep4ce622"
# openFPGALoader's flash path (-f) shells out to cygpath to normalise paths --
# present under Git for Windows, but not on a plain PowerShell PATH. Only
# needed for -Flash/-FlashOnly; a bare "cygpath not recognized" error with no
# other symptom is this exact problem.
$GIT_USR_BIN = "C:\Program Files\Git\usr\bin"

# Quartus names generated files after the *revision*, not the project --
# output_files\enc28j60_eth.sof for Host A, output_files_hostb\
# enc28j60_eth_hostb.sof for Host B (its own qsf sets that output dir).
# ---------------------------------------------------------------------------
# Board identity over the console cable
# ---------------------------------------------------------------------------
# The design prints "ID HOST=A BLD=0002" every ~2.7 s. Listening for it beats
# the alternatives: reading the power-on banner needs a reset (which throws
# away whatever state we are trying to preserve), and sending a query byte
# would collide with the typed-message feature that shares this port.

function Get-BoardId([string]$name, [int]$seconds = 6) {
    $sp = $null
    try {
        $sp = New-Object System.IO.Ports.SerialPort $name,115200,None,8,one
        $sp.Open()
        Start-Sleep -Milliseconds 300
        $sp.ReadExisting() | Out-Null
        $buf = New-Object System.Text.StringBuilder
        $end = (Get-Date).AddSeconds($seconds)
        while ((Get-Date) -lt $end) {
            Start-Sleep -Milliseconds 200
            if ($sp.BytesToRead -gt 0) { [void]$buf.Append($sp.ReadExisting()) }
            $m = [regex]::Match($buf.ToString(), 'ID HOST=([AB]) BLD=([0-9A-F]{4})')
            if ($m.Success) {
                return [pscustomobject]@{
                    Port  = $name
                    Host  = $m.Groups[1].Value
                    Build = $m.Groups[2].Value
                }
            }
        }
        return $null
    } catch {
        # A port held open by a soak or a terminal is not an error worth
        # stopping the build for -- it just is not the board we can see.
        Write-Verbose "${name}: $($_.Exception.Message)"
        return $null
    } finally {
        if ($sp -and $sp.IsOpen) { $sp.Close() }
    }
}

function Find-Boards([string]$only) {
    $ports = if ($only) { @($only) } else { [System.IO.Ports.SerialPort]::GetPortNames() }
    $found = @()
    foreach ($n in $ports) {
        $id = Get-BoardId $n
        if ($id) {
            $found += $id
            Write-Host ("  {0}: Host {1}, build {2}" -f $id.Port, $id.Host, $id.Build)
        }
    }
    return $found
}

# The build identifier the RTL will report once this bitstream is running.
function Get-SourceBuildId {
    $m = Select-String -Path "rtl\eth_top.v" -Pattern "BUILD_ID = 16'h([0-9A-Fa-f]{4})"
    if ($m) { return $m.Matches[0].Groups[1].Value.ToUpper() }
    return $null
}

$detected = $null
if ($Auto) {
    Write-Host "=== Identifying board over the console cable ===" -ForegroundColor Cyan
    $boards = Find-Boards $Port
    if ($boards.Count -eq 0) {
        throw ("No board answered on any console port. Check the console cable, " +
               "or pass -HostB explicitly. (A board mid-flash, powered off, or " +
               "with its port already open elsewhere will not answer.)")
    }
    if ($boards.Count -gt 1) {
        throw ("More than one board answered: " +
               (($boards | ForEach-Object { "$($_.Port)=Host$($_.Host)" }) -join ", ") +
               ". JTAG cannot tell which one the blaster is on, so pass -Port " +
               "<the one being programmed>, or -HostB explicitly.")
    }
    $detected = $boards[0]
    $HostB = [switch]($detected.Host -eq "B")
    Write-Host ("Targeting Host {0} (from {1}, currently running build {2})" -f `
        $detected.Host, $detected.Port, $detected.Build) -ForegroundColor Green
}

$REVISION = if ($HostB) { "enc28j60_eth_hostb" } else { "enc28j60_eth" }
$OUTDIR   = if ($HostB) { "output_files_hostb" } else { "output_files" }

$onlyMode     = $ProgOnly -or $FlashOnly   # program from the existing .sof, no compile
$willFlash    = $Flash -or $FlashOnly
$willProgram  = $Prog -or $Flash -or $onlyMode
# Simulation runs on the plain/-Sim path only -- -Prog and -Flash skip it
# (matching -Prog's original behaviour: a fast compile+program iteration
# loop, on the assumption -Sim was already run separately beforehand).
$willSimulate = -not $onlyMode -and -not ($Prog -or $Flash)

# -ProgOnly/-FlashOnly never simulate, so Questa isn't needed then.
$toolChecks = @(@{p=$QUARTUS;n="Quartus bin64"})
if ($willSimulate) { $toolChecks += @{p=$QUESTA;n="Questa win64"} }
foreach ($t in $toolChecks) {
    if (-not (Test-Path $t.p)) {
        throw "$($t.n) not found at '$($t.p)'. Pass -QuartusBin/-QuestaBin or set QUARTUS_BIN/QUESTA_BIN."
    }
}

# Only checked when actually programming: a full path can be validated up
# front, unlike a bare "openFPGALoader.exe" which depends on PATH at call time.
if ($willProgram -and -not (Test-Path $LOADER)) {
    throw "openFPGALoader not found at '$LOADER'. Pass -LoaderExe or set OFL_EXE."
}
if ($willFlash -and -not (Test-Path $SOJ_DIR)) {
    throw "spiOverJtag bridge directory not found at '$SOJ_DIR'. Pass -SojDir or set OFL_SOJ_DIR."
}

$root = $PSScriptRoot
Set-Location $root

# Converts .sof -> .rbf (this clone USB-Blaster + openFPGALoader combination
# rejects a raw .sof, "Error: wrong file") and programs the board. -ToFlash
# writes the board's non-volatile config flash instead of SRAM -- needs the
# spiOverJtag bridge, which openFPGALoader finds via OPENFPGALOADER_SOJ_DIR
# and --fpga-part. Verified on hardware 2026-08-23.
function Program-Board([switch]$ToFlash) {
    $sof = "$OUTDIR\$REVISION.sof"
    $rbf = "$OUTDIR\$REVISION.rbf"
    if (-not (Test-Path $sof)) {
        throw "$sof not found -- run a normal build first (.\build.ps1 or .\build.ps1 -Prog)."
    }
    $env:PATH = "$QUARTUS;$env:PATH"
    quartus_cpf -c $sof $rbf
    if ($LASTEXITCODE -ne 0) { throw "sof -> rbf conversion failed" }

    if ($ToFlash) {
        Write-Host "=== Programming config flash (non-volatile) ===" -ForegroundColor Cyan
        if (Test-Path $GIT_USR_BIN) { $env:PATH = "$GIT_USR_BIN;$env:PATH" }
        $env:OPENFPGALOADER_SOJ_DIR = $SOJ_DIR
        & $LOADER -c usb-blaster -f --fpga-part $FPGA_PART $rbf
    } else {
        Write-Host "=== Programming board (SRAM, volatile) ===" -ForegroundColor Cyan
        & $LOADER -c usb-blaster $rbf
    }
    if ($LASTEXITCODE -ne 0) { throw "Programming failed -- check WinUSB driver via zadig" }
}

# ---- verify what actually ended up on the board -------------------------
# Only meaningful once the design is running in SRAM: -Flash on its own leaves
# the spiOverJtag bridge loaded, so the console stays silent until a SRAM load
# or a power cycle. This is the check that catches the two failures this
# project hit repeatedly -- programming the wrong board, and testing a node
# that was quietly still running an older bitstream.
function Verify-Board {
    if (-not ($Auto -and $detected)) { return }
    $expect = Get-SourceBuildId
    Start-Sleep -Seconds 2
    $now = Get-BoardId $detected.Port 12
    if (-not $now) {
        Write-Host ("Verify: {0} did not answer after programming. If only the config flash was written, the bridge bitstream is still loaded -- run -ProgOnly or power-cycle, then re-check." -f $detected.Port) -ForegroundColor Yellow
    } elseif ($expect -and $now.Build -ne $expect) {
        Write-Host ("Verify: board reports build {0}, expected {1} -- the new bitstream is NOT running." -f $now.Build, $expect) -ForegroundColor Red
    } elseif ($now.Host -ne $detected.Host) {
        Write-Host ("Verify: board now reports Host {0}, was Host {1} -- identity changed unexpectedly." -f $now.Host, $detected.Host) -ForegroundColor Red
    } else {
        Write-Host ("Verify: Host {0} running build {1}." -f $now.Host, $now.Build) -ForegroundColor Green
    }
}

# ---- program only, from the existing .sof -------------------------------
if ($onlyMode) {
    Program-Board -ToFlash:$FlashOnly
    Verify-Board
    Write-Host "Done." -ForegroundColor Green
    exit 0
}

# ---- simulate ----------------------------------------------------------
if ($willSimulate) {
    Write-Host "=== Simulating (Questa) ===" -ForegroundColor Cyan
    $env:PATH = "$QUESTA;$env:PATH"
    if (-not (Test-Path sim)) { New-Item -ItemType Directory sim | Out-Null }
    Set-Location sim
    if (-not (Test-Path work)) { vlib work }
    # $readmemh resolves relative to the simulation working directory.
    Copy-Item ..\rtl\font5x8.mem . -Force

    vlog -sv ../rtl/spi_master.v ../rtl/i2c_master.v ../rtl/oled_ssd1306.v `
             ../rtl/uart_tx.v ../rtl/uart_rx.v ../rtl/uart_console.v `
             ../rtl/debounce.v ../rtl/net_stack.v ../rtl/eth_top.v `
             ../tb/tb_m1.v ../tb/tb_m2.v ../tb/tb_m3.v ../tb/tb_m4.v ../tb/tb_oled.v ../tb/tb_uart.v
    if ($LASTEXITCODE -ne 0) { throw "vlog failed" }

    foreach ($tb in @("tb_m1", "tb_m2", "tb_m3", "tb_m4", "tb_oled", "tb_uart")) {
        Write-Host "--- $tb ---" -ForegroundColor DarkCyan
        $out = (vsim -c -do "run -all; quit -f" $tb) -join "`n"
        Write-Host $out
        # -join first: on an array, -match/-notmatch filters instead of
        # returning a boolean, so an array test silently always "fails".
        if ($out -notmatch "PASS:") { throw "$tb did not report PASS" }
    }
    Set-Location $root
    if ($Sim) { Write-Host "Simulation passed." -ForegroundColor Green; exit 0 }
}

# ---- synthesise --------------------------------------------------------
Write-Host "=== Compiling (Quartus) -- $REVISION ===" -ForegroundColor Cyan
$env:PATH = "$QUARTUS;$env:PATH"
# Quartus resolves $readmemh relative to the project root, not rtl/, for
# every revision alike.
Copy-Item rtl\font5x8.mem . -Force
quartus_sh --flow compile enc28j60_eth -c $REVISION
if ($LASTEXITCODE -ne 0) { throw "Quartus compile failed -- see $OUTDIR\*.rpt" }

Select-String -Path "$OUTDIR\$REVISION.fit.rpt" `
    -Pattern "Total logic elements|Total registers|Total pins" |
    ForEach-Object { $_.Line.Trim() }

# ---- program -----------------------------------------------------------
if ($willFlash) {
    Program-Board -ToFlash
} elseif ($Prog) {
    Program-Board
}
if ($Prog -or $willFlash) { Verify-Board }

Write-Host "Done." -ForegroundColor Green
