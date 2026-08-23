# Two-node wiring: Host A ⇄ Host B

Two identical nodes — each an EP4CE6E22 board, an ENC28J60 Ethernet module and
a 1.3" OLED — joined through a **10/100 switch** with two ordinary patch
cables.

![Wiring diagram for both nodes. Each EP4CE6E22 board's right-hand header connects by twelve colour-coded female-to-female DuPont jumpers to an ENC28J60 module's 2x5 header and a 1.3 inch OLED. Both RJ45 jacks connect to a small 10/100 switch with ordinary straight-through patch cables.](wiring-diagram.svg)

Twelve jumpers per node, twenty-four in total. Wires cross in the drawing —
follow the colour, not the path. The dashed purple `INT` line is optional;
milestone 1 polls `EPKTCNT` over SPI instead. The dashed red and grey lines are
the 3.3 V and GND rails, shared between the two modules. `PIN_101` is marked ✗
because it is the `nCEO` configuration pin; see below.

## Why a switch, not a direct cable

The ENC28J60 has **no Auto-MDIX and no manual MDI/MDI-X swap**. Its PHY
register set (`PHCON1`, `PHCON2`, `PHSTAT1/2`, `PHLCON`, ...) covers duplex,
loopback, power-save and LED configuration — nothing touches which pair is
transmit and which is receive. That crossing has to happen somewhere between
the two RJ45 jacks, and there is nothing in this design's logic, nor in the
chip's, that can do it. It is fixed by the cabling.

Two ways to get the crossing done:

- **A crossover cable** direct between the two boards (T568A on one end,
  T568B on the other) — no switch needed, and it also unlocks forced full
  duplex (see below). Fine if you have one, or a crimp tool to make one.
- **A 10/100 switch** with two ordinary straight-through patch cables — the
  switch's own ports do the crossing internally. **This is the path this
  project actually uses**, because crossover cables have become hard to buy
  and any switch, or a router's built-in LAN ports, does the job. This
  includes plain unmanaged 5-port switches, not just "smart" ones.

A straight-through cable with **no** switch in between wires transmitter to
transmitter on both ends, and the link LED never comes on. That is the one
combination that does not work.

| Host A RJ45 | → switch → | Host B RJ45 |
|---|---|---|
| 1,2 (TX) | patch cable, port 1 | switch crosses internally |
| 3,6 (RX) | patch cable, port 1 | switch crosses internally |
| — | patch cable, port 2 | 1,2 (TX) |
| — | patch cable, port 2 | 3,6 (RX) |
| 4, 5, 7, 8 | — | unused at 10Base-T |

Both patch cables are ordinary straight-through — nothing to crimp, nothing to
verify pin-by-pin.

## Per-board connections (identical on both hosts)

Twelve female-to-female 2.54 mm DuPont jumpers per node, twenty-four in total.
Every header involved presents male pins, so F-F is the correct cable and no
breadboard is needed.

### To the ENC28J60

| Wire | FPGA board | Which header | ENC28J60 | Module row | IC pin |
|---|---|---|---|---|---|
| `enc_sck`   | `105`  | right, row 1 left  | `SCK`  | 3 right | 8  |
| `enc_mosi`  | `106`  | right, row 1 right | `SI`   | 3 left  | 7  |
| `enc_miso`  | `103`  | right, row 2 left  | `SO`   | 2 right | 6  |
| `enc_cs_n`  | `104`  | right, row 2 right | `CS`   | 4 left  | 9  |
| `enc_rst_n` | `100`  | right, row 3 left  | `RST`  | 4 right | 10 |
| `enc_int`   | `98`   | right, row 4 left  | `INT`  | 1 right | 4  |
| VCC         | `3.3V` | **top**, right end | `VCC`  | 5 left  | 28 |
| GND         | `GND`  | right, bottom      | `GND`  | 5 right | 2  |

Left empty on the module: `CLK` (programmable clock output — the FPGA has its
own 50 MHz oscillator) and `WOL` (wake-on-LAN — nothing here sleeps).

### To the 1.3" OLED

| Wire | FPGA board | Which header | OLED |
|---|---|---|---|
| `oled_scl` | `85`   | right, row 5 left  | `SCL` |
| `oled_sda` | `86`   | right, row 5 right | `SDA` |
| VCC        | `3.3V` | **top**, right end | `VCC` — **3.3 V, not the 5 V on the silkscreen** |
| GND        | `GND`  | right, bottom      | `GND` |

