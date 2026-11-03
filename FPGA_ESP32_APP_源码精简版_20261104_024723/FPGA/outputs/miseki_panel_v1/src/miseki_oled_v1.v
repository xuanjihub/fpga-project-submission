`timescale 1ns/1ps
// N08 display-only owner; config and audio run independently of the display.
// Compare the visible state to the last immutable frame. Coalesce all changes
// during a transfer; resnapshot only when transport acknowledges frame_request.
module miseki_oled_v1 #(
 parameter integer CLK_HZ=50000000,I2C_HZ=100000,
 STARTUP_CYCLES=CLK_HZ/20,RETRY_CYCLES=CLK_HZ/10,
 FRAME_GAP_CYCLES=CLK_HZ/20,LINE_TIMEOUT_CYCLES=CLK_HZ/100
)(
 input wire clk,reset,input wire [3:0] screen,input wire [1:0] focus,
 input wire language,language_preview,language_dirty,
 input wire [223:0] drafts,input wire [13:0] dirty,
 input wire [4:0] mod_level,master_volume,
 input wire [1:0] preset_slot,preset_notice,input wire preset_save,preset_pending,
 input wire [3:0] preset_valid,input wire [11:0] pressure_level,
 input wire pressure_valid,editing,busy,fault,armed,healthy,mute,
 input wire [31:0] active,input wire [1:0] laser_mode,laser_function,timbre_a,timbre_b,
 input wire [7:0] laser_draft,input wire [3:0] laser_dirty,
 input wire mix_enabled,mix_draft,mix_dirty,
 input wire laser_level_valid,laser_blocked,laser_ready,laser_busy,
 input wire [15:0] revision,input wire [3:0] menu_selection,
 input wire [1:0] diag_selection,input wire [2:0] diag_status,diag_state,
 input wire [4:0] diag_index,input wire [7:0] diag_errors,
 inout wire scl,sda,output wire online,display_fault,
 output wire [6:0] address,output wire [7:0] errors,
 output wire [3:0] last_error,output wire [15:0] frames
);
 wire frame_start,pixel_req;wire [2:0] page;wire [6:0] column;
 wire pixel_valid;wire [7:0] pixel_data;
 // One local synchronous stage contains global POR fanout at this display
 // boundary. Transport and its I2C master assert/deassert together one cycle
 // later; audio/configuration and snapshot/valid reset timing are unchanged.
 (* syn_preserve = 1 *) reg display_reset=1'b1;
 always @(posedge clk)display_reset<=reset;
 integer v;reg [5:0] active_count;
 always @* begin
  active_count=0;
  for(v=0;v<32;v=v+1)active_count=active_count+{5'b0,active[v]};
 end
 // Pressure is quantized only for the display, which absorbs raw ADC jitter.
 // The full-resolution audio input is intact.
 wire [11:0] visible_pressure={pressure_level[11:8],8'b0};
 // Diagnostic progress changes only on bounded events; the snapshot covers
 // those events alone. A steady HOLD/READY page remains idle between real changes.
 wire [20:0] visible_diag=screen==10?{diag_selection,diag_status,diag_state,diag_index,diag_errors}:21'd0;
 localparam integer W=4+2+3+224+14+5+5+2+2+1+1+4+12+1+7+6+8+8+4+3+4+16+4+21;
 wire [W-1:0] visible={screen,focus,language,language_preview,language_dirty,drafts,dirty,mod_level,master_volume,
  preset_slot,preset_notice,preset_save,preset_pending,preset_valid,visible_pressure,
  pressure_valid,editing,busy,fault,armed,healthy,mute,1'b0,active_count,
  laser_mode,laser_function,timbre_a,timbre_b,laser_draft,laser_dirty,
  mix_enabled,mix_draft,mix_dirty,laser_level_valid,laser_blocked,laser_ready,laser_busy,
  revision,menu_selection,visible_diag};
 // Register short per-word comparisons. Only these narrow flags feed the
 // transport request decode; snapshot still captures the live, coherent state
 // at its acknowledgement. The flags may be stale for one clock after
 // frame_start, while transport is still busy with that immutable frame.
 localparam integer DIRTY_WORD_BITS=16;
 localparam integer DIRTY_WORDS=(W+DIRTY_WORD_BITS-1)/DIRTY_WORD_BITS;
 reg [DIRTY_WORDS-1:0] changed_words;
 reg [W-1:0] snapshot;reg have_snapshot;
 wire frame_request=!have_snapshot || |changed_words;
 genvar word_index;
 generate for(word_index=0;word_index<DIRTY_WORDS;word_index=word_index+1)begin:dirty_compare
  localparam integer LOW=word_index*DIRTY_WORD_BITS;
  localparam integer BITS=(LOW+DIRTY_WORD_BITS<=W)?DIRTY_WORD_BITS:W-LOW;
  always @(posedge clk)begin
   if(reset)changed_words[word_index]<=1'b0;
   else changed_words[word_index]<=visible[LOW+:BITS]!=snapshot[LOW+:BITS];
  end
 end endgenerate
 wire [3:0] screen_q,menu_q;wire [1:0] focus_q,slot_q,notice_q;
 wire language_q,language_preview_q,language_dirty_q,save_q,pending_q;wire [223:0] drafts_q;wire [13:0] dirty_q;
 wire [4:0] mod_q,master_q;wire [3:0] valid_q;wire [11:0] pressure_q;
 wire pressure_valid_q,editing_q,busy_q,fault_q,armed_q,healthy_q,mute_q,unused_q;
 wire [5:0] count_q;wire [1:0] laser_mode_q,function_q,a_q,b_q;
 wire [7:0] laser_draft_q;wire [3:0] laser_dirty_q;
 wire mix_q,mix_draft_q,mix_dirty_q,laser_valid_q,blocked_q,ready_q,laser_busy_q;
 wire [15:0] revision_q;
 wire [1:0] diag_selection_q;wire [2:0] diag_status_q,diag_state_q;
 wire [4:0] diag_index_q;wire [7:0] diag_errors_q;
 assign {screen_q,focus_q,language_q,language_preview_q,language_dirty_q,drafts_q,dirty_q,mod_q,master_q,slot_q,notice_q,
  save_q,pending_q,valid_q,pressure_q,pressure_valid_q,editing_q,busy_q,fault_q,
  armed_q,healthy_q,mute_q,unused_q,count_q,laser_mode_q,function_q,a_q,b_q,
  laser_draft_q,laser_dirty_q,mix_q,mix_draft_q,mix_dirty_q,laser_valid_q,blocked_q,
  ready_q,laser_busy_q,revision_q,menu_q,
  diag_selection_q,diag_status_q,diag_state_q,diag_index_q,diag_errors_q}=snapshot;
 always @(posedge clk)begin
  if(reset)begin snapshot<=0;have_snapshot<=0;end
  else begin
   if(frame_start)begin snapshot<=visible;have_snapshot<=1;end
  end
 end
 miseki_renderer_v1 pixels(
  .clk(clk),.reset(reset),.request(pixel_req),.valid(pixel_valid),
  .page(page),.column(column),.data(pixel_data),.screen(screen_q),
  .focus(focus_q),.language(language_q),.drafts(drafts_q),.dirty(dirty_q),
  .language_preview(language_preview_q),.language_dirty(language_dirty_q),
  .mod_level(mod_q),.master_volume(master_q),.preset_slot(slot_q),.preset_save(save_q),
  .preset_pending(pending_q),.preset_valid(valid_q),.preset_notice(notice_q),
  .pressure_level(pressure_q),.pressure_valid(pressure_valid_q),.active_count(count_q),
  .editing(editing_q),.busy(busy_q),.fault(fault_q),.armed(armed_q),.healthy(healthy_q),.mute(mute_q),
  .laser_mode(laser_mode_q),.laser_function(function_q),.timbre_a(a_q),.timbre_b(b_q),
  .laser_draft(laser_draft_q),.laser_dirty(laser_dirty_q),.mix_enabled(mix_q),
  .mix_draft(mix_draft_q),.mix_dirty(mix_dirty_q),.laser_level_valid(laser_valid_q),
  .laser_blocked(blocked_q),.laser_ready(ready_q),.laser_busy(laser_busy_q),
  .revision(revision_q),.menu_selection(menu_q),
  .diag_selection(diag_selection_q),.diag_status(diag_status_q),.diag_state(diag_state_q),
  .diag_index(diag_index_q),.diag_errors(diag_errors_q));
 miseki_ssd1309_v1 #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ),.STARTUP_CYCLES(STARTUP_CYCLES),
  .RETRY_CYCLES(RETRY_CYCLES),.FRAME_GAP_CYCLES(FRAME_GAP_CYCLES),
  .LINE_TIMEOUT_CYCLES(LINE_TIMEOUT_CYCLES)) display(
  .clk(clk),.reset(display_reset),.frame_request(frame_request),.frame_start(frame_start),
  .pixel_req(pixel_req),.page(page),.column(column),.pixel_valid(pixel_valid),.pixel_data(pixel_data),
  .scl(scl),.sda(sda),.online(online),.fault(display_fault),.address(address),
  .errors(errors),.last_error(last_error),.frames(frames));
endmodule
