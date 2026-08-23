# build.ps1 -- compile, simulate, and optionally program the M1 design.
#
#   .\build.ps1            # simulate + compile
#   .\build.ps1 -Sim       # simulate only
#   .\build.ps1 -Prog      # compile + program the board over USB-Blaster
#   .\build.ps1 -ProgOnly  # program the board from the existing .sof, no
#                          # simulate/compile step -- use after a compile
#                          # already succeeded and only the board changed
#                          # (different board plugged in, board power-cycled).
#
# Toolchain paths default to this project's dev machine layout: Quartus Prime
# Lite 25.1 under C:\altera_lite, and openFPGALoader under C:\FPGA\tools.
# Override on the command line or via the QUARTUS_BIN / QUESTA_BIN / OFL_EXE
# environment variables if yours lives elsewhere:
#
#   .\build.ps1 -QuartusBin "D:\intelFPGA_lite\23.1std\quartus\bin64"
#   .\build.ps1 -LoaderExe  "D:\tools\openFPGALoader\openFPGALoader.exe"

param(
    [switch]$Sim,
    [switch]$Prog,
    [switch]$ProgOnly,
    [string]$QuartusBin,
    [string]$QuestaBin,
    [string]$LoaderExe
)

$ErrorActionPreference = "Stop"

function Resolve-Tool($param, $envVar, $default) {
    if ($param) { return $param }
    $fromEnv = [Environment]::GetEnvironmentVariable($envVar)
    if ($fromEnv) { return $fromEnv }
    return $default
}

$QUARTUS = Resolve-Tool $QuartusBin "QUARTUS_BIN" "C:\altera_lite\25.1std\quartus\bin64"
$QUESTA  = Resolve-Tool $QuestaBin  "QUESTA_BIN"  "C:\altera_lite\25.1std\questa_fse\win64"
$LOADER  = Resolve-Tool $LoaderExe  "OFL_EXE"     "C:\FPGA\tools\openFPGALoader\openFPGALoader.exe"

# -ProgOnly never simulates or compiles, so Questa isn't needed for it.
$toolChecks = @(@{p=$QUARTUS;n="Quartus bin64"})
if (-not $ProgOnly) { $toolChecks += @{p=$QUESTA;n="Questa win64"} }
foreach ($t in $toolChecks) {
    if (-not (Test-Path $t.p)) {
        throw "$($t.n) not found at '$($t.p)'. Pass -QuartusBin/-QuestaBin or set QUARTUS_BIN/QUESTA_BIN."
    }
}

# Only checked when actually programming: a full path can be validated up
# front, unlike a bare "openFPGALoader.exe" which depends on PATH at call time.
if (($Prog -or $ProgOnly) -and -not (Test-Path $LOADER)) {
    throw "openFPGALoader not found at '$LOADER'. Pass -LoaderExe or set OFL_EXE."
}

$root = $PSScriptRoot
Set-Location $root

# ---- program only, from the existing .sof -------------------------------
if ($ProgOnly) {
    $sof = "output_files\enc28j60_eth.sof"
    if (-not (Test-Path $sof)) {
        throw "$sof not found -- run a normal build first (.\build.ps1 or .\build.ps1 -Prog)."
    }
    Write-Host "=== Programming board (no compile) ===" -ForegroundColor Cyan
    $env:PATH = "$QUARTUS;$env:PATH"
    # Same clone USB-Blaster + openFPGALoader quirk as the -Prog path below:
    # a raw .sof is rejected ("Error: wrong file"), needs the .rbf instead.
    quartus_cpf -c $sof output_files\enc28j60_eth.rbf
    if (-not $?) { throw "sof -> rbf conversion failed" }
    & $LOADER -c usb-blaster output_files\enc28j60_eth.rbf
    if (-not $?) { throw "Programming failed -- check WinUSB driver via zadig" }
    Write-Host "Done." -ForegroundColor Green
    exit 0
}

# ---- simulate ----------------------------------------------------------
if (-not $Prog) {
    Write-Host "=== Simulating (Questa) ===" -ForegroundColor Cyan
    $env:PATH = "$QUESTA;$env:PATH"
    if (-not (Test-Path sim)) { New-Item -ItemType Directory sim | Out-Null }
    Set-Location sim
    if (-not (Test-Path work)) { vlib work }
    # $readmemh resolves relative to the simulation working directory.
    Copy-Item ..\rtl\font5x8.mem . -Force

    vlog -sv ../rtl/spi_master.v ../rtl/i2c_master.v ../rtl/oled_sh1106.v `
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
if ($Prog) {
    Write-Host "=== Programming board ===" -ForegroundColor Cyan
    # This clone USB-Blaster + openFPGALoader combination rejects a raw .sof
    # ("Error: wrong file") and needs the raw bitstream (.rbf) instead.
    # Verified on hardware 2026-08-23.
    $env:PATH = "$QUARTUS;$env:PATH"
    quartus_cpf -c output_files\enc28j60_eth.sof output_files\enc28j60_eth.rbf
    if (-not $?) { throw "sof -> rbf conversion failed" }
    & $LOADER -c usb-blaster output_files\enc28j60_eth.rbf
    if (-not $?) { throw "Programming failed -- check WinUSB driver via zadig" }
}

Write-Host "Done." -ForegroundColor Green
