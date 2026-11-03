`timescale 1ns/1ps
// Predict the frozen s15_poll_core touch-age comparison for the next edge.
// This is cycle-equivalent to touch_age >= CLK_HZ/50.
// The retained core saturates age, resets it to ffffffff, and clears it
// on exactly touch_update && m_ready && !m_fault. Keep that source hash-bound.
module ble_touch_freshness_v1 #(
    parameter integer CLK_HZ = 50000000
)(
    input wire clk, reset, touch_update, m_ready, m_fault,
    input wire [31:0] touch_age,
    output wire stale,
    output wire usable
);
    localparam [31:0] STALE_CYCLES = CLK_HZ / 50;
    generate
        if (STALE_CYCLES == 0) begin : zero_threshold
            assign stale = 1'b1;
        end else begin : positive_threshold
            reg predicted_stale;
            assign stale = predicted_stale;
            always @(posedge clk) begin
                if (reset)
                    predicted_stale <= 1'b1;
                else if (touch_update && m_ready && !m_fault)
                    predicted_stale <= 1'b0;
                else
                    predicted_stale <= touch_age >= STALE_CYCLES - 32'd1;
            end
        end
    endgenerate
    // Ready/fault remain combinational, so failure and recovery respond in
    // the same cycle. Physical STOP and reset paths bypass this predictor.
    assign usable = m_ready && !m_fault && !stale;
endmodule
