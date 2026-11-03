`timescale 1ns/1ps
// Four EC11 S1/S2 pairs and eight independent active-low keys, all on clk.
// encoder_ab[i*2+:2] is {S2,S1}; "up" is 11->01->00->10->11,
// a Gray-coded direction for this decoder.
// A pair is qualified jointly. Four signed legal transitions make a detent;
// a qualified diagonal jump clears that lane's partial detent and is counted.
// Every lane may pulse on the same clock.
// key_held is zero during reset/startup, then the qualified active-low state.
// A boot-held key pulses and arms on its later qualified release.
// invalid_counts[i*8+:8] is that encoder's saturating diagnostic count.
module panel_inputs_v2 #(
 parameter integer AB_CYCLES=5000, BUTTON_CYCLES=250000
)(
 input wire clk, reset,
 input wire [7:0] encoder_ab,
 input wire [7:0] keys_n,
 output reg [3:0] encoder_up, encoder_down,
 output reg [7:0] key_press, key_release, key_held,
 output reg [31:0] invalid_counts
);
 localparam integer AW=AB_CYCLES<2?1:$clog2(AB_CYCLES);
 localparam integer BW=BUTTON_CYCLES<2?1:$clog2(BUTTON_CYCLES);
 (* syn_keep=1 *) reg [15:0] input_meta, input_sync;
 reg [1:0] sync_ready;
 reg [1:0] ab_candidate[0:3], ab_previous[0:3];
 reg [AW-1:0] ab_count[0:3];
 reg signed [3:0] ab_progress[0:3];
 reg [3:0] ab_initialized;
 reg [7:0] key_candidate, key_initialized, key_armed;
 reg [BW-1:0] key_count[0:7];
 integer i;

 function signed [3:0] gray_delta;
  input [1:0] previous, candidate;
  begin
   case({previous,candidate})
    4'b1101,4'b0100,4'b0010,4'b1011: gray_delta=4'sd1;
    4'b1110,4'b1000,4'b0001,4'b0111: gray_delta=-4'sd1;
    default: gray_delta=4'sd0;
   endcase
  end
 endfunction

 always @(posedge clk) begin
  if(reset) begin
   input_meta<=16'hffff;
   input_sync<=16'hffff;
   sync_ready<=2'b00;
  end else begin
   input_meta<={keys_n,encoder_ab};
   input_sync<=input_meta;
   sync_ready<={sync_ready[0],1'b1};
  end
 end

 always @(posedge clk) begin
  encoder_up<=4'b0;
  encoder_down<=4'b0;
  key_press<=8'b0;
  key_release<=8'b0;
  if(reset) begin
   invalid_counts<=32'b0;
   ab_initialized<=4'b0;
   key_held<=8'b0;
   key_candidate<=8'hff;
   key_initialized<=8'b0;
   key_armed<=8'b0;
   for(i=0;i<4;i=i+1) begin
    ab_candidate[i]<=2'b11;
    ab_previous[i]<=2'b11;
    ab_count[i]<=0;
    ab_progress[i]<=0;
   end
   for(i=0;i<8;i=i+1) key_count[i]<=0;
  end else if(sync_ready[1]) begin
   // Startup waits for both synchronizer stages; AB_CYCLES=1 and
   // BUTTON_CYCLES=1 still require a post-reset qualified level.
   for(i=0;i<4;i=i+1) begin
    if(input_sync[i*2+:2]!=ab_candidate[i]) begin
     ab_candidate[i]<=input_sync[i*2+:2];
     ab_count[i]<=0;
    end else if(ab_count[i]==AB_CYCLES-1) begin
     if(!ab_initialized[i]) begin
      ab_previous[i]<=ab_candidate[i];
      ab_initialized[i]<=1'b1;
      ab_progress[i]<=0;
     end else if(ab_candidate[i]!=ab_previous[i]) begin
      ab_previous[i]<=ab_candidate[i];
      case(gray_delta(ab_previous[i],ab_candidate[i]))
       4'sd1: begin
        if(ab_progress[i]==4'sd3) begin
         ab_progress[i]<=0;
         encoder_up[i]<=1'b1;
        end else ab_progress[i]<=ab_progress[i]+4'sd1;
       end
       -4'sd1: begin
        if(ab_progress[i]==-4'sd3) begin
         ab_progress[i]<=0;
         encoder_down[i]<=1'b1;
        end else ab_progress[i]<=ab_progress[i]-4'sd1;
       end
       default: begin
        ab_progress[i]<=0;
        if(invalid_counts[i*8+:8]!=8'hff)
         invalid_counts[i*8+:8]<=invalid_counts[i*8+:8]+1'b1;
       end
      endcase
     end
    end else ab_count[i]<=ab_count[i]+1'b1;
   end
   for(i=0;i<8;i=i+1) begin
    if(input_sync[i+8]!=key_candidate[i]) begin
     key_candidate[i]<=input_sync[i+8];
     key_count[i]<=0;
    end else if(key_count[i]==BUTTON_CYCLES-1) begin
     // First qualified level records held state.
     // A qualified release arms only that key for its next qualified press.
     key_initialized[i]<=1'b1;
     if(key_candidate[i]) key_armed[i]<=1'b1;
     if(key_held[i]!=~key_candidate[i]) begin
      key_held[i]<=~key_candidate[i];
      if(key_candidate[i]) begin
       if(key_initialized[i]) key_release[i]<=1'b1;
      end else begin
       if(key_initialized[i] && key_armed[i]) key_press[i]<=1'b1;
       key_armed[i]<=1'b0;
      end
     end
    end else key_count[i]<=key_count[i]+1'b1;
   end
  end
 end
`ifndef SYNTHESIS
 initial if(AB_CYCLES<1 || BUTTON_CYCLES<1)
  $fatal(1,"panel_inputs_v2 filter cycles must be positive");
`endif
endmodule
