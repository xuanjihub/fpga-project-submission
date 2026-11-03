`timescale 1ns/1ps
// S10: continuous fourth-power expression curve, then audio-rate slew.
// Raw 32..25600 is normalized to 0..4095. Two registered Q12 squares
// reduce early loudness without imposing a large raw-input dead zone.
// Relative expression only. Full scale stays exact.
module s12_pressure_gain #(parameter integer CLK_HZ=50000000,
 parameter integer STALE_CYCLES=CLK_HZ/50)(
 input wire clk,reset,sample_ce,adc_strobe,adc_valid,
 input wire signed [15:0] adc_raw,audio_in,
 output wire signed [15:0] audio_out,
 output wire [11:0] level,
 output reg [11:0] gain,
 output wire valid,pressed);
 wire updated,config_error;wire[31:0]age;
 fsr_pressure_channel #(.CLK_HZ(CLK_HZ),.STALE_CYCLES(STALE_CYCLES),
 .RAW_ZERO(32),.RAW_FULL(25600),.SMOOTH_SHIFT(0),
 .PRESS_ON(128),.PRESS_OFF(64)) normalize(
 .clk(clk),.reset(reset),.sample_strobe(adc_strobe),
 .sample_valid(adc_valid),.calibration_valid(1'b1),.sample_raw(adc_raw),
 .level(level),.level_valid(valid),.pressed(pressed),.updated(updated),
 .age_cycles(age),.config_error(config_error));
 wire [23:0] square_product=level*level;
 reg [11:0] square_q,curve_target;
 reg full_q;
 reg [1:0] curve_valid;
 wire [23:0] fourth_product=square_q*square_q;
 // Two extra clocks (40ns at 50MHz). Flush both stages on every fault,
 // including when sample_ce is high, so recovery starts from a clean gain.
 always @(posedge clk) begin
  if(reset || !adc_valid || !valid) begin
   square_q<=0;curve_target<=0;full_q<=0;curve_valid<=0;
  end else begin
   square_q<=square_product[23:12];
   full_q<=(level==12'd4095);
   curve_target<=full_q ? 12'd4095 : fourth_product[23:12];
   curve_valid<={curve_valid[0],1'b1};
  end
 end
 // Unpressed FSR means silence. An A1 fault blocks note events.
 // Future UI/BLE calibration would enter upstream of normalize.
 always @(posedge clk) begin
  if(reset || !adc_valid || !valid || !curve_valid[1]) gain<=0;
  else if(sample_ce) begin
   if(curve_target>gain) begin
    if(({1'b0,curve_target}-{1'b0,gain})>13'd32) gain<=gain+12'd32;
    else gain<=curve_target;
   end else begin
    if(({1'b0,gain}-{1'b0,curve_target})>13'd32) gain<=gain-12'd32;
    else gain<=curve_target;
   end
  end
 end
 reg signed [28:0] product;
 always @(posedge clk) begin
  if(reset || !adc_valid || !valid) product<=0;
  else product<=audio_in*$signed({1'b0,gain});
 end
 assign audio_out=product >>> 12;
endmodule
