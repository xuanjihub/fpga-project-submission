`timescale 1ns/1ps
// All resets are synchronous to clk. Configuration initial values hold POR
// until the oscillator has supplied STARTUP_CYCLES rising edges. S4 is a
// debounced soft reset whose own filter keeps running.
module s09_control #(
    parameter integer STARTUP_CYCLES = 1048576,
    parameter integer DEBOUNCE_CYCLES = 105000
)(
    input wire clk,
    input wire [2:0] key_n,
    output wire reset,
    output wire power_reset,
    output reg [2:0] pressed = 0
);
    localparam integer SW = (STARTUP_CYCLES < 2) ? 1 : $clog2(STARTUP_CYCLES);
    localparam integer DW = (DEBOUNCE_CYCLES < 2) ? 1 : $clog2(DEBOUNCE_CYCLES);
    reg [SW-1:0] startup_count = 0;
    reg por = 1;
    (* syn_keep = 1 *) reg [2:0] key_meta = 3'b111;
    (* syn_keep = 1 *) reg [2:0] key_sync = 3'b111;
    reg [DW-1:0] stable_count [0:2];
    integer i;
    initial begin
        for (i=0; i<3; i=i+1) stable_count[i] = 0;
`ifndef SYNTHESIS
        if (STARTUP_CYCLES < 1 || DEBOUNCE_CYCLES < 1)
            $fatal(1, "invalid adc_board_control parameters");
`endif
    end
    always @(posedge clk) begin
        key_meta <= key_n;
        key_sync <= key_meta;
        if (por) begin
            if (startup_count == STARTUP_CYCLES-1) por <= 0;
            else startup_count <= startup_count + 1'b1;
            pressed <= 0;
            for (i=0; i<3; i=i+1) stable_count[i] <= 0;
        end else begin
            for (i=0; i<3; i=i+1) begin
                if ((~key_sync[i]) == pressed[i]) stable_count[i] <= 0;
                else if (stable_count[i] == DEBOUNCE_CYCLES-1) begin
                    pressed[i] <= ~key_sync[i];
                    stable_count[i] <= 0;
                end else stable_count[i] <= stable_count[i] + 1'b1;
            end
        end
    end
    assign reset = por | pressed[0];
    assign power_reset = por;
endmodule
