// P13 notes only: parameter ownership is exclusively p09_control.
// Stable ready/valid payload, exactly one outstanding response.
module p13_events #(
 parameter integer HOLD_FRAMES=390625, RELEASE_FRAMES=12207
)(input wire clk,reset,blocked,sample_ce,start,
 input wire [11:0] touch,input wire [31:0] allocated,
 output reg flush,output reg [2:0] state,output reg auto_mode,
 output reg event_valid,input wire event_ready,
 output reg [1:0] event_op,output reg [15:0] event_id,
 output reg [6:0] event_note,output wire [6:0] event_velocity,
 input wire result_valid,input wire [2:0] result_code,
 output reg [7:0] errors,output reg [4:0] test_index);
 // Explicit one-hot control avoids a long reset-to-binary-state feedback cone.
 // The UART interface retains the original compact 0..7 state codes.
 localparam [7:0] CONFIG=8'h01,APPLY=8'h02,PLAY=8'h04,FILL=8'h08,
                  HOLD=8'h10,RELEASE=8'h20,DRAIN=8'h40,DONE=8'h80;
 (* syn_encoding = "onehot" *) reg [7:0] phase;
 always @* begin
  case(phase)
   CONFIG:state=0;APPLY:state=1;PLAY:state=2;FILL:state=3;
   HOLD:state=4;RELEASE:state=5;DRAIN:state=6;DONE:state=7;
   default:state=0;
  endcase
 end

 reg waiting;
 reg [31:0] timer;
 reg [11:0] seen,live;
 reg [15:0] key_ids[0:11];
 reg [14:0] next_id;
 reg [3:0] pending_key;
 integer i,j,changed;
 assign event_velocity=127;
 always @* begin
  changed=-1;
  for(i=11;i>=0;i=i-1)if(touch[i]!=seen[i])changed=i;
 end
 always @(posedge clk)begin
  flush<=0;
  if(reset||blocked)begin
   phase<=PLAY;auto_mode<=0;waiting<=0;timer<=0;
   event_valid<=0;event_op<=0;event_id<=0;event_note<=0;test_index<=0;
   seen<=0;live<=0;next_id<=0;pending_key<=0;
   if(reset)errors<=0;
   for(j=0;j<12;j=j+1)key_ids[j]<=0;
  end else if(start)begin
   // A deliberate mode transition cancels both producer and allocator queues.
   flush<=1;phase<=FILL;auto_mode<=1;waiting<=0;
   event_valid<=0;test_index<=0;timer<=0;seen<=0;live<=0;
  end else begin
   if(event_valid&&event_ready)begin event_valid<=0;waiting<=1;end
   if(phase==PLAY&&!event_valid&&!waiting&&changed>=0)begin
    seen[changed]<=touch[changed];
    if(touch[changed]||live[changed])begin
     event_valid<=1;event_op<=touch[changed] ? 0 : 1;
     event_id<=touch[changed] ? {1'b0,next_id} : key_ids[changed];
     event_note<=60+changed;pending_key<=changed;
     if(touch[changed])next_id<=next_id+1'b1;
    end
   end
   if((phase==FILL||(phase==RELEASE&&timer==0))&&!event_valid&&!waiting)begin
    event_valid<=1;event_op<=phase==FILL ? 0 : 1;
    event_id<=16'h8000+test_index;event_note<=48+test_index;
   end
   if(phase==HOLD&&sample_ce)begin
    if(timer==HOLD_FRAMES-1)begin phase<=RELEASE;timer<=0;test_index<=0;end
    else timer<=timer+1'b1;
   end
   if(phase==RELEASE&&sample_ce&&timer!=0)timer<=timer-1'b1;
   if(phase==DRAIN&&allocated==0)phase<=DONE;
   // DONE keeps auto_mode=1 and ignores touch until KEY2/reset or another run.
   if(result_valid&&waiting)begin
    waiting<=0;
    if(result_code!=0)begin
     if(errors!=255)errors<=errors+1'b1;
     if(auto_mode)begin flush<=1;phase<=DONE;event_valid<=0;end
    end else if(phase==PLAY)begin
     live[pending_key]<=event_op==0;
     if(event_op==0)key_ids[pending_key]<=event_id;
    end else if(phase==FILL)begin
     if(test_index==31)begin phase<=HOLD;timer<=0;end
     else test_index<=test_index+1'b1;
    end else if(phase==RELEASE)begin
     if(test_index==31)phase<=DRAIN;
     else begin test_index<=test_index+1'b1;timer<=RELEASE_FRAMES-1;end
    end
   end
  end
 end
`ifndef SYNTHESIS
 initial if(HOLD_FRAMES<1||RELEASE_FRAMES<1)$fatal(1,"bad diagnostic duration");
`endif
endmodule
