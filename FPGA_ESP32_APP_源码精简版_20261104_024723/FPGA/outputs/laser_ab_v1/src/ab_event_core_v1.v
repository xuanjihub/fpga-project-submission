// Event-facing wrapper with a separate sample-boundary timbre override.
module ab_event_core_v1 #(parameter integer VOICES=32)(
 input wire clk,reset,panic,sample_ce,force_pluck,
 input wire timbre_override_enable,input wire [1:0] timbre_override,
 input wire event_valid,output wire event_ready,
 input wire [1:0] event_op,input wire [15:0] event_id,
 input wire [6:0] event_note,event_velocity,
 output wire result_valid,output wire [2:0] result_code,
 output wire [15:0] result_id,output wire [4:0] result_slot,
 input wire [11:0] expression_gain,input wire expression_valid,
 input wire cfg_valid,input wire [7:0] cfg_id,input wire [15:0] cfg_value,
 output wire cfg_ready,output wire [1:0] cfg_error,output wire cfg_applied,
 output wire [15:0] cfg_revision,output wire [111:0] cfg_state,
 output wire [VOICES-1:0] allocated,voice_gate,active,voice_modes,
 output wire [VOICES*2-1:0] voice_timbres,
 output wire [VOICES*7-1:0] voice_note,voice_velocity,
 output wire [VOICES*16-1:0] slot_ids,
 output wire [15:0] full_count,duplicate_count,unknown_off_count,bad_op_count,
 output wire signed [15:0] sample,output wire sample_valid
);
 p06_allocator #(.VOICES(VOICES)) allocator(
  .clk(clk),.reset(reset),.panic(panic),.sample_ce(sample_ce),
  .sample_done(sample_valid),.core_active(active),
  .event_valid(event_valid),.event_ready(event_ready),.event_op(event_op),
  .event_id(event_id),.event_note(event_note),.event_velocity(event_velocity),
  .result_valid(result_valid),.result_code(result_code),.result_id(result_id),
  .result_slot(result_slot),.allocated(allocated),.voice_gate(voice_gate),
  .voice_note(voice_note),.voice_velocity(voice_velocity),.slot_ids(slot_ids),
  .full_count(full_count),.duplicate_count(duplicate_count),
  .unknown_off_count(unknown_off_count),.bad_op_count(bad_op_count));
 ab_voice_core_v1 #(.VOICES(VOICES)) core(
  .clk(clk),.reset(reset),.panic(panic),.sample_ce(sample_ce),.force_pluck(force_pluck),
  .timbre_override_enable(timbre_override_enable),.timbre_override(timbre_override),
  .voice_gate(voice_gate),.voice_note(voice_note),.voice_velocity(voice_velocity),
  .expression_gain(expression_gain),.expression_valid(expression_valid),
  .cfg_valid(cfg_valid),.cfg_id(cfg_id),.cfg_value(cfg_value),
  .cfg_ready(cfg_ready),.cfg_error(cfg_error),.cfg_applied(cfg_applied),
  .cfg_revision(cfg_revision),.cfg_state(cfg_state),.active(active),
  .voice_timbres(voice_timbres),.voice_modes(voice_modes),
  .sample(sample),.sample_valid(sample_valid));
endmodule
