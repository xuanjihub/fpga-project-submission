// S15 polling candidate: original arbitration and watchdog behavior, local MPR scheduler.
`timescale 1ns/1ps
// One physical open-drain master. Round-robin at transaction boundaries.
module s12_shared_core #(parameter CLK_HZ=52500000, I2C_HZ=100000,
 parameter LINE_TIMEOUT=CLK_HZ/1000)(
 input wire clk,reset, inout wire scl,sda,
 output wire [11:0] touch,
 output reg [31:0] touch_age,
 output wire touch_update,
 output wire adc_strobe,adc_channel,
 output wire signed [15:0] adc_raw,
 output wire m_ready,m_fault,m_valid,
 output wire [3:0] m_error, output wire [7:0] m_errors,
 output wire [15:0] m_seq, output reg [31:0] m_age,
 output wire signed [15:0] raw0,raw1,
 output wire [1:0] a_valid, output wire [7:0] a_error,
 output wire [31:0] a_errors,a_seq,age0,age1,
 output wire bus_fault_valid, output wire [39:0] bus_fault_context);
 wire mr,ar,rv,re,rr; wire [3:0] ec;
 wire [15:0] data; wire [6:0] ma;
 wire [7:0] mg,md,ag; wire [15:0] ad;
 wire mread,aread;
 // Transaction ownership changes only when the response is consumed.
 // Bounded line recovery in the one master protects both clients. One device's
 // successful response leaves the other's error/validity state intact.
 reg active=0,owner=0,last_owner=1;
 wire choose = mr && ar ? !last_owner : ar;
 wire launch=!active && rr && (mr||ar);
 wire done=active && rv;
 wire [39:0] master_fault_context;
 assign bus_fault_valid=done && re;
 // The retained owner is the request owner.
 assign bus_fault_context={master_fault_context[39:5],owner,master_fault_context[3:0]};
 shared_mpr_client #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ)) m(
 .clk(clk),.reset(reset),.master_req_valid(mr),
 .master_req_ready(launch && !choose),.master_rsp_valid(done && !owner),
 .master_rsp_error(re),.master_rsp_error_code(ec),
 .master_rsp_rdata({data[7:0],data[15:8]}),
 .req_read2(mread),.req_addr(ma),.req_reg(mg),.req_data(md),
 .touch_mask(touch),.touch_update(touch_update),.ready(m_ready),.sensor_fault(m_fault),
 .diag_valid(m_valid),.last_i2c_error(m_error),.error_count(m_errors),.diag_seq(m_seq));
 shared_ads_client #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ),
 .TRANSACTION_TIMEOUT_CYCLES(CLK_HZ/20)) a(
 .clk(clk),.reset(reset),.req_valid(ar),.req_ready(launch && choose),
 .req_read(aread),.req_reg(ag),.config_word(ad),
 .rsp_valid(done && owner),.rsp_error(re),.rsp_error_code(ec),.rsp_rdata(data),
 .sample_strobe(adc_strobe),.sample_channel(adc_channel),.sample_raw(adc_raw),
 .raw0(raw0),.raw1(raw1),.data_valid(a_valid),.sample_sequence(a_seq),
 .age0(age0),.age1(age1),.last_error(a_error),.error_count(a_errors));
 shared_i2c_master #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ),
 .LINE_TIMEOUT_CYCLES(LINE_TIMEOUT)) bus(
 .clk(clk),.reset(reset),.req_valid(launch),.req_ready(rr),
 .req_read2(choose ? aread : mread),.req_write8(!choose),
 .req_addr7(choose ? 7'h48 : ma),.req_reg(choose ? ag : mg),
 .req_wdata(choose ? ad : {md,8'b0}),.rsp_valid(rv),.rsp_ready(active),
 .rsp_rdata(data),.rsp_error(re),.rsp_error_code(ec),.fault_context(master_fault_context),.scl(scl),.sda(sda));
 reg [15:0] last_seq;
 always @(posedge clk) begin
  if(reset) begin active<=0;owner<=0;last_owner<=1;last_seq<=0;m_age<=32'hffffffff;touch_age<=32'hffffffff;end
  else begin
   if(touch_update && m_ready && !m_fault) touch_age<=0;
   else if(touch_age!=32'hffffffff) touch_age<=touch_age+1'b1;
   if(launch) begin active<=1;owner<=choose;end
   if(done) begin active<=0;last_owner<=owner;end
   if(m_seq!=last_seq) begin last_seq<=m_seq;m_age<=0;end
   else if(m_age!=32'hffffffff) m_age<=m_age+1'b1;
  end
 end
endmodule
