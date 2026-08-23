// uart_tx.v -- 8N1 UART transmitter.
//
// Idle high. One start bit low, eight data bits LSB first, one stop bit high.
// Assert tx_valid with tx_data while tx_ready is high; the byte is taken on
// that cycle and tx_ready drops until the stop bit has been sent.

module uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] tx_data,
    input  wire       tx_valid,
    output wire       tx_ready,
    output reg        tx                 // to the CH340 RX pin
);

    // Rounded to nearest rather than truncated: at 115200 the exact value is
    // 434.03, and rounding down on every bit would drift the stop bit early.
    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer DW  = $clog2(DIV + 1);

    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [1:0]    state;
    reg [DW:0]   cnt;
    reg [2:0]    bit_idx;
    reg [7:0]    shifter;

    assign tx_ready = (state == S_IDLE);

    wire tick = (cnt == DIV - 1);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            tx    <= 1'b1;
            cnt   <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx  <= 1'b1;
                    cnt <= 0;
                    if (tx_valid) begin
                        shifter <= tx_data;
                        bit_idx <= 3'd0;
                        tx      <= 1'b0;      // start bit
                        state   <= S_START;
                    end
                end

                S_START:
                    if (tick) begin
                        cnt   <= 0;
                        tx    <= shifter[0];
                        state <= S_DATA;
                    end else cnt <= cnt + 1'b1;

                S_DATA:
                    if (tick) begin
                        cnt <= 0;
                        if (bit_idx == 3'd7) begin
                            tx    <= 1'b1;    // stop bit
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                            shifter <= {1'b0, shifter[7:1]};
                            tx      <= shifter[1];
                        end
                    end else cnt <= cnt + 1'b1;

                S_STOP:
                    if (tick) begin
                        cnt   <= 0;
                        state <= S_IDLE;
                    end else cnt <= cnt + 1'b1;

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
