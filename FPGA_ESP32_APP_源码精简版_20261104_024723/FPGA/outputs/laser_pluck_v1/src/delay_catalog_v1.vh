// Module-local, repeatable catalog: each consumer gets its own
// constant/function declarations. No storage/clock.
// N05.4b: delay and MASTER are transactional; live depth stays separate.
localparam [7:0] CAT_ATTACK=8'h00, CAT_DECAY=8'h01, CAT_SUSTAIN=8'h02,
 CAT_RELEASE=8'h03, CAT_BEND=8'h04, CAT_TIMBRE=8'h05, CAT_PLUCK=8'h06,
 CAT_FSR_ROUTE=8'h07, CAT_MOD_RATE=8'h08, CAT_MOD_DEPTH=8'h09,
 CAT_LFO_RATE=CAT_MOD_RATE, CAT_LFO_DEPTH=CAT_MOD_DEPTH,
 CAT_DELAY_ENABLE=8'h0a, CAT_DELAY_SAMPLES=8'h0b, CAT_DELAY_WET=8'h0c,
 CAT_MASTER_VOLUME=8'h0d, CAT_ABORT=8'h7e, CAT_COMMIT=8'h7f;
localparam integer CAT_FIELD_BITS=16, CAT_CORE_FIELDS=7, CAT_SYSTEM_FIELDS=14;
localparam [1:0] CAT_OFF=2'd0, CAT_VOLUME=2'd1, CAT_PITCH=2'd2;
localparam signed [15:0] CAT_BEND_MIN=-16'sd256, CAT_BEND_MAX=16'sd256;
localparam [111:0] CAT_CORE_DEFAULT={16'd0,16'd0,16'd0,16'd16,16'd36000,16'd24,16'd256};
localparam [111:0] CAT_SYSTEM_DEFAULT={16'd0,16'd0,16'd0,16'd8,16'd49152,16'd32,16'd2048};
localparam [31:0] CAT_MOD_DEFAULT={16'd64,16'd5};
// Wire fields: old core 0..6, route 7, rate 8, depth 9. UI page 8
// is MASTER, numbered separately from cfg field 8.
localparam [47:0] CAT_DELAY_DEFAULT={16'd4,16'd8192,16'd0};
localparam [223:0] CAT_UI_DEFAULT={16'd16,CAT_DELAY_DEFAULT,CAT_MOD_DEFAULT,16'd0,CAT_SYSTEM_DEFAULT};

function [5:0] cat_ui_default_index;
 input [3:0] page;
 begin case(page)
  0:cat_ui_default_index=2;1:cat_ui_default_index=5;
  2:cat_ui_default_index=12;3:cat_ui_default_index=6;
  4:cat_ui_default_index=16;8:cat_ui_default_index=16;
  9:cat_ui_default_index=4;10:cat_ui_default_index=16;
  12:cat_ui_default_index=3;13:cat_ui_default_index=4;
  default:cat_ui_default_index=0;
 endcase end
endfunction
function [5:0] cat_ui_limit;
 input [3:0] page;
 begin case(page)
  2:cat_ui_limit=16;4:cat_ui_limit=32;
  5:cat_ui_limit=3;6:cat_ui_limit=1;7:cat_ui_limit=2;
  8,10,13:cat_ui_limit=16;9,12:cat_ui_limit=7;11:cat_ui_limit=1;default:cat_ui_limit=7;
 endcase end
endfunction
function cat_ui_wrap;
 input [3:0] page;
 begin cat_ui_wrap=(page==CAT_TIMBRE||page==CAT_FSR_ROUTE);end
endfunction
function [15:0] cat_ui_value;
 input [3:0] page;input [5:0] n;
 begin case(page)
  0,1,3:case(n)
   0:cat_ui_value=0;1:cat_ui_value=8192;2:cat_ui_value=2048;3:cat_ui_value=512;
   4:cat_ui_value=128;5:cat_ui_value=32;6:cat_ui_value=8;default:cat_ui_value=2;
  endcase
  2:cat_ui_value=n==16 ? 16'hffff : {n[3:0],12'b0};
  4:cat_ui_value=($signed({1'b0,n})-16)*16;
  5,7:cat_ui_value={14'b0,n[1:0]};
  8,13:cat_ui_value={10'b0,n};
  9:cat_ui_value={10'b0,n}+16'd1;
  10:cat_ui_value={8'b0,n,2'b0};
  12:case(n)
   0:cat_ui_value=2048;1:cat_ui_value=4096;2:cat_ui_value=6144;3:cat_ui_value=8192;
   4:cat_ui_value=10240;5:cat_ui_value=12288;6:cat_ui_value=14336;default:cat_ui_value=16383;
  endcase
  default:cat_ui_value={15'b0,n[0]};
 endcase end
endfunction
// Different existing boundary policies are named individually.
// System errors latch in the owner; nonzero ABORT/COMMIT retain error=1.
function [1:0] cat_system_error;
 input [7:0] id;input [15:0] value;
 begin
  cat_system_error=0;
  if(id<=CAT_PLUCK)begin
   if(id==CAT_TIMBRE&&value>3)cat_system_error=2;
   else if(id==CAT_PLUCK&&value>1)cat_system_error=2;
   else if(id==CAT_BEND&&($signed(value)>CAT_BEND_MAX||$signed(value)<CAT_BEND_MIN))cat_system_error=2;
  end else if(id==CAT_FSR_ROUTE)begin if(value>2)cat_system_error=2;end
  else if(id==CAT_LFO_RATE)begin if(value<1||value>8)cat_system_error=2;end
  else if(id==CAT_LFO_DEPTH)begin if(value>64)cat_system_error=2;end
  else if(id==CAT_DELAY_ENABLE)begin if(value>1)cat_system_error=2;end
  else if(id==CAT_DELAY_SAMPLES)begin if(value<1||value>16383)cat_system_error=2;end
  else if(id==CAT_DELAY_WET||id==CAT_MASTER_VOLUME)begin if(value>16)cat_system_error=2;end
  else if((id==CAT_ABORT||id==CAT_COMMIT)&&value==0)cat_system_error=0;
  else cat_system_error=1;
 end
endfunction
// Core errors are one-cycle pulses; BEND clamps without raising an error.
function [1:0] cat_core_error;
 input [7:0] id;input [15:0] value;
 begin case(id)
  CAT_ATTACK,CAT_DECAY,CAT_SUSTAIN,CAT_RELEASE,CAT_BEND:cat_core_error=0;
  // Keep legacy procedural-if semantics for X/Z conditions as well as 0/1.
  // A ternary would merge 0 and 2 into x0; the if/else keeps else=2.
  CAT_TIMBRE:begin
   if(value<=3)cat_core_error=0;else cat_core_error=2;
  end
  CAT_PLUCK:begin
   if(value<=1)cat_core_error=0;else cat_core_error=2;
  end
  CAT_ABORT,CAT_COMMIT:begin
   if(value==0)cat_core_error=0;else cat_core_error=2;
  end
  default:cat_core_error=1;
 endcase end
endfunction
function signed [9:0] cat_core_bend;
 input signed [15:0] value;
 begin
  if(value>CAT_BEND_MAX)cat_core_bend=10'sd256;
  else if(value<CAT_BEND_MIN)cat_core_bend=-10'sd256;
  else cat_core_bend=value[9:0];
 end
endfunction
