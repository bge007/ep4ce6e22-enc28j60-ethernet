# Two-node wiring: Host A ⇄ Host B

Two identical EP4CE6E22 + ENC28J60 nodes joined by one LAN cable.

## The cable must be a crossover

The ENC28J60 has **no Auto-MDIX**, and with no switch in this topology there is
nothing to do the crossing for you. A straight-through patch cable wires
transmitter to transmitter and the link LED never comes on.

Use a crossover cable (T568A crimped on one end, T568B on the other), or drop
any 10/100 switch between the two boards and use two ordinary patch cables.

| Host A RJ45 | | Host B RJ45 |
|---|---|---|
| 1 TX+ | → | 3 RX+ |
| 2 TX− | → | 6 RX− |
| 3 RX+ | ← | 1 TX+ |
| 6 RX− | ← | 2 TX− |
| 4, 5, 7, 8 | — | unused at 10Base-T |

## Per-board connections (identical on both hosts)

| FPGA net | FPGA pin | Dir | Module header | ENC28J60 IC pin | Note |
|---|---|---|---|---|---|
| `enc_sck`   | PIN_103 | → | `SCK`   | 8  | 12.5 MHz in M1, 20 MHz final |
| `enc_mosi`  | PIN_104 | → | `SI`    | 7  | master out |
| `enc_miso`  | PIN_105 | ← | `SO`    | 6  | master in |
| `enc_cs_n`  | PIN_106 | → | `CS`    | 9  | active low, held low across a burst |
| `enc_rst_n` | PIN_110 | → | `RESET` | 10 | hold low ≥1 ms at power-up |
| `enc_int`   | PIN_111 | ← | `INT`   | 4  | optional — M1 polls `EPKTCNT` |
| 3.3 V | — | — | `VCC` | 28 | **own regulator**, not an FPGA pin |
| GND | GND | — | `GND` | 2 | common ground, mandatory |

`TPOUT±` → RJ45 pins 1,2 and `TPIN±` ← RJ45 pins 3,6 are wired inside the
breakout through the magnetics, along with the RBIAS resistor and
termination. You never touch them.

> **Match the module header by label, not by position.** ENC28J60 breakouts
> ship with several different 2×5 header layouts. The FPGA pin numbers were
> taken from the other projects' pinouts on this board rather than a header
> diagram — check both against the silkscreen before powering on.

Power: the module draws up to ~180 mA transmitting. Give it its own 3.3 V
regulator rated ≥300 mA, tie grounds to the FPGA, and decouple with
100 nF + 10 µF at the module.

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

## This topology unlocks full duplex

The ENC28J60 cannot auto-negotiate, which is why a switch always falls back to
10 Mbit/s half duplex. Two ENC28J60s on a direct crossover cable have no
negotiating partner to disagree with: set `PHCON1.PDPXMD` and `MACON3.FULDPX`
on **both** boards and the link runs full duplex, ~9.5 Mbit/s each way
simultaneously.

Set it on only one side and you get a duplex mismatch — late collisions and
throughput that collapses under load. Both or neither.

## Bring-up order

1. **Power first, cable second.** Confirm `EREVID` = `0x06` on each board
   independently with no cable attached. A board that cannot reach its own
   controller over SPI will not be fixed by plugging in Ethernet.
2. **Then the crossover cable.** Link LEDs on both modules should light within
   a second. Exactly one lit → suspect the cable. Neither lit → suspect PHY
   init.
3. **Then ARP.** Host A ARPs for Host B's IP. A reply proves the whole path in
   both directions: SPI out, transmit, cable, receive, SPI in.
4. **Then throughput.** Host A streams 1,472-byte sequence-numbered UDP
   datagrams; Host B counts bytes and gaps.
