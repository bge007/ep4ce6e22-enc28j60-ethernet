// tb_m2.v -- Milestone 2 testbench: the link/MAC init sequence against a
// behavioural ENC28J60 with REAL per-bank register storage.
//
// tb_m1's model only tracks a single ECON1 byte -- enough to prove the SPI
// path and EREVID read, not enough to catch a wrong register address or a
// MAC-address byte landing in the wrong slot. This model stores every WCR
// into a genuine {bank, address} array and serves RCR from it, so a mistake
// in eth_top's cfg_op/cfg_dat table shows up as a wrong readback here instead
// of only on real hardware.
//
// Checks:
//   * RX buffer:  ERXST=0x0000, ERXND=0x19FF, ERXRDPT=0x19FF, ETXST=0x1A00
//   * bank 1:     ERXFCON = 0xA1 (unicast+broadcast+CRC, no pattern match)
//   * bank 2:     MACON1=0x01, MACON3=0x32, MACON4=0x00, MABBIPG=0x12,
//                 MAIPGL=0x12, MAIPGH=0x0C, MAMXFL=0x05EE
//   * bank 3:     MAC address 02:42:CE:60:00:01, correctly placed at the
//                 documented MAADR5/6/3/4/1/2 file order
//   * ECON1 ends with RXEN=1 and bank=3 (bits 0x07)
//   * eth_top's own ECON1 readback (econ1_rb) matches what was written
//   * the "ETH C1=xx" UART line reports the same byte
//
// MACON1/MACON3 readback was tried and dropped from the design (see
// eth_top.v's cfg_op comment): this testbench still verifies those writes
// landed correctly, but via the model's internal register storage directly,
// not via an SPI readback -- unaffected by the read-protocol question.
//
// Run:  vlog -sv ../rtl/*.v ../tb/tb_m2.v
//       vsim -c -do "run -all; quit -f" tb_m2

