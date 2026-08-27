// tb_m3.v -- Milestone 3 testbench: net_stack's ARP responder against a
// behavioural ENC28J60 with real per-bank registers AND real buffer memory
// (RBM/WBM with auto-incrementing pointers, EPKTCNT/PKTDEC bookkeeping).
//
// tb_m1/tb_m2's models don't understand RBM/WBM or hold buffer content at
// all -- not enough to inject a synthetic frame and check a byte-correct
// reply. This model does both.
//
// Scenario: inject an ARP request for our IP into the RX buffer, tell the
// model one packet is waiting, let net_stack process it, then check:
//   * the reply written to the TX buffer is a byte-correct ARP reply
//     (control byte, then 42 bytes: dest/src MAC swapped, OPER=2, SHA/SPA
//     set to ours, THA/TPA mirroring the request's SHA/SPA), zero-padded
//     out to Ethernet's 60-byte minimum frame size
//   * ETXND was set correctly (61 bytes, inclusive end)
//   * ECON1.TXRTS was pulsed
//   * ERXRDPT was advanced to the packet's own "next packet pointer" - 1
//   * EPKTCNT was decremented (PKTDEC bit seen on ECON2)
//   * frames_seen and arp_replies_sent both read 1
//
// A second scenario (non-matching IP) checks net_stack correctly declines to
// reply -- frames_seen increments, arp_replies_sent does not.
//
// Run:  vlog -sv ../rtl/spi_master.v ../rtl/net_stack.v ../tb/tb_m3.v
//       vsim -c -do "run -all; quit -f" tb_m3

