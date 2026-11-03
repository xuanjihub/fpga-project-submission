// N06 single-beam fixed-velocity PLUCK derivative built on the frozen owners.
// Preserve the independent, sample-paced master coefficient
// after the dry+wet mix. Fixed 2x trim follows MASTER without another stage.
// Preserve sensor validation, routing, allocation, panic, sample storage/I2S.
module ab_board_audio_v1 #(
 parameter integer CLK_HZ=50000000,BCLK_HALF_PERIOD=8,
 parameter integer HOLD_FRAMES=CLK_HZ/128,RELEASE_FRAMES=CLK_HZ/4096,
 parameter integer LASER_STABLE_CYCLES=25000,
 parameter integer MIDI_ENABLE=0
)(input wire clk,reset,power_reset,input wire [2:0] key_pressed,
 input wire configured,cfg_valid,input wire [7:0] cfg_id,input wire [15:0] cfg_value,
 input wire [4:0] mod_level,input wire external_cancel,
 input wire [1:0] laser_mode,input wire laser_raw,
 input wire [1:0] laser_function,timbre_a,timbre_b,input wire mix_enabled,
 output wire [5:0] mix_level,
 output wire laser_level_valid,laser_blocked,laser_ready,laser_event,laser_busy,
 output wire [15:0] laser_triggers,laser_dropped,
 output wire [47:0] delay_state,actual_delay_state,output wire [4:0] master_volume, output wire [7:0] master_smooth_level,output wire cfg_cancelled,
 output wire cfg_ready,cfg_applied,output wire [1:0] cfg_error,
 output wire [111:0] cfg_state,output wire [15:0] cfg_revision,
 output wire [31:0] mod_state,output wire signed [15:0] mod_offset,
 output wire [4:0] mod_applied_level,
 output wire [1:0] route_mode,output wire signed [15:0] effective_bend,
 input wire [111:0] touch_input,pressure_input,
 input wire midi_event_valid,output wire midi_event_ready,
 input wire [1:0] midi_event_op,input wire [15:0] midi_event_id,
 input wire [6:0] midi_event_note,midi_event_velocity,
 output wire midi_result_valid,output wire [2:0] midi_result_code,
 output wire [15:0] midi_result_id,
 output wire sample_ce,output wire [11:0] gain,
 output reg armed,output wire healthy,mute,auto_mode,output wire [2:0] state,
 output wire [31:0] allocated,gate,active,output wire [4:0] test_index,
 output wire [511:0] slot_ids,
 output wire [7:0] errors,output reg [15:0] responses,
 output reg [2:0] last_result,output wire [15:0] fulls,duplicates,unknowns,bads,
 output wire signed [15:0] sample,output wire bclk,lrck,dout);
 wire sv;
 wire touch_header_ok=touch_input[3:0]==1&&touch_input[11:4]==1&&touch_input[15:12]==1&&
  touch_input[31:24]==0&&touch_input[23:19]==0&&touch_input[95:92]==0&&touch_input[111:96]==0;
 wire pressure_header_ok=pressure_input[3:0]==1&&pressure_input[11:4]==2&&pressure_input[15:12]==2&&
  pressure_input[31:24]==0&&pressure_input[23:20]==0&&pressure_input[95:92]==0&&pressure_input[111:108]==0;
 wire [11:0] touch=touch_input[91:80];
 wire [11:0] pressure_level=pressure_input[91:80],pressure_gain=pressure_input[107:96];
 wire pressure_valid=pressure_header_ok&&pressure_input[16]&&!pressure_input[17]&&!pressure_input[18];
 assign healthy=touch_header_ok&&touch_input[16]&&!touch_input[17]&&!touch_input[18];
 wire mod_ready;
 wire actual_delay_enabled,runtime_clear;
 wire [13:0] actual_delay_samples;
 wire [4:0] actual_wet,master_target;
 assign actual_delay_state={{11'd0,actual_wet},{2'd0,actual_delay_samples},15'd0,actual_delay_enabled};
 // Mode changes clear both producer histories and all old voice ownership.
 // The filter stays independent of audio armed, so rearming stays possible.
 wire laser_enabled=(laser_mode!=0);
 wire laser_pluck_enabled=laser_enabled&&(laser_function==0);
 wire timbre_override_enable=laser_enabled&&(laser_function==1)&&laser_level_valid;
 wire [1:0] timbre_override=laser_blocked ? timbre_a : timbre_b;
 wire laser_mode_invalid=(laser_mode==3)||(laser_function==3);
 reg [1:0] previous_laser_mode, previous_function;
 wire laser_mode_changed=(laser_mode!=previous_laser_mode)||(laser_function!=previous_function);
 // Recover the accepted bank on every source change. Its combined ACK is
 // the barrier that withdraws old pressure pitch before the filter can arm;
 // debounce timing follows that parameter-owner ACK.
 wire transaction_cancel=external_cancel||!healthy||key_pressed[2]||laser_mode_changed;
 reg [2:0] previous_keys;
 wire laser_inhibit=reset||!configured||!healthy||key_pressed[2]||external_cancel||
                    !mod_ready||laser_mode_changed||laser_mode_invalid;
 wire [15:0] laser_filter_triggers;
 laser_input_v1 #(.STABLE_CYCLES(LASER_STABLE_CYCLES)) laser_input(
  .clk(clk),.reset(reset),.enable(laser_enabled&&!laser_mode_invalid),
  .inhibit(laser_inhibit),.blocked_high(laser_mode==1),.raw_level(laser_raw),
  .level_valid(laser_level_valid),.beam_blocked(laser_blocked),
  .armed(laser_ready),.pluck(laser_event),.trigger_count(laser_filter_triggers));
 always @(posedge clk)begin
  if(reset)begin previous_keys<=0;previous_laser_mode<=0;previous_function<=0;end
  else begin previous_keys<=key_pressed;previous_laser_mode<=laser_mode;previous_function<=laser_function;end
  if(laser_inhibit)armed<=0;
  else if(laser_pluck_enabled)begin
   if(laser_level_valid)armed<=1;
  end else if(touch==0&&key_pressed==0)armed<=1;
 end
 wire start=!laser_pluck_enabled&&armed&&healthy&&key_pressed[1]&&!previous_keys[1]&&!key_pressed[2];
 wire blocked=laser_inhibit||!armed;
 wire legacy_flush,flush;
 wire panic=blocked||flush;
 assign mute=panic;
 wire [11:0] routed_gain;
 wire [11:0] expression_gain=(auto_mode||laser_pluck_enabled) ? 12'd1024 : routed_gain;
 // Preserve the old observed combined-gain field. The actual voice-mixer
 // coefficient tracks raw expression before FX.
 panel_master_gain_v2 volume(.clk(clk),.reset(reset),.sample_ce(sample_ce),
  .master_volume(master_volume),.expression_gain(expression_gain),.gain(gain),.smooth_gain());
 wire core_cfg_valid,core_cfg_ready,core_cfg_applied;
 wire [7:0] core_cfg_id;wire [15:0] core_cfg_value,core_revision;
 wire [1:0] core_cfg_error;wire [111:0] core_cfg_state;
 assign effective_bend=core_cfg_state[64+:16];
 delay_route_v1 #(.CLK_HZ(CLK_HZ)) system(.clk(clk),.reset(reset),.sample_ce(sample_ce),
  .cancel(transaction_cancel),.cfg_cancelled(cfg_cancelled),.delay_state(delay_state),.master_volume(master_volume), .master_smooth_level(master_smooth_level),.actual_delay_enabled(actual_delay_enabled), .actual_delay_samples(actual_delay_samples),.actual_wet(actual_wet),.master_target(master_target),.stream_clear(runtime_clear), .mod_level(mod_level),.modulation_clear(panic),.mod_state(mod_state),
  .mod_offset(mod_offset),.mod_applied_level(mod_applied_level),.mod_ready(mod_ready),
  .pressure_valid(pressure_valid&&!laser_pluck_enabled),.pressure_level(pressure_level),.pressure_gain(pressure_gain),
  .cfg_valid(cfg_valid),.cfg_id(cfg_id),.cfg_value(cfg_value),.cfg_ready(cfg_ready),
  .cfg_applied(cfg_applied),.cfg_error(cfg_error),.cfg_state(cfg_state),.revision(cfg_revision),
  .route_mode(route_mode),.gain(routed_gain),.core_valid(core_cfg_valid),.core_id(core_cfg_id),
  .core_value(core_cfg_value),.core_ready(core_cfg_ready),.core_applied(core_cfg_applied),
  .core_error(core_cfg_error),.core_state(core_cfg_state));
 wire ev,er,rv;wire [1:0] op;
 wire [2:0] rc;wire [15:0] eid,rid;wire [4:0] rslot;
 wire [6:0] note,velocity;
 wire signed [15:0] core_sample;
 wire legacy_ev,laser_ev,legacy_auto;
 wire [1:0] legacy_op,laser_op;
 wire [15:0] legacy_eid,laser_eid;
 wire [6:0] legacy_note,legacy_velocity,laser_note,laser_velocity;
 wire [2:0] legacy_state;
 wire [7:0] legacy_errors,laser_errors;
 wire [4:0] legacy_test_index;
 wire midi_valid_int=MIDI_ENABLE ? midi_event_valid : 1'b0;
 wire [1:0] core_op;wire [15:0] core_eid;wire [6:0] core_note,core_velocity;
 wire core_ev,core_er,panel_event_ready,midi_event_ready_int;
 assign er=panel_event_ready;
 reg prefer_midi;
 wire select_midi=midi_valid_int&&(!ev||prefer_midi);
 assign core_ev=ev||midi_valid_int;
 assign core_op=select_midi?midi_event_op:op;
 assign core_eid=select_midi?midi_event_id:eid;
 assign core_note=select_midi?midi_event_note:note;
 assign core_velocity=select_midi?midi_event_velocity:velocity;
 assign panel_event_ready=core_er&&!select_midi;
 assign midi_event_ready_int=core_er&&select_midi;
 wire midi_grant_result=MIDI_ENABLE&&rv&&(rid[15:13]==3'b101);
 assign midi_event_ready=MIDI_ENABLE ? midi_event_ready_int : 1'b0;
 assign midi_result_valid=MIDI_ENABLE ? midi_grant_result : 1'b0;
 assign midi_result_code=rc;
 assign midi_result_id=rid;
 assign flush=!laser_pluck_enabled&&legacy_flush;
 assign ev=laser_pluck_enabled ? laser_ev : legacy_ev;
 assign op=laser_pluck_enabled ? laser_op : legacy_op;
 assign eid=laser_pluck_enabled ? laser_eid : legacy_eid;
 assign note=laser_pluck_enabled ? laser_note : legacy_note;
 assign velocity=laser_pluck_enabled ? laser_velocity : legacy_velocity;
 assign auto_mode=!laser_pluck_enabled&&legacy_auto;
 assign state=laser_pluck_enabled ? 3'd2 : legacy_state;
 assign errors=laser_pluck_enabled ? laser_errors : legacy_errors;
 assign test_index=laser_pluck_enabled ? 5'd0 : legacy_test_index;
 always @(posedge clk)begin
  if(reset)prefer_midi<=0;
  else if(core_ev&&core_er)prefer_midi<=!select_midi;
 end
 p13_events #(.HOLD_FRAMES(HOLD_FRAMES),.RELEASE_FRAMES(RELEASE_FRAMES)) producer(
  .clk(clk),.reset(reset),.blocked(blocked||laser_pluck_enabled),.sample_ce(sample_ce),.start(start),.touch(touch),
  .allocated(allocated),.flush(legacy_flush),.state(legacy_state),.auto_mode(legacy_auto),
  .event_valid(legacy_ev),.event_ready(panel_event_ready&&!laser_pluck_enabled),.event_op(legacy_op),
  .event_id(legacy_eid),.event_note(legacy_note),.event_velocity(legacy_velocity),
  .result_valid(rv&&!midi_grant_result&&!laser_pluck_enabled),.result_code(rc),.errors(legacy_errors),.test_index(legacy_test_index));
 laser_pluck_events_v1 #(.SHARED_MIDI_IDS(MIDI_ENABLE)) laser_producer(.clk(clk),.reset(reset),
  .blocked(blocked||!laser_pluck_enabled),.pluck(laser_event),.touch(touch),
  .allocated(allocated),.slot_ids(slot_ids),.event_valid(laser_ev),
  .event_ready(panel_event_ready&&laser_pluck_enabled),.event_op(laser_op),.event_id(laser_eid),
  .event_note(laser_note),.event_velocity(laser_velocity),
  .result_valid(rv&&!midi_grant_result&&laser_pluck_enabled),.result_code(rc),.result_id(rid),
  .busy(laser_busy),.errors(laser_errors),.dropped(laser_dropped),.trigger_count(laser_triggers));
 ab_event_core_v1 engine(.clk(clk),.reset(reset),.panic(panic),.sample_ce(sample_ce),
  .force_pluck(laser_pluck_enabled), .timbre_override_enable(timbre_override_enable), .timbre_override(timbre_override),
  .event_valid(core_ev),.event_ready(core_er),.event_op(core_op),.event_id(core_eid),.event_note(core_note),.event_velocity(core_velocity),
  .result_valid(rv),.result_code(rc),.result_id(rid),.result_slot(rslot),
  .expression_gain(expression_gain),.expression_valid(!mute),
  .cfg_valid(core_cfg_valid),.cfg_id(core_cfg_id),.cfg_value(core_cfg_value),.cfg_ready(core_cfg_ready),.cfg_error(core_cfg_error),
  .cfg_applied(core_cfg_applied),.cfg_revision(core_revision),.cfg_state(core_cfg_state),
  .allocated(allocated),.voice_gate(gate),.active(active),.voice_timbres(),.voice_modes(),
  .voice_note(),.voice_velocity(),.slot_ids(slot_ids),.full_count(fulls),.duplicate_count(duplicates),
  .unknown_off_count(unknowns),.bad_op_count(bads),.sample(core_sample),.sample_valid(sv));
 always @(posedge clk)begin
  if(reset)begin responses<=0;last_result<=0;end
  else if(rv)begin responses<=responses+1'b1;last_result<=rc;end
 end
 // Preserve the original MASTER saturation boundary before fixed output trim.
 // This is combinational net preservation on the existing sample path.
 (* syn_keep=1 *) wire signed [15:0] stream_sample;
 wire stream_valid;
 // A bounded stream pipeline must finish before the original next I2S frame.
 // clear remains owned by output_link; allocator completion remains core sv.
 wire fx_valid;
 wire stream_clear=panic||runtime_clear;
 wire mix_target=mix_enabled&&(!(laser_enabled&&(laser_function==2))||(laser_level_valid&&laser_blocked));
 wire wet_active=mix_target||(mix_level!=0);
 reg signed [15:0] dry_q0,dry_q1;
 always @(posedge clk)begin
  if(reset||stream_clear)begin dry_q0<=0;dry_q1<=0;end
  else begin if(sv)dry_q0<=core_sample;dry_q1<=dry_q0;end
 end
 wire mixed_valid;wire signed [15:0] mixed_sample;
 wire signed [15:0] fx_sample;
 delay_stream_v1 stream(.clk(clk),.reset(reset),.clear(stream_clear),
  .enabled(actual_delay_enabled&&wet_active),.delay_samples(actual_delay_samples),.wet_level(actual_wet),
  .in_valid(sv),.in_sample(core_sample),.out_valid(fx_valid),.out_sample(fx_sample));
 ab_mix_bypass_v1 mix_switch(.clk(clk),.reset(reset),.clear(stream_clear),.sample_ce(sample_ce),
  .in_valid(fx_valid),.dry_sample(dry_q1),.wet_sample(fx_sample),.mix_enabled(mix_target),
  .out_valid(mixed_valid),.out_sample(mixed_sample),.mix_level(mix_level));
 delay_master_v1 master(.clk(clk),.reset(reset),.clear(stream_clear),.sample_ce(sample_ce),
  .master_volume(master_target),.in_valid(mixed_valid),.in_sample(mixed_sample),
  .out_valid(stream_valid),.out_sample(stream_sample),.frame_gain(),.smooth_level(master_smooth_level));
 wire signed [15:0] trimmed_sample;
 audio_output_trim_v1 output_trim(.in_sample(stream_sample),.out_sample(trimmed_sample));
 system_audio_output #(.BCLK_HALF_PERIOD(BCLK_HALF_PERIOD)) output_link(
  .clk(clk),.power_reset(power_reset),.clear(stream_clear),.sample_valid(stream_valid),
  .source_sample(trimmed_sample),.held_sample(sample),.sample_ce(sample_ce),
  .bclk(bclk),.lrck(lrck),.dout(dout));
endmodule
