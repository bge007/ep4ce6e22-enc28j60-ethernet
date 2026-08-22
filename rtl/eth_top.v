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
    parameter [7:0] HOST_ID = 8'd1
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

    inout  wire       oled_scl,   // 1.3" SH1106 OLED, I2C
    inout  wire       oled_sda
);

    // ------------------------------------------------------------------
    // reset sync
    // ------------------------------------------------------------------
    reg [1:0] rst_sync;
    always @(posedge clk) rst_sync <= {rst_sync[0], ~nrst};
    wire rst = rst_sync[1];

    // ------------------------------------------------------------------
    // SPI master (12.5 MHz for bring-up; final design moves to 20 MHz)
    // ------------------------------------------------------------------
    reg        spi_start;
    reg  [7:0] spi_tx;
    wire [7:0] spi_rx;
    wire       spi_busy;

    spi_master #(.CLK_DIV(2)) u_spi (
        .clk    (clk),
        .rst    (rst),
        .start  (spi_start),
        .tx_byte(spi_tx),
        .rx_byte(spi_rx),
        .busy   (spi_busy),
        .sck    (enc_sck),
        .mosi   (enc_mosi),
        .miso   (enc_miso)
    );

    // ------------------------------------------------------------------
    // ENC28J60 opcodes / registers used here
    // ------------------------------------------------------------------
    localparam [7:0] OP_SRC        = 8'hFF;              // system reset
    localparam [7:0] OP_WCR_ECON1  = {3'b010, 5'h1F};    // write ECON1
    localparam [7:0] OP_RCR_EREVID = {3'b000, 5'h12};    // read  EREVID (bank 3)
    localparam [7:0] BANK3         = 8'h03;

    // delays at 50 MHz
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

    reg [3:0]  state;
    reg [22:0] wait_cnt;
    reg        cs_n;
    reg        enc_rst_q;
    reg [7:0]  erevid;
    reg        spi_busy_d;

    wire spi_done = spi_busy_d & ~spi_busy;   // falling edge of busy

    assign enc_cs_n  = cs_n;
    assign enc_rst_n = enc_rst_q;

    always @(posedge clk) begin
        spi_busy_d <= spi_busy;
        spi_start  <= 1'b0;                   // default: single-cycle pulse

        if (rst) begin
            state     <= S_HW_RESET;
            wait_cnt  <= 23'd0;
            cs_n      <= 1'b1;
            enc_rst_q <= 1'b0;
            erevid    <= 8'h00;
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
                        state    <= S_SRC;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;

                S_SRC: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= OP_SRC;
                    spi_start <= 1'b1;
                    state     <= S_SRC_WAIT;
                end

                S_SRC_WAIT:
                    if (spi_done) begin
                        cs_n     <= 1'b1;
                        wait_cnt <= 23'd0;
                        state    <= S_BANK_OP;   // S_BANK_OP waits 10 ms first
                    end

                S_BANK_OP: begin
                    // wait out the post-SRC delay before first real command
                    if (wait_cnt == {3'b000, T_10MS}) begin
                        cs_n      <= 1'b0;
                        spi_tx    <= OP_WCR_ECON1;
                        spi_start <= 1'b1;
                        state     <= S_BANK_DATA;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;
                end

                S_BANK_DATA:
                    if (spi_done) begin
                        if (cs_n == 1'b0 && spi_tx == OP_WCR_ECON1) begin
                            spi_tx    <= BANK3;
                            spi_start <= 1'b1;
                        end else begin
                            cs_n  <= 1'b1;
                            state <= S_RD_OP;
                        end
                    end

                S_RD_OP: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= OP_RCR_EREVID;
                    spi_start <= 1'b1;
                    state     <= S_RD_DATA;
                end

                S_RD_DATA:
                    if (spi_done) begin
                        if (spi_tx == OP_RCR_EREVID) begin
                            spi_tx    <= 8'h00;       // clock in the data byte
                            spi_start <= 1'b1;
                        end else begin
                            cs_n  <= 1'b1;
                            state <= S_LATCH;
                        end
                    end

                S_LATCH: begin
                    erevid   <= spi_rx;
                    wait_cnt <= 23'd0;
                    state    <= S_IDLE;
                end

                S_IDLE:
                    // re-read ~10x/s (skip re-reset: bank 3 is still selected)
                    if (wait_cnt == T_100MS)
                        state <= S_RD_OP;
                    else
                        wait_cnt <= wait_cnt + 1'b1;

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
    // 1.3" SH1106 OLED status display
    //
    //   line 0   EP4CE6E22 ENC28J60
    //   line 1   EREVID 0xNN OK|BAD
    //   line 2   HOST A 192.168.1.60
    //   line 3   MSG <payload>
    //
    // Line 3 is the integration point for milestone 4: today it holds a
    // placeholder, and once UDP receive exists the payload is written through
    // the same msg_* port instead.
    // ------------------------------------------------------------------
    localparam integer OCOLS = 21;

    // Static template. '#' marks a cell patched at runtime.
    reg [7:0] tmpl [0:OCOLS*4-1];
    integer   ti;
    initial begin
        for (ti = 0; ti < OCOLS*4; ti = ti + 1) tmpl[ti] = 8'h20;
        // line 0
        tmpl[ 0]="E"; tmpl[ 1]="P"; tmpl[ 2]="4"; tmpl[ 3]="C"; tmpl[ 4]="E";
        tmpl[ 5]="6"; tmpl[ 6]="E"; tmpl[ 7]="2"; tmpl[ 8]="2";
        tmpl[10]="E"; tmpl[11]="N"; tmpl[12]="C"; tmpl[13]="2"; tmpl[14]="8";
        tmpl[15]="J"; tmpl[16]="6"; tmpl[17]="0";
        // line 1: "EREVID 0x## ..."
        tmpl[21]="E"; tmpl[22]="R"; tmpl[23]="E"; tmpl[24]="V"; tmpl[25]="I";
        tmpl[26]="D"; tmpl[28]="0"; tmpl[29]="x";
        // line 2: "HOST A 192.168.1.6#"
        tmpl[42]="H"; tmpl[43]="O"; tmpl[44]="S"; tmpl[45]="T";
        tmpl[49]="1"; tmpl[50]="9"; tmpl[51]="2"; tmpl[52]=".";
        tmpl[53]="1"; tmpl[54]="6"; tmpl[55]="8"; tmpl[56]=".";
        tmpl[57]="1"; tmpl[58]="."; tmpl[59]="6";
        // line 3
        tmpl[63]="M"; tmpl[64]="S"; tmpl[65]="G"; tmpl[67]="-"; tmpl[68]="-";
    end

    function [7:0] hexdig(input [3:0] n);
        hexdig = (n < 4'd10) ? (8'h30 + n) : (8'h41 + n - 4'd10);
    endfunction

    wire erevid_ok = (erevid == 8'h06);

    // Patch the dynamic cells as the template is streamed out.
    reg  [6:0] w_addr;
    reg  [7:0] w_char;
    reg        w_en;
    reg        w_done;
    reg        o_refresh;
    reg  [7:0] last_shown;
    wire       o_ready;

    always @(posedge clk) begin
        if (rst) begin
            w_addr     <= 7'd0;
            w_en       <= 1'b0;
            w_done     <= 1'b0;
            o_refresh  <= 1'b0;
            last_shown <= 8'hFF;
        end else begin
            o_refresh <= 1'b0;
            if (!w_done) begin
                w_en <= 1'b1;
                case (w_addr)
                    7'd30: w_char <= hexdig(erevid[7:4]);
                    7'd31: w_char <= hexdig(erevid[3:0]);
                    7'd33: w_char <= erevid_ok ? "O" : "B";
                    7'd34: w_char <= erevid_ok ? "K" : "A";
                    7'd35: w_char <= erevid_ok ? " " : "D";
                    7'd47: w_char <= (HOST_ID == 8'd1) ? "A" : "B";
                    7'd60: w_char <= (HOST_ID == 8'd1) ? "0" : "1";
                    default: w_char <= tmpl[w_addr];
                endcase
                if (w_addr == OCOLS*4-1) begin
                    w_done    <= 1'b1;
                    o_refresh <= 1'b1;      // paint once the buffer is filled
                end else begin
                    w_addr <= w_addr + 7'd1;
                end
            end else begin
                w_en <= 1'b0;
                // Repaint whenever the EREVID readback changes, so a wire
                // coming loose is visible on the panel and not just the LEDs.
                if (o_ready && (erevid != last_shown)) begin
                    o_refresh  <= 1'b1;
                    last_shown <= erevid;
                    w_addr     <= 7'd0;
                    w_done     <= 1'b0;
                end
            end
        end
    end

    oled_sh1106 #(.CLK_HZ(50_000_000)) u_oled (
        .clk(clk), .rst(rst),
        .txt_we(w_en), .txt_addr(w_addr), .txt_char(w_char),
        .refresh(o_refresh), .ready(o_ready), .i2c_err(),
        .oled_scl(oled_scl), .oled_sda(oled_sda)
    );

endmodule
