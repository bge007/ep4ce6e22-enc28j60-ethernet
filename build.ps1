# build.ps1 -- compile, simulate, and optionally program the M1 design.
#
#   .\build.ps1            # simulate + compile
#   .\build.ps1 -Sim       # simulate only
#   .\build.ps1 -Prog      # compile + program the board over USB-Blaster
#
# Toolchain paths default to a stock Quartus Prime Lite 25.1 install. Override
# on the command line or via the QUARTUS_BIN / QUESTA_BIN / OFL_EXE environment
# variables if yours lives elsewhere:
#
#   .\build.ps1 -QuartusBin "D:\intelFPGA_lite\23.1std\quartus\bin64"

param(
    [switch]$Sim,
    [switch]$Prog,
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
$LOADER  = Resolve-Tool $LoaderExe  "OFL_EXE"     "openFPGALoader.exe"

foreach ($t in @(@{p=$QUARTUS;n="Quartus bin64"}, @{p=$QUESTA;n="Questa win64"})) {
    if (-not (Test-Path $t.p)) {
        throw "$($t.n) not found at '$($t.p)'. Pass -QuartusBin/-QuestaBin or set QUARTUS_BIN/QUESTA_BIN."
    }
}

$root = $PSScriptRoot
Set-Location $root

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
             ../rtl/debounce.v ../rtl/eth_top.v `
             ../tb/tb_m1.v ../tb/tb_oled.v ../tb/tb_uart.v
    if (-not $?) { throw "vlog failed" }

    foreach ($tb in @("tb_m1", "tb_oled", "tb_uart")) {
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
    & $LOADER -c usb-blaster output_files\enc28j60_eth.sof
    if (-not $?) { throw "Programming failed -- check WinUSB driver via zadig" }
}

Write-Host "Done." -ForegroundColor Green
