// Transaction coordinator. The frozen modulation owner remains the sole core
// bus writer. Its private ACK and the actual FX/MASTER ACK must both finish
// before publishing one accepted bank/revision to panel, presets or telemetry.
module delay_route_v1 #(
 parameter integer CLK_HZ=50000000,CONTROL_CYCLES=CLK_HZ/1000,
 parameter integer TX_TIMEOUT_CYCLES=CLK_HZ
)(
 input wire clk,reset,sample_ce,pressure_valid,cancel,
 input wire modulation_clear,input wire [4:0] mod_level,
 input wire [11:0] pressure_level,pressure_gain,
 input wire cfg_valid,input wire [7:0] cfg_id,input wire [15:0] cfg_value,
 output wire cfg_ready,output reg cfg_applied,output reg [1:0] cfg_error,
 output wire [111:0] cfg_state,output reg [15:0] revision,
 output wire [31:0] mod_state,output wire signed [15:0] mod_offset,
 output wire [4:0] mod_applied_level,output wire [31:0] mod_phase,output wire mod_ready,
 output wire [1:0] route_mode,output wire [11:0] gain,
 output wire [47:0] delay_state,output wire [4:0] master_volume,
 output wire cfg_cancelled,
 input wire [7:0] master_smooth_level,
 output wire actual_delay_enabled,output wire [13:0] actual_delay_samples,
 output wire [4:0] actual_wet,master_target,output wire stream_clear,
 output wire core_valid,output wire [7:0] core_id,output wire [15:0] core_value,
 input wire core_ready,core_applied,input wire [1:0] core_error,
 input wire [111:0] core_state
);
 `include "modulation_catalog_v1.vh"
 localparam IDLE=0,FX_START=1,INNER_SEND=2,INNER_COMMIT=3,WAIT_ALL=4,
            RECOVER_WAIT=5,FAULT=6;
 localparam [223:0] DEFAULT_BANK={16'd16,16'd4,16'd8192,16'd0,
                                 CAT_MOD_DEFAULT,16'd0,CAT_SYSTEM_DEFAULT};
 reg [2:0] state;
 reg [223:0] accepted,shadow,pending;
 reg [3:0] field_index;
 reg recovering,fx_done,inner_done;
 reg [31:0] timeout_count;
 wire inner_ready,inner_applied,inner_mod_ready;
 wire [1:0] inner_error;
 wire [111:0] inner_state;
 wire [31:0] inner_mod_state;
 wire [1:0] inner_route;
 wire [15:0] inner_revision;
 wire fx_ready,fx_applied,fx_busy;
 wire [1:0] fx_error;
 wire inner_valid=!cancel&&cfg_error==0&&
                  (state==INNER_SEND||state==INNER_COMMIT||state==RECOVER_WAIT);
 wire [7:0] inner_id=state==RECOVER_WAIT?8'h7e:
                     state==INNER_COMMIT?8'h7f:{4'b0,field_index};
 wire [15:0] inner_value=(state==INNER_COMMIT||state==RECOVER_WAIT)?16'd0:
                         pending[field_index*16+:16];
 assign cfg_state=accepted[111:0];assign route_mode=accepted[113:112];
 assign mod_state=accepted[159:128];assign delay_state=accepted[207:160];
 assign master_volume=accepted[212:208];
 // Level held for the whole transaction: panel must suppress a partial SEND/WAIT
 // for the entire STOP/health level and recovery. Presets survive.
 assign cfg_cancelled=cancel||recovering||cfg_error!=0;
 assign cfg_ready=!reset&&!cfg_cancelled&&state==IDLE;
 assign mod_ready=inner_mod_ready&&!cfg_cancelled;
 // Snapshot only the frozen owner's private pressure correction input. Keep
 // valid/level/gain coherent and break health->bend arithmetic->core-CE timing.
 // Direct cancellation, public ACK suppression and hard audio clear remain
 // independent of this one-main-clock (20 ns at 50 MHz) private-input delay.
 reg legacy_pressure_valid;
 reg [11:0] legacy_pressure_level,legacy_pressure_gain;
 always @(posedge clk)begin
  if(reset)begin
   legacy_pressure_valid<=0;legacy_pressure_level<=0;legacy_pressure_gain<=0;
  end else begin
   legacy_pressure_valid<=pressure_valid&&!cfg_cancelled;
   legacy_pressure_level<=pressure_level;legacy_pressure_gain<=pressure_gain;
  end
 end
 wire [1:0] legacy_error=cat_system_error(cfg_id,cfg_value);
 wire [1:0] command_error=cfg_id<=9||cfg_id==8'h7e||cfg_id==8'h7f ? legacy_error:
   cfg_id==10 ? (cfg_value<=1?2'd0:2'd2):
   cfg_id==11 ? (cfg_value>=1&&cfg_value<=16383?2'd0:2'd2):
   cfg_id==12||cfg_id==13 ? (cfg_value<=16?2'd0:2'd2):2'd1;
 modulation_route_v1 #(.CLK_HZ(CLK_HZ),.CONTROL_CYCLES(CONTROL_CYCLES)) base(
  .clk(clk),.reset(reset),.sample_ce(sample_ce),
  .pressure_valid(legacy_pressure_valid),.pressure_level(legacy_pressure_level),.pressure_gain(legacy_pressure_gain),
  .modulation_clear(modulation_clear||cfg_cancelled),.mod_level(mod_level),
  .cfg_valid(inner_valid),.cfg_id(inner_id),.cfg_value(inner_value),
  .cfg_ready(inner_ready),.cfg_applied(inner_applied),.cfg_error(inner_error),
  .cfg_state(inner_state),.revision(inner_revision),.mod_state(inner_mod_state),
  .mod_offset(mod_offset),.mod_applied_level(mod_applied_level),.mod_phase(mod_phase),
  .mod_ready(inner_mod_ready),.route_mode(inner_route),.gain(gain),
  .core_valid(core_valid),.core_id(core_id),.core_value(core_value),
  .core_ready(core_ready),.core_applied(core_applied),.core_error(core_error),.core_state(core_state));
 delay_runtime_v1 fx(.clk(clk),.reset(reset),.sample_ce(sample_ce),
  .cancel(cancel||cfg_error!=0),.request_valid(state==FX_START&&!cancel&&cfg_error==0),
  .request_state(pending[207:160]),.request_master(pending[212:208]),
  .request_ready(fx_ready),.request_applied(fx_applied),.error(fx_error),
  .master_smooth_level(master_smooth_level),.actual_enabled(actual_delay_enabled),
  .actual_samples(actual_delay_samples),.actual_wet(actual_wet),.master_target(master_target),
  .stream_clear(stream_clear),.busy(fx_busy));
 always @(posedge clk)begin
  if(reset)begin
   state<=IDLE;accepted<=DEFAULT_BANK;shadow<=DEFAULT_BANK;pending<=DEFAULT_BANK;
   field_index<=0;recovering<=0;fx_done<=0;inner_done<=0;timeout_count<=0;
   revision<=0;cfg_applied<=0;cfg_error<=0;
  end else begin
   cfg_applied<=0;
   if(cancel)begin
    // STOP defers any new legacy COMMIT. If one was already
    // accepted, let the sole core owner drain it while hard output is muted.
    // Recovery ABORT discards a partial shadow before resending accepted data.
    state<=RECOVER_WAIT;recovering<=1;shadow<=accepted;pending<=accepted;
    fx_done<=0;inner_done<=0;timeout_count<=0;
   end else if(cfg_error!=0)state<=FAULT;
   else if(inner_error!=0||fx_error!=0)begin
    cfg_error<=inner_error!=0?inner_error:fx_error;state<=FAULT;recovering<=1;
   end else if(state!=IDLE&&timeout_count>=TX_TIMEOUT_CYCLES-1)begin
    cfg_error<=3;state<=FAULT;recovering<=1;
   end else begin
    if(state==IDLE)timeout_count<=0;else timeout_count<=timeout_count+1'b1;
    if(fx_applied)fx_done<=1;
    if(inner_applied&&(state==INNER_COMMIT||state==WAIT_ALL))inner_done<=1;
    case(state)
     IDLE:if(cfg_valid&&cfg_ready)begin
      if(command_error!=0)begin cfg_error<=command_error;state<=FAULT;end
      else if(cfg_id<=13)shadow[cfg_id*16+:16]<=cfg_value;
      else if(cfg_id==8'h7e)shadow<=accepted;
      else if(cfg_id==8'h7f)begin
       pending<=shadow;fx_done<=0;inner_done<=0;field_index<=0;state<=FX_START;
      end
     end
     FX_START:if(fx_ready)begin field_index<=0;state<=INNER_SEND;end
     INNER_SEND:if(inner_ready)begin
      if(field_index==9)state<=INNER_COMMIT;else field_index<=field_index+1'b1;
     end
     INNER_COMMIT:if(inner_ready)state<=WAIT_ALL;
     WAIT_ALL:if((fx_done||fx_applied)&&(inner_done||inner_applied)&&inner_mod_ready)begin
      if(!recovering)begin
       accepted<=pending;revision<=revision+1'b1;cfg_applied<=1;
      end
      recovering<=0;state<=IDLE;shadow<=pending;
     end
     RECOVER_WAIT:if(inner_ready)begin
      // inner_valid sends ABORT on this edge. New accepted-state transaction
      // starts only after the canceled core work/neutral-bend ACK drained.
      pending<=accepted;fx_done<=0;inner_done<=0;field_index<=0;state<=FX_START;
     end
     default:begin cfg_error<=1;state<=FAULT;recovering<=1;end
    endcase
   end
  end
 end
endmodule
