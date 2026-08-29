// net_stack.v -- M3 (ARP responder) + M4 (UDP message) over the ENC28J60's
// SPI/buffer interface.
//
// M3 scope, deliberately: ARP only, no ICMP echo -- ARP is the smaller,
// fixed-length, checksum-free half of "make ping work" and independently
// testable on its own. Confirmed on real hardware 2026-08-24 after three
// real bugs: a stale bank-select on re-poll, the documented ENC28J60
// transmit-logic errata (ECON1.TXRST must be pulsed before every TX, not
// just the first), and an unpadded 42-byte ARP reply silently discarded as
// a runt frame by any real switch (Ethernet's minimum is 60 bytes) -- see
// git history for each. ICMP echo remains out of scope.
//
// M4 scope: the project's own "Hello World" demo -- a UDP datagram to port
// 1234 whose payload is exactly uart_console's 21-byte message buffer (the
// same text shown on the OLED), sent whenever a line completes, received
// and displayed by the peer. Deliberately trivial: fixed payload length
// (space-padded, matching the OLED line), UDP checksum left at 0x0000
// (valid per RFC 768 -- zero means "not computed", not "computed as zero"),
// and an IP header checksum computed once at *compile* time (a function
// evaluated over localparams, not runtime hardware) since every field of
// this fixed one-shot packet format is a compile-time constant. No ARP
// client either: the peer's MAC is derived from HOST_ID with the same
// formula OUR_MAC already uses, since there are only ever two hosts.
//
// Strategy for both: mirror-and-patch / build-from-constants rather than a
// general packet engine. Frames are read and written one byte at a time
// over RBM/WBM; nothing is held in local memory in full.
//
// This module takes over the SPI bus entirely once `start` pulses (which
// eth_top asserts once after its own M1/M2 sequence finishes) -- one owner
// at a time, no arbitration logic needed.

