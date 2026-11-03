`timescale 1ns/1ps
// N08 event-driven derivative. Initial/recovery frame is unconditional;
// thereafter frame_request is a level held until frame_start acknowledges it.
// Coalescing and snapshots belong to the OLED owner, which redraws only on change.
// SSD1309 Rev.1.1 I2C transport for a 128x64 panel.
// SA0 selects 7-bit 3Ch/3Dh. A write is [address+W, control, payload],
// where control 00h is command and 40h is GDDRAM data. Page mode is 20h,02h;
// each page is positioned with B0-B7, low-column 00h, high-column 10h.
// SSD1309 has no documented SSD1306 8Dh charge-pump command.
// Dedicated OLED bus. The inherited master drives only low or Z; pull-ups are
// external. Audio runs independently of this slow display transaction engine.
// frame_start freezes a coherent renderer snapshot. pixel_req carries page /
// column; the renderer returns pixel_valid/data before the byte is transmitted.
module miseki_ssd1309_v1 #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer I2C_HZ = 100_000,
    parameter integer STARTUP_CYCLES = CLK_HZ / 20,
    parameter integer RETRY_CYCLES = CLK_HZ / 10,
    parameter integer FRAME_GAP_CYCLES = CLK_HZ / 20,
    parameter integer LINE_TIMEOUT_CYCLES = CLK_HZ / 100,
    parameter integer PIXEL_TIMEOUT_CYCLES = 1024,
    parameter integer MAX_RETRIES = 3
) (
    input wire clk, reset,
    input wire frame_request,
    output reg frame_start,
    output reg pixel_req,
    output reg [2:0] page,
    output reg [6:0] column,
    input wire pixel_valid,
    input wire [7:0] pixel_data,
    inout wire scl, sda,
    output reg online,
    output reg fault,
    output reg [6:0] address,
    output reg [7:0] errors,
    output reg [3:0] last_error,
    output reg [15:0] frames
);
    localparam [3:0] ST_WAIT=0, ST_PROBE=1, ST_INIT=2, ST_PAGE=3,
        ST_PIXEL_REQ=4, ST_PIXEL_WAIT=5, ST_DATA=6, ST_ENABLE=7,
        ST_GAP=8, ST_RETRY=9, ST_FAULT=10;
    localparam integer RETRY_WIDTH = MAX_RETRIES < 2 ? 1 : $clog2(MAX_RETRIES + 1);
    reg [3:0] state;
    reg [31:0] timer;
    reg [RETRY_WIDTH-1:0] retry_count;
    reg [4:0] init_index;
    reg [1:0] page_command;
    reg pending;
    reg [7:0] pixel_latched;

    function [7:0] init_byte;
        input [4:0] index;
        begin
            // SSD1309 documented command/parameter pairs; AE is sent as probe.
            case(index)
                0:init_byte=8'hD5;  1:init_byte=8'h80;
                2:init_byte=8'hA8;  3:init_byte=8'h3F;
                4:init_byte=8'hD3;  5:init_byte=8'h00;
                6:init_byte=8'h40;  7:init_byte=8'hA1;
                8:init_byte=8'hC8;  9:init_byte=8'hDA;
                10:init_byte=8'h12; 11:init_byte=8'h81;
                12:init_byte=8'h7F; 13:init_byte=8'hD9;
                14:init_byte=8'hF1; 15:init_byte=8'hDB;
                // Rev.1.1 Table 9-5 / section 10.19: DB has A[7:6]=00,
                // A[1:0]=00 and reset A[5:2]=1101 (34h).
                16:init_byte=8'h34; 17:init_byte=8'hA4;
                18:init_byte=8'hA6; 19:init_byte=8'h20;
                20:init_byte=8'h02;
                default:init_byte=8'hAE;
            endcase
        end
    endfunction

    reg [7:0] tx_data;
    always @* begin
        case(state)
            ST_INIT: tx_data=init_byte(init_index);
            ST_PAGE: case(page_command)
                0:tx_data=8'hB0|{5'b0,page};
                1:tx_data=8'h00;
                default:tx_data=8'h10;
            endcase
            ST_DATA:tx_data=pixel_latched;
            ST_ENABLE:tx_data=8'hAF;
            default:tx_data=8'hAE;
        endcase
    end
    wire sending=(state==ST_PROBE)||(state==ST_INIT)||(state==ST_PAGE)||
                 (state==ST_DATA)||(state==ST_ENABLE);
    wire req_ready,rsp_valid,rsp_error;
    wire [3:0] rsp_code;
    i2c_reg_master #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ),
        .LINE_TIMEOUT_CYCLES(LINE_TIMEOUT_CYCLES)) bus(
        .clk(clk),.reset(reset),.req_valid(sending&&!pending),.req_ready(req_ready),
        .req_read2(1'b0),.req_addr7(address),
        .req_reg(state==ST_DATA?8'h40:8'h00),.req_wdata(tx_data),
        .rsp_valid(rsp_valid),.rsp_ready(1'b1),.rsp_rdata(),
        .rsp_error(rsp_error),.rsp_error_code(rsp_code),.busy(),.scl(scl),.sda(sda));

    task fail_attempt;
        input [3:0] code;
        begin
            online<=0;last_error<=code;
            if(errors!=8'hFF)errors<=errors+1'b1;
            if(retry_count>=MAX_RETRIES-1)begin
                retry_count<=MAX_RETRIES;fault<=1;state<=ST_FAULT;
            end else begin
                retry_count<=retry_count+1'b1;timer<=RETRY_CYCLES-1;state<=ST_RETRY;
            end
        end
    endtask

    always @(posedge clk) begin
        frame_start<=0;pixel_req<=0;
        if(reset)begin
            state<=ST_WAIT;timer<=STARTUP_CYCLES-1;retry_count<=0;
            init_index<=0;page<=0;column<=0;page_command<=0;pending<=0;
            pixel_latched<=0;online<=0;fault<=0;address<=7'h3C;
            errors<=0;last_error<=0;frames<=0;
        end else begin
            if(sending&&!pending&&req_ready)pending<=1;
            case(state)
                ST_WAIT,ST_RETRY: if(timer!=0)timer<=timer-1'b1;
                    else begin state<=ST_PROBE;init_index<=0;page<=0;column<=0;page_command<=0;end
                ST_GAP: if(timer!=0)timer<=timer-1'b1;
                    else if(frame_request) begin state<=ST_PAGE;page<=0;column<=0;page_command<=0;frame_start<=1;end
                ST_PIXEL_REQ: begin pixel_req<=1;timer<=PIXEL_TIMEOUT_CYCLES-1;state<=ST_PIXEL_WAIT;end
                ST_PIXEL_WAIT: if(pixel_valid)begin pixel_latched<=pixel_data;state<=ST_DATA;end
                    else if(timer!=0)timer<=timer-1'b1;
                    else fail_attempt(4'd8);
                default: begin end
            endcase

            if(rsp_valid&&pending)begin
                pending<=0;
                if(rsp_error)begin
                    // Only the first 3Ch address+W NACK is interpreted as SA0=1.
                    if(state==ST_PROBE&&address==7'h3C&&rsp_code==4'd2)begin
                        address<=7'h3D;last_error<=rsp_code;
                        if(errors!=8'hFF)errors<=errors+1'b1;
                    end else fail_attempt(rsp_code);
                end else case(state)
                    ST_PROBE:begin state<=ST_INIT;init_index<=0;end
                    ST_INIT:if(init_index==20)begin
                        state<=ST_PAGE;page<=0;column<=0;page_command<=0;frame_start<=1;
                    end else init_index<=init_index+1'b1;
                    ST_PAGE:if(page_command==2)begin state<=ST_PIXEL_REQ;column<=0;end
                        else page_command<=page_command+1'b1;
                    ST_DATA:if(column==127)begin
                        column<=0;
                        if(page==7)begin
                            if(!online)state<=ST_ENABLE;
                            else begin
                                state<=ST_GAP;timer<=FRAME_GAP_CYCLES-1;
                                if(frames!=16'hFFFF)frames<=frames+1'b1;
                                retry_count<=0;last_error<=0;
                            end
                        end else begin page<=page+1'b1;page_command<=0;state<=ST_PAGE;end
                    end else begin column<=column+1'b1;state<=ST_PIXEL_REQ;end
                    ST_ENABLE:begin
                        online<=1;last_error<=0;retry_count<=0;state<=ST_GAP;
                        timer<=FRAME_GAP_CYCLES-1;
                        if(frames!=16'hFFFF)frames<=frames+1'b1;
                    end
                    default:begin state<=ST_FAULT;fault<=1;online<=0;end
                endcase
            end
        end
    end
`ifndef SYNTHESIS
    initial if(STARTUP_CYCLES<1||RETRY_CYCLES<1||FRAME_GAP_CYCLES<1||
        PIXEL_TIMEOUT_CYCLES<1||MAX_RETRIES<1)$fatal(1,"invalid SSD1309 parameters");
`endif
endmodule
