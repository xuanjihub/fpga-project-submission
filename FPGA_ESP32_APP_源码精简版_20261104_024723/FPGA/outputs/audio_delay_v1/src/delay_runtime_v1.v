// Actual FX/MASTER owner. Requests contain accepted transaction snapshots.
// ACK means both wet and the real MASTER ramp have settled.
module delay_runtime_v1(
 input wire clk,reset,sample_ce,cancel,
 input wire request_valid,input wire [47:0] request_state,
 input wire [4:0] request_master,
 output wire request_ready,output reg request_applied,output reg [1:0] error,
 input wire [7:0] master_smooth_level,
 output reg actual_enabled,output reg [13:0] actual_samples,
 output reg [4:0] actual_wet,master_target,
 output reg stream_clear,output wire busy
);
 localparam IDLE=0,DOWN=1,CLEAR=2,SETTLE=3;
 reg [1:0] state;
 reg target_enabled;
 reg [13:0] target_samples;
 reg [4:0] target_wet,target_master;
 wire legal=request_state[15:0]<=1&&request_state[31:16]>=1&&request_state[31:16]<=16383&&
            request_state[47:32]<=16&&request_master<=16;
 wire [7:0] target_level={target_master,3'b0};
 assign request_ready=!reset&&!cancel&&error==0&&state==IDLE;
 assign busy=state!=IDLE;
 always @(posedge clk)begin
  if(reset)begin
   state<=IDLE;actual_enabled<=0;actual_samples<=8192;actual_wet<=4;
   master_target<=16;target_enabled<=0;target_samples<=8192;
   target_wet<=4;target_master<=16;request_applied<=0;error<=0;stream_clear<=1;
  end else begin
   request_applied<=0;stream_clear<=0;
   if(cancel||error!=0)begin
    // Cancellation is immediate, independent of the slow fade.
    // The coordinator subsequently restores the last accepted snapshot.
    state<=IDLE;actual_enabled<=0;actual_wet<=0;master_target<=0;stream_clear<=1;
   end else case(state)
    IDLE:if(request_valid&&request_ready)begin
     if(!legal)begin error<=2;stream_clear<=1;master_target<=0;actual_wet<=0;end
     else begin
      target_enabled<=request_state[0];target_samples<=request_state[29:16];
      target_wet<=request_state[36:32];target_master<=request_master;
      if(actual_enabled!=request_state[0]||actual_samples!=request_state[29:16])begin
       // Fade the complete dry+wet output, then clear and change the RAM
       // contract at silence. This avoids relying on a wet-only crossfade.
       master_target<=0;state<=DOWN;
      end else begin master_target<=request_master;state<=SETTLE;end
     end
    end
    // MASTER captures the pre-ramp coefficient at sample_ce. After ramp 1->0,
    // the in-flight frame still owns coefficient 1. Wait for a request that
    // captures zero before changing enabled/D or invalidating history.
    DOWN:if(sample_ce&&master_smooth_level==0)state<=CLEAR;
    CLEAR:begin
     stream_clear<=1;actual_enabled<=target_enabled;actual_samples<=target_samples;
     actual_wet<=0;master_target<=target_master;state<=SETTLE;
    end
    SETTLE:if(sample_ce)begin
     if(actual_wet<target_wet)actual_wet<=actual_wet+1'b1;
     else if(actual_wet>target_wet)actual_wet<=actual_wet-1'b1;
     // At this same request edge the MASTER captures its already settled
     // coefficient. ACK follows the coefficient's first use.
     if(actual_wet==target_wet&&master_smooth_level==target_level)begin
      request_applied<=1;state<=IDLE;
     end
    end
    default:begin error<=1;master_target<=0;stream_clear<=1;end
   endcase
  end
 end
endmodule
