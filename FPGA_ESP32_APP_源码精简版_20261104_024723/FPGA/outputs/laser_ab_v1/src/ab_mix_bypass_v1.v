// Sample-boundary 32-step crossfade between aligned dry and effected samples.
// This combinational stream stage has zero added latency. The owning audio pipeline
// must align dry_sample with wet_sample and retain the delay engine while
// mix_level is nonzero. clear cancels output and restarts at exact dry.
module ab_mix_bypass_v1(
 input wire clk,reset,clear,sample_ce,
 input wire in_valid,
 input wire signed [15:0] dry_sample,wet_sample,
 input wire mix_enabled,
 output wire out_valid,
 output wire signed [15:0] out_sample,
 output reg [5:0] mix_level
);
 wire [5:0] dry_weight=6'd32-mix_level;
 wire signed [22:0] dry_product=$signed(dry_sample)*$signed({1'b0,dry_weight});
 wire signed [22:0] wet_product=$signed(wet_sample)*$signed({1'b0,mix_level});
 wire signed [23:0] weighted_sum=$signed({dry_product[22],dry_product})+
                                $signed({wet_product[22],wet_product});
 wire signed [23:0] scaled_sample=weighted_sum >>> 5;
 assign out_valid=in_valid && !reset && !clear;
 assign out_sample=out_valid ? scaled_sample[15:0] : 16'sd0;
 always @(posedge clk)begin
  if(reset || clear)mix_level<=0;
  else if(sample_ce)begin
   if(mix_enabled && mix_level<6'd32)mix_level<=mix_level+1'b1;
   else if(!mix_enabled && mix_level!=0)mix_level<=mix_level-1'b1;
  end
 end
endmodule
