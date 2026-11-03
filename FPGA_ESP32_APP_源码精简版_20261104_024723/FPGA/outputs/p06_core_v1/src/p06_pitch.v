// P06-only, bit-exact replacement for s12_pitch. Three-clock pipeline.
// Precompute clamp/interpolation at elaboration; the bend -> ratio path is
// a pure lookup. The ROM holds frequency ratios.
module p06_pitch(
 input wire clk,reset,
 input wire [31:0] base_step,
 input wire signed [9:0] bend,
 output reg [31:0] step
);
 function [20:0] ratio_point;
  input integer index;
  begin
   case(index)
    0: ratio_point=21'd934175;
    1: ratio_point=21'd940944;
    2: ratio_point=21'd947763;
    3: ratio_point=21'd954631;
    4: ratio_point=21'd961548;
    5: ratio_point=21'd968516;
    6: ratio_point=21'd975534;
    7: ratio_point=21'd982604;
    8: ratio_point=21'd989724;
    9: ratio_point=21'd996896;
    10: ratio_point=21'd1004120;
    11: ratio_point=21'd1011396;
    12: ratio_point=21'd1018725;
    13: ratio_point=21'd1026107;
    14: ratio_point=21'd1033543;
    15: ratio_point=21'd1041032;
    16: ratio_point=21'd1048576;
    17: ratio_point=21'd1056174;
    18: ratio_point=21'd1063828;
    19: ratio_point=21'd1071537;
    20: ratio_point=21'd1079302;
    21: ratio_point=21'd1087123;
    22: ratio_point=21'd1095000;
    23: ratio_point=21'd1102935;
    24: ratio_point=21'd1110928;
    25: ratio_point=21'd1118978;
    26: ratio_point=21'd1127086;
    27: ratio_point=21'd1135254;
    28: ratio_point=21'd1143480;
    29: ratio_point=21'd1151766;
    30: ratio_point=21'd1160113;
    31: ratio_point=21'd1168519;
    32: ratio_point=21'd1176987;
    default: ratio_point=21'd1176987;
   endcase
  end
 endfunction
 function [20:0] encoded_ratio;
  input integer encoding;
  integer limited,position,index,lower,upper;
  begin
   limited=(encoding<512) ? encoding : encoding-1024;
   if(limited>256)limited=256;
   if(limited< -256)limited=-256;
   position=limited+256;
   index=position/16;
   lower=ratio_point(index);
   upper=ratio_point(index==32 ? 32 : index+1);
   encoded_ratio=lower+((upper-lower)*(position%16)+8)/16;
  end
 endfunction
 reg [20:0] ratios[0:1023];
 integer i;
 initial for(i=0;i<1024;i=i+1)ratios[i]=encoded_ratio(i);
 reg [20:0] ratio;
 reg [31:0] base_delayed;
 reg [52:0] product;
 wire [53:0] rounded={1'b0,product}+54'd524288;
 always @(posedge clk)begin
  if(reset)begin ratio<=21'd1048576;base_delayed<=0;product<=0;step<=0;end
  else begin
   ratio<=ratios[$unsigned(bend)];
   base_delayed<=base_step;
   product<=base_delayed*ratio;
   step<=|rounded[53:52] ? 32'hffffffff : rounded[51:20];
  end
 end
endmodule