`timescale 1ns/1ps

module enc28j60_bank_model (
    input  wire rst_n,
    input  wire cs_n,
    input  wire sck,
    input  wire mosi,
    output reg  miso
);
    reg [7:0] shift_in, shift_out;
    reg [3:0] bit_cnt;
    integer   byte_idx;
    reg [7:0] opcode;

    reg [7:0] econ1;                    // common register, not banked
    reg [7:0] regs [0:3][0:31];         // [bank][addr] -- everything else

    integer bi, ai;
    initial begin
        miso = 0; shift_in = 0; shift_out = 0; bit_cnt = 0; byte_idx = 0;
        opcode = 0; econ1 = 0;
        for (bi = 0; bi < 4; bi = bi + 1)
            for (ai = 0; ai < 32; ai = ai + 1) regs[bi][ai] = 8'h00;
    end

    wire [1:0] cur_bank = econ1[1:0];

    always @(negedge cs_n) begin
        byte_idx = 0; bit_cnt = 0; shift_out = 8'h00;
    end

    // ECON1/EREVID (Ethernet-type/common registers) return data right after
    // the opcode -- the only read this design performs after dropping the
    // MAC-register readback (see eth_top.v's cfg_op comment for why).
    always @(posedge sck) begin
        if (!cs_n) begin
            shift_in = {shift_in[6:0], mosi};
            bit_cnt  = bit_cnt + 1;
            if (bit_cnt == 8) begin
                bit_cnt = 0;
                if (byte_idx == 0) begin
                    opcode = shift_in;
                    if (shift_in[7:5] == 3'b000) begin         // RCR
                        if (shift_in[4:0] == 5'h1F)
                            shift_out = econ1;
                        else if (shift_in[4:0] == 5'h12 && cur_bank == 2'd3)
                            shift_out = 8'h06;                 // EREVID
                        else
                            shift_out = regs[cur_bank][shift_in[4:0]];
                    end
                end else begin
                    if (opcode[7:5] == 3'b010) begin           // WCR
                        if (opcode[4:0] == 5'h1F) econ1 = shift_in;
                        else                       regs[cur_bank][opcode[4:0]] = shift_in;
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


module tb_m2;

    reg clk = 0;
    always #10 clk = ~clk;
    reg nrst = 0;

    wire [4:0] led;
    wire enc_rst_n, enc_cs_n, enc_sck, enc_mosi, enc_miso;
    wire oled_scl, oled_sda;
    wire uart_tx;
    reg  uart_rx = 1'b1;

    pullup(oled_scl);
    pullup(oled_sda);

    eth_top #(.HOST_ID(8'd1)) dut (
        .clk(clk), .nrst(nrst), .key(4'b1111), .led(led),
        .enc_rst_n(enc_rst_n), .enc_cs_n(enc_cs_n), .enc_sck(enc_sck),
        .enc_mosi(enc_mosi), .enc_miso(enc_miso), .enc_int(1'b0),
        .oled_scl(oled_scl), .oled_sda(oled_sda),
        .uart_tx(uart_tx), .uart_rx(uart_rx)
    );

    enc28j60_bank_model model (
        .rst_n(enc_rst_n), .cs_n(enc_cs_n), .sck(enc_sck),
        .mosi(enc_mosi), .miso(enc_miso)
    );

    // Monitor the UART "ETH ..." line so the console report is checked too.
    wire [7:0] mon_data;
    wire       mon_valid, mon_err;
    uart_rx #(.CLK_HZ(50_000_000), .BAUD(115200)) u_mon (
        .clk(clk), .rst(1'b0), .rx(uart_tx),
        .rx_data(mon_data), .rx_valid(mon_valid), .rx_err(mon_err)
    );
    reg [7:0] seen [0:255];
    integer   seen_n = 0;
    always @(posedge clk) if (mon_valid) begin seen[seen_n] = mon_data; seen_n = seen_n + 1; end

    function integer contains(input [8*24-1:0] pat, input integer len);
        integer a, b_, ok;
        begin
            contains = -1;
            for (a = 0; a <= seen_n - len; a = a + 1) begin
                ok = 1;
                for (b_ = 0; b_ < len; b_ = b_ + 1)
                    if (seen[a+b_] !== pat[8*(len-1-b_) +: 8]) ok = 0;
                if (ok && contains < 0) contains = a;
            end
        end
    endfunction

    integer errors = 0;
    task check(input cond, input [80*8:0] what);
        if (!cond) begin $display("FAIL: %0s", what); errors = errors + 1; end
    endtask
    task check_reg(input [1:0] bank, input [4:0] addr, input [7:0] exp, input [80*8:0] what);
        if (model.regs[bank][addr] !== exp) begin
            $display("FAIL: %0s -- bank%0d[0x%02h] = 0x%02h, expected 0x%02h",
                     what, bank, addr, model.regs[bank][addr], exp);
            errors = errors + 1;
        end
    endtask

    initial begin
        #200 nrst = 1;

        // Check right as M2 finishes, not after a fixed delay: M3 (net_stack)
        // now starts running the instant eth_ready fires, and its own
        // one-time init writes ECON1 again (bank 1, to poll EPKTCNT) shortly
        // afterward. A fixed-time sample would risk catching net_stack's
        // state instead of M2's -- sampling at the edge avoids that.
        wait (dut.eth_ready);
        #10;

        // ---- RX/TX buffer, bank 0 ----
        check_reg(2'd0, 5'h08, 8'h00, "ERXSTL");
        check_reg(2'd0, 5'h09, 8'h00, "ERXSTH");
        check_reg(2'd0, 5'h0A, 8'hFF, "ERXNDL");
        check_reg(2'd0, 5'h0B, 8'h19, "ERXNDH");
        check_reg(2'd0, 5'h0C, 8'hFF, "ERXRDPTL");
        check_reg(2'd0, 5'h0D, 8'h19, "ERXRDPTH");
        check_reg(2'd0, 5'h04, 8'h00, "ETXSTL");
        check_reg(2'd0, 5'h05, 8'h1A, "ETXSTH");

        // ---- receive filter, bank 1 ----
        check_reg(2'd1, 5'h18, 8'hA1, "ERXFCON");

        // ---- MAC config, bank 2 ----
        check_reg(2'd2, 5'h00, 8'h01, "MACON1 (MARXEN)");
        check_reg(2'd2, 5'h02, 8'h32, "MACON3 (pad/CRC/half-duplex)");
        check_reg(2'd2, 5'h03, 8'h00, "MACON4");
        check_reg(2'd2, 5'h04, 8'h12, "MABBIPG");
        check_reg(2'd2, 5'h06, 8'h12, "MAIPGL");
        check_reg(2'd2, 5'h07, 8'h0C, "MAIPGH");
        check_reg(2'd2, 5'h0A, 8'hEE, "MAMXFLL (1518 low)");
        check_reg(2'd2, 5'h0B, 8'h05, "MAMXFLH (1518 high)");

        // ---- MAC address, bank 3, documented reversed file order ----
        check_reg(2'd3, 5'h00, 8'h00, "MAADR5 (byte 5 = 0x00)");
        check_reg(2'd3, 5'h01, 8'h01, "MAADR6 (byte 6 = HOST_ID = 0x01)");
        check_reg(2'd3, 5'h02, 8'hCE, "MAADR3 (byte 3 = 0xCE)");
        check_reg(2'd3, 5'h03, 8'h60, "MAADR4 (byte 4 = 0x60)");
        check_reg(2'd3, 5'h04, 8'h02, "MAADR1 (byte 1 = 0x02)");
        check_reg(2'd3, 5'h05, 8'h42, "MAADR2 (byte 2 = 0x42)");

        // ---- final ECON1: RXEN=1, bank=3 (0x07) ----
        check(model.econ1 === 8'h07, "final ECON1 is not 0x07 (RXEN=1, bank=3)");

        // ---- eth_top's own readback matches what was written ----
        check(dut.econ1_rb  === 8'h04, "eth_top's ECON1 readback wrong (expected 0x04, sampled before the final re-bank)");
        check(dut.eth_ready === 1'b1,  "eth_ready never asserted");

        // ---- the UART status line reports the same byte ----
        // Give the banner + "ETH C1=xx" line time to actually transmit
        // (roughly 2 ms of real UART bytes at 115200) -- unaffected by
        // net_stack's later ECON1 writes, which is a separate signal path.
        #3_000_000;
        check(contains("ETH C1=04", 9) >= 0, "UART did not report 'ETH C1=04'");

        // ---- M1 behaviour must still work: EREVID readback unaffected ----
        check(dut.erevid === 8'h06, "M1 EREVID readback broken by M2 changes");

        if (errors == 0)
            $display("PASS: M2 link/MAC init -- RX/TX buffer, filter, MAC config, MAC address, RXEN, readback, UART report all correct");
        else
            $display("%0d ERROR(S)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
