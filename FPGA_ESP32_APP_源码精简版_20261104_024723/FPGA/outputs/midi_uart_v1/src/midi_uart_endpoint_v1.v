`timescale 1ns/1ps
// MIDI-v2 UART input. SHARED_AUDIO adds scoped voice cleanup for the panel
// allocator; its default preserves the standalone D04 test profile.
module midi_uart_endpoint_v1 #(
    parameter integer CLK_HZ=50000000,
    parameter integer BAUD=115200,
    parameter integer GAP_CYCLES=CLK_HZ*3/100,
    parameter integer WATCHDOG_CYCLES=CLK_HZ*5/2,
    // 0 preserves the isolated N11 image; 1 scopes stop, drain, and watchdog
    // cleanup to MIDI-owned IDs when sharing the panel's allocator.
    parameter integer SHARED_AUDIO=0,
    parameter [31:0] BUILD_ID=32'h50314D04
)(
    input wire clk, reset, rx,
    input wire source_cancel,
    output wire tx,
    output wire panic,
    output wire event_valid,
    input wire event_ready,
    output wire [1:0] event_op,
    output wire [15:0] event_id,
    output wire [6:0] event_note, event_velocity,
    input wire event_result_valid,
    input wire [2:0] event_result_code,
    input wire [15:0] event_result_id,
    input wire [31:0] allocated, active, voice_gate,
    input wire [511:0] slot_ids
);
    localparam [2:0] SESSION_NONE=3'd0, SESSION_ACTIVE=3'd1,
                     SESSION_QUIESCING=3'd2, SESSION_DRAINED=3'd3,
                     SESSION_FAULT=3'd4;
    localparam [3:0] RX=0, CHECK=1, DISPATCH=2, EVENT_SEND=3,
                     EVENT_WAIT=4, ALL_SCAN=5, ALL_SEND=6, ALL_WAIT=7,
                     RESPONSE_CRC=8, SEND=9, DRAIN=10;
    localparam integer GCW=$clog2(GAP_CYCLES+1);
    localparam integer WCW=$clog2(WATCHDOG_CYCLES+1);

    reg [3:0] midi_state;
    reg [159:0] request, response, cache_request, cache_response;
    reg [4:0] rx_count, crc_index;
    reg [15:0] crc;
    reg [GCW-1:0] gap_count;
    reg [WCW-1:0] watchdog_count;
    reg cache_valid, response_cacheable;
    reg [2:0] session_state;
    reg [31:0] session_token;
    reg [15:0] last_sequence;
    reg panic_reg;
    reg watchdog_cleanup;
    reg [2:0] event_count;
    reg [1:0] event_index;
    reg [15:0] event_ids [0:3];
    reg [6:0] event_notes [0:3];
    reg [6:0] event_velocities [0:3];
    reg [1:0] event_codes [0:3];
    reg [5:0] all_index;
    reg [15:0] all_event_id;
    integer i;

    wire byte_valid, byte_error, tx_ready;
    wire [7:0] byte_data;
    wire [7:0] opcode=request[16+:8];
    wire [7:0] length=request[48+:8];
    wire [15:0] sequence_id=request[32+:16];
    wire [31:0] request_token={request[24+:8],request[120+:24]};
    wire [63:0] payload=request[56+:64];
    reg [5:0] allocated_count;
    reg [31:0] owned_live;
    // State transitions need only an OR reduction.
    wire voices_empty=!(|owned_live);
    wire watchdog_due=(session_state==SESSION_ACTIVE || session_state==SESSION_FAULT) &&
                      watchdog_count>=WATCHDOG_CYCLES-1 &&
                      !(midi_state==SEND || midi_state==DRAIN);
    // Response info bytes are [midi_state:u8, remaining:u16le], followed by zeros.
    wire [2:0] drain_state=(session_state==SESSION_QUIESCING && voices_empty) ?
                           SESSION_DRAINED : session_state;
    wire [55:0] drain_info={32'd0,10'd0,allocated_count,5'd0,drain_state};
    wire padding_ok;
    reg pad_ok;
    reg events_ok;
    integer pad_index;
    integer count_index;
    // CHECK already spends 18 clocks accumulating CRC after the request is
    // immutable. Register the independent dispatch predicates there, so
    // response CE reads only those registered flags.
    reg dispatch_events_ok, dispatch_token_ok, dispatch_cache_hit;
    reg dispatch_frame_equal, dispatch_sequence_ok;
    reg dispatch_sequence_zero,dispatch_token_zero,dispatch_token_match;
    reg [7:0] dispatch_length;
    always @(posedge clk) begin
        dispatch_events_ok<=events_ok;
        dispatch_token_ok<=request_token!=0 && request_token==session_token &&
                           session_state!=SESSION_NONE;
        dispatch_cache_hit<=cache_valid && sequence_id==last_sequence;
        dispatch_frame_equal<=request==cache_request;
        dispatch_sequence_ok<=last_sequence!=16'hFFFF &&
                              sequence_id==last_sequence+1'b1;
        dispatch_length<=length;
        dispatch_sequence_zero<=sequence_id==0;
        dispatch_token_zero<=request_token==0;
        dispatch_token_match<=request_token==session_token;
    end

    assign event_valid=((midi_state==EVENT_SEND)||(midi_state==ALL_SEND)) &&
                        !(SHARED_AUDIO && watchdog_due);
    assign event_op=(midi_state==EVENT_SEND)?event_codes[event_index]:2'd1;
    assign event_id=(midi_state==EVENT_SEND)?event_ids[event_index]:all_event_id;
    assign event_note=(midi_state==EVENT_SEND)?event_notes[event_index]:7'd0;
    assign event_velocity=(midi_state==EVENT_SEND)?event_velocities[event_index]:7'd0;
    assign panic=panic_reg;

    always @* begin
        allocated_count=0;
        for(count_index=0;count_index<32;count_index=count_index+1) begin
            owned_live[count_index]=SHARED_AUDIO ?
                ((allocated[count_index]|active[count_index]) &&
                 slot_ids[count_index*16+13+:3]==3'b101) :
                (allocated[count_index]|active[count_index]);
            if(owned_live[count_index])
                allocated_count=allocated_count+1'b1;
        end
    end

    always @* begin
        pad_ok=1'b1;
        for(pad_index=0;pad_index<8;pad_index=pad_index+1)
            if(pad_index>=length && request[56+pad_index*8+:8]!=0)
                pad_ok=1'b0;
    end
    assign padding_ok=pad_ok;

    // Reject the entire batch before publishing any event. The host and ESP32
    // enforce the same packed-bit/velocity/duplicate-ID contract.
    always @* begin
        events_ok=1'b1;
        if(opcode==8'h20) begin
            if(length==4)
                events_ok=payload[63:27]==0 && payload[26:20]!=0;
            else
                events_ok=payload[63:54]==0 && payload[26:20]!=0 &&
                          payload[53:47]!=0 && payload[12:0]!=payload[39:27];
        end else if(opcode==8'h21) begin
            // The four wire formats have fixed bit boundaries. Avoid an
            // inferred multiplier/barrel shifter for a two-bit batch count.
            case(length)
                2: events_ok=payload[63:13]==0;
                4: events_ok=payload[63:26]==0 && payload[12:0]!=payload[25:13];
                5: events_ok=payload[63:39]==0 && payload[12:0]!=payload[25:13] &&
                             payload[12:0]!=payload[38:26] && payload[25:13]!=payload[38:26];
                7: events_ok=payload[63:52]==0 && payload[12:0]!=payload[25:13] &&
                             payload[12:0]!=payload[38:26] && payload[12:0]!=payload[51:39] &&
                             payload[25:13]!=payload[38:26] && payload[25:13]!=payload[51:39] &&
                             payload[38:26]!=payload[51:39];
                default: events_ok=payload==0;
            endcase
        end
    end

    ble_uart_rx_v1 #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) receiver(
        .clk(clk),.reset(reset),.rx(rx),.valid(byte_valid),
        .error(byte_error),.data(byte_data));
    ble_uart_tx_v1 #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) transmitter(
        .clk(clk),.reset(reset),.valid(midi_state==SEND),.frame(response),
        .ready(tx_ready),.tx(tx));

    function [15:0] crc_byte;
        input [15:0] previous;
        input [7:0] value;
        reg [15:0] current;
        integer bit_number;
        begin
            current=previous^{value,8'b0};
            for(bit_number=0;bit_number<8;bit_number=bit_number+1)
                current=current[15]?(current<<1)^16'h1021:current<<1;
            crc_byte=current;
        end
    endfunction

    task queue_response;
        input [7:0] response_opcode;
        input [7:0] response_status;
        input [15:0] response_id;
        input [31:0] response_token;
        input [3:0] info_length;
        input [55:0] info;
        input cache_this;
        reg [159:0] next_response;
        integer b;
        begin
            next_response=160'd0;
            next_response[0+:8]=8'hB2;
            next_response[8+:8]=8'd2;
            next_response[16+:8]=response_opcode;
            next_response[24+:8]=response_status;
            next_response[32+:16]=response_id;
            next_response[48+:8]=info_length+1'b1;
            next_response[56+:8]=response_token[31:24];
            for(b=0;b<7;b=b+1)
                next_response[64+b*8+:8]=info[b*8+:8];
            next_response[120+:24]=response_token[23:0];
            response<=next_response;
            response_cacheable<=cache_this;
            crc<=16'hFFFF;
            crc_index<=0;
            midi_state<=RESPONSE_CRC;
        end
    endtask

    task queue_error;
        input [7:0] error_status;
        input [31:0] response_token;
        input cache_this;
        begin
            queue_response(8'hFF,error_status,sequence_id,response_token,
                           4'd0,56'd0,cache_this);
        end
    endtask

    task queue_success;
        input [7:0] response_opcode;
        input [15:0] response_id;
        input [31:0] response_token;
        input [3:0] info_length;
        input [55:0] info;
        input cache_this;
        begin
            queue_response(response_opcode,8'd0,response_id,response_token,
                           info_length,info,cache_this);
        end
    endtask

    function [7:0] result_status;
        input [2:0] result_code;
        begin
            case(result_code)
                3'd1: result_status=8'h16;
                3'd2: result_status=8'h17;
                3'd3: result_status=8'h18;
                default: result_status=8'h19;
            endcase
        end
    endfunction

    task queue_profile;
        input [7:0] response_opcode;
        input [7:0] response_status;
        input [15:0] response_id;
        input [31:0] response_token;
        input [2:0] profile_state;
        input cache_this;
        reg [55:0] info;
        begin
            info=56'd0;
            info[0+:8]=profile_state;
            info[8+:32]=BUILD_ID;
            info[40+:8]=8'd32;
            info[48+:8]=8'h0F;
            queue_response(response_opcode,response_status,response_id,
                           response_token,4'd7,info,cache_this);
        end
    endtask

    task load_note_events;
        input [7:0] input_opcode;
        integer n;
        reg [63:0] bits;
        reg [26:0] on_event;
        reg [12:0] off_event;
        reg [7:0] number;
        begin
            bits=payload;
            if(input_opcode==8'h20) begin
                number=(length==4)?1:2;
                event_count<=number;
                for(n=0;n<2;n=n+1) begin
                    on_event=bits[n*27+:27];
                    event_ids[n]<=16'hA000+on_event[12:0];
                    event_notes[n]<=on_event[19:13];
                    event_velocities[n]<=on_event[26:20];
                    event_codes[n]<=2'd0;
                end
            end else begin
                case(length)
                    2:number=1;
                    4:number=2;
                    5:number=3;
                    default:number=4;
                endcase
                event_count<=number;
                for(n=0;n<4;n=n+1) begin
                    off_event=bits[n*13+:13];
                    event_ids[n]<=16'hA000+off_event;
                    event_notes[n]<=0;
                    event_velocities[n]<=0;
                    event_codes[n]<=2'd1;
                end
            end
            event_index<=0;
        end
    endtask

    always @(posedge clk) begin
        if(reset) begin
            midi_state<=RX;request<=0;response<=0;cache_request<=0;cache_response<=0;
            rx_count<=0;crc_index<=0;crc<=16'hFFFF;gap_count<=0;
            watchdog_count<=0;cache_valid<=0;response_cacheable<=0;
            session_state<=SESSION_NONE;session_token<=0;last_sequence<=0;
            panic_reg<=0;watchdog_cleanup<=0;event_count<=0;event_index<=0;all_index<=0;
            all_event_id<=0;
            for(i=0;i<4;i=i+1) begin
                event_ids[i]<=0;event_notes[i]<=0;
                event_velocities[i]<=0;event_codes[i]<=0;
            end
        end else begin
            panic_reg<=0;
            // Timeout owns this clock edge: late allocator results, cached
            // responses and DISPATCH assignments are all ignored.
            if(SHARED_AUDIO && source_cancel &&
                ((midi_state==DISPATCH && request[8+:8]==8'd2) ||
                 midi_state==EVENT_SEND || midi_state==EVENT_WAIT ||
                 midi_state==ALL_SCAN || midi_state==ALL_SEND || midi_state==ALL_WAIT)) begin
                // Global STOP/config recovery cancels the allocator's pending
                // event, so the cancelled ACK is skipped.
                // Keep UART framing alive so the host receives a bounded NAK.
                session_state<=SESSION_NONE;session_token<=0;last_sequence<=0;
                cache_valid<=0;watchdog_cleanup<=0;watchdog_count<=0;
                if(watchdog_cleanup || (midi_state==DISPATCH && opcode==8'h23)) begin
                    // Background cleanup and heartbeat run as fire-and-forget traffic.
                    // An unsolicited reply could collide with a v1 transaction.
                    midi_state<=RX;rx_count<=0;gap_count<=0;request<=0;
                end else queue_error(8'h10,request_token,0);
            end else if(watchdog_due) begin
                watchdog_count<=0;
                session_state<=SHARED_AUDIO?SESSION_QUIESCING:SESSION_NONE;
                session_token<=0;cache_valid<=0;
                response_cacheable<=0;last_sequence<=0;
                if(SHARED_AUDIO) begin
                    watchdog_cleanup<=1;
                    // Let an already accepted event receive its allocator ACK
                    // before scanning, so a late NoteOn still reaches the scan.
                    if((midi_state==EVENT_WAIT || midi_state==ALL_WAIT) && event_result_valid) begin
                        all_index<=0;midi_state<=ALL_SCAN;
                    end else if(midi_state!=EVENT_WAIT && midi_state!=ALL_WAIT) begin
                        midi_state<=ALL_SCAN;all_index<=0;
                    end
                end else begin
                    panic_reg<=1;
                    midi_state<=RX;rx_count<=0;gap_count<=0;request<=0;
                end
            end else begin
            if(session_state==SESSION_ACTIVE || session_state==SESSION_FAULT) begin
                watchdog_count<=watchdog_count+1'b1;
            end else watchdog_count<=0;
            if(session_state==SESSION_QUIESCING && voices_empty)
                session_state<=SESSION_DRAINED;

            case(midi_state)
                RX: begin
                    if(byte_error) begin rx_count<=0;gap_count<=0;request<=0;end
                    else if(byte_valid) begin
                        request<={byte_data,request[159:8]};gap_count<=0;
                        if(rx_count==19) begin
                            midi_state<=CHECK;crc<=16'hFFFF;crc_index<=0;
                        end else rx_count<=rx_count+1'b1;
                    end else if(rx_count!=0) begin
                        if(gap_count>=GAP_CYCLES-1) begin
                            rx_count<=0;gap_count<=0;request<=0;
                        end else gap_count<=gap_count+1'b1;
                    end
                end
                CHECK: begin
                    if(crc_index<18) begin
                        crc<=crc_byte(crc,request[crc_index*8+:8]);
                        crc_index<=crc_index+1'b1;
                    end else if(request[7:0]==8'hB2 &&
                                ((request[15:8]==8'd2) ||
                                 (SHARED_AUDIO && request[15:8]==8'd1)) &&
                                length<=8 && padding_ok && crc==request[144+:16]) begin
                        midi_state<=DISPATCH;
                    end else begin
                        rx_count<=19;gap_count<=0;midi_state<=RX;
                    end
                end
                DISPATCH: begin
                    if(SHARED_AUDIO && request[8+:8]==8'd1) begin
                        // Panel configuration owns this frame; keep the shared
                        // TX pin free of a competing error response.
                        midi_state<=RX;rx_count<=0;gap_count<=0;request<=0;
                    end else if(opcode==8'h24) begin
                        if(dispatch_length!=0 || dispatch_sequence_zero || dispatch_token_zero) begin
                            queue_error(8'h03,request_token,0);
                        end else if(cache_valid && dispatch_frame_equal) begin
                            response<=cache_response;midi_state<=SEND;
                        end else if(session_state==SESSION_NONE ||
                                    session_state==SESSION_DRAINED) begin
                            session_state<=SESSION_ACTIVE;session_token<=request_token;
                            last_sequence<=sequence_id;watchdog_count<=0;
                            cache_valid<=0;
                            queue_profile(8'hA4,8'd0,sequence_id,request_token,
                                          SESSION_ACTIVE,1);
                        end else begin
                            queue_profile(8'hFF,8'h11,sequence_id,session_token,
                                          session_state,0);
                        end
                    end else if(opcode==8'h23) begin
                        if(dispatch_length!=0 || !dispatch_sequence_zero) queue_error(8'h03,request_token,0);
                        else if(!dispatch_token_match || session_state==SESSION_NONE)
                            queue_error(8'h1A,request_token,0);
                        else begin watchdog_count<=0;midi_state<=RX;rx_count<=0;end
                    end else if(opcode==8'h25 && dispatch_token_zero) begin
                        if(dispatch_length!=0 || dispatch_sequence_zero) queue_error(8'h03,0,0);
                        else begin
                            queue_success(8'hA5,sequence_id,session_token,3,
                                drain_info,0);
                        end
                    end else if(opcode==8'h25) begin
                        if(dispatch_length!=0 || dispatch_sequence_zero) queue_error(8'h03,request_token,0);
                        else if(!dispatch_token_match) queue_error(8'h1A,request_token,0);
                        else if(dispatch_cache_hit) begin
                            if(dispatch_frame_equal) begin response<=cache_response;midi_state<=SEND;end
                            else queue_error(8'h04,request_token,0);
                        end else if(!dispatch_sequence_ok)
                            queue_error(8'h1B,request_token,0);
                        else begin
                            last_sequence<=sequence_id;watchdog_count<=0;
                            queue_success(8'hA5,sequence_id,session_token,3,
                                drain_info,1);
                        end
                    end else if(opcode==8'h20 || opcode==8'h21 || opcode==8'h22) begin
                        if((opcode==8'h20 && dispatch_length!=4 && dispatch_length!=7) ||
                           (opcode==8'h21 && dispatch_length!=2 && dispatch_length!=4 && dispatch_length!=5 && dispatch_length!=7) ||
                           (opcode==8'h22 && dispatch_length!=0) || !dispatch_events_ok || dispatch_sequence_zero)
                            queue_error(8'h03,request_token,0);
                        else if(!dispatch_token_ok)
                            queue_error(8'h1A,request_token,0);
                        else if(dispatch_cache_hit) begin
                            if(dispatch_frame_equal) begin response<=cache_response;midi_state<=SEND;end
                            else queue_error(8'h04,request_token,0);
                        end else if(!dispatch_sequence_ok)
                            queue_error(8'h1B,request_token,0);
                        else if(session_state!=SESSION_ACTIVE && opcode!=8'h22)
                            queue_error(8'h11,request_token,0);
                        else begin
                            last_sequence<=sequence_id;watchdog_count<=0;
                            if(opcode==8'h22) begin
                                all_index<=0;midi_state<=ALL_SCAN;
                            end else begin
                                load_note_events(opcode);midi_state<=EVENT_SEND;
                            end
                        end
                    end else queue_error(8'h01,request_token,0);
                end
                EVENT_SEND: if(event_ready) midi_state<=EVENT_WAIT;
                EVENT_WAIT: if(event_result_valid) begin
                    if(watchdog_cleanup) begin
                        all_index<=0;midi_state<=ALL_SCAN;
                    end else if(event_result_id!=event_ids[event_index] ||
                        (event_result_code!=0 && !(SHARED_AUDIO &&
                         event_codes[event_index]==2'd1 && event_result_code==3'd3))) begin
                        session_state<=SESSION_FAULT;
                        queue_error(result_status(event_result_code),session_token,1);
                    end else if(event_index+1'b1>=event_count) begin
                        queue_success(opcode|8'h80,sequence_id,session_token,0,56'd0,1);
                    end else begin
                        event_index<=event_index+1'b1;midi_state<=EVENT_SEND;
                    end
                end
                ALL_SCAN: begin
                    if(all_index>=32) begin
                        session_state<=voices_empty?
                                       SESSION_DRAINED:SESSION_QUIESCING;
                        if(watchdog_cleanup) begin
                            watchdog_cleanup<=0;midi_state<=RX;rx_count<=0;gap_count<=0;request<=0;
                        end else queue_success(8'hA2,sequence_id,session_token,1,
                            {48'd0,5'd0,(voices_empty?SESSION_DRAINED:SESSION_QUIESCING)},1);
                    end else if(allocated[all_index] && voice_gate[all_index] &&
                        (!SHARED_AUDIO || slot_ids[all_index*16+13+:3]==3'b101)) begin
                        all_event_id<=slot_ids[all_index*16+:16];
                        midi_state<=ALL_SEND;
                    end else all_index<=all_index+1'b1;
                end
                ALL_SEND: if(event_ready) midi_state<=ALL_WAIT;
                ALL_WAIT: if(event_result_valid) begin
                    if(watchdog_cleanup) begin
                        all_index<=0;midi_state<=ALL_SCAN;
                    end else if(event_result_id!=all_event_id || event_result_code!=0) begin
                        session_state<=SESSION_FAULT;
                        queue_error(result_status(event_result_code),session_token,1);
                    end else begin
                        all_index<=all_index+1'b1;midi_state<=ALL_SCAN;
                    end
                end
                RESPONSE_CRC: begin
                    if(crc_index<18) begin
                        crc<=crc_byte(crc,response[crc_index*8+:8]);
                        crc_index<=crc_index+1'b1;
                    end else begin
                        response[144+:16]<=crc;
                        if(response_cacheable) begin
                            cache_valid<=1;cache_request<=request;
                            cache_response<={crc,response[143:0]};
                        end
                        midi_state<=SEND;
                    end
                end
                SEND: if(tx_ready) midi_state<=DRAIN;
                DRAIN: if(tx_ready) begin
                    midi_state<=RX;rx_count<=0;gap_count<=0;request<=0;
                end
                default: begin midi_state<=RX;rx_count<=0;end
            endcase
            end
        end
    end
endmodule
