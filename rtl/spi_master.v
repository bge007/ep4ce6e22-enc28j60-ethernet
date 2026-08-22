// spi_master.v -- byte-streaming SPI master, mode 0, burst-capable.
//
// CS is controlled by the caller (cs_n input pass-through is NOT done here;
// the caller owns enc_cs_n directly so it can hold it low across a burst).
// Handshake: pulse start with tx_byte valid; busy goes high; when busy falls,
// rx_byte holds the byte clocked in during the transfer.
//
// SCK = clk / (2*CLK_DIV).  With clk=50 MHz, CLK_DIV=2 -> 12.5 MHz (safe for
// jumper-wire bring-up); CLK_DIV=1 -> 25 MHz is OVER the ENC28J60 20 MHz max,
// so the 20 MHz final config comes from a 40 MHz PLL clock with CLK_DIV=1...
// which is also over. Final: 40 MHz PLL + CLK_DIV=1 gives 20 MHz. For M1 we
// stay at 50 MHz / CLK_DIV=2 = 12.5 MHz.

module spi_master #(
    parameter CLK_DIV = 2               // SCK = clk/(2*CLK_DIV), min 1
) (
    input  wire       clk,
    input  wire       rst,

    input  wire       start,            // 1-cycle pulse, tx_byte must be valid
    input  wire [7:0] tx_byte,
    output reg  [7:0] rx_byte,
    output reg        busy,

    output reg        sck,              // idle low (mode 0)
    output reg        mosi,
    input  wire       miso
);

    localparam integer DW = (CLK_DIV <= 1) ? 1 : $clog2(CLK_DIV + 1);

    reg [DW:0]  div_cnt;
    reg [2:0]   bit_cnt;
    reg [7:0]   sh_out;
    reg [7:0]   sh_in;
    reg         phase;      // 0 = SCK-low half, 1 = SCK-high half

    always @(posedge clk) begin
        if (rst) begin
            busy    <= 1'b0;
            sck     <= 1'b0;
            mosi    <= 1'b0;
            phase   <= 1'b0;
            div_cnt <= 0;
            bit_cnt <= 3'd0;
            rx_byte <= 8'h00;
        end else if (!busy) begin
            sck <= 1'b0;
            if (start) begin
                busy    <= 1'b1;
                sh_out  <= tx_byte;
                mosi    <= tx_byte[7];      // MSB first, set up before 1st edge
                phase   <= 1'b0;
                div_cnt <= 0;
                bit_cnt <= 3'd0;
            end
        end else begin
            if (div_cnt == CLK_DIV - 1) begin
                div_cnt <= 0;
                if (!phase) begin
                    // rising edge: slave & master sample
                    sck   <= 1'b1;
                    sh_in <= {sh_in[6:0], miso};
                    phase <= 1'b1;
                end else begin
                    // falling edge: shift out next bit
                    sck   <= 1'b0;
                    phase <= 1'b0;
                    if (bit_cnt == 3'd7) begin
                        busy    <= 1'b0;
                        rx_byte <= sh_in;   // last bit was captured on the rising edge
                    end else begin
                        bit_cnt <= bit_cnt + 3'd1;
                        sh_out  <= {sh_out[6:0], 1'b0};
                        mosi    <= sh_out[6];
                    end
                end
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

endmodule
