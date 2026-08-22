// oled_sh1106.v -- 1.3" 128x64 OLED (QG-2864KSWLG01, SH1106G) over I2C.
//
// Text-only: a 4 x 21 character buffer is rendered to display pages 0, 2, 4
// and 6, leaving the odd pages blank so the lines have air between them.
// Glyphs are 5x8 with a one-column gap, so 21 characters span 126 of 128
// columns.
//
// THE SH1106 COLUMN OFFSET
// ------------------------
// The SH1106 has 132 columns of display RAM and the 128-pixel panel is
// centred in it, so panel column 0 is RAM column 2. Every page must therefore
// start at column 0x02, not 0x00. The panel datasheet's own init listing does
// exactly this -- "write_i(0x02); /*set lower column address*/". Get it wrong
// and the image sits two pixels right with the rightmost two columns wrapped
// around to the left edge. This is the most common SH1106 bug, and it is why
// an SSD1306 driver appears to "nearly" work on this panel.
//
// Init values come from the panel datasheet section 4.4, with one deliberate
// change: the charge pump is set to 0x8B (internal DC-DC on) rather than the
// datasheet's 0x8A (external VCC). The datasheet describes the bare panel,
// where VCC is supplied externally; the 4-pin breakout has no external VCC
// pin, so the SH1106 must generate it. 0x8A on a breakout gives a display
// that initialises cleanly and stays dark.
//
// Both memories are read synchronously so they infer M9K blocks. Cyclone IV E
// has no LUT RAM, so an asynchronous read would become flip-flops plus a wide
// mux -- around 700 LEs for the character buffer alone. The FSM stalls on the
// I2C master for tens of microseconds per byte, so a cycle of read latency is
// free.

