`timescale 1ns/1ps
// Shared-bus transaction client fork. Scheduler owns the physical master.
// Independent ADS deadlines/validity/error counters retained from sampler.
// Raw signed values only: pressure calibration/smoothing belongs downstream.
module shared_ads_client #(
    parameter integer CLK_HZ = 52_500_000,
    parameter integer I2C_HZ = 100_000,
    parameter [6:0] ADDRESS = 7'h48,
    parameter integer POWERUP_CYCLES = CLK_HZ / 100,
    parameter integer POLL_CYCLES = CLK_HZ / 5000,
    parameter integer CONVERSION_TIMEOUT_CYCLES = CLK_HZ / 200,
    parameter integer TRANSACTION_TIMEOUT_CYCLES = CLK_HZ / 100,
    parameter integer LINE_TIMEOUT_CYCLES = CLK_HZ / 1000,
    parameter integer RETRY_CYCLES = CLK_HZ / 100,
    parameter integer STALE_CYCLES = CLK_HZ / 20
) (
    input wire clk, reset,
    output wire req_valid, req_read,
    output wire [7:0] req_reg,
    output wire [15:0] config_word,
    input wire req_ready, rsp_valid, rsp_error,
    input wire [3:0] rsp_error_code,
    input wire [15:0] rsp_rdata,
    output reg sample_strobe,
    output reg sample_channel,
    output reg signed [15:0] sample_raw,
    output reg signed [15:0] raw0, raw1,
    output reg [1:0] data_valid,
    output reg [31:0] sample_sequence,
    output reg [31:0] age0, age1,
    output reg [31:0] error_count,
    output reg [7:0] last_error
);
    localparam [3:0] POWERUP=0, CFG_REQ=1, CFG_WAIT=2, POLL_DELAY=3,
        POLL_REQ=4, POLL_WAIT=5, READ_REQ=6, READ_WAIT=7, RETRY=8;
    reg [3:0] state;
    reg channel;
    reg [31:0] delay_count, transaction_count, conversion_count;
    // On a client deadline the arbiter retains ownership and drains the old
    // physical response before accepting any retry.
    assign req_valid = (state == CFG_REQ || state == POLL_REQ || state == READ_REQ);
    assign req_read = (state != CFG_REQ);
    assign req_reg = (state == READ_REQ) ? 8'h00 : 8'h01;
    assign config_word = channel ? 16'hD3E3 : 16'hC3E3;
    wire waiting = (state == CFG_WAIT || state == POLL_WAIT || state == READ_WAIT);
    wire transaction_active = req_valid || waiting;
    wire conversion_active = (state == POLL_DELAY || state == POLL_REQ || state == POLL_WAIT);
    wire conversion_expired = conversion_active &&
        (conversion_count >= CONVERSION_TIMEOUT_CYCLES - 1);
    wire transaction_expired = transaction_active &&
        (transaction_count >= TRANSACTION_TIMEOUT_CYCLES - 1);
    wire response_failed = waiting && rsp_valid && rsp_error;
    wire config_mismatch = (state == POLL_WAIT) && rsp_valid && !rsp_error &&
        (rsp_rdata[14:0] != config_word[14:0]);

`ifndef SYNTHESIS
    initial begin
        if (POWERUP_CYCLES < 1 || POLL_CYCLES < 1 ||
            CONVERSION_TIMEOUT_CYCLES < 1 || TRANSACTION_TIMEOUT_CYCLES < 1 ||
            LINE_TIMEOUT_CYCLES < 1 || RETRY_CYCLES < 1 || STALE_CYCLES < 1)
            $fatal(1, "ads1115_sampler timing parameters must be positive");
    end
`endif

    always @(posedge clk) begin
        if (reset) begin
            state <= POWERUP;
            channel <= 0;
            delay_count <= 0;
            transaction_count <= 0;
            conversion_count <= 0;
            sample_strobe <= 0;
            sample_channel <= 0;
            sample_raw <= 0;
            raw0 <= 0; raw1 <= 0;
            data_valid <= 0;
            sample_sequence <= 0;
            age0 <= 32'hffffffff; age1 <= 32'hffffffff;
            error_count <= 0;
            last_error <= 0;
        end else begin
            sample_strobe <= 0;
            if (age0 != 32'hffffffff) age0 <= age0 + 1'b1;
            if (age1 != 32'hffffffff) age1 <= age1 + 1'b1;
            if (age0 >= STALE_CYCLES-1) data_valid[0] <= 0;
            if (age1 >= STALE_CYCLES-1) data_valid[1] <= 0;
            if (transaction_active) transaction_count <= transaction_count + 1'b1;
            else transaction_count <= 0;
            if (conversion_active) conversion_count <= conversion_count + 1'b1;
            else conversion_count <= 0;

            // Fault is atomic: it suppresses publication, invalidates BOTH
            // channels, and retries from A0 after the arbiter drains any old
            // transaction. Retain raw values for diagnostics; bus recovery
            // belongs to the arbiter.
            // 01=conversion deadline, 02=transaction deadline, 03=config echo;
            // 1x=I2C master error code. last_error is sticky until system reset.
            if (conversion_expired || transaction_expired || response_failed || config_mismatch) begin
                if (conversion_expired) last_error <= 8'h01;
                else if (transaction_expired) last_error <= 8'h02;
                else if (response_failed) last_error <= {4'h1, rsp_error_code};
                else last_error <= 8'h03;
                if (error_count != 32'hffffffff) error_count <= error_count + 1'b1;
                data_valid <= 0;
                delay_count <= 0;
                transaction_count <= 0;
                conversion_count <= 0;
                channel <= 0;
                state <= RETRY;
            end else begin
                case (state)
                    POWERUP, RETRY: begin
                        if (delay_count >= ((state == POWERUP) ? POWERUP_CYCLES : RETRY_CYCLES)-1) begin
                            delay_count <= 0;
                            state <= CFG_REQ;
                        end else delay_count <= delay_count + 1'b1;
                    end
                    CFG_REQ: if (req_ready) state <= CFG_WAIT;
                    CFG_WAIT: if (rsp_valid) begin
                        transaction_count <= 0;
                        conversion_count <= 0;
                        delay_count <= 0;
                        state <= POLL_DELAY;
                    end
                    POLL_DELAY: begin
                        if (delay_count >= POLL_CYCLES-1) begin
                            delay_count <= 0;
                            state <= POLL_REQ;
                        end else delay_count <= delay_count + 1'b1;
                    end
                    POLL_REQ: if (req_ready) state <= POLL_WAIT;
                    POLL_WAIT: if (rsp_valid) begin
                        transaction_count <= 0;
                        delay_count <= 0;
                        // First poll may already be ready; the busy flag comes
                        // from that response.
                        state <= rsp_rdata[15] ? READ_REQ : POLL_DELAY;
                    end
                    READ_REQ: if (req_ready) state <= READ_WAIT;
                    READ_WAIT: if (rsp_valid) begin
                        sample_strobe <= 1;
                        sample_channel <= channel;
                        sample_raw <= rsp_rdata;
                        sample_sequence <= sample_sequence + 1'b1;
                        if (channel) begin
                            raw1 <= rsp_rdata;
                            age1 <= 0;
                            data_valid[1] <= 1;
                        end else begin
                            raw0 <= rsp_rdata;
                            age0 <= 0;
                            data_valid[0] <= 1;
                        end
                        transaction_count <= 0;
                        channel <= !channel;
                        state <= CFG_REQ;
                    end
                    default: begin
                        state <= POWERUP;
                        delay_count <= 0;
                        data_valid <= 0;
                    end
                endcase
            end
        end
    end
endmodule
