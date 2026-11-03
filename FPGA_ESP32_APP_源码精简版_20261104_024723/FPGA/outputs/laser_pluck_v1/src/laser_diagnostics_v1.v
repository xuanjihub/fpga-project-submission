`timescale 1ns/1ps
// N05.4 observation only: one-way UART telemetry frames.
// Three explicit 64-byte frame schemas. The UART snapshots all bytes together.
module laser_diagnostics_v1 #(
    parameter integer CLK_HZ=50000000,
    parameter integer REPORT_CYCLES=CLK_HZ/10,
    parameter [31:0] BUILD_ID=32'h50314C02
)(
    input wire clk, reset, power_reset,
    input wire [31:0] trace_cycles,
    input wire bus_fault_valid, input wire [39:0] bus_fault_context,
    input wire [11:0] touch, gain, pressure_level,
    input wire configured, pressure_pressed, pressure_valid, mute, armed, healthy,
    input wire signed [15:0] audio_sample, effective_bend,
    input wire [31:0] allocated, voice_gate, active,
    input wire [3:0] selected,
    input wire [2:0] ui_view,
    input wire [1:0] route_mode, cfg_error, preset_slot, preset_notice,
    input wire [4:0] master_volume,
    input wire [7:0] key_held,
    input wire [2:0] expansion_levels,
    input wire [1:0] laser_mode,
    input wire laser_level_valid, laser_blocked, laser_ready, laser_busy,
    input wire [15:0] laser_triggers, laser_dropped,
    input wire editing, config_fault, config_busy, preset_save, preset_pending,
    input wire [15:0] draft_value, cfg_revision,
    input wire [111:0] cfg_state,
    input wire [47:0] delay_state, actual_delay_state,
    input wire [7:0] master_smooth_level,
    input wire transaction_cancel,
    input wire [31:0] mod_state,
    input wire [4:0] mod_level, mod_applied_level,
    input wire signed [15:0] mod_offset,
    input wire [31:0] invalid_counts,
    input wire [3:0] preset_valid,
    input wire oled_online, oled_fault,
    input wire [6:0] oled_address,
    input wire [7:0] oled_errors,
    input wire [3:0] oled_last_error,
    input wire [15:0] oled_frames,
    input wire [15:0] m_seq,
    input wire [31:0] m_age, touch_age, a_seq, a_errors, age0, age1,
    input wire [1:0] a_valid,
    input wire [7:0] a_error, m_errors,
    input wire signed [15:0] raw0, raw1,
    input wire m_ready, m_fault, m_valid, touch_usable,
    input wire [3:0] m_error,
    output reg [71:0] last_bus_fault,
    output reg [15:0] bus_fault_count,
    output reg [1:0] report_kind,
    output wire [495:0] payload,
    output wire report_ce, uart_tx
);
    wire [495:0] audio_payload, panel_payload, sensor_payload, delay_payload;
    always @(posedge clk) begin
        if(reset) begin last_bus_fault<=0; bus_fault_count<=0; end
        else if(bus_fault_valid) begin
            last_bus_fault<={trace_cycles,bus_fault_context};
            if(bus_fault_count!=16'hFFFF) bus_fault_count<=bus_fault_count+1'b1;
        end
        if(power_reset) report_kind<=0;
        else if(report_ce) report_kind<=report_kind+1'b1;
    end

    assign audio_payload[0+:32]=32'h2D5055AA;
    assign audio_payload[32+:32]=BUILD_ID;
    assign audio_payload[64+:32]=CLK_HZ;
    assign audio_payload[96+:32]=trace_cycles;
    assign audio_payload[128+:16]={4'b0,touch};
    assign audio_payload[144+:8]={configured,reset,pressure_pressed,pressure_valid,mute,armed,healthy,1'b0};
    assign audio_payload[152+:8]={6'b0,route_mode};
    assign audio_payload[160+:16]={4'b0,gain};
    assign audio_payload[176+:16]=audio_sample;
    assign audio_payload[192+:16]={4'b0,pressure_level};
    assign audio_payload[208+:16]=effective_bend;
    assign audio_payload[224+:32]=allocated;
    assign audio_payload[256+:32]=voice_gate;
    assign audio_payload[288+:32]=active;
    assign audio_payload[320+:16]=cfg_revision;
    assign audio_payload[336+:8]={3'b0,master_volume};
    assign audio_payload[344+:8]=key_held;
    assign audio_payload[352+:8]={5'b0,expansion_levels};
    assign audio_payload[360+:16]=mod_state[15:0];
    assign audio_payload[376+:16]=mod_state[31:16];
    assign audio_payload[392+:8]={3'b0,mod_level};
    assign audio_payload[400+:8]={3'b0,mod_applied_level};
    assign audio_payload[408+:16]=mod_offset;
    assign audio_payload[424+:8]={6'b0,laser_mode};
    assign audio_payload[432+:8]={4'b0,laser_busy,laser_ready,laser_blocked,laser_level_valid};
    assign audio_payload[440+:16]=laser_triggers;
    assign audio_payload[456+:16]=laser_dropped;
    assign audio_payload[472+:24]=0;

    assign panel_payload[0+:32]=32'h2E5055AA;
    assign panel_payload[32+:32]=BUILD_ID;
    assign panel_payload[64+:32]=CLK_HZ;
    assign panel_payload[96+:32]=trace_cycles;
    assign panel_payload[128+:8]={4'b0,selected};
    assign panel_payload[136+:8]={5'b0,ui_view};
    assign panel_payload[144+:8]={3'b0,master_volume};
    assign panel_payload[152+:8]={2'b0,config_busy,config_fault,configured,editing,pressure_valid,healthy};
    assign panel_payload[160+:16]=draft_value;
    assign panel_payload[176+:16]=cfg_revision;
    assign panel_payload[192+:112]=cfg_state;
    assign panel_payload[304+:8]={6'b0,route_mode};
    assign panel_payload[312+:8]=key_held;
    assign panel_payload[320+:32]=invalid_counts;
    assign panel_payload[352+:8]={6'b0,preset_slot};
    assign panel_payload[360+:8]={preset_valid,preset_notice,preset_pending,preset_save};
    assign panel_payload[368+:8]={6'b0,cfg_error};
    assign panel_payload[376+:8]={6'b0,oled_fault,oled_online};
    assign panel_payload[384+:8]={1'b0,oled_address};
    assign panel_payload[392+:8]=oled_errors;
    assign panel_payload[400+:8]={4'b0,oled_last_error};
    assign panel_payload[408+:16]=oled_frames;
    assign panel_payload[424+:8]={5'b0,expansion_levels};
    assign panel_payload[432+:16]=mod_state[15:0];
    assign panel_payload[448+:16]=mod_state[31:16];
    assign panel_payload[464+:8]={3'b0,mod_level};
    assign panel_payload[472+:8]={3'b0,mod_applied_level};
    assign panel_payload[480+:16]=mod_offset;

    assign sensor_payload[0+:32]=32'h2F5055AA;
    assign sensor_payload[32+:32]=BUILD_ID;
    assign sensor_payload[64+:32]=CLK_HZ;
    assign sensor_payload[96+:32]=trace_cycles;
    assign sensor_payload[128+:16]=m_seq;
    assign sensor_payload[144+:32]=m_age;
    assign sensor_payload[176+:32]=touch_age;
    assign sensor_payload[208+:32]=a_seq;
    assign sensor_payload[240+:8]={6'b0,a_valid};
    assign sensor_payload[248+:8]=a_error;
    assign sensor_payload[256+:32]=a_errors;
    assign sensor_payload[288+:16]=raw0;
    assign sensor_payload[304+:16]=raw1;
    assign sensor_payload[320+:32]=age0;
    assign sensor_payload[352+:32]=age1;
    assign sensor_payload[384+:8]={4'b0,touch_usable,m_valid,m_fault,m_ready};
    assign sensor_payload[392+:8]={4'b0,m_error};
    assign sensor_payload[400+:8]=m_errors;
    assign sensor_payload[408+:72]=last_bus_fault;
    assign sensor_payload[480+:16]=bus_fault_count;
    // N05.4 has its own schema: accepted and running coefficients are distinct.
    assign delay_payload[0+:32]=32'h305055AA;
    assign delay_payload[32+:32]=BUILD_ID;
    assign delay_payload[64+:32]=CLK_HZ;
    assign delay_payload[96+:32]=trace_cycles;
    assign delay_payload[128+:48]=delay_state;
    assign delay_payload[176+:8]={3'b0,master_volume};
    assign delay_payload[184+:16]=cfg_revision;
    assign delay_payload[200+:8]={4'b0,transaction_cancel,config_fault,config_busy,configured};
    assign delay_payload[208+:48]=actual_delay_state;
    assign delay_payload[256+:8]=master_smooth_level;
    assign delay_payload[264+:8]=8'd4; // volatile preset format
    assign delay_payload[272+:224]=0;
    assign payload=report_kind==3?delay_payload:report_kind==2?sensor_payload:report_kind==1?panel_payload:audio_payload;
    p13_uart #(.CLK_HZ(CLK_HZ),.REPORT_CYCLES(REPORT_CYCLES)) reporter (
        .clk(clk),.reset(power_reset),.payload(payload),.frame_ce(report_ce),.tx(uart_tx)
    );
endmodule
