// Full-width balanced tree followed by the preserved S18 attenuation boundary.
// Supported VOICES: 4 or 32. Accepts a new vector every clock; latency is
// clog2(VOICES) clocks from the accepting edge to out_valid (inclusive edges +1).
module p06_mix_gain #(parameter integer VOICES=32)(
 input wire clk,reset,in_valid,
 input wire [VOICES*16-1:0] voice_samples,
 input wire [11:0] gain,
 output wire signed [15:0] sample,
 output wire out_valid
);
 localparam integer LEVELS=$clog2(VOICES);
 localparam integer SUM_BITS=16+LEVELS;
 wire signed [SUM_BITS-1:0] tree[1:2*VOICES-1];
 reg [LEVELS:0] valid_pipe;
 reg [11:0] gain_pipe[0:LEVELS-1];
 integer g;
 always @(posedge clk)begin
  if(reset)begin
   valid_pipe<=0;
   for(g=0;g<LEVELS;g=g+1)gain_pipe[g]<=0;
  end else begin
   valid_pipe<={valid_pipe[LEVELS-1:0],in_valid};
   gain_pipe[0]<=gain;
   for(g=1;g<LEVELS;g=g+1)gain_pipe[g]<=gain_pipe[g-1];
  end
 end
 genvar v,level,n;
 generate
  for(v=0;v<VOICES;v=v+1)begin:leaves
   assign tree[VOICES+v]={{LEVELS{voice_samples[v*16+15]}},voice_samples[v*16+:16]};
  end
  for(level=0;level<LEVELS;level=level+1)begin:layers
   for(n=0;n<(VOICES>>(level+1));n=n+1)begin:nodes
    localparam integer INDEX=(VOICES>>(level+1))+n;
    reg signed [SUM_BITS-1:0] subtotal;
    wire update;
    if(level==0)begin:first_level
     assign update=in_valid;
    end else begin:later_level
     assign update=valid_pipe[level-1];
    end
    always @(posedge clk)begin
     if(reset)subtotal<=0;
     else if(update)subtotal<=tree[INDEX*2]+tree[INDEX*2+1];
    end
    assign tree[INDEX]=subtotal;
   end
  end
 endgenerate
 // Keep the sum full width before attenuation. 32 signed16 inputs need 21 bits.
 (* syn_keep = 1 *) wire signed [15:0] scaled_mix=tree[1]>>>6;
 reg signed [28:0] product;
 always @(posedge clk)begin
  if(reset)product<=0;
  else if(valid_pipe[LEVELS-1])product<=scaled_mix*$signed({1'b0,gain_pipe[LEVELS-1]});
 end
 assign sample=product>>>12;
 assign out_valid=valid_pipe[LEVELS];
endmodule
