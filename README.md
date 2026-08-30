# EP4CE6E22 + ENC28J60 — a hardware Ethernet stack in Verilog

Two **EP4CE6E22C8** Cyclone IV E boards, each driving a Microchip **ENC28J60**
10 Mbps Ethernet controller over SPI, joined through a **10/100 switch** with
ordinary patch cables — with the ARP / ICMP / UDP stack built as pure HDL
rather than firmware on a soft CPU.

The target is the practical ceiling of 10Base-T: **~9.57 Mbit/s** of UDP
payload, which is what 1,472-byte datagrams work out to once framing overhead
is accounted for. See [docs/plan.md](docs/plan.md) for that arithmetic and the
design rationale.

> ### Status: M1–M4 working on real hardware — ping replies, and button
> state crosses between nodes. M5 not started
>
> Both nodes have been flashed and tested on real EP4CE6E22 + ENC28J60
> boards. `EREVID` reads back `0x06` on the LEDs and OLED, the serial console
> and button input work, and M2's RX/TX buffer, MAC filter, MAC address and
> `RXEN` are written with the `ECON1` readback confirmed over the real UART.
>
> **M3's ARP responder now answers on the wire.** `ping` moved from
> "Destination host unreachable" to "Request timed out" — the expected M3
> result, since ICMP echo is deferred — confirmed four ways: the Windows ARP
> cache resolves, the Cisco 2960 learns both MAC addresses, the switch port's
> `InUcastPkts` climbs, and the node's own console counters advance. Getting
> there took two hardware-only bugs that no amount of simulation would have
> surfaced; both are written up in [docs/enc28j60.md](docs/enc28j60.md):
>
> - **Every transmitted frame had a bad CRC.** The transmit status vector read
>   back `s2=0x90` — Transmit Done, but with the CRC-error bit set. Switches
>   discard bad-CRC frames silently, so the symptom was simply that nothing
>   ever arrived. Fixed with a per-packet control byte of `0x07`, which forces
>   pad and CRC generation per frame rather than relying on `MACON3`.
> - **Bank selects were switching the receiver off.** `ECON1` holds the
>   bank-select bits *and* `RXEN`, so a whole-byte `WCR` of `0x00` meaning
>   "select bank 0" also cleared `RXEN`. Both nodes would run for a while and
>   then stop receiving with their counters frozen. Fixed by moving every
>   `ECON1` access to the `BFS`/`BFC` bit-field opcodes, which touch only the
>   masked bits. `tb_m3`/`tb_m4` now assert that `RXEN` is never dropped
>   outside an `RXRST` pulse, and that assertion fails against the old code.
>
> **M4 works: the headline demo runs.** A line typed on Host A's serial
> console appears on Host B's OLED, and messaging is bidirectional — each
> message increments only the receiving node's counter. Getting there needed
> one more hardware-only fix, and it is the most instructive of the lot:
>
> - **A single SPI timing violation had been corrupting the MAC setup all
>   along.** `TCSH`, the CS hold time, is 10 ns for ETH registers but **210 ns
>   for MAC and MII registers**. This design raised CS one clock (20 ns) after
>   the last byte, so ETH access worked perfectly while every MAC register
>   write silently failed to commit. `MAADR` never held the MAC address, so
>   each node answered broadcast ARP and dropped every unicast frame sent to
>   it — which is exactly why board-to-board messaging could not work. It also
>   explains the earlier bad-CRC transmissions (`MACON3.TXCRCEN` never took)
>   and why MAC-register readback had been written off as unworkable silicon.
>
> A 15-minute soak with both nodes on the fixed build: 1,009 and 1,316 frames,
> zero receive-chain corruptions on either, both still answering afterwards —
> and with CS held correctly, the MAC configuration is finally the one the
> design intends rather than the part's reset defaults.
>
> What's still open: the ENC28J60's own link LED hasn't been visually
> confirmed, and the MAC-register (`MACON1`/`MACON3`) readback diagnostic was
> tried and dropped (two different guesses at the SPI read protocol for
> MAC-type registers both produced wrong values on real hardware) — that
> doesn't affect the writes themselves, only my ability to read them back.

---

## What works today

**M1 — prove the SPI path.** The design resets the ENC28J60, issues the soft
reset opcode, selects register bank 3, reads `EREVID`, and displays it on the
board's five LEDs. Rev B7 silicon reads `0x06`, so LEDs 1 and 2 lit is the
pass condition. It re-reads ten times a second, so a loose wire shows up as
flicker rather than a stuck value.

