// uart_console.v -- serial console on the board's CH340 port.
//
// Transmits:
//   * a banner once at reset               "EP4CE6E22 node A ready"
//   * a line whenever a button changes     "KEYS 0.2."
//   * an echo whenever a line is received  "MSG: hello world"
//   * "OLED READY" once, when oled_ready first asserts (proves the driver
//     FSM completed init+clear -- this fires regardless of whether the
//     display actually acked anything, since the FSM does not gate on it)
//   * "OLED I2C NACK" once, if oled_nack is ever seen (the OLED never ACKed
//     an I2C byte -- almost always wiring, power, or address, not logic)
//   * "ETH C1=xx" once, when eth_ready first asserts -- the M2 link/MAC init
//     readback of ECON1 (confirms RXEN got set). MACON1/MACON3 readback was
//     tried and dropped: this project has no ENC28J60 datasheet, and two
//     different guesses at the MAC-register SPI read protocol both produced
//     wrong values on real hardware -- see eth_top.v's cfg_op comment. ECON1
//     is an Ethernet-type/common register with no such ambiguity and has
//     read back correctly against real hardware every time.
//   * "NET F=xxxx R=xxxx" every time net_frames or net_replies changes --
//     M3's frame/ARP-reply counters. Lets a `ping` failure be isolated by
//     eye instead of guessed at: F stuck at 0 means the ENC28J60 never saw a
//     frame at all (link/physical problem, or the MAC filter is rejecting
//     everything); F increments but R doesn't mean frames arrive but aren't
//     recognised as an ARP request for us; R increments but ping still fails
//     means the reply is being sent but not reaching the PC (duplex, switch,
//     or wiring on the return path).
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

    // Second, independent read port into the same buffer -- for M4's UDP
    // send path (net_stack), so it can stream the just-completed line out
    // over SPI without contending with the OLED writer's own read port
    // above, which addresses the same buffer on its own schedule.
    input  wire [4:0] tx_rd_addr,
    output wire [7:0] tx_rd_data,

    input  wire       oled_ready,    // OLED driver FSM finished init + clear
    input  wire       oled_nack,     // OLED never ACKed an I2C byte (sticky)

    input  wire       eth_ready,     // M2 link/MAC init complete
    input  wire [7:0] eth_econ1,     // ECON1 readback after RXEN set

    input  wire [15:0] net_frames,   // M3: frames seen by net_stack
    input  wire [15:0] net_replies,  // M3: ARP replies sent
    input  wire [7:0]  net_eir,      // EIR readback after the last TX attempt
    input  wire [7:0]  net_estat,    // ESTAT readback after the last TX attempt
    input  wire [15:0] net_arpreqs,  // frames parsed as an ARP request
    input  wire [15:0] net_etype,    // EtherType of the last frame walked
    input  wire [15:0] net_resyncs,  // RX pointer-chain rebuilds
    input  wire [15:0] build_id,     // bitstream identity, echoed on the ID line
    input  wire [15:0] net_polls,    // EPKTCNT polls completed (liveness)
    input  wire [7:0]  net_pktcnt,   // EPKTCNT value the last poll read
    input  wire [15:0] net_tsvcount, // transmit status vector: byte count
    input  wire [15:0] net_tsvwire,  //   "  bytes actually put on the wire
    input  wire [7:0]  net_tsvs2,    //   "  done/CRC/length/collision-count
    input  wire [7:0]  net_tsvs3,    //   "  defer/excess-coll/giant/underrun

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
    assign tx_rd_data  = msg[tx_rd_addr];

    wire is_eol   = (rx_data == 8'h0D) || (rx_data == 8'h0A);
    wire is_back  = (rx_data == 8'h08) || (rx_data == 8'h7F);
    wire is_print = (rx_data >= 8'd32) && (rx_data <= 8'd126);

    // ------------------------------------------------------------------
    // Transmit: banner, key state, or line echo
    // ------------------------------------------------------------------
    localparam T_NONE     = 4'd0, T_BANNER   = 4'd1, T_KEYS = 4'd2, T_ECHO = 4'd3,
               T_OLED_RDY = 4'd4, T_OLED_ERR = 4'd5, T_ETH = 4'd6, T_NET = 4'd7,
               T_TSV      = 4'd8, T_ID       = 4'd9;

    localparam integer BANNER_N   = 24;
    localparam integer KEYS_N     = 11;
    localparam integer ECHO_N     = 5 + MSG_LEN + 2;
    localparam integer OLED_RDY_N = 12;   // "OLED READY\r\n"
    localparam integer OLED_ERR_N = 15;   // "OLED I2C NACK\r\n"
    localparam integer ETH_N      = 11;   // "ETH C1=xx\r\n"
    localparam integer NET_N      = 62;   // "NET F=... R=... E=.. S=.. A=... T=... X=... P=xxxx K=xx\r\n"

    localparam integer TSV_N      = 31;   // TSV n=xxxx w=xxxx s2=xx s3=xx + CRLF
    // "ID HOST=A BLD=xxxx\r\n" -- emitted every ~2.7 s so a tool can identify
    // the board by listening alone: no reset (which would lose the run's
    // state), no keystroke (which would collide with the typed-message
    // feature), and no dependence on catching the power-on banner.
    localparam integer ID_N       = 20;

    function [7:0] hexdig(input [3:0] n);
        hexdig = (n < 4'd10) ? (8'h30 + n) : (8'h41 + n - 4'd10);
    endfunction

    reg [7:0] banner [0:BANNER_N-1];
    initial begin
        banner[ 0]="E"; banner[ 1]="P"; banner[ 2]="4"; banner[ 3]="C";
        banner[ 4]="E"; banner[ 5]="6"; banner[ 6]="E"; banner[ 7]="2";
        banner[ 8]="2"; banner[ 9]=" "; banner[10]="n"; banner[11]="o";
        banner[12]="d"; banner[13]="e"; banner[14]=" "; banner[15]="?";
        banner[16]=" "; banner[17]="r"; banner[18]="e"; banner[19]="a";
        banner[20]="d"; banner[21]="y"; banner[22]=8'h0D; banner[23]=8'h0A;
    end

    reg [7:0] id_msg [0:ID_N-1];
    initial begin
        id_msg[ 0]="I"; id_msg[ 1]="D"; id_msg[ 2]=" ";
        id_msg[ 3]="H"; id_msg[ 4]="O"; id_msg[ 5]="S"; id_msg[ 6]="T"; id_msg[ 7]="=";
        id_msg[ 8]="?";                                  // patched: A or B
        id_msg[ 9]=" ";
        id_msg[10]="B"; id_msg[11]="L"; id_msg[12]="D"; id_msg[13]="=";
        id_msg[14]="?"; id_msg[15]="?"; id_msg[16]="?"; id_msg[17]="?";
        id_msg[18]=8'h0D; id_msg[19]=8'h0A;
    end

    reg [7:0] oled_rdy_msg [0:OLED_RDY_N-1];
    reg [7:0] oled_err_msg [0:OLED_ERR_N-1];
    initial begin
        oled_rdy_msg[ 0]="O"; oled_rdy_msg[ 1]="L"; oled_rdy_msg[ 2]="E"; oled_rdy_msg[ 3]="D";
        oled_rdy_msg[ 4]=" "; oled_rdy_msg[ 5]="R"; oled_rdy_msg[ 6]="E"; oled_rdy_msg[ 7]="A";
        oled_rdy_msg[ 8]="D"; oled_rdy_msg[ 9]="Y"; oled_rdy_msg[10]=8'h0D; oled_rdy_msg[11]=8'h0A;

        oled_err_msg[ 0]="O"; oled_err_msg[ 1]="L"; oled_err_msg[ 2]="E"; oled_err_msg[ 3]="D";
        oled_err_msg[ 4]=" "; oled_err_msg[ 5]="I"; oled_err_msg[ 6]="2"; oled_err_msg[ 7]="C";
        oled_err_msg[ 8]=" "; oled_err_msg[ 9]="N"; oled_err_msg[10]="A"; oled_err_msg[11]="C";
        oled_err_msg[12]="K"; oled_err_msg[13]=8'h0D; oled_err_msg[14]=8'h0A;
    end

    reg [3:0] cur;
    reg [5:0] sidx;
    reg       req_banner, req_keys, req_echo, req_oled_rdy, req_oled_err, req_eth, req_net;
    reg       req_id;
    reg [2:0] id_div;      // divides the heartbeat down to roughly 2.7 s
    reg       oled_ready_d, oled_nack_d, eth_ready_d;   // for edge detection
    reg [15:0] net_frames_d, net_replies_d, net_arpreqs_d, net_tsvwire_d;

    // Heartbeat, kept local to this module on purpose. Printing only on
    // change makes a wedged node look identical to an idle one -- both just
    // stop emitting. With this the console keeps talking regardless, and the
    // P= field says which it is: still counting, or genuinely stuck.
    // 2^24 cycles at 50 MHz is ~0.34 s.
    reg [23:0] hb_cnt = 24'd0;
    always @(posedge clk) hb_cnt <= hb_cnt + 24'd1;
    reg        req_tsv;

    wire [5:0] cur_len = (cur == T_BANNER)   ? BANNER_N[5:0]   :
                         (cur == T_KEYS)     ? KEYS_N[5:0]     :
                         (cur == T_OLED_RDY) ? OLED_RDY_N[5:0] :
                         (cur == T_OLED_ERR) ? OLED_ERR_N[5:0] :
                         (cur == T_ETH)      ? ETH_N[5:0]      :
                         (cur == T_NET)      ? NET_N[5:0]      :
                         (cur == T_TSV)      ? TSV_N[5:0]      :
                         (cur == T_ID)       ? ID_N[5:0]       :
                                               ECHO_N[5:0];

    // "ETH C1=xx\r\n" -- ECON1 readback as hex.
    reg [7:0] eth_byte;
    always @(*) begin
        case (sidx)
            6'd0: eth_byte = "E";
            6'd1: eth_byte = "T";
            6'd2: eth_byte = "H";
            6'd3: eth_byte = " ";
            6'd4: eth_byte = "C";
            6'd5: eth_byte = "1";
            6'd6: eth_byte = "=";
            6'd7: eth_byte = hexdig(eth_econ1[7:4]);
            6'd8: eth_byte = hexdig(eth_econ1[3:0]);
            6'd9: eth_byte = 8'h0D;
            default: eth_byte = 8'h0A;
        endcase
    end

    // "NET F=xxxx R=xxxx E=xx S=xx\r\n" -- M3's frame/ARP-reply counters,
    // plus the raw EIR/ESTAT bytes read back after the last TX attempt
    // (common/bank-independent registers, same proven RCR protocol as
    // ECON1/EPKTCNT -- real hardware data on whether the ENC28J60 itself
    // believes a transmission succeeded, since net_stack's own TXRTS-and-
    // wait logic never checks).
    reg [7:0] net_byte;
    always @(*) begin
        case (sidx)
            6'd0:  net_byte = "N";
            6'd1:  net_byte = "E";
            6'd2:  net_byte = "T";
            6'd3:  net_byte = " ";
            6'd4:  net_byte = "F";
            6'd5:  net_byte = "=";
            6'd6:  net_byte = hexdig(net_frames[15:12]);
            6'd7:  net_byte = hexdig(net_frames[11:8]);
            6'd8:  net_byte = hexdig(net_frames[7:4]);
            6'd9:  net_byte = hexdig(net_frames[3:0]);
            6'd10: net_byte = " ";
            6'd11: net_byte = "R";
            6'd12: net_byte = "=";
            6'd13: net_byte = hexdig(net_replies[15:12]);
            6'd14: net_byte = hexdig(net_replies[11:8]);
            6'd15: net_byte = hexdig(net_replies[7:4]);
            6'd16: net_byte = hexdig(net_replies[3:0]);
            6'd17: net_byte = " ";
            6'd18: net_byte = "E";
            6'd19: net_byte = "=";
            6'd20: net_byte = hexdig(net_eir[7:4]);
            6'd21: net_byte = hexdig(net_eir[3:0]);
            6'd22: net_byte = " ";
            6'd23: net_byte = "S";
            6'd24: net_byte = "=";
            6'd25: net_byte = hexdig(net_estat[7:4]);
            6'd26: net_byte = hexdig(net_estat[3:0]);
            6'd27: net_byte = " ";
            6'd28: net_byte = "A";
            6'd29: net_byte = "=";
            6'd30: net_byte = hexdig(net_arpreqs[15:12]);
            6'd31: net_byte = hexdig(net_arpreqs[11:8]);
            6'd32: net_byte = hexdig(net_arpreqs[7:4]);
            6'd33: net_byte = hexdig(net_arpreqs[3:0]);
            6'd34: net_byte = " ";
            6'd35: net_byte = "T";
            6'd36: net_byte = "=";
            6'd37: net_byte = hexdig(net_etype[15:12]);
            6'd38: net_byte = hexdig(net_etype[11:8]);
            6'd39: net_byte = hexdig(net_etype[7:4]);
            6'd40: net_byte = hexdig(net_etype[3:0]);
            6'd41: net_byte = " ";
            6'd42: net_byte = "X";
            6'd43: net_byte = "=";
            6'd44: net_byte = hexdig(net_resyncs[15:12]);
            6'd45: net_byte = hexdig(net_resyncs[11:8]);
            6'd46: net_byte = hexdig(net_resyncs[7:4]);
            6'd47: net_byte = hexdig(net_resyncs[3:0]);
            6'd48: net_byte = " ";
            6'd49: net_byte = "P";
            6'd50: net_byte = "=";
            6'd51: net_byte = hexdig(net_polls[15:12]);
            6'd52: net_byte = hexdig(net_polls[11:8]);
            6'd53: net_byte = hexdig(net_polls[7:4]);
            6'd54: net_byte = hexdig(net_polls[3:0]);
            6'd55: net_byte = " ";
            6'd56: net_byte = "K";
            6'd57: net_byte = "=";
            6'd58: net_byte = hexdig(net_pktcnt[7:4]);
            6'd59: net_byte = hexdig(net_pktcnt[3:0]);
            6'd60: net_byte = 8'h0D;
            default: net_byte = 8'h0A;
        endcase
    end

    // TSV line: the part's own account of the last transmission.
    // last transmission. w= is the one that matters most: bytes actually put
    // on the wire.
    reg [7:0] tsv_byte;
    always @(*) begin
        case (sidx)
            6'd0:  tsv_byte = "T";
            6'd1:  tsv_byte = "S";
            6'd2:  tsv_byte = "V";
            6'd3:  tsv_byte = " ";
            6'd4:  tsv_byte = "n";
            6'd5:  tsv_byte = "=";
            6'd6:  tsv_byte = hexdig(net_tsvcount[15:12]);
            6'd7:  tsv_byte = hexdig(net_tsvcount[11:8]);
            6'd8:  tsv_byte = hexdig(net_tsvcount[7:4]);
            6'd9:  tsv_byte = hexdig(net_tsvcount[3:0]);
            6'd10: tsv_byte = " ";
            6'd11: tsv_byte = "w";
            6'd12: tsv_byte = "=";
            6'd13: tsv_byte = hexdig(net_tsvwire[15:12]);
            6'd14: tsv_byte = hexdig(net_tsvwire[11:8]);
            6'd15: tsv_byte = hexdig(net_tsvwire[7:4]);
            6'd16: tsv_byte = hexdig(net_tsvwire[3:0]);
            6'd17: tsv_byte = " ";
            6'd18: tsv_byte = "s";
            6'd19: tsv_byte = "2";
            6'd20: tsv_byte = "=";
            6'd21: tsv_byte = hexdig(net_tsvs2[7:4]);
            6'd22: tsv_byte = hexdig(net_tsvs2[3:0]);
            6'd23: tsv_byte = " ";
            6'd24: tsv_byte = "s";
            6'd25: tsv_byte = "3";
            6'd26: tsv_byte = "=";
            6'd27: tsv_byte = hexdig(net_tsvs3[7:4]);
            6'd28: tsv_byte = hexdig(net_tsvs3[3:0]);
            6'd29: tsv_byte = 8'h0D;
            default: tsv_byte = 8'h0A;
        endcase
    end

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

    wire [7:0] id_byte = (sidx == 6'd8)  ? (8'd64 + HOST_ID)          // 1->"A", 2->"B"
                       : (sidx == 6'd14) ? hexdig(build_id[15:12])
                       : (sidx == 6'd15) ? hexdig(build_id[11:8])
                       : (sidx == 6'd16) ? hexdig(build_id[7:4])
                       : (sidx == 6'd17) ? hexdig(build_id[3:0])
                                         : id_msg[sidx[4:0]];

    wire [7:0] send_byte = (cur == T_BANNER) ?
                             ((sidx == 6'd15) ? (8'd64 + HOST_ID) : banner[sidx[4:0]])
                         : (cur == T_KEYS)     ? keys_byte
                         : (cur == T_OLED_RDY) ? oled_rdy_msg[sidx[3:0]]
                         : (cur == T_OLED_ERR) ? oled_err_msg[sidx[3:0]]
                         : (cur == T_ETH)      ? eth_byte
                         : (cur == T_NET)      ? net_byte
                         : (cur == T_TSV)      ? tsv_byte
                         : (cur == T_ID)       ? id_byte
                                               : echo_byte;

    always @(posedge clk) begin
        tx_valid    <= 1'b0;
        msg_updated <= 1'b0;

        if (rst) begin
            cur          <= T_NONE;
            sidx         <= 6'd0;
            wr_idx       <= 5'd0;
            req_banner   <= 1'b1;          // greet the terminal on power-up
            req_keys     <= 1'b0;
            req_echo     <= 1'b0;
            req_oled_rdy <= 1'b0;
            req_oled_err <= 1'b0;
            req_eth      <= 1'b0;
            req_net      <= 1'b0;
            req_id       <= 1'b1;   // announce identity as soon as the port opens
            id_div       <= 3'd0;
            oled_ready_d <= 1'b0;
            oled_nack_d  <= 1'b0;
            eth_ready_d  <= 1'b0;
            net_frames_d  <= 16'd0;
            net_replies_d <= 16'd0;
            net_arpreqs_d <= 16'd0;
            net_tsvwire_d <= 16'd0;
            req_tsv       <= 1'b0;
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

            // Edge-detect the status lines: each fires exactly once.
            oled_ready_d <= oled_ready;
            oled_nack_d  <= oled_nack;
            eth_ready_d  <= eth_ready;
            if (oled_ready && !oled_ready_d) req_oled_rdy <= 1'b1;
            if (oled_nack  && !oled_nack_d)  req_oled_err <= 1'b1;
            if (eth_ready  && !eth_ready_d)  req_eth      <= 1'b1;

            net_frames_d  <= net_frames;
            net_replies_d <= net_replies;
            net_arpreqs_d <= net_arpreqs;
            net_tsvwire_d <= net_tsvwire;
            // Trigger on a completed transmission, not on the TSV value
            // changing: if the part reports zero bytes on the wire every time,
            // the value never changes and the line would never print -- which
            // is exactly the case we most need to see.
            if (net_replies != net_replies_d) req_tsv <= 1'b1;
            if (net_frames != net_frames_d || net_replies != net_replies_d
                || net_arpreqs != net_arpreqs_d)
                req_net <= 1'b1;
            if (hb_cnt == 24'd0) begin
                req_net <= 1'b1;
                id_div  <= id_div + 3'd1;
                if (id_div == 3'd7) req_id <= 1'b1;
            end

            // ---- transmit -----------------------------------------------
            if (cur == T_NONE) begin
                sidx <= 6'd0;
                // Banner first, then the M2 status (diagnostic, wanted
                // early), then OLED status, then a received line, then key
                // state. Key changes are the most frequent and least urgent.
                if      (req_banner)   begin cur <= T_BANNER;   req_banner   <= 1'b0; end
                else if (req_id)       begin cur <= T_ID;       req_id       <= 1'b0; end
                else if (req_eth)      begin cur <= T_ETH;      req_eth      <= 1'b0; end
                else if (req_net)      begin cur <= T_NET;      req_net      <= 1'b0; end
                else if (req_tsv)      begin cur <= T_TSV;      req_tsv      <= 1'b0; end
                else if (req_oled_rdy) begin cur <= T_OLED_RDY; req_oled_rdy <= 1'b0; end
                else if (req_oled_err) begin cur <= T_OLED_ERR; req_oled_err <= 1'b0; end
                else if (req_echo)     begin cur <= T_ECHO;     req_echo     <= 1'b0; end
                else if (req_keys)     begin cur <= T_KEYS;     req_keys     <= 1'b0; end
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
