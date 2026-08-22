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

module eth_top (
    input  wire       clk,        // 50 MHz
    input  wire       nrst,       // board reset button, active low
    input  wire [3:0] key,        // user buttons, active low
    output wire [4:0] led,        // active low

    output wire       enc_rst_n,
    output wire       enc_cs_n,
    output wire       enc_sck,
    output wire       enc_mosi,
    input  wire       enc_miso,
    input  wire       enc_int     // unused in M1
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

endmodule