module net_stack #(
    parameter [7:0]  HOST_ID = 8'd1,                     // 1 or 2; picks the peer
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

    // M4 TX: uart_console's message buffer, read through its own dedicated
    // port (see uart_console.v) so this never contends with the OLED
    // writer's independent read of the same buffer. send_req is a 1-cycle
    // pulse (uart_console's msg_updated, wired straight through by eth_top)
    // requesting the current buffer be sent as a UDP datagram to the peer.
    output reg  [4:0]  tx_rd_addr,
    input  wire [7:0]  tx_rd_data,
    input  wire        send_req,

    // M4 RX: the last UDP message received from the peer, read through a
    // dedicated port the same way -- eth_top's OLED writer addresses this
    // exactly like it addresses uart_console's own buffer. rx_updated is a
    // 1-cycle pulse each time a new message finishes landing.
    input  wire [4:0]  rx_rd_addr,
    output wire [7:0]  rx_rd_data,
    output reg         rx_updated,

    // Diagnostics (all level/sticky, read by uart_console)
    output reg  [15:0] frames_seen,
    output reg  [15:0] arp_replies_sent,
    // EIR/ESTAT read back right after every TX attempt (both common,
    // bank-independent registers -- same simple immediate-RCR protocol
    // already confirmed correct for ECON1/EPKTCNT, unlike the MAC-type
    // register readback this project gave up on). Raw bytes, deliberately
    // not decoded here: real hardware data to look at while diagnosing why
    // a transmitted ARP reply never reaches the far end despite net_stack's
    // own TXRTS-and-wait logic believing it succeeded every time.
    output reg  [7:0]   last_eir,
    output reg  [7:0]   last_estat,
    // RX-parsing telemetry. Hardware showed frames_seen racing while
    // arp_replies_sent stayed at zero, which does not say whether we are
    // failing to SEE ARP requests or failing to MATCH them. These separate
    // the two: arp_reqs counts frames parsed as an ARP request (whatever
    // the target), and last_etype is the raw EtherType of the last frame
    // walked -- if that is not 0x0806/0x0800 on a real network, the read
    // pointer is misaligned and we are parsing garbage.
    output reg  [15:0]  arp_reqs,
    output reg  [15:0]  last_etype,
    // Transmit status vector, read straight out of the buffer after each TX.
    // tsv_count = bytes the part says it queued; tsv_wire = "Total Bytes
    // Transmitted on Wire" (TSV bits 47-32) -- zero there means nothing
    // physically left the chip, which no amount of switch-side counting can
    // tell us. tsv_stat2/3 carry Transmit Done, CRC/length errors, collision
    // count, defer, giant and underrun.
    output reg  [15:0]  rx_resyncs,   // times the RX chain was found corrupt
    // Asserted when the RX packet chain is provably corrupt and this module
    // wants the whole ENC28J60 brought back up from scratch. eth_top takes
    // the SPI bus back, re-runs the hardware reset, the errata-19 reset
    // sequence and the M2 configuration, then hands the bus back -- at which
    // point `start` rises again and the FSM below restarts from S_INIT0.
    output reg          reinit_req,
    // Liveness diagnostics. "Counters frozen" on the console is ambiguous:
    // it means the FSM is stuck OR the part is reporting no packets, and
    // those need completely different fixes. polls increments once per
    // EPKTCNT poll, so it separates the two -- if it advances the FSM is
    // alive and the part simply has nothing to hand over. last_pktcnt is
    // whatever that poll actually read back.
    // Messages accepted from the peer. rx_updated is a one-cycle pulse, so
    // there was no way to tell from the console whether a UDP message had
    // been received and stored or merely a frame had gone by -- only the OLED
    // showed it, which makes board-to-board messaging untestable without eyes
    // on the panel.
    output reg  [15:0]  msgs_rx,
    output reg  [15:0]  polls,
    output reg  [7:0]   last_pktcnt,
    output reg  [15:0]  tsv_count,
    output reg  [15:0]  tsv_wire,
    output reg  [7:0]   tsv_stat2,
    output reg  [7:0]   tsv_stat3
);

    // ------------------------------------------------------------------
    // M4: the peer. Only two hosts ever exist, so HOST_ID (1 or 2) picks
    // the other one with the same formula eth_top.v uses for OUR_MAC/OUR_IP
    // -- no ARP client needed to learn it dynamically.
    // ------------------------------------------------------------------
    localparam [7:0]  PEER_ID  = (HOST_ID == 8'd1) ? 8'd2 : 8'd1;
    localparam [47:0] PEER_MAC = {40'h02_42_CE_60_00, PEER_ID};
    localparam [31:0] PEER_IP  = {24'hC0_A8_01, 8'd59 + PEER_ID};

    // ------------------------------------------------------------------
    // Opcodes / addresses. Same "widely-documented, not datasheet-verified"
    // caveat as eth_top.v's M2 table -- real hardware is the actual proof.
    // ------------------------------------------------------------------
    function [7:0] WCR(input [4:0] a); WCR = {3'b010, a}; endfunction
    function [7:0] RCR(input [4:0] a); RCR = {3'b000, a}; endfunction
    // Bit Field Set / Clear. Same two-byte shape as WCR (opcode, then a
    // mask), but the part ORs / AND-NOTs the mask into the register instead
    // of overwriting it. Legal on ETH registers only -- which ECON1 is.
    // Every ECON1 access below goes through these now, because a whole-byte
    // WCR to ECON1 cannot avoid rewriting RXEN and TXRTS as a side effect of
    // selecting a bank: the bank selects were switching the receiver off,
    // which is what left both nodes with frozen counters after a while.
    function [7:0] BFS(input [4:0] a); BFS = {3'b100, a}; endfunction
    function [7:0] BFC(input [4:0] a); BFC = {3'b101, a}; endfunction
    localparam [7:0] OP_RBM = 8'h3A;     // fixed opcode, no address field
    localparam [7:0] OP_WBM = 8'h7A;

    localparam [4:0] A_ECON1   = 5'h1F, A_ECON2 = 5'h1E;   // common
    localparam [4:0] A_EIR     = 5'h1C, A_ESTAT = 5'h1D;   // common -- diagnostic only
    localparam [4:0] A_ERDPTL  = 5'h00, A_ERDPTH = 5'h01;  // bank 0
    localparam [4:0] A_EWRPTL  = 5'h02, A_EWRPTH = 5'h03;
    localparam [4:0] A_ERXSTL  = 5'h08, A_ERXSTH = 5'h09;
    localparam [4:0] A_ERXNDL  = 5'h0A, A_ERXNDH = 5'h0B;
    localparam [4:0] A_ETXSTL  = 5'h04, A_ETXSTH = 5'h05;
    localparam [4:0] A_ETXNDL  = 5'h06, A_ETXNDH = 5'h07;
    localparam [4:0] A_ERXRDPTL= 5'h0C, A_ERXRDPTH= 5'h0D;
    localparam [4:0] A_EPKTCNT = 5'h19;                    // bank 1

    localparam [15:0] ERXST = 16'h0000, ERXND = 16'h19FF, ETXST = 16'h1A00;
    // The ARP reply itself is only 42 bytes (14-byte dest/src/EtherType
    // header + 28-byte ARP body), well under Ethernet's 60-byte minimum
    // frame size (excluding FCS). MACON3's PADCFG bits were meant to pad
    // this in hardware, but that write was never independently verifiable
    // (the abandoned MAC-register readback -- see the cfg_op comment in
    // eth_top.v) and real-hardware evidence points at it not having taken
    // effect: EIR/ESTAT confirm the ENC28J60 completes the transmission
    // cleanly, yet the frame never reaches anything downstream -- exactly
    // what every compliant switch does with a runt frame, silently. Padding
    // explicitly here removes the dependency on that unverified register.
    localparam integer ARP_TX_LEN = 60;  // Ethernet minimum, header+payload
    // Control byte (1) + ARP_TX_LEN bytes; ETXND is inclusive of the last
    // byte written, so ETXST + (1 + ARP_TX_LEN) - 1.
    localparam [15:0] ARP_ETXND = ETXST + ARP_TX_LEN[15:0];

    // ------------------------------------------------------------------
    // M4 UDP message: Ethernet(14) + IP(20, no options) + UDP(8) + a fixed
    // 21-byte payload (uart_console's MSG_LEN, always fully populated --
    // shorter lines are space-padded there already) = 63 bytes, already
    // above the 60-byte Ethernet minimum, so no extra padding needed here.
    // ------------------------------------------------------------------
    localparam integer MSG_LEN     = 21;
    localparam integer MSG_HDR_LEN = 14 + 20 + 8;                  // 42
    localparam integer MSG_TX_LEN  = MSG_HDR_LEN + MSG_LEN;        // 63
    localparam [15:0]  MSG_ETXND   = ETXST + MSG_TX_LEN[15:0];
    localparam [15:0]  UDP_PORT    = 16'd1234;                     // 0x04D2

    // A UDP message is accepted if it is addressed to us OR broadcast. The
    // broadcast path is what makes the display usable while the transmit side
    // is still broken: receiving is confirmed working on hardware (the
    // ENC28J60's activity LED blinks, frames_seen climbs, EtherType decodes
    // as 0806/0800), so a PC broadcasting to port 1234 can drive the OLED
    // without the board needing to transmit anything at all.
    //
    // Broadcast frames already pass the MAC filter -- ERXFCON is 0xA1, which
    // has BCEN set (see eth_top.v's cfg table).
    localparam [31:0] IP_BCAST_LIMITED = 32'hFFFF_FFFF;            // 255.255.255.255
    localparam [31:0] IP_BCAST_SUBNET  = {OUR_IP[31:8], 8'hFF};    // e.g. 192.168.1.255

    function dest_accept(input [31:0] d);
        dest_accept = (d == OUR_IP) || (d == IP_BCAST_LIMITED) || (d == IP_BCAST_SUBNET);
    endfunction
    localparam [15:0]  IP_TOTAL_LEN = 16'd20 + 16'd8 + MSG_LEN[15:0]; // 49

    // IPv4 header checksum: ones'-complement sum of the header's 16-bit
    // words (checksum field itself treated as zero), folded, then
    // complemented. Every field of this fixed one-shot header is a
    // compile-time constant (OUR_IP/PEER_IP included, both parameters), so
    // this function is evaluated once at elaboration -- no runtime checksum
    // hardware needed.
    function [15:0] ip_checksum(input [15:0] w0, w1, w2, w3, w4, w6, w7, w8, w9);
        reg [31:0] sum;
        begin
            sum = w0 + w1 + w2 + w3 + w4 + w6 + w7 + w8 + w9;
            sum = sum[15:0] + sum[31:16];   // fold carry back in
            sum = sum[15:0] + sum[31:16];   // fold again: the first fold's
                                             // own carry-out is at most 1
            ip_checksum = ~sum[15:0];
        end
    endfunction

    localparam [15:0] IP_CHECKSUM = ip_checksum(
        16'h4500,               // version=4, IHL=5, TOS=0
        IP_TOTAL_LEN,
        16'h0000,               // identification
        16'h0000,               // flags=0, fragment offset=0
        {8'd64, 8'd17},         // TTL=64, protocol=17 (UDP)
        OUR_IP[31:16],  OUR_IP[15:0],
        PEER_IP[31:16], PEER_IP[15:0]
    );

    // ------------------------------------------------------------------
    // Bit-banged SPI transaction primitives, matching eth_top's M1/M2 style.
    // ------------------------------------------------------------------
    reg        spi_busy_d;
    wire       spi_done = spi_busy_d & ~spi_busy;
    always @(posedge clk) spi_busy_d <= spi_busy;

    // ------------------------------------------------------------------
    // RX frame layout (offsets from the start of the Ethernet frame, as
    // delivered by RBM right after the 6-byte per-packet RX header). Two
    // frame types share the same 0-13 prefix and diverge after that:
    //
    // ARP:
    //   0-5   dest MAC   6-11  src MAC        12-13 EtherType (0x0806=ARP)
    //   14-15 HTYPE(=1)  16-17 PTYPE(=0x0800) 18 HLEN(=6)    19 PLEN(=4)
    //   20-21 OPER (1=request, 2=reply)
    //   22-27 SHA (sender MAC)   28-31 SPA (sender IP)
    //   32-37 THA (target MAC)  38-41 TPA (target IP)
    // A reply mirrors the request with: dest MAC <- SHA, src MAC <- ours,
    // OPER <- 2, SHA <- ours, SPA <- ours, THA <- old SHA, TPA <- old SPA.
    //
    // IPv4/UDP (M4), assuming a standard 20-byte IP header (IHL=5, no
    // options -- true for both this design's own TX and any normal sender):
    //   0-5 dest MAC  6-11 src MAC  12-13 EtherType (0x0800=IPv4)
    //   14 ver/IHL  15 TOS  16-17 total length  18-19 ID  20-21 flags/frag
    //   22 TTL  23 protocol (0x11=UDP)  24-25 header checksum
    //   26-29 source IP  30-33 destination IP
    //   34-35 UDP src port  36-37 UDP dst port (must be 1234)
    //   38-39 UDP length  40-41 UDP checksum
    //   42-62 UDP payload (21 bytes, the message)
    // ------------------------------------------------------------------
    reg [47:0] sender_mac;
    reg [31:0] sender_ip, target_ip;
    reg [15:0] next_rdpt;      // where the next RX packet's header begins
    reg [15:0] cur_next_ptr;   // this packet's own "next packet" field
    reg [5:0]  rxpos;          // 0..62, byte offset within the frame (fits: max 63)
    reg [5:0]  txpos;          // 0..63 likewise
    reg [7:0]  hdr_byte_idx;   // 0..5, the 6-byte per-packet RX header
    reg        is_arp, is_request, target_is_us;
    reg        is_ip, is_udp, dest_ip_is_us, is_our_port;  // dest_ip_is_us: ours OR broadcast
    reg        ethertype_hi08;   // scratch: high byte of EtherType was 0x08
    reg [7:0]  udp_payload [0:MSG_LEN-1];

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam S_INIT0      = 7'd0,  S_INIT1      = 7'd1,
               S_POLL       = 7'd2,  S_POLL_WAIT  = 7'd3,  S_POLL_CHECK = 7'd4,
               S_SETRDPT0   = 7'd5,  S_SETRDPT1   = 7'd6,  S_SETRDPT2   = 7'd7,
               S_RBM_OP     = 7'd8,  S_RBM_OPWAIT = 7'd9,
               S_RBM_HDR_GO = 7'd10, S_RBM_HDR_WT = 7'd11,
               S_RBM_BOD_GO = 7'd12, S_RBM_BOD_WT = 7'd13,
               S_TX_BANK    = 7'd14, S_SETWRPT0   = 7'd15, S_SETWRPT1   = 7'd16,
               S_WBM_OP     = 7'd17, S_WBM_OPWAIT = 7'd18,
               S_WBM_BOD_GO = 7'd19, S_WBM_BOD_WT = 7'd20,
               S_SETETXND0  = 7'd21, S_SETETXND1  = 7'd22,
               S_TXRTS      = 7'd23, S_TXWAIT     = 7'd24,
               S_CLEANUP0   = 7'd25, S_CLEANUP1   = 7'd26, S_CLEANUP2   = 7'd27,
               S_CLEANUP3   = 7'd28, S_CLEANUP4   = 7'd29,
               S_WCR_OP     = 7'd30, S_WCR_DATA   = 7'd31, // generic 1-shot WCR
               S_RCR_OP     = 7'd32, S_RCR_WAIT   = 7'd33, // generic 1-shot RCR
               S_RD_EIR_GO  = 7'd34, S_RD_ESTAT_GO = 7'd35, // TX diagnostic readback
               S_TXRST0     = 7'd36, S_TXRST1     = 7'd37, // errata: reset TX logic before every TX
               // ---- M4: send the current typed line as a UDP message ----
               S_MSGBANK    = 7'd38, S_MSGWRPT0   = 7'd39, S_MSGWRPT1   = 7'd40,
               S_MSGTXRST0  = 7'd41, S_MSGTXRST1  = 7'd42,
               S_MSGOP      = 7'd43, S_MSGOPWAIT  = 7'd44,
               S_MSGHDR_GO  = 7'd45, S_MSGHDR_WT  = 7'd46,
               S_MSGBOD_GO  = 7'd47, S_MSGBOD_WT  = 7'd48,
               S_MSGETXND0  = 7'd49, S_MSGETXND1  = 7'd50,
               S_MSGTXRTS   = 7'd51, S_MSGTXWAIT  = 7'd52, S_MSGDONE = 7'd53,
               S_MSGCTRL_GO = 7'd54, S_MSGCTRL_WT = 7'd55,
               // Re-arm ETXST after each TXRST pulse (see S_SETTXST0 below)
               S_SETTXST0   = 7'd56, S_SETTXST1   = 7'd57,
               S_MSGTXST0   = 7'd58, S_MSGTXST1   = 7'd59,
               // Read back the 7-byte transmit status vector the part writes
               // just past ETXND after every transmission (datasheet 7.1 /
               // Table 7-1). Read via RBM, which is already proven working --
               // unlike the MAC-type register reads this project abandoned.
               S_TSV_RDPT0  = 7'd60, S_TSV_RDPT1  = 7'd61,
               S_TSV_OP     = 7'd62, S_TSV_OPWAIT = 7'd63,
               S_TSV_GO     = 7'd64, S_TSV_WT     = 7'd65,
               // Hard receive-logic resync: pulse ECON1.RXRST and rebuild the
               // RX FIFO bounds from scratch. Reached only when the packet
               // chain is provably corrupt (see next_ptr_ok).
               // Ask eth_top for a full re-init, then wait for it to take
               // the bus. Replaces the old RXRST-based resync -- see the
               // comment on S_REINIT_REQ below for why that could not work.
               S_REINIT_REQ = 7'd66, S_REINIT_WAIT = 7'd67,
               // Generic 1-shot BFS/BFC, and the two-step bank select built
               // on top of it (clear BSEL, then set the wanted bits).
               S_BF_OP      = 7'd74, S_BF_DATA    = 7'd75,
               S_BSEL0      = 7'd76, S_BSEL1      = 7'd77;

    reg [6:0]  state, ret_state;    // ret_state: where the generic WCR/RCR returns to
    reg [4:0]  wcr_addr;
    reg [7:0]  wcr_data;
    // Explicit phase for every two-byte SPI helper below. These used to
    // infer "have I sent the opcode yet?" by comparing the byte just shifted
    // out against the opcode itself -- which silently breaks whenever the
    // DATA byte happens to equal the OPCODE byte: the comparison stays true,
    // the helper resends the data forever and the whole FSM wedges.
    //
    // That is not hypothetical. WCR(ERDPTL) is 0x40 and WCR(ERXRDPTL) is
    // 0x4C, and both are written with the low byte of an RX ring pointer,
    // which walks through all 256 values as packets march up the buffer. Two
    // chances in 256 per frame; nodes wedged after 122, 156 and 134 frames
    // against a predicted mean of 128.
    reg        op_ph2;              // 0 = opcode sent next, 1 = data byte next
    reg [4:0]  bf_addr;             // generic BFS/BFC target
    reg [7:0]  bf_mask;
    reg        bf_set;              // 1 = BFS (set bits), 0 = BFC (clear bits)
    reg [6:0]  bf_ret;              // where the generic BF op returns to
    reg [7:0]  ec1_set;             // bits to set after a bank select
    reg [4:0]  rcr_addr;
    reg [7:0]  rcr_rb;              // generic RCR's captured byte
    reg [26:0] wait_cnt;
    reg        send_pending;    // M4: a typed line is waiting to go out
    reg [15:0] tsv_addr;        // first byte of the status vector = ETXND + 1
    reg [2:0]  tsv_idx;

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
                6'd41: arp_reply_byte = sender_ip[7:0];
                // Padding up to ARP_TX_LEN (60), see the ARP_ETXND comment above.
                default: arp_reply_byte = 8'h00;
            endcase
        end
    endfunction

    // One header byte (0..41) of the M4 UDP message: fixed Ethernet + IPv4 +
    // UDP header, entirely from compile-time constants -- see the header
    // comment for the field layout and IP_CHECKSUM for why no runtime
    // checksum computation is needed.
    function [7:0] msg_hdr_byte(input [5:0] p);
        begin
            case (p)
                // dest MAC = peer's
                6'd0: msg_hdr_byte = PEER_MAC[47:40];
                6'd1: msg_hdr_byte = PEER_MAC[39:32];
                6'd2: msg_hdr_byte = PEER_MAC[31:24];
                6'd3: msg_hdr_byte = PEER_MAC[23:16];
                6'd4: msg_hdr_byte = PEER_MAC[15:8];
                6'd5: msg_hdr_byte = PEER_MAC[7:0];
                // src MAC = ours
                6'd6:  msg_hdr_byte = OUR_MAC[47:40];
                6'd7:  msg_hdr_byte = OUR_MAC[39:32];
                6'd8:  msg_hdr_byte = OUR_MAC[31:24];
                6'd9:  msg_hdr_byte = OUR_MAC[23:16];
                6'd10: msg_hdr_byte = OUR_MAC[15:8];
                6'd11: msg_hdr_byte = OUR_MAC[7:0];
                6'd12: msg_hdr_byte = 8'h08;  // EtherType 0x0800 (IPv4)
                6'd13: msg_hdr_byte = 8'h00;
                6'd14: msg_hdr_byte = 8'h45;  // version=4, IHL=5
                6'd15: msg_hdr_byte = 8'h00;  // TOS
                6'd16: msg_hdr_byte = IP_TOTAL_LEN[15:8];
                6'd17: msg_hdr_byte = IP_TOTAL_LEN[7:0];
                6'd18: msg_hdr_byte = 8'h00;  // identification
                6'd19: msg_hdr_byte = 8'h00;
                6'd20: msg_hdr_byte = 8'h00;  // flags/fragment offset
                6'd21: msg_hdr_byte = 8'h00;
                6'd22: msg_hdr_byte = 8'd64;  // TTL
                6'd23: msg_hdr_byte = 8'd17;  // protocol = UDP
                6'd24: msg_hdr_byte = IP_CHECKSUM[15:8];
                6'd25: msg_hdr_byte = IP_CHECKSUM[7:0];
                // source IP = ours
                6'd26: msg_hdr_byte = OUR_IP[31:24];
                6'd27: msg_hdr_byte = OUR_IP[23:16];
                6'd28: msg_hdr_byte = OUR_IP[15:8];
                6'd29: msg_hdr_byte = OUR_IP[7:0];
                // destination IP = peer's
                6'd30: msg_hdr_byte = PEER_IP[31:24];
                6'd31: msg_hdr_byte = PEER_IP[23:16];
                6'd32: msg_hdr_byte = PEER_IP[15:8];
                6'd33: msg_hdr_byte = PEER_IP[7:0];
                // UDP src port (reused as dst port too -- a fixed p2p pair,
                // the actual value doesn't matter as long as both agree)
                6'd34: msg_hdr_byte = UDP_PORT[15:8];
                6'd35: msg_hdr_byte = UDP_PORT[7:0];
                6'd36: msg_hdr_byte = UDP_PORT[15:8];
                6'd37: msg_hdr_byte = UDP_PORT[7:0];
                6'd38: msg_hdr_byte = 8'h00;  // UDP length = 8 + MSG_LEN = 29
                6'd39: msg_hdr_byte = 8'd29;
                6'd40: msg_hdr_byte = 8'h00;  // UDP checksum: 0 = not computed (RFC 768)
                default: msg_hdr_byte = 8'h00;   // 41
            endcase
        end
    endfunction

    // Where ERXRDPT must point after freeing this packet's buffer space.
    // Documented ENC28J60 workaround: one less than the next-packet pointer,
    // unless that pointer is the start of the buffer, in which case use the
    // end instead (avoids ERXRDPT ever landing one before ERXST).
    // The per-packet "next packet pointer" is the only thing keeping the read
    // side aligned: each packet is read from wherever the previous one said
    // the next begins. So one bad value desyncs the chain permanently -- from
    // then on the "header" is really packet payload, every EtherType is
    // nonsense, and nothing is ever recognised again.
    //
    // Seen on hardware 2026-08-27: Host B ran correctly for a while, then
    // frames_seen kept racing while arp_reqs froze and last_etype degenerated
    // to garbage (D87E, 0001, ...). It dropped out of the switch's MAC table
    // and only a reset brought it back. Host A behaved identically given
    // enough traffic.
    //
    // A pointer outside the RX FIFO is provably corrupt, so treat it as a
    // resync point: rebuild the chain at ERXST and hand the whole buffer back
    // to the hardware, instead of chasing the bad pointer forever.
    wire        next_ptr_ok  = (cur_next_ptr <= ERXND);
    wire [15:0] next_erxrdpt = (!next_ptr_ok)              ? ERXND :
                               (cur_next_ptr == ERXST)     ? ERXND :
                                                             (cur_next_ptr - 16'd1);

    assign rx_rd_data = udp_payload[rx_rd_addr];

    always @(posedge clk) begin
        spi_start  <= 1'b0;
        rx_updated <= 1'b0;
        // Sticky, set here unconditionally so a line completed while
        // net_stack is mid-RX-processing isn't missed; cleared once the
        // send actually starts (S_MSG_TXBANK below). A later assignment in
        // the same always block (the rst clear, or that clear-on-start)
        // wins over this tentative one for the same clock edge.
        if (send_req) send_pending <= 1'b1;

        if (rst) begin
            state            <= S_INIT0;
            cs_n             <= 1'b1;
            next_rdpt        <= ERXST;
            op_ph2           <= 1'b0;
            msgs_rx          <= 16'd0;
            polls            <= 16'd0;
            last_pktcnt      <= 8'd0;
            wait_cnt         <= 0;
            frames_seen      <= 16'd0;
            arp_replies_sent <= 16'd0;
            last_eir         <= 8'd0;
            last_estat       <= 8'd0;
            send_pending     <= 1'b0;
            arp_reqs         <= 16'd0;
            last_etype       <= 16'd0;
            rx_resyncs       <= 16'd0;
            reinit_req       <= 1'b0;
            tsv_count        <= 16'd0;
            tsv_wire         <= 16'd0;
            tsv_stat2        <= 8'd0;
            tsv_stat3        <= 8'd0;
        end else if (!start && state == S_INIT0) begin
            // Idle until eth_top hands off the bus. Dropping reinit_req here
            // is what ends the request: by the time this branch is taken,
            // eth_top has already lowered `start` (taken the bus), so it has
            // certainly latched the request. Holding it any longer would make
            // eth_top re-init forever.
            reinit_req <= 1'b0;
        end else begin
            case (state)
                // ---- one-time: AUTOINC on, prepare to poll bank 1 ----
                S_INIT0: begin
                    wcr_addr   <= A_ECON2; wcr_data <= 8'h80;   // AUTOINC=1
                    ret_state  <= S_INIT1;
                    state      <= S_WCR_OP;
                end
                S_INIT1: begin
                    ec1_set   <= 8'h05;                         // bank1, RXEN=1
                    ret_state <= S_POLL;
                    state     <= S_BSEL0;
                end
                // ---- poll EPKTCNT ----
                S_POLL: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= RCR(A_EPKTCNT);
                    spi_start <= 1'b1;
                    op_ph2    <= 1'b0;
                    state     <= S_POLL_WAIT;
                end
                S_POLL_WAIT:
                    if (spi_done) begin
                        if (!op_ph2) begin
                            op_ph2 <= 1'b1;
                            spi_tx <= 8'h00; spi_start <= 1'b1;   // clock in count
                        end else begin
                            cs_n  <= 1'b1;
                            state <= S_POLL_CHECK;
                        end
                    end
                S_POLL_CHECK: begin
                    polls       <= polls + 16'd1;
                    last_pktcnt <= spi_rx;
                    if (spi_rx == 8'h00) begin
                        wait_cnt <= 0;
                        // Nothing waiting to receive -- if a typed line is
                        // queued to go out (M4), send it now; otherwise poll
                        // again.
                        state <= send_pending ? S_MSGBANK : S_POLL;
                    end else begin
                        state <= S_SETRDPT0;
                    end
                end

                // ---- point ERDPT at this packet's header ----
                // These bank-0 selects write 0x00, which also clears RXEN
                // (bit 2) -- a plain WCR overwrites the whole register. Keeping
                // RXEN set here instead (0x04) was TRIED on hardware 2026-08-27
                // and made things measurably WORSE: a freshly reset node went
                // from A=0003/R=0001/X=0000 (working) to A=0000 with rx_resyncs
                // climbing about once every two frames, never recognising a
                // single ARP request. Reverted. Leaving the receiver disabled
                // during the pointer updates is evidently what this part wants,
                // so do not "fix" this again without hardware evidence.
                S_SETRDPT0: begin
                    ec1_set   <= 8'h00;                         // bank 0; RXEN untouched
                    ret_state <= S_SETRDPT1;
                    state     <= S_BSEL0;
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
                    is_ip         <= 1'b0;
                    is_udp        <= 1'b0;
                    dest_ip_is_us <= 1'b0;
                    is_our_port   <= 1'b0;
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

                // The Ethernet frame itself, byte by byte. Bytes 0-13 (dest/
                // src MAC, EtherType) are shared between ARP and IP/UDP;
                // byte 13 resolves which one this is, and rxpos 14 onward is
                // interpreted differently per protocol. Abandons early
                // (jumps to cleanup) the moment it is clearly not something
                // we care about -- no need to read bytes we will not use,
                // and every frame still needs the cleanup step either way.
                S_RBM_BOD_GO: begin
                    spi_tx <= 8'h00; spi_start <= 1'b1;
                    state  <= S_RBM_BOD_WT;
                end
                S_RBM_BOD_WT:
                    if (spi_done) begin
                        if (rxpos < 6'd14) begin
                            if (rxpos == 6'd12) begin
                                ethertype_hi08     <= (spi_rx == 8'h08);
                                last_etype[15:8]   <= spi_rx;
                            end
                            if (rxpos == 6'd13) begin
                                last_etype[7:0] <= spi_rx;
                            end
                            if (rxpos == 6'd13) begin
                                is_arp <= ethertype_hi08 && (spi_rx == 8'h06);
                                is_ip  <= ethertype_hi08 && (spi_rx == 8'h00);
                            end
                        end else if (is_ip) begin
                            case (rxpos)
                                6'd23: is_udp          <= (spi_rx == 8'h11);
                                6'd30: target_ip[31:24] <= spi_rx;
                                6'd31: target_ip[23:16] <= spi_rx;
                                6'd32: target_ip[15:8]  <= spi_rx;
                                6'd33: dest_ip_is_us    <= dest_accept({target_ip[31:8], spi_rx});
                                6'd36: is_our_port      <= (spi_rx == UDP_PORT[15:8]);
                                6'd37: is_our_port      <= is_our_port && (spi_rx == UDP_PORT[7:0]);
                                default:
                                    if (rxpos >= 6'd42) udp_payload[rxpos - 6'd42] <= spi_rx;
                            endcase
                        end else begin
                            case (rxpos)
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
                        end

                        // Neither ARP nor IP: stop reading, nothing more to learn.
                        if (rxpos == 6'd13 && !(ethertype_hi08 && (spi_rx == 8'h06 || spi_rx == 8'h00))) begin
                            cs_n  <= 1'b1;
                            state <= S_CLEANUP0;
                        // IP path: bail the moment it's clearly not "UDP to our port".
                        end else if (is_ip && rxpos == 6'd23 && spi_rx != 8'h11) begin
                            cs_n  <= 1'b1;
                            state <= S_CLEANUP0;
                        end else if (is_ip && rxpos == 6'd33 && !dest_accept({target_ip[31:8], spi_rx})) begin
                            cs_n  <= 1'b1;
                            state <= S_CLEANUP0;
                        end else if (is_ip && rxpos == 6'd37 && !(is_our_port && spi_rx == UDP_PORT[7:0])) begin
                            cs_n  <= 1'b1;
                            state <= S_CLEANUP0;
                        end else if (is_ip && rxpos == 6'd62) begin
                            cs_n  <= 1'b1;
                            state <= S_CLEANUP0;
                        end else if (!is_ip && rxpos == 6'd41) begin
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
                    // A valid M4 message: no reply needed, just latch it for
                    // eth_top's OLED writer to pick up (udp_payload itself
                    // was already captured byte-by-byte during the walk
                    // above). This check is correct regardless of whether we
                    // got here via early abort or full completion: each flag
                    // only ever reaches 1 once its own check actually passed
                    // (see the S_RBM_BOD_WT walk), so an aborted frame always
                    // leaves at least one of these still 0.
                    if (is_ip && is_udp && dest_ip_is_us && is_our_port) begin
                        rx_updated <= 1'b1;
                        msgs_rx    <= msgs_rx + 16'd1;
                    end
                    // Telemetry: did we parse this as an ARP request at all,
                    // regardless of whether its target IP matched us?
                    if (is_arp && is_request)
                        arp_reqs <= arp_reqs + 16'd1;
                    // Decide whether to reply *before* touching ECON1/ERXRDPT,
                    // so the branch below always lands correctly.
                    if (is_arp && is_request && target_is_us) begin
                        state <= S_TX_BANK;
                    end else begin
                        state <= S_CLEANUP1;
                    end
                end

                // ---- ARP reply: bank 0, reset TX logic, then build the frame ----
                // ORDER MATTERS. The TXRST pulse comes FIRST, before EWRPT and
                // ETXND are loaded, because resetting the transmit logic also
                // resets the transmit pointer registers -- pulsing it after
                // loading them (as this originally did) clobbers the length
                // and the part sends a bogus frame while still reporting
                // success. Real evidence, 2026-08-24: with TXRST last, EIR
                // read back TXIF=1 (transmission complete, no error flags) on
                // every attempt, yet a Cisco L2 switch never learned either
                // board's MAC address -- i.e. not one valid frame ever
                // reached the wire.
                S_TX_BANK: begin
                    ec1_set   <= 8'h00;                         // bank 0; RXEN untouched
                    ret_state <= S_TXRST0;
                    state     <= S_BSEL0;
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

                // Byte 0 of the write is the per-packet control byte, 0x07 =
                // POVERRIDE | PCRCEN | PPADEN (datasheet Figure 7-1: bit 0
                // POVERRIDE, bit 1 PCRCEN, bit 2 PPADEN). That forces pad-to-60
                // and a valid appended CRC for THIS packet, overriding MACON3.
                //
                // It was 0x00 (defer to MACON3.TXCRCEN) until 2026-08-27, when
                // the transmit status vector read straight off the chip said:
                //     TSV n=003C w=003C s2=90 s3=00
                // 60 bytes queued, 60 bytes actually on the wire, Transmit Done
                // set, no collisions or deferral -- but s2 bit 4, TRANSMIT CRC
                // ERROR, also set. A frame with a bad CRC is discarded silently
                // by any switch, which is precisely the "InOctets climb but no
                // packet ever completes, and no error counter moves" signature
                // seen on the Cisco 2960.
                //
                // MACON3.TXCRCEN is supposed to be set already (0x32, bit 4),
                // but this project has never been able to read MAC-type
                // registers back to confirm it. Overriding per packet removes
                // that unverifiable dependency completely.
                // Bytes 1..ARP_TX_LEN are the
                // 42-byte ARP reply followed by explicit zero padding up to
                // ARP_TX_LEN -- see the ARP_ETXND comment above for why this
                // isn't left to MACON3.PADCFG.
                S_WBM_BOD_GO: begin
                    spi_tx    <= (txpos == 6'd0) ? 8'h07 : arp_reply_byte(txpos - 6'd1);
                    spi_start <= 1'b1;
                    state     <= S_WBM_BOD_WT;
                end
                S_WBM_BOD_WT:
                    if (spi_done) begin
                        if (txpos == ARP_TX_LEN[5:0]) begin
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
                    tsv_addr  <= ARP_ETXND + 16'd1;
                    ret_state <= S_TXRTS;
                    state     <= S_WCR_OP;
                end

                // Documented ENC28J60 errata: the transmit logic can get
                // corrupted after a transmission (successful or not) and must
                // be reset -- ECON1.TXRST pulsed high then low -- before every
                // subsequent TX, not just the first. Adding this is what first
                // got TXIF to set at all (before it, the TX engine sat wedged
                // and never reported completion).
                //
                // Both writes keep RXEN set: a plain WCR overwrites the whole
                // register, so clearing it here would disable the receiver for
                // the entire buffer-write that follows and drop frames arriving
                // in that window. (A real driver would use the bit-set/bit-clear
                // opcodes to touch only TXRST; this design only implements WCR.)
                S_TXRST0: begin
                    bf_addr <= A_ECON1; bf_mask <= 8'h80; bf_set <= 1'b1;  // TXRST=1 only
                    bf_ret  <= S_TXRST1;
                    state   <= S_BF_OP;
                end
                S_TXRST1: begin
                    bf_addr <= A_ECON1; bf_mask <= 8'h80; bf_set <= 1'b0;  // TXRST=0 only
                    bf_ret  <= S_SETTXST0;
                    state   <= S_BF_OP;
                end

                // Re-arm ETXST after every TXRST pulse. ETXST is written once
                // during M2 init and was never rewritten here, on the
                // assumption it stays put -- but TXRST resets the transmit
                // logic, and that plausibly includes the transmit start
                // pointer. If it does, the part transmits from wherever ETXST
                // landed (0x0000, i.e. the RX buffer) all the way to
                // ETXND=0x1A3C: about 6.7 KB, which is precisely the
                // oversized frame the switch counted as "1 giants" while
                // rejecting every frame. Cheap to write, removes the
                // assumption entirely.
                S_SETTXST0: begin
                    wcr_addr  <= A_ETXSTL; wcr_data <= ETXST[7:0];
                    ret_state <= S_SETTXST1;
                    state     <= S_WCR_OP;
                end
                S_SETTXST1: begin
                    wcr_addr  <= A_ETXSTH; wcr_data <= ETXST[15:8];
                    ret_state <= S_SETWRPT0;
                    state     <= S_WCR_OP;
                end

                S_TXRTS: begin
                    bf_addr <= A_ECON1; bf_mask <= 8'h08; bf_set <= 1'b1;  // TXRTS=1 only
                    bf_ret  <= S_TXWAIT;
                    state   <= S_BF_OP;
                end
                S_TXWAIT:
                    // Fixed conservative delay rather than polling TXRTS --
                    // fewer register reads, fewer chances to hit another
                    // untested protocol edge case. 42 bytes at 10 Mbit half
                    // duplex is ~34 us; 500 us at 50 MHz is comfortable.
                    if (wait_cnt == 27'd25_000) begin
                        wait_cnt         <= 0;
                        arp_replies_sent <= arp_replies_sent + 16'd1;
                        state            <= S_RD_EIR_GO;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end

                // ---- diagnostic: what does the hardware itself think happened? ----
                S_RD_EIR_GO: begin
                    rcr_addr  <= A_EIR;
                    ret_state <= S_RD_ESTAT_GO;
                    state     <= S_RCR_OP;
                end
                S_RD_ESTAT_GO: begin
                    last_eir  <= rcr_rb;
                    rcr_addr  <= A_ESTAT;
                    ret_state <= S_TSV_RDPT0;
                    state     <= S_RCR_OP;
                end

                // ---- read the 7-byte transmit status vector ----
                // ECON1 is still on bank 0 from S_TXRTS, so no bank switch.
                // last_estat is captured here rather than in S_CLEANUP1,
                // because control no longer lands there straight after the
                // ESTAT read.
                S_TSV_RDPT0: begin
                    last_estat <= rcr_rb;
                    wcr_addr   <= A_ERDPTL; wcr_data <= tsv_addr[7:0];
                    ret_state  <= S_TSV_RDPT1;
                    state      <= S_WCR_OP;
                end
                S_TSV_RDPT1: begin
                    wcr_addr  <= A_ERDPTH; wcr_data <= tsv_addr[15:8];
                    ret_state <= S_TSV_OP;
                    state     <= S_WCR_OP;
                end
                S_TSV_OP: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= OP_RBM;
                    spi_start <= 1'b1;
                    tsv_idx   <= 3'd0;
                    state     <= S_TSV_OPWAIT;
                end
                S_TSV_OPWAIT:
                    if (spi_done) state <= S_TSV_GO;
                S_TSV_GO: begin
                    spi_tx <= 8'h00; spi_start <= 1'b1;
                    state  <= S_TSV_WT;
                end
                S_TSV_WT:
                    if (spi_done) begin
                        case (tsv_idx)
                            3'd0: tsv_count[7:0]  <= spi_rx;
                            3'd1: tsv_count[15:8] <= spi_rx;
                            3'd2: tsv_stat2       <= spi_rx;
                            3'd3: tsv_stat3       <= spi_rx;
                            3'd4: tsv_wire[7:0]   <= spi_rx;
                            3'd5: tsv_wire[15:8]  <= spi_rx;
                            default: ;            // byte 6, control-frame flags
                        endcase
                        if (tsv_idx == 3'd6) begin
                            cs_n  <= 1'b1;
                            state <= S_CLEANUP1;
                        end else begin
                            tsv_idx <= tsv_idx + 3'd1;
                            state   <= S_TSV_GO;
                        end
                    end

                // ---- free the RX buffer space, decrement EPKTCNT ----
                // last_estat capture belongs here, not a dedicated state: this
                // is where control lands right after the ESTAT RCR above (via
                // ret_state), and non-ARP-reply frames (which skip TX/the EIR
                // read entirely) also pass through here on every packet, so
                // gating the capture on "did we just do a TX" would need its
                // own extra state for no real benefit -- rcr_rb simply holds
                // stale data on those frames instead of a fresh ESTAT value.
                S_CLEANUP1: begin
                    ec1_set    <= 8'h00;                         // bank 0; RXEN untouched
                    ret_state  <= S_CLEANUP2;
                    state      <= S_BSEL0;
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
                    next_rdpt   <= next_ptr_ok ? cur_next_ptr : ERXST;
                    if (!next_ptr_ok) rx_resyncs <= rx_resyncs + 16'd1;
                    frames_seen <= frames_seen + 16'd1;
                    wcr_addr    <= A_ECON2; wcr_data <= 8'hC0;   // AUTOINC + PKTDEC
                    // A corrupt chain needs the whole part brought back up,
                    // not just our own pointer moved. Pulsing ECON1.RXRST and
                    // assuming the next packet then sits at ERXST was tried
                    // and does not work: the hardware's write pointer ends up
                    // somewhere this module cannot know, so the very next read
                    // returns stale bytes and the chain is corrupt again. On
                    // hardware that showed as rx_resyncs climbing into the
                    // hundreds while the part quietly stopped delivering
                    // packets altogether -- EPKTCNT reading 0 forever with the
                    // poll loop still running.
                    ret_state   <= next_ptr_ok ? S_INIT1 : S_REINIT_REQ;
                    state       <= S_WCR_OP;
                end

                // ---- ask for a full re-initialisation ----
                // Release the bus and raise the request. eth_top lowers
                // `start` when it takes the bus over; parking in S_INIT0 then
                // waits (see the !start guard at the top of this block) until
                // the part has been reset and reconfigured and `start` rises
                // again, at which point the FSM restarts cleanly.
                S_REINIT_REQ: begin
                    cs_n       <= 1'b1;
                    spi_start  <= 1'b0;
                    reinit_req <= 1'b1;
                    state      <= S_REINIT_WAIT;
                end
                S_REINIT_WAIT:
                    if (!start) begin
                        next_rdpt <= ERXST;   // the part restarts empty
                        state     <= S_INIT0;
                    end

                // ---- M4: send the current typed line as a UDP message ----
                // Standalone TX, not triggered by an RX frame -- mirrors the
                // ARP reply's bank/pointer/TXRST/TXRTS sequence, but starts
                // fresh from S_POLL_CHECK instead of RX cleanup, and returns
                // to S_INIT1 itself (no RX buffer pointers to restore).
                // Same ordering rule as the ARP path above: TXRST pulse FIRST,
                // then load EWRPT, then write the frame, then ETXND, then TXRTS.
                S_MSGBANK: begin
                    ec1_set   <= 8'h00;                         // bank 0; RXEN untouched
                    ret_state <= S_MSGTXRST0;
                    state     <= S_BSEL0;
                end
                S_MSGTXRST0: begin
                    bf_addr <= A_ECON1; bf_mask <= 8'h80; bf_set <= 1'b1;  // TXRST=1 only
                    bf_ret  <= S_MSGTXRST1;
                    state   <= S_BF_OP;
                end
                S_MSGTXRST1: begin
                    bf_addr <= A_ECON1; bf_mask <= 8'h80; bf_set <= 1'b0;  // TXRST=0 only
                    bf_ret  <= S_MSGTXST0;
                    state   <= S_BF_OP;
                end
                // Re-arm ETXST, same reason as S_SETTXST0 on the ARP path.
                S_MSGTXST0: begin
                    wcr_addr  <= A_ETXSTL; wcr_data <= ETXST[7:0];
                    ret_state <= S_MSGTXST1;
                    state     <= S_WCR_OP;
                end
                S_MSGTXST1: begin
                    wcr_addr  <= A_ETXSTH; wcr_data <= ETXST[15:8];
                    ret_state <= S_MSGWRPT0;
                    state     <= S_WCR_OP;
                end
                S_MSGWRPT0: begin
                    wcr_addr  <= A_EWRPTL; wcr_data <= ETXST[7:0];
                    ret_state <= S_MSGWRPT1;
                    state     <= S_WCR_OP;
                end
                S_MSGWRPT1: begin
                    wcr_addr  <= A_EWRPTH; wcr_data <= ETXST[15:8];
                    ret_state <= S_MSGOP;
                    state     <= S_WCR_OP;
                end

                S_MSGOP: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= OP_WBM;
                    spi_start <= 1'b1;
                    txpos     <= 6'd0;
                    state     <= S_MSGOPWAIT;
                end
                S_MSGOPWAIT:
                    if (spi_done) state <= S_MSGCTRL_GO;

                // Per-packet control byte, same 0x07 override as the ARP path
                // (see the comment there) -- easy to miss since it isn't part
                // of msg_hdr_byte's own 0..41 range, but every WBM-written
                // frame needs exactly one.
                S_MSGCTRL_GO: begin
                    spi_tx    <= 8'h07;
                    spi_start <= 1'b1;
                    state     <= S_MSGCTRL_WT;
                end
                S_MSGCTRL_WT:
                    if (spi_done) state <= S_MSGHDR_GO;

                // 42 fixed header bytes, then MSG_LEN payload bytes read
                // live from uart_console via tx_rd_addr/tx_rd_data.
                S_MSGHDR_GO: begin
                    spi_tx    <= msg_hdr_byte(txpos);
                    spi_start <= 1'b1;
                    state     <= S_MSGHDR_WT;
                end
                S_MSGHDR_WT:
                    if (spi_done) begin
                        if (txpos == MSG_HDR_LEN[5:0] - 6'd1) begin
                            txpos      <= 6'd0;
                            tx_rd_addr <= 5'd0;
                            state      <= S_MSGBOD_GO;
                        end else begin
                            txpos <= txpos + 6'd1;
                            state <= S_MSGHDR_GO;
                        end
                    end
                S_MSGBOD_GO: begin
                    spi_tx     <= tx_rd_data;
                    tx_rd_addr <= tx_rd_addr + 5'd1;   // set up the NEXT byte
                    spi_start  <= 1'b1;
                    state      <= S_MSGBOD_WT;
                end
                S_MSGBOD_WT:
                    if (spi_done) begin
                        if (txpos == MSG_LEN[5:0] - 6'd1) begin
                            cs_n  <= 1'b1;
                            state <= S_MSGETXND0;
                        end else begin
                            txpos <= txpos + 6'd1;
                            state <= S_MSGBOD_GO;
                        end
                    end

                S_MSGETXND0: begin
                    wcr_addr  <= A_ETXNDL; wcr_data <= MSG_ETXND[7:0];
                    ret_state <= S_MSGETXND1;
                    state     <= S_WCR_OP;
                end
                S_MSGETXND1: begin
                    wcr_addr  <= A_ETXNDH; wcr_data <= MSG_ETXND[15:8];
                    ret_state <= S_MSGTXRTS;
                    state     <= S_WCR_OP;
                end
                S_MSGTXRTS: begin
                    bf_addr <= A_ECON1; bf_mask <= 8'h08; bf_set <= 1'b1;  // TXRTS=1 only
                    bf_ret  <= S_MSGTXWAIT;
                    state   <= S_BF_OP;
                end
                S_MSGTXWAIT:
                    if (wait_cnt == 27'd25_000) begin
                        wait_cnt <= 0;
                        state    <= S_MSGDONE;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                // Bank was never changed away from 0 on this path (unlike
                // the ARP reply, no RX pointer restore is needed), so head
                // to S_INIT1 to reselect bank 1 before polling again.
                S_MSGDONE: begin
                    send_pending <= 1'b0;
                    state        <= S_INIT1;
                end

                // ---- generic single WCR, returns to ret_state ----
                S_WCR_OP: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= WCR(wcr_addr);
                    spi_start <= 1'b1;
                    op_ph2    <= 1'b0;
                    state     <= S_WCR_DATA;
                end
                S_WCR_DATA:
                    if (spi_done) begin
                        if (!op_ph2) begin
                            op_ph2 <= 1'b1;
                            spi_tx <= wcr_data; spi_start <= 1'b1;
                        end else begin
                            cs_n  <= 1'b1;
                            state <= ret_state;
                        end
                    end

                // ---- generic single BFS/BFC ----
                S_BF_OP: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= bf_set ? BFS(bf_addr) : BFC(bf_addr);
                    spi_start <= 1'b1;
                    op_ph2    <= 1'b0;
                    state     <= S_BF_DATA;
                end
                S_BF_DATA:
                    if (spi_done) begin
                        if (!op_ph2) begin
                            op_ph2 <= 1'b1;
                            spi_tx <= bf_mask; spi_start <= 1'b1;
                        end else begin
                            cs_n  <= 1'b1;
                            state <= bf_ret;
                        end
                    end

                // ---- bank select that leaves RXEN and TXRTS alone ----
                // Clear BSEL[1:0], then set whatever ec1_set asks for (the
                // bank number, plus RXEN where the caller wants it on). A
                // caller wanting bank 0 and no other change sets ec1_set = 0,
                // which skips the second op entirely.
                S_BSEL0: begin
                    bf_addr <= A_ECON1; bf_mask <= 8'h03; bf_set <= 1'b0;
                    bf_ret  <= S_BSEL1;
                    state   <= S_BF_OP;
                end
                S_BSEL1:
                    if (ec1_set == 8'h00) state <= ret_state;
                    else begin
                        bf_addr <= A_ECON1; bf_mask <= ec1_set; bf_set <= 1'b1;
                        bf_ret  <= ret_state;
                        state   <= S_BF_OP;
                    end

                // ---- generic single RCR of a common/bank-independent
                // register, returns to ret_state with the byte in rcr_rb ----
                S_RCR_OP: begin
                    cs_n      <= 1'b0;
                    spi_tx    <= RCR(rcr_addr);
                    spi_start <= 1'b1;
                    op_ph2    <= 1'b0;
                    state     <= S_RCR_WAIT;
                end
                S_RCR_WAIT:
                    if (spi_done) begin
                        if (!op_ph2) begin
                            op_ph2 <= 1'b1;
                            spi_tx <= 8'h00; spi_start <= 1'b1;   // clock in the byte
                        end else begin
                            cs_n   <= 1'b1;
                            rcr_rb <= spi_rx;
                            state  <= ret_state;
                        end
                    end

                default: state <= S_INIT0;
            endcase
        end
    end

endmodule
