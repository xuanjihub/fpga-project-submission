// Laser A/B derivative: inherits all base parameter readback and allocation
// contracts. Override is snapshotted with the audio request and applied
// inside each voice at its render sample_ce without a new NoteOn.
module ab_voice_core_v1 #(parameter integer VOICES=32)(
 input wire clk,reset,panic,sample_ce,force_pluck,
 input wire timbre_override_enable,input wire [1:0] timbre_override,
 input wire [VOICES-1:0] voice_gate,
 input wire [VOICES*7-1:0] voice_note,voice_velocity,
 input wire [11:0] expression_gain,input wire expression_valid,
 input wire cfg_valid,input wire [7:0] cfg_id,input wire [15:0] cfg_value,
 output wire cfg_ready,output wire [1:0] cfg_error,output wire cfg_applied,
 output wire [15:0] cfg_revision,output wire [111:0] cfg_state,
 output wire [VOICES-1:0] active,voice_modes,
 output wire [VOICES*2-1:0] voice_timbres,
 output wire signed [15:0] sample,output wire sample_valid
);
 wire [15:0] attack_step,decay_step,sustain_level,release_step;
 wire signed [9:0] bend;
 wire [1:0] timbre;wire pluck;
 timbre_parameter_bank_v1 params(.clk(clk),.reset(reset),.sample_ce(sample_ce),
  .cfg_valid(cfg_valid),.cfg_id(cfg_id),.cfg_value(cfg_value),
  .cfg_ready(cfg_ready),.cfg_error(cfg_error),.cfg_applied(cfg_applied),
  .revision(cfg_revision),.attack_step(attack_step),.decay_step(decay_step),
  .sustain_level(sustain_level),.release_step(release_step),
  .bend(bend),.timbre(timbre),.pluck(pluck));
 assign cfg_state={15'b0,pluck,14'b0,timbre,{{6{bend[9]}},bend},
                   release_step,sustain_level,decay_step,attack_step};
 wire audio_reset=reset||panic;
 reg [VOICES-1:0] gates;
 reg [VOICES*7-1:0] notes,velocities;
 reg [11:0] gain;
 reg [7:0] pipeline;
 reg override_enable;
 reg [1:0] override_value;
 always @(posedge clk)begin
  if(audio_reset)begin
   gates<=0;notes<=0;velocities<=0;gain<=0;pipeline<=0;
   override_enable<=0;override_value<=0;
  end else begin
   pipeline<={pipeline[6:0],sample_ce};
   if(sample_ce)begin
    gates<=voice_gate;notes<=voice_note;velocities<=voice_velocity;
    gain<=expression_valid ? expression_gain : 12'd0;
    override_enable<=timbre_override_enable;override_value<=timbre_override;
   end
  end
 end
 wire [VOICES*16-1:0] voice_samples;
 genvar v;
 generate for(v=0;v<VOICES;v=v+1)begin:voices
  wire [31:0] base_step,phase_step;
  note_to_step note_map(.note(notes[v*7+:7]),.step(base_step));
  p06_pitch pitch(.clk(clk),.reset(audio_reset),.base_step(base_step),
   .bend(bend),.step(phase_step));
  ab_timbre_voice_v1 voice(.clk(clk),.reset(audio_reset),.sample_ce(pipeline[3]),
   .gate(gates[v]),.phase_step(phase_step),.velocity(velocities[v*7+:7]),
   .timbre_select(timbre),.pluck_select(force_pluck||pluck),
   .timbre_override_enable(override_enable),.timbre_override(override_value),
   .attack_step(attack_step),.decay_step(decay_step),
   .sustain_level(sustain_level),.release_step(release_step),
   .timbre_latched(voice_timbres[v*2+:2]),.mode_latched(voice_modes[v]),
   .sample(voice_samples[v*16+:16]),.active(active[v]));
 end endgenerate
 p06_mix_gain #(.VOICES(VOICES)) mixer(.clk(clk),.reset(audio_reset),
  .in_valid(pipeline[7]),.voice_samples(voice_samples),.gain(gain),
  .sample(sample),.out_valid(sample_valid));
endmodule
