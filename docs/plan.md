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
| M4 | UDP echo — parsing, checksums, echo path | 10k datagrams echoed correctly | **Works on hardware, bidirectionally.** Volume testing folds into M5 |
| M5 | Max speed — UDP blaster, measurement scripts, full duplex | >= 9.3 Mbit/s, loss-free | Not started |

Each milestone is a self-contained chunk; M3 is the largest.


## Current status (2026-08-30)

**M1–M4 all work on real hardware.** The headline demo runs: a line typed on
one node's serial console appears on the other's OLED, in both directions, with
each message counted only by its receiver.

| | milestone | state |
|---|---|---|
| M1 | SPI alive, `EREVID` readback | hardware ✓ both nodes |
| M2 | Link up, MAC config, `RXEN` | hardware ✓, MAC address now verified by readback |
| M3 | ARP responder | hardware ✓ — `ping` goes "unreachable" → "timed out" |
| M4 | UDP message display | hardware ✓ — bidirectional, board to board |
| M5 | Throughput | **not started** — this is the next phase |

Best measured run, both nodes on build `000C`, 8 minutes:

| node | frames | ARP parsed | replies | re-inits | longest gap |
|---|---|---|---|---|---|
| Host A | 437 | 239 | 11 | 0 | 4.0 s |
| Host B | 435 | 239 | 11 | 0 | 4.4 s |

Resource use is now the thing to watch going into M5: **4,126 / 6,272 LE (66%)**,
1,628 registers, 4,472 memory bits. M5 adds a payload generator and a
loss-counting receiver, so the remaining third of the device is the budget.

### The five faults that had to be fixed first

All were invisible in simulation and are written up in full, with the
diagnostic that found each, in [enc28j60.md](enc28j60.md). Summarised only so
the shape of the problem is visible from here:

| # | fault | signature |
|---|---|---|
| 1 | Every transmitted frame had a bad CRC | switch counted octets, zero packets, zero errors |
| 2 | `ECON1` bank selects cleared `RXEN` | ran a while, then received nothing |
| 3 | Two-byte SPI helpers hung when data equalled the opcode | froze after ~128 frames (2-in-256 per frame) |
| 4 | A JTAG reflash does not reset the ENC28J60 | `A=0000` from the first frame |
| 5 | `TCSH` is 210 ns for MAC/MII, not the 10 ns for ETH | every MAC register write silently failed to commit |

Fault 5 is the one worth internalising: it had been corrupting the MAC setup
since M2 and explains three symptoms that looked unrelated — no unicast
reception, bad transmit CRCs, and MAC-register readback returning nonsense.

Each fix carries a regression test verified to **fail** against the pre-fix RTL
rather than pass vacuously, which is the only way to know a test is doing
anything. Six testbenches pass.

### Recovery, and what it is for

A corrupt receive chain, a stalled receiver, or a deliberate `KEY3` press all
route into the same recovery: hand the SPI bus back, re-run the entire
bring-up — hardware reset, errata-19 reset sequence, `ESTAT.CLKRDY`
confirmation, full M2 configuration — then hand back. All three routes have run
on real silicon, not just in simulation:

- **chain corruption** — Host A absorbed 542 of them while continuing to serve ARP
- **`KEY3`** — manual trigger, for exercising the path on demand
- **stall watchdog** — proven by shutting the node's switch port for 60 s
  (`pc/blackout-test.ps1`), which fired two re-inits and recovered cleanly

### The dominant risk right now: the wiring

**Host A is down as of this writing** — `MAC=000000000000`, unreachable, while
its switch port still shows `connected`. Link up with SPI dead means the module
has power and its PHY is running, but the SPI path is not responding.

This is the second such failure in a day. Host B had the same class of fault
after its jumpers were disturbed: 633 re-inits in eight minutes against Host A's
zero, on identical firmware, with the MAC reading back differently on every
re-init. Reseating fixed it completely.

Both nodes are wired with F-F DuPont jumpers, and that is now the least
reliable part of the system by a wide margin. **Before any M5 throughput
measurement is worth recording, the wiring has to be made solid** — soldered
leads, or at minimum shorter jumpers with strain relief. A throughput figure
taken over a marginal SPI link measures the jumper, not the design.

The `MAC=` field on the console's `ID` line is the fastest check: it is written
once at init and re-read on every re-init, so a value that is wrong *and varies
between reads* is a connection fault, not a firmware one.

### ICMP echo: ping works

`ping 192.168.1.61` now returns replies rather than timing out — 30 of 30, zero
loss, TTL 64. Host A, still on the previous build, timed out on the same LAN
during the same test, which is as clean a control as this project has managed.

The payload bound behaves as designed: the 40-byte echo buffer holds an 8-byte
ICMP header plus a 32-byte payload, so `ping` and `ping -l 32` are answered
while `ping -l 40` and larger are walked and ignored. A truncated reply would
be rejected by the sender anyway, so not answering is the honest response.

