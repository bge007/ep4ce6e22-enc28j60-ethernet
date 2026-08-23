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
    $sof = "output_files\enc28j60_eth.sof"
    if (-not (Test-Path $sof)) {
        throw "$sof not found -- run a normal build first (.\build.ps1 or .\build.ps1 -Prog)."
    }
    $env:PATH = "$QUARTUS;$env:PATH"
    quartus_cpf -c $sof output_files\enc28j60_eth.rbf
    if (-not $?) { throw "sof -> rbf conversion failed" }

    if ($ToFlash) {
        Write-Host "=== Programming config flash (non-volatile) ===" -ForegroundColor Cyan
        if (Test-Path $GIT_USR_BIN) { $env:PATH = "$GIT_USR_BIN;$env:PATH" }
        $env:OPENFPGALOADER_SOJ_DIR = $SOJ_DIR
        & $LOADER -c usb-blaster -f --fpga-part $FPGA_PART output_files\enc28j60_eth.rbf
    } else {
        Write-Host "=== Programming board (SRAM, volatile) ===" -ForegroundColor Cyan
        & $LOADER -c usb-blaster output_files\enc28j60_eth.rbf
    }
    if (-not $?) { throw "Programming failed -- check WinUSB driver via zadig" }
}

# ---- program only, from the existing .sof -------------------------------
if ($onlyMode) {
    Program-Board -ToFlash:$FlashOnly
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
             ../tb/tb_m1.v ../tb/tb_m2.v ../tb/tb_m3.v ../tb/tb_oled.v ../tb/tb_uart.v
    if (-not $?) { throw "vlog failed" }

    foreach ($tb in @("tb_m1", "tb_m2", "tb_m3", "tb_oled", "tb_uart")) {
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
Write-Host "=== Compiling (Quartus) ===" -ForegroundColor Cyan
$env:PATH = "$QUARTUS;$env:PATH"
# Quartus resolves $readmemh relative to the project root, not rtl/.
Copy-Item rtl\font5x8.mem . -Force
quartus_sh --flow compile enc28j60_eth
if (-not $?) { throw "Quartus compile failed -- see output_files\*.rpt" }

Select-String -Path output_files\enc28j60_eth.fit.rpt `
    -Pattern "Total logic elements|Total registers|Total pins" |
    ForEach-Object { $_.Line.Trim() }

# ---- program -----------------------------------------------------------
if ($willFlash) {
    Program-Board -ToFlash
} elseif ($Prog) {
    Program-Board
}

Write-Host "Done." -ForegroundColor Green
