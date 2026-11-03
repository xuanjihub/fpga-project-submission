`timescale 1ns/1ps
// One fourteen-field writer, revision-qualified publication, page-wide drafts.
module miseki_panel_config_v1 (
 input wire clk,reset,input wire [3:0] encoder_up,encoder_down,
 input wire [7:0] key_press,input wire sideband_editing,
 input wire diagnostic_begin,diagnostic_restore,diagnostic_latency_profile,
 output reg diagnostic_active,diagnostic_ready,
 input wire remote_valid,input wire [4:0] remote_master,
 output wire remote_ready,output reg remote_done,
 output wire [7:0] remote_status,output wire [15:0] remote_revision,
 output wire [4:0] remote_value,
 input wire remote_timbre_valid,input wire [1:0] remote_timbre,
 output wire remote_timbre_ready,output reg remote_timbre_done,
 output wire [7:0] remote_timbre_status,output wire [15:0] remote_timbre_revision,
 output wire [1:0] remote_timbre_value,
 input wire remote_adsr_valid,input wire [1:0] remote_adsr_field,input wire [4:0] remote_adsr_index,
 output wire remote_adsr_ready,output reg remote_adsr_done,
 output wire [7:0] remote_adsr_status,output wire [15:0] remote_adsr_revision,
 output wire [4:0] remote_adsr_value,output wire [19:0] adsr_indices,output wire [15:0] adsr_revision,
 input wire cfg_ready,cfg_applied,input wire [15:0] cfg_revision,
 input wire [1:0] cfg_error,input wire [111:0] cfg_state,
 input wire [31:0] mod_state,input wire [47:0] delay_state,
 input wire transaction_cancel,live_clear,input wire [1:0] route_mode,
 output wire cfg_valid,output wire [7:0] cfg_id,output wire [15:0] cfg_value,
 output reg [3:0] selected,output wire editing,output reg initialized,fault,
 output wire busy,output wire [15:0] draft_value,output wire [2:0] ui_view,
 output reg [4:0] mod_level,master_volume,output reg [1:0] preset_slot,
 output reg preset_save,preset_pending,output reg [3:0] preset_valid,
 output reg [1:0] preset_notice,output reg [3:0] screen,
 output reg [1:0] focus,output reg language,output wire [223:0] drafts,
 output wire [13:0] dirty,output reg [3:0] menu_selection,
 output wire language_preview,language_dirty
);
 `include "delay_catalog_v1.vh"
 localparam [2:0] SEND=0,WAIT_APPLY=1,IDLE=2,ERROR=3,LOAD_FIELD=4;
 localparam [2:0] PRESET_FORMAT_VERSION=4;
 reg [2:0] state;reg [3:0] tx_index;reg [15:0] tx_value;
 reg [5:0] accepted_index[0:13],draft_index[0:13];
 reg [83:0] pending_indices;reg pending_load,pending_remote,pending_remote_timbre,pending_remote_adsr;
 reg [83:0] diagnostic_saved;
 reg diagnostic_restoring;
 reg [1:0] pending_adsr_field;
 // The endpoint consumes one response class at a time; share its payload
 // registers and qualify the payload with exactly one corresponding done.
 reg [7:0] response_status;reg [15:0] response_revision;reg [4:0] response_value;
 assign remote_status=response_status;
 assign remote_timbre_status=response_status;
 assign remote_adsr_status=response_status;
 assign remote_revision=response_revision;
 assign remote_timbre_revision=response_revision;
 assign remote_adsr_revision=response_revision;
 assign remote_value=response_value;
 assign remote_timbre_value=response_value[1:0];
 assign remote_adsr_value=response_value;
 reg [15:0] accepted_revision;reg [83:0] preset_mem[0:3];
 reg [2:0] preset_version[0:3];reg language_draft;integer field,knob;
 function [3:0] wire_page;
  input [3:0] id;begin wire_page=id<8?id:id==13?4'd8:id+4'd1;end
 endfunction
 function [3:0] screen_field;
  input [3:0] page;input [1:0] column;
  begin screen_field=15;case(page)
   0:case(column)0:screen_field=5;1:screen_field=6;2:screen_field=8;3:screen_field=7;endcase
   1:screen_field={2'd0,column};
   2:if(column<2)screen_field=9+column;else if(column==3)screen_field=4;
   3:if(column<3)screen_field=11+column;
   4:if(column==0)screen_field=7;
   default:begin end
  endcase end
 endfunction
 // UI indices are saved.
 // This temporary profile uses the same single writer and publication ACK.
 function [5:0] diagnostic_index;
  input [3:0] id;input latency_profile;
  begin case(id)
   1:diagnostic_index=latency_profile?6'd5:6'd0;
   2,4:diagnostic_index=16;
   8:diagnostic_index=8;
   default:diagnostic_index=0;
  endcase end
 endfunction
 function [5:0] step_index;
  input [3:0] page;input [5:0] index;input up;reg [5:0] limit;
  begin limit=cat_ui_limit(page);step_index=index;
   if(cat_ui_wrap(page))begin
    if(up)step_index=index==limit?6'd0:index+6'd1;
    else step_index=index==0?limit:index-6'd1;
   end else if(up)begin if(index<limit)step_index=index+6'd1;end
   else if(index!=0)step_index=index-6'd1;
  end
 endfunction
 function preset_compatible;
  input [2:0] version;begin preset_compatible=version==PRESET_FORMAT_VERSION;end
 endfunction
 genvar g;
 generate for(g=0;g<14;g=g+1)begin:display_drafts
  assign dirty[g]=draft_index[g]!=accepted_index[g];
  assign drafts[g*16+:16]=cat_ui_value(g,draft_index[g]);
 end endgenerate
 assign language_preview=language_draft;
 assign language_dirty=language_draft!=language;
 assign editing=(|dirty)||language_dirty;
 assign busy=state!=IDLE;
 assign ui_view=screen==5?3'd5:screen==6?3'd6:screen==7?3'd3:screen==2?3'd4:3'd0;
 assign draft_value=selected<14?cat_ui_value(selected,draft_index[selected]):16'd0;
 assign cfg_valid=!reset&&!fault&&!transaction_cancel&&state==SEND;
 assign cfg_id=tx_index==14?CAT_COMMIT:{4'b0,tx_index};
 assign cfg_value=tx_value;
 wire remote_common_eligible=initialized&&state==IDLE&&!editing&&!sideband_editing&&!diagnostic_active&&
  !preset_pending&&!fault&&key_press==0&&encoder_up==0&&encoder_down==0;
 wire remote_eligible=remote_common_eligible&&remote_master<=16;
 wire remote_timbre_eligible=remote_common_eligible&&remote_timbre<=3;
 assign remote_ready=remote_eligible&&!reset&&!transaction_cancel&&cfg_error==0;
 assign remote_timbre_ready=remote_timbre_eligible&&!reset&&!transaction_cancel&&cfg_error==0;
 wire remote_adsr_eligible=remote_common_eligible&&remote_adsr_field<4&&remote_adsr_index <= (remote_adsr_field==2 ? 5'd16 : 5'd7);
 assign remote_adsr_ready=remote_adsr_eligible&&!reset&&!transaction_cancel&&cfg_error==0;
 assign adsr_indices={accepted_index[3][4:0],accepted_index[2][4:0],accepted_index[1][4:0],accepted_index[0][4:0]};
 assign adsr_revision=accepted_revision;
 wire publication_ack=cfg_applied&&cfg_revision==(accepted_revision+16'd1);
 wire navigation=|key_press[6:2];
 wire [3:0] target_screen=key_press[2]?4'd1:key_press[3]?4'd3:key_press[4]?4'd0:key_press[5]?4'd7:4'd9;
 task discard_drafts;
  integer n;begin
   for(n=0;n<14;n=n+1)draft_index[n]<=accepted_index[n];
   language_draft<=language;
  end
 endtask
 task launch_drafts;
  integer n;begin
   for(n=0;n<14;n=n+1)begin
    pending_indices[n*6+:6]<=draft_index[n];
   end
   pending_load<=0;pending_remote<=0;pending_remote_timbre<=0;pending_remote_adsr<=0;tx_index<=0;state<=LOAD_FIELD;
  end
 endtask
 always @(posedge clk)begin
  if(reset)begin
   state<=LOAD_FIELD;tx_index<=0;tx_value<=0;selected<=5;
   initialized<=0;fault<=0;accepted_revision<=0;
   pending_load<=0;pending_remote<=0;pending_remote_timbre<=0;pending_remote_adsr<=0;
   diagnostic_active<=0;diagnostic_ready<=0;diagnostic_restoring<=0;diagnostic_saved<=0;
   pending_adsr_field<=0;
   remote_done<=0;remote_timbre_done<=0;remote_adsr_done<=0;
   response_status<=0;response_revision<=0;response_value<=16;
   mod_level<=0;master_volume<=16;
   preset_slot<=0;preset_save<=0;preset_pending<=0;preset_valid<=0;preset_notice<=0;
   screen<=0;focus<=0;menu_selection<=0;language<=1;language_draft<=1;
   for(field=0;field<14;field=field+1)begin
    accepted_index[field]<=cat_ui_default_index(field);
    draft_index[field]<=cat_ui_default_index(field);
    pending_indices[field*6+:6]<=cat_ui_default_index(field);
   end
   for(field=0;field<4;field=field+1)preset_version[field]<=0;
  end else begin
   remote_done<=0;remote_timbre_done<=0;remote_adsr_done<=0;
   if(transaction_cancel||live_clear||cfg_error!=0||fault||diagnostic_active)mod_level<=0;
   else if(state==IDLE&&screen==2&&!preset_pending&&!key_press[7]&&
    !key_press[1]&&!navigation&&encoder_up[2]!=encoder_down[2])begin
    focus<=2;
    if(encoder_up[2]&&mod_level<16)mod_level<=mod_level+5'd1;
    else if(encoder_down[2]&&mod_level!=0)mod_level<=mod_level-5'd1;
   end
   if(cfg_error!=0)begin
    if(pending_remote)begin
     response_status<=8'h14;response_revision<=cfg_revision;
     if(pending_remote_adsr)begin
      remote_adsr_done<=1;response_value<=accepted_index[pending_adsr_field][4:0];
     end else if(pending_remote_timbre)begin
      remote_timbre_done<=1;response_value<={3'b0,accepted_index[5][1:0]};
     end else begin
      remote_done<=1;response_value<=master_volume;
     end
    end
    pending_remote<=0;pending_remote_timbre<=0;pending_remote_adsr<=0;state<=ERROR;fault<=1;initialized<=0;
    preset_pending<=0;preset_notice<=0;pending_load<=0;discard_drafts();
    diagnostic_ready<=0;
   end else if(state==WAIT_APPLY&&publication_ack)begin
    // A real publication wins over cancellation at this edge.
    state<=IDLE;tx_index<=0;initialized<=1;accepted_revision<=cfg_revision;
    for(field=0;field<14;field=field+1)begin
     accepted_index[field]<=pending_indices[field*6+:6];
     draft_index[field]<=pending_indices[field*6+:6];
    end
    master_volume<=pending_indices[48+:5];
    if(pending_remote)begin
     response_status<=8'h00;response_revision<=cfg_revision;
     if(pending_remote_adsr)begin
      remote_adsr_done<=1;response_value<=pending_indices[pending_adsr_field*6 +: 5];
     end else if(pending_remote_timbre)begin
      remote_timbre_done<=1;response_value<={3'b0,pending_indices[30+:2]};
     end else begin
      remote_done<=1;response_value<=pending_indices[48+:5];
     end
    end
    pending_remote<=0;pending_remote_timbre<=0;pending_remote_adsr<=0;
    if(pending_load)preset_notice<=2;else if(transaction_cancel)preset_notice<=0;
    pending_load<=0;if(transaction_cancel)preset_pending<=0;
    if(diagnostic_active)begin
     if(diagnostic_restoring)begin
      diagnostic_active<=0;diagnostic_ready<=0;diagnostic_restoring<=0;
     end else diagnostic_ready<=!transaction_cancel;
    end
   end else if(transaction_cancel)begin
    if(pending_remote)begin
     response_status<=8'h13;response_revision<=cfg_revision;
     if(pending_remote_adsr)begin
      remote_adsr_done<=1;response_value<=accepted_index[pending_adsr_field][4:0];
     end else if(pending_remote_timbre)begin
      remote_timbre_done<=1;response_value<={3'b0,accepted_index[5][1:0]};
     end else begin
      remote_done<=1;response_value<=master_volume;
     end
    end
    pending_remote<=0;pending_remote_timbre<=0;pending_remote_adsr<=0;state<=IDLE;tx_index<=0;
    pending_load<=0;preset_pending<=0;preset_notice<=0;discard_drafts();
    diagnostic_ready<=0;diagnostic_restoring<=0;
   end else if(!initialized&&state==IDLE&&!fault)begin
    state<=LOAD_FIELD;tx_index<=0;
    for(field=0;field<14;field=field+1)
     pending_indices[field*6+:6]<=cat_ui_default_index(field);
   end else if(state==IDLE&&diagnostic_active&&diagnostic_restore)begin
    pending_indices<=diagnostic_saved;
    diagnostic_ready<=0;diagnostic_restoring<=1;
    pending_load<=0;pending_remote<=0;pending_remote_timbre<=0;pending_remote_adsr<=0;
    tx_index<=0;state<=LOAD_FIELD;
   end else if(state==IDLE&&initialized&&!fault&&!editing&&!sideband_editing&&
               !preset_pending&&diagnostic_begin&&!diagnostic_active)begin
    for(field=0;field<14;field=field+1)begin
     diagnostic_saved[field*6+:6]<=accepted_index[field];
     pending_indices[field*6+:6]<=diagnostic_index(field,diagnostic_latency_profile);
    end
    diagnostic_active<=1;diagnostic_ready<=0;diagnostic_restoring<=0;mod_level<=0;
    pending_load<=0;pending_remote<=0;pending_remote_timbre<=0;pending_remote_adsr<=0;
    tx_index<=0;state<=LOAD_FIELD;
   end else if(remote_adsr_valid&&remote_adsr_eligible)begin
    if(remote_adsr_index==accepted_index[remote_adsr_field][4:0])begin
     remote_adsr_done<=1;response_status<=8'h00;response_revision<=cfg_revision;
     response_value<=accepted_index[remote_adsr_field][4:0];
    end else begin
     for(field=0;field<14;field=field+1)pending_indices[field*6+:6]<=accepted_index[field];
     case(remote_adsr_field)
      2'd0:pending_indices[0+:6]<={1'b0,remote_adsr_index};
      2'd1:pending_indices[6+:6]<={1'b0,remote_adsr_index};
      2'd2:pending_indices[12+:6]<={1'b0,remote_adsr_index};
      2'd3:pending_indices[18+:6]<={1'b0,remote_adsr_index};
     endcase
     pending_adsr_field<=remote_adsr_field;pending_remote<=1;pending_remote_adsr<=1;pending_remote_timbre<=0;pending_load<=0;tx_index<=0;state<=LOAD_FIELD;
    end
   end else if(remote_valid&&remote_eligible)begin
    if(remote_master==master_volume)begin
     remote_done<=1;response_status<=8'h00;response_revision<=cfg_revision;response_value<=master_volume;
    end else begin
     for(field=0;field<14;field=field+1)pending_indices[field*6+:6]<=accepted_index[field];
     pending_indices[48+:6]<={1'b0,remote_master};
     pending_remote<=1;pending_remote_timbre<=0;pending_remote_adsr<=0;pending_load<=0;tx_index<=0;state<=LOAD_FIELD;
    end
   end else if(remote_timbre_valid&&remote_timbre_eligible)begin
    if(remote_timbre==accepted_index[5][1:0])begin
     remote_timbre_done<=1;response_status<=8'h00;response_revision<=cfg_revision;
     response_value<={3'b0,accepted_index[5][1:0]};
    end else begin
     for(field=0;field<14;field=field+1)pending_indices[field*6+:6]<=accepted_index[field];
     pending_indices[30+:6]<={4'b0,remote_timbre};
     pending_remote<=1;pending_remote_timbre<=1;pending_remote_adsr<=0;pending_load<=0;tx_index<=0;state<=LOAD_FIELD;
    end
   end else case(state)
    // The immutable index snapshot is the transaction's only full-bank
    // storage. Decode one field before asserting valid; the registered value
    // remains stable under backpressure, and index 14 is the COMMIT marker.
    LOAD_FIELD:begin
     if(tx_index<14)
      tx_value<=cat_ui_value(wire_page(tx_index),pending_indices[wire_page(tx_index)*6+:6]);
     else tx_value<=0;
     state<=SEND;
    end
    SEND:if(cfg_ready)begin
     if(tx_index==14)state<=WAIT_APPLY;
     else begin tx_index<=tx_index+4'd1;state<=LOAD_FIELD;end
    end
    WAIT_APPLY:begin end
    IDLE:if(!key_press[7]&&!diagnostic_active)begin
     if(key_press[1])begin
      if(preset_pending)preset_pending<=0;
      else if(editing)discard_drafts();
      else if(!sideband_editing)begin
       if(screen==10)begin screen<=9;menu_selection<=9;focus<=0;end
       else begin screen<=0;focus<=0;selected<=5;end
      end
     end else if(navigation)begin
      if(!editing&&!sideband_editing&&!preset_pending)begin
       screen<=target_screen;focus<=0;
       if(target_screen==9)menu_selection<=screen==10?4'd9:screen<9?screen:menu_selection;
       if(screen_field(target_screen,0)<14)selected<=screen_field(target_screen,0);
      end
     end else if(key_press[0])begin
      if(screen==9)begin
       screen<=menu_selection==9?4'd10:menu_selection;focus<=0;
       if(screen_field(menu_selection,0)<14)selected<=screen_field(menu_selection,0);
      end else if(screen==8)language<=language_draft;
      else if(screen==7)begin
       if(preset_pending)begin
        preset_pending<=0;
        if(preset_save)begin
         for(field=0;field<14;field=field+1)
          preset_mem[preset_slot][field*6+:6]<=accepted_index[field];
         preset_valid[preset_slot]<=1;preset_version[preset_slot]<=PRESET_FORMAT_VERSION;
         preset_notice<=1;
        end else if(preset_valid[preset_slot]&&preset_compatible(preset_version[preset_slot]))begin
         pending_indices<=preset_mem[preset_slot];pending_load<=1;
         pending_remote<=0;pending_remote_timbre<=0;pending_remote_adsr<=0;tx_index<=0;state<=LOAD_FIELD;
        end else preset_notice<=3;
       end else if(!preset_save&&(!preset_valid[preset_slot]||
        !preset_compatible(preset_version[preset_slot])))preset_notice<=3;
       else begin preset_pending<=1;preset_notice<=0;end
      end else if((|dirty)&&!sideband_editing)launch_drafts();
     end else if(!preset_pending)begin
      if(screen==9)begin
       if(encoder_up[0]!=encoder_down[0])
        menu_selection<=encoder_up[0]?(menu_selection==9?0:menu_selection+4'd1):
         (menu_selection==0?9:menu_selection-4'd1);
      end else if(screen==7)begin
       if(encoder_up[0]!=encoder_down[0])begin
        preset_slot<=encoder_up[0]?preset_slot+2'd1:preset_slot-2'd1;focus<=0;
       end
       if(encoder_up[1]!=encoder_down[1])begin preset_save<=!preset_save;focus<=1;end
      end else if(screen==8)begin
       if(encoder_up[0]!=encoder_down[0])begin language_draft<=!language_draft;focus<=0;end
      end else if(!sideband_editing)begin
       // Distinct columns update distinct drafts on the same edge.
       for(knob=0;knob<4;knob=knob+1)begin
        if(encoder_up[knob]!=encoder_down[knob]&&screen_field(screen,knob)<14)begin
         draft_index[screen_field(screen,knob)]<=step_index(screen_field(screen,knob),
          draft_index[screen_field(screen,knob)],encoder_up[knob]);
         selected<=screen_field(screen,knob);focus<=knob;
        end
       end
      end
     end
    end
    default:begin end
   endcase
  end
 end
endmodule