That sounds trivial, and it is deliberately the smallest thing that proves
something real: a correct `EREVID` means the SPI master, the clock divider,
the opcode encoding, the bank switching, the wiring, and the module's power
are all simultaneously working.

| | |
|---|---|
| Simulation | Passes — five self-checking testbenches, against behavioral ENC28J60 models (SPI with per-bank registers for M2; full 8 KB buffer memory with RBM/WBM pointer emulation for M3's ARP responder) and SSD1306 (I²C) plus a UART loopback |
| Quartus compile | 0 errors |
| Logic elements | 2,176 / 6,272 (35%) |
| Worst-case setup slack | +7.85 ns |
| Worst-case hold slack | +0.19 ns |
| Hardware | M1 confirmed, M2's RXEN confirmed (`ECON1` readback), M3 ARP answering on both nodes (`ping`: "unreachable" → "timed out") |

**The OLED display also works.** Each node drives a 1.3" 128×64 SSD1306 panel
over I²C showing the board identity, the live EREVID readback, the host's IP,
a build identifier (`BLD xxxx`, so the running image is identifiable from the
panel alone) and a message line. Line 3 is the hook for milestone 4: Host A will write what
it transmits, Host B what it receives. See [docs/oled.md](docs/oled.md) —
including the two traps, powering it at 3.3 V rather than the 5 V on the
silkscreen and the panel's mislabelled datasheet (packaged as "SH1106", real
silicon confirmed SSD1306), plus a
[reset-button gotcha](docs/oled.md#troubleshooting-panel-blank-after-power-up-despite-clean-ic)
seen on real hardware after reflashing.

**And a serial console, on the board's onboard CH340** — one USB-C cable
carries power and the terminal, no dongle needed. It prints a banner at reset,
a line every time a button changes, and takes a line you type and puts it on
the OLED. See [docs/serial-console.md](docs/serial-console.md).

```powershell
.\pc\serial-monitor.ps1
```
```
EP4CE6E22 node A ready
KEYS 0...
KEYS 0.2.
MSG: Hello World
```

The OLED mirrors it — the four buttons on line 2, the typed message on line 3:

```
HOST A 192.168.1.60
EREVID 0x06 OK
KEYS 0.2.
Hello World
```

The Ethernet stack is budgeted at ~2,500 LE on top of this, which still fits
in the remaining 4,773.

## Bill of materials

A two-node link means two of nearly everything. Prices are rough marketplace
figures in USD to give a sense of scale — they are not quotes and they drift.

### Per node — buy two of each

| # | Item | Qty | Spec that matters | ~$ |
|---|---|---|---|---|
| 1 | EP4CE6E22 Cyclone IV E core board | 1 | `EP4CE6E22C8N`, 144-LQFP, onboard CH340 + USB-C, 5 LEDs, 4 keys, 50 MHz osc | 12–20 |
| 2 | ENC28J60 Ethernet module | 1 | **must** carry the RJ45 jack with integrated magnetics (HanRun `HR911105A` or equivalent) and a 25 MHz crystal; **3.3 V logic** | 3–6 |
| 3 | 1.3" I²C OLED, 128×64 | 1 | 4-pin (VCC/GND/SCL/SDA). Controller is **SSD1306** (the panel's own datasheet mislabels it SH1106 — see [docs/oled.md](docs/oled.md)), panel QG-2864KSWLG01. **Run it at 3.3 V — see the warning below** | 4–8 |
| 4 | USB-C cable | 1 | data-capable, not charge-only — it carries power *and* the CH340 serial port | 2–4 |
| 5 | 100 nF ceramic capacitor | 1 | decoupling across the ENC28J60's VCC/GND, as close to the header as you can get | <1 |
| 6 | 10 µF capacitor | 1 | same place; ceramic or electrolytic both fine | <1 |

### Shared across both nodes — buy one

| # | Item | Qty | Spec that matters | ~$ |
|---|---|---|---|---|
| 7 | **10/100 switch**, any unmanaged 5-port | 1 | does the MDI/MDI-X crossing the ENC28J60 cannot do itself — see the warning below | 5–10 |
| 8 | Cat5e patch cables, **straight-through** | 2 | ordinary cables, nothing to crimp or verify — one board to each switch port | 2–4 |
| 9 | Female-to-female DuPont jumpers, 2.54 mm | 24 used | buy a 40-way ribbon. **10 cm if you can find it**, 20 cm at the outside — see harness length below | 2–4 |
| 10 | USB-Blaster JTAG programmer | 1 | 10-pin ribbon included; one programmer flashes both boards in turn | 5–10 |
| 11 | USB power source | 1 | a powered hub or mains adapter, ≥1 A per board. A low-current laptop port is the usual cause of flaky behaviour | 5–12 |

Rough total for a complete two-node build: **$65–115**.

> Already have a crossover cable, or a crimp tool to make one? Skip the switch
> and cable it direct between the two boards instead — same $ either way,
> roughly, and it additionally unlocks forced full duplex (see
> [docs/plan.md](docs/plan.md#duplex)). Neither is required over the other;
> the switch is simply what is easiest to find right now.

### Only if you hit rail sag

| # | Item | Qty | When you need it | ~$ |
|---|---|---|---|---|
| 12 | AMS1117-3.3 regulator module, or a bench supply | 2 | Only if the link drops or the FPGA resets *specifically while transmitting*. See [Before you power anything on](#before-you-power-anything-on) | 1–3 |
| 13 | Multimeter | 1 | **Not really optional.** Confirming 3.3 V at both modules — and that the OLED's I²C lines idle at 3.3 V, not 5 V — before connecting signal wires | — |

### Software — all free

| Item | Notes |
|---|---|
| Quartus Prime Lite 25.1 | Questa FSE simulator ships bundled; no separate install |
| [openFPGALoader](https://github.com/trabucayre/openFPGALoader) | Programming path that works with clone blasters |
| [Zadig](https://zadig.akeo.ie/) | Only if your USB-Blaster is a clone and needs the WinUSB driver |
| Wireshark | Optional, for watching frames when testing a node against a PC |

### Five purchasing traps

1. **Do not connect the two boards with a plain patch cable and no switch.**
   The ENC28J60 has no Auto-MDIX and no manual MDI/MDI-X swap, so a
   straight-through cable direct between two boards wires transmitter to
   transmitter on both ends and the link LED never lights. This project uses
   **any cheap 10/100 switch with two ordinary patch cables** — the switch's
   ports do the crossing internally, and it is easier to find than a crossover
   cable. A direct crossover cable also works if you have one, and additionally
   unlocks forced full duplex, but it is not required — the switch path is
   what this repo is built and documented against. See
   [docs/wiring.md](docs/wiring.md).
2. **Female-to-female jumpers, not male-to-female.** Both the FPGA board
   headers and the module's 2×5 header present *male* pins. Male-to-female
   ribbons are the more common purchase and will not connect these two boards.
3. **Short jumpers.** SPI runs at 12.5 MHz in milestone 1 and 20 MHz in the
   final design, and Quartus rejects both slew-rate and drive-strength
   overrides on this device — so signal integrity is entirely down to wiring.
   Keep the harness under ~10 cm. A 30 cm ribbon is a false economy.
4. **Check the ENC28J60 module is 3.3 V logic.** The classic breakout is, and
   connects straight to the FPGA. Some variants aimed at 5 V Arduino boards
   add level shifting; one of those driving 5 V back into a Cyclone IV input
   will damage it.
5. **The OLED is sold as a 5 V module — run it at 3.3 V anyway.** Its SDA and
   SCL pull-ups go to its own VCC, so powering it at 5 V puts 5 V on the I²C
   lines and straight into a 3.3 V FPGA bank. At 3.3 V the pull-ups are 3.3 V
   and everything is safe, which is also what the SSD1306 wants — VDD is
   1.65–3.3 V. Measure SDA and SCL against ground before
   connecting them. Details in [docs/oled.md](docs/oled.md).

### Building with only one FPGA board

If you have one board rather than two, most of the project still works: point
the node at a PC instead of a second board. Milestones 1 through 4 — SPI
readback, link up, ping, and UDP echo — all run fine against a PC's NIC, and
you get Wireshark on the other end, which is a genuinely better debugging
position than two silent FPGAs. You need a second board only for the two-node
demo itself. A PC link needs no switch: almost every PC NIC made in the last
twenty years has Auto-MDIX and detects and swaps automatically, so a plain
straight-through cable to a PC just works.

## Repository layout

| Path | Contents |
|---|---|
| [`rtl/spi_master.v`](rtl/spi_master.v) | Byte-streaming SPI master, mode 0, burst-capable |
| [`rtl/i2c_master.v`](rtl/i2c_master.v) | Write-only open-drain I²C master, 400 kHz |
| [`rtl/oled_ssd1306.v`](rtl/oled_ssd1306.v) | SSD1306 OLED driver: init, page addressing, 4×21 text |
| [`rtl/font5x8.mem`](rtl/font5x8.mem) | ASCII 32–126 font, generated — don't hand-edit |
| [`rtl/uart_tx.v`](rtl/uart_tx.v), [`rtl/uart_rx.v`](rtl/uart_rx.v) | 8N1 UART at 115200 |
| [`rtl/uart_console.v`](rtl/uart_console.v) | Banner, key lines, received-line buffer, echo |
| [`rtl/debounce.v`](rtl/debounce.v) | Four button debouncers with press/release pulses |
| [`rtl/net_stack.v`](rtl/net_stack.v) | M3: ARP responder, RX/TX engine over the ENC28J60 buffer |
| [`rtl/eth_top.v`](rtl/eth_top.v) | Top level: EREVID read, LEDs, OLED, buttons, console |
| [`tb/tb_m1.v`](tb/tb_m1.v) | Self-checking testbench + behavioral ENC28J60 SPI-slave model |
| [`tb/tb_m2.v`](tb/tb_m2.v) | Self-checking testbench + per-bank ENC28J60 register model (M2) |
| [`tb/tb_m3.v`](tb/tb_m3.v) | Self-checking testbench + full-buffer ENC28J60 model (M3 ARP) |
| [`tb/tb_oled.v`](tb/tb_oled.v) | Self-checking testbench + behavioral SSD1306 I²C slave model |
| [`tb/tb_uart.v`](tb/tb_uart.v) | Self-checking UART loopback and console testbench |
| [`pc/serial-monitor.ps1`](pc/serial-monitor.ps1) | PowerShell terminal for the board's COM port |
| [`docs/oled.md`](docs/oled.md) | SSD1306 vs. the mislabelled datasheet, the 3.3 V warning, driver internals |
| [`docs/serial-console.md`](docs/serial-console.md) | UART pins, buttons, PowerShell usage |
| [`tools/`](tools/) | Generators for the font and the wiring diagram |
| [`docs/plan.md`](docs/plan.md) | Design rationale, throughput budget, milestones, errata list |
| [`docs/wiring.md`](docs/wiring.md) | Pin-by-pin wiring for both nodes, board photos, the switch topology |
| [`docs/wiring-diagram.svg`](docs/wiring-diagram.svg) | The colour-coded jumper diagram, as a standalone SVG |
| [`docs/bringup.md`](docs/bringup.md) | How to read the LEDs, what each failure mode looks like |
| [`build.ps1`](build.ps1) | Simulate, compile, and program (SRAM or non-volatile flash) in one command |

## Building

Needs Quartus Prime Lite 25.1 (Questa FSE ships bundled with it, so there is
no separate simulator to install).

```powershell
.\build.ps1              # simulate, then compile
.\build.ps1 -Sim         # simulate only
.\build.ps1 -Prog        # compile + program SRAM (volatile -- lost on reset/power-cycle)
.\build.ps1 -ProgOnly    # program SRAM from the existing .sof, skip simulate/compile
.\build.ps1 -Flash       # compile + program the config flash (non-volatile -- boots on its own)
.\build.ps1 -FlashOnly   # program the config flash from the existing .sof, skip simulate/compile
.\build.ps1 -HostB       # target Host B (192.168.1.61, MAC ...:02) -- combine with any of the above
```

`-Prog`/`-ProgOnly` write the FPGA's SRAM directly — fast, but the design is
gone on the next power-cycle or reset-button press, exactly like every other
programming step described elsewhere in this README. `-Flash`/`-FlashOnly`
write the board's onboard config flash instead (a Winbond-compatible chip,
confirmed via `openFPGALoader --detect -f`) — the board loads the design from
flash on its own every time it powers up, no USB-Blaster or PC required
afterward. Flashing takes longer (erase + write + verify a whole sector) and
is a real write cycle on physical flash, so `-Prog` remains the right choice
for day-to-day iteration; reach for `-Flash` only once a design is meant to
stick.

`-HostB` builds the *same* source through a second Quartus revision
(`enc28j60_eth_hostb.qsf`, which only overrides `HOST_ID` and the output
directory) rather than a second project, matching "build one source twice"
above. Its own `.sof`/`.rbf` live in `output_files_hostb`, so building one
host never clobbers the other's bitstream — e.g. `.\build.ps1 -HostB -Prog`
compiles and programs Host B while Host A's last build sits untouched.

Tool paths default to a stock `C:\altera_lite\25.1std` install. Override with
`-QuartusBin` / `-QuestaBin` / `-LoaderExe`, or the `QUARTUS_BIN`,
`QUESTA_BIN`, `OFL_EXE` environment variables. `-Flash`/`-FlashOnly` also need
`-SojDir`/`-FpgaPart` (or `OFL_SOJ_DIR`/`OFL_FPGA_PART`) — see the comment
block at the top of [`build.ps1`](build.ps1) for what these are and why.

Programming goes through [openFPGALoader](https://github.com/trabucayre/openFPGALoader)
rather than Quartus's own JTAG server. If your USB-Blaster is a clone — most
bundled ones are — see the
[troubleshooting write-up](https://github.com/bge007/ep4ce6e22-fpga-quickstart/blob/main/docs/usb-blaster-troubleshooting.md)
in the companion repo.

## Wiring

Identical on both boards. Full detail, including why a switch is used instead
of a crossover cable, is in [docs/wiring.md](docs/wiring.md).

![Wiring diagram for both nodes. Each EP4CE6E22 board's right-hand header connects by twelve colour-coded female-to-female DuPont jumpers to an ENC28J60 module's 2x5 header and a 1.3 inch OLED. Both RJ45 jacks connect to a small 10/100 switch with ordinary straight-through patch cables.](docs/wiring-diagram.svg)

Twelve female-to-female 2.54 mm DuPont jumpers per node — eight to the
ENC28J60, four to the OLED. Every header involved presents male pins, so F-F is
the correct cable.

| Wire | FPGA board | Which header | ENC28J60 | IC pin |
|---|---|---|---|---|
| `enc_sck`   | `105`  | right, row 1 left  | `SCK`  | 8  |
| `enc_mosi`  | `106`  | right, row 1 right | `SI`   | 7  |
| `enc_miso`  | `103`  | right, row 2 left  | `SO`   | 6  |
| `enc_cs_n`  | `104`  | right, row 2 right | `CS`   | 9  |
| `enc_rst_n` | `100`  | right, row 3 left  | `RST`  | 10 |
| `enc_int`   | `98`   | right, row 4 left  | ENC `INT`  | 4  |
| `oled_scl`  | `85`   | right, row 5 left  | OLED `SCL` | —  |
| `oled_sda`  | `86`   | right, row 5 right | OLED `SDA` | —  |
| VCC         | `3.3V` | **top**, right end | both `VCC` | 28 |
| GND         | `GND`  | right, bottom      | both `GND` | 2  |

The ENC28J60's 2×5 header reads down as `CLK|INT`, `WOL|SO`, `SI|SCK`,
`CS|RST`, `VCC|GND`. `CLK` and `WOL` stay empty. Both modules share the 3.3 V
and GND rails — see [docs/wiring.md](docs/wiring.md).

### Before you power anything on

1. **Use the right-hand header only.** It is the board's fixed 3.3 V group,
   I/O bank 6. The top (C group) and bottom (B group) headers are bank 7 and
   run at whatever VC/VB is jumpered to — 3.3, 2.5, 1.8 or 1.2 V. The
   ENC28J60 drives `SO` and `INT` at 3.3 V, so an input there with the jumper
   set low is over-driven. Only the `3.3V` *power* pin is taken from the top
   header, and that is a fixed rail.
2. **`PIN_101` is skipped on purpose** — it is `nCEO`, which the FPGA drives
   during configuration while the module drives `INT`. `INT` is on `PIN_98`.
3. **Match the module header by printed label, not position.** ENC28J60
   breakouts ship with several different 2×5 layouts between vendors; the
   order above is from a HanRun HR911105A module.
4. **Power the module from the board's `3.3V` pin,** and feed the board from a
   real USB-C supply rather than a low-current laptop port. If the link drops
   or the FPGA resets *specifically while transmitting*, that is rail sag —
   move VCC to its own 3.3 V supply with grounds tied together.

### Connect the two boards through a switch, not a direct cable

The ENC28J60 has **no Auto-MDIX and no manual MDI/MDI-X swap** — nothing in
its PHY registers can do that crossing, and neither can this project's logic,
since the crossing happens on wires the FPGA never touches. A straight-through
patch cable direct between the two boards wires transmitter to transmitter on
both ends and the link LED never comes on.

This project uses **any cheap 10/100 switch** — including a router's built-in
LAN ports — **with two ordinary straight-through patch cables**; the switch's
ports do the crossing internally. A direct crossover cable (T568A crimped on
one end, T568B on the other, swapping pins 1↔3 and 2↔6) also works if you have
one, but a switch is what this repo is built and documented against, since
crossover cables have become hard to buy.

This runs **half duplex**, which the switch's own auto-negotiated ports also
expect — `MACON3.FULDPX` stays clear on both boards. That is not a loss
against this project's target: the ~9.57 Mbit/s figure and the M5 exit test
are both one-directional, and half duplex delivers that in full since only one
side is transmitting at a time. Full duplex — forcing `PHCON1.PDPXMD` +
`MACON3.FULDPX` on *both* boards for ~9.5 Mbit/s each way at once — is only
available on a direct crossover cable with no switch in the path, and is an
optional upgrade, not something the switch is missing. Setting it on one side
only, or with a switch present, produces a duplex mismatch: late collisions
and throughput that collapses under load.

## Roadmap

| | Milestone | Exit criterion | State |
|---|---|---|---|
| M1 | SPI alive — `spi_master`, EREVID readback | `0x06` on the LEDs | Simulated ✓, hardware ✓ (Host A) |
| M1.5 | OLED — I²C master, SSD1306 driver, status text | Status text on the panel | Simulated ✓, hardware ✓ (Host A — see [docs/oled.md](docs/oled.md#troubleshooting-panel-blank-after-power-up-despite-clean-ic) for the controller-ID and reset-button gotchas) |
| M1.6 | Console — UART, buttons, typed message to OLED | Type in PowerShell, see it on the panel | Simulated ✓, hardware ✓ (Host A, byte-perfect round trip) |
| M2 | Link up — RX/TX buffer, MAC filter, MAC config, MAC address, RXEN | Link LED on both boards | RXEN confirmed on hardware ✓ (Host A), link LED pending |
| M3 | Ping — ARP responder (ICMP echo deferred to M4) | `ping` moves from "unreachable" to "timed out" | Simulated ✓, hardware ✓ (both nodes). Answering, but not yet *sustained* — see [docs/plan.md](docs/plan.md) |
| M4 | UDP echo + **message display** | Host A sends `Hello World`, Host B shows it | Simulated ✓, hardware ✓ (bidirectional, both nodes; needed the CS-hold-time fix above) |
| M5 | Max speed — UDP blaster + measurement | ≥ 9.3 Mbit/s, loss-free | Not started |

The headline demo — **`Hello World` typed on Host A appearing on Host B's
screen** — lands at M4. Both halves it depends on now exist in some form: the
display works, and the message protocol is defined (a UDP datagram to port
1234 whose payload is up to 21 ASCII characters). What is missing between them
is the Ethernet stack itself, M2 and M3.

## Notes for anyone reusing this

A few things that cost time and are not obvious from the datasheet or the
Quartus docs:

- **Quartus 25.1 rejects the device name `EP4CE6E22C8N`.** The legal part name
  is `EP4CE6E22C8`, without the trailing N.
- **`SLEW_RATE` and `CURRENT_STRENGTH` are both rejected** on ordinary user
  I/O on this device — LVCMOS refuses current strength, LVTTL refuses slew
  rate, and LVCMOS refuses slew rate too. Leave the I/O at default drive.
- **An illegal I/O assignment makes the Fitter also report
  `Error (171000): Can't fit design in device`,** which has nothing to do with
  capacity. Fix the I/O error and the phantom fit error disappears.
- **Every project needs an SDC declaring the clock,** or the Timing Analyzer
  reports failure purely for the lack of a clock definition.
- **`ESTAT.CLKRDY` is unreliable after a soft reset** (ENC28J60 errata). Use a
  flat delay instead of polling it.
- **`EREVID` is an Ethernet register, so its read needs no dummy byte** —
  the data arrives in the second SPI byte. MAC and MII registers *do* need
  one. Getting this backwards is the classic first-read bug.

## Related

- [ep4ce6e22-fpga-quickstart](https://github.com/bge007/ep4ce6e22-fpga-quickstart)
  — getting this board programmed from Windows, including the clone
  USB-Blaster workaround.

## License

MIT — see [LICENSE](LICENSE). This covers the source code and the written
documentation.

The board photographs and the panel datasheet in [`docs/`](docs/) are
vendor product, manual and datasheet material, included for reference and
identification. They are not original work of this project and are not covered
by the MIT licence — see [Image credits](docs/wiring.md#image-credits).
