`timescale 1ns/1ps
// Standard adapter around the unchanged S12 pressure expression path.
// adc_strobe is already FSR-filtered, adc_valid is sustained source status,
// and adc_age is that raw channel's receive age.
module fsr_input #(
    parameter integer CLK_HZ = 50000000
) (
    input wire clk,
    input wire reset,
    input wire sample_ce,
    input wire adc_strobe,
    input wire adc_valid,
    input wire signed [15:0] adc_raw,
    input wire [31:0] adc_age,
    input wire [31:0] time_now,
    output wire [111:0] packet,
    output wire [11:0] level,
    output wire [11:0] gain,
    output wire level_valid,
    output wire pressed
);
    // Audio-rate slew and the fourteen-clock normalization delay are
    // retained. The unused old audio multiply can be trimmed.
    s12_pressure_gain #(.CLK_HZ(CLK_HZ)) pressure (
        .clk(clk), .reset(reset), .sample_ce(sample_ce),
        .adc_strobe(adc_strobe), .adc_valid(adc_valid), .adc_raw(adc_raw),
        .audio_in(16'sd0), .audio_out(), .level(level), .gain(gain),
        .valid(level_valid), .pressed(pressed)
    );
    reg [15:0] seq;
    reg [31:0] timestamp;
    always @(posedge clk) begin
        if (reset) begin
            seq <= 16'd0;
            timestamp <= 32'd0;
        end else if (adc_strobe && adc_valid) begin
            seq <= seq + 16'd1;
            timestamp <= time_now;
        end
    end
    wire usable = adc_valid && level_valid;
    wire stale = adc_valid && !level_valid && (adc_age >= CLK_HZ / 50);
    wire [7:0] flags = {4'b0, pressed, stale, !adc_valid, usable};
    // Timestamp marks ADC reception. The
    // value/aux wires remain live between ADC strobes, including sample_ce.
    // Unconsumed metadata registers can be removed by synthesis.
    input_snapshot #(.SOURCE(8'd2), .KIND(4'd2), .CONTROL(8'd0)) snapshot (
        .flags(flags), .seq(seq), .timestamp(timestamp),
        .value({4'b0, level}), .aux({4'b0, gain}), .packet(packet)
    );
endmodule
