// tb_m4.v -- Milestone 4 testbench: net_stack's UDP message send/receive
// against a behavioural ENC28J60 with real per-bank registers AND real
// buffer memory (same model as tb_m3.v).
//
// Two scenarios:
//   1. RECEIVE -- inject a synthetic UDP datagram (dest IP = OUR_IP, dest
//      port = 1234) addressed to us, check net_stack captures the 21-byte
//      payload byte-correct into its rx_rd_addr/rx_rd_data port, pulses
//      rx_updated exactly once, generates NO reply (arp_replies_sent stays
//      0), and still completes the normal RX-buffer cleanup (frames_seen
//      increments, EPKTCNT decrements).
//   2. SEND -- drive send_req (simulating uart_console's msg_updated) with
//      a 21-byte message staged on tx_rd_addr/tx_rd_data, check the TX
//      buffer holds a byte-correct Ethernet+IP+UDP frame: fixed header
//      fields, the IP header checksum matching an independently computed
//      reference value, and the payload matching what was staged. Also
//      checks ETXND and that ECON1.TXRTS was pulsed.
//
// Run:  vlog -sv ../rtl/spi_master.v ../rtl/net_stack.v ../tb/tb_m4.v
//       vsim -c -do "run -all; quit -f" tb_m4

`timescale 1ns/1ps

module enc28j60_buf_model4 (
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
                            regs[cur_bank][5'h1E] = shift_in;
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


module tb_m4;

    reg clk = 0;
    always #10 clk = ~clk;
    reg rst = 1;
    reg start = 0;

    wire cs_n, spi_start, sck, mosi, miso;
    wire [7:0] spi_tx, spi_rx;
    wire spi_busy;
    wire [15:0] frames_seen, arp_replies_sent;
    wire [7:0] last_eir, last_estat;

    spi_master #(.CLK_DIV(2)) u_spi (
        .clk(clk), .rst(rst), .start(spi_start), .tx_byte(spi_tx),
        .rx_byte(spi_rx), .busy(spi_busy), .sck(sck), .mosi(mosi), .miso(miso)
    );

    localparam [7:0]  HOST_ID = 8'd1;
    localparam [47:0] OUR_MAC = 48'h02_42_CE_60_00_01;
    localparam [31:0] OUR_IP  = 32'hC0_A8_01_3C;   // 192.168.1.60
    localparam [47:0] PEER_MAC = 48'h02_42_CE_60_00_02;
    localparam [31:0] PEER_IP  = 32'hC0_A8_01_3D;  // 192.168.1.61

    // M4 TX staging (stands in for uart_console's message buffer) and RX
    // readout port.
    reg  [7:0] tb_tx_msg [0:20];
    wire [4:0] tx_rd_addr;
    wire [7:0] tx_rd_data;
    reg        send_req;
    assign tx_rd_data = tb_tx_msg[tx_rd_addr];

    wire [4:0] rx_rd_addr_dut;
    wire [7:0] rx_rd_data;
    wire       rx_updated;
    wire [15:0] icmp_replies;   // declared before the DUT: a port
                                // connection to an undeclared name would
                                // otherwise create a 1-bit implicit net
    reg  [4:0] rx_rd_addr;
    assign rx_rd_addr_dut = rx_rd_addr;

    net_stack #(.HOST_ID(HOST_ID), .OUR_MAC(OUR_MAC), .OUR_IP(OUR_IP)) dut (
        .clk(clk), .rst(rst), .start(start),
        .cs_n(cs_n), .spi_start(spi_start), .spi_tx(spi_tx),
        .spi_rx(spi_rx), .spi_busy(spi_busy),
        .tx_rd_addr(tx_rd_addr), .tx_rd_data(tx_rd_data), .send_req(send_req),
        .force_reinit(1'b0),
        .icmp_replies(icmp_replies),
        .rx_rd_addr(rx_rd_addr_dut), .rx_rd_data(rx_rd_data), .rx_updated(rx_updated),
        .frames_seen(frames_seen), .arp_replies_sent(arp_replies_sent),
        .last_eir(last_eir), .last_estat(last_estat),
        .arp_reqs(), .last_etype(),
        .rx_resyncs(), .tsv_count(), .tsv_wire(), .tsv_stat2(), .tsv_stat3()
    );

    enc28j60_buf_model4 model (
        .rst_n(1'b1), .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso)
    );

    integer errors = 0;
    reg  [15:0] icmp_before;
    reg         icmp_ok;
    reg  [31:0] chk_sum;
    integer     kk;
    task check(input cond, input [120*8:0] what);
        if (!cond) begin $display("FAIL: %0s", what); errors = errors + 1; end
    endtask

    // Reference IP header checksum, computed independently of net_stack's
    // own ip_checksum function (same algorithm, separately transcribed --
    // catches a mistake in one from propagating into a matching mistake in
    // the other).
    function [15:0] ref_checksum;
        input [15:0] w0, w1, w2, w3, w4, w6, w7, w8, w9;
        reg [31:0] s;
        begin
            s = w0 + w1 + w2 + w3 + w4 + w6 + w7 + w8 + w9;
            s = s[15:0] + s[31:16];
            s = s[15:0] + s[31:16];
            ref_checksum = ~s[15:0];
        end
    endfunction

    // IP header as HOST A (dut) sends it: dest = PEER_IP, src = OUR_IP.
    localparam [15:0] EXP_CHECKSUM = ref_checksum(
        16'h4500, 16'd49, 16'h0000, 16'h0000, {8'd64, 8'd17},
        OUR_IP[31:16], OUR_IP[15:0], PEER_IP[31:16], PEER_IP[15:0]
    );

    // Inject a synthetic UDP datagram addressed to OUR_IP:1234, matching
    // what real hardware would have delivered into the RX buffer.
    // An ICMP echo request with a 32-byte payload -- exactly what a default
    // Windows `ping` sends, which is the case that has to work.
    task inject_icmp_echo(input [15:0] next_ptr, input [15:0] base_addr,
                          input [31:0] dst_ip, input [15:0] ident,
                          input [15:0] seqno);
        integer i;
        reg [7:0]  frame [0:73];
        reg [31:0] sum;
        begin
            frame[ 0]=OUR_MAC[47:40]; frame[ 1]=OUR_MAC[39:32];
            frame[ 2]=OUR_MAC[31:24]; frame[ 3]=OUR_MAC[23:16];
            frame[ 4]=OUR_MAC[15:8];  frame[ 5]=OUR_MAC[7:0];
            frame[ 6]=PEER_MAC[47:40]; frame[ 7]=PEER_MAC[39:32];
            frame[ 8]=PEER_MAC[31:24]; frame[ 9]=PEER_MAC[23:16];
            frame[10]=PEER_MAC[15:8];  frame[11]=PEER_MAC[7:0];
            frame[12]=8'h08; frame[13]=8'h00;
            frame[14]=8'h45; frame[15]=8'h00;
            frame[16]=8'h00; frame[17]=8'd60;          // total length 20 + 40
            frame[18]=8'h00; frame[19]=8'h00;
            frame[20]=8'h00; frame[21]=8'h00;
            frame[22]=8'd64;
            frame[23]=8'd1;                            // protocol = ICMP
            frame[24]=8'h00; frame[25]=8'h00;
            frame[26]=PEER_IP[31:24]; frame[27]=PEER_IP[23:16];
            frame[28]=PEER_IP[15:8];  frame[29]=PEER_IP[7:0];
            frame[30]=dst_ip[31:24];  frame[31]=dst_ip[23:16];
            frame[32]=dst_ip[15:8];   frame[33]=dst_ip[7:0];
            frame[34]=8'd8;                            // type = echo request
            frame[35]=8'd0;                            // code
            frame[36]=8'h00; frame[37]=8'h00;          // checksum, filled below
            frame[38]=ident[15:8];  frame[39]=ident[7:0];
            frame[40]=seqno[15:8];  frame[41]=seqno[7:0];
            for (i = 0; i < 32; i = i + 1) frame[42+i] = 8'h61 + i[7:0];   // 'a'...

            // Real ICMP checksum over the 40-byte message, so the design's
            // incremental update has something valid to update from.
            sum = 0;
            for (i = 34; i < 74; i = i + 2)
                sum = sum + {frame[i], frame[i+1]};
            sum = (sum & 32'h0000FFFF) + (sum >> 16);
            sum = (sum & 32'h0000FFFF) + (sum >> 16);
            frame[36] = ~sum[15:8];
            frame[37] = ~sum[7:0];

            model.buf_mem[base_addr+0] = next_ptr[7:0];
            model.buf_mem[base_addr+1] = next_ptr[15:8];
            model.buf_mem[base_addr+2] = 8'h00; model.buf_mem[base_addr+3] = 8'h00;
            model.buf_mem[base_addr+4] = 8'h00; model.buf_mem[base_addr+5] = 8'h00;
            for (i = 0; i < 74; i = i + 1) model.buf_mem[base_addr+6+i] = frame[i];
            model.pktcnt = 8'd1;
        end
    endtask

    task inject_udp_message(input [15:0] next_ptr, input [15:0] base_addr,
                            input [31:0] dst_ip);
        integer i;
        reg [7:0] frame [0:62];
        reg [7:0] rx_payload [0:20];
        begin
            rx_payload[ 0]="H"; rx_payload[ 1]="I"; rx_payload[ 2]=" ";
            rx_payload[ 3]="F"; rx_payload[ 4]="R"; rx_payload[ 5]="O";
            rx_payload[ 6]="M"; rx_payload[ 7]=" "; rx_payload[ 8]="B";
            rx_payload[ 9]=8'h20; rx_payload[10]=8'h20; rx_payload[11]=8'h20;
            rx_payload[12]=8'h20; rx_payload[13]=8'h20; rx_payload[14]=8'h20;
            rx_payload[15]=8'h20; rx_payload[16]=8'h20; rx_payload[17]=8'h20;
            rx_payload[18]=8'h20; rx_payload[19]=8'h20; rx_payload[20]=8'h20;

            frame[ 0]=OUR_MAC[47:40]; frame[ 1]=OUR_MAC[39:32];   // dest MAC (unchecked)
            frame[ 2]=OUR_MAC[31:24]; frame[ 3]=OUR_MAC[23:16];
            frame[ 4]=OUR_MAC[15:8];  frame[ 5]=OUR_MAC[7:0];
            frame[ 6]=PEER_MAC[47:40]; frame[ 7]=PEER_MAC[39:32]; // src MAC
            frame[ 8]=PEER_MAC[31:24]; frame[ 9]=PEER_MAC[23:16];
            frame[10]=PEER_MAC[15:8];  frame[11]=PEER_MAC[7:0];
            frame[12]=8'h08; frame[13]=8'h00;                     // EtherType IPv4
            frame[14]=8'h45; frame[15]=8'h00;                     // ver/IHL, TOS
            frame[16]=8'h00; frame[17]=8'd49;                     // total length
            frame[18]=8'h00; frame[19]=8'h00;                     // ID
            frame[20]=8'h00; frame[21]=8'h00;                     // flags/frag
            frame[22]=8'd64;                                      // TTL
            frame[23]=8'd17;                                      // protocol = UDP
            frame[24]=8'h00; frame[25]=8'h00;                     // header checksum (unchecked by dut)
            frame[26]=PEER_IP[31:24]; frame[27]=PEER_IP[23:16];   // source IP
            frame[28]=PEER_IP[15:8];  frame[29]=PEER_IP[7:0];
            frame[30]=dst_ip[31:24];  frame[31]=dst_ip[23:16];    // dest IP
            frame[32]=dst_ip[15:8];   frame[33]=dst_ip[7:0];
            frame[34]=8'h04; frame[35]=8'hD2;                     // UDP src port
            frame[36]=8'h04; frame[37]=8'hD2;                     // UDP dst port = 1234
            frame[38]=8'h00; frame[39]=8'd29;                     // UDP length
            frame[40]=8'h00; frame[41]=8'h00;                     // UDP checksum (unused)
            for (i = 0; i < 21; i = i + 1) frame[42+i] = rx_payload[i];

            model.buf_mem[base_addr+0] = next_ptr[7:0];
            model.buf_mem[base_addr+1] = next_ptr[15:8];
            model.buf_mem[base_addr+2] = 8'h00; model.buf_mem[base_addr+3] = 8'h00;
            model.buf_mem[base_addr+4] = 8'h00; model.buf_mem[base_addr+5] = 8'h00;
            for (i = 0; i < 63; i = i + 1) model.buf_mem[base_addr+6+i] = frame[i];

            model.pktcnt      = 8'd1;
            model.pktdec_seen = 1'b0;
        end
    endtask

    initial begin
        #200 rst = 0;
        #40;

        // ------------------------------------------------------------
        // Scenario 1: RECEIVE a UDP message addressed to us.
        // ------------------------------------------------------------
        inject_udp_message(16'h0032, 16'h0000, OUR_IP);
        #40;
        start = 1'b1;

        wait (rx_updated == 1'b1);
        // rx_updated pulses in S_CLEANUP0, before the RX-buffer cleanup runs.
        // frames_seen bumps in S_CLEANUP4, once it is genuinely done.
        wait (frames_seen == 16'd1);
        #2_000;

        check(frames_seen == 16'd1, "frames_seen != 1 after the UDP message");
        check(arp_replies_sent == 16'd0, "a UDP message must never trigger an ARP reply");
        check(model.pktdec_seen, "ECON2.PKTDEC was never pulsed for the UDP message");
        check(model.pktcnt == 8'd0, "EPKTCNT was not decremented for the UDP message");

        begin : rx_check
            integer i;
            reg [7:0] want [0:20];
            want[ 0]="H"; want[ 1]="I"; want[ 2]=" "; want[ 3]="F"; want[ 4]="R";
            want[ 5]="O"; want[ 6]="M"; want[ 7]=" "; want[ 8]="B";
            for (i = 9; i < 21; i = i + 1) want[i] = 8'h20;
            for (i = 0; i < 21; i = i + 1) begin
                rx_rd_addr = i[4:0];
                #1;
                if (rx_rd_data !== want[i]) begin
                    $display("FAIL: rx payload byte %0d is 0x%02h, expected 0x%02h", i, rx_rd_data, want[i]);
                    errors = errors + 1;
                end
            end
        end

        $display("INFO: scenario 1 (UDP receive) complete, errors so far = %0d", errors);

        // ------------------------------------------------------------
        // Scenario 2: SEND the staged message as a UDP datagram.
        // ------------------------------------------------------------
        tb_tx_msg[ 0]="S"; tb_tx_msg[ 1]="E"; tb_tx_msg[ 2]="N"; tb_tx_msg[ 3]="T";
        tb_tx_msg[ 4]=" "; tb_tx_msg[ 5]="O"; tb_tx_msg[ 6]="K";
        tb_tx_msg[ 7]=8'h20; tb_tx_msg[ 8]=8'h20; tb_tx_msg[ 9]=8'h20; tb_tx_msg[10]=8'h20;
        tb_tx_msg[11]=8'h20; tb_tx_msg[12]=8'h20; tb_tx_msg[13]=8'h20; tb_tx_msg[14]=8'h20;
        tb_tx_msg[15]=8'h20; tb_tx_msg[16]=8'h20; tb_tx_msg[17]=8'h20; tb_tx_msg[18]=8'h20;
        tb_tx_msg[19]=8'h20; tb_tx_msg[20]=8'h20;

        model.txrts_seen = 1'b0;
        @(posedge clk);
        send_req = 1'b1;
        @(posedge clk);
        send_req = 1'b0;

        wait (dut.send_pending == 1'b1);
        wait (dut.send_pending == 1'b0);
        #10_000;

        // ---- fixed header, byte-correct ----
        check(model.buf_mem[16'h1A00] == 8'h07, "TX control byte is not 0x07 (POVERRIDE|PCRCEN|PPADEN)");
        check(model.buf_mem[16'h1A01] == PEER_MAC[47:40], "dest MAC[0] wrong");
        check(model.buf_mem[16'h1A06] == PEER_MAC[7:0],   "dest MAC[5] wrong");
        check(model.buf_mem[16'h1A07] == OUR_MAC[47:40],  "src MAC[0] wrong");
        check(model.buf_mem[16'h1A0C] == OUR_MAC[7:0],    "src MAC[5] wrong");
        check(model.buf_mem[16'h1A0D] == 8'h08 && model.buf_mem[16'h1A0E] == 8'h00,
              "EtherType is not IPv4 (0x0800)");
        check(model.buf_mem[16'h1A0F] == 8'h45, "IP version/IHL is not 0x45");
        check(model.buf_mem[16'h1A11] == 8'h00 && model.buf_mem[16'h1A12] == 8'd49,
              "IP total length is not 49");
        check(model.buf_mem[16'h1A17] == 8'd64, "TTL is not 64");
        check(model.buf_mem[16'h1A18] == 8'd17, "protocol is not UDP (17)");
        check({model.buf_mem[16'h1A19], model.buf_mem[16'h1A1A]} == EXP_CHECKSUM,
              "IP header checksum does not match the independently-computed reference");
        check(model.buf_mem[16'h1A1B] == OUR_IP[31:24], "source IP[0] wrong");
        check(model.buf_mem[16'h1A1E] == OUR_IP[7:0],   "source IP[3] wrong");
        check(model.buf_mem[16'h1A1F] == PEER_IP[31:24], "dest IP[0] wrong");
        check(model.buf_mem[16'h1A22] == PEER_IP[7:0],   "dest IP[3] wrong");
        check(model.buf_mem[16'h1A25] == 8'h04 && model.buf_mem[16'h1A26] == 8'hD2,
              "UDP dst port is not 1234");
        check(model.buf_mem[16'h1A27] == 8'h00 && model.buf_mem[16'h1A28] == 8'd29,
              "UDP length is not 29");

        // ---- payload, byte-correct ----
        begin : tx_check
            integer i;
            for (i = 0; i < 21; i = i + 1)
                if (model.buf_mem[16'h1A2B + i] !== tb_tx_msg[i]) begin
                    $display("FAIL: tx payload byte %0d is 0x%02h, expected 0x%02h",
                             i, model.buf_mem[16'h1A2B + i], tb_tx_msg[i]);
                    errors = errors + 1;
                end
        end

        // ---- ETXND = ETXST + 63 = 0x1A3F ----
        check(model.regs[0][5'h06] == 8'h3F && model.regs[0][5'h07] == 8'h1A,
              "ETXND not set to 0x1A3F");
        check(model.txrts_seen, "ECON1.TXRTS was never pulsed for the sent message");

        $display("INFO: scenario 2 (UDP send) complete, errors so far = %0d", errors);

        // ------------------------------------------------------------
        // Scenario 3: a BROADCAST UDP message must also be accepted.
        // This is what lets a PC drive the OLED while the transmit path
        // is still under investigation -- receive is known good on
        // hardware, so broadcast needs no transmission from the board.
        // ------------------------------------------------------------
        begin : bcast
            integer i;
            reg [7:0] want [0:20];
            inject_udp_message(16'h0096, dut.next_rdpt, 32'hC0_A8_01_FF);
            wait (rx_updated == 1'b1);
            wait (frames_seen == 16'd2);
            #2_000;
            check(arp_replies_sent == 16'd0, "a broadcast UDP must not trigger an ARP reply");
            want[0]="H"; want[1]="I"; want[2]=" "; want[3]="F"; want[4]="R";
            want[5]="O"; want[6]="M"; want[7]=" "; want[8]="B";
            for (i = 9; i < 21; i = i + 1) want[i] = 8'h20;
            for (i = 0; i < 21; i = i + 1) begin
                rx_rd_addr = i[4:0];
                #1;
                if (rx_rd_data !== want[i]) begin
                    $display("FAIL: broadcast payload byte %0d is 0x%02h, expected 0x%02h",
                             i, rx_rd_data, want[i]);
                    errors = errors + 1;
                end
            end
        end
        // Two messages accepted: the unicast in scenario 1 and the broadcast
        // in scenario 3. rx_updated is a one-cycle pulse, so without this
        // counter nothing outside the OLED could tell whether a message was
        // actually accepted -- which made board-to-board messaging impossible
        // to verify without looking at the panel.
        check(dut.msgs_rx == 16'd2,
              "msgs_rx did not count both accepted messages");

        $display("INFO: scenario 3 (broadcast UDP receive) complete, errors so far = %0d", errors);

        // ------------------------------------------------------------------
        // Scenario 4: ICMP echo request -> byte-correct echo reply.
        // ------------------------------------------------------------------
        // This is what makes `ping` actually succeed rather than resolving ARP
        // and timing out. Everything from the identifier onward has to come
        // back unchanged -- the sender compares it -- and both checksums have
        // to be right or the reply is silently discarded, which on hardware
        // looks identical to no reply at all.
        icmp_before = icmp_replies;
        inject_icmp_echo(16'h0100, dut.next_rdpt, OUR_IP, 16'h1234, 16'h0001);
        wait (icmp_replies == icmp_before + 16'd1);
        #20_000;

        // addressing: reply goes back to the sender, from us
        check(model.buf_mem[16'h1A00] == 8'h07, "ICMP control byte not 0x07");
        check(model.buf_mem[16'h1A01] == PEER_MAC[47:40], "ICMP reply dest MAC wrong");
        check(model.buf_mem[16'h1A06] == PEER_MAC[7:0],   "ICMP reply dest MAC wrong");
        check(model.buf_mem[16'h1A07] == OUR_MAC[47:40],  "ICMP reply src MAC wrong");
        check(model.buf_mem[16'h1A0D] == 8'h08 && model.buf_mem[16'h1A0E] == 8'h00,
              "ICMP reply EtherType not IPv4");
        check(model.buf_mem[16'h1A18] == 8'd1, "ICMP reply protocol not 1");
        check(model.buf_mem[16'h1A1B] == OUR_IP[31:24] &&
              model.buf_mem[16'h1A1E] == OUR_IP[7:0], "ICMP reply source IP wrong");
        check(model.buf_mem[16'h1A1F] == PEER_IP[31:24] &&
              model.buf_mem[16'h1A22] == PEER_IP[7:0], "ICMP reply dest IP wrong");

        // type must become 0, and identifier/sequence/payload come back intact
        check(model.buf_mem[16'h1A23] == 8'd0, "ICMP reply type not 0 (echo reply)");
        check(model.buf_mem[16'h1A27] == 8'h12 && model.buf_mem[16'h1A28] == 8'h34,
              "ICMP identifier not echoed");
        check(model.buf_mem[16'h1A29] == 8'h00 && model.buf_mem[16'h1A2A] == 8'h01,
              "ICMP sequence number not echoed");
        icmp_ok = 1;
        for (kk = 0; kk < 32; kk = kk + 1)
            if (model.buf_mem[16'h1A2B + kk] !== (8'h61 + kk[7:0])) icmp_ok = 0;
        check(icmp_ok, "ICMP payload not echoed byte-for-byte");

        // both checksums, recomputed here rather than trusting the design's
        chk_sum = 0;
        for (kk = 0; kk < 20; kk = kk + 2)
            chk_sum = chk_sum + {model.buf_mem[16'h1A0F + kk], model.buf_mem[16'h1A10 + kk]};
        chk_sum = (chk_sum & 32'h0000FFFF) + (chk_sum >> 16);
        chk_sum = (chk_sum & 32'h0000FFFF) + (chk_sum >> 16);
        check(chk_sum[15:0] == 16'hFFFF, "IP header checksum wrong");

        chk_sum = 0;
        for (kk = 0; kk < 40; kk = kk + 2)
            chk_sum = chk_sum + {model.buf_mem[16'h1A23 + kk], model.buf_mem[16'h1A24 + kk]};
        chk_sum = (chk_sum & 32'h0000FFFF) + (chk_sum >> 16);
        chk_sum = (chk_sum & 32'h0000FFFF) + (chk_sum >> 16);
        check(chk_sum[15:0] == 16'hFFFF, "ICMP checksum wrong");

        $display("INFO: scenario 4 (ICMP echo) complete, errors so far = %0d", errors);

        // A broadcast ping must NOT be answered: every node on the segment
        // would transmit at once.
        icmp_before = icmp_replies;
        inject_icmp_echo(16'h0180, dut.next_rdpt, 32'hC0A801FF, 16'h1234, 16'h0002);
        #400_000;
        check(icmp_replies == icmp_before, "replied to a broadcast ping");


        // RXEN must have survived every bank select, TX sequence and
        // cleanup above. It did not before ECON1 moved to BFS/BFC:
        // each whole-byte bank select switched the receiver off.
        check(!model.rxen_dropped,
              "RXEN was cleared outside an RXRST pulse (bank select clobbered ECON1)");

        if (errors == 0)
            $display("PASS: UDP receive (unicast + broadcast, payload byte-correct, no spurious reply) UDP send, and ICMP echo (byte-correct reply, both checksums, broadcast ignored) all correct, messages counted, RXEN never dropped");
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