> **Run the OLED at 3.3 V.** Its SDA and SCL pull-ups go to the module's own
> VCC, so powering it at 5 V puts 5 V onto the I²C lines and into a 3.3 V
> Cyclone IV bank. Measure both lines against ground before connecting them —
> they idle high and should read ~3.3 V. Full reasoning in [oled.md](oled.md).

Pins 85/86 are I/O **bank 5** while the ENC28J60 signals are bank 6. Both sit
on the same fixed-3.3 V right header, so it makes no practical difference.

**Both modules share the 3.3 V and GND rails.** These headers are two-row, so
most positions offer a second pin to branch from. If yours does not,
daisy-chain the second module off the first rather than forcing two DuPont
sockets onto one pin.

### The ENC28J60 2×5 header

Silkscreen order on the HanRun/HR911105A module, reading down with the RJ45 to
the right:

```
CLK | INT
WOL | SO
SI  | SCK
CS  | RST
VCC | GND
```

![ENC28J60 module pinout, showing the 2x5 header labelled CLK/INT, WOL/SO, SI/SCK, CS/RST, VCC/GND alongside the HR911105A RJ45 jack](pinout-ENC28J60.png)

All ten pins are present on every module, but **the physical order differs
between vendors** — match by printed label, not by position in this photo.

`TPOUT±` → RJ45 pins 1,2 and `TPIN±` ← RJ45 pins 3,6 are wired inside the
breakout through the magnetics, along with the RBIAS resistor and
termination. You never touch them.

### Use the right-hand FPGA header, not the top or bottom

![EP4CE6E22 core board, showing the top header numbered 144 down to 110 with VC voltage-select pins, the right-hand header in pairs from 105/106 down to 34/NC with GND at the bottom, and the bottom header with VB voltage-select pins](pinlayout-EP4CE6E22-fpga_board.jpg)

The EP4CE6E22 board has three I/O headers and they are not equivalent:

- **Right-hand header — fixed 3.3 V.** All eight signals go here: six SPI to
  the ENC28J60 and two I²C to the OLED. Two columns, reading down: `105|106`,
  `103|104`, `100|101`, `98|99`, `85|86`, `77|83`, `76|78`, `30|31`, `32|33`,
  `34|NC`, then `GND` at the bottom. Using the top rows keeps both buses on one
  connector with ground on the same strip. (Rows 1–4 are I/O bank 6 and row 5
  is bank 5; the board ties both to the same 3.3 V rail.)
- **Top header (C group) and bottom header (B group) — bank 7, voltage set by
  a jumper cap** to 3.3, 2.5, 1.8 or 1.2 V. The ENC28J60 drives `SO` and `INT`
  at 3.3 V, so an FPGA input there with VC/VB jumpered low is over-driven.
  An earlier revision of this project used `PIN_110`/`PIN_111` from the C
  group for exactly that reason — don't go back to it. The only thing taken
  from the top header now is the `3.3V` *power* pin, which is a fixed rail and
  not bank-dependent.

> **`PIN_101` is deliberately skipped.** It is the `nCEO` configuration pin.
> Quartus will release it as regular I/O with
> `CYCLONEII_RESERVE_NCEO_AFTER_CONFIGURATION`, but the FPGA *drives* nCEO
> during configuration while the ENC28J60 drives `INT` — output against
> output, every time the board configures. `INT` lives on `PIN_98` instead.

> **Match the module header by printed label, not by position.** ENC28J60
> breakouts ship with several different 2×5 layouts between vendors. The order
> above is from the HanRun module shown in the photo.

The board vendor's own annotated diagram states the rule directly — "the right
pin is a fixed 3.3V voltage pin", while both the C and B groups need a jumper
cap to select VC/VB:

![Annotated EP4CE6E22 board diagram, labelling the upper C group and lower B group as jumper-selectable voltage pins, the right-hand pins as fixed 3.3V, plus the JTAG header pinout and the USB-C power input](pinout-EP4CE6E22-fpga_board_info.jpg)

That same diagram gives the JTAG header pinout, which is worth having when
wiring a USB-Blaster: `GND / NC / NC / 2.5V / GND` down one side and
`TDI / NC / TMS / TDO / TCK` down the other.

### Power

The board carries an AMS1117-3.3 and brings a `3.3V` pin out at the right end
of the top header, so **take VCC from that pin**. It is one jumper instead of
a separate supply, and the regulator has headroom on paper: the module's
~180 mA transmit peak against a part rated 1 A, dissipating roughly 0.3 W
extra in a SOT-223 package.

