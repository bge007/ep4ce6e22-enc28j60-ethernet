// eth_top.v -- Milestone 1: prove the SPI path to the ENC28J60.
//
// Sequence after power-up / nrst:
//   1. Hold ENC28J60 RESET low 2 ms, release, wait 10 ms (osc + PHY start).
//   2. System Reset Command (0xFF), then wait 1 ms  (errata: don't trust
//      ESTAT.CLKRDY after an SRC -- a fixed delay is the reliable path).
//   3. WCR ECON1 = 0x03  (select register bank 3).
//   4. RCR EREVID (0x12) -- Ethernet register, data arrives in byte 2.
//   5. Show the value on the 5 LEDs (active low). Rev B7 silicon = 0x06
//      = LEDs [4:0] show 0_0110 -> led[1] and led[2] lit.
//   6. Re-read 10x per second so a loose wire shows up as flicker.
//
// key[0] (active low) held down: LEDs show the *raw* last SPI byte's upper
// bits instead -- crude but enough to distinguish "all zeros" (MISO stuck
// low / no power) from "all ones" (MISO stuck high / not connected).

module eth_top #(
    // 1 = Host A (192.168.1.60), 2 = Host B (192.168.1.61). Build twice.
    parameter [7:0]  HOST_ID = 8'd1
) (
    input  wire       clk,        // 50 MHz
    input  wire       nrst,       // board reset button, active low
    input  wire [3:0] key,        // user buttons, active low
    output wire [4:0] led,        // active low

    output wire       enc_rst_n,
    output wire       enc_cs_n,
    output wire       enc_sck,
    output wire       enc_mosi,
    input  wire       enc_miso,
    input  wire       enc_int,    // unused in M1

    inout  wire       oled_scl,   // 1.3" SSD1306 OLED, I2C
    inout  wire       oled_sda,

    output wire       uart_tx,    // to CH340 -> USB COM port
    input  wire       uart_rx     // from CH340
);

    // ------------------------------------------------------------------
    // reset: power-on reset OR the board's RESET button
    //
    // The POR half is not optional. Cyclone IV registers come out of
    // configuration cleared, so rst_sync powered up to 2'b00 and `rst` was
    // never asserted -- every reset block in the design was skipped, and
    // every register whose reset value is NOT zero started life wrong:
    //
    //   oled_ssd1306.clear_pass  1 -> 0  display-on 0xAF never sent, panel
    //                                    stays dark until RESET is pressed
    //                                    (this is the "OLED only appears
    //                                    after a reset press" symptom)
    //   uart_console.req_banner  1 -> 0  no boot banner
    //   eth_top.m12_cs_n         1 -> 0  ENC28J60 chip-select ASSERTED from
    //   net_stack.cs_n           1 -> 0  configuration, so the first SPI
    //                                    transaction has no framing CS edge
    //   eth_top.last_shown    0xFF -> 0  minor: first OLED repaint trigger
    //
    // Pressing RESET repaired all of it at once, which is exactly why the
    // board "worked" only after a button press. por_rst is initialised to 1
    // and the counter to 0 in their declarations; Quartus encodes those
    // power-up values into the configuration bitstream for Cyclone IV, so
    // the reset is genuinely asserted from the first clock after config.
    //
    // 65536 cycles at 50 MHz is ~1.3 ms, comfortably longer than anything
    // downstream needs to see a clean reset. (The OLED driver additionally
    // runs its own 100 ms POR_TICKS delay before touching the panel.)
    // ------------------------------------------------------------------
    reg [15:0] por_cnt = 16'd0;
    reg        por_rst = 1'b1;
    always @(posedge clk) begin
        if (por_cnt != 16'hFFFF) por_cnt <= por_cnt + 16'd1;
        else                     por_rst <= 1'b0;
    end

    reg [1:0] rst_sync;
    always @(posedge clk) rst_sync <= {rst_sync[0], ~nrst};
    wire rst = rst_sync[1] | por_rst;

    // Declared here (rather than down in the M2 section that actually sets
    // it) purely so the SPI mux and net_stack instantiation below can use it
    // -- referencing a reg before its driving always block is fine in
    // Verilog, but referencing one before ANY declaration at all, inside a
    // module port connection, is what actually breaks (hit this once
    // already with o_ready/oled_i2c_err_sticky further down).
    reg        eth_ready;            // M2 complete (level, held)

    // Same reason as eth_ready above: net_stack's instantiation (M4's
    // send_req) needs this before uart_console (which actually drives it,
    // via msg_updated) is instantiated further down.
    wire       msg_updated;

    // ------------------------------------------------------------------
    // SPI master (12.5 MHz for bring-up; final design moves to 20 MHz)
    // ------------------------------------------------------------------
    reg        m12_spi_start;
    reg  [7:0] m12_spi_tx;
    reg        m12_cs_n;
    wire [7:0] spi_rx;
    wire       spi_busy;

    // M3 (net_stack) takes over the bus once M2 finishes; see the mux below
    // and the S_HANDOFF note in the M1/M2 FSM further down. Only one of the
    // two ever drives at a time, so this is a plain mux, not an arbiter.
    wire        net_cs_n, net_spi_start;
    wire [7:0]  net_spi_tx;
    wire [15:0] eth_frames_seen, eth_arp_replies;
    wire [7:0]  eth_last_eir, eth_last_estat;
    wire [15:0] eth_arp_reqs, eth_last_etype;
    wire [15:0] eth_tsv_count, eth_tsv_wire, eth_rx_resyncs;
    wire [15:0] eth_polls;
    wire [15:0] eth_msgs_rx;
    wire        net_reinit_req;   // net_stack found the RX chain corrupt
    wire [7:0]  eth_pktcnt;

    wire [7:0]  eth_tsv_s2, eth_tsv_s3;

    wire        mux_cs_n      = eth_ready ? net_cs_n      : m12_cs_n;
    wire        mux_spi_start = eth_ready ? net_spi_start : m12_spi_start;
    wire [7:0]  mux_spi_tx    = eth_ready ? net_spi_tx    : m12_spi_tx;

    spi_master #(.CLK_DIV(2)) u_spi (
        .clk    (clk),
        .rst    (rst),
        .start  (mux_spi_start),
        .tx_byte(mux_spi_tx),
        .rx_byte(spi_rx),
        .busy   (spi_busy),
        .sck    (enc_sck),
        .mosi   (enc_mosi),
        .miso   (enc_miso)
    );

    // M4: net_stack's own read port into uart_console's message buffer (TX),
    // and the buffer it exposes for a received message (RX) -- both wired to
    // uart_console/the OLED writer further down.
    wire [4:0] net_tx_rd_addr;
    wire [7:0] net_tx_rd_data;
    wire [4:0] net_rx_rd_addr;
    wire [7:0] net_rx_rd_data;
    wire       net_rx_updated;

    net_stack #(
        .HOST_ID(HOST_ID),
        .OUR_MAC({40'h0242CE6000, HOST_ID}),
        .OUR_IP ({24'hC0A801, 8'd59 + HOST_ID})
    ) u_net (
        .clk(clk), .rst(rst), .start(eth_ready),
        .cs_n(net_cs_n), .spi_start(net_spi_start), .spi_tx(net_spi_tx),
        .spi_rx(spi_rx), .spi_busy(spi_busy),
        .tx_rd_addr(net_tx_rd_addr), .tx_rd_data(net_tx_rd_data), .send_req(msg_updated),
        .rx_rd_addr(net_rx_rd_addr), .rx_rd_data(net_rx_rd_data), .rx_updated(net_rx_updated),
        .frames_seen(eth_frames_seen), .arp_replies_sent(eth_arp_replies),
        .last_eir(eth_last_eir), .last_estat(eth_last_estat),
        .arp_reqs(eth_arp_reqs), .last_etype(eth_last_etype),
        .rx_resyncs(eth_rx_resyncs),
        .polls(eth_polls), .last_pktcnt(eth_pktcnt), .msgs_rx(eth_msgs_rx),
        .reinit_req(net_reinit_req),
        .tsv_count(eth_tsv_count), .tsv_wire(eth_tsv_wire),
        .tsv_stat2(eth_tsv_s2), .tsv_stat3(eth_tsv_s3)
    );

    assign enc_cs_n = mux_cs_n;

    // ------------------------------------------------------------------
    // ENC28J60 opcodes / registers used here
    // ------------------------------------------------------------------
    localparam [7:0] OP_SRC        = 8'hFF;              // system reset
    localparam [7:0] OP_BFC_ECON2  = {3'b101, 5'h1E};    // Bit Field Clear, ECON2
    localparam [7:0] OP_RCR_ESTAT  = {3'b000, 5'h1D};    // read ESTAT (common)
    localparam [7:0] M_PWRSV       = 8'h20;              // ECON2<5>
    localparam [7:0] OP_WCR_ECON1  = {3'b010, 5'h1F};    // write ECON1
    localparam [7:0] OP_RCR_EREVID = {3'b000, 5'h12};    // read  EREVID (bank 3)
    localparam [7:0] BANK3         = 8'h03;

    // Register addresses below are the standard, widely-documented ENC28J60
    // map (this project was not supplied that datasheet, unlike the OLED's --
    // only general knowledge of this very common chip). The read-back this
    // sequence performs at the end (ECON1/MACON1/MACON3 over UART) is exactly
    // the safety net for that: a transcription mistake here shows up as a
    // wrong hex byte on the console, not a silent failure.
    function [7:0] WCR(input [4:0] a); WCR = {3'b010, a}; endfunction
    function [7:0] RCR(input [4:0] a); RCR = {3'b000, a}; endfunction

    localparam [4:0] A_ECON1    = 5'h1F;                 // common, all banks
    // bank 0
    localparam [4:0] A_ETXSTL   = 5'h04, A_ETXSTH   = 5'h05;
    localparam [4:0] A_ERXSTL   = 5'h08, A_ERXSTH   = 5'h09;
    localparam [4:0] A_ERXNDL   = 5'h0A, A_ERXNDH   = 5'h0B;
    localparam [4:0] A_ERXRDPTL = 5'h0C, A_ERXRDPTH = 5'h0D;
    // bank 1
    localparam [4:0] A_ERXFCON  = 5'h18;
    // bank 2
    localparam [4:0] A_MACON1   = 5'h00, A_MACON3   = 5'h02, A_MACON4 = 5'h03;
    localparam [4:0] A_MABBIPG  = 5'h04;
    localparam [4:0] A_MAIPGL   = 5'h06, A_MAIPGH   = 5'h07;
    localparam [4:0] A_MAMXFLL  = 5'h0A, A_MAMXFLH  = 5'h0B;
    // MII registers (bank 2) -- the only way to reach the PHY's own registers.
    localparam [4:0] A_MIREGADR = 5'h14;
    localparam [4:0] A_MIWRL    = 5'h16, A_MIWRH    = 5'h17;
    // PHY register addresses (16-bit registers, written via the MII trio above)
    localparam [7:0] PHY_PHCON2 = 8'h10;
    // bank 3 -- MAADR file order is NOT sequential with the logical MAC
    // address bytes; this mapping (5,6,3,4,1,2) is the documented quirk.
    localparam [4:0] A_MAADR5   = 5'h00, A_MAADR6   = 5'h01;
    localparam [4:0] A_MAADR3   = 5'h02, A_MAADR4   = 5'h03;
    localparam [4:0] A_MAADR1   = 5'h04, A_MAADR2   = 5'h05;

    // ------------------------------------------------------------------
    // M2: link/MAC init sequence, run once after the first EREVID read.
    //
    // A flat list of SPI transactions: write (opcode, data) or read (opcode,
    // dummy) -- which one, is decoded structurally from the opcode's own top
    // 3 bits (000 = RCR, 010 = WCR), so no separate tag bit is needed. Bank
    // selects are folded into the same list as ordinary WCR ECON1 writes.
    //
    // RX buffer 0x0000-0x19FF (6.5 KB), TX from 0x1A00, matching plan.md.
    // ERXRDPT = ERXND = 0x19FF, which already satisfies the errata requiring
    // an odd address (0x19FF is odd) with no extra work.
    // MACON3 = 0x32: pad to 60B + CRC + frame-length check, HALF duplex
    // (FULDPX=0), with MABBIPG = 0x12, the half-duplex back-to-back gap.
    //
    // These were briefly set to 0x33 / 0x15 (full duplex) on 2026-08-23 while
    // testing a duplex-mismatch theory, and wrongly left that way when it did
    // not immediately fix anything. Reverted 2026-08-26 on direct evidence
    // from the Cisco 2960 the boards are attached to:
    //
    //     Gi1/0/13  connected  1  a-half  a-10
    //     Half-duplex, 10Mb/s, media type is 10/100/1000BaseTX
    //
    // The link really is half duplex, and the ENC28J60's own PHY is at its
    // half-duplex default because nothing here ever writes PHCON1.PDPXMD.
    // Leaving the MAC in full duplex therefore created a duplex mismatch
    // *inside the chip*, which the part requires to match (MACON3.FULDPX and
    // PHCON1.PDPXMD must agree). The switch port counters show exactly what
    // that produces: 0 valid packets input, 0 runts, 0 CRC errors, but
    // "1 giants / 1 input errors" -- frames are physically reaching the
    // switch and being rejected as OVERSIZED, which is what a wrong
    // inter-packet gap does when frames run together.
    //
    // If full duplex is ever wanted (direct crossover cable, no switch), both
    // MACON3.FULDPX and PHCON1.PDPXMD must be set together -- and PHCON1 is a
    // PHY register reached over MIIM, which this design does not implement.
    // MAC address 02:42:CE:60:00:<HOST_ID>, locally administered.
    // Final ECON1 writes double as "select bank N" + "keep RXEN set", since
    // RXEN and BSEL share the same register.
    // ------------------------------------------------------------------
    localparam integer CFG_N = 33;   // +3 for the PHCON2.HDLDIS MIIM write
    reg [7:0] cfg_op  [0:CFG_N-1];
    reg [7:0] cfg_dat [0:CFG_N-1];
    integer ci;
    initial begin
        ci = 0;
        // -- bank 0: RX/TX buffer pointers --
        cfg_op[ci]=WCR(A_ECON1);    cfg_dat[ci]=8'h00; ci=ci+1; // bank 0
        cfg_op[ci]=WCR(A_ERXSTL);   cfg_dat[ci]=8'h00; ci=ci+1;
        cfg_op[ci]=WCR(A_ERXSTH);   cfg_dat[ci]=8'h00; ci=ci+1;
        cfg_op[ci]=WCR(A_ERXNDL);   cfg_dat[ci]=8'hFF; ci=ci+1;
        cfg_op[ci]=WCR(A_ERXNDH);   cfg_dat[ci]=8'h19; ci=ci+1;
        cfg_op[ci]=WCR(A_ERXRDPTL); cfg_dat[ci]=8'hFF; ci=ci+1;
        cfg_op[ci]=WCR(A_ERXRDPTH); cfg_dat[ci]=8'h19; ci=ci+1;
        cfg_op[ci]=WCR(A_ETXSTL);   cfg_dat[ci]=8'h00; ci=ci+1;
        cfg_op[ci]=WCR(A_ETXSTH);   cfg_dat[ci]=8'h1A; ci=ci+1;
        // -- bank 1: receive filter (unicast + broadcast + CRC-valid only;
        //    avoid the pattern-match filter per errata) --
        cfg_op[ci]=WCR(A_ECON1);    cfg_dat[ci]=8'h01; ci=ci+1; // bank 1
        cfg_op[ci]=WCR(A_ERXFCON);  cfg_dat[ci]=8'hA1; ci=ci+1;
        // -- bank 2: MAC config, half duplex to match the link (see above) --
        cfg_op[ci]=WCR(A_ECON1);    cfg_dat[ci]=8'h02; ci=ci+1; // bank 2

        // ---- PHY: PHCON2.HDLDIS -- disable half-duplex loopback ----
        // DATASHEET-CONFIRMED, section 6.6: "If using half duplex, the host
        // controller may wish to set the PHCON2.HDLDIS bit to prevent
        // automatic loopback of the data which is transmitted."
        //
        // Without it the PHY loops transmitted frames back internally in half
        // duplex instead of driving them cleanly onto the wire, which explains
        // BOTH long-standing symptoms at once: the Cisco 2960 counting
        // InOctets on Gi1/0/13 while never completing a single valid frame
        // (no FCS/runt/giant error, because no frame ever finishes), and
        // net_stack's receive side racing through garbage -- it has been
        // receiving our own transmissions looped back.
        //
        // PHY registers are not reachable over SPI directly; they go through
        // the MII trio. Per datasheet 3.3.2: write MIREGADR, then MIWRL, then
        // MIWRH -- writing MIWRH starts the transaction, so it must come last.
        // All three are ordinary WCR writes, so this needs none of the
        // MAC-type register *read* protocol that this project could never get
        // working. The transaction takes 10.24 us; the eight MAC-config writes
        // that immediately follow take longer than that at 12.5 MHz SPI, so
        // they double as the required settle time, and nothing after this
        // touches MIWRH again.
        cfg_op[ci]=WCR(A_MIREGADR); cfg_dat[ci]=PHY_PHCON2; ci=ci+1; // PHCON2
        cfg_op[ci]=WCR(A_MIWRL);    cfg_dat[ci]=8'h00;      ci=ci+1; // low byte
        cfg_op[ci]=WCR(A_MIWRH);    cfg_dat[ci]=8'h01;      ci=ci+1; // HDLDIS = bit 8 -> 0x0100, starts MIIM
        cfg_op[ci]=WCR(A_MACON1);   cfg_dat[ci]=8'h01; ci=ci+1; // MARXEN
        cfg_op[ci]=WCR(A_MACON3);   cfg_dat[ci]=8'h32; ci=ci+1; // pad/CRC/half-dup
        // MACON4 = 0x40: DEFER (bit 6) set. DATASHEET-CONFIRMED, not a guess
        // -- DS39662E section 6.5 step 3: "Configure the bits in MACON4. For
        // conformance to the IEEE 802.3 standard, set the DEFER bit."
        //
        // This was 0x00 (DEFER clear) until 2026-08-27, and the datasheet says
        // what that does in half duplex: "When the medium is occupied, the MAC
        // will abort the transmission after the excessive deferral limit is
        // reached." On a busy segment the medium is occupied constantly, so
        // transmissions were aborting part-way through.
        //
        // That matches the Cisco 2960 port counters exactly: InOctets 1140 but
        // InUcastPkts/InMcastPkts/InBcastPkts all 0, and Align-Err, FCS-Err,
        // Rcv-Err, UnderSize, Runts and Giants ALL zero. Signal energy arrives
        // and is counted, but no frame ever completes -- so there is nothing
        // to classify as a CRC, runt or giant error.
        cfg_op[ci]=WCR(A_MACON4);   cfg_dat[ci]=8'h40; ci=ci+1; // DEFER
        cfg_op[ci]=WCR(A_MABBIPG);  cfg_dat[ci]=8'h12; ci=ci+1; // half-duplex value
        cfg_op[ci]=WCR(A_MAIPGL);   cfg_dat[ci]=8'h12; ci=ci+1;
        cfg_op[ci]=WCR(A_MAIPGH);   cfg_dat[ci]=8'h0C; ci=ci+1;
        cfg_op[ci]=WCR(A_MAMXFLL);  cfg_dat[ci]=8'hEE; ci=ci+1; // 1518
        cfg_op[ci]=WCR(A_MAMXFLH);  cfg_dat[ci]=8'h05; ci=ci+1;
        // -- bank 3: MAC address 02:42:CE:60:00:<HOST_ID> --
        cfg_op[ci]=WCR(A_ECON1);    cfg_dat[ci]=8'h03; ci=ci+1; // bank 3
        cfg_op[ci]=WCR(A_MAADR5);   cfg_dat[ci]=8'h00; ci=ci+1;
        cfg_op[ci]=WCR(A_MAADR6);   cfg_dat[ci]=HOST_ID; ci=ci+1;
        cfg_op[ci]=WCR(A_MAADR3);   cfg_dat[ci]=8'hCE; ci=ci+1;
        cfg_op[ci]=WCR(A_MAADR4);   cfg_dat[ci]=8'h60; ci=ci+1;
        cfg_op[ci]=WCR(A_MAADR1);   cfg_dat[ci]=8'h02; ci=ci+1;
        cfg_op[ci]=WCR(A_MAADR2);   cfg_dat[ci]=8'h42; ci=ci+1;
        // -- enable reception, then read back proof --
        //
        // MACON1/MACON3 readback was tried and dropped: this project was not
        // supplied the ENC28J60 datasheet, and two different guesses at the
        // MAC-register SPI read protocol (dummy byte vs. none) both produced
        // wrong, and differently wrong, values on real hardware -- a sign
        // something about that protocol is still misunderstood rather than
        // something to keep guessing at. ECON1 is kept: its readback (an
        // Ethernet-type/common register, immediate response, no dummy byte
        // ambiguity) has been confirmed correct against real hardware twice.
        cfg_op[ci]=WCR(A_ECON1);    cfg_dat[ci]=8'h04; ci=ci+1; // bank0, RXEN=1
        cfg_op[ci]=RCR(A_ECON1);    cfg_dat[ci]=8'h00; ci=ci+1; // readback
        // Leave bank 3 selected (RXEN stays set): the pre-existing periodic
        // EREVID re-read in S_IDLE/S_RD_OP assumes bank 3 stays current
        // forever, same as before M2 existed. Without this, that re-read
        // silently starts reading whatever address 0x12 means in bank 2.
        cfg_op[ci]=WCR(A_ECON1);    cfg_dat[ci]=8'h07; ci=ci+1; // bank3, RXEN=1
        // synthesis translate_off
        // Simulation-only: if this fires, CFG_N is out of sync with the
        // number of entries actually written above.
        if (ci != CFG_N)
            $display("ERROR: eth_top cfg_op table has %0d entries, CFG_N=%0d", ci, CFG_N);
        // synthesis translate_on
    end

    // delays at 50 MHz
    localparam [19:0] T_300US = 20'd15_000;
    localparam [19:0] T_2MS  = 20'd100_000;
    localparam [19:0] T_10MS = 20'd500_000;
    localparam [22:0] T_100MS = 23'd5_000_000;

    // ------------------------------------------------------------------
    // M1 command FSM
    // ------------------------------------------------------------------
    localparam S_HW_RESET   = 4'd0;
    localparam S_HW_WAIT    = 4'd1;
    localparam S_SRC        = 4'd2;
    localparam S_SRC_WAIT   = 4'd3;
    localparam S_BANK_OP    = 4'd4;
    localparam S_BANK_DATA  = 4'd5;
    localparam S_RD_OP      = 4'd6;
    localparam S_RD_DATA    = 4'd7;
    localparam S_LATCH      = 4'd8;
    localparam S_IDLE       = 4'd9;
    // M2: link/MAC init, ROM-driven, runs once (see S_LATCH below)
    localparam S_M2_OP      = 4'd10;
    localparam S_M2_OPWAIT  = 4'd11;
    localparam S_M2_WRWAIT  = 4'd12;
    localparam S_M2_RDWAIT  = 4'd13;
    localparam S_M2_NEXT    = 4'd14;
    localparam S_M2_DONE    = 4'd15;
    localparam S_HANDOFF    = 5'd16;   // M1/M2 FSM done forever; net_stack owns SPI now
    // Errata DS80349C item 19 reset sequence, for "a device in an unknown
    // state" -- which is exactly what a JTAG reconfigure leaves behind, since
    // the FPGA restarts while the ENC28J60 keeps whatever state it had. The
    // critical part is clearing ECON2.PWRSV FIRST: in Power Save mode the SPI
    // System Reset command has no effect at all, so a plain SRC can silently
    // do nothing and every register write afterwards lands on a part that was
    // never reset.
    localparam S_PWRSV_OP   = 5'd17;
    localparam S_PWRSV_DAT  = 5'd18;
    localparam S_PWRSV_WAIT = 5'd19;   // step 2: >= 300 us for the regulator
    localparam S_CLKRDY_OP  = 5'd20;   // step 5: confirm the reset took
    localparam S_CLKRDY_DAT = 5'd21;
    localparam S_CLKRDY_CHK = 5'd22;
    localparam S_CLKRDY_WAIT= 5'd23;   // step 4: >= 1 ms for the reset to complete
    // Read MAADR1..6 back after configuring them. MAC-type registers return a
    // DUMMY byte before the data (datasheet 4.2.1, Figure 4-4) -- three bytes
    // per read, not two. Getting that wrong is why this project's earlier
    // MAC-register readback attempts returned nonsense and were abandoned,
    // which in turn meant the MAC address was written but never verified.
    localparam S_MACRD_OP   = 5'd24;
    localparam S_MACRD_DUM  = 5'd25;
    localparam S_MACRD_DAT  = 5'd26;
    localparam S_MACRD_NEXT = 5'd27;

    reg [4:0]  state;
    reg [22:0] wait_cnt;
    reg        enc_rst_q;
    reg        m12_ph2;             // explicit SPI phase; never infer it from data
    reg [7:0]  estat_rb;
    reg [15:0] reinits;             // full re-initialisations performed
    reg [47:0] mac_rb;              // MAADR1..6, captured from the 3rd byte
    reg [47:0] mac_d;               // ... and from the 2nd, to settle which
                                    // byte actually carries the data
    reg [2:0]  mac_idx;
    // MAADR1 is the first octet on the wire but lives at 04h; the file order
    // is deliberately not sequential (datasheet Table 3-1, bank 3).
    function [4:0] maadr_addr(input [2:0] i);
        case (i)
            3'd0: maadr_addr = 5'h04;   // MAADR1
            3'd1: maadr_addr = 5'h05;   // MAADR2
            3'd2: maadr_addr = 5'h02;   // MAADR3
            3'd3: maadr_addr = 5'h03;   // MAADR4
            3'd4: maadr_addr = 5'h00;   // MAADR5
            default: maadr_addr = 5'h01; // MAADR6
        endcase
    endfunction
    reg [7:0]  erevid;
    reg        spi_busy_d;

    reg        m2_started;          // guards the once-only M2 sequence
    reg [5:0]  m2_idx;               // index into cfg_op/cfg_dat, 0..CFG_N-1
    reg [7:0]  econ1_rb;             // the one register this sequence reads back
    wire       m2_is_read = (cfg_op[m2_idx][7:5] == 3'b000);
    // The only read left in this sequence is ECON1, an Ethernet-type/common
    // register that returns data immediately after the opcode -- no dummy
    // byte. MAC-type register readback was tried and dropped; see the
    // comment above the cfg_op table.

    wire spi_done = spi_busy_d & ~spi_busy;   // falling edge of busy

    assign enc_rst_n = enc_rst_q;

    always @(posedge clk) begin
        spi_busy_d <= spi_busy;
        m12_spi_start  <= 1'b0;                   // default: single-cycle pulse

        if (rst) begin
            state      <= S_HW_RESET;
            wait_cnt   <= 23'd0;
            m12_cs_n       <= 1'b1;
            enc_rst_q  <= 1'b0;
            m12_ph2    <= 1'b0;
            estat_rb   <= 8'h00;
            reinits    <= 16'd0;
            mac_rb     <= 48'd0;
            mac_d      <= 48'd0;
            mac_idx    <= 3'd0;
            erevid     <= 8'h00;
            m2_started <= 1'b0;
            m2_idx     <= 6'd0;
            econ1_rb   <= 8'h00;
            eth_ready  <= 1'b0;
        end else begin
            case (state)
                S_HW_RESET: begin
                    enc_rst_q <= 1'b0;
                    if (wait_cnt == {3'b000, T_2MS}) begin
                        wait_cnt  <= 23'd0;
                        enc_rst_q <= 1'b1;
                        state     <= S_HW_WAIT;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;
                end

                S_HW_WAIT:
                    if (wait_cnt == {3'b000, T_10MS}) begin
                        wait_cnt <= 23'd0;
                        state    <= S_PWRSV_OP;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;

                // ---- errata 19, step 1: clear ECON2.PWRSV ----
                S_PWRSV_OP: begin
                    m12_cs_n      <= 1'b0;
                    m12_spi_tx    <= OP_BFC_ECON2;
                    m12_spi_start <= 1'b1;
                    m12_ph2       <= 1'b0;
                    state         <= S_PWRSV_DAT;
                end
                S_PWRSV_DAT:
                    if (spi_done) begin
                        if (!m12_ph2) begin
                            m12_ph2       <= 1'b1;
                            m12_spi_tx    <= M_PWRSV;
                            m12_spi_start <= 1'b1;
                        end else begin
                            m12_cs_n <= 1'b1;
                            wait_cnt <= 23'd0;
                            state    <= S_PWRSV_WAIT;
                        end
                    end

                // ---- step 2: let the internal regulator settle ----
                S_PWRSV_WAIT:
                    if (wait_cnt == {3'b000, T_300US}) begin
                        wait_cnt <= 23'd0;
                        state    <= S_SRC;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;

                S_SRC: begin
                    m12_cs_n      <= 1'b0;
                    m12_spi_tx    <= OP_SRC;
                    m12_spi_start <= 1'b1;
                    state     <= S_SRC_WAIT;
                end

                S_SRC_WAIT:
                    if (spi_done) begin
                        m12_cs_n <= 1'b1;
                        wait_cnt <= 23'd0;
                        // Step 4's 1 ms is covered by S_BANK_OP's existing
                        // 10 ms wait, but the part must be *checked* before it
                        // is configured, so detour via the CLKRDY read.
                        state    <= S_CLKRDY_WAIT;
                    end

                // ---- step 5: confirm the reset actually took ----
                // ESTAT.CLKRDY (bit 0) set and the unimplemented bit 3 clear.
                // If not, the part is not ready (or never reset) -- go back to
                // step 1 rather than configuring a device in an unknown state.
                S_CLKRDY_WAIT:
                    if (wait_cnt == {3'b000, T_2MS}) begin
                        wait_cnt <= 23'd0;
                        state    <= S_CLKRDY_OP;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;

                S_CLKRDY_OP: begin
                    m12_cs_n      <= 1'b0;
                    m12_spi_tx    <= OP_RCR_ESTAT;
                    m12_spi_start <= 1'b1;
                    m12_ph2       <= 1'b0;
                    state         <= S_CLKRDY_DAT;
                end
                S_CLKRDY_DAT:
                    if (spi_done) begin
                        if (!m12_ph2) begin
                            m12_ph2       <= 1'b1;
                            m12_spi_tx    <= 8'h00;
                            m12_spi_start <= 1'b1;
                        end else begin
                            m12_cs_n <= 1'b1;
                            estat_rb <= spi_rx;
                            state    <= S_CLKRDY_CHK;
                        end
                    end
                S_CLKRDY_CHK: begin
                    wait_cnt <= 23'd0;
                    if (estat_rb[0] && !estat_rb[3]) state <= S_BANK_OP;
                    else                             state <= S_PWRSV_OP;
                end

                S_BANK_OP: begin
                    // wait out the post-SRC delay before first real command
                    if (wait_cnt == {3'b000, T_10MS}) begin
                        m12_cs_n      <= 1'b0;
                        m12_spi_tx    <= OP_WCR_ECON1;
                        m12_spi_start <= 1'b1;
                        state     <= S_BANK_DATA;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;
                end

                S_BANK_DATA:
                    if (spi_done) begin
                        if (m12_cs_n == 1'b0 && m12_spi_tx == OP_WCR_ECON1) begin
                            m12_spi_tx    <= BANK3;
                            m12_spi_start <= 1'b1;
                        end else begin
                            m12_cs_n  <= 1'b1;
                            state <= S_RD_OP;
                        end
                    end

                S_RD_OP: begin
                    m12_cs_n      <= 1'b0;
                    m12_spi_tx    <= OP_RCR_EREVID;
                    m12_spi_start <= 1'b1;
                    m12_ph2       <= 1'b0;
                    state     <= S_RD_DATA;
                end

                S_RD_DATA:
                    if (spi_done) begin
                        // Explicit phase, not "does the byte look like the
                        // opcode?" -- see the op_ph2 note in net_stack.v.
                        if (!m12_ph2) begin
                            m12_ph2       <= 1'b1;
                            m12_spi_tx    <= 8'h00;       // clock in the data byte
                            m12_spi_start <= 1'b1;
                        end else begin
                            m12_cs_n  <= 1'b1;
                            state <= S_LATCH;
                        end
                    end

                S_LATCH: begin
                    erevid   <= spi_rx;
                    wait_cnt <= 23'd0;
                    // Run the M2 link/MAC sequence exactly once, right after
                    // the first EREVID proof. Every later visit to S_LATCH
                    // (the periodic re-read below) just returns to S_IDLE.
                    if (!m2_started) begin
                        m2_started <= 1'b1;
                        m2_idx     <= 6'd0;
                        state      <= S_M2_OP;
                    end else begin
                        state <= S_IDLE;
                    end
                end

                S_IDLE:
                    // re-read ~10x/s (skip re-reset: bank 3 is still selected)
                    if (wait_cnt == T_100MS)
                        state <= S_RD_OP;
                    else
                        wait_cnt <= wait_cnt + 1'b1;

                // ---- M2: walk cfg_op/cfg_dat, one SPI transaction each ----
                S_M2_OP: begin
                    m12_cs_n      <= 1'b0;
                    m12_spi_tx    <= cfg_op[m2_idx];
                    m12_spi_start <= 1'b1;
                    state     <= S_M2_OPWAIT;
                end

                S_M2_OPWAIT:
                    if (spi_done) begin
                        if (m2_is_read) begin
                            m12_spi_tx    <= 8'h00;   // clocks in the reply directly
                            m12_spi_start <= 1'b1;
                            state     <= S_M2_RDWAIT;
                        end else begin
                            m12_spi_tx    <= cfg_dat[m2_idx];
                            m12_spi_start <= 1'b1;
                            state     <= S_M2_WRWAIT;
                        end
                    end

                S_M2_WRWAIT:
                    if (spi_done) begin
                        m12_cs_n  <= 1'b1;
                        state <= S_M2_NEXT;
                    end

                S_M2_RDWAIT:
                    if (spi_done) begin
                        m12_cs_n     <= 1'b1;
                        econ1_rb <= spi_rx;      // the only read in this sequence
                        state    <= S_M2_NEXT;
                    end

                S_M2_NEXT:
                    if (m2_idx == CFG_N - 1) begin
                        state <= S_M2_DONE;
                    end else begin
                        m2_idx <= m2_idx + 6'd1;
                        state  <= S_M2_OP;
                    end

                S_M2_DONE: begin
                    mac_idx <= 3'd0;
                    state   <= S_MACRD_OP;
                end

                // ---- read MAADR1..6 back (3-byte MAC-register read) ----
                // Bank 3 is still selected from the MAC address writes above.
                S_MACRD_OP: begin
                    m12_cs_n      <= 1'b0;
                    m12_spi_tx    <= {3'b000, maadr_addr(mac_idx)};   // RCR
                    m12_spi_start <= 1'b1;
                    state         <= S_MACRD_DUM;
                end
                S_MACRD_DUM:
                    if (spi_done) begin
                        m12_spi_tx    <= 8'h00;   // clocks out the dummy byte
                        m12_spi_start <= 1'b1;
                        state         <= S_MACRD_DAT;
                    end
                S_MACRD_DAT:
                    if (spi_done) begin
                        // byte 2 -- the dummy position per the datasheet
                        case (mac_idx)
                            3'd0: mac_d[47:40] <= spi_rx;
                            3'd1: mac_d[39:32] <= spi_rx;
                            3'd2: mac_d[31:24] <= spi_rx;
                            3'd3: mac_d[23:16] <= spi_rx;
                            3'd4: mac_d[15:8]  <= spi_rx;
                            default: mac_d[7:0] <= spi_rx;
                        endcase
                        m12_spi_tx    <= 8'h00;   // clocks in the real data
                        m12_spi_start <= 1'b1;
                        state         <= S_MACRD_NEXT;
                    end
                S_MACRD_NEXT:
                    if (spi_done) begin
                        m12_cs_n <= 1'b1;
                        case (mac_idx)
                            3'd0: mac_rb[47:40] <= spi_rx;
                            3'd1: mac_rb[39:32] <= spi_rx;
                            3'd2: mac_rb[31:24] <= spi_rx;
                            3'd3: mac_rb[23:16] <= spi_rx;
                            3'd4: mac_rb[15:8]  <= spi_rx;
                            default: mac_rb[7:0] <= spi_rx;
                        endcase
                        if (mac_idx == 3'd5) begin
                            eth_ready <= 1'b1;
                            state     <= S_HANDOFF;
                        end else begin
                            mac_idx <= mac_idx + 3'd1;
                            state   <= S_MACRD_OP;
                        end
                    end

                // net_stack owns m12_cs_n/m12_spi_start/m12_spi_tx from here,
                // until it asks for a re-initialisation. erevid stays frozen
                // at its last M1/M2 value; the LED and OLED continue showing
                // that snapshot rather than polling forever, since polling
                // would race net_stack for the bus.
                //
                // Recovery from a corrupt RX packet chain runs through here
                // rather than inside net_stack, because the only thing known
                // to bring the part back from an unknown state is the full
                // sequence this FSM already implements: pulse the hardware
                // reset line, clear ECON2.PWRSV, system reset, confirm
                // ESTAT.CLKRDY, then rewrite the whole M2 configuration.
                // Dropping eth_ready hands the SPI bus back automatically via
                // the mux above, and net_stack parks itself until it returns.
                S_HANDOFF:
                    if (net_reinit_req) begin
                        eth_ready  <= 1'b0;
                        m2_started <= 1'b0;    // let S_LATCH re-run the M2 config
                        m2_idx     <= 6'd0;
                        wait_cnt   <= 23'd0;
                        reinits    <= reinits + 16'd1;
                        state      <= S_HW_RESET;
                    end

                default: state <= S_HW_RESET;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // LEDs (active low)
    // ------------------------------------------------------------------
    assign led = ~key[0] ? ~erevid[7:3]     // button held: upper bits
                         : ~erevid[4:0];    // normal: lower 5 bits (0x06)

    // ------------------------------------------------------------------
    // 1.3" SSD1306 OLED status display
    //
    //   line 0   EP4CE6E22 ENC28J60
    //   line 1   EREVID 0xNN OK|BAD
    //   line 2   HOST A 192.168.1.60
    //   line 3   text typed locally, or received from the peer (M4)
    //
    // Line 3 shows whichever happened more recently: a line typed over the
    // serial port (msg_updated, also triggers net_stack to send it to the
    // peer as a UDP message) or one received from the peer (net_rx_updated).
    // See use_net_msg below.
    // ------------------------------------------------------------------
    // Build identifier, shown on the OLED as "BLD xxxx". Bump this whenever
    // you flash a build you need to tell apart from another one. Knowing at a
    // glance which image is on which board is worth more than it sounds:
    // several wrong conclusions during bring-up came from testing a node that
    // was quietly running an older bitstream.
    localparam [15:0] BUILD_ID = 16'h0006;

    localparam integer OCOLS = 21;

    // Static template; the runtime cells are patched in the case below.
    //
    //   line 0   HOST A 192.168.1.60
    //   line 1   EREVID 0x06 OK
    //   line 2   KEYS 0.2.   BLD 0001
    //   line 3   MSG <text typed over the serial port>
    reg [7:0] tmpl [0:OCOLS*4-1];
    integer   ti;
    initial begin
        for (ti = 0; ti < OCOLS*4; ti = ti + 1) tmpl[ti] = 8'h20;
        // line 0: "HOST A 192.168.1.6#"
        tmpl[ 0]="H"; tmpl[ 1]="O"; tmpl[ 2]="S"; tmpl[ 3]="T";
        tmpl[ 7]="1"; tmpl[ 8]="9"; tmpl[ 9]="2"; tmpl[10]=".";
        tmpl[11]="1"; tmpl[12]="6"; tmpl[13]="8"; tmpl[14]=".";
        tmpl[15]="1"; tmpl[16]="."; tmpl[17]="6";
        // line 1: "EREVID 0x## .."
        tmpl[21]="E"; tmpl[22]="R"; tmpl[23]="E"; tmpl[24]="V"; tmpl[25]="I";
        tmpl[26]="D"; tmpl[28]="0"; tmpl[29]="x";
        // line 2: "KEYS ...."
        tmpl[42]="K"; tmpl[43]="E"; tmpl[44]="Y"; tmpl[45]="S";
        // line 2, right half: "BLD xxxx" (cols 52-59; 60-62 stay blank)
        tmpl[52]="B"; tmpl[53]="L"; tmpl[54]="D";
        // line 3 is the received text, all 21 cells of it -- no prefix, so a
        // full-length serial message fits without being truncated.
    end

    function [7:0] hexdig(input [3:0] n);
        hexdig = (n < 4'd10) ? (8'h30 + n) : (8'h41 + n - 4'd10);
    endfunction

    wire erevid_ok = (erevid == 8'h06);

    // ------------------------------------------------------------------
    // Buttons and the serial console
    //
    // key[0..3] are the four user buttons. nrst (PIN_88, the RESET button) is
    // the design's reset, so it cannot also be read as a user button.
    // ------------------------------------------------------------------
    wire [3:0] keys, key_rise, key_fall;

    debounce #(.N(4), .CLK_HZ(50_000_000), .STABLE_MS(10)) u_deb (
        .clk(clk), .rst(rst),
        .btn_n(key),
        .pressed(keys), .rise(key_rise), .fall(key_fall)
    );

    wire keys_changed = |key_rise | |key_fall;

    wire [4:0] msg_addr;          // driven by the display writer below
    wire [7:0] msg_char;
    // msg_updated is declared near the top of the module -- see the comment there.

    // Declared here, ahead of u_con's instantiation below, so nothing forces
    // an implicit net: o_ready and oled_i2c_err are driven by u_oled further
    // down, oled_i2c_err_sticky is set in the display-writer block below.
    wire       o_ready;
    wire       oled_i2c_err;
    reg        oled_i2c_err_sticky;   // latched forever once seen; cleared only at reset

    uart_console #(.CLK_HZ(50_000_000), .BAUD(115200), .HOST_ID(HOST_ID)) u_con (
        .clk(clk), .rst(rst),
        .keys(keys), .keys_changed(keys_changed),
        .msg_rd_addr(msg_addr), .msg_rd_data(msg_char), .msg_updated(msg_updated),
        .tx_rd_addr(net_tx_rd_addr), .tx_rd_data(net_tx_rd_data),
        .oled_ready(o_ready), .oled_nack(oled_i2c_err_sticky),
        .eth_ready(eth_ready), .eth_econ1(econ1_rb),
        .net_frames(eth_frames_seen), .net_replies(eth_arp_replies),
        .net_eir(eth_last_eir), .net_estat(eth_last_estat),
        .net_arpreqs(eth_arp_reqs), .net_etype(eth_last_etype),
        .net_resyncs(eth_rx_resyncs),
        .build_id(BUILD_ID), .mac_rb(mac_rb), .mac_d(mac_d),
        .net_msgs(eth_msgs_rx),
        .net_polls(eth_polls), .net_pktcnt(eth_pktcnt),
        .net_tsvcount(eth_tsv_count), .net_tsvwire(eth_tsv_wire),
        .net_tsvs2(eth_tsv_s2), .net_tsvs3(eth_tsv_s3),
        .uart_rx_pin(uart_rx), .uart_tx_pin(uart_tx)
    );

    // Patch the dynamic cells as the template is streamed out.
    reg  [6:0] w_addr;
    reg  [7:0] w_char;
    reg        w_en;
    reg        w_done;
    reg        o_refresh;
    reg  [7:0] last_shown;
    reg        redraw_pending;
    // M4: which source currently feeds line 3 -- the last-typed local line,
    // or the last message received from the peer. Whichever happened more
    // recently wins; a locally-typed line always takes priority over a
    // stale received one arriving to be shown, since it's the user's own
    // action on this board.
    reg        use_net_msg;

    // Line 3 of the panel reads straight out of whichever buffer is active.
    // Both are the same 21-byte layout, addressed identically.
    assign msg_addr        = (w_addr >= 7'd63) ? (w_addr - 7'd63) : 5'd0;
    assign net_rx_rd_addr  = msg_addr;

    always @(posedge clk) begin
        if (rst) begin
            w_addr              <= 7'd0;
            w_en                <= 1'b0;
            w_done              <= 1'b0;
            o_refresh           <= 1'b0;
            last_shown          <= 8'hFF;
            redraw_pending      <= 1'b0;
            oled_i2c_err_sticky <= 1'b0;
            use_net_msg         <= 1'b0;
        end else begin
            if (net_rx_updated) use_net_msg <= 1'b1;
            if (msg_updated)    use_net_msg <= 1'b0;
            o_refresh <= 1'b0;
            if (oled_i2c_err) oled_i2c_err_sticky <= 1'b1;
            if (!w_done) begin
                w_en <= 1'b1;
                case (w_addr)
                    // line 0: host letter and last IP digit
                    7'd 5: w_char <= (HOST_ID == 8'd1) ? "A" : "B";
                    7'd18: w_char <= (HOST_ID == 8'd1) ? "0" : "1";
                    // line 1: EREVID readback
                    7'd30: w_char <= hexdig(erevid[7:4]);
                    7'd31: w_char <= hexdig(erevid[3:0]);
                    7'd33: w_char <= erevid_ok ? "O" : "B";
                    7'd34: w_char <= erevid_ok ? "K" : "A";
                    7'd35: w_char <= erevid_ok ? " " : "D";
                    // line 2: one character per button, its number or a dot
                    7'd47: w_char <= keys[0] ? "0" : ".";
                    7'd48: w_char <= keys[1] ? "1" : ".";
                    7'd49: w_char <= keys[2] ? "2" : ".";
                    7'd50: w_char <= keys[3] ? "3" : ".";
                    // line 2: build identifier, so the running image is
                    // identifiable from the panel alone
                    7'd56: w_char <= hexdig(BUILD_ID[15:12]);
                    7'd57: w_char <= hexdig(BUILD_ID[11:8]);
                    7'd58: w_char <= hexdig(BUILD_ID[7:4]);
                    7'd59: w_char <= hexdig(BUILD_ID[3:0]);
                    // line 3: the text typed locally, or received from the
                    // peer (M4) -- whichever happened more recently
                    default:
                        if (w_addr >= 7'd63) w_char <= use_net_msg ? net_rx_rd_data : msg_char;
                        else                 w_char <= tmpl[w_addr];
                endcase
                if (w_addr == OCOLS*4-1) begin
                    w_done    <= 1'b1;
                    o_refresh <= 1'b1;      // paint once the buffer is filled
                end else begin
                    w_addr <= w_addr + 7'd1;
                end
            end else begin
                w_en <= 1'b0;
                // Repaint on anything the panel shows changing: the EREVID
                // readback (so a loose SPI wire shows up here and not only on
                // the LEDs), a button, or a new line over the serial port.
                if (o_ready && ((erevid != last_shown) || keys_changed
                                || msg_updated || net_rx_updated || redraw_pending)) begin
                    o_refresh      <= 1'b1;
                    last_shown     <= erevid;
                    redraw_pending <= 1'b0;
                    w_addr         <= 7'd0;
                    w_done         <= 1'b0;
                end else if (keys_changed || msg_updated || net_rx_updated) begin
                    // A change arriving mid-repaint would otherwise be lost:
                    // a full refresh takes ~25 ms and o_ready is low throughout.
                    redraw_pending <= 1'b1;
                end
            end
        end
    end

    oled_ssd1306 #(.CLK_HZ(50_000_000)) u_oled (
        .clk(clk), .rst(rst),
        .txt_we(w_en), .txt_addr(w_addr), .txt_char(w_char),
        .refresh(o_refresh), .ready(o_ready), .i2c_err(oled_i2c_err),
        .oled_scl(oled_scl), .oled_sda(oled_sda)
    );

endmodule
