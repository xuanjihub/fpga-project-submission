// Capture the pre-ramp MASTER at the original request; data arrives in-frame.
// The parent must finish each stream transaction before the next sample_ce.
// MASTER scales both dry and wet; zero volume leaves history advancing.
module delay_master_v1(
 input wire clk,reset,clear,sample_ce,
 input wire [4:0] master_volume,
 input wire in_valid,input wire signed [15:0] in_sample,
 output reg out_valid,output wire signed [15:0] out_sample,
 output wire [7:0] frame_gain,output wire [7:0] smooth_level
);
 reg [7:0] ramp,captured;
 wire [7:0] target=master_volume<=16 ? {master_volume,3'b0} : 8'd0;
 assign frame_gain=captured;
 assign smooth_level=ramp;
 always @(posedge clk) begin
  if(reset)begin ramp<=128;captured<=128;end
  else if(sample_ce)begin
   captured<=ramp;
   if(ramp<target)ramp<=ramp+1'b1;
   else if(ramp>target)ramp<=ramp-1'b1;
  end
 end
 // signed16 * positive signed9 retains the full 25-bit product.
 reg signed [24:0] product;
 wire signed [24:0] quantized=product>>>7;
 assign out_sample=quantized>25'sd32767 ? 16'sh7fff :
                   quantized< -25'sd32768 ? 16'sh8000 : quantized[15:0];
 always @(posedge clk)begin
  if(reset||clear)begin product<=0;out_valid<=0;end
  else begin
   out_valid<=in_valid;
   if(in_valid)product<=in_sample*$signed({1'b0,captured});
  end
 end
endmodule