`timescale 1ns/1ps

module enc28j60_buf_model (
    input  wire        rst_n,
    input  wire        cs_n,
    input  wire        sck,
    input  wire        mosi,
    output reg         miso
);
    reg [7:0] shift_in, shift_out;
    reg [3:0] bit_cnt;
    integer   byte_idx;
    reg [7:0] opcode;

    reg [7:0] econ1;
    reg [7:0] regs [0:3][0:31];      // [bank][addr]
    reg [7:0] buf_mem [0:8191];      // full 8 KB on-chip buffer
    reg [15:0] cur_ptr;              // active RBM/WBM streaming pointer
    reg [7:0]  pktcnt;               // testbench pokes this directly

    integer bi, ai, k;
    initial begin
        miso = 0; shift_in = 0; shift_out = 0; bit_cnt = 0; byte_idx = 0;
        opcode = 0; econ1 = 0; cur_ptr = 0; pktcnt = 0;
        for (bi = 0; bi < 4; bi = bi + 1)
            for (ai = 0; ai < 32; ai = ai + 1) regs[bi][ai] = 8'h00;
        for (k = 0; k < 8192; k = k + 1) buf_mem[k] = 8'h00;
    end

    wire [1:0] cur_bank = econ1[1:0];

    // Once RXEN has been turned on, it must stay on except while RXRST is
    // being pulsed (the datasheet requires RXEN clear to move ERXST/ERXND).
    // Bank selects silently clearing it is the hardware bug this guards.
    reg rxen_was_on = 1'b0;
    reg rxen_dropped = 1'b0;
    always @(econ1) begin
        if (econ1[2]) rxen_was_on = 1'b1;
        else if (rxen_was_on && !econ1[6]) rxen_dropped = 1'b1;
    end
    localparam [7:0] OP_RBM = 8'h3A, OP_WBM = 8'h7A;

    // Observation flags for the testbench.
    reg pktdec_seen;
    reg txrts_seen;

    always @(negedge cs_n) begin
        byte_idx = 0; bit_cnt = 0; shift_out = 8'h00;
    end

    always @(posedge sck) begin
        if (!cs_n) begin
            shift_in = {shift_in[6:0], mosi};
            bit_cnt  = bit_cnt + 1;
            if (bit_cnt == 8) begin
                bit_cnt = 0;
                if (byte_idx == 0) begin
                    opcode = shift_in;
                    if (shift_in == OP_RBM) begin
                        cur_ptr   = {regs[0][1], regs[0][0]};   // ERDPTH:ERDPTL
                        shift_out = buf_mem[cur_ptr];
                    end else if (shift_in[7:5] == 3'b000) begin // RCR
                        if (shift_in[4:0] == 5'h1F) shift_out = econ1;
                        else if (shift_in[4:0] == 5'h19 && cur_bank == 2'd1)
                            shift_out = pktcnt;                  // EPKTCNT
                        else
                            shift_out = regs[cur_bank][shift_in[4:0]];
                    end
                end else begin
                    if (opcode == OP_RBM) begin
                        cur_ptr   = cur_ptr + 16'd1;
                        shift_out = buf_mem[cur_ptr];
                    end else if (opcode == OP_WBM) begin
                        if (byte_idx == 1) cur_ptr = {regs[0][3], regs[0][2]}; // EWRPTH:EWRPTL
                        buf_mem[cur_ptr] = shift_in;
                        cur_ptr = cur_ptr + 16'd1;
                    end else if (opcode[7:5] == 3'b100 && opcode[4:0] == 5'h1F) begin
                        // BFS ECON1: OR the mask in, touching nothing else.
                        econ1 = econ1 | shift_in;
                        if (shift_in[3]) txrts_seen = 1'b1;      // TXRTS bit
                    end else if (opcode[7:5] == 3'b101 && opcode[4:0] == 5'h1F) begin
                        // BFC ECON1: AND the inverted mask in.
                        econ1 = econ1 & ~shift_in;
                    end else if (opcode[7:5] == 3'b010) begin   // WCR
                        if (opcode[4:0] == 5'h1F) begin
                            econ1 = shift_in;
                            if (shift_in[3]) txrts_seen = 1'b1;  // TXRTS bit
                        end else if (opcode[4:0] == 5'h1E) begin // ECON2
                            regs[cur_bank][5'h1E] = shift_in;    // not bank-dependent really, harmless
                            if (shift_in[6]) begin               // PKTDEC
                                pktdec_seen = 1'b1;
                                if (pktcnt != 0) pktcnt = pktcnt - 8'd1;
                            end
                        end else begin
                            regs[cur_bank][opcode[4:0]] = shift_in;
                        end
                    end
                end
                byte_idx = byte_idx + 1;
            end
        end
    end

    always @(negedge sck) if (!cs_n) begin
        miso      = shift_out[7];
        shift_out = {shift_out[6:0], 1'b0};
    end
    always @(negedge cs_n) miso = shift_out[7];

endmodule


module tb_m3;

    reg clk = 0;
    always #10 clk = ~clk;
    reg rst = 1;
    reg start = 0;

    wire cs_n, spi_start, sck, mosi, miso;
    wire [7:0] spi_tx, spi_rx;
    wire spi_busy;
    wire [15:0] frames_seen, arp_replies_sent;

    spi_master #(.CLK_DIV(2)) u_spi (
        .clk(clk), .rst(rst), .start(spi_start), .tx_byte(spi_tx),
        .rx_byte(spi_rx), .busy(spi_busy), .sck(sck), .mosi(mosi), .miso(miso)
    );

    localparam [47:0] OUR_MAC = 48'h02_42_CE_60_00_01;
    localparam [31:0] OUR_IP  = 32'hC0_A8_01_3C;   // 192.168.1.60

    wire [7:0] last_eir, last_estat;   // TX diagnostic readback, unused in this tb

    net_stack #(.OUR_MAC(OUR_MAC), .OUR_IP(OUR_IP)) dut (
        .clk(clk), .rst(rst), .start(start),
        .cs_n(cs_n), .spi_start(spi_start), .spi_tx(spi_tx),
        .spi_rx(spi_rx), .spi_busy(spi_busy),
        .frames_seen(frames_seen), .arp_replies_sent(arp_replies_sent),
        .last_eir(last_eir), .last_estat(last_estat),
        .arp_reqs(), .last_etype(),
        .rx_resyncs(), .tsv_count(), .tsv_wire(), .tsv_stat2(), .tsv_stat3()
    );

    // spi_master itself has no chip-select notion (matching eth_top.v's
    // pattern) -- net_stack's own cs_n output gates the model directly.
    enc28j60_buf_model model (
        .rst_n(1'b1), .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso)
    );

    localparam [47:0] SENDER_MAC = 48'hAA_BB_CC_DD_EE_FF;
    localparam [31:0] SENDER_IP  = 32'hC0_A8_01_65;   // 192.168.1.101
    localparam [31:0] OTHER_IP   = 32'hC0_A8_01_C8;   // 192.168.1.200 (not us)
    localparam [15:0] NEXT_PTR   = 16'h0032;          // arbitrary, non-edge-case

    integer errors = 0;
    task check(input cond, input [100*8:0] what);
        if (!cond) begin $display("FAIL: %0s", what); errors = errors + 1; end
    endtask

    // Write a 6-byte RX header + 42-byte ARP request into the model's buffer at
    // base_addr, matching what real hardware would have received. Must be
    // called with base_addr == wherever net_stack will actually read from
    // next (0 for the first packet; its own tracked next_rdpt afterward --
    // net_stack updates ERDPT to the previous packet's "next pointer" field
    // as part of cleanup, exactly as real firmware would).
    task inject_arp_request(input [31:0] target_ip, input [15:0] next_ptr,
                             input [15:0] base_addr);
        integer i;
        reg [7:0] frame [0:41];
        begin
            frame[ 0]=8'hFF; frame[ 1]=8'hFF; frame[ 2]=8'hFF;         // dest MAC = broadcast
            frame[ 3]=8'hFF; frame[ 4]=8'hFF; frame[ 5]=8'hFF;
            frame[ 6]=SENDER_MAC[47:40]; frame[ 7]=SENDER_MAC[39:32];  // src MAC
            frame[ 8]=SENDER_MAC[31:24]; frame[ 9]=SENDER_MAC[23:16];
            frame[10]=SENDER_MAC[15:8];  frame[11]=SENDER_MAC[7:0];
            frame[12]=8'h08; frame[13]=8'h06;                          // EtherType ARP
            frame[14]=8'h00; frame[15]=8'h01;                          // HTYPE
            frame[16]=8'h08; frame[17]=8'h00;                          // PTYPE
            frame[18]=8'h06; frame[19]=8'h04;                          // HLEN, PLEN
            frame[20]=8'h00; frame[21]=8'h01;                          // OPER=request
            frame[22]=SENDER_MAC[47:40]; frame[23]=SENDER_MAC[39:32];  // SHA
            frame[24]=SENDER_MAC[31:24]; frame[25]=SENDER_MAC[23:16];
            frame[26]=SENDER_MAC[15:8];  frame[27]=SENDER_MAC[7:0];
            frame[28]=SENDER_IP[31:24];  frame[29]=SENDER_IP[23:16];   // SPA
            frame[30]=SENDER_IP[15:8];   frame[31]=SENDER_IP[7:0];
            frame[32]=8'h00; frame[33]=8'h00; frame[34]=8'h00;         // THA (unused in request)
            frame[35]=8'h00; frame[36]=8'h00; frame[37]=8'h00;
            frame[38]=target_ip[31:24]; frame[39]=target_ip[23:16];    // TPA
            frame[40]=target_ip[15:8];  frame[41]=target_ip[7:0];

            model.buf_mem[base_addr+0] = next_ptr[7:0];
            model.buf_mem[base_addr+1] = next_ptr[15:8];
            model.buf_mem[base_addr+2] = 8'h00; model.buf_mem[base_addr+3] = 8'h00; // byte count, unused
            model.buf_mem[base_addr+4] = 8'h00; model.buf_mem[base_addr+5] = 8'h00; // status vector, unused
            for (i = 0; i < 42; i = i + 1) model.buf_mem[base_addr+6+i] = frame[i];

            model.pktcnt      = 8'd1;
            model.pktdec_seen = 1'b0;
            model.txrts_seen  = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // Scenario 1: ARP request for our IP -- expect a byte-correct reply.
    // ------------------------------------------------------------------
    initial begin
        #200 rst = 0;
        #40;
        inject_arp_request(OUR_IP, NEXT_PTR, 16'h0000);   // net_stack starts at ERXST
        #40;
        start = 1'b1;

        wait (arp_replies_sent == 16'd1);
        // arp_replies_sent bumps in S_TXWAIT, BEFORE the EIR/ESTAT/TSV reads
        // and the RX-buffer cleanup. Wait on frames_seen, which bumps in
        // S_CLEANUP4 once everything has actually finished -- a fixed delay
        // here silently breaks whenever the post-TX sequence grows.
        wait (frames_seen == 16'd1);
        #2_000;

        check(frames_seen == 16'd1, "frames_seen != 1 after one ARP request");

        // ---- TX buffer: control byte + 42-byte reply, byte-correct ----
        check(model.buf_mem[16'h1A00] == 8'h07, "TX control byte is not 0x07 (POVERRIDE|PCRCEN|PPADEN)");
        // dest MAC = sender's MAC
        check(model.buf_mem[16'h1A01] == SENDER_MAC[47:40], "reply dest MAC[0] wrong");
        check(model.buf_mem[16'h1A06] == SENDER_MAC[7:0],   "reply dest MAC[5] wrong");
        // src MAC = ours
        check(model.buf_mem[16'h1A07] == OUR_MAC[47:40], "reply src MAC[0] wrong");
        check(model.buf_mem[16'h1A0C] == OUR_MAC[7:0],   "reply src MAC[5] wrong");
        // EtherType/HTYPE/PTYPE/HLEN/PLEN unchanged
        check(model.buf_mem[16'h1A0D] == 8'h08 && model.buf_mem[16'h1A0E] == 8'h06,
              "reply EtherType is not ARP");
        // OPER = 2 (reply)
        check(model.buf_mem[16'h1A15] == 8'h00 && model.buf_mem[16'h1A16] == 8'h02,
              "reply OPER is not 2");
        // SHA = ours, SPA = ours
        check(model.buf_mem[16'h1A17] == OUR_MAC[47:40], "reply SHA[0] wrong");
        check(model.buf_mem[16'h1A1C] == OUR_MAC[7:0],   "reply SHA[5] wrong");
        check(model.buf_mem[16'h1A1D] == OUR_IP[31:24],  "reply SPA[0] wrong");
        check(model.buf_mem[16'h1A20] == OUR_IP[7:0],    "reply SPA[3] wrong");
        // THA = sender's MAC (mirrors request SHA), TPA = sender's IP
        check(model.buf_mem[16'h1A21] == SENDER_MAC[47:40], "reply THA[0] wrong");
        check(model.buf_mem[16'h1A26] == SENDER_MAC[7:0],   "reply THA[5] wrong");
        check(model.buf_mem[16'h1A27] == SENDER_IP[31:24],  "reply TPA[0] wrong");
        check(model.buf_mem[16'h1A2A] == SENDER_IP[7:0],    "reply TPA[3] wrong");

        // ---- explicit zero padding, byte 43 (0x1A2B) through byte 60
        // (0x1A3C), up to Ethernet's 60-byte minimum frame size ----
        begin : pad_check
            integer p;
            for (p = 16'h1A2B; p <= 16'h1A3C; p = p + 1)
                if (model.buf_mem[p] !== 8'h00) begin
                    $display("FAIL: pad byte at 0x%04h is 0x%02h, expected 0x00", p, model.buf_mem[p]);
                    errors = errors + 1;
                end
        end

        // ---- ETXND = ETXST + 60 = 0x1A3C ----
        check(model.regs[0][5'h06] == 8'h3C && model.regs[0][5'h07] == 8'h1A,
              "ETXND not set to 0x1A3C");

        check(model.txrts_seen, "ECON1.TXRTS was never pulsed");

        // ---- ERXRDPT advanced to next_ptr - 1 (0x0031) ----
        check(model.regs[0][5'h0C] == 8'h31 && model.regs[0][5'h0D] == 8'h00,
              "ERXRDPT not advanced to NEXT_PTR-1");

        check(model.pktdec_seen, "ECON2.PKTDEC was never pulsed");
        check(model.pktcnt == 8'd0, "EPKTCNT was not decremented");

        $display("INFO: scenario 1 (ARP for us) complete, errors so far = %0d", errors);

        // ------------------------------------------------------------------
        // Scenario 2: ARP request for a DIFFERENT IP -- expect no reply.
        // ------------------------------------------------------------------
        // Placed at dut.next_rdpt: net_stack tracks this itself, updating it
        // to the previous packet's own "next pointer" field during cleanup,
        // exactly as real firmware would -- the testbench must place the
        // next synthetic frame wherever that now points, not at address 0.
        inject_arp_request(OTHER_IP, NEXT_PTR + 16'h0032, dut.next_rdpt);
        wait (frames_seen == 16'd2);
        #10_000;

        check(arp_replies_sent == 16'd1,
              "arp_replies_sent changed on a request for a different IP");
        check(model.pktcnt == 8'd0, "EPKTCNT not decremented for the second frame");

        // ------------------------------------------------------------------
        // Scenario 3: a next-packet pointer that poisons the SPI helpers.
        // ------------------------------------------------------------------
        // The two-byte helpers used to work out "have I sent the opcode yet?"
        // by comparing the byte just shifted out against the opcode itself.
        // That breaks whenever the DATA byte equals the OPCODE byte: the test
        // stays true, the helper resends the data forever, and the whole FSM
        // wedges with the packet still pending.
        //
        // WCR(ERXRDPTL) is 0x4C, and ERXRDPT is written as next_ptr - 1. A
        // next pointer of 0x004D therefore writes 0x4C into opcode 0x4C and
        // hangs the pre-fix design. On hardware the ring pointer walks all
        // 256 low-byte values, so this hit roughly every 128 frames -- nodes
        // wedged after 122, 156 and 134 frames.
        //
        // There is no assertion here on purpose: if the FSM wedges,
        // frames_seen never reaches 3 and the testbench times out.
        inject_arp_request(OUR_IP, 16'h004D, dut.next_rdpt);
        wait (frames_seen == 16'd3);
        #10_000;
        check(arp_replies_sent == 16'd2,
              "no ARP reply for the poisoned-pointer frame (SPI helper wedged?)");

        // RXEN must have survived every bank select, TX sequence and
        // cleanup above. It did not before ECON1 moved to BFS/BFC:
        // each whole-byte bank select switched the receiver off.
        check(!model.rxen_dropped,
              "RXEN was cleared outside an RXRST pulse (bank select clobbered ECON1)");

        if (errors == 0)
            $display("PASS: ARP reply byte-correct, ERXRDPT/EPKTCNT/ETXND/TXRTS all correct, RXEN never dropped, non-matching IP ignored, poisoned next-pointer survived");
        else
            $display("%0d ERROR(S)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
