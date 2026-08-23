// net_stack.v -- M3: ARP responder over the ENC28J60's SPI/buffer interface.
//
// Scope, deliberately: ARP only. ICMP echo is the next increment once ARP is
// confirmed on real hardware. This project has no ENC28J60 datasheet (unlike
// the OLED's), and M2 already found two real register-level mistakes from
// memory alone; ARP is the smaller, fixed-length, checksum-free half of "make
// ping work" and is a complete, independently useful, independently testable
// step on its own -- a working ARP responder turns `ping` from "Destination
// host unreachable" (ARP never resolves) into "Request timed out" (ARP
// resolves, ICMP doesn't reply yet), which is a real, observable improvement.
//
// Strategy: mirror-and-patch rather than synthesize from scratch. An ARP
// reply is the request with six fields swapped/changed and everything else
// copied -- so this reads the request byte-by-byte via RBM, capturing only
// the ~10 bytes of state actually needed (the sender's MAC and IP), then
// writes a reply byte-by-byte via WBM, selecting each byte from a small case
// statement fed by those captured values or fixed constants. No frame is
// held in local memory in full.
//
// This module takes over the SPI bus entirely once `start` pulses (which
// eth_top asserts once after its own M1/M2 sequence finishes) -- one owner
// at a time, no arbitration logic needed.

