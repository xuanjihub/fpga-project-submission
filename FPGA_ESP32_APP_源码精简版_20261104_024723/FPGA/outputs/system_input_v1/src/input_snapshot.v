`timescale 1ns/1ps
// Fixed v1 input snapshot. Pure combinational wiring.
// flags: bit0 sustained valid, bit1 source fault, bit2 stale, bit3 pressed.
// Consumers test flags[0]; zero is a legitimate value.
module input_snapshot #(
    parameter [7:0] SOURCE = 8'd1,
    parameter [3:0] KIND = 4'd1,
    parameter [7:0] CONTROL = 8'd0
) (
    input wire [7:0] flags,
    input wire [15:0] seq,
    input wire [31:0] timestamp,
    input wire [15:0] value,
    input wire [15:0] aux,
    output wire [111:0] packet
);
    // Preserve caller flags; source adapters provide reserved zero bits.
    assign packet = {aux, value, timestamp, seq, CONTROL, flags, KIND, SOURCE, 4'd1};
endmodule