module oled_sh1106 #(
    parameter integer CLK_HZ    = 50_000_000,
    parameter [6:0]   I2C_ADR   = 7'h3C,           // 0111100b; 0x3D if D/C# high
    parameter integer POR_TICKS = 5_000_000        // 100 ms at 50 MHz
) (
    input  wire       clk,
    input  wire       rst,

    // Character buffer write port. addr = line*21 + column.
    input  wire       txt_we,
    input  wire [6:0] txt_addr,
    input  wire [7:0] txt_char,

    input  wire       refresh,                     // pulse: redraw the panel
    output reg        ready,                       // idle and safe to refresh
    output wire       i2c_err,                     // display did not ACK

    inout  wire       oled_scl,
    inout  wire       oled_sda
);

    localparam integer COLS   = 21;
    localparam [7:0]   ADDR_W = {I2C_ADR, 1'b0};   // write address byte, 0x78

    // ------------------------------------------------------------------
    // I2C master
    // ------------------------------------------------------------------
    reg        c_start, c_write, c_stop;
    reg  [7:0] c_data;
    wire       i2c_busy, i2c_ack_err;

    i2c_master #(.CLK_HZ(CLK_HZ), .I2C_HZ(400_000)) u_i2c (
        .clk(clk), .rst(rst),
        .cmd_start(c_start), .cmd_write(c_write), .cmd_stop(c_stop),
        .wr_data(c_data), .busy(i2c_busy), .ack_err(i2c_ack_err),
        .scl(oled_scl), .sda(oled_sda)
    );

    assign i2c_err = i2c_ack_err;

    // ------------------------------------------------------------------
    // Init sequence (datasheet 4.4, charge pump changed as noted above)
    // ------------------------------------------------------------------
    localparam integer INIT_N = 25;
    reg [7:0] initrom [0:INIT_N-1];
    initial begin
        initrom[ 0] = 8'hAE;                        // display off
        initrom[ 1] = 8'h02;                        // lower column = 2
        initrom[ 2] = 8'h10;                        // higher column = 0
        initrom[ 3] = 8'h40;                        // start line 0
        initrom[ 4] = 8'hB0;                        // page 0
        initrom[ 5] = 8'h81; initrom[ 6] = 8'hBF;   // contrast
        initrom[ 7] = 8'hA1;                        // segment remap
        initrom[ 8] = 8'hA6;                        // normal, not inverted
        initrom[ 9] = 8'hA8; initrom[10] = 8'h3F;   // multiplex 1/64
        initrom[11] = 8'hAD; initrom[12] = 8'h8B;   // charge pump: internal
        initrom[13] = 8'h32;                        // VPP 8 V
        initrom[14] = 8'hC8;                        // COM scan remapped
        initrom[15] = 8'hD3; initrom[16] = 8'h00;   // display offset 0
        initrom[17] = 8'hD5; initrom[18] = 8'h80;   // clock divide / osc
        initrom[19] = 8'hD9; initrom[20] = 8'h22;   // pre-charge
        initrom[21] = 8'hDA; initrom[22] = 8'h12;   // COM pins
        initrom[23] = 8'hDB; initrom[24] = 8'h40;   // VCOMH
    end

    localparam [7:0] CTL_CMD  = 8'h00;   // Co=0, D/C=0 -> command stream
    localparam [7:0] CTL_DATA = 8'h40;   // Co=0, D/C=1 -> data stream

    // ------------------------------------------------------------------
    // Column walk. Kept as counters rather than col/6 and col%6, which would
    // otherwise infer constant dividers.
    // ------------------------------------------------------------------
    reg [7:0] col;        // 0..128, where 128 means "page finished"
    reg [2:0] gcol;       // 0..5 within the character cell
    reg [4:0] cidx;       // 0..20 character index in the line
    reg [2:0] page;       // 0..7

    wire       is_text_page = ~page[0];
    wire [1:0] text_line    = page[2:1];

    // ------------------------------------------------------------------
    // Character buffer and font, both synchronous-read (M9K)
    // ------------------------------------------------------------------
    reg [7:0] textbuf [0:COLS*4-1];
    reg [7:0] tb_q;
    wire [6:0] tb_addr = text_line * COLS + cidx;

    // Start blank rather than relying on M9K powering up to zero. Quartus
    // turns this into the RAM's initial contents; without it the unwritten
    // cells read as X in simulation.
    integer k;
    initial for (k = 0; k < COLS*4; k = k + 1) textbuf[k] = 8'h20;   // space

    always @(posedge clk) begin
        if (txt_we) textbuf[txt_addr] <= txt_char;
        tb_q <= textbuf[tb_addr];
    end

    reg [7:0] font [0:474];
    reg [7:0] font_q;
    initial $readmemh("font5x8.mem", font);

    wire        ch_ok   = (tb_q >= 8'd32) && (tb_q <= 8'd126);
    wire [8:0]  ch_off  = ch_ok ? (tb_q - 8'd32) : 9'd0;
    wire [11:0] f_addr  = ch_off * 5 + gcol;

    always @(posedge clk) font_q <= font[f_addr[8:0]];

    // A byte is blank on odd pages, past the end of the line, in the
    // inter-character gap, or for an unprintable code.
    wire blank = !is_text_page || (cidx >= COLS) || (gcol == 3'd5) || !ch_ok;

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam S_POR      = 4'd0,
               S_I_START  = 4'd1,
               S_I_ADDR   = 4'd2,
               S_I_CTL    = 4'd3,
               S_I_BYTE   = 4'd4,
               S_I_STOP   = 4'd5,
               S_AFTER_I  = 4'd6,
               S_IDLE     = 4'd7,
               S_P_START  = 4'd8,
               S_P_ADDR   = 4'd9,
               S_P_CTL    = 4'd10,
               S_P_CMD    = 4'd11,
               S_P_DSTART = 4'd12,
               S_P_DADDR  = 4'd13,
               S_P_DCTL   = 4'd14,
               S_P_DATA   = 4'd15;

    reg [3:0]  st;
    reg [26:0] delay;
    reg [4:0]  init_i;
    reg [1:0]  cmd_i;
    reg        turn_on;      // this init pass sends 0xAF rather than the table
    reg        clear_pass;   // paint blanks, not text

    wire [7:0] page_cmd = (cmd_i == 2'd0) ? (8'hB0 | {5'd0, page}) :
                          (cmd_i == 2'd1) ? 8'h02 :     // lower col = 2
                                            8'h10;      // higher col = 0

    task reset_walk;
        begin
            page  <= 3'd0;
            col   <= 8'd0;
            gcol  <= 3'd0;
            cidx  <= 5'd0;
            cmd_i <= 2'd0;
        end
    endtask

    always @(posedge clk) begin
        c_start <= 1'b0;
        c_write <= 1'b0;
        c_stop  <= 1'b0;

        if (rst) begin
            st         <= S_POR;
            delay      <= 0;
            init_i     <= 5'd0;
            ready      <= 1'b0;
            turn_on    <= 1'b0;
            clear_pass <= 1'b1;
            reset_walk;
        end else begin
            case (st)
                S_POR:
                    if (delay == POR_TICKS) begin
                        delay <= 0;
                        st    <= S_I_START;
                    end else delay <= delay + 1'b1;

                S_I_START:
                    if (!i2c_busy) begin c_start <= 1'b1; st <= S_I_ADDR; end

                S_I_ADDR:
                    if (!i2c_busy && !c_start) begin
                        c_data <= ADDR_W; c_write <= 1'b1; st <= S_I_CTL;
                    end

                S_I_CTL:
                    if (!i2c_busy && !c_write) begin
                        c_data <= CTL_CMD; c_write <= 1'b1; st <= S_I_BYTE;
                    end

                S_I_BYTE:
                    if (!i2c_busy && !c_write) begin
                        if (turn_on) begin
                            c_data  <= 8'hAF;               // display on
                            c_write <= 1'b1;
                            st      <= S_I_STOP;
                        end else if (init_i == INIT_N) begin
                            st <= S_I_STOP;
                        end else begin
                            c_data  <= initrom[init_i];
                            c_write <= 1'b1;
                            init_i  <= init_i + 5'd1;
                        end
                    end

                S_I_STOP:
                    if (!i2c_busy && !c_write) begin c_stop <= 1'b1; st <= S_AFTER_I; end

                // Datasheet order: initialise, clear the RAM, then switch the
                // panel on -- so power-up noise is never displayed.
                S_AFTER_I:
                    if (!i2c_busy && !c_stop) begin
                        if (turn_on) begin
                            ready <= 1'b1;
                            st    <= S_IDLE;
                        end else begin
                            reset_walk;
                            st <= S_P_START;
                        end
                    end

                S_IDLE:
                    if (refresh && !i2c_busy) begin
                        ready <= 1'b0;
                        reset_walk;
                        st <= S_P_START;
                    end

                S_P_START:
                    if (!i2c_busy) begin c_start <= 1'b1; st <= S_P_ADDR; end

                S_P_ADDR:
                    if (!i2c_busy && !c_start) begin
                        c_data <= ADDR_W; c_write <= 1'b1; st <= S_P_CTL;
                    end

                S_P_CTL:
                    if (!i2c_busy && !c_write) begin
                        c_data <= CTL_CMD; c_write <= 1'b1; st <= S_P_CMD;
                    end

                S_P_CMD:
                    if (!i2c_busy && !c_write) begin
                        c_data  <= page_cmd;
                        c_write <= 1'b1;
                        if (cmd_i == 2'd2) begin cmd_i <= 2'd0; st <= S_P_DSTART; end
                        else                      cmd_i <= cmd_i + 2'd1;
                    end

                // Repeated START to switch from the command to the data stream.
                S_P_DSTART:
                    if (!i2c_busy && !c_write) begin c_start <= 1'b1; st <= S_P_DADDR; end

                S_P_DADDR:
                    if (!i2c_busy && !c_start) begin
                        c_data <= ADDR_W; c_write <= 1'b1; st <= S_P_DCTL;
                    end

                S_P_DCTL:
                    if (!i2c_busy && !c_write) begin
                        c_data <= CTL_DATA; c_write <= 1'b1; st <= S_P_DATA;
                    end

                S_P_DATA:
                    if (!i2c_busy && !c_write) begin
                        if (col == 8'd128) begin
                            c_stop <= 1'b1;
                            col    <= 8'd0;
                            gcol   <= 3'd0;
                            cidx   <= 5'd0;
                            if (page == 3'd7) begin
                                page <= 3'd0;
                                if (clear_pass) begin
                                    clear_pass <= 1'b0;
                                    turn_on    <= 1'b1;
                                    st         <= S_I_START;   // now send 0xAF
                                end else begin
                                    ready <= 1'b1;
                                    st    <= S_IDLE;
                                end
                            end else begin
                                page <= page + 3'd1;
                                st   <= S_P_START;
                            end
                        end else begin
                            c_data  <= (clear_pass || blank) ? 8'h00 : font_q;
                            c_write <= 1'b1;
                            col     <= col + 8'd1;
                            if (gcol == 3'd5) begin
                                gcol <= 3'd0;
                                cidx <= cidx + 5'd1;
                            end else begin
                                gcol <= gcol + 3'd1;
                            end
                        end
                    end

                default: st <= S_POR;
            endcase
        end
    end

endmodule
