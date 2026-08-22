# M1 bring-up: prove the SPI path to the ENC28J60

Milestone 1 of the [project plan](plan.md).
Exit criterion: **`EREVID` = `0x06` displayed on the LEDs.**

## What the design does

On reset the FSM in `rtl/eth_top.v` runs:

1. ENC28J60 `RESET` held low 2 ms, released, then 10 ms settle.
2. SPI System Reset Command (`0xFF`), then 10 ms.
   The datasheet's `ESTAT.CLKRDY` poll is unreliable after an SRC (errata), so
   this is a flat delay rather than a status poll.
3. `WCR ECON1 = 0x03` — select register bank 3.
4. `RCR EREVID` (`0x12`) — an Ethernet register, so the data byte comes back
   in the second SPI byte with no dummy byte in between. (MAC and MII
   registers *do* need a dummy byte; EREVID does not. Getting this backwards
   is the classic first-read bug.)
5. Value latched to the LEDs, re-read 10× per second.

SPI runs at **12.5 MHz** here (50 MHz ÷ 4), deliberately below the chip's
20 MHz maximum — bring-up over jumper wires should not also be a
signal-integrity experiment. The 20 MHz final configuration comes later from a
40 MHz PLL clock with `CLK_DIV = 1`.

## Reading the LEDs

LEDs are active low; the design drives them so a **lit** LED means a 1 bit.

| LED pattern (`led[4:0]`) | Value | Meaning |
|---|---|---|
| `.  .  #  #  .` | `0x06` | **Correct** — rev B7 silicon, SPI path good |
| all dark | `0x00` | MISO stuck low: no power to the module, MISO not connected, or CS never asserting |
| all lit | `0x1F` | MISO stuck high (floating input pulled up) — check the MISO wire |
| anything else | — | Noise or wrong bank. Reseat wiring, shorten the harness |

Holding **key[0]** shows `erevid[7:3]` instead of `erevid[4:0]`, which
distinguishes a genuine `0x06` from a value whose low bits happen to match:
with the button held, correct silicon shows all LEDs dark.

## Wiring

| ENC28J60 module | FPGA pin | Direction |
|---|---|---|
| `SCK`   | PIN_103 | FPGA → module |
| `SI` (MOSI) | PIN_104 | FPGA → module |
| `SO` (MISO) | PIN_105 | module → FPGA |
| `CS`    | PIN_106 | FPGA → module |
| `RESET` | PIN_110 | FPGA → module |
| `INT`   | PIN_111 | module → FPGA (unused in M1) |

> **Verify these against your board's header silkscreen before plugging in.**
> They are free user I/O in the same region the TM1638 project drives, but
> they were chosen from the other projects' pinouts, not from a header
> diagram.

Two things that cause most first-time failures:

- **Power.** The ENC28J60 draws up to ~180 mA transmitting — more than an
  FPGA board's 3.3 V pin should be asked to supply. Feed the module from its
  own regulator, tie grounds together, and decouple with 100 nF + 10 µF at
  the module.
- **Harness length.** Keep it under ~10 cm and give SCK its own ground
  return. Quartus rejects both `SLEW_RATE` and `CURRENT_STRENGTH` overrides
  on these pins on this device (errors 169303 / 169205), so the SPI lines run
  at default drive — signal integrity is entirely a wiring problem here.

## Building

```powershell
.\build.ps1
```

Simulates then compiles. `-Sim` stops after simulation; `-Prog` also programs
the board via openFPGALoader.

## Results as built

Simulation (`tb/tb_m1.v`, Questa 2025.2) passes against a behavioral
ENC28J60 SPI-slave model — it self-checks that the model saw the hardware
reset and the SRC, that `ECON1` bank bits were set to 3, and that `0x06` came
back and reached the LEDs.

Quartus 25.1 Lite full compile, 0 errors:

| Metric | Value |
|---|---|
| Logic elements | 155 / 6,272 (2 %) |
| Registers | 88 |
| Pins | 17 / 92 |
| M9K / PLLs used | 0 / 0 |
| Worst-case setup slack | +7.29 ns |
| Worst-case hold slack | +0.40 ns |

The full stack is budgeted at ~2,500 LE, so this leaves ample room.

## Toolchain notes

- Quartus Prime Lite 25.1 at `C:\altera_lite\25.1std`. The device name must be
  **`EP4CE6E22C8`** — 25.1 rejects `EP4CE6E22C8N`.
- Questa FSE ships with it at `questa_fse\win64` — no separate simulator
  install needed.
- Every project needs an SDC declaring the 50 MHz clock or the Timing
  Analyzer reports failure purely for lack of a clock definition.
- Programming goes through openFPGALoader + WinUSB at
  `C:\BGE\AI\FPGA\tools`, not Quartus's own jtagd.
