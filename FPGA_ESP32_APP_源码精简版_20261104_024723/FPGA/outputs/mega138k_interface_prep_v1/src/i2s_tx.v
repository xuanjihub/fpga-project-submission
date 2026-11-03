`timescale 1ns/1ps
// Standalone Philips I2S transmitter.
// 16-bit signed stereo in 32-bit slots: LRCK=0 left, LRCK=1 right.
// Change DATA/WS on BCK falling edges; receiver samples on rising edges.
// The MSB follows the WS transition by one BCK. Remaining bits are zero.
// Fs = clk_hz / (128 * BCLK_HALF_PERIOD).
// Example: 24.576 MHz / (128 * 4) = 48 kHz.
// sample_ce captures BOTH inputs and mute on the same clk edge. A producer
// updating via nonblocking assignments on that edge supplies the NEXT frame.
// reset is active-high SYNCHRONOUS: integration must synchronize external reset
// and all inputs to clk. sample_ce is a combinational enable.
// Future UI/BLE controls must enter upstream control logic and leave the
// clocks untouched.
module i2s_tx #(
    parameter integer BCLK_HALF_PERIOD = 4
) (
    input wire clk,
    input wire reset,
    input wire signed [15:0] sample_left,
    input wire signed [15:0] sample_right,
    input wire mute,
    output wire sample_ce,
    output reg bclk,
    output reg lrck,
    output reg dout
);
    localparam integer CW = (BCLK_HALF_PERIOD > 1) ? $clog2(BCLK_HALF_PERIOD) : 1;
    reg [CW-1:0] divider;
    reg [5:0] slot;
    reg [15:0] left_latched, right_latched;
    wire terminal = (divider == BCLK_HALF_PERIOD - 1);
    wire [5:0] next_slot = slot + 6'd1;

    // Simulation rejects invalid configuration; synthesis integration must also
    // validate the parameter.
`ifndef SYNTHESIS
    initial begin
        if (BCLK_HALF_PERIOD < 1)
            $fatal(1, "invalid BCLK_HALF_PERIOD: must be >= 1");
    end
`endif
    assign sample_ce = !reset && terminal && bclk && (slot == 6'd63);

    always @(posedge clk) begin
        if (reset) begin
            divider <= 0;
            slot <= 6'd63;
            bclk <= 1'b1;
            lrck <= 1'b1;
            dout <= 1'b0;
            left_latched <= 0;
            right_latched <= 0;
        end else if (terminal) begin
            divider <= 0;
            bclk <= !bclk;
            if (bclk) begin
                slot <= next_slot;
                lrck <= next_slot[5];
                if (next_slot == 0) begin
                    left_latched <= mute ? 16'b0 : sample_left;
                    right_latched <= mute ? 16'b0 : sample_right;
                end
                if (next_slot >= 1 && next_slot <= 16)
                    dout <= left_latched[16 - next_slot];
                else if (next_slot >= 33 && next_slot <= 48)
                    dout <= right_latched[48 - next_slot];
                else
                    dout <= 1'b0;
            end
        end else begin
            divider <= divider + 1'b1;
        end
    end
endmodule