module net_stack #(
    parameter [47:0] OUR_MAC = 48'h02_42_CE_60_00_01,   // 02:42:CE:60:00:01
    parameter [31:0] OUR_IP  = 32'hC0_A8_01_3C          // 192.168.1.60
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,          // 1-cycle pulse: begin operating

    // Shared SPI bus -- this module owns it completely once `start` fires.
    output reg         cs_n,
    output reg         spi_start,
    output reg  [7:0]  spi_tx,
    input  wire [7:0]  spi_rx,
    input  wire        spi_busy,

    // Diagnostics (all level/sticky, read by uart_console)
    output reg  [15:0] frames_seen,
    output reg  [15:0] arp_replies_sent
);

    // ------------------------------------------------------------------
    // Opcodes / addresses. Same "widely-documented, not datasheet-verified"
    // caveat as eth_top.v's M2 table -- real hardware is the actual proof.
    // ------------------------------------------------------------------
    function [7:0] WCR(input [4:0] a); WCR = {3'b010, a}; endfunction
    function [7:0] RCR(input [4:0] a); RCR = {3'b000, a}; endfunction
    localparam [7:0] OP_RBM = 8'h3A;     // fixed opcode, no address field
    localparam [7:0] OP_WBM = 8'h7A;

    localparam [4:0] A_ECON1   = 5'h1F, A_ECON2 = 5'h1E;   // common
    localparam [4:0] A_ERDPTL  = 5'h00, A_ERDPTH = 5'h01;  // bank 0
    localparam [4:0] A_EWRPTL  = 5'h02, A_EWRPTH = 5'h03;
    localparam [4:0] A_ETXNDL  = 5'h06, A_ETXNDH = 5'h07;
    localparam [4:0] A_ERXRDPTL= 5'h0C, A_ERXRDPTH= 5'h0D;
    localparam [4:0] A_EPKTCNT = 5'h19;                    // bank 1

    localparam [15:0] ERXST = 16'h0000, ERXND = 16'h19FF, ETXST = 16'h1A00;
    // Control byte (1) + 42-byte ARP reply = 43 bytes; ETXND is inclusive of
    // the last byte written, so ETXST + 43 - 1.
    localparam [15:0] ARP_ETXND = ETXST + 16'd42;

    // ------------------------------------------------------------------
    // Bit-banged SPI transaction primitives, matching eth_top's M1/M2 style.
    // ------------------------------------------------------------------
    reg        spi_busy_d;
    wire       spi_done = spi_busy_d & ~spi_busy;
    always @(posedge clk) spi_busy_d <= spi_busy;

    // ------------------------------------------------------------------
    // ARP frame layout (offsets from the start of the Ethernet frame, as
    // delivered by RBM right after the 6-byte per-packet RX header):
    //   0-5   dest MAC   6-11  src MAC        12-13 EtherType (0x0806=ARP)
    //   14-15 HTYPE(=1)  16-17 PTYPE(=0x0800) 18 HLEN(=6)    19 PLEN(=4)
    //   20-21 OPER (1=request, 2=reply)
    //   22-27 SHA (sender MAC)   28-31 SPA (sender IP)
    //   32-37 THA (target MAC)  38-41 TPA (target IP)
    // A reply mirrors the request with: dest MAC <- SHA, src MAC <- ours,
    // OPER <- 2, SHA <- ours, SPA <- ours, THA <- old SHA, TPA <- old SPA.
    // ------------------------------------------------------------------
    reg [47:0] sender_mac;
    reg [31:0] sender_ip, target_ip;
    reg [15:0] next_rdpt;      // where the next RX packet's header begins
    reg [15:0] cur_next_ptr;   // this packet's own "next packet" field
    reg [5:0]  rxpos;          // 0..41, byte offset within the ARP frame
    reg [5:0]  txpos;
    reg [7:0]  hdr_byte_idx;   // 0..5, the 6-byte per-packet RX header
    reg        is_arp, is_request, target_is_us;

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam S_INIT0      = 5'd0,  S_INIT1      = 5'd1,
               S_POLL       = 5'd2,  S_POLL_WAIT  = 5'd3,  S_POLL_CHECK = 5'd4,
               S_SETRDPT0   = 5'd5,  S_SETRDPT1   = 5'd6,  S_SETRDPT2   = 5'd7,
               S_RBM_OP     = 5'd8,  S_RBM_OPWAIT = 5'd9,
               S_RBM_HDR_GO = 5'd10, S_RBM_HDR_WT = 5'd11,
               S_RBM_BOD_GO = 5'd12, S_RBM_BOD_WT = 5'd13,
               S_TX_BANK    = 5'd14, S_SETWRPT0   = 5'd15, S_SETWRPT1   = 5'd16,
               S_WBM_OP     = 5'd17, S_WBM_OPWAIT = 5'd18,
               S_WBM_BOD_GO = 5'd19, S_WBM_BOD_WT = 5'd20,
               S_SETETXND0  = 5'd21, S_SETETXND1  = 5'd22,
               S_TXRTS      = 5'd23, S_TXWAIT     = 5'd24,
               S_CLEANUP0   = 5'd25, S_CLEANUP1   = 5'd26, S_CLEANUP2   = 5'd27,
               S_CLEANUP3   = 5'd28, S_CLEANUP4   = 5'd29,
               S_WCR_OP     = 5'd30, S_WCR_DATA   = 5'd31; // generic 1-shot WCR

    reg [4:0]  state, ret_state;    // ret_state: where the generic WCR returns to
    reg [4:0]  wcr_addr;
    reg [7:0]  wcr_data;
    reg [26:0] wait_cnt;

    // One TX byte, addressed by txpos, for the 42-byte ARP reply (43 with
    // the leading per-packet control byte handled separately in S_WBM_OP).
    function [7:0] arp_reply_byte(input [5:0] p);
        begin
            case (p)
                // dest MAC = sender's MAC (SHA from the request)
                6'd0: arp_reply_byte = sender_mac[47:40];
                6'd1: arp_reply_byte = sender_mac[39:32];
                6'd2: arp_reply_byte = sender_mac[31:24];
                6'd3: arp_reply_byte = sender_mac[23:16];
                6'd4: arp_reply_byte = sender_mac[15:8];
                6'd5: arp_reply_byte = sender_mac[7:0];
                // src MAC = ours
                6'd6:  arp_reply_byte = OUR_MAC[47:40];
                6'd7:  arp_reply_byte = OUR_MAC[39:32];
                6'd8:  arp_reply_byte = OUR_MAC[31:24];
                6'd9:  arp_reply_byte = OUR_MAC[23:16];
                6'd10: arp_reply_byte = OUR_MAC[15:8];
                6'd11: arp_reply_byte = OUR_MAC[7:0];
                6'd12: arp_reply_byte = 8'h08;  // EtherType 0x0806
                6'd13: arp_reply_byte = 8'h06;
                6'd14: arp_reply_byte = 8'h00;  // HTYPE 0x0001
                6'd15: arp_reply_byte = 8'h01;
                6'd16: arp_reply_byte = 8'h08;  // PTYPE 0x0800
                6'd17: arp_reply_byte = 8'h00;
                6'd18: arp_reply_byte = 8'h06;  // HLEN
                6'd19: arp_reply_byte = 8'h04;  // PLEN
                6'd20: arp_reply_byte = 8'h00;  // OPER = 2 (reply)
                6'd21: arp_reply_byte = 8'h02;
                // SHA = ours
                6'd22: arp_reply_byte = OUR_MAC[47:40];
                6'd23: arp_reply_byte = OUR_MAC[39:32];
                6'd24: arp_reply_byte = OUR_MAC[31:24];
                6'd25: arp_reply_byte = OUR_MAC[23:16];
                6'd26: arp_reply_byte = OUR_MAC[15:8];
                6'd27: arp_reply_byte = OUR_MAC[7:0];
                // SPA = ours
                6'd28: arp_reply_byte = OUR_IP[31:24];
                6'd29: arp_reply_byte = OUR_IP[23:16];
                6'd30: arp_reply_byte = OUR_IP[15:8];
                6'd31: arp_reply_byte = OUR_IP[7:0];
                // THA = sender's MAC (mirrors the request's SHA)
                6'd32: arp_reply_byte = sender_mac[47:40];
                6'd33: arp_reply_byte = sender_mac[39:32];
                6'd34: arp_reply_byte = sender_mac[31:24];
                6'd35: arp_reply_byte = sender_mac[23:16];
                6'd36: arp_reply_byte = sender_mac[15:8];
                6'd37: arp_reply_byte = sender_mac[7:0];
                // TPA = sender's IP (mirrors the request's SPA)
                6'd38: arp_reply_byte = sender_ip[31:24];
                6'd39: arp_reply_byte = sender_ip[23:16];
                6'd40: arp_reply_byte = sender_ip[15:8];
                default: arp_reply_byte = sender_ip[7:0];   // 41
            endcase
        end
    endfunction

    // Where ERXRDPT must point after freeing this packet's buffer space.
    // Documented ENC28J60 workaround: one less than the next-packet pointer,
    // unless that pointer is the start of the buffer, in which case use the
    // end instead (avoids ERXRDPT ever landing one before ERXST).
    wire [15:0] next_erxrdpt = (cur_next_ptr == ERXST) ? ERXND : (cur_next_ptr - 16'd1);

    always @(posedge clk) begin
        spi_start <= 1'b0;

        if (rst) begin
            state            <= S_INIT0;
            cs_n             <= 1'b1;
            next_rdpt        <= ERXST;
            wait_cnt         <= 0;
            frames_seen      <= 16'd0;
            arp_replies_sent <= 16'd0;
        end else if (!start && state == S_INIT0) begin
            // idle until eth_top hands off the bus
        end else begin
            case (state)
                // ---- one-time: AUTOINC on, prepare to poll bank 1 ----
                S_INIT0: begin
                    wcr_addr   <= A_ECON2; wcr_data <= 8'h80;   // AUTOINC=1
                    ret_state  <= S_INIT1;
                    state      <= S_WCR_OP;
                end
                S_INIT1: begin
                    wcr_addr  <= A_ECON1; wcr_data <= 8'h05;    // bank1, RXEN=1
                    ret_state <= S_POLL;
                    state     <= S_WCR_OP;
                end
                // ---- poll EPKTCNT ----
                S_POLL: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= RCR(A_EPKTCNT);
                    spi_start <= 1'b1;
                    state     <= S_POLL_WAIT;
                end
                S_POLL_WAIT:
                    if (spi_done) begin
                        if (spi_tx == RCR(A_EPKTCNT)) begin
                            spi_tx <= 8'h00; spi_start <= 1'b1;   // clock in count
                        end else begin
                            cs_n  <= 1'b1;
                            state <= S_POLL_CHECK;
                        end
                    end
                S_POLL_CHECK:
                    if (spi_rx == 8'h00) begin
                        wait_cnt <= 0;
                        state    <= S_POLL;   // nothing waiting, poll again
                    end else begin
                        state <= S_SETRDPT0;
                    end

                // ---- point ERDPT at this packet's header ----
                S_SETRDPT0: begin
                    wcr_addr  <= A_ECON1; wcr_data <= 8'h00;    // bank 0
                    ret_state <= S_SETRDPT1;
                    state     <= S_WCR_OP;
                end
                S_SETRDPT1: begin
                    wcr_addr  <= A_ERDPTL; wcr_data <= next_rdpt[7:0];
                    ret_state <= S_SETRDPT2;
                    state     <= S_WCR_OP;
                end
                S_SETRDPT2: begin
                    wcr_addr  <= A_ERDPTH; wcr_data <= next_rdpt[15:8];
                    ret_state <= S_RBM_OP;
                    state     <= S_WCR_OP;
                end

                // ---- stream the packet in via RBM ----
                S_RBM_OP: begin
                    cs_n         <= 1'b0;
                    spi_tx       <= OP_RBM;
                    spi_start    <= 1'b1;
                    hdr_byte_idx <= 8'd0;
                    rxpos        <= 6'd0;
                    is_arp       <= 1'b0;
                    is_request   <= 1'b0;
                    target_is_us <= 1'b0;
                    state        <= S_RBM_OPWAIT;
                end
                // The opcode byte's own reply is meaningless (RBM is a fixed
                // opcode, not a register address+data pair) -- just wait for
                // it to finish, then start clocking real header bytes.
                S_RBM_OPWAIT:
                    if (spi_done) state <= S_RBM_HDR_GO;

                // 6-byte per-packet RX header: bytes 0-1 = next packet
                // pointer (little-endian), bytes 2-5 = receive status
                // vector (byte count + flags) -- not otherwise inspected;
                // the MAC filter already limits us to CRC-valid unicast and
                // broadcast frames. Each byte is its own issue/wait pair,
                // the same pattern as the WCR helper below.
                S_RBM_HDR_GO: begin
                    spi_tx <= 8'h00; spi_start <= 1'b1;
                    state  <= S_RBM_HDR_WT;
                end
                S_RBM_HDR_WT:
                    if (spi_done) begin
                        case (hdr_byte_idx)
                            8'd0: cur_next_ptr[7:0]  <= spi_rx;
                            8'd1: cur_next_ptr[15:8] <= spi_rx;
                            default: ; // status vector bytes, unused
                        endcase
                        if (hdr_byte_idx == 8'd5) begin
                            hdr_byte_idx <= 8'd0;
                            state        <= S_RBM_BOD_GO;
                        end else begin
                            hdr_byte_idx <= hdr_byte_idx + 8'd1;
                            state        <= S_RBM_HDR_GO;
                        end
                    end

                // The Ethernet+ARP frame itself, byte by byte. Abandons
                // early (jumps to cleanup) as soon as it is clearly not an
                // ARP request for us -- no need to read bytes we will not
                // use, and every frame still needs the cleanup step either
                // way, regardless of whether we respond to it.
                S_RBM_BOD_GO: begin
                    spi_tx <= 8'h00; spi_start <= 1'b1;
                    state  <= S_RBM_BOD_WT;
                end
                S_RBM_BOD_WT:
                    if (spi_done) begin
                        case (rxpos)
                            6'd12: is_arp <= (spi_rx == 8'h08);
                            6'd21: is_request <= (spi_rx == 8'h01);
                            6'd22: sender_mac[47:40] <= spi_rx;
                            6'd23: sender_mac[39:32] <= spi_rx;
                            6'd24: sender_mac[31:24] <= spi_rx;
                            6'd25: sender_mac[23:16] <= spi_rx;
                            6'd26: sender_mac[15:8]  <= spi_rx;
                            6'd27: sender_mac[7:0]   <= spi_rx;
                            6'd28: sender_ip[31:24]  <= spi_rx;
                            6'd29: sender_ip[23:16]  <= spi_rx;
                            6'd30: sender_ip[15:8]   <= spi_rx;
                            6'd31: sender_ip[7:0]    <= spi_rx;
                            6'd38: target_ip[31:24]  <= spi_rx;
                            6'd39: target_ip[23:16]  <= spi_rx;
                            6'd40: target_ip[15:8]   <= spi_rx;
                            6'd41: target_ip[7:0]    <= spi_rx;
                            default: ;
                        endcase

                        // Not ARP: stop reading, nothing more to learn.
                        if (rxpos == 6'd13 && !(is_arp && spi_rx == 8'h06)) begin
                            cs_n  <= 1'b1;
                            state <= S_CLEANUP0;
                        end else if (rxpos == 6'd41) begin
                            target_is_us <= ({target_ip[31:8], spi_rx} == OUR_IP);
                            cs_n         <= 1'b1;
                            state        <= S_CLEANUP0;
                        end else begin
                            rxpos <= rxpos + 6'd1;
                            state <= S_RBM_BOD_GO;
                        end
                    end

                // ---- cleanup: always run, then branch to TX if warranted ----
                S_CLEANUP0: begin
                    cs_n <= 1'b1;
                    // Decide whether to reply *before* touching ECON1/ERXRDPT,
                    // so the branch below always lands correctly.
                    if (is_arp && is_request && target_is_us) begin
                        state <= S_TX_BANK;
                    end else begin
                        state <= S_CLEANUP1;
                    end
                end

                // ---- ARP reply: switch to bank 0, point EWRPT at TX start ----
                S_TX_BANK: begin
                    wcr_addr  <= A_ECON1; wcr_data <= 8'h00;    // bank 0
                    ret_state <= S_SETWRPT0;
                    state     <= S_WCR_OP;
                end
                S_SETWRPT0: begin
                    wcr_addr  <= A_EWRPTL; wcr_data <= ETXST[7:0];
                    ret_state <= S_SETWRPT1;
                    state     <= S_WCR_OP;
                end
                S_SETWRPT1: begin
                    wcr_addr  <= A_EWRPTH; wcr_data <= ETXST[15:8];
                    ret_state <= S_WBM_OP;
                    state     <= S_WCR_OP;
                end

                S_WBM_OP: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= OP_WBM;
                    spi_start <= 1'b1;
                    txpos     <= 6'd0;
                    state     <= S_WBM_OPWAIT;
                end
                S_WBM_OPWAIT:
                    if (spi_done) state <= S_WBM_BOD_GO;

                // Byte 0 of the write is the per-packet control byte (0x00:
                // defer padding/CRC to MACON3, which M2 already configured
                // to add both). Bytes 1..42 are the 42-byte ARP reply.
                S_WBM_BOD_GO: begin
                    spi_tx    <= (txpos == 6'd0) ? 8'h00 : arp_reply_byte(txpos - 6'd1);
                    spi_start <= 1'b1;
                    state     <= S_WBM_BOD_WT;
                end
                S_WBM_BOD_WT:
                    if (spi_done) begin
                        if (txpos == 6'd42) begin
                            cs_n  <= 1'b1;
                            state <= S_SETETXND0;
                        end else begin
                            txpos <= txpos + 6'd1;
                            state <= S_WBM_BOD_GO;
                        end
                    end

                S_SETETXND0: begin
                    wcr_addr  <= A_ETXNDL; wcr_data <= ARP_ETXND[7:0];
                    ret_state <= S_SETETXND1;
                    state     <= S_WCR_OP;
                end
                S_SETETXND1: begin
                    wcr_addr  <= A_ETXNDH; wcr_data <= ARP_ETXND[15:8];
                    ret_state <= S_TXRTS;
                    state     <= S_WCR_OP;
                end

                S_TXRTS: begin
                    // bank 0, RXEN=1, TXRTS=1
                    wcr_addr  <= A_ECON1; wcr_data <= 8'h0C;
                    ret_state <= S_TXWAIT;
                    state     <= S_WCR_OP;
                end
                S_TXWAIT:
                    // Fixed conservative delay rather than polling TXRTS --
                    // fewer register reads, fewer chances to hit another
                    // untested protocol edge case. 42 bytes at 10 Mbit half
                    // duplex is ~34 us; 500 us at 50 MHz is comfortable.
                    if (wait_cnt == 27'd25_000) begin
                        wait_cnt         <= 0;
                        arp_replies_sent <= arp_replies_sent + 16'd1;
                        state            <= S_CLEANUP1;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end

                // ---- free the RX buffer space, decrement EPKTCNT ----
                S_CLEANUP1: begin
                    wcr_addr  <= A_ECON1; wcr_data <= 8'h00;    // bank 0
                    ret_state <= S_CLEANUP2;
                    state     <= S_WCR_OP;
                end
                S_CLEANUP2: begin
                    wcr_addr  <= A_ERXRDPTL; wcr_data <= next_erxrdpt[7:0];
                    ret_state <= S_CLEANUP3;
                    state     <= S_WCR_OP;
                end
                S_CLEANUP3: begin
                    wcr_addr  <= A_ERXRDPTH; wcr_data <= next_erxrdpt[15:8];
                    ret_state <= S_CLEANUP4;
                    state     <= S_WCR_OP;
                end
                // Buffer space freed; now decrement EPKTCNT and advance the
                // bookkeeping pointer before polling for the next packet.
                // ret_state is S_INIT1, not S_POLL directly: S_CLEANUP1 left
                // ECON1 on bank 0 (for the ERXRDPT writes above), and S_POLL
                // reads EPKTCNT assuming bank 1 is already selected. S_INIT1
                // already does exactly "select bank 1, then go poll" -- reuse
                // it here instead of adding a new state just to repeat it.
                S_CLEANUP4: begin
                    next_rdpt   <= cur_next_ptr;
                    frames_seen <= frames_seen + 16'd1;
                    wcr_addr    <= A_ECON2; wcr_data <= 8'hC0;   // AUTOINC + PKTDEC
                    ret_state   <= S_INIT1;
                    state       <= S_WCR_OP;
                end

                // ---- generic single WCR, returns to ret_state ----
                S_WCR_OP: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= WCR(wcr_addr);
                    spi_start <= 1'b1;
                    state     <= S_WCR_DATA;
                end
                S_WCR_DATA:
                    if (spi_done) begin
                        if (spi_tx == WCR(wcr_addr)) begin
                            spi_tx <= wcr_data; spi_start <= 1'b1;
                        end else begin
                            cs_n  <= 1'b1;
                            state <= ret_state;
                        end
                    end

                default: state <= S_INIT0;
            endcase
        end
    end

endmodule
