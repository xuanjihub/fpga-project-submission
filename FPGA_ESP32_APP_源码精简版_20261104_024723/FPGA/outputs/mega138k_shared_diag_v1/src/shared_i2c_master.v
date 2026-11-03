`timescale 1ns/1ps

// Shared single-master fork of the verified ADS master. Original drivers stay
// unchanged. req_write8 selects one data byte from req_wdata[15:8]; otherwise
// write16 sends MSB then LSB. read2 always publishes MSB-first wire order;
// the MPR client adapter explicitly swaps its low-byte-first register pairs.
//
// Supported transactions:
//   write16: START, address+W, register, MSB, LSB, STOP
//   read2 : START, address+W, register, repeated START, address+R,
//           MSB+ACK, LSB+NACK, STOP; rsp_rdata has natural MSB-first order
//
// SCL and SDA are true open-drain outputs: this module only drives zero or Z.
// External pull-ups to the I/O-bank voltage are required on both lines.
module shared_i2c_master #(
    parameter integer CLK_HZ = 52_500_000,
    parameter integer I2C_HZ = 100_000,
    parameter integer LINE_TIMEOUT_CYCLES = 52_500
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_read2,
    input wire req_write8,
    input  wire [6:0]  req_addr7,
    input  wire [7:0]  req_reg,
    input  wire [15:0] req_wdata,

    output reg         rsp_valid,
    input  wire        rsp_ready,
    output reg  [15:0] rsp_rdata,
    output reg         rsp_error,
    output reg  [3:0]  rsp_error_code,
    output wire        busy,
    // Snapshot at the error edge; valid only with the error response.
    // Read-only telemetry outside bus timing/recovery decisions.
    // See P13 telemetry layout.
    output reg [39:0] fault_context,

    inout  wire        scl,
    inout  wire        sda
);

    // Ceiling division deliberately keeps the generated clock at or below
    // I2C_HZ. An extra qualified-high quarter also covers clock stretching;
    // ordinary bit rate is CLK_HZ/(5*QTR_CYCLES), ~79.55 kHz at defaults.
    localparam integer QTR_CYCLES =
        (CLK_HZ + (4 * I2C_HZ) - 1) / (4 * I2C_HZ);

    localparam [4:0] ST_IDLE       = 5'd0;
    localparam [4:0] ST_BUS_FREE   = 5'd1;
    localparam [4:0] ST_START      = 5'd2;
    localparam [4:0] ST_TX         = 5'd3;
    localparam [4:0] ST_TX_ACK     = 5'd4;
    localparam [4:0] ST_RESTART    = 5'd5;
    localparam [4:0] ST_RX         = 5'd6;
    localparam [4:0] ST_MASTER_ACK = 5'd7;
    localparam [4:0] ST_STOP       = 5'd8;
    localparam [4:0] ST_RESPONSE   = 5'd9;
    localparam [4:0] ST_BUS_CLEAR  = 5'd10;

    localparam [1:0] TX_ADDR_W = 2'd0;
    localparam [1:0] TX_REG    = 2'd1;
    localparam [1:0] TX_DATA   = 2'd2;
    localparam [1:0] TX_ADDR_R = 2'd3;

    localparam [3:0] ERR_NONE        = 4'd0;
    localparam [3:0] ERR_BUS_BUSY    = 4'd1;
    localparam [3:0] ERR_NACK_ADDR_W = 4'd2;
    localparam [3:0] ERR_NACK_REG    = 4'd3;
    localparam [3:0] ERR_NACK_DATA   = 4'd4;
    localparam [3:0] ERR_NACK_ADDR_R = 4'd5;
    localparam [3:0] ERR_SCL_TIMEOUT = 4'd6;

    reg scl_drive_low;
    reg sda_drive_low;

    assign scl = scl_drive_low ? 1'b0 : 1'bz;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    // Synchronizers also make the engine observe the real released line before
    // treating Z as logic one.
    reg scl_meta;
    reg scl_sync;
    reg sda_meta;
    reg sda_sync;

    reg [31:0] divider_count;
    wire qtr_tick = (divider_count >= (QTR_CYCLES - 1));

    reg [4:0] state;
    reg [2:0] phase;
    reg [2:0] bit_index;
    reg [1:0] tx_stage;
    reg [7:0] tx_byte;
    reg [7:0] rx_byte;
    reg       rx_second_byte;
    reg       master_send_nack;

    reg latched_write8;
    reg       latched_read2;
    reg [6:0] latched_addr7;
    reg [7:0] latched_reg;
    reg [15:0] latched_wdata;
    reg tx_second_byte;
    reg       transaction_error;
    reg [3:0] transaction_error_code;
    reg [31:0] line_wait_count;
    reg [3:0] recovery_pulse_count;
    reg       recovering_bus;

    wire waiting_bus_free = (state == ST_BUS_FREE);
    wire waiting_scl_high =
        ((state == ST_START)      && (phase == 3'd1)) ||
        ((state == ST_TX)         && (phase == 2'd2)) ||
        ((state == ST_TX_ACK)     && (phase == 2'd2)) ||
        ((state == ST_RESTART)    && (phase == 2'd2)) ||
        ((state == ST_RX)         && (phase == 2'd2)) ||
        ((state == ST_MASTER_ACK) && (phase == 2'd2)) ||
        ((state == ST_STOP)       && (phase == 2'd2)) ||
        ((state == ST_BUS_CLEAR)  && (phase == 2'd2));
    wire waiting_for_line = waiting_bus_free || waiting_scl_high;
    wire requested_line_high = waiting_bus_free ? (scl_sync && sda_sync)
                                                : scl_sync;
    wire line_timeout = waiting_for_line && !requested_line_high &&
        (line_wait_count >= (LINE_TIMEOUT_CYCLES - 1));

    assign req_ready = (state == ST_IDLE) && !rsp_valid;
    assign busy = (state != ST_IDLE) && (state != ST_RESPONSE);

    function [39:0] capture_fault;
        input [3:0] code;
        input timed_out;
        begin
            // Little-endian bytes: code/flags, state/phase, digital lines,
            // address/write8, register. Bit 4 is filled by the owning arbiter.
            capture_fault = {latched_reg, latched_write8, latched_addr7,
                tx_stage, waiting_scl_high, waiting_bus_free,
                sda_drive_low, scl_drive_low, sda_sync, scl_sync,
                phase, state, timed_out, recovering_bus, latched_read2,
                1'b0, code};
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            scl_meta <= 1'b1;
            scl_sync <= 1'b1;
            sda_meta <= 1'b1;
            sda_sync <= 1'b1;
        end else begin
            scl_meta <= scl;
            scl_sync <= scl_meta;
            sda_meta <= sda;
            sda_sync <= sda_meta;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            divider_count <= 32'd0;
        end else if (qtr_tick) begin
            divider_count <= 32'd0;
        end else begin
            divider_count <= divider_count + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state                  <= ST_IDLE;
            phase                  <= 2'd0;
            bit_index              <= 3'd7;
            tx_stage               <= TX_ADDR_W;
            tx_byte                <= 8'd0;
            rx_byte                <= 8'd0;
            rx_second_byte         <= 1'b0;
            master_send_nack       <= 1'b0;
            latched_read2          <= 1'b0;
            latched_write8         <= 1'b0;
            latched_addr7          <= 7'd0;
            latched_reg            <= 8'd0;
            latched_wdata          <= 16'd0;
            tx_second_byte         <= 1'b0;
            transaction_error      <= 1'b0;
            transaction_error_code <= ERR_NONE;
            line_wait_count        <= 32'd0;
            recovery_pulse_count   <= 4'd0;
            recovering_bus         <= 1'b0;
            rsp_valid              <= 1'b0;
            rsp_rdata              <= 16'd0;
            rsp_error              <= 1'b0;
            rsp_error_code         <= ERR_NONE;
            fault_context          <= 40'd0;
            scl_drive_low          <= 1'b0;
            sda_drive_low          <= 1'b0;
        end else begin
            if (waiting_for_line && !requested_line_high) begin
                line_wait_count <= line_wait_count + 1'b1;
            end else begin
                line_wait_count <= 32'd0;
            end

            if (state == ST_IDLE) begin
                scl_drive_low <= 1'b0;
                sda_drive_low <= 1'b0;
                if (req_valid && req_ready) begin
                    latched_read2          <= req_read2;
                    latched_write8         <= req_write8;
                    latched_addr7          <= req_addr7;
                    latched_reg            <= req_reg;
                    latched_wdata          <= req_wdata;
                    tx_second_byte         <= 1'b0;
                    transaction_error      <= 1'b0;
                    transaction_error_code <= ERR_NONE;
                    fault_context          <= 40'd0;
                    recovery_pulse_count   <= 4'd0;
                    recovering_bus         <= 1'b0;
                    rsp_rdata              <= 16'd0;
                    tx_stage               <= TX_ADDR_W;
                    state                  <= ST_BUS_FREE;
                    phase                  <= 2'd0;
                end
            end else if (state == ST_RESPONSE) begin
                scl_drive_low <= 1'b0;
                sda_drive_low <= 1'b0;
                if (rsp_valid && rsp_ready) begin
                    rsp_valid <= 1'b0;
                    state <= ST_IDLE;
                end
            end else if (line_timeout) begin
                // A bounded failure releases both bus wires.
                scl_drive_low  <= 1'b0;
                sda_drive_low  <= 1'b0;
                rsp_valid      <= 1'b1;
                rsp_error      <= 1'b1;
                rsp_error_code <= waiting_bus_free ? ERR_BUS_BUSY
                                                   : ERR_SCL_TIMEOUT;
                fault_context <= capture_fault(waiting_bus_free ? ERR_BUS_BUSY
                                                   : ERR_SCL_TIMEOUT, 1'b1);
                recovering_bus <= 1'b0;
                state <= ST_RESPONSE;
            end else if (qtr_tick) begin
                case (state)
                    ST_BUS_FREE: begin
                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;
                        if (scl_sync && sda_sync) begin
                            state <= ST_START;
                            phase <= 2'd0;
                        end else if (scl_sync && !sda_sync) begin
                            // A target may have been left part-way through a
                            // byte by an FPGA reset. Clock it at most nine
                            // times, then emit an explicit STOP.
                            recovery_pulse_count <= 4'd0;
                            state <= ST_BUS_CLEAR;
                            phase <= 2'd0;
                        end
                    end

                    ST_START: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b0;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            3'd1: begin
                                if (scl_sync) phase <= 3'd2;
                            end
                            3'd2: begin
                                // SDA high-to-low while SCL is high.
                                sda_drive_low <= 1'b1;
                                phase <= 3'd3;
                            end
                            3'd3: phase <= 3'd4; // >=2 quarters START hold
                            default: begin
                                scl_drive_low <= 1'b1;
                                tx_byte <= {latched_addr7, 1'b0};
                                tx_stage <= TX_ADDR_W;
                                bit_index <= 3'd7;
                                state <= ST_TX;
                                phase <= 2'd0;
                            end
                        endcase
                    end

                    ST_TX: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= ~tx_byte[bit_index];
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                if (scl_sync)
                                    phase <= 2'd3;
                            end
                            3'd3: phase <= 3'd4;
                            default: begin
                                scl_drive_low <= 1'b1;
                                if (bit_index == 3'd0) begin
                                    // Hold the final data bit until ACK phase 0.
                                    // Releasing SDA on this same edge can appear
                                    // as STOP if target SCL fall lags SDA rise.
                                    state <= ST_TX_ACK;
                                    phase <= 2'd0;
                                end else begin
                                    bit_index <= bit_index - 1'b1;
                                    phase <= 2'd0;
                                end
                            end
                        endcase
                    end

                    ST_TX_ACK: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                if (scl_sync) begin
                                    if (sda_sync) begin
                                        transaction_error <= 1'b1;
                                        case (tx_stage)
                                            TX_ADDR_W: begin
                                                transaction_error_code <= ERR_NACK_ADDR_W;
                                                fault_context <= capture_fault(ERR_NACK_ADDR_W, 1'b0);
                                            end
                                            TX_REG: begin
                                                transaction_error_code <= ERR_NACK_REG;
                                                fault_context <= capture_fault(ERR_NACK_REG, 1'b0);
                                            end
                                            TX_DATA: begin
                                                transaction_error_code <= ERR_NACK_DATA;
                                                fault_context <= capture_fault(ERR_NACK_DATA, 1'b0);
                                            end
                                            default: begin
                                                transaction_error_code <= ERR_NACK_ADDR_R;
                                                fault_context <= capture_fault(ERR_NACK_ADDR_R, 1'b0);
                                            end
                                        endcase
                                    end
                                    phase <= 2'd3;
                                end
                            end
                            3'd3: phase <= 3'd4;
                            default: begin
                                scl_drive_low <= 1'b1;
                                if (transaction_error || sda_sync) begin
                                    // SDA is pulled low first in ST_STOP, so a
                                    // legal STOP is also generated after NACK.
                                    state <= ST_STOP;
                                    phase <= 2'd0;
                                end else begin
                                    case (tx_stage)
                                        TX_ADDR_W: begin
                                            tx_byte <= latched_reg;
                                            tx_stage <= TX_REG;
                                            bit_index <= 3'd7;
                                            state <= ST_TX;
                                            phase <= 2'd0;
                                        end
                                        TX_REG: begin
                                            if (latched_read2) begin
                                                state <= ST_RESTART;
                                                phase <= 2'd0;
                                            end else begin
                                                tx_byte <= latched_wdata[15:8];
                                                tx_stage <= TX_DATA;
                                                bit_index <= 3'd7;
                                                state <= ST_TX;
                                                phase <= 2'd0;
                                            end
                                        end
                                        TX_DATA: begin
                                            phase <= 2'd0;
                                            if (!tx_second_byte && !latched_write8) begin
                                                tx_second_byte <= 1'b1;
                                                tx_byte <= latched_wdata[7:0];
                                                bit_index <= 3'd7;
                                                state <= ST_TX;
                                            end else begin
                                                state <= ST_STOP;
                                            end
                                        end
                                        default: begin
                                            rx_byte <= 8'd0;
                                            rx_second_byte <= 1'b0;
                                            bit_index <= 3'd7;
                                            state <= ST_RX;
                                            phase <= 2'd0;
                                        end
                                    endcase
                                end
                            end
                        endcase
                    end

                    ST_RESTART: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                if (scl_sync) begin
                                    phase <= 3'd3;
                                end
                            end
                            3'd3: phase <= 3'd4;
                            3'd4: begin
                                sda_drive_low <= 1'b1;
                                phase <= 3'd5;
                            end
                            3'd5: phase <= 3'd6; // >=2 quarters START hold
                            default: begin
                                scl_drive_low <= 1'b1;
                                tx_byte <= {latched_addr7, 1'b1};
                                tx_stage <= TX_ADDR_R;
                                bit_index <= 3'd7;
                                state <= ST_TX;
                                phase <= 2'd0;
                            end
                        endcase
                    end

                    ST_RX: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                if (scl_sync) begin
                                    rx_byte[bit_index] <= sda_sync;
                                    phase <= 2'd3;
                                end
                            end
                            3'd3: phase <= 3'd4;
                            default: begin
                                scl_drive_low <= 1'b1;
                                if (bit_index == 3'd0) begin
                                    if (rx_second_byte)
                                        rsp_rdata[7:0] <= rx_byte;
                                    else
                                        rsp_rdata[15:8] <= rx_byte;
                                    master_send_nack <= rx_second_byte;
                                    state <= ST_MASTER_ACK;
                                    phase <= 2'd0;
                                end else begin
                                    bit_index <= bit_index - 1'b1;
                                    phase <= 2'd0;
                                end
                            end
                        endcase
                    end

                    ST_MASTER_ACK: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                // ACK first byte (drive low), NACK last byte (Z).
                                sda_drive_low <= ~master_send_nack;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                if (scl_sync)
                                    phase <= 2'd3;
                            end
                            3'd3: phase <= 3'd4;
                            default: begin
                                scl_drive_low <= 1'b1;
                                // Keep ACK stable across the SCL falling edge;
                                // RX/STOP phase 0 changes SDA one quarter later.
                                if (master_send_nack) begin
                                    state <= ST_STOP;
                                    phase <= 2'd0;
                                end else begin
                                    rx_byte <= 8'd0;
                                    rx_second_byte <= 1'b1;
                                    bit_index <= 3'd7;
                                    state <= ST_RX;
                                    phase <= 2'd0;
                                end
                            end
                        endcase
                    end

                    ST_BUS_CLEAR: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b0;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                if (scl_sync)
                                    phase <= 2'd3;
                            end
                            3'd3: phase <= 3'd4;
                            default: begin
                                scl_drive_low <= 1'b1;
                                if (sda_sync ||
                                    (recovery_pulse_count == 4'd8)) begin
                                    recovering_bus <= 1'b1;
                                    state <= ST_STOP;
                                    phase <= 2'd0;
                                end else begin
                                    recovery_pulse_count <=
                                        recovery_pulse_count + 1'b1;
                                    phase <= 2'd0;
                                end
                            end
                        endcase
                    end

                    ST_STOP: begin
                        case (phase)
                            2'd0: begin
                                scl_drive_low <= 1'b1;
                                sda_drive_low <= 1'b1;
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_drive_low <= 1'b0;
                                phase <= 2'd2;
                            end
                            2'd2: begin
                                if (scl_sync) begin
                                    phase <= 3'd3;
                                end
                            end
                            3'd3: phase <= 3'd4;
                            3'd4: begin
                                // >=2 quarters setup, then SDA rises with SCL high.
                                sda_drive_low <= 1'b0;
                                phase <= 3'd5;
                            end
                            default: begin
                                scl_drive_low  <= 1'b0;
                                sda_drive_low  <= 1'b0;
                                if (recovering_bus) begin
                                    recovering_bus <= 1'b0;
                                    if (sda_sync) begin
                                        // The original request is still pending;
                                        // retry it after bus-free time.
                                        state <= ST_BUS_FREE;
                                        phase <= 2'd0;
                                    end else begin
                                        rsp_valid <= 1'b1;
                                        rsp_error <= 1'b1;
                                        rsp_error_code <= ERR_BUS_BUSY;
                                        fault_context <= capture_fault(ERR_BUS_BUSY, 1'b0);
                                        state <= ST_RESPONSE;
                                    end
                                end else begin
                                    rsp_valid      <= 1'b1;
                                    rsp_error      <= transaction_error;
                                    rsp_error_code <= transaction_error_code;
                                    state <= ST_RESPONSE;
                                end
                            end
                        endcase
                    end

                    default: begin
                        scl_drive_low  <= 1'b0;
                        sda_drive_low  <= 1'b0;
                        rsp_valid      <= 1'b1;
                        rsp_error      <= 1'b1;
                        rsp_error_code <= ERR_SCL_TIMEOUT;
                        fault_context <= capture_fault(ERR_SCL_TIMEOUT, 1'b0);
                        state <= ST_RESPONSE;
                    end
                endcase
            end
        end
    end

endmodule
