// RX is already synchronized in the board top. A stable light interval is
// required after every inhibit/enable/polarity transition before a pluck.
module laser_input_v1 #(parameter integer STABLE_CYCLES=25000)(
 input wire clk,reset,enable,inhibit,blocked_high,raw_level,
 output reg level_valid,beam_blocked,armed,pluck,
 output reg [15:0] trigger_count
);
 localparam integer COUNT_WIDTH=(STABLE_CYCLES<2)?1:$clog2(STABLE_CYCLES+1);
 reg [COUNT_WIDTH-1:0] stable_count;
 reg candidate,previous_polarity;
 wire settled=(STABLE_CYCLES==1)||
              ((raw_level==candidate)&&(stable_count==STABLE_CYCLES-1));
 wire is_blocked=(raw_level==blocked_high);
 always @(posedge clk)begin
  pluck<=0;
  previous_polarity<=blocked_high;
  if(reset)begin
   stable_count<=0;candidate<=raw_level;
   level_valid<=0;beam_blocked<=0;armed<=0;trigger_count<=0;
  end else if(!enable||inhibit||(previous_polarity!=blocked_high))begin
   stable_count<=0;candidate<=raw_level;
   level_valid<=0;beam_blocked<=0;armed<=0;
  end else begin
   if(raw_level!=candidate)begin candidate<=raw_level;stable_count<=1;end
   else if(stable_count<STABLE_CYCLES)stable_count<=stable_count+1'b1;
   if(settled)begin
    level_valid<=1;beam_blocked<=is_blocked;
    if(!is_blocked)armed<=1;
    else begin
     armed<=0;
     if(armed)begin
      pluck<=1;
      if(trigger_count!=16'hffff)trigger_count<=trigger_count+1'b1;
     end
    end
   end
  end
 end
`ifndef SYNTHESIS
 initial if(STABLE_CYCLES<1)$fatal(1,"laser STABLE_CYCLES must be positive");
`endif
endmodule
