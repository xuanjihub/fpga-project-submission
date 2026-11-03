// S15 polling candidate: isolated fork; one diagnostic transaction per touch cycle.
`timescale 1ns/1ps

// MPR121 bring-up and polling controller.
//
// Pure RTL implementation. It initializes the sensor by
// hardware state machine, continuously reads registers 0x00/0x01 in one I2C
// transaction, and atomically publishes all twelve touch bits.
module shared_mpr_client #(
    parameter integer CLK_HZ = 52_500_000,
    parameter integer I2C_HZ = 100_000,
    parameter [6:0] I2C_ADDRESS = 7'h5A,
    // Global CDT=0.5us fallback, ESI=1ms, SFI=4. Auto-config may select
    // per-electrode CDT; actual scan/filter delay still needs measurement.
    parameter [7:0] AFE_CONFIG2 = 8'h20,

    // These are conservative engineering delays.
    parameter integer POWERUP_WAIT_CYCLES = CLK_HZ/100,       // 10 ms
    parameter integer RESET_WAIT_CYCLES = CLK_HZ/200,         // 5 ms
    parameter integer SETTLE_WAIT_CYCLES = CLK_HZ/50,          // 20 ms
    parameter integer POLL_INTERVAL_CYCLES = CLK_HZ/1000,     // 1 ms
    parameter integer RETRY_BACKOFF_CYCLES = CLK_HZ/2,        // 500 ms
    parameter integer LINE_TIMEOUT_CYCLES = CLK_HZ/1000       // 1 ms
) (
    input  wire        clk,
    input  wire        reset,
    output wire master_req_valid,
    input wire master_req_ready, master_rsp_valid, master_rsp_error,
    input wire [15:0] master_rsp_rdata,
    input wire [3:0] master_rsp_error_code,
    output wire req_read2,
    output wire [6:0] req_addr,
    output wire [7:0] req_reg, req_data,


    output reg  [11:0] touch_mask,
    output reg         touch_update,
    output reg         ready,
    output reg         sensor_fault,
    output reg  [3:0]  last_i2c_error,
    output reg  [7:0]  error_count,
    output reg  [5:0]  init_index,
    output reg [15:0] raw_touch, health,
    output reg diag_valid,
    output reg [15:0] diag_seq,
    output reg [9:0] filtered0, filtered2,
    output reg [7:0] baseline0, baseline2,
    output reg [7:0] nhdt, nclt, fdlt,
    output reg [15:0] thresholds0, thresholds2
);

    localparam [3:0] C_POWER_WAIT = 4'd0;
    localparam [3:0] C_SEND       = 4'd1;
    localparam [3:0] C_WAIT_RSP   = 4'd2;
    localparam [3:0] C_RESET_WAIT = 4'd3;
    localparam [3:0] C_INIT_PREP  = 4'd4;
    localparam [3:0] C_SETTLE     = 4'd5;
    localparam [3:0] C_POLL_WAIT  = 4'd6;
    localparam [3:0] C_RETRY_WAIT = 4'd7;

    localparam [3:0] TAG_SOFT_RESET = 4'd0;
    localparam [2:0] TAG_VERIFY     = 3'd1;
    localparam [2:0] TAG_FORCE_STOP = 3'd2;
    localparam [2:0] TAG_INIT       = 3'd3;
    localparam [2:0] TAG_RUN        = 3'd4;
    localparam [2:0] TAG_FIRST_POLL = 3'd5;
    localparam [2:0] TAG_POLL       = 3'd6;
    localparam [2:0] TAG_HEALTH     = 3'd7;
    localparam [3:0] TAG_DIAG = 4'd8;

    localparam [5:0] INIT_LAST = 6'd37;

    reg [3:0] controller_state;
    reg [3:0] transaction_tag;
    reg [3:0] poll_div;
    reg [2:0] diag_index;
    reg diag_in_progress;
    reg [15:0] diag_pending [0:7];
    integer d;
    reg       pending_read2;
    reg [7:0] pending_reg;
    reg [7:0] pending_data;
    reg [31:0] wait_count;
    reg [11:0] pending_touch;

    assign master_req_valid = (controller_state == C_SEND);
    assign req_read2=pending_read2;
    assign req_addr=I2C_ADDRESS;
    assign req_reg=pending_reg;
    assign req_data=pending_data;

    function [7:0] table_reg;
        input [5:0] index;
        begin
            if (index <= 6'd7)
                table_reg = 8'h2B + index;
            else if (index <= 6'd31)
                table_reg = 8'h41 + (index - 6'd8);
            else begin
                case (index)
                    6'd32: table_reg = 8'h5D;
                    6'd33: table_reg = 8'h7B;
                    6'd34: table_reg = 8'h7C;
                    6'd35: table_reg = 8'h7D;
                    6'd36: table_reg = 8'h7E;
                    default: table_reg = 8'h7F;
                endcase
            end
        end
    endfunction

    function [7:0] table_data;
        input [5:0] index;
        begin
            case (index)
                6'd0: table_data = 8'h01; // MHDR
                6'd1: table_data = 8'h01; // NHDR
                6'd2: table_data = 8'h00; // NCLR
                6'd3: table_data = 8'h00; // FDLR
                6'd4: table_data = 8'h01; // MHDF
                6'd5: table_data = 8'h01; // NHDF
                6'd6: table_data = 8'hFF; // NCLF
                6'd7: table_data = 8'h02; // FDLF
                6'd32: table_data = AFE_CONFIG2;
                6'd33: table_data = 8'h0B; // AUTOCONFIG0
                6'd34: table_data = 8'h00; // AUTOCONFIG1
                6'd35: table_data = 8'h9C; // USL
                6'd36: table_data = 8'h65; // LSL
                6'd37: table_data = 8'h8C; // TL
                default: begin
                    // 0x41..0x58: touch 0x0F, release 0x0A.
                    if (index[0] == 1'b0)
                        table_data = 8'h0F;
                    else
                        table_data = 8'h0A;
                end
            endcase
        end
    endfunction

    // Read at most one diagnostic pair between successive touch/health polls.
    // Final diagnostic fields still publish atomically after all eight pairs.
    function [7:0] diag_register;
        input [2:0] index;
        begin
            case(index)
                0: diag_register=8'h04;
                1: diag_register=8'h08;
                2: diag_register=8'h1E;
                3: diag_register=8'h20;
                4: diag_register=8'h33;
                5: diag_register=8'h35;
                6: diag_register=8'h41;
                default: diag_register=8'h45;
            endcase
        end
    endfunction

    task queue_transaction;
        input read2;
        input [7:0] register_address;
        input [7:0] write_data;
        input [3:0] tag;
        begin
            pending_read2  <= read2;
            pending_reg    <= register_address;
            pending_data   <= write_data;
            transaction_tag <= tag;
            controller_state <= C_SEND;
        end
    endtask

    task enter_retry;
        input [3:0] error_code;
        begin
            touch_mask <= 12'd0;
            touch_update <= 1'b1;
            ready <= 1'b0;
            sensor_fault <= 1'b1;
            diag_valid <= 1'b0;
            poll_div <= 0;
            diag_in_progress <= 0;
            last_i2c_error <= error_code;
            if (error_count != 8'hFF)
                error_count <= error_count + 1'b1;
            wait_count <= 32'd0;
            controller_state <= C_RETRY_WAIT;
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            touch_mask       <= 12'd0;
            touch_update     <= 1'b0;
            ready            <= 1'b0;
            sensor_fault     <= 1'b0;
            last_i2c_error   <= 4'd0;
            error_count      <= 8'd0;
            init_index       <= 6'd0;
            controller_state <= C_POWER_WAIT;
            transaction_tag  <= TAG_SOFT_RESET;
            pending_read2    <= 1'b0;
            pending_reg      <= 8'd0;
            pending_data     <= 8'd0;
            wait_count       <= 32'd0;
            pending_touch    <= 12'd0;
            raw_touch <= 0; health <= 0;
            diag_valid <= 0; diag_seq <= 0; poll_div <= 0; diag_index <= 0; diag_in_progress <= 0;
            filtered0 <= 0; filtered2 <= 0; baseline0 <= 0; baseline2 <= 0;
            nhdt <= 0; nclt <= 0; fdlt <= 0; thresholds0 <= 0; thresholds2 <= 0;
            for (d=0; d<8; d=d+1) diag_pending[d] <= 0;
        end else begin
            touch_update <= 1'b0;

            case (controller_state)
                C_POWER_WAIT: begin
                    if ((POWERUP_WAIT_CYCLES <= 1) ||
                        (wait_count >= POWERUP_WAIT_CYCLES - 1)) begin
                        wait_count <= 32'd0;
                        queue_transaction(1'b0, 8'h80, 8'h63,
                                          TAG_SOFT_RESET);
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                C_SEND: begin
                    if (master_req_ready)
                        controller_state <= C_WAIT_RSP;
                end

                C_WAIT_RSP: begin
                    if (master_rsp_valid) begin
                        if (master_rsp_error) begin
                            enter_retry(master_rsp_error_code);
                        end else begin
                            case (transaction_tag)
                                TAG_SOFT_RESET: begin
                                    wait_count <= 32'd0;
                                    controller_state <= C_RESET_WAIT;
                                end

                                TAG_VERIFY: begin
                                    // read2 from 0x5C returns 0x5C in bits 7:0
                                    // and 0x5D in bits 15:8.
                                    if (master_rsp_rdata == 16'h2410)
                                        queue_transaction(1'b0, 8'h5E,
                                                          8'h00,
                                                          TAG_FORCE_STOP);
                                    else
                                        enter_retry(4'hF);
                                end

                                TAG_FORCE_STOP: begin
                                    init_index <= 6'd0;
                                    controller_state <= C_INIT_PREP;
                                end

                                TAG_INIT: begin
                                    if (init_index == INIT_LAST) begin
                                        // CL=10 initializes baselines from the
                                        // first measurement; ELE_EN=12.
                                        queue_transaction(1'b0, 8'h5E,
                                                          8'h8C, TAG_RUN);
                                    end else begin
                                        init_index <= init_index + 1'b1;
                                        controller_state <= C_INIT_PREP;
                                    end
                                end

                                TAG_RUN: begin
                                    wait_count <= 32'd0;
                                    controller_state <= C_SETTLE;
                                end

                                TAG_FIRST_POLL, TAG_POLL: begin
                                    raw_touch <= master_rsp_rdata;
                                    if (master_rsp_rdata[15]) begin
                                        enter_retry(4'hE);
                                    end else begin
                                        pending_touch <= master_rsp_rdata[11:0];
                                        queue_transaction(1'b1, 8'h02, 8'h00,
                                                          TAG_HEALTH);
                                    end
                                end

                                TAG_HEALTH: begin
                                    health <= master_rsp_rdata;
                                    // 0x02/03: ELE0..11 OOR and ACFF/ARFF.
                                    // Proximity is disabled; ignore its bit and reserved bit.
                                    if ((master_rsp_rdata & 16'hCFFF) != 0) begin
                                        enter_retry(4'hD);
                                    end else begin
                                        touch_mask <= pending_touch;
                                        touch_update <= 1'b1;
                                        ready <= 1'b1;
                                        sensor_fault <= 1'b0;
                                        last_i2c_error <= 4'd0;
                                        wait_count <= 32'd0;
                                        if (diag_in_progress) begin
                                            queue_transaction(1'b1, diag_register(diag_index), 8'h00, TAG_DIAG);
                                        end else if (poll_div == 0) begin
                                            diag_in_progress <= 1;
                                            diag_index <= 0;
                                            queue_transaction(1'b1, 8'h04, 8'h00, TAG_DIAG);
                                        end else controller_state <= C_POLL_WAIT;
                                        poll_div <= poll_div + 1'b1;
                                    end
                                end
                                TAG_DIAG: begin
                                    diag_pending[diag_index] <= master_rsp_rdata;
                                    if (diag_index == 7) begin
                                        // Atomic publication of a completed diagnostic scan.
                                        // Reads occur sequentially, one register pair at a time.
                                        filtered0 <= diag_pending[0][9:0];
                                        filtered2 <= diag_pending[1][9:0];
                                        baseline0 <= diag_pending[2][7:0];
                                        baseline2 <= diag_pending[3][7:0];
                                        nhdt <= diag_pending[4][7:0];
                                        nclt <= diag_pending[4][15:8];
                                        fdlt <= diag_pending[5][7:0];
                                        thresholds0 <= diag_pending[6];
                                        thresholds2 <= master_rsp_rdata;
                                        diag_seq <= diag_seq + 1'b1;
                                        diag_valid <= 1'b1;
                                        diag_in_progress <= 0;
                                        wait_count <= 0;
                                        controller_state <= C_POLL_WAIT;
                                    end else begin
                                        diag_index <= diag_index + 1'b1;
                                        wait_count <= 0;
                                        controller_state <= C_POLL_WAIT;
                                    end
                                end
                                default: enter_retry(4'hF);
                            endcase
                        end
                    end
                end

                C_RESET_WAIT: begin
                    if ((RESET_WAIT_CYCLES <= 1) ||
                        (wait_count >= RESET_WAIT_CYCLES - 1)) begin
                        wait_count <= 32'd0;
                        queue_transaction(1'b1, 8'h5C, 8'h00,
                                          TAG_VERIFY);
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                C_INIT_PREP: begin
                    queue_transaction(1'b0, table_reg(init_index),
                                      table_data(init_index), TAG_INIT);
                end

                C_SETTLE: begin
                    if ((SETTLE_WAIT_CYCLES <= 1) ||
                        (wait_count >= SETTLE_WAIT_CYCLES - 1)) begin
                        wait_count <= 32'd0;
                        queue_transaction(1'b1, 8'h00, 8'h00,
                                          TAG_FIRST_POLL);
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                C_POLL_WAIT: begin
                    if ((POLL_INTERVAL_CYCLES <= 1) ||
                        (wait_count >= POLL_INTERVAL_CYCLES - 1)) begin
                        wait_count <= 32'd0;
                        queue_transaction(1'b1, 8'h00, 8'h00,
                                          TAG_POLL);
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                default: begin // C_RETRY_WAIT
                    if ((RETRY_BACKOFF_CYCLES <= 1) ||
                        (wait_count >= RETRY_BACKOFF_CYCLES - 1)) begin
                        wait_count <= 32'd0;
                        init_index <= 6'd0;
                        controller_state <= C_POWER_WAIT;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
