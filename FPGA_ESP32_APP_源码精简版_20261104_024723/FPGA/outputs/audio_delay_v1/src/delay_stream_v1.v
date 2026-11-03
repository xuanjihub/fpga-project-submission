// Shared mono single echo. Store expression-scaled samples before final MASTER;
// feedback is zero. Every in_valid request returns exactly one clock later in
// every mode. reset/clear cancel pending requests and invalidate all history.
// enabled/D edits restart history; wet edits preserve it, including wet=0.
// Output coefficients and history-valid state are snapshotted per request.
module delay_stream_v1 #(parameter ADDR_BITS = 14) (
    input wire clk,
    input wire reset,
    input wire clear,
    input wire in_valid,
    input wire signed [15:0] in_sample,
    input wire enabled,
    input wire [ADDR_BITS-1:0] delay_samples,
    input wire [4:0] wet_level,
    output reg out_valid,
    output reg signed [15:0] out_sample
);
    localparam DEPTH = (1 << ADDR_BITS);
    localparam [ADDR_BITS-1:0] LAST_COUNT = {ADDR_BITS{1'b1}};
    // Separate synchronous read/write ports; reset covers the control registers only.
    // Valid length masks uninitialized/stale contents. D=0 bypasses RAM;
    // 1<=D<DEPTH guarantees distinct simultaneous read/write addresses.
    reg signed [15:0] history [0:DEPTH-1];
    reg signed [15:0] ram_read_sample;
    reg [ADDR_BITS-1:0] write_ptr, valid_count;
    reg cfg_enabled;
    reg [ADDR_BITS-1:0] cfg_delay;
    wire wet_legal = (wet_level <= 5'd16);
    wire config_changed = (enabled != cfg_enabled) ||
                          (delay_samples != cfg_delay);
    wire history_restart = config_changed || !wet_legal;
    wire [ADDR_BITS-1:0] request_write_addr = history_restart ? 0 : write_ptr;
    wire [ADDR_BITS-1:0] request_read_addr = request_write_addr - delay_samples;
    wire [ADDR_BITS-1:0] request_valid_count = history_restart ? 0 : valid_count;
    wire ram_write_enable = in_valid && enabled && (delay_samples != 0) &&
                            wet_legal && !reset && !clear;
    wire ram_read_enable = ram_write_enable;
    always @(posedge clk) begin
        if (ram_write_enable) history[request_write_addr] <= in_sample;
        if (ram_read_enable) ram_read_sample <= history[request_read_addr];
    end

    reg request_valid;
    reg signed [15:0] request_dry;
    reg [4:0] request_wet;
    reg request_mix, request_history_valid, request_bad_wet;
    // Full signed products/sum, with one floor quantization after summation.
    // Nonnegative coefficients sum to16, so legal inputs remain in signed16.
    wire signed [15:0] wet_sample = request_history_valid ? ram_read_sample : 16'sd0;
    wire [4:0] dry_weight = 5'd16 - request_wet;
    wire signed [21:0] dry_product =
        $signed(request_dry) * $signed({1'b0, dry_weight});
    wire signed [21:0] wet_product =
        $signed(wet_sample) * $signed({1'b0, request_wet});
    wire signed [22:0] mix_sum = $signed({dry_product[21], dry_product}) +
                                $signed({wet_product[21], wet_product});
    wire signed [22:0] mixed_quantized = mix_sum >>> 4;
    wire signed [15:0] mixed_sample =
        (mixed_quantized > 23'sd32767) ? 16'sh7fff :
        (mixed_quantized < -23'sd32768) ? 16'sh8000 : mixed_quantized[15:0];

    always @(posedge clk) begin
        cfg_enabled <= enabled;
        cfg_delay <= delay_samples;
        if (reset || clear) begin
            write_ptr <= 0;
            valid_count <= 0;
            request_valid <= 0;
            request_dry <= 0;
            request_wet <= 0;
            request_mix <= 0;
            request_history_valid <= 0;
            request_bad_wet <= 0;
            out_valid <= 0;
            out_sample <= 0;
        end else begin
            // Runtime edits preserve already accepted sample identity. Only
            // reset/clear cancel in-flight output. Length edits deliberately
            // restart history, so a length change is a time discontinuity.
            out_valid <= request_valid;
            if (request_valid) begin
                if (request_bad_wet) out_sample <= 0;
                else if (request_mix) out_sample <= mixed_sample;
                else out_sample <= request_dry;
            end
            request_valid <= in_valid;
            if (in_valid) begin
                request_dry <= in_sample;
                request_wet <= wet_legal ? wet_level : 5'd0;
                request_mix <= enabled && (delay_samples != 0) &&
                               (wet_level != 0) && wet_legal;
                request_history_valid <= enabled && (delay_samples != 0) &&
                    wet_legal && (request_valid_count >= delay_samples);
                request_bad_wet <= !wet_legal;
            end
            if (history_restart || !enabled || (delay_samples == 0)) begin
                write_ptr <= 0;
                valid_count <= 0;
            end
            if (ram_write_enable) begin
                write_ptr <= request_write_addr + 1'b1;
                if (request_valid_count != LAST_COUNT)
                    valid_count <= request_valid_count + 1'b1;
                else valid_count <= LAST_COUNT;
            end
        end
    end
endmodule
