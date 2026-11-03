// BLE-compatible control implementation.
// Derived from audio_modulation_v1: raw LFO readout and late clear selection
// preserve same-cycle reset/cancel, arithmetic, publication and audio latency.
// Shared 1 kHz-enabled triangle on the main clock domain.
// Frequency table is round(2^32 * rate_hz / 1000), one increment per tick.
// Q64 triangle * depth[0..64] * live[0..16] / 1024; ties round away from 0.
module modulation_lfo_v1(
 input wire clk,reset,clear,control_ce,
 input wire [15:0] rate_hz,depth,
 input wire [4:0] live_level,
 output wire signed [15:0] offset,
 output wire signed [15:0] raw_offset,
 output reg [4:0] applied_level,
 output reg [31:0] phase
);
 function [31:0] phase_increment;
  input [15:0] rate;
  begin case(rate)
   1:phase_increment=32'd4294967;2:phase_increment=32'd8589935;
   3:phase_increment=32'd12884902;4:phase_increment=32'd17179869;
   5:phase_increment=32'd21474836;6:phase_increment=32'd25769804;
   7:phase_increment=32'd30064771;8:phase_increment=32'd34359738;
   default:phase_increment=0;
  endcase end
 endfunction
 wire [7:0] position=phase[31:24];
 wire signed [9:0] triangle=position<64 ? $signed({2'b0,position}) :
  position<192 ? 10'sd128-$signed({2'b0,position}) : $signed({2'b0,position})-10'sd256;
 wire signed [17:0] depth_product=triangle*$signed({1'b0,depth[6:0]});
 wire signed [23:0] product=depth_product*$signed({1'b0,applied_level});
 wire [23:0] magnitude=product<0 ? -product : product;
 wire [23:0] rounded=(magnitude+24'd512)>>10;
 // Control-only register breaks the two multipliers away from the route's
 // sum/clamp/transaction comparison. Audio samples and I2S latency are unchanged.
 // phase/applied_level lead this result by one main-clock edge.
 reg signed [15:0] offset_q;
 assign raw_offset=offset_q;
 assign offset=(reset||clear) ? 16'sd0 : offset_q;
 always @(posedge clk)begin
  if(reset||clear)begin applied_level<=0;phase<=0;offset_q<=0;end
  else begin
   offset_q<=product<0 ? -$signed(rounded[15:0]) : $signed(rounded[15:0]);
   if(control_ce)begin
   if(live_level>applied_level)applied_level<=applied_level+5'd1;
   else if(live_level<applied_level)applied_level<=applied_level-5'd1;
   if(depth==0||(live_level==0&&applied_level==0))phase<=0;
    else phase<=phase+phase_increment(rate_hz);
   end
  end
 end
`ifndef SYNTHESIS
 always @(posedge clk)if(!reset&&!clear&&control_ce)begin
  if(rate_hz<1||rate_hz>8||depth>64||live_level>16)$fatal(1,"modulation LFO input outside contract");
 end
`endif
endmodule
