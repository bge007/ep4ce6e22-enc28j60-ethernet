# EP4CE6E22 + ENC28J60 — a hardware Ethernet stack in Verilog

Two **EP4CE6E22C8** Cyclone IV E boards, each driving a Microchip **ENC28J60**
10 Mbps Ethernet controller over SPI, joined by a single LAN cable — with the
ARP / ICMP / UDP stack built as pure HDL rather than firmware on a soft CPU.

The target is the practical ceiling of 10Base-T: **~9.57 Mbit/s** of UDP
payload, which is what 1,472-byte datagrams work out to once framing overhead
is accounted for. See [docs/plan.md](docs/plan.md) for that arithmetic and the
design rationale.

> ### Status: milestone 1 of 5, simulated and synthesised, **not yet run on hardware**
>
> Unlike [ep4ce6e22-fpga-quickstart](https://github.com/bge007/ep4ce6e22-fpga-quickstart),
> where everything was verified on a real board before publishing, this repo is
> work in progress. What exists is checked by simulation and compiles cleanly
> with timing met — but no part of it has driven a physical ENC28J60 yet.
>
> Pin assignments *are* now taken from the actual board layout rather than
> guessed, and all six signals sit in the fixed-3.3 V bank 6; see
> [Before you power anything on](#before-you-power-anything-on) for the
> reasoning and the two pins to avoid.

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
| Simulation | Passes — two self-checking testbenches, against behavioral ENC28J60 (SPI) and SH1106 (I²C) models |
| Quartus compile | 0 errors |
| Logic elements | 602 / 6,272 (10%) |
| Registers | 221 |
| Memory bits | 4,472 / 276,480 (2%) |
| Worst-case setup slack | +4.53 ns |
| Worst-case hold slack | +0.43 ns |
| Hardware | **Not yet tested** |

**The OLED display also works.** Each node drives a 1.3" 128×64 SH1106 panel
over I²C showing the board identity, the live EREVID readback, the host's IP,
and a message line. Line 3 is the hook for milestone 4: Host A will write what
it transmits, Host B what it receives. See [docs/oled.md](docs/oled.md) —
including the two traps, powering it at 3.3 V rather than the 5 V on the
silkscreen, and the SH1106's two-column RAM offset.

```
EP4CE6E22 ENC28J60
EREVID 0x06 OK
HOST A 192.168.1.60
MSG --
```

The full stack is budgeted at ~2,500 LE on top of this, which still fits.

## Bill of materials

A two-node link means two of nearly everything. Prices are rough marketplace
figures in USD to give a sense of scale — they are not quotes and they drift.

### Per node — buy two of each

| # | Item | Qty | Spec that matters | ~$ |
|---|---|---|---|---|
| 1 | EP4CE6E22 Cyclone IV E core board | 1 | `EP4CE6E22C8N`, 144-LQFP, onboard CH340 + USB-C, 5 LEDs, 4 keys, 50 MHz osc | 12–20 |
| 2 | ENC28J60 Ethernet module | 1 | **must** carry the RJ45 jack with integrated magnetics (HanRun `HR911105A` or equivalent) and a 25 MHz crystal; **3.3 V logic** | 3–6 |
| 3 | 1.3" I²C OLED, 128×64 | 1 | 4-pin (VCC/GND/SCL/SDA). Controller is **SH1106**, panel QG-2864KSWLG01. **Run it at 3.3 V — see the warning below** | 4–8 |
| 4 | USB-C cable | 1 | data-capable, not charge-only — it carries power *and* the CH340 serial port | 2–4 |
| 5 | 100 nF ceramic capacitor | 1 | decoupling across the ENC28J60's VCC/GND, as close to the header as you can get | <1 |
| 6 | 10 µF capacitor | 1 | same place; ceramic or electrolytic both fine | <1 |

### Shared across both nodes — buy one

| # | Item | Qty | Spec that matters | ~$ |
|---|---|---|---|---|
| 7 | **Crossover** Cat5e patch cable | 1 | see the warning below — this is the item people get wrong | 3–6 |
| 8 | Female-to-female DuPont jumpers, 2.54 mm | 24 used | buy a 40-way ribbon. **10 cm if you can find it**, 20 cm at the outside — see harness length below | 2–4 |
| 9 | USB-Blaster JTAG programmer | 1 | 10-pin ribbon included; one programmer flashes both boards in turn | 5–10 |
| 10 | USB power source | 1 | a powered hub or mains adapter, ≥1 A per board. A low-current laptop port is the usual cause of flaky behaviour | 5–12 |

Rough total for a complete two-node build: **$60–110**.

### Only if you hit rail sag

| # | Item | Qty | When you need it | ~$ |
|---|---|---|---|---|
| 11 | AMS1117-3.3 regulator module, or a bench supply | 2 | Only if the link drops or the FPGA resets *specifically while transmitting*. See [Before you power anything on](#before-you-power-anything-on) | 1–3 |
| 12 | Multimeter | 1 | **Not really optional.** Confirming 3.3 V at both modules — and that the OLED's I²C lines idle at 3.3 V, not 5 V — before connecting signal wires | — |

### Software — all free

| Item | Notes |
|---|---|
| Quartus Prime Lite 25.1 | Questa FSE simulator ships bundled; no separate install |
| [openFPGALoader](https://github.com/trabucayre/openFPGALoader) | Programming path that works with clone blasters |
| [Zadig](https://zadig.akeo.ie/) | Only if your USB-Blaster is a clone and needs the WinUSB driver |
| Wireshark | Optional, for watching frames when testing a node against a PC |

### Five purchasing traps

1. **The Ethernet cable must be a crossover.** The ENC28J60 has no Auto-MDIX
   and there is no switch in this topology, so a straight-through patch cable
   wires transmitter to transmitter and the link LED never lights. Crossover
   cables are increasingly hard to buy — the easy substitute is **any cheap
   10/100 switch plus two ordinary patch cables**, which costs about the same
   and does the crossing internally. You lose the ability to force full
   duplex, dropping the link to ~9.5 Mbit/s one-way instead of each-way.
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
   and everything is safe, which is also what the SH1106 wants — the datasheet
   gives VDD as 1.65–3.3 V. Measure SDA and SCL against ground before
   connecting them. Details in [docs/oled.md](docs/oled.md).

### Building with only one FPGA board

If you have one board rather than two, most of the project still works: point
the node at a PC instead of a second board. Milestones 1 through 4 — SPI
readback, link up, ping, and UDP echo — all run fine against a PC's NIC, and
you get Wireshark on the other end, which is a genuinely better debugging
position than two silent FPGAs. You need a second board only for the two-node
demo itself, and note that a PC link still needs the crossover cable (or a
switch), because the ENC28J60's lack of Auto-MDIX is unchanged.

## Repository layout

| Path | Contents |
|---|---|
| [`rtl/spi_master.v`](rtl/spi_master.v) | Byte-streaming SPI master, mode 0, burst-capable |
| [`rtl/i2c_master.v`](rtl/i2c_master.v) | Write-only open-drain I²C master, 400 kHz |
| [`rtl/oled_sh1106.v`](rtl/oled_sh1106.v) | SH1106 OLED driver: init, page addressing, 4×21 text |
| [`rtl/font5x8.mem`](rtl/font5x8.mem) | ASCII 32–126 font, generated — don't hand-edit |
| [`rtl/eth_top.v`](rtl/eth_top.v) | Top level: reset sequencing, EREVID read, LEDs, OLED status |
| [`tb/tb_m1.v`](tb/tb_m1.v) | Self-checking testbench + behavioral ENC28J60 SPI-slave model |
| [`tb/tb_oled.v`](tb/tb_oled.v) | Self-checking testbench + behavioral SH1106 I²C slave model |
| [`docs/oled.md`](docs/oled.md) | SH1106 column offset, the 3.3 V warning, driver internals |
| [`tools/`](tools/) | Generators for the font and the wiring diagram |
| [`docs/plan.md`](docs/plan.md) | Design rationale, throughput budget, milestones, errata list |
| [`docs/wiring.md`](docs/wiring.md) | Pin-by-pin wiring for both nodes, board photos, the crossover cable |
| [`docs/wiring-diagram.svg`](docs/wiring-diagram.svg) | The colour-coded jumper diagram, as a standalone SVG |
| [`docs/bringup.md`](docs/bringup.md) | How to read the LEDs, what each failure mode looks like |
| [`build.ps1`](build.ps1) | Simulate, compile, and program in one command |

## Building

Needs Quartus Prime Lite 25.1 (Questa FSE ships bundled with it, so there is
no separate simulator to install).

```powershell
.\build.ps1          # simulate, then compile
.\build.ps1 -Sim     # simulate only
.\build.ps1 -Prog    # compile and program the board
```

Tool paths default to a stock `C:\altera_lite\25.1std` install. Override with
`-QuartusBin` / `-QuestaBin` / `-LoaderExe`, or the `QUARTUS_BIN`,
`QUESTA_BIN`, `OFL_EXE` environment variables.

Programming goes through [openFPGALoader](https://github.com/trabucayre/openFPGALoader)
rather than Quartus's own JTAG server. If your USB-Blaster is a clone — most
bundled ones are — see the
[troubleshooting write-up](https://github.com/bge007/ep4ce6e22-fpga-quickstart/blob/main/docs/usb-blaster-troubleshooting.md)
in the companion repo.

## Wiring

Identical on both boards. Full detail, including the RJ45 crossover pinout, is
in [docs/wiring.md](docs/wiring.md).

![Wiring diagram for both nodes. Each EP4CE6E22 board's right-hand header connects by twelve colour-coded female-to-female DuPont jumpers to an ENC28J60 module's 2x5 header and a 1.3 inch OLED, and the two RJ45 jacks are joined by one crossover cable.](docs/wiring-diagram.svg)

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

### The cable must be a crossover

The ENC28J60 has **no Auto-MDIX**, and in a two-board topology there is no
switch to do the crossing for you. A straight-through patch cable wires
transmitter to transmitter and the link LED never comes on.

Use a crossover cable — T568A crimped on one end, T568B on the other, which
swaps pins 1↔3 and 2↔6 — or put any 10/100 switch between the boards and use
two ordinary patch cables.

The upside of the direct connection: with no switch there is no
auto-negotiation partner to disagree with, so **full duplex can be forced**.
Set `PHCON1.PDPXMD` and `MACON3.FULDPX` on *both* boards for ~9.5 Mbit/s in
each direction at once. Set it on one side only and you get a duplex mismatch:
late collisions and throughput that collapses under load. Both or neither.

## Roadmap

| | Milestone | Exit criterion | State |
|---|---|---|---|
| M1 | SPI alive — `spi_master`, EREVID readback | `0x06` on the LEDs | Simulated ✓, hardware ✗ |
| M1.5 | OLED — I²C master, SH1106 driver, status text | Status text on the panel | Simulated ✓, hardware ✗ |
| M2 | Link up — full init FSM, PHY config | Link LED on both boards | Not started |
| M3 | Ping — RX/TX engines, ARP, ICMP echo | Sustained ping, 0% loss | Not started |
| M4 | UDP echo + **message display** | Host A sends `Hello World`, Host B shows it | Not started |
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

The board photographs and the SH1106 panel datasheet in [`docs/`](docs/) are
vendor product, manual and datasheet material, included for reference and
identification. They are not original work of this project and are not covered
by the MIT licence — see [Image credits](docs/wiring.md#image-credits).
