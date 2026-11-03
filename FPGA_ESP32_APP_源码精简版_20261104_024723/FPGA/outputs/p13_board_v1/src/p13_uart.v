`timescale 1ns/1ps
// Fixed 64-byte frame, 115200 8N1 at nominal 52.5 MHz, TX only.
module p13_uart #(
    parameter integer CLK_HZ=52500000,
    parameter integer BAUD=115200,
    parameter integer REPORT_CYCLES=CLK_HZ/10
)(
    input wire clk, reset,
    input wire [495:0] payload, // bytes 0..61, byte zero in least significant bits
    output wire frame_ce,output reg tx=1'b1
);
    localparam integer BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD;
    reg [511:0] frame;
    reg [31:0] report_count, bit_count;
    reg [5:0] byte_index;
    reg [3:0] bit_index;
    reg sending;
    reg [7:0] check;
    integer k;
    assign frame_ce=!reset&&!sending&&report_count>=REPORT_CYCLES-1;
    always @* begin
        check=0;
        for(k=0;k<62;k=k+1) check=check ^ payload[k*8 +: 8];
    end
    always @(posedge clk) begin
        if(reset) begin
            tx<=1; sending<=0; report_count<=0; bit_count<=0;
            byte_index<=0; bit_index<=0; frame<=0;
        end else if(!sending) begin
            tx<=1;
            if(report_count >= REPORT_CYCLES-1) begin
                frame <= {8'h0A,check,payload};
                report_count<=0; sending<=1;
                byte_index<=0; bit_index<=0; bit_count<=0; tx<=0;
            end else report_count<=report_count+1'b1;
        end else if(bit_count == BIT_CYCLES-1) begin
            bit_count<=0;
            if(bit_index<8) begin
                tx<=frame[byte_index*8+bit_index];
                bit_index<=bit_index+1'b1;
            end else if(bit_index==8) begin
                tx<=1; bit_index<=9;
            end else if(byte_index==63) begin
                tx<=1; sending<=0;
            end else begin
                byte_index<=byte_index+1'b1; bit_index<=0; tx<=0;
            end
        end else bit_count<=bit_count+1'b1;
    end
endmodule
