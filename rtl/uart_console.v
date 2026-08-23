// uart_console.v -- serial console on the board's CH340 port.
//
// Transmits:
//   * a banner once at reset               "EP4CE6E22 node A ready"
//   * a line whenever a button changes     "KEYS 0.2."
//   * an echo whenever a line is received  "MSG: hello world"
//
// Receives a line of printable ASCII terminated by CR or LF into a 21-character
// buffer -- 21 because that is one OLED text line. Backspace and DEL erase.
// Characters past 21 are dropped rather than wrapping.
//
// There is no character echo: a terminal that wants to show what you type
// should echo locally. Echoing here would mean arbitrating the transmitter
// against the button and banner messages for no real gain.

module uart_console #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer BAUD    = 115200,
    parameter [7:0]   HOST_ID = 8'd1,
    parameter integer MSG_LEN = 21
) (
    input  wire       clk,
    input  wire       rst,

    input  wire [3:0] keys,          // debounced, active high
    input  wire       keys_changed,  // 1-cycle pulse

    input  wire [4:0] msg_rd_addr,
    output wire [7:0] msg_rd_data,
    output reg        msg_updated,   // 1-cycle pulse when a line completes

    input  wire       uart_rx_pin,
    output wire       uart_tx_pin
);

    // ------------------------------------------------------------------
    // PHY
    // ------------------------------------------------------------------
    reg  [7:0] tx_data;
    reg        tx_valid;
    wire       tx_ready;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx(uart_tx_pin)
    );

    wire [7:0] rx_data;
    wire       rx_valid, rx_err;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst),
        .rx(uart_rx_pin),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_err(rx_err)
    );

    // ------------------------------------------------------------------
    // Received-line buffer
    // ------------------------------------------------------------------
    reg [7:0] msg [0:MSG_LEN-1];
    reg [4:0] wr_idx;
    integer   k;

    assign msg_rd_data = msg[msg_rd_addr];

    wire is_eol   = (rx_data == 8'h0D) || (rx_data == 8'h0A);
    wire is_back  = (rx_data == 8'h08) || (rx_data == 8'h7F);
    wire is_print = (rx_data >= 8'd32) && (rx_data <= 8'd126);

    // ------------------------------------------------------------------
    // Transmit: banner, key state, or line echo
    // ------------------------------------------------------------------
    localparam T_NONE = 2'd0, T_BANNER = 2'd1, T_KEYS = 2'd2, T_ECHO = 2'd3;

    localparam integer BANNER_N = 24;
    localparam integer KEYS_N   = 11;
    localparam integer ECHO_N   = 5 + MSG_LEN + 2;

    reg [7:0] banner [0:BANNER_N-1];
    initial begin
        banner[ 0]="E"; banner[ 1]="P"; banner[ 2]="4"; banner[ 3]="C";
        banner[ 4]="E"; banner[ 5]="6"; banner[ 6]="E"; banner[ 7]="2";
        banner[ 8]="2"; banner[ 9]=" "; banner[10]="n"; banner[11]="o";
        banner[12]="d"; banner[13]="e"; banner[14]=" "; banner[15]="?";
        banner[16]=" "; banner[17]="r"; banner[18]="e"; banner[19]="a";
        banner[20]="d"; banner[21]="y"; banner[22]=8'h0D; banner[23]=8'h0A;
    end

    reg [1:0] cur;
    reg [5:0] sidx;
    reg       req_banner, req_keys, req_echo;

    wire [5:0] cur_len = (cur == T_BANNER) ? BANNER_N[5:0] :
                         (cur == T_KEYS)   ? KEYS_N[5:0]   : ECHO_N[5:0];

    // "KEYS " then one character per button: its number if pressed, '.' if not.
    reg [7:0] keys_byte;
    always @(*) begin
        case (sidx)
            6'd0: keys_byte = "K";
            6'd1: keys_byte = "E";
            6'd2: keys_byte = "Y";
            6'd3: keys_byte = "S";
            6'd4: keys_byte = " ";
            6'd5: keys_byte = keys[0] ? "0" : ".";
            6'd6: keys_byte = keys[1] ? "1" : ".";
            6'd7: keys_byte = keys[2] ? "2" : ".";
            6'd8: keys_byte = keys[3] ? "3" : ".";
            6'd9: keys_byte = 8'h0D;
            default: keys_byte = 8'h0A;
        endcase
    end

    reg [7:0] echo_byte;
    always @(*) begin
        case (sidx)
            6'd0: echo_byte = "M";
            6'd1: echo_byte = "S";
            6'd2: echo_byte = "G";
            6'd3: echo_byte = ":";
            6'd4: echo_byte = " ";
            default:
                if (sidx < 6'd5 + MSG_LEN[5:0]) echo_byte = msg[sidx - 6'd5];
                else if (sidx == 6'd5 + MSG_LEN[5:0]) echo_byte = 8'h0D;
                else echo_byte = 8'h0A;
        endcase
    end

    wire [7:0] send_byte = (cur == T_BANNER) ?
                             ((sidx == 6'd15) ? (8'd64 + HOST_ID) : banner[sidx[4:0]])
                         : (cur == T_KEYS) ? keys_byte : echo_byte;

    always @(posedge clk) begin
        tx_valid    <= 1'b0;
        msg_updated <= 1'b0;

        if (rst) begin
            cur        <= T_NONE;
            sidx       <= 6'd0;
            wr_idx     <= 5'd0;
            req_banner <= 1'b1;          // greet the terminal on power-up
            req_keys   <= 1'b0;
            req_echo   <= 1'b0;
            for (k = 0; k < MSG_LEN; k = k + 1) msg[k] <= 8'h20;
        end else begin

            // ---- receive ------------------------------------------------
            if (rx_valid && !rx_err) begin
                if (is_eol) begin
                    if (wr_idx != 5'd0) begin
                        msg_updated <= 1'b1;
                        req_echo    <= 1'b1;
                        wr_idx      <= 5'd0;
                    end
                end else if (is_back) begin
                    if (wr_idx != 5'd0) begin
                        msg[wr_idx - 5'd1] <= 8'h20;
                        wr_idx             <= wr_idx - 5'd1;
                    end
                end else if (is_print && wr_idx < MSG_LEN[4:0]) begin
                    // First character of a fresh line clears the previous one,
                    // so a short message does not leave the old tail behind.
                    if (wr_idx == 5'd0)
                        for (k = 1; k < MSG_LEN; k = k + 1) msg[k] <= 8'h20;
                    msg[wr_idx] <= rx_data;
                    wr_idx      <= wr_idx + 5'd1;
                end
            end

            if (keys_changed) req_keys <= 1'b1;

            // ---- transmit -----------------------------------------------
            if (cur == T_NONE) begin
                sidx <= 6'd0;
                // Banner first, then a received line, then key state. Key
                // changes are the most frequent and the least urgent.
                if      (req_banner) begin cur <= T_BANNER; req_banner <= 1'b0; end
                else if (req_echo)   begin cur <= T_ECHO;   req_echo   <= 1'b0; end
                else if (req_keys)   begin cur <= T_KEYS;   req_keys   <= 1'b0; end
            end else if (tx_ready && !tx_valid) begin
                tx_data  <= send_byte;
                tx_valid <= 1'b1;
                if (sidx == cur_len - 1) begin
                    cur  <= T_NONE;
                    sidx <= 6'd0;
                end else begin
                    sidx <= sidx + 6'd1;
                end
            end
        end
    end

endmodule
