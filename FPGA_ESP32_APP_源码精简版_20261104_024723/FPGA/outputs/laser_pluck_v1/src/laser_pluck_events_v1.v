// One snapshotted chord, one request/result outstanding. Every successful
// NoteOn is followed by NoteOff of the same instance; PLUCK decays naturally.
// blocked must be asserted together with allocator panic on mode/safety clear.
module laser_pluck_events_v1 #(
 parameter integer SHARED_MIDI_IDS=0
)(
 input wire clk,reset,blocked,pluck,
 input wire [11:0] touch,input wire [31:0] allocated,
 input wire [511:0] slot_ids,
 output reg event_valid,input wire event_ready,
 output reg [1:0] event_op,output reg [15:0] event_id,
 output reg [6:0] event_note,event_velocity,
 input wire result_valid,input wire [2:0] result_code,
 input wire [15:0] result_id,
 output wire busy,output reg [7:0] errors,
 output reg [15:0] dropped,trigger_count
);
 localparam [2:0] IDLE=0,SELECT_NOTE=1,SCAN_ID=2,OFFER_ON=3,
                  WAIT_ON=4,OFFER_OFF=5,WAIT_OFF=6;
 reg [2:0] phase;
 reg [11:0] pending_notes;
 reg [15:0] next_id,candidate_id;
 // Shared MIDI owns A000..BFFF. Keep laser IDs in C000..FFFF after wrap.
 wire [15:0] successor=SHARED_MIDI_IDS ?
                     {2'b11,candidate_id[13:0]+14'd1} : candidate_id+16'd1;
 reg [4:0] scan_slot;
 reg [3:0] selected_note;
 integer i,first_note;
 assign busy=(phase!=IDLE);
 always @*begin
  first_note=-1;
  for(i=11;i>=0;i=i-1)if(pending_notes[i])first_note=i;
 end
 always @(posedge clk)begin
  if(reset||blocked)begin
   phase<=IDLE;pending_notes<=0;candidate_id<=0;scan_slot<=0;selected_note<=0;
   event_valid<=0;event_op<=0;event_id<=0;event_note<=0;event_velocity<=127;
   // Preserve the cursor across panic: retained counters aid diagnostics.
   if(reset)begin next_id<=16'hc000;errors<=0;dropped<=0;trigger_count<=0;end
  end else begin
   if(pluck&&busy&&dropped!=16'hffff)dropped<=dropped+1'b1;
   case(phase)
    IDLE:if(pluck&&touch!=0)begin
     pending_notes<=touch;phase<=SELECT_NOTE;
     if(trigger_count!=16'hffff)trigger_count<=trigger_count+1'b1;
    end
    SELECT_NOTE:begin
     if(first_note<0)phase<=IDLE;
     else begin
      selected_note<=first_note;
      pending_notes[first_note]<=0;
      candidate_id<=next_id;scan_slot<=0;phase<=SCAN_ID;
     end
    end
    SCAN_ID:begin
     // Serial slot search bounds the comparator fan-in. At most 32 resident
     // IDs can conflict, including low-gate release tails and ID wraparound.
     if(allocated[scan_slot]&&slot_ids[scan_slot*16+:16]==candidate_id)begin
      candidate_id<=successor;scan_slot<=0;
     end else if(scan_slot==31)begin
      event_valid<=1;event_op<=0;event_id<=candidate_id;
      event_note<=7'd60+selected_note;event_velocity<=127;
      next_id<=successor;phase<=OFFER_ON;
     end else scan_slot<=scan_slot+1'b1;
    end
    OFFER_ON:if(event_valid&&event_ready)begin event_valid<=0;phase<=WAIT_ON;end
    WAIT_ON:if(result_valid)begin
     if(result_id!=event_id)begin
      if(errors!=255)errors<=errors+1'b1;
     end else if(result_code!=0)begin
      if(errors!=255)errors<=errors+1'b1;
      phase<=SELECT_NOTE;
     end else begin event_valid<=1;event_op<=1;phase<=OFFER_OFF;end
    end
    OFFER_OFF:if(event_valid&&event_ready)begin event_valid<=0;phase<=WAIT_OFF;end
    WAIT_OFF:if(result_valid)begin
     if(result_id!=event_id)begin
      if(errors!=255)errors<=errors+1'b1;
     end else begin
      if(result_code!=0&&errors!=255)errors<=errors+1'b1;
      phase<=SELECT_NOTE;
     end
    end
    default:begin event_valid<=0;pending_notes<=0;phase<=IDLE;end
   endcase
  end
 end
endmodule
