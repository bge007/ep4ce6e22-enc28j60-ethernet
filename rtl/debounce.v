// debounce.v -- N independent button debouncers.
//
// The board's buttons are active low and externally pulled up. Inputs are
// synchronised first (they are asynchronous to clk), then a per-button counter
// requires the level to hold steady for STABLE_MS before the output follows.
//
// Output is active HIGH -- pressed = 1 -- so the rest of the design does not
// have to keep inverting.

module debounce #(
    parameter integer N         = 4,
    parameter integer CLK_HZ    = 50_000_000,
    parameter integer STABLE_MS = 10
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [N-1:0] btn_n,        // raw, active low
    output reg  [N-1:0] pressed,      // debounced, active high
    output reg  [N-1:0] rise,         // 1-cycle pulse on press
    output reg  [N-1:0] fall          // 1-cycle pulse on release
);

    localparam integer TICKS = (CLK_HZ / 1000) * STABLE_MS;
    localparam integer CW    = $clog2(TICKS + 1);

    reg [N-1:0] sync0, sync1;
    always @(posedge clk) begin
        sync0 <= ~btn_n;              // to active high
        sync1 <= sync0;
    end

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_btn
            reg [CW:0] cnt;
            always @(posedge clk) begin
                rise[i] <= 1'b0;
                fall[i] <= 1'b0;

                if (rst) begin
                    cnt        <= 0;
                    pressed[i] <= 1'b0;
                end else if (sync1[i] == pressed[i]) begin
                    cnt <= 0;                       // agrees with output, nothing to do
                end else if (cnt == TICKS) begin
                    cnt        <= 0;
                    pressed[i] <= sync1[i];
                    if (sync1[i]) rise[i] <= 1'b1;
                    else          fall[i] <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    endgenerate

endmodule
