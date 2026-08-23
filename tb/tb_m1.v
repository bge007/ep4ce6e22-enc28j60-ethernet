// tb_m1.v -- Milestone 1 testbench: eth_top against a behavioral ENC28J60.
//
// The model implements just enough: SPI mode-0 slave, SRC opcode, WCR ECON1
// (bank select), RCR of an Ethernet register, EREVID=0x06 in bank 3.
// Timeouts in eth_top are ms-scale, so we shrink them via defparam-free
// brute force: just run long enough (sim is cheap at this size).
//
// Pass criteria (self-checking):
//   * model saw hardware reset then SRC
//   * ECON1[1:0] written to 3
//   * EREVID read returned 0x06 and dut.erevid == 0x06
//
// Run:  iverilog -o tb_m1.vvp tb/tb_m1.v rtl/eth_top.v rtl/spi_master.v
//       vvp tb_m1.vvp

`timescale 1ns/1ps

module enc28j60_model (
    input  wire rst_n,
    input  wire cs_n,
    input  wire sck,
    input  wire mosi,
    output reg  miso
);
    reg [7:0] shift_in;
    reg [7:0] shift_out;
    reg [3:0] bit_cnt;          // bits received in current byte
    integer   byte_idx;         // byte index within current CS frame
    reg [7:0] opcode;
    reg [7:0] econ1;
    reg       got_src;
    reg       got_hw_reset;

    localparam [7:0] EREVID_B7 = 8'h06;

    initial begin
        miso = 1'b0; shift_in = 0; shift_out = 0; bit_cnt = 0;
        byte_idx = 0; opcode = 0; econ1 = 0; got_src = 0; got_hw_reset = 0;
    end

    always @(negedge rst_n) got_hw_reset = 1'b1;

    // new frame on CS falling edge
    always @(negedge cs_n) begin
        byte_idx = 0;
        bit_cnt  = 0;
        shift_out = 8'h00;
    end

    // sample MOSI on rising SCK
    always @(posedge sck) begin
        if (!cs_n) begin
            shift_in = {shift_in[6:0], mosi};
            bit_cnt  = bit_cnt + 1;
            if (bit_cnt == 8) begin
                bit_cnt = 0;
                if (byte_idx == 0) begin
                    opcode = shift_in;
                    if (opcode == 8'hFF) got_src = 1'b1;
                    // RCR (000aaaaa): preload response for the next byte
                    if (opcode[7:5] == 3'b000) begin
                        if (econ1[1:0] == 2'b11 && opcode[4:0] == 5'h12)
                            shift_out = EREVID_B7;
                        else
                            shift_out = 8'hAA;  // wrong bank / wrong reg marker
                    end
                end else begin
                    // WCR (010aaaaa) data byte
                    if (opcode[7:5] == 3'b010 && opcode[4:0] == 5'h1F)
                        econ1 = shift_in;
                end
                byte_idx = byte_idx + 1;
            end
        end
    end

    // drive MISO on falling SCK (mode 0: master samples on rising)
    always @(negedge sck) begin
        if (!cs_n) begin
            miso     = shift_out[7];
            shift_out = {shift_out[6:0], 1'b0};
        end
    end

    // MSB must be valid before the first rising edge of a response byte:
    // put it out when the previous byte completes / CS asserts
    always @(negedge cs_n) miso = shift_out[7];

endmodule


module tb_m1;

    reg clk = 0;
    always #10 clk = ~clk;      // 50 MHz

    reg nrst = 0;

    wire [4:0] led;
    wire enc_rst_n, enc_cs_n, enc_sck, enc_mosi, enc_int_unused;
    wire enc_miso;

    eth_top dut (
        .clk      (clk),
        .nrst     (nrst),
        .key      (4'b1111),
        .led      (led),
        .enc_rst_n(enc_rst_n),
        .enc_cs_n (enc_cs_n),
        .enc_sck  (enc_sck),
        .enc_mosi (enc_mosi),
        .enc_miso (enc_miso),
        .enc_int  (1'b0)
    );

    enc28j60_model model (
        .rst_n(enc_rst_n),
        .cs_n (enc_cs_n),
        .sck  (enc_sck),
        .mosi (enc_mosi),
        .miso (enc_miso)
    );

    integer errors = 0;

    initial begin
        $dumpfile("tb_m1.vcd");
        $dumpvars(0, tb_m1);

        #200 nrst = 1;

        // Check the instant EREVID first latches, not after a fixed delay.
        // Since M3 (net_stack) now starts running the moment M2 completes,
        // and this model's crude EPKTCNT response (0xAA, non-zero) tricks
        // net_stack into thinking a packet is always waiting, ECON1 keeps
        // changing indefinitely afterward -- a fixed-time sample would catch
        // whatever net_stack happened to write most recently, not M1's own
        // result. Sampling right at the M1 milestone avoids that entirely.
        wait (dut.erevid == 8'h06);
        #10;

        if (!model.got_hw_reset) begin
            $display("FAIL: model never saw hardware reset");
            errors = errors + 1;
        end
        if (!model.got_src) begin
            $display("FAIL: model never saw SRC (0xFF)");
            errors = errors + 1;
        end
        if (model.econ1[1:0] !== 2'b11) begin
            $display("FAIL: ECON1 bank select = %b, expected 11", model.econ1[1:0]);
            errors = errors + 1;
        end
        if (dut.erevid !== 8'h06) begin
            $display("FAIL: dut.erevid = 0x%02h, expected 0x06", dut.erevid);
            errors = errors + 1;
        end
        if (led !== ~5'b00110) begin
            $display("FAIL: led = %b, expected %b", led, ~5'b00110);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: EREVID=0x%02h read correctly, LEDs correct", dut.erevid);
        else
            $display("%0d ERROR(S)", errors);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("FAIL: timeout -- dut.erevid never reached 0x06");
        $finish;
    end

endmodule
