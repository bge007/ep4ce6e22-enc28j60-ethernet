// uart_rx.v -- 8N1 UART receiver.
//
// Samples each bit at its midpoint: on the falling edge that starts a frame it
// waits half a bit time, re-checks that the line is still low (so a glitch is
// not mistaken for a start bit), then samples every bit time from there.
//
// rx_valid pulses for one cycle with rx_data when a byte completes. A frame
// whose stop bit is not high sets rx_err for that byte and the data is still
// presented -- the caller can ignore it or not.

module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,                // from the CH340 TX pin
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    output reg        rx_err
);

    localparam integer DIV  = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer HALF = DIV / 2;
    localparam integer DW   = $clog2(DIV + 1);

    // Two-stage synchroniser: rx is asynchronous to clk.
    reg [2:0] sync;
    always @(posedge clk) sync <= {sync[1:0], rx};
    wire rx_s = sync[2];

    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [1:0]  state;
    reg [DW:0] cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shifter;

    always @(posedge clk) begin
        rx_valid <= 1'b0;

        if (rst) begin
            state  <= S_IDLE;
            cnt    <= 0;
            rx_err <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    cnt <= 0;
                    if (!rx_s) state <= S_START;      // possible start bit
                end

                // Wait to the middle of the start bit and confirm it is still
                // low. A brief glitch on an idle line is rejected here.
                S_START:
                    if (cnt == HALF - 1) begin
                        cnt <= 0;
                        if (!rx_s) begin
                            bit_idx <= 3'd0;
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE;          // false start
                        end
                    end else cnt <= cnt + 1'b1;

                // Sample each data bit one full bit time apart, which lands on
                // the midpoint because we started from the middle of the start bit.
                S_DATA:
                    if (cnt == DIV - 1) begin
                        cnt     <= 0;
                        shifter <= {rx_s, shifter[7:1]};   // LSB first
                        if (bit_idx == 3'd7) state <= S_STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else cnt <= cnt + 1'b1;

                S_STOP:
                    if (cnt == DIV - 1) begin
                        cnt      <= 0;
                        rx_data  <= shifter;
                        rx_err   <= ~rx_s;             // stop bit should be high
                        rx_valid <= 1'b1;
                        state    <= S_IDLE;
                    end else cnt <= cnt + 1'b1;

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
