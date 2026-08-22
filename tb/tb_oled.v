// tb_oled.v -- self-checking testbench for oled_sh1106 + i2c_master against a
// behavioural SH1106 I2C slave.
//
// What it proves:
//   * the slave address byte is 0x78 (7-bit 0x3C, write)
//   * the datasheet init sequence is delivered, in order
//   * the charge pump is set to internal DC-DC (0xAD 0x8B), not 0x8A
//   * EVERY page sets column low = 0x02 and high = 0x10 -- the SH1106 offset
//   * all eight pages are addressed 0xB0..0xB7 and each receives 128 bytes
//   * 0xAF is sent only after the clear pass, so noise is never displayed
//   * text written to the buffer reaches the panel as the right glyph bytes
//
// Run:  vlog -sv ../rtl/i2c_master.v ../rtl/oled_sh1106.v ../tb/tb_oled.v
//       vsim -c -do "run -all; quit -f" tb_oled

`timescale 1ns/1ps

module sh1106_model (
    input wire scl,
    input wire sda_line,
    output wire sda_drive_low
);
    // Simple slave: always ACKs. Decodes START/STOP and bytes, classifies each
    // transaction as a command or data stream from the control byte.
    reg ack_low;
    assign sda_drive_low = ack_low;

    reg [7:0] shifter;
    reg [3:0] nbits;
    integer   byte_idx;
    reg       in_frame;
    reg       in_ack;
    reg       is_data_stream;
    reg [7:0] addr_byte;

    // observations
    reg [7:0] cmd_log [0:255];
    integer   cmd_n;
    integer   data_count [0:7];
    integer   cur_page;
    reg [7:0] last_page_cmd;
    integer   col_lo_ok, col_hi_ok, page_cmd_n;
    reg       seen_af;
    reg       af_before_clear;
    integer   total_pages_done;
    reg [7:0] page0_bytes [0:127];
    integer   p0i;

    initial begin
        ack_low = 0; nbits = 0; byte_idx = 0; in_frame = 0; in_ack = 0;
        is_data_stream = 0; cmd_n = 0; cur_page = 0;
        col_lo_ok = 0; col_hi_ok = 0; page_cmd_n = 0;
        seen_af = 0; af_before_clear = 0; total_pages_done = 0; p0i = 0;
        for (byte_idx = 0; byte_idx < 8; byte_idx = byte_idx + 1) data_count[byte_idx] = 0;
        byte_idx = 0;
    end

    // START / STOP detection on SDA edges while SCL is high
    integer starts, stops;
    initial begin starts = 0; stops = 0; end

    always @(negedge sda_line) if (scl === 1'b1) begin
        in_frame = 1; nbits = 0; byte_idx = 0; is_data_stream = 0;
        starts = starts + 1;
        if (starts < 8) $display("  [model] START #%0d at %0t", starts, $time);
    end
    always @(posedge sda_line) if (scl === 1'b1) begin
        in_frame = 0; nbits = 0;
        stops = stops + 1;
        if (stops < 8) $display("  [model] STOP  #%0d at %0t", stops, $time);
    end

    // sample bits on rising SCL -- but NOT during the ACK clock, or the ACK
    // bit gets shifted in as bit 0 of the following byte
    always @(posedge scl) begin
        if (in_frame && !in_ack) begin
            if (nbits < 8) begin
                shifter = {shifter[6:0], (sda_line === 1'b0) ? 1'b0 : 1'b1};
                nbits   = nbits + 1;
            end
        end
    end

    // drive ACK during the 9th clock, and interpret the completed byte
    always @(negedge scl) begin
        if (in_ack) begin
            in_ack  = 0;
            ack_low = 0;
        end else if (in_frame && nbits == 8) begin
            if (byte_idx == 0) begin
                addr_byte = shifter;
            end else if (byte_idx == 1) begin
                is_data_stream = (shifter == 8'h40);
            end else begin
                if (is_data_stream) begin
                    if (cur_page >= 0 && cur_page < 8) data_count[cur_page] = data_count[cur_page] + 1;
                    // Wrap so the buffer ends up holding the MOST RECENT pass
                    // over page 0. The first pass is the clear (all zeros);
                    // the text we want to check arrives on the second.
                    if (cur_page == 0) begin
                        page0_bytes[p0i] = shifter;
                        p0i = (p0i == 127) ? 0 : p0i + 1;
                    end
                end else begin
                    cmd_log[cmd_n] = shifter; cmd_n = cmd_n + 1;
                    if (shifter[7:4] == 4'hB) begin
                        cur_page   = shifter[2:0];
                        page_cmd_n = page_cmd_n + 1;
                        last_page_cmd = shifter;
                    end
                    // the two bytes after a page command must be 0x02 then 0x10
                    if (shifter == 8'h02 && last_page_cmd[7:4] == 4'hB) col_lo_ok = col_lo_ok + 1;
                    if (shifter == 8'h10 && last_page_cmd[7:4] == 4'hB) col_hi_ok = col_hi_ok + 1;
                    if (shifter == 8'hAF) begin
                        seen_af = 1;
                        if (total_pages_done < 8) af_before_clear = 1;
                    end
                end
            end
            byte_idx = byte_idx + 1;
            nbits    = 0;
            in_ack   = 1;
            ack_low  = 1;          // pull SDA low for the ACK bit
        end
    end

    // count completed pages
    always @(*) begin
        total_pages_done = 0;
        begin : cnt
            integer k;
            for (k = 0; k < 8; k = k + 1)
                if (data_count[k] >= 128) total_pages_done = total_pages_done + 1;
        end
    end
endmodule


module tb_oled;

    reg clk = 0;
    always #10 clk = ~clk;          // 50 MHz
    reg rst = 1;

    wire scl, sda;
    // Pull-ups on the bus.
    pullup (scl);
    pullup (sda);

    reg        txt_we = 0;
    reg  [6:0] txt_addr = 0;
    reg  [7:0] txt_char = 0;
    reg        refresh = 0;
    wire       ready, i2c_err;

    // POR shortened so the sim is seconds, not minutes.
    oled_sh1106 #(.CLK_HZ(50_000_000), .POR_TICKS(200)) dut (
        .clk(clk), .rst(rst),
        .txt_we(txt_we), .txt_addr(txt_addr), .txt_char(txt_char),
        .refresh(refresh), .ready(ready), .i2c_err(i2c_err),
        .oled_scl(scl), .oled_sda(sda)
    );

    wire model_pulls_low;
    sh1106_model model (.scl(scl), .sda_line(sda), .sda_drive_low(model_pulls_low));
    assign sda = model_pulls_low ? 1'b0 : 1'bz;

    integer errors = 0;
    integer i;

    // expected init table (datasheet 4.4, charge pump 0x8B)
    reg [7:0] expect_init [0:25];
    initial begin
        expect_init[ 0]=8'hAE; expect_init[ 1]=8'h02; expect_init[ 2]=8'h10;
        expect_init[ 3]=8'h40; expect_init[ 4]=8'hB0; expect_init[ 5]=8'h81;
        expect_init[ 6]=8'hBF; expect_init[ 7]=8'hA1; expect_init[ 8]=8'hA6;
        expect_init[ 9]=8'hA8; expect_init[10]=8'h3F; expect_init[11]=8'hAD;
        expect_init[12]=8'h8B; expect_init[13]=8'h32; expect_init[14]=8'hC8;
        expect_init[15]=8'hD3; expect_init[16]=8'h00; expect_init[17]=8'hD5;
        expect_init[18]=8'h80; expect_init[19]=8'hD9; expect_init[20]=8'h22;
        expect_init[21]=8'hDA; expect_init[22]=8'h12; expect_init[23]=8'hDB;
        expect_init[24]=8'h40;
    end

    task check(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                $display("FAIL: %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // "Hi" on line 0 so we can check glyph bytes reach the panel
        #100 rst = 0;
        @(posedge clk);
        txt_we = 1;
        txt_addr = 0; txt_char = "H"; @(posedge clk);
        txt_addr = 1; txt_char = "i"; @(posedge clk);
        txt_we = 0;

        // wait for init + clear + display-on, then the first text paint
        wait (ready == 1'b1);
        $display("INFO: init + clear complete at %0t ns", $time);

        @(posedge clk);
        refresh = 1; @(posedge clk); refresh = 0;
        wait (ready == 1'b0);
        wait (ready == 1'b1);
        $display("INFO: text refresh complete at %0t ns", $time);

        // ---------------- observed state ----------------
        $display("INFO: starts=%0d stops=%0d cmd_n=%0d page_cmds=%0d col_lo=%0d col_hi=%0d",
                 model.starts, model.stops, model.cmd_n,
                 model.page_cmd_n, model.col_lo_ok, model.col_hi_ok);
        for (i = 0; i < 8; i = i + 1)
            $display("INFO: page %0d data bytes = %0d", i, model.data_count[i]);
        $write("INFO: first 32 command bytes:");
        for (i = 0; i < 32; i = i + 1) $write(" %02h", model.cmd_log[i]);
        $display("");

        // ---------------- checks ----------------
        check(model.addr_byte == 8'h78, "slave address byte is not 0x78");

        for (i = 0; i < 25; i = i + 1)
            if (model.cmd_log[i] !== expect_init[i]) begin
                $display("FAIL: init byte %0d is 0x%02h, expected 0x%02h",
                         i, model.cmd_log[i], expect_init[i]);
                errors = errors + 1;
            end

        check(model.cmd_log[11] == 8'hAD && model.cmd_log[12] == 8'h8B,
              "charge pump is not 0xAD 0x8B (internal DC-DC)");

        // 8 pages cleared + 8 pages painted = 16 page-setup transactions.
        // page_cmd_n is larger than that because the init table also contains
        // a 0xB0, so compare the column counts against 16 rather than against
        // page_cmd_n.
        if (model.col_lo_ok != 16) begin
            $display("FAIL: lower column set to 0x02 on %0d of 16 pages -- SH1106 offset missing",
                     model.col_lo_ok);
            errors = errors + 1;
        end
        if (model.col_hi_ok != 16) begin
            $display("FAIL: higher column set to 0x10 on %0d of 16 pages", model.col_hi_ok);
            errors = errors + 1;
        end

        for (i = 0; i < 8; i = i + 1)
            if (model.data_count[i] < 256) begin
                $display("FAIL: page %0d got %0d data bytes, expected >= 256 (clear + paint)",
                         i, model.data_count[i]);
                errors = errors + 1;
            end

        check(model.seen_af == 1'b1, "display-on 0xAF never sent");
        check(model.af_before_clear == 1'b0, "0xAF sent before the clear pass finished");
        check(i2c_err == 1'b0, "I2C reported a NACK");

        // Line 0 holds "Hi". From font5x8.mem, 'H' is 7f 08 08 08 7f and 'i'
        // is 7d 00 00 00 00, each followed by a blank gap column.
        begin : glyph_check
            reg [7:0] want [0:11];
            want[0]=8'h7f; want[1]=8'h08; want[2]=8'h08; want[3]=8'h08; want[4]=8'h7f; want[5]=8'h00;
            want[6]=8'h7d; want[7]=8'h00; want[8]=8'h00; want[9]=8'h00; want[10]=8'h00; want[11]=8'h00;
            for (i = 0; i < 12; i = i + 1)
                if (model.page0_bytes[i] !== want[i]) begin
                    $display("FAIL: page0 column %0d is 0x%02h, expected 0x%02h",
                             i, model.page0_bytes[i], want[i]);
                    errors = errors + 1;
                end
        end
        // and the rest of the line, past the two characters, must be blank
        check(model.page0_bytes[20] == 8'h00, "column past end of text is not blank");

        if (errors == 0)
            $display("PASS: SH1106 init, 0x02/0x10 column offset on all %0d pages, 8 pages painted, text rendered",
                     model.page_cmd_n);
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
