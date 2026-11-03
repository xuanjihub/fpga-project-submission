`timescale 1ns/1ps
// RX is already synchronized by the board's retained two-flop input adapter.
// Fixed 8N1.
module ble_uart_rx_v1 #(parameter integer CLK_HZ=50000000, BAUD=115200)(
    input wire clk, reset, rx,
    output reg valid, error, output reg [7:0] data
);
    localparam integer BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=$clog2(BIT_CYCLES+1);
    reg [CW-1:0] count;
    reg [1:0] state;
    reg [2:0] bit_index;
    reg [7:0] shift;
    reg seen_high;
    always @(posedge clk) begin
        if(reset) begin
            valid<=0; error<=0; data<=0; count<=0; state<=0;
            bit_index<=0; shift<=0; seen_high<=0;
        end else begin
            valid<=0; error<=0;
            case(state)
                0: if(rx) seen_high<=1;
                   else if(seen_high) begin
                       state<=1; count<=(BIT_CYCLES/2)-1; seen_high<=0;
                   end
                1: if(count!=0) count<=count-1'b1;
                   else if(rx) state<=0;
                   else begin state<=2; count<=BIT_CYCLES-1; bit_index<=0; end
                2: if(count!=0) count<=count-1'b1;
                   else begin
                       shift[bit_index]<=rx; count<=BIT_CYCLES-1;
                       if(bit_index==7) state<=3;
                       else bit_index<=bit_index+1'b1;
                   end
                3: if(count!=0) count<=count-1'b1;
                   else begin
                       state<=0; seen_high<=rx;
                       if(rx) begin data<=shift; valid<=1; end
                       else error<=1;
                   end
            endcase
        end
    end
endmodule

module ble_uart_tx_v1 #(parameter integer CLK_HZ=50000000, BAUD=115200)(
    input wire clk, reset, valid, input wire [159:0] frame,
    output wire ready, output reg tx
);
    localparam integer BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=$clog2(BIT_CYCLES+1);
    reg [CW-1:0] count;
    reg busy;
    // The endpoint owns frame and keeps it unchanged until ready returns.
    // Capture/serialize one byte at a time; the endpoint keeps the
    // complete 160-bit response register.
    reg [7:0] saved_byte;
    reg [4:0] byte_index;
    reg [3:0] bit_index;
    wire [4:0] next_byte_index=byte_index+5'd1;
    assign ready=!reset&&!busy;
    always @(posedge clk) begin
        if(reset) begin
            busy<=0; saved_byte<=0; count<=0; byte_index<=0; bit_index<=0; tx<=1;
        end else if(!busy) begin
            tx<=1;
            if(valid) begin
                saved_byte<=frame[7:0]; busy<=1; count<=BIT_CYCLES-1;
                byte_index<=0; bit_index<=0; tx<=0;
            end
        end else if(count!=0) count<=count-1'b1;
        else begin
            count<=BIT_CYCLES-1;
            if(bit_index<8) begin
                tx<=saved_byte[0]; saved_byte<={1'b0,saved_byte[7:1]};
                bit_index<=bit_index+1'b1;
            end else if(bit_index==8) begin tx<=1; bit_index<=9; end
            else if(byte_index==19) begin busy<=0; tx<=1; end
            else begin
                byte_index<=next_byte_index; bit_index<=0; tx<=0;
                saved_byte<=frame[next_byte_index*8+:8];
            end
        end
    end
endmodule