Cost: 66% → 83% LE, setup slack 4.27 → 2.32 ns. Most of it is the echo buffer,
read asynchronously and therefore built from logic; only 2% of M9K is in use,
so a synchronous read would recover most of it if space gets tight.

### Button state across the wire

Pressing a button on one node puts its key state on the other node's OLED, in
the same notation as the local KEYS console line: `A KEYS 0...` is node A with
KEY0 held. Both nodes run the same build, so it works in either direction.

Confirmed on hardware three independent ways, which is what made it convincing
rather than merely plausible. Five presses of KEY0 on Host A:

| | baseline | after | delta |
|---|---|---|---|
| Host A `B=` (sends queued) | 24 | 34 | +10 |
| switch port 13 `InUcastPkts` | 35 | 45 | +10 |
| switch port 13 `InOctets` | 2,363 | 3,033 | +670 = 10 x 67 |
| Host B `M=` (messages accepted) | 1 | 11 | +10 |

Ten sends for five presses because press and release are both real state
changes, and the display should follow both.

**The `B=` counter is the reason this was diagnosable at all.** "The peer's
display did not change" has three causes -- the button never reached the
design, the send never fired, or the frame never arrived -- and without a
counter at the sending end there is no way to tell them apart. Adding one
turned a guessing exercise into a single measurement. The same move has now
paid off four times on this project: the transmit status vector, the poll
counter, the message counter, and this.

A related trap worth recording: the first attempt at this test was inconclusive
because the presses happened *before* any switch baseline was taken, so "the
switch shows 35 packets" said nothing. A delta needs both ends.

### Known open

- **ICMP echo is not implemented**, so `ping` resolves ARP and then times out.
  That is the defined M3 exit criterion, not a defect, but it does mean `ping`
  cannot be used as a liveness check for M5.
- The receive-chain corruption still happens occasionally in bursts. The
  recovery absorbs it invisibly; the underlying cause has not been isolated,
  and it may well be the same wiring marginality.

## M5: throughput

The goal is **≥ 9.3 Mbit/s of UDP payload, loss-free**, against the derived
ceiling of ~9.57 Mbit/s (1,472 B payload inside 1,538 B of wire occupancy,
~813 packets/s). The budget section above has the arithmetic.

### What has to be built

1. **A parameterised frame writer.** The transmit path currently emits
   fixed-size frames — a 60-byte ARP reply, a 63-byte message. M5 needs
   arbitrary lengths up to 1,514 bytes, which means the `txpos` counters and
   the length arithmetic stop fitting in the current 6-bit registers. That
   width assumption is exactly the kind that failed silently before (`m2_idx`
   was 5 bits for a 6-bit table), so size these from the actual maximum.
2. **A payload generator.** Counting patterns, not stored data — 1,472 bytes of
   buffer per frame is affordable but pointless when the receiver can verify a
   sequence arithmetically.
3. **A sequence number and a loss counter.** Put a 32-bit sequence in the
   payload; the receiver counts received, out-of-order and missing. Loss has to
   be measured at the receiver, because the switch counts frames that arrive,
   not frames that were meant to.
4. **A rate control.** Back-to-back transmission at the SPI level will not
   reach line rate on its own; the interesting number is what it *does* reach,
   so make the inter-frame gap adjustable and sweep it.

### How it gets measured

Three independent instruments, which is what made the earlier debugging
tractable:

- **the receiver's own counters** — packets, bytes, sequence gaps, over the console
- **the switch port counters** — `InUcastPkts` and `InOctets` on Gi1/0/13 and
  Gi1/0/17, an authoritative count that owes nothing to our RTL
- **elapsed time** from the console, so throughput is derived from the node's
  own clock rather than the PC's scheduling

A run only counts if the receiver's packet count and the switch's agree.

### Order of work

1. **Fix the wiring first.** Nothing measured before this is worth recording.
2. Long soak — 30–60 minutes, both nodes, target zero re-inits. Every previous
   long soak was measuring a node with a wiring fault.
3. Widen the transmit path to arbitrary frame lengths; extend `tb_m4` to send
   and check a maximum-size frame.
4. Add the sequence number, the loss counter and the rate control, with a
   testbench that injects a deliberate gap and checks it is counted.
5. Measure: sweep the inter-frame gap, record throughput against loss, and
   confirm the switch agrees with the receiver at each point.
6. Only if the number falls short: revisit duplex. Both nodes currently
   negotiate 10 Mbit **half** duplex through the switch. Full duplex needs
   `PHCON1.PDPXMD` and `MACON3.FULDPX` on both nodes, and — per the duplex
   section above — setting it on one side only causes a duplex mismatch that
   collapses under load. Both or neither.

## Verification approach

**Simulation.** A behavioral ENC28J60 SPI-slave model in the testbench
implements the opcode set, register banks, and buffer memory. The testbench
drives init -> ARP -> ICMP -> UDP and self-checks the frames the design emits.
This is where most stack bugs should die, before hardware is involved.

**Hardware,** in order: EREVID readback, then link LED, then ping from a PC
with Wireshark watching, then UDP echo, then throughput measurement.
