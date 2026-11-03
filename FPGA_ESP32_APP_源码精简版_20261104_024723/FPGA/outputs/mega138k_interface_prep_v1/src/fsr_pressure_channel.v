`timescale 1ns/1ps
// Offline FSR pressure channel: approximate normalized control value.
// Synchronous active-high reset.
module fsr_pressure_channel #(
    parameter integer CLK_HZ = 52_500_000,
    parameter integer STALE_CYCLES = CLK_HZ / 50,
    parameter integer RAW_ZERO = 0,
    parameter integer RAW_FULL = 24000,
    parameter integer SMOOTH_SHIFT = 0,
    parameter integer PRESS_ON = 128,
    parameter integer PRESS_OFF = 64
) (
    input wire clk,
    input wire reset,
    input wire sample_strobe,
    input wire sample_valid,
    input wire calibration_valid,
    input wire signed [15:0] sample_raw,
    output reg [11:0] level,
    output reg level_valid,
    output reg pressed,
    output reg updated,
    output reg [31:0] age_cycles,
    output wire config_error
);
    localparam integer RAW_SPAN = RAW_FULL - RAW_ZERO;
    // Positive compile-time divisor; equal endpoints are fail-closed below.
    localparam integer SAFE_DIVISOR = (RAW_SPAN < 0) ? -RAW_SPAN :
                                      ((RAW_SPAN == 0) ? 1 : RAW_SPAN);

    reg [15:0] clamped_distance;
    reg [15:0] distance_q;
    reg [27:0] remainder_pipe [0:12];
    reg [11:0] quotient_pipe [0:12];
    reg [13:0] valid_pipe;
    wire [11:0] target_level = quotient_pipe[12];
    wire invalid = reset || !calibration_valid || !sample_valid || config_error;

    reg [12:0] level_difference;
    reg [12:0] smoothing_step;
    reg [11:0] next_level;

    assign config_error = (RAW_ZERO == RAW_FULL);

    // Clamp the signed distance first. The exact numerator is at most
    // 65535*4095 = 268365825 (28 bits). Division is exact.
    // sample_raw is the only runtime input; explicit sensitivity also covers
    // the equal-endpoint constant branch without an empty @* sensitivity list.
    always @(sample_raw) begin
        clamped_distance = 0;

        if (RAW_FULL > RAW_ZERO) begin
            if ($signed(sample_raw) <= RAW_ZERO) begin
                clamped_distance = 0;
            end else if ($signed(sample_raw) >= RAW_FULL) begin
                clamped_distance = SAFE_DIVISOR;
            end else begin
                clamped_distance = $signed(sample_raw) - RAW_ZERO;
            end
        end else if (RAW_FULL < RAW_ZERO) begin
            if ($signed(sample_raw) >= RAW_ZERO) begin
                clamped_distance = 0;
            end else if ($signed(sample_raw) <= RAW_FULL) begin
                clamped_distance = SAFE_DIVISOR;
            end else begin
                clamped_distance = RAW_ZERO - $signed(sample_raw);
            end
        end
        // Equal endpoints leave distance zero and force fail-closed outputs.
    end

    // Accept at edge N; publish at N+14. One sample per clock is supported.
    // Invalidation flushes every in-flight valid bit before re-enabling.
    // Datapath bits are don't-care when their valid bit is low, which keeps
    // the arithmetic registers free of reset logic.
    always @(posedge clk) begin
        if (invalid)
            valid_pipe <= 14'b0;
        else
            valid_pipe <= {valid_pipe[12:0], sample_strobe};
        distance_q <= clamped_distance;
        remainder_pipe[0] <= ({12'b0, distance_q} << 12) - {12'b0, distance_q};
        quotient_pipe[0] <= 12'b0;
    end

    // Exact unsigned division: decide one of the twelve quotient bits per
    // registered stage. Each path is a single compare/subtract. All possible
    // quotients lie in 0..4095.
    genvar bit_stage;
    generate for (bit_stage = 0; bit_stage < 12; bit_stage = bit_stage + 1) begin: divide_stage
        localparam [27:0] TRIAL = SAFE_DIVISOR << (11-bit_stage);
        always @(posedge clk) begin
            if (remainder_pipe[bit_stage] >= TRIAL) begin
                remainder_pipe[bit_stage+1] <= remainder_pipe[bit_stage] - TRIAL;
                quotient_pipe[bit_stage+1] <= quotient_pipe[bit_stage] | (12'b1 << (11-bit_stage));
            end else begin
                remainder_pipe[bit_stage+1] <= remainder_pipe[bit_stage];
                quotient_pipe[bit_stage+1] <= quotient_pipe[bit_stage];
            end
        end
    end endgenerate

    // Move by ceil(abs(target-old)/2^SHIFT); a fresh first result seeds
    // directly. Commit only on publication, fourteen clocks after acceptance.
    always @* begin
        level_difference = 0;
        smoothing_step = 0;
        next_level = target_level;

        if (SMOOTH_SHIFT != 0 && level_valid) begin
            if (target_level >= level) begin
                level_difference = target_level - level;
            end else begin
                level_difference = level - target_level;
            end
            smoothing_step = (level_difference + ((1 << SMOOTH_SHIFT) - 1)) >> SMOOTH_SHIFT;

            if (target_level > level) begin
                if (smoothing_step >= level_difference)
                    next_level = target_level;
                else
                    next_level = level + smoothing_step[11:0];
            end else if (target_level < level) begin
                if (smoothing_step >= level_difference)
                    next_level = target_level;
                else
                    next_level = level - smoothing_step[11:0];
            end else begin
                next_level = level;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (CLK_HZ < 1)
            $fatal(1, "fsr_pressure_channel CLK_HZ must be positive");
        if (STALE_CYCLES < 1)
            $fatal(1, "fsr_pressure_channel STALE_CYCLES must be positive");
        if (RAW_ZERO < -32768 || RAW_ZERO > 32767 ||
            RAW_FULL < -32768 || RAW_FULL > 32767)
            $fatal(1, "fsr_pressure_channel raw endpoints must fit signed 16-bit samples");
        if (SMOOTH_SHIFT < 0 || SMOOTH_SHIFT > 4)
            $fatal(1, "fsr_pressure_channel SMOOTH_SHIFT must be in 0..4");
        if (PRESS_OFF < 0 || PRESS_OFF > 4095 ||
            PRESS_ON < 0 || PRESS_ON > 4095 || PRESS_OFF >= PRESS_ON)
            $fatal(1, "fsr_pressure_channel thresholds require 0<=OFF<ON<=4095");
    end
`endif

    always @(posedge clk) begin
        if (reset) begin
            level <= 12'd0;
            level_valid <= 1'b0;
            pressed <= 1'b0;
            updated <= 1'b0;
            age_cycles <= 32'hffffffff;
        end else if (!calibration_valid || !sample_valid || config_error) begin
            // Invalid controls dominate a coincident strobe and discard history.
            level <= 12'd0;
            level_valid <= 1'b0;
            pressed <= 1'b0;
            updated <= 1'b0;
            age_cycles <= 32'hffffffff;
        end else if (valid_pipe[13]) begin
            // Fresh publication wins over a simultaneous stale deadline. level_valid
            // determines whether to smooth from history or seed after a gap.
            level <= next_level;
            level_valid <= 1'b1;
            updated <= 1'b1;
            age_cycles <= 32'd0;

            if (!pressed && next_level >= PRESS_ON)
                pressed <= 1'b1;
            else if (pressed && next_level <= PRESS_OFF)
                pressed <= 1'b0;
        end else begin
            updated <= 1'b0;

            if (age_cycles != 32'hffffffff)
                age_cycles <= age_cycles + 1'b1;

            // Age is measured from publication (input age adds fourteen clocks).
            // Expire exactly STALE_CYCLES clocks after the last publication.
            if (age_cycles >= STALE_CYCLES - 1) begin
                level <= 12'd0;
                level_valid <= 1'b0;
                pressed <= 1'b0;
            end
        end
    end
endmodule