Two conditions. Feed the board from a real USB-C supply or a powered hub
rather than a low-current laptop port, and keep 100 nF + 10 µF decoupling at
the module — the current spikes when the transmitter fires are what upset a
shared rail, not the average draw.

**The symptom that means you need a separate supply:** the link works at idle
but drops, resets, or corrupts frames specifically while transmitting, or the
FPGA re-configures under load. That is rail sag, not a logic bug. Move VCC to
its own 3.3 V supply with grounds tied together rather than debugging the RTL.

## What differs between the hosts

Nothing in the wiring — two constants in the bitstream.

| | Host A | Host B |
|---|---|---|
| IP | `192.168.1.60` | `192.168.1.61` |
| MAC | `02:42:CE:60:00:01` | `02:42:CE:60:00:02` |
| Bitstream | `eth_A.sof` | `eth_B.sof` |

Both MACs are locally administered (bit 1 of the first octet set) so they
cannot collide with a real vendor address. Build both images from one source:

```verilog
module eth_top #(
    parameter [7:0]  HOST_ID  = 8'd1,          // 1 = Host A, 2 = Host B
    parameter [47:0] MAC_ADDR = {40'h0242CE6000, HOST_ID},
    parameter [31:0] IP_ADDR  = {24'hC0A801, 8'd59 + HOST_ID}
) ( ... );
```

## Duplex: this topology runs half duplex, and that is fine

The ENC28J60 cannot auto-negotiate at all — no Auto-MDIX, and no duplex
negotiation either. Through a switch it is always seen as **10 Mbit/s half
duplex**, and `MACON3.FULDPX` must stay clear on both boards to match. Setting
it on one or both sides while a switch is in the path creates a duplex
mismatch with the switch's own auto-negotiated half-duplex port — late
collisions, and throughput that collapses under load rather than failing
cleanly.

This costs nothing against the project's actual target. The ~9.57 Mbit/s
figure in [plan.md](plan.md) and the M5 exit test are both **one-directional**
— Host A streaming to Host B, nothing coming back except ACKs at the
application layer. Half duplex delivers that in full: with only one side
transmitting at a time, there are no collisions to lose time to. What half
duplex gives up is the *bonus* of ~9.5 Mbit/s simultaneously in both
directions, which was never the milestone target.

If you later swap the switch for a direct crossover cable between the two
boards, full duplex becomes available — see the note in
[plan.md](plan.md#duplex) — but it is an optional upgrade, not something this
topology is missing.

## Bring-up order

1. **Ground first**, to both modules, before any other wire.
2. **Then VCC** from the top header's `3.3V` pin. Power the board and confirm
   3.3 V at each module before adding signals. On the OLED, also measure SDA
   and SCL against ground — if either reads ~5 V, stop and fix the supply
   before connecting them to the FPGA.
3. **Then the five required ENC28J60 signals** — SCK, SI, SO, CS, RST. Leave
   INT for later; milestone 1 does not use it.
4. **Then the OLED's SCL and SDA.** The panel should light and show the status
   text within a second of configuration.
5. **Test each board alone.** Confirm `EREVID` = `0x06` with no cable
   attached. A board that cannot reach its own controller over SPI will not be
   fixed by plugging in Ethernet.
6. **Then the switch.** Plug both boards into the switch with ordinary patch
   cables. Link LEDs on both modules, and on the corresponding switch ports,
   should light within a second. Exactly one lit → suspect that cable or
   port. Neither lit → suspect PHY init.
7. **Then ARP.** Host A ARPs for Host B's IP. A reply proves the whole path in
   both directions: SPI out, transmit, switch, receive, SPI in.
8. **Then throughput.** Host A streams 1,472-byte sequence-numbered UDP
   datagrams; Host B counts bytes and gaps.

## Image credits

`wiring-diagram.svg` is original work of this project and is covered by the
repository's MIT licence like the rest of the source.

The board photographs and the panel datasheet in this directory —
`pinout-ENC28J60.png`, `pinlayout-EP4CE6E22-fpga_board.jpg`,
`pinout-EP4CE6E22-fpga_board_info.jpg`, `1.3inch-oled-pin.jpg` and
`3nfR8M2Am86tmUNdMO8j8wvWXkTdW8tsHJ4XG1fn.pdf` (the QG-2864KSWLG01 / SH1106
datasheet) — are **vendor product, manual and datasheet material**, reproduced
here for identification and reference. They are not original work of this
project and are **not covered by the repository's MIT licence**, which applies
to the source code and written documentation only.

If you are the rights holder and would prefer they were removed, please open
an issue and they will be taken down.
