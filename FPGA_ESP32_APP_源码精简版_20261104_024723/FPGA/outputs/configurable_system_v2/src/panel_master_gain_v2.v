`timescale 1ns/1ps
// Independent master attenuation, preceding the existing mixer gain input.
// 17 panel targets: 0..16 = 0..100%. Q12 unity is exactly 4096, so the
// default preserves every expression gain bit. Only the coefficient ramps,
// at 32/4096 per audio sample tick.
module panel_master_gain_v2 (
    input wire clk, reset, sample_ce,
    input wire [4:0] master_volume,
    input wire [11:0] expression_gain,
    output wire [11:0] gain,
    output wire [12:0] smooth_gain
);
    // Targets and ramp steps are multiples of 32. Keep that common factor
    // outside the multiplier: 0..128 represents the same Q12 coefficient.
    reg [7:0] ramp_level;
    // Out-of-contract targets fail closed to zero gain.
    wire [7:0] target = master_volume <= 5'd16 ? {master_volume,3'b0} : 8'd0;
    assign smooth_gain = {ramp_level,5'b0};
    always @(posedge clk) begin
        if (reset) ramp_level <= 8'd128;
        else if (sample_ce) begin
            if (ramp_level < target)
                ramp_level <= ramp_level+8'd1;
            else if (ramp_level > target)
                ramp_level <= ramp_level-8'd1;
        end
    end
    (* syn_keep = 1 *) wire [19:0] product = expression_gain * ramp_level;
    // Both operands are nonnegative and the coefficient stays within unity.
    // Max product 4095*128 fits 19 bits. Dividing by 128 is exactly the
    // original Q12 calculation after factoring out 32, including flooring.
    assign gain = product[18:7];
endmodule
