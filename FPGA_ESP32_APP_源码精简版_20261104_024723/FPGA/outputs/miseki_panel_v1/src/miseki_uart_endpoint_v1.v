`timescale 1ns/1ps
// Derived exactly from frozen ble_uart_endpoint_v1. Only the module name and
// CRC/index initialization ownership differ; framing, arbitration and cycles
// remain unchanged. Local state prepares CRC before each compute phase.
module miseki_uart_endpoint_v1 #(
    parameter integer CLK_HZ=50000000, BAUD=115200,
    parameter integer GAP_CYCLES=CLK_HZ*3/100,
    parameter integer OWNER_TIMEOUT_CYCLES=CLK_HZ/4,
    parameter integer MIDI_SHARED=0,
    parameter [31:0] BUILD_ID=32'h50314B03
)(
    input wire clk, power_reset, owner_reset, rx,
    output wire tx,
    input wire configured, fault,
    input wire [15:0] revision,
    input wire [4:0] master,
    input wire [1:0] timbre,
    input wire [19:0] adsr_indices,
    input wire [15:0] adsr_revision,
    output wire remote_valid,
    output wire [4:0] remote_master,
    input wire remote_ready, remote_done,
    input wire [7:0] remote_status,
    input wire [15:0] remote_revision,
    input wire [4:0] remote_value,
    output wire remote_timbre_valid,
    output wire [1:0] remote_timbre,
    input wire remote_timbre_ready, remote_timbre_done,
    input wire [7:0] remote_timbre_status,
    input wire [15:0] remote_timbre_revision,
    input wire [1:0] remote_timbre_value,
    output wire remote_adsr_valid,
    output wire [1:0] remote_adsr_field,
    output wire [4:0] remote_adsr_index,
    input wire remote_adsr_ready, remote_adsr_done,
    input wire [7:0] remote_adsr_status,
    input wire [15:0] remote_adsr_revision,
    input wire [4:0] remote_adsr_value
);
    localparam [3:0] RECEIVE=0, CHECK=1, DISPATCH=2, ACCEPT=3,
        WAIT_OWNER=4, RESPONSE_CRC=5, SEND=6, DRAIN=7;
    localparam integer GCW=$clog2(GAP_CYCLES+1);
    localparam integer TCW=$clog2(OWNER_TIMEOUT_CYCLES+1);
    reg [3:0] state;
    reg [159:0] request, response;
    reg [4:0] count, crc_index;
    reg [15:0] crc;
    reg [GCW-1:0] gap_count;
    reg [TCW-1:0] owner_count;
    reg cache_valid, install_cache;
    reg [159:0] cache_request, cache_response;
    wire byte_valid, byte_error, tx_ready;
    wire [7:0] byte_data;
    wire [7:0] opcode=request[16+:8];
    wire [15:0] request_id=request[32+:16];
    wire [7:0] length=request[48+:8];
    wire [31:0] nonce=length>=4 ? request[56+:32] : 32'd0;
    wire [15:0] expected_revision=request[88+:16];
    wire [7:0] requested_master=request[104+:8];
    wire [7:0] requested_timbre=request[104+:8];
    wire adsr_command=opcode>=8'h14&&opcode<=8'h1b;
    wire timbre_command=opcode==8'h12||opcode==8'h13;
    wire [7:0] requested_index=request[104+:8];
    wire [7:0] adsr_offset=opcode-8'h14;
    assign remote_adsr_field=adsr_offset[2:1];
    assign remote_adsr_index=requested_index[4:0];
    wire [4:0] adsr_value=adsr_indices[remote_adsr_field*5+:5];
    wire [7:0] public_value=adsr_command ? {3'd0,adsr_value} :
        timbre_command ? {6'd0,timbre} : {3'd0,master};
    // The panel consumes the owner publication ACK one clk later. Its index
    // snapshot must carry that same accepted revision so the revision and ADSR
    // index stay paired through the ACK propagation edge.
    wire [15:0] public_revision=adsr_command ? adsr_revision : revision;
    wire selected_ready=adsr_command ? remote_adsr_ready :
        timbre_command ? remote_timbre_ready : remote_ready;
    wire selected_done=adsr_command ? remote_adsr_done :
        timbre_command ? remote_timbre_done : remote_done;
    wire [7:0] selected_status=adsr_command ? remote_adsr_status :
        timbre_command ? remote_timbre_status : remote_status;
    wire [15:0] selected_revision=adsr_command ? remote_adsr_revision :
        timbre_command ? remote_timbre_revision : remote_revision;
    wire [7:0] selected_value=adsr_command ? {3'd0,remote_adsr_value} :
        timbre_command ? {6'd0,remote_timbre_value} : {3'd0,remote_value};
    wire adsr_range_ok=requested_index<=(remote_adsr_field==2 ? 8'd16 : 8'd7);
    assign remote_master=requested_master[4:0];
    assign remote_timbre=requested_timbre[1:0];
    // Valid is a proposal; only valid && ready accepts it. Avoid returning
    // the owner's safety/ready chain through this endpoint and back again.
    assign remote_valid=state==ACCEPT&&opcode==8'h11&&!owner_reset&&configured&&!fault&&
        expected_revision==revision&&requested_master<=8'd16;
    assign remote_timbre_valid=state==ACCEPT&&opcode==8'h13&&!owner_reset&&configured&&!fault&&
        expected_revision==revision&&requested_timbre<=8'd3;
    assign remote_adsr_valid=state==ACCEPT&&adsr_command&&opcode[0]&&!owner_reset&&configured&&!fault&&
        expected_revision==revision&&adsr_range_ok;
    ble_uart_rx_v1 #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) receiver(
        .clk(clk),.reset(power_reset),.rx(rx),.valid(byte_valid),.error(byte_error),.data(byte_data));
    ble_uart_tx_v1 #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) transmitter(
        .clk(clk),.reset(power_reset),.valid(state==SEND),.frame(response),.ready(tx_ready),.tx(tx));

    function [15:0] crc_byte;
        input [15:0] previous;
        input [7:0] value;
        reg [15:0] next;
        integer bitno;
        begin
            next=previous^{value,8'b0};
            for(bitno=0;bitno<8;bitno=bitno+1)
                next=next[15] ? (next<<1)^16'h1021 : next<<1;
            crc_byte=next;
        end
    endfunction
    reg padding_ok;
    integer p;
    always @* begin
        padding_ok=1;
        for(p=0;p<11;p=p+1)
            if(p>=length&&request[(p+7)*8+:8]!=0) padding_ok=0;
    end
    task respond;
        input [7:0] result_opcode, status;
        input [15:0] public_revision;
        input [7:0] value;
        input remember;
        begin
            response<= {16'd0,value,public_revision,BUILD_ID,
                        nonce,8'd11,request_id,status,result_opcode,8'd1,8'hB2};
            install_cache<=remember;
            state<=RESPONSE_CRC;
        end
    endtask
    always @(posedge clk) begin
        if(power_reset) begin
            state<=RECEIVE; request<=0; response<=0; count<=0; crc_index<=0;
            crc<=16'hFFFF; gap_count<=0; owner_count<=0;
            cache_valid<=0; install_cache<=0; cache_request<=0; cache_response<=0;
        end else begin
            // All entry states initialize before CHECK/RESPONSE_CRC starts.
            // Keep the long remote-ready/response selection out of CRC D/CE.
            if(state!=CHECK && state!=RESPONSE_CRC) begin
                crc<=16'hFFFF; crc_index<=0;
            end
            case(state)
                RECEIVE: begin
                    if(byte_error) begin count<=0; gap_count<=0; request<=0; end
                    else if(byte_valid) begin
                        // Each complete frame ends in little-endian byte
                        // order without a variable write-enable decoder.
                        request<={byte_data,request[159:8]}; gap_count<=0;
                        if(count==19) begin
                            state<=CHECK;
                        end else count<=count+1'b1;
                    end else if(count!=0) begin
                        if(gap_count>=GAP_CYCLES-1) begin
                            count<=0; gap_count<=0; request<=0;
                        end else gap_count<=gap_count+1'b1;
                    end
                end
                CHECK: begin
                    if(crc_index<18) begin
                        crc<=crc_byte(crc,request[crc_index*8+:8]);
                        crc_index<=crc_index+1'b1;
                    end else if(request[7:0]==8'hB2&&
                        ((MIDI_SHARED && request[15:8]==8'd2 && length<=8) ||
                         ((!MIDI_SHARED || request[15:8]!=8'd2) &&
                          length<=11 && request[24+:8]==0))&&
                        padding_ok&&crc==request[144+:16])
                        state<=DISPATCH;
                    else begin
                        // Slide one byte so a false magic inside garbage is
                        // rejected, and recheck the next complete 20-byte window.
                        // The next receive shifts out the oldest byte and
                        // appends the new one, forming the next full window.
                        count<=19; gap_count<=0;
                        state<=RECEIVE;
                    end
                end
                DISPATCH: begin
                    if(MIDI_SHARED && request[8+:8]==8'd2) begin
                        // The MIDI endpoint owns protocol v2 frames; ignoring
                        // them here prevents duplicate/error replies on TX.
                        state<=RECEIVE;count<=0;gap_count<=0;request<=0;
                    end else if(cache_valid&&request_id==cache_request[32+:16]) begin
                        if(request==cache_request) begin response<=cache_response; state<=SEND; end
                        else respond(8'hFF,8'h04,revision,master,0);
                    end else if(request[8+:8]!=1) respond(8'hFF,8'h02,revision,master,1);
                    else if(opcode<8'h10||opcode>8'h1b)
                        respond(8'hFF,8'h01,revision,master,1);
                    else if((!opcode[0]&&length!=4)||
                            (opcode[0]&&length!=7)||
                            (opcode==8'h11&&requested_master>16)||
                            (opcode==8'h13&&requested_timbre>3)||
                            (adsr_command&&opcode[0]&&!adsr_range_ok))
                        respond(8'hFF,8'h03,revision,master,1);
                    else if(fault) respond(opcode|8'h80,8'h14,public_revision,public_value,1);
                    else if(owner_reset||!configured) respond(opcode|8'h80,8'h11,public_revision,public_value,1);
                    else if(!opcode[0]) respond(opcode|8'h80,8'h00,public_revision,public_value,1);
                    else state<=ACCEPT;
                end
                ACCEPT: begin
                    if(fault) respond(opcode|8'h80,8'h14,public_revision,public_value,1);
                    else if(expected_revision!=revision) respond(opcode|8'h80,8'h12,public_revision,public_value,1);
                    else if(owner_reset||!configured||!selected_ready)
                        respond(opcode|8'h80,8'h11,public_revision,public_value,1);
                    else begin state<=WAIT_OWNER; owner_count<=0; end
                end
                WAIT_OWNER: begin
                    if(selected_done) respond(opcode|8'h80,selected_status,selected_revision,selected_value,1);
                    // Reset may hide a just-published ACK; the reply reports 15h.
                    else if(owner_reset) respond(opcode|8'h80,8'h15,public_revision,public_value,1);
                    else if(owner_count>=OWNER_TIMEOUT_CYCLES-1)
                        respond(opcode|8'h80,8'h15,public_revision,public_value,1);
                    else owner_count<=owner_count+1'b1;
                end
                RESPONSE_CRC: begin
                    if(crc_index<18) begin
                        crc<=crc_byte(crc,response[crc_index*8+:8]);
                        crc_index<=crc_index+1'b1;
                    end else begin
                        response[144+:16]<=crc;
                        if(install_cache) begin
                            cache_valid<=1; cache_request<=request;
                            cache_response<={crc,response[143:0]};
                        end
                        state<=SEND;
                    end
                end
                SEND: if(tx_ready) state<=DRAIN;
                DRAIN: if(tx_ready) begin state<=RECEIVE; count<=0; gap_count<=0; request<=0; end
                default: begin state<=RECEIVE; count<=0; end
            endcase
        end
    end
endmodule
