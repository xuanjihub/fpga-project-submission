`timescale 1ns/1ps
// Independent volatile A/B sideband outside the preset bank.
module miseki_panel_control_v1 (
 input wire clk,reset,input wire [2:0] ui_view,input wire [3:0] screen,
 input wire [3:0] encoder_up,encoder_down,input wire [7:0] key_press,
 input wire configured,config_busy,config_fault,transaction_cancel,stop,
 output reg [1:0] mode,output wire [1:0] draft,output wire editing,
 output reg changed,output reg [1:0] function_mode,timbre_a,timbre_b,field,
 output reg mix_enabled,output wire [7:0] laser_drafts,
 output wire [3:0] dirty,output reg mix_draft,output wire mix_dirty
);
 reg [1:0] pending[0:3];reg [3:0] previous_screen;
 wire ready=configured&&!config_busy&&!config_fault;
 wire cancel=transaction_cancel||stop||!ready||key_press[1]||
  (screen!=5&&screen!=6)||screen!=previous_screen;
 assign dirty={pending[3]!=timbre_b,pending[2]!=timbre_a,
  pending[1]!=mode,pending[0]!=function_mode};
 assign mix_dirty=mix_draft!=mix_enabled;
 assign editing=(|dirty)||mix_dirty;
 assign laser_drafts={pending[3],pending[2],pending[1],pending[0]};
 assign draft=screen==6?{1'b0,mix_draft}:pending[field];
 function [1:0] step_value;
  input [1:0] old,maximum;input up;
  begin
   if(up)step_value=old==maximum?0:old+1'b1;
   else step_value=old==0?maximum:old-1'b1;
  end
 endfunction
 always @(posedge clk)begin
  if(reset)begin
   mode<=0;function_mode<=0;timbre_a<=0;timbre_b<=2;field<=0;
   pending[0]<=0;pending[1]<=0;pending[2]<=0;pending[3]<=2;
   mix_enabled<=1;mix_draft<=1;changed<=0;previous_screen<=0;
  end else begin
   changed<=0;previous_screen<=screen;
   if(cancel)begin
    pending[0]<=function_mode;pending[1]<=mode;pending[2]<=timbre_a;pending[3]<=timbre_b;
    mix_draft<=mix_enabled;
   end else if(key_press[7])begin end
   else if(|key_press[6:2])begin end
   else if(key_press[0])begin
    if(screen==6)mix_enabled<=mix_draft;
    else if(editing)begin
     function_mode<=pending[0];mode<=pending[1];timbre_a<=pending[2];timbre_b<=pending[3];
     changed<=pending[0]!=function_mode||pending[1]!=mode;
    end
   end else if(screen==6)begin
    if(encoder_up[0]!=encoder_down[0])begin mix_draft<=!mix_draft;field<=0;end
   end else begin
    if(encoder_up[0]!=encoder_down[0])begin
     pending[0]<=step_value(pending[0],2,encoder_up[0]);field<=0;
    end
    if(encoder_up[1]!=encoder_down[1])begin
     pending[1]<=step_value(pending[1],2,encoder_up[1]);field<=1;
    end
    // FX A/B has fixed actions, so A/B colors remain immutable in FX mode.
    if(pending[0]!=2)begin
     if(encoder_up[2]!=encoder_down[2])begin
      pending[2]<=step_value(pending[2],3,encoder_up[2]);field<=2;
     end
     if(encoder_up[3]!=encoder_down[3])begin
      pending[3]<=step_value(pending[3],3,encoder_up[3]);field<=3;
     end
    end
   end
  end
 end
endmodule
