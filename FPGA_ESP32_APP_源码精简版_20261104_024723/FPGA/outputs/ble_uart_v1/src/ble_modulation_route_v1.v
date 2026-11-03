// BLE-compatible control implementation.
// Derived from audio_modulation_v1: raw LFO readout and late clear selection
// preserve same-cycle reset/cancel, arithmetic, publication and audio latency.
// Migrated copy of route_system; this module alone owns the audio parameter bus.
// Base values and modulation are separate; a new route replaces the old one.
module modulation_route_v1 #(parameter integer CLK_HZ=50000000,
 parameter integer CONTROL_CYCLES=CLK_HZ/1000)(
 input wire clk,reset,sample_ce,pressure_valid,
 input wire modulation_clear,input wire [4:0] mod_level,
 input wire [11:0] pressure_level,pressure_gain,
 input wire cfg_valid,input wire [7:0] cfg_id,input wire [15:0] cfg_value,
 output wire cfg_ready,output reg cfg_applied,output reg [1:0] cfg_error,
 output reg [111:0] cfg_state,output reg [15:0] revision,
 output reg [31:0] mod_state,output wire signed [15:0] mod_offset,
 output wire [4:0] mod_applied_level,output wire [31:0] mod_phase,output wire mod_ready,
 output reg [1:0] route_mode,output reg [11:0] gain,
 output wire core_valid,output wire [7:0] core_id,output wire [15:0] core_value,
 input wire core_ready,core_applied,input wire [1:0] core_error,
 input wire [111:0] core_state);
 `include "modulation_catalog_v1.vh"
 localparam IDLE=0,SEND=1,WAIT_ACK=2,ERROR=3,NEUTRAL=4,PREVIEW=5;
 reg [2:0] state;
 reg [1:0] pending_route,shadow_route;
 reg [3:0] tx_index;
 reg [111:0] shadow,pending_base,tx_bank;
 reg [31:0] shadow_mod,pending_mod;
 reg writing,user_commit,initialized,preparing;
 reg mod_dirty,withdraw_pending,tx_has_mod;
 reg signed [15:0] preview_offset_q,preview_pressure;
 reg [1:0] preview_route;
 reg offset_settle;
 reg [31:0] control_timer;
 wire control_tick=control_timer==CONTROL_CYCLES-1;
 wire [12:0] pressure_rounded={1'b0,pressure_level}+13'd8;
 wire signed [15:0] offset=pressure_valid ? {7'b0,pressure_rounded[12:4]} : 16'd0;
 wire [1:0] command_error=cat_system_error(cfg_id,cfg_value);
 wire signed [15:0] raw_offset;
 modulation_lfo_v1 lfo(.clk(clk),.reset(reset),.clear(modulation_clear||withdraw_pending),.control_ce(control_tick),
  .rate_hz(mod_state[15:0]),.depth(mod_state[31:16]),.live_level(mod_level),
  .offset(mod_offset),.raw_offset(raw_offset),.applied_level(mod_applied_level),.phase(mod_phase));
 // Preview a transaction's new depth at its captured phase/level. This lets
 // the existing core ACK publish base/routing/modulation fields atomically.
 // The live LFO still runs from accepted state while the transaction is busy.
 function signed [15:0] transaction_offset;
  input [15:0] depth;
  reg signed [9:0] position,triangle_value;
  reg signed [17:0] depth_product;
  reg signed [23:0] product;
  reg [23:0] magnitude,rounded;
  begin
   position={2'd0,mod_phase[31:24]};
   if(position<64)triangle_value=position;else if(position<192)triangle_value=128-position;else triangle_value=position-256;
   depth_product=triangle_value*$signed({1'b0,depth[6:0]});
   product=depth_product*$signed({1'b0,mod_applied_level});
   magnitude=product<0?-product:product;
   rounded=(magnitude+24'd512)>>10;
   if(reset||modulation_clear||withdraw_pending)transaction_offset=0;
   else if(product<0)transaction_offset=-$signed(rounded[15:0]);
   else transaction_offset=$signed(rounded[15:0]);
  end
 endfunction
 function [15:0] mapped_bend;
  input [111:0] base;input [1:0] mode;input signed [15:0] amount,modulation;
  // Accepted base [-256,256] + pressure [0,256] + LFO [-64,64]
  // is [-320,576]. Signed eleven bits retain the entire sum before the
  // single clamp, without an unnecessary eighteen-bit comparison chain.
  reg signed [10:0] n;
  begin
   n=$signed(base[64+:11]);
   if(mode==CAT_PITCH)n=n+$signed(amount[10:0]);
   n=n+$signed(modulation[10:0]);
   if(n>11'sd256)mapped_bend=CAT_BEND_MAX;
   else if(n< -11'sd256)mapped_bend=CAT_BEND_MIN;
   else mapped_bend={{5{n[10]}},n};
  end
 endfunction
 wire lfo_mask=reset||modulation_clear||withdraw_pending;
 wire [15:0] bend_without_mod=mapped_bend(cfg_state,route_mode,offset,16'sd0);
 wire [15:0] bend_with_mod=mapped_bend(cfg_state,route_mode,offset,raw_offset);
 wire [15:0] live_bend=lfo_mask ? bend_without_mod : bend_with_mod;
 wire live_bend_changed=lfo_mask ? bend_without_mod!=core_state[64+:16] : bend_with_mod!=core_state[64+:16];
 // Pressure failure withdraws its contribution.
 wire [11:0] gain_target=(!preparing&&route_mode==CAT_VOLUME&&pressure_valid) ? {2'b0,pressure_gain[11:2]} : 12'd1024;
 assign mod_ready=!withdraw_pending;
 assign cfg_ready=!reset&&state==IDLE&&cfg_error==0&&!withdraw_pending;
 assign core_valid=!reset&&state==SEND;
 assign core_id=tx_index==7 ? CAT_COMMIT : {4'b0,tx_index};
 assign core_value=tx_index==7 ? 16'd0 : tx_bank[tx_index*16+:16];
 always @(posedge clk)begin
  if(reset)begin
   state<=IDLE;tx_index<=0;route_mode<=CAT_OFF;shadow_route<=CAT_OFF;pending_route<=CAT_OFF;
   cfg_state<=CAT_SYSTEM_DEFAULT;
   shadow<=CAT_SYSTEM_DEFAULT;
   mod_state<=CAT_MOD_DEFAULT;shadow_mod<=CAT_MOD_DEFAULT;pending_mod<=0;
   pending_base<=0;tx_bank<=0;writing<=0;user_commit<=0;initialized<=0;preparing<=0;
   mod_dirty<=0;withdraw_pending<=0;tx_has_mod<=0;
   preview_offset_q<=0;preview_pressure<=0;preview_route<=CAT_OFF;offset_settle<=0;
   revision<=0;cfg_applied<=0;cfg_error<=0;gain<=1024;control_timer<=0;
  end else begin
   cfg_applied<=0;
   offset_settle<=0;
   // STOP/health loss clears the oscillator immediately, but an old bend
   // transaction may still be in SEND/WAIT_ACK. Hold re-arm until a known
   // modulation-free bank is acknowledged. The live-OFF path leaves this
   // state clean and retains the previous version's exact transaction timing.
   if(mod_offset!=0||((state==SEND||state==WAIT_ACK)&&tx_has_mod)||
      (state==PREVIEW&&preview_offset_q!=0))mod_dirty<=1;
   if(modulation_clear&&(mod_dirty||((state==SEND||state==WAIT_ACK)&&tx_has_mod)||
      (state==PREVIEW&&preview_offset_q!=0)))withdraw_pending<=1;
   if(state==WAIT_ACK&&core_applied&&!tx_has_mod&&!preparing&&(modulation_clear||withdraw_pending))begin
    mod_dirty<=0;withdraw_pending<=0;
   end
   if(control_tick)control_timer<=0;else control_timer<=control_timer+1'b1;
   if(sample_ce)begin
    if(gain_target>gain)gain<=gain_target-gain>32 ? gain+12'd32 : gain_target;
    else gain<=gain-gain_target>32 ? gain-12'd32 : gain_target;
   end
   if(core_error!=0)begin cfg_error<=core_error;state<=ERROR;end
   else case(state)
    IDLE:begin
     if(withdraw_pending)begin
      tx_bank<=cfg_state;tx_bank[64+:16]<=mapped_bend(cfg_state,route_mode,offset,16'sd0);
      tx_has_mod<=0;user_commit<=0;tx_index<=0;state<=SEND;
     end else if(cfg_valid&&cfg_ready)begin
      if(command_error!=0)begin cfg_error<=command_error;state<=ERROR;end
      else if(cfg_id<=CAT_PLUCK)begin
       shadow[cfg_id*16+:16]<=cfg_value;writing<=1;
      end else if(cfg_id==CAT_FSR_ROUTE)begin
       shadow_route<=cfg_value[1:0];writing<=1;
      end else if(cfg_id==CAT_MOD_RATE)begin
       shadow_mod[15:0]<=cfg_value;writing<=1;
      end else if(cfg_id==CAT_MOD_DEPTH)begin
       shadow_mod[31:16]<=cfg_value;writing<=1;
      end else if(cfg_id==CAT_ABORT&&cfg_value==0)begin
       shadow<=cfg_state;shadow_route<=route_mode;shadow_mod<=mod_state;writing<=0;
      end else if(cfg_id==CAT_COMMIT&&cfg_value==0)begin
       pending_base<=shadow;pending_route<=shadow_route;pending_mod<=shadow_mod;user_commit<=1;
       // Break before make: withdraw old pitch and slew old gain to neutral
       // before publishing a different target. UI stays WAIT throughout.
       preparing<=shadow_route!=route_mode;
       tx_bank<=shadow_route!=route_mode ? cfg_state : shadow;
       tx_index<=0;
       if(shadow_route!=route_mode||(mod_applied_level==0||shadow_mod[31:16]==0))begin
        // Retain the old OFF transaction timing and break-before-make bank.
        tx_bank[64+:16]<=mapped_bend(shadow_route!=route_mode ? cfg_state : shadow,
                                   shadow_route!=route_mode?CAT_OFF:shadow_route,offset,
                                   shadow_route!=route_mode?mod_offset:16'sd0);
        tx_has_mod<=shadow_route!=route_mode&&mod_offset!=0;state<=SEND;
       end else begin
        // Capture arithmetic and its operands together before sum/clamp.
        // This register separates the preview multipliers from the bank.
        preview_offset_q<=transaction_offset(shadow_mod[31:16]);
        preview_pressure<=offset;preview_route<=shadow_route;state<=PREVIEW;
       end
      end else begin cfg_error<=1;state<=ERROR;end
     end else if(!writing&&initialized&&!offset_settle&&control_tick&&live_bend_changed)begin
      // Hold publication until the UI transaction is complete.
      tx_bank<=cfg_state;tx_bank[64+:16]<=live_bend;
      tx_has_mod<=mod_offset!=0;
      pending_route<=route_mode;user_commit<=0;tx_index<=0;state<=SEND;
     end
    end
    SEND:if(core_ready)begin
     if(tx_index==7)state<=WAIT_ACK;else tx_index<=tx_index+1'b1;
    end
    WAIT_ACK:if(core_applied)begin
     if(preparing)begin
      route_mode<=CAT_OFF;state<=NEUTRAL;
     end else if(user_commit)begin
      cfg_state<=pending_base;route_mode<=pending_route;mod_state<=pending_mod;
      // A changed accepted depth reaches the registered LFO result one
      // main clock later; the correction waits for the settled result.
      offset_settle<=mod_applied_level!=0&&pending_mod[31:16]!=mod_state[31:16];
      revision<=revision+1'b1;cfg_applied<=1;writing<=0;initialized<=1;state<=IDLE;
     end
     else state<=IDLE;
    end
    NEUTRAL:if(gain==1024)begin
     tx_bank<=pending_base;preparing<=0;tx_index<=0;
     if(mod_applied_level==0||pending_mod[31:16]==0)begin
      tx_bank[64+:16]<=mapped_bend(pending_base,pending_route,offset,16'sd0);
      tx_has_mod<=0;state<=SEND;
     end else begin
      preview_offset_q<=transaction_offset(pending_mod[31:16]);
      preview_pressure<=offset;preview_route<=pending_route;state<=PREVIEW;
     end
    end
    PREVIEW:begin
     tx_bank[64+:16]<=mapped_bend(tx_bank,preview_route,preview_pressure,
                                 modulation_clear||withdraw_pending?16'sd0:preview_offset_q);
     tx_has_mod<=!modulation_clear&&!withdraw_pending&&preview_offset_q!=0;
     state<=SEND;
    end
    default:state<=ERROR;
   endcase
  end
 end
`ifndef SYNTHESIS
 initial if(CONTROL_CYCLES<1)$fatal(1,"invalid control tick");
`endif
endmodule
