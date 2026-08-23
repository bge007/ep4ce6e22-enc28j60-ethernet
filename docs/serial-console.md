# Serial console and buttons

Each node exposes a 115200 8N1 console on the board's **onboard CH340**, so a
single USB-C cable carries both power and the terminal. No extra hardware, no
extra jumpers, no USB-serial dongle.

The console does three things:

- prints a banner at reset, so you can tell the port is alive and which host
  you are talking to
- prints a line every time a button changes, with the same state the OLED shows
- takes a line you type and puts it on the OLED's bottom row

That last one is the manual version of the milestone-4 demo: today you type
`Hello World` into Host A's terminal and it appears on Host A's screen; once
the Ethernet stack lands it will travel to Host B's screen instead.

## Pins

| Signal | FPGA pin | Direction | Note |
|---|---|---|---|
| `uart_tx` | `PIN_10` | FPGA → CH340 | silkscreened `TX_10` beside the CH340 |
| `uart_rx` | `PIN_23` | CH340 → FPGA | silkscreened `RX 23` |

Both are dedicated to the CH340 and are **not** brought out on the B or C
group headers, so nothing needs wiring and no jumper cap affects them. This is
the same assignment the `hello_demo` project used, which was verified on real
hardware.

## Using it from PowerShell

[`pc/serial-monitor.ps1`](../pc/serial-monitor.ps1) auto-detects the CH340 and
opens an interactive terminal.

```powershell
.\pc\serial-monitor.ps1
```

```powershell
.\pc\serial-monitor.ps1 -List                       # show candidate COM ports
.\pc\serial-monitor.ps1 -Port COM5                  # pick one explicitly
.\pc\serial-monitor.ps1 -Port COM5 -Send "Hello World"   # one-shot, for scripts
```

With two boards plugged in there will be two CH340 ports, so auto-detect bows
out and lists them — pass `-Port` to pick. Open two PowerShell windows, one per
node, and you have both consoles side by side.

Esc quits. **The FPGA does not echo characters**, so the script echoes locally;
if you use a different terminal (PuTTY, Tera Term) turn on local echo or you
will type blind. Echoing in hardware would mean arbitrating the transmitter
against the banner and button messages for no real benefit.

Any terminal at **115200 8N1, no flow control** works just as well.

## What you see

At reset:

```
EP4CE6E22 node A ready
```

Press button 0, then also button 2, then release both:

```
KEYS 0...
KEYS 0.2.
KEYS ....
```

Each of the four characters is that button's number when pressed and `.` when
not, so the line reads as a little bitmap. The OLED's line 2 shows exactly the
same four characters.

Type `Hello World` and press Enter:

```
MSG: Hello World
```

and the OLED's bottom line becomes `Hello World`.

## Buttons

| Button | FPGA pin | Role |
|---|---|---|
| `key[0]` | `PIN_114` | user button 0 |
| `key[1]` | `PIN_89`  | user button 1 |
| `key[2]` | `PIN_80`  | user button 2 |
| `key[3]` | `PIN_73`  | user button 3 |
| RESET    | `PIN_88`  | **resets the FPGA** — not readable as a user button |

The board has five buttons but only four are usable. `PIN_88` is the design's
reset, so while it is held the logic is in reset and cannot report anything.
Reading it as a fifth button would mean giving up the reset.

Buttons are active low with external pull-ups, and
[`rtl/debounce.v`](../rtl/debounce.v) requires **10 ms** of stable level before
the output follows — the counter restarts on every bounce, so a noisy contact
just delays the transition rather than producing a burst of events. The
debouncer also emits one-cycle press and release pulses, which is what triggers
the serial line and the OLED repaint.

A change that arrives while the OLED is mid-repaint would otherwise be missed,
because a full panel refresh takes ~25 ms and the driver is busy throughout.
`eth_top` latches a `redraw_pending` flag in that window and repaints again as
soon as the panel goes idle.

## How it is built

| File | Role |
|---|---|
| [`rtl/uart_tx.v`](../rtl/uart_tx.v) | 8N1 transmitter |
| [`rtl/uart_rx.v`](../rtl/uart_rx.v) | 8N1 receiver, mid-bit sampling |
| [`rtl/uart_console.v`](../rtl/uart_console.v) | Banner, key lines, line assembly, echo |
| [`rtl/debounce.v`](../rtl/debounce.v) | Four independent debouncers |
| [`tb/tb_uart.v`](../tb/tb_uart.v) | Self-checking testbench |

**Bit rate.** 50 MHz ÷ 115200 = 434.03 clocks per bit. The divider rounds to
nearest rather than truncating: at 434 the error is 0.006 %, but truncating
every bit would walk the sampling point earlier across the frame.

**Receiving.** On the falling edge that starts a frame the receiver waits half
a bit time and re-checks that the line is still low, so a glitch on an idle
line is rejected rather than becoming a garbage byte. From that midpoint it
samples every bit time, which keeps each sample centred. A frame whose stop bit
is not high sets `rx_err` and the console drops that byte.

**Line buffer.** 21 characters, matching one OLED row. Backspace and DEL erase;
the first character of a new line clears the previous one so a short message
does not leave the old tail behind; input past 21 characters is dropped rather
than wrapping.

## Verification

`tb/tb_uart.v` passes, checking:

- `uart_tx` → `uart_rx` round-trips bytes at the real bit rate, no framing errors
- the banner is transmitted at reset with the host letter substituted
- a button press produces `KEYS 0...`, and two produce `KEYS .1.3`
- a line typed in lands in the message buffer, is blank-padded, and comes back
  as `MSG: Hello World`
- backspace erases the character before it

```
INFO: PHY loopback OK
INFO: banner seen, 24 bytes so far
INFO: button lines OK
INFO: line receive + echo OK
INFO: backspace OK
PASS: UART loopback, banner, key lines, line receive, echo, backspace
```

Quartus 25.1 with everything integrated: 0 errors, **1,499 / 6,272 LE (24 %)**,
582 registers, +4.27 ns setup and +0.45 ns hold slack.

Still **not tested on hardware**, like the rest of this repo.
