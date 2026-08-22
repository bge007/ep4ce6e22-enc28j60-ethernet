// i2c_master.v -- minimal single-master I2C, write-only, open-drain.
//
// Enough for the SH1106 OLED and nothing more: the display is write-only, so
// there is no read path, and it never stretches the clock, so there is no
// stretch handling. SCL is released rather than driven high, as I2C requires;
// the module's own 4.7k pull-ups do the rest.
//
// Handshake: assert exactly one of cmd_start / cmd_write / cmd_stop for one
// cycle while busy is low. busy rises immediately and falls when the phase is
// complete. After a cmd_write, ack_err reflects whether the slave ACKed.
//
// Bit timing is a four-phase cell per SCL period:
//   p0  SCL low, SDA driven to the new value
//   p1  SCL released (rising edge); data must already be stable
//   p2  SCL high
//   p3  SCL pulled low again
// START and STOP need SDA to move while SCL is high, so they use their own
// phase ordering rather than the data cell.

module i2c_master #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer I2C_HZ = 400_000
) (
    input  wire       clk,
    input  wire       rst,

    input  wire       cmd_start,   // START, or repeated START
    input  wire       cmd_write,   // shift out wr_data, then sample ACK
    input  wire       cmd_stop,    // STOP
    input  wire [7:0] wr_data,
    output wire       busy,
    output reg        ack_err,     // sticky until the next cmd_start

    inout  wire       scl,
    inout  wire       sda
);

    // Quarter-period in clocks, rounded up so the bus never runs fast.
    localparam integer QUARTER = (CLK_HZ + (I2C_HZ * 4) - 1) / (I2C_HZ * 4);
    localparam integer QW      = $clog2(QUARTER + 1);

    // Open drain: drive low or let go. Never drive high.
    reg scl_low, sda_low;
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;

    // Synchronise SDA in before sampling the ACK.
    reg [1:0] sda_sync;
    always @(posedge clk) sda_sync <= {sda_sync[0], sda};
    wire sda_in = sda_sync[1];

    localparam S_IDLE  = 3'd0,
               S_START = 3'd1,
               S_BITS  = 3'd2,
               S_ACK   = 3'd3,
               S_STOP  = 3'd4;

    reg [2:0]    state;
    reg [1:0]    phase;
    reg [QW:0]   tick;
    reg [2:0]    bit_idx;
    reg [7:0]    shifter;
    reg          busy_r;

    // busy must be true in the same cycle a command pulse is presented, not
    // one cycle later. Otherwise a caller that issues cmd_stop and then looks
    // at busy on the very next cycle still sees idle, fires cmd_start, and
    // that START is silently dropped because the FSM has already left S_IDLE.
    assign busy = busy_r | cmd_start | cmd_write | cmd_stop;

    wire tick_done = (tick == QUARTER - 1);

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            phase   <= 2'd0;
            tick    <= 0;
            busy_r  <= 1'b0;
            ack_err <= 1'b0;
            scl_low <= 1'b0;      // bus released at reset
            sda_low <= 1'b0;
            bit_idx <= 3'd0;
        end else begin

            if (state == S_IDLE) begin
                tick  <= 0;
                phase <= 2'd0;
                if (cmd_start) begin
                    shifter <= 8'h00;
                    ack_err <= 1'b0;          // fresh transaction
                    busy_r  <= 1'b1;
                    state   <= S_START;
                end else if (cmd_write) begin
                    shifter <= wr_data;
                    bit_idx <= 3'd0;
                    busy_r  <= 1'b1;
                    state   <= S_BITS;
                end else if (cmd_stop) begin
                    busy_r  <= 1'b1;
                    state   <= S_STOP;
                end
            end else begin
                // every state below advances on the quarter tick
                if (!tick_done) begin
                    tick <= tick + 1'b1;
                end else begin
                    tick  <= 0;
                    phase <= phase + 2'd1;

                    case (state)
                        // START: SDA falls while SCL is high.
                        S_START: case (phase)
                            2'd0: begin sda_low <= 1'b0; scl_low <= 1'b0; end  // both released
                            2'd1: begin sda_low <= 1'b1;                  end  // SDA low, SCL still high
                            2'd2: begin scl_low <= 1'b1;                  end  // SCL low: ready for data
                            2'd3: begin busy_r <= 1'b0; state <= S_IDLE;    end
                        endcase

                        // Data bits, MSB first.
                        S_BITS: case (phase)
                            2'd0: begin scl_low <= 1'b1; sda_low <= ~shifter[7]; end
                            2'd1: begin scl_low <= 1'b0;                          end
                            2'd2: begin /* SCL high, slave samples */             end
                            2'd3: begin
                                scl_low <= 1'b1;
                                if (bit_idx == 3'd7) begin
                                    state <= S_ACK;
                                end else begin
                                    bit_idx <= bit_idx + 3'd1;
                                    shifter <= {shifter[6:0], 1'b0};
                                end
                            end
                        endcase

                        // Ninth clock: release SDA, slave pulls it low to ACK.
                        S_ACK: case (phase)
                            2'd0: begin scl_low <= 1'b1; sda_low <= 1'b0; end
                            2'd1: begin scl_low <= 1'b0;                  end
                            2'd2: begin ack_err <= ack_err | sda_in;      end  // high = NACK
                            2'd3: begin
                                scl_low <= 1'b1;
                                busy_r  <= 1'b0;
                                state   <= S_IDLE;
                            end
                        endcase

                        // STOP: SDA rises while SCL is high.
                        S_STOP: case (phase)
                            2'd0: begin scl_low <= 1'b1; sda_low <= 1'b1; end
                            2'd1: begin scl_low <= 1'b0;                  end  // SCL high, SDA still low
                            2'd2: begin sda_low <= 1'b0;                  end  // SDA rises: STOP
                            2'd3: begin busy_r <= 1'b0; state <= S_IDLE;    end  // bus idle
                        endcase

                        default: state <= S_IDLE;
                    endcase
                end
            end
        end
    end

endmodule

