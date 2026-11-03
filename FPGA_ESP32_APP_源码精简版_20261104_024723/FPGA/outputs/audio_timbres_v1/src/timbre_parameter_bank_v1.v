// Same P04 state machine, timing and errors; values/IDs owned by the catalog.
module timbre_parameter_bank_v1(
 input wire clk,reset,sample_ce,
 input wire cfg_valid,input wire [7:0] cfg_id,input wire [15:0] cfg_value,
 output wire cfg_ready,output reg [1:0] cfg_error,
 output reg cfg_applied,output reg [15:0] revision,
 output reg [15:0] attack_step,decay_step,sustain_level,release_step,
 output reg signed [9:0] bend,output reg [1:0] timbre,output reg pluck
);
 `include "timbre_catalog_v1.vh"
 reg [15:0] shadow_a,shadow_d,shadow_s,shadow_r;
 reg signed [9:0] shadow_bend;
 reg [1:0] shadow_timbre;reg shadow_pluck,pending;
 assign cfg_ready=!reset && !pending;
 always @(posedge clk) begin
  if(reset) begin
   attack_step<=CAT_CORE_DEFAULT[0+:16];decay_step<=CAT_CORE_DEFAULT[16+:16];
   sustain_level<=CAT_CORE_DEFAULT[32+:16];release_step<=CAT_CORE_DEFAULT[48+:16];
   bend<=CAT_CORE_DEFAULT[64+:10];timbre<=CAT_CORE_DEFAULT[80+:2];pluck<=CAT_CORE_DEFAULT[96];revision<=0;
   shadow_a<=CAT_CORE_DEFAULT[0+:16];shadow_d<=CAT_CORE_DEFAULT[16+:16];
   shadow_s<=CAT_CORE_DEFAULT[32+:16];shadow_r<=CAT_CORE_DEFAULT[48+:16];
   shadow_bend<=CAT_CORE_DEFAULT[64+:10];shadow_timbre<=CAT_CORE_DEFAULT[80+:2];shadow_pluck<=CAT_CORE_DEFAULT[96];
   pending<=0;cfg_error<=0;cfg_applied<=0;
  end else begin
   cfg_error<=0;cfg_applied<=0;
   // Acceptance on sample_ce still publishes at the NEXT sample boundary.
   if(sample_ce && pending) begin
    attack_step<=shadow_a;decay_step<=shadow_d;sustain_level<=shadow_s;
    release_step<=shadow_r;bend<=shadow_bend;
    timbre<=shadow_timbre;pluck<=shadow_pluck;
    pending<=0;cfg_applied<=1;revision<=revision+16'd1;
   end
   if(cfg_valid && cfg_ready) begin
    case(cfg_id)
     CAT_ATTACK: shadow_a<=cfg_value;
     CAT_DECAY: shadow_d<=cfg_value;
     CAT_SUSTAIN: shadow_s<=cfg_value;
     CAT_RELEASE: shadow_r<=cfg_value;
     CAT_BEND: shadow_bend<=cat_core_bend($signed(cfg_value));
     CAT_TIMBRE: if(cat_core_error(cfg_id,cfg_value)==0)shadow_timbre<=cfg_value[1:0];
                 else cfg_error<=cat_core_error(cfg_id,cfg_value);
     CAT_PLUCK: if(cat_core_error(cfg_id,cfg_value)==0)shadow_pluck<=cfg_value[0];
                else cfg_error<=cat_core_error(cfg_id,cfg_value);
     CAT_ABORT: if(cfg_value==0)begin
      shadow_a<=attack_step;shadow_d<=decay_step;shadow_s<=sustain_level;
      shadow_r<=release_step;shadow_bend<=bend;
      shadow_timbre<=timbre;shadow_pluck<=pluck;
     end else cfg_error<=cat_core_error(cfg_id,cfg_value);
     CAT_COMMIT: if(cfg_value==0)pending<=1;else cfg_error<=cat_core_error(cfg_id,cfg_value);
     default: cfg_error<=cat_core_error(cfg_id,cfg_value);
    endcase
   end
  end
 end
endmodule
