// Fixed 2x digital output trim after MASTER, before the retained I2S storage.
// Combinational sign-bit logic has zero clock/sample latency. Saturation
// protects future upstream changes; present 32-voice bounds remain below it.
module audio_output_trim_v1(
 input wire signed [15:0] in_sample,
 output wire signed [15:0] out_sample
);
 // A left shift overflows signed16 exactly when the two high bits differ.
 wire overflow=in_sample[15]^in_sample[14];
 assign out_sample=overflow ? (in_sample[15] ? 16'sh8000 : 16'sh7fff) :
                             {in_sample[14:0],1'b0};
endmodule
