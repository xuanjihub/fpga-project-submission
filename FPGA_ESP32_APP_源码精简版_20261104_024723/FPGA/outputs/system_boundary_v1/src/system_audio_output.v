// Signed16 sample boundary; clocks remain alive through instrument soft reset.
// This is the exact storage formerly inside system_param_audio.
module system_audio_output #(
 parameter integer BCLK_HALF_PERIOD=8
)(input wire clk,power_reset,clear,sample_valid,
 input wire signed [15:0] source_sample,
 output reg signed [15:0] held_sample,
 output wire sample_ce,bclk,lrck,dout);
 always @(posedge clk)begin
  if(clear)held_sample<=0;else if(sample_valid)held_sample<=source_sample;
 end
 // NBA producers on sample_ce still feed the NEXT frame; route through this storage.
 i2s_tx #(.BCLK_HALF_PERIOD(BCLK_HALF_PERIOD)) pcm(.clk(clk),.reset(power_reset),
  .sample_left(held_sample),.sample_right(held_sample),.mute(clear),
  .sample_ce(sample_ce),.bclk(bclk),.lrck(lrck),.dout(dout));
endmodule
