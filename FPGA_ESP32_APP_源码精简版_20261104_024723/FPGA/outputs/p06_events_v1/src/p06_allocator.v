// One-entry event queue; sample-boundary allocation preserves held/tail voices.
// Supports VOICES=4 or 32, one clk domain.
module p06_allocator #(parameter integer VOICES=32)(
 input wire clk,reset,panic,sample_ce,sample_done,
 input wire [VOICES-1:0] core_active,
 input wire event_valid,output wire event_ready,
 input wire [1:0] event_op,input wire [15:0] event_id,
 input wire [6:0] event_note,event_velocity,
 output reg result_valid,output reg [2:0] result_code,
 output reg [15:0] result_id,output reg [4:0] result_slot,
 output reg [VOICES-1:0] allocated,voice_gate,
 output reg [VOICES*7-1:0] voice_note,voice_velocity,
 output reg [VOICES*16-1:0] slot_ids,
 output reg [15:0] full_count,duplicate_count,unknown_off_count,bad_op_count
);
 reg pending;
 reg [1:0] pending_op;
 reg [15:0] pending_id;
 reg [6:0] pending_note,pending_velocity;
 reg frame_pending;
 reg [VOICES-1:0] sampled_allocated,sampled_gate;
 reg found_id,found_free;
 reg [4:0] id_slot,free_slot;
 integer scan,slot;
 assign event_ready=!(reset||panic||pending);
 function [15:0] increment(input [15:0] count);
  increment=(count==16'hffff) ? count : count+16'd1;
 endfunction
 always @* begin
  found_id=0;found_free=0;id_slot=0;free_slot=0;
  for(scan=0;scan<VOICES;scan=scan+1)begin
   if(!found_id && allocated[scan] && slot_ids[scan*16+:16]==pending_id)begin
    found_id=1;id_slot=scan;
   end
   if(!found_free && !allocated[scan])begin found_free=1;free_slot=scan;end
  end
 end
 always @(posedge clk)begin
  if(reset||panic)begin
   pending<=0;pending_op<=0;pending_id<=0;pending_note<=0;pending_velocity<=0;
   frame_pending<=0;sampled_allocated<=0;sampled_gate<=0;
   allocated<=0;voice_gate<=0;voice_note<=0;voice_velocity<=0;slot_ids<=0;
   result_valid<=0;result_code<=0;result_id<=0;result_slot<=0;
   if(reset)begin full_count<=0;duplicate_count<=0;unknown_off_count<=0;bad_op_count<=0;end
  end else begin
   result_valid<=0;
   if(event_valid && event_ready)begin
    pending<=1;pending_op<=event_op;pending_id<=event_id;
    pending_note<=event_note;pending_velocity<=event_velocity;
   end
   // A complete low-gate render must precede reclamation. Active=0 alone
   // is insufficient: the first attack sample and held plucks can be silent.
   if(sample_done && frame_pending)begin
    frame_pending<=0;
    for(slot=0;slot<VOICES;slot=slot+1)begin
     if(allocated[slot] && sampled_allocated[slot] &&
        !sampled_gate[slot] && !voice_gate[slot] && !core_active[slot])
      allocated[slot]<=0;
    end
   end
   if(sample_ce)begin
    sampled_allocated<=allocated;sampled_gate<=voice_gate;frame_pending<=1;
    if(pending)begin
     pending<=0;result_valid<=1;result_id<=pending_id;
     result_code<=0;result_slot<=0;
     case(pending_op)
      0:begin
       if(found_id)begin result_code<=2;duplicate_count<=increment(duplicate_count);end
       else if(!found_free)begin result_code<=1;full_count<=increment(full_count);end
       else begin
        allocated[free_slot]<=1;voice_gate[free_slot]<=1;
        voice_note[free_slot*7+:7]<=pending_note;
        voice_velocity[free_slot*7+:7]<=pending_velocity;
        slot_ids[free_slot*16+:16]<=pending_id;result_slot<=free_slot;
       end
      end
      1:begin
       if(found_id)begin voice_gate[id_slot]<=0;result_slot<=id_slot;end
       else begin result_code<=3;unknown_off_count<=increment(unknown_off_count);end
      end
      default:begin result_code<=4;bad_op_count<=increment(bad_op_count);end
     endcase
    end
   end
  end
 end
endmodule
