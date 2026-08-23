# Project plan: hardware Ethernet stack on the EP4CE6E22

## Goal

Demonstrate real network communication between two EP4CE6E22 boards, each
driving a Microchip ENC28J60 10 Mbps Ethernet controller over SPI, joined
through a 10/100 switch — and push it to the practical limit of 10Base-T.

The ENC28J60 integrates the 10Base-T MAC and PHY. The FPGA supplies everything
above it: the SPI master, the controller driver, and the protocol stack.

## Why a hardware stack and not a soft CPU

| Option | What it is | Verdict |
|---|---|---|
| **Hardware stack (chosen)** | Pure-HDL FSMs for ARP + ICMP + UDP | ~2,500 LE of 6,272, deterministic, easily saturates 10 Mbit/s. No TCP, which is fine for a demo. |
| Soft CPU + firmware | PicoRV32 + a uIP/lwIP-class stack in M9K RAM | Fits, barely — 30 KB on-chip RAM total. Slower, more moving parts. Worth revisiting only if TCP is ever needed. |

## Throughput budget

10Base-T moves 10 Mbit/s on the wire. Per maximum-length frame the overhead is
fixed: 8 B preamble + 14 B Ethernet header + 20 B IP + 8 B UDP + 4 B FCS +
12 B inter-frame gap = 66 B around a 1,472 B UDP payload, so 1,538 B of wire
time carries 1,472 B of payload.

```
1472 / 1538 x 10 Mbit/s  =  ~9.57 Mbit/s usable UDP payload  =  ~813 packets/s
```

The SPI side must sustain that. At 20 MHz the raw SPI rate is 20 Mbit/s, and
the ENC28J60's buffer read/write opcodes auto-increment the address pointer, so
a whole frame moves in one burst behind a single opcode byte. Effective SPI
throughput is therefore ~19.9 Mbit/s — roughly double the wire rate, so SPI is
never the bottleneck and the FPGA can service receive and transmit
back-to-back.

## Duplex

The ENC28J60 has neither Auto-MDIX nor duplex auto-negotiation — it is a fixed
10 Mbit/s half-duplex PHY however it is cabled. **This project runs the two
boards through a 10/100 switch on ordinary patch cables**, which the switch's
own auto-negotiated ports see as half duplex, so `MACON3.FULDPX` stays clear
on both boards to match.

This is not a compromise against the stated target. The throughput budget
above and the M5 exit test are both **one-directional** — Host A streaming to
Host B — and half duplex delivers the full ~9.57 Mbit/s there, since with only
one side transmitting there are no collisions to lose time to.

If a direct crossover cable is available instead of a switch, full duplex can
be forced — `PHCON1.PDPXMD` + `MACON3.FULDPX` on **both** boards, giving
~9.5 Mbit/s each way at once — but this is an optional upgrade over the
switch-based setup, not something the switch is missing. Setting it on one
side only, or with a switch in the path, produces a duplex mismatch: late
collisions and throughput that collapses under load.

See [wiring.md](wiring.md) for the cabling and why a straight-through cable
with no switch does not link up at all — the ENC28J60's missing Auto-MDIX
means that combination wires transmitter to transmitter on both ends.

## Architecture

```
EP4CE6E22
  pll            50 MHz osc -> 40 MHz system clock
  spi_master     byte-streaming SPI mode 0, burst-capable
  enc28j60_ctrl  opcode layer, bank switching, MII-indirect PHY, init FSM
  rx_engine      EPKTCNT poll / INT, burst frame into RX FIFO, free buffer
  tx_engine      control byte + frame into TX area, fire ECON1.TXRTS
  net_stack      MAC/IP filter, ARP responder, ICMP echo, UDP echo + blaster
  FIFOs          2 KB RX + 2 KB TX in M9K
        |
     SPI (SCK MOSI MISO CS INT RST)
        |
ENC28J60  MAC + PHY + 8 KB buffer
        |
     10Base-T, RJ45 + magnetics
        |
   patch cable -> 10/100 switch -> patch cable -> second identical node
```

### Module budget

| Module | Function | Est. LE |
|---|---|---|
| `pll` | 50 MHz -> 40 MHz; SPI FSM toggles SCK at 20 MHz | — |
| `spi_master` | SPI mode 0, burst-capable (CS held across a frame) | ~150 |
| `enc28j60_ctrl` | RCR/WCR/BFS/BFC/RBM/WBM/SRC, bank switching, PHY access, init | ~600 |
| `rx_engine` | Frame receive, buffer management, ERXRDPT errata | ~350 |
| `tx_engine` | Frame transmit, TXRST errata workaround | ~300 |
| `net_stack` | ARP, ICMP echo, UDP echo, UDP blaster | ~1,100 |
| FIFOs | 2 KB RX + 2 KB TX | 4 M9K |

Total ~2,500 LE of 6,272 — comfortable margin, no external RAM.

## ENC28J60 bring-up sequence

1. Hard reset via the RESET pin, then the soft reset opcode `0xFF`; wait
   >= 1 ms. The `ESTAT.CLKRDY` polling shortcut is unreliable per the errata —
   use a flat delay.
2. Read `EREVID`, expect `0x06` (rev B7). This is the smoke test for the whole
   SPI path.
3. RX buffer `0x0000`–`0x19FF` (6.5 KB), TX from `0x1A00`. **Errata:**
   `ERXRDPT` must always be programmed to an *odd* address.
4. MAC: `MACON1` receive enable, `MACON3` pad + CRC append, `MAMXFL` = 1518,
   back-to-back and inter-packet gaps per datasheet, then the MAC address —
   note the byte order is reversed in the registers.
5. PHY via MII-indirect: `PHCON1` duplex, `PHLCON` LED config (LEDA = link,
   LEDB = TX/RX activity). Wait 10.24 us after each PHY write.
6. Enable reception (`ECON1.RXEN`).

### Errata workarounds (silicon rev B7)

- **Transmit hang:** the transmit logic can lock up after a collision. Pulse
  `ECON1.TXRST` before every transmission — cheap, and standard practice.
- **Receive hang:** avoid the pattern-match filter entirely; use
  unicast + broadcast + CRC filters only.
- **LEDs:** `PHLCON` stretching interacts with duplex mode, so set it after
  duplex is final.

## Milestones

| | Milestone | Exit criterion | State |
|---|---|---|---|
| M1 | SPI alive — project, pinout, `spi_master`, EREVID readback | `0x06` on the LEDs | **Confirmed on Host A hardware** |
| M2 | Link up — full init FSM, MAC config, RXEN | Link established | RXEN confirmed on Host A hardware; link LED not yet visually checked |
| M3 | Ping — RX/TX engines, ARP responder (ICMP echo deferred to M4) | Sustained ping, 0% loss | Implemented, simulation-verified, flashed to Host A; hardware `ping` retest pending |
| M4 | UDP echo — parsing, checksums, echo path | 10k datagrams echoed correctly | Not started |
| M5 | Max speed — UDP blaster, measurement scripts, full duplex | >= 9.3 Mbit/s, loss-free | Not started |

Each milestone is a self-contained chunk; M3 is the largest.

## Verification approach

**Simulation.** A behavioral ENC28J60 SPI-slave model in the testbench
implements the opcode set, register banks, and buffer memory. The testbench
drives init -> ARP -> ICMP -> UDP and self-checks the frames the design emits.
This is where most stack bugs should die, before hardware is involved.

**Hardware,** in order: EREVID readback, then link LED, then ping from a PC
with Wireshark watching, then UDP echo, then throughput measurement.
