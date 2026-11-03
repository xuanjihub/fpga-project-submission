// Base timbre is still latched per NoteOn. The laser override is an independent
// sample-boundary sideband that leaves phase, ADSR and articulation untouched.
module ab_timbre_voice_v1(
 input wire clk,reset,sample_ce,gate,
 input wire [1:0] timbre_select,input wire pluck_select,
 input wire timbre_override_enable,input wire [1:0] timbre_override,
 input wire [31:0] phase_step,input wire [6:0] velocity,
 input wire [15:0] attack_step,decay_step,sustain_level,release_step,
 output reg [1:0] timbre_latched,output reg mode_latched,
 output wire signed [15:0] sample,output wire active
);
 localparam IDLE=3'd0,ATTACK=3'd1,DECAY=3'd2,SUSTAIN=3'd3,RELEASE=3'd4;
 reg [31:0] phase;
 reg [15:0] envelope;
 reg [2:0] state;
 reg gate_d;
 reg [6:0] velocity_latched;
 reg override_enabled_latched;
 reg [1:0] override_latched;
 wire [1:0] audible_timbre=override_enabled_latched ? override_latched : timbre_latched;
 wire [15:0] wave_bits;
 wire signed [15:0] wave=wave_bits;
 reg signed [32:0] product;
 wire signed [15:0] enveloped_wave=product[31:16];
 reg signed [23:0] velocity_product;
 wire [15:0] target_sustain=mode_latched ? 16'd0 : sustain_level;
 assign sample=velocity_product[22:7];
 assign active=(envelope!=0);
 timbre_wave_rom_v1 rom(.clk(clk),.rst_n(~reset),
  .addr({audible_timbre,phase[31:24]}),.data(wave_bits));
 always @(posedge clk) begin
  if(reset)begin product<=0;velocity_product<=0;end
  else begin
   product<=wave*$signed({1'b0,envelope});
   velocity_product<=enveloped_wave*$signed({1'b0,velocity_latched});
  end
 end
 always @(posedge clk) begin
  if(reset)begin
   phase<=0;envelope<=0;state<=IDLE;gate_d<=0;
   velocity_latched<=0;timbre_latched<=0;mode_latched<=0;
   override_enabled_latched<=0;override_latched<=0;
  end else if(sample_ce)begin
   override_enabled_latched<=timbre_override_enable;
   override_latched<=timbre_override;
   phase<=phase+phase_step;gate_d<=gate;
   if(gate && !gate_d)begin
    state<=ATTACK;timbre_latched<=timbre_select;
    mode_latched<=pluck_select;velocity_latched<=velocity;
   end else if(!gate && gate_d && !mode_latched)state<=RELEASE;
   else case(state)
    IDLE: envelope<=0;
    ATTACK: begin
     if(attack_step==0 || {1'b0,envelope}+{1'b0,attack_step}>=17'd65535)begin
      envelope<=65535;state<=DECAY;
     end else envelope<=envelope+attack_step;
    end
    DECAY: begin
     if(decay_step==0 || envelope<=target_sustain ||
        {1'b0,envelope}<={1'b0,target_sustain}+{1'b0,decay_step})begin
      envelope<=target_sustain;state<=SUSTAIN;
     end else envelope<=envelope-decay_step;
    end
    SUSTAIN: envelope<=target_sustain;
    RELEASE: begin
     if(release_step==0 || envelope<=release_step)begin
      envelope<=0;state<=IDLE;
     end else envelope<=envelope-release_step;
    end
    default:begin envelope<=0;state<=IDLE;end
   endcase
  end
 end
endmodule
