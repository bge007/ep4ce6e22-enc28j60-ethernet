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
| M1 | SPI alive — project, pinout, `spi_master`, EREVID readback | `0x06` on the LEDs | **Confirmed on both nodes** |
| M2 | Link up — full init FSM, MAC config, RXEN | Link established | RXEN confirmed on hardware (`ECON1` readback); link LED not yet visually checked |
| M3 | Ping — RX/TX engines, ARP responder (ICMP echo deferred to M4) | Sustained ping, 0% loss | **ARP answering on hardware**; not yet *sustained* — see the stability section below |
| M4 | UDP echo — parsing, checksums, echo path | 10k datagrams echoed correctly | Simulated; receive half confirmed on hardware (PC broadcast → OLED). Board-to-board blocked on M3 stability |
| M5 | Max speed — UDP blaster, measurement scripts, full duplex | >= 9.3 Mbit/s, loss-free | Not started |

Each milestone is a self-contained chunk; M3 is the largest.


## Stability: where M3 actually stands

M3's *functional* exit criterion is met — the ARP responder answers, `ping`
moves from "Destination host unreachable" to "Request timed out", the switch
learns both MACs, and the port's `InUcastPkts` climbs. The *sustained* half is
not met: a node runs correctly for a few minutes and then stops receiving.

Four separate hardware-only faults have been found and fixed, none of which
simulation would have surfaced on its own. They are written up in full in
[enc28j60.md](enc28j60.md); in brief:

| # | Fault | Signature | Status |
|---|---|---|---|
| 1 | Every TX frame had a bad CRC | TSV `s2=0x90`; switch `InOctets` up, `InUcastPkts` 0 | Fixed — per-packet control byte `0x07` |
| 2 | Bank selects cleared `ECON1.RXEN` | Ran a while, then received nothing | Fixed — all `ECON1` access via `BFS`/`BFC` |
| 3 | Two-byte SPI helpers hung when data equalled the opcode | FSM frozen, `P=` static, `K=01` | Fixed — explicit phase bit |
| 4 | Reflashing the FPGA does not reset the ENC28J60 | `A=0000`, `T=0000` from frame 1 | Fixed — errata-19 reset sequence |

Fault 3 is worth singling out: `WCR(ERDPTL)` is `0x40` and `WCR(ERXRDPTL)` is
`0x4C`, and both are written with the low byte of an RX ring pointer that walks
all 256 values. Two chances in 256 per frame predicts a mean of 128 frames to
failure; the observed wedges were at **122, 156 and 134 frames**.

Each fix carries a regression test that was verified to *fail* against the
pre-fix RTL rather than pass vacuously.

### Measured results after the fixes

| Run | Frames | Resyncs (`X`) | Outcome |
|---|---|---|---|
| Host A, 25 ping rounds | — | — | 0/25 degraded (was 25/25) |
| Host B, 15 min | 365 | 0 → 21 late | Ran ~11 min, then chain corruption |
| Host A, 15 min | 275 → 904 | 0 → 414 | Clean ~8.5 min, then resync storm |
| Host A, current | 602 | **0** | Healthy, counters advancing |

### The one remaining fault

After a period of correct operation the RX packet-chain pointer goes out of
range. The driver detects this (`next_ptr_ok`) and pulses `ECON1.RXRST` to
resync — but **the resync does not restore reception**. `X` climbs into the
hundreds, the part stops delivering packets (`EPKTCNT` reads 0 forever) and the
node never recovers, while the FSM itself stays alive and polling.

Two facts constrain the cause:

- It is not the FSM. The poll counter keeps advancing throughout, so the driver
  is healthy and the *part* has stopped handing over frames.
- It is not purely the module. A faulty ENC28J60 was found and replaced early
  on, which removed one source of chain corruption but not this failure.

**Planned fix.** Stop trying to patch the pointers. `RXRST` resets the receive
logic but leaves the driver guessing where the part's write pointer ended up,
and that guess is what fails. Now that a *verified* full reset exists — the
errata-19 sequence, which demonstrably brings a part back from an unknown
state — the recovery path should re-run that entire sequence plus the M2
configuration, rather than the partial `RXRST` patch-up.

This needs `net_stack` to hand the SPI bus back to the M1/M2 FSM on demand and
take it again when configuration completes, which is a real change to how the
two share the bus rather than a local edit.

### Operational notes learned the hard way

- **A JTAG reflash is not a power cycle.** The FPGA restarts; the ENC28J60 does
  not. Fix 4 makes the driver recover from this, but a genuinely wedged module
  has still needed a power cycle. Measurements taken right after a reflash
  misled this project more than once.
- **Check the build identifier.** The OLED shows `BLD xxxx` (line 2) precisely
  because there is one USB-Blaster between two boards, and they routinely sit
  one flash apart. Several wrong conclusions came from testing a node quietly
  running an older bitstream.
- **The console only speaks when a counter changes** — so a wedged node and an
  idle one look identical. Hence the heartbeat and the `P=`/`K=` fields; that
  instrumentation is what made fault 3 findable at all.

## Next steps, in order

1. Re-run the full ENC28J60 init (errata-19 reset + M2 config) as the recovery
   path for a corrupt packet chain, replacing the `RXRST` resync.
2. Re-soak both nodes; the target is a clean run well past 1000 frames with
   `X` staying at 0.
3. Only then, board-to-board M4: type on Host A's console, see it on Host B's
   OLED. Both nodes must be on the same build first.
4. Merge `m4-udp-messaging` into `main`.
5. Optional once stable: ICMP echo, so `ping` succeeds outright rather than
   resolving ARP and timing out.


## Verification approach

**Simulation.** A behavioral ENC28J60 SPI-slave model in the testbench
implements the opcode set, register banks, and buffer memory. The testbench
drives init -> ARP -> ICMP -> UDP and self-checks the frames the design emits.
This is where most stack bugs should die, before hardware is involved.

**Hardware,** in order: EREVID readback, then link LED, then ping from a PC
with Wireshark watching, then UDP echo, then throughput measurement.
