`timescale 1ns/1ps
// Display-only 128x64, four 32px parameter columns.
// The local serial divider only places graphics.
// Pixel-positioned text preserves the approved HTML whitespace. A single font
// port is time-shared across layers; request/valid is local to the OLED path.
module miseki_renderer_v1(
 input wire clk,reset,request,input wire [2:0] page,input wire [6:0] column,
 input wire [3:0] screen,input wire [1:0] focus,input wire language,
 input wire language_preview,language_dirty,
 input wire [223:0] drafts,input wire [13:0] dirty,
 input wire [4:0] mod_level,master_volume,input wire [1:0] preset_slot,
 input wire preset_save,preset_pending,input wire [3:0] preset_valid,
 input wire [1:0] preset_notice,input wire [11:0] pressure_level,
 input wire pressure_valid,input wire [5:0] active_count,
 input wire editing,busy,fault,armed,healthy,mute,
 input wire [1:0] laser_mode,laser_function,timbre_a,timbre_b,
 input wire [7:0] laser_draft,input wire [3:0] laser_dirty,
 input wire mix_enabled,mix_draft,mix_dirty,
 input wire laser_level_valid,laser_blocked,laser_ready,laser_busy,
 input wire [15:0] revision,input wire [3:0] menu_selection,
 input wire [1:0] diag_selection,input wire [2:0] diag_status,diag_state,
 input wire [4:0] diag_index,input wire [7:0] diag_errors,
 output reg valid,output reg [7:0] data
);
// MISEKI_LABELS_BEGIN -- generated font label table.
    localparam [7:0] W_TONE=8'd0;
    localparam [7:0] W_MODE=8'd1;
    localparam [7:0] W_VOL=8'd2;
    localparam [7:0] W_FSR=8'd3;
    localparam [7:0] W_ATK=8'd4;
    localparam [7:0] W_DEC=8'd5;
    localparam [7:0] W_SUS=8'd6;
    localparam [7:0] W_REL=8'd7;
    localparam [7:0] W_RATE=8'd8;
    localparam [7:0] W_MAX=8'd9;
    localparam [7:0] W_LIVE=8'd10;
    localparam [7:0] W_BEND=8'd11;
    localparam [7:0] W_ON=8'd12;
    localparam [7:0] W_TIME=8'd13;
    localparam [7:0] W_WET=8'd14;
    localparam [7:0] W_OUT=8'd15;
    localparam [7:0] W_RX=8'd16;
    localparam [7:0] W_FUNC=8'd17;
    localparam [7:0] W_AB_A=8'd18;
    localparam [7:0] W_AB_B=8'd19;
    localparam [7:0] W_LANG=8'd20;
    localparam [7:0] W_KEYS=8'd21;
    localparam [7:0] W_SINE=8'd22;
    localparam [7:0] W_PULSE=8'd23;
    localparam [7:0] W_ORGAN=8'd24;
    localparam [7:0] W_REED=8'd25;
    localparam [7:0] W_HOLD=8'd26;
    localparam [7:0] W_PLUCK=8'd27;
    localparam [7:0] W_OFF=8'd28;
    localparam [7:0] W_YES=8'd29;
    localparam [7:0] W_VOLUME=8'd30;
    localparam [7:0] W_PITCH=8'd31;
    localparam [7:0] W_ZERO=8'd32;
    localparam [7:0] W_VF=8'd33;
    localparam [7:0] W_FAST=8'd34;
    localparam [7:0] W_MF=8'd35;
    localparam [7:0] W_MED=8'd36;
    localparam [7:0] W_MS=8'd37;
    localparam [7:0] W_SLOW=8'd38;
    localparam [7:0] W_VS=8'd39;
    localparam [7:0] W_HIGH=8'd40;
    localparam [7:0] W_LOW=8'd41;
    localparam [7:0] W_TIMBRE=8'd42;
    localparam [7:0] W_FX=8'd43;
    localparam [7:0] W_DRY=8'd44;
    localparam [7:0] W_WAIT=8'd45;
    localparam [7:0] W_READY=8'd46;
    localparam [7:0] W_ERROR=8'd47;
    localparam [7:0] W_BLOCK=8'd48;
    localparam [7:0] W_LIGHT=8'd49;
    localparam [7:0] W_EMPTY=8'd50;
    localparam [7:0] W_SAVED=8'd51;
    localparam [7:0] W_LOAD=8'd52;
    localparam [7:0] W_SAVE=8'd53;
    localparam [7:0] W_SLOT=8'd54;
    localparam [7:0] W_ACTION=8'd55;
    localparam [7:0] W_MIX=8'd56;
    localparam [7:0] W_HEALTH=8'd57;
    localparam [7:0] W_MUTE=8'd58;
    localparam [7:0] W_APPLY=8'd59;
    localparam [7:0] W_TEST_ITEM=8'd60;
    localparam [7:0] W_TEST_STATE=8'd61;
    localparam [7:0] W_VOICES=8'd62;
    localparam [7:0] W_TEST_ERRORS=8'd63;
    localparam [7:0] W_TEST_INDEX=8'd64;
    localparam [7:0] W_TEST_32=8'd65;
    localparam [7:0] W_TEST_FS=8'd66;
    localparam [7:0] W_TEST_LATENCY=8'd67;
    localparam [7:0] W_IDLE=8'd68;
    localparam [7:0] W_PREP=8'd69;
    localparam [7:0] W_RUN=8'd70;
    localparam [7:0] W_DONE=8'd71;
    localparam [7:0] W_RESTORE=8'd72;
    function [31:0] w;
        input [7:0] id;
        begin case(id)
            W_TONE: w=language ? 32'h69112020 : 32'h544f4e45; // 音色 / TONE
            W_MODE: w=language ? 32'hecc42020 : 32'h4d4f4445; // 模式 / MODE
            W_VOL: w=language ? 32'h69602020 : 32'h564f4c20; // 音量 / VOL
            W_FSR: w=language ? 32'ha1ce2020 : 32'h46535220; // 压感 / FSR
            W_ATK: w=language ? 32'h411e6920 : 32'h41544b20; // A起音 / ATK
            W_DEC: w=language ? 32'h44139720 : 32'h44454320; // D衰减 / DEC
            W_SUS: w=language ? 32'h538bd220 : 32'h53555320; // S保持 / SUS
            W_REL: w=language ? 32'h525fdb20 : 32'h52454c20; // R释放 / REL
            W_RATE: w=language ? 32'h6cf72020 : 32'h52415445; // 频率 / RATE
            W_MAX: w=language ? 32'hf2c02020 : 32'h4d415820; // 深度 / MAX
            W_LIVE: w=language ? 32'ha0e42020 : 32'h4c495645; // 即时 / LIVE
            W_BEND: w=language ? 32'ha61d2020 : 32'h53544550; // 变调 / STEP
            W_ON: w=language ? 32'hc3922020 : 32'h4f4e2020; // 开关 / ON
            W_TIME: w=language ? 32'he4652020 : 32'h4d532020; // 时间 / MS
            W_WET: w=language ? 32'hf3a82020 : 32'h4d495820; // 混合 / MIX
            W_OUT: w=language ? 32'h24982020 : 32'h4f555420; // 输出 / OUT
            W_RX: w=language ? 32'hfbbd2020 : 32'h52582020; // 电平 / RX
            W_FUNC: w=language ? 32'h9d0f2020 : 32'h46554e43; // 功能 / FUNC
            W_AB_A: w=language ? 32'h415bd320 : 32'h4120424c; // A遮挡 / A BL
            W_AB_B: w=language ? 32'h42a59020 : 32'h42204c54; // B受光 / B LT
            W_LANG: w=language ? 32'h1a162020 : 32'h4c414e47; // 语言 / LANG
            W_KEYS: w=language ? 32'h15d72020 : 32'h4b455953; // 触摸 / KEYS
            W_SINE: w=language ? 32'hedc52020 : 32'h53494e45; // 正弦 / SINE
            W_PULSE: w=language ? 32'h10952020 : 32'h50554c53; // 脉冲 / PULS
            W_ORGAN: w=language ? 32'h6ef82020 : 32'h4f52474e; // 风琴 / ORGN
            W_REED: w=language ? 32'h08072020 : 32'h52454544; // 簧管 / REED
            W_HOLD: w=language ? 32'hd20d2020 : 32'h484f4c44; // 持续 / HOLD
            W_PLUCK: w=language ? 32'hd1c52020 : 32'h504c4b20; // 拨弦 / PLK
            W_OFF: w=language ? 32'h92632020 : 32'h4f464620; // 关闭 / OFF
            W_YES: w=language ? 32'hc3aa2020 : 32'h4f4e2020; // 开启 / ON
            W_VOLUME: w=language ? 32'h69602020 : 32'h564f4c20; // 音量 / VOL
            W_PITCH: w=language ? 32'h696f2020 : 32'h50434820; // 音高 / PCH
            W_ZERO: w=language ? 32'ha0e42020 : 32'h5a45524f; // 即时 / ZERO
            W_VF: w=language ? 32'he7ca2020 : 32'h562e4620; // 极快 / V.F
            W_FAST: w=language ? 32'hca202020 : 32'h46415354; // 快 / FAST
            W_MF: w=language ? 32'h23ca2020 : 32'h4d2e4620; // 较快 / M.F
            W_MED: w=language ? 32'h82202020 : 32'h4d454420; // 中 / MED
            W_MS: w=language ? 32'h23cf2020 : 32'h4d2e5320; // 较慢 / M.S
            W_SLOW: w=language ? 32'hcf202020 : 32'h534c4f57; // 慢 / SLOW
            W_VS: w=language ? 32'he7cf2020 : 32'h562e5320; // 极慢 / V.S
            W_HIGH: w=language ? 32'h6ffbbd20 : 32'h48494748; // 高电平 / HIGH
            W_LOW: w=language ? 32'h88fbbd20 : 32'h4c4f5720; // 低电平 / LOW
            W_TIMBRE: w=language ? 32'h69112020 : 32'h544f4e45; // 音色 / TONE
            W_FX: w=language ? 32'hdde82020 : 32'h46582020; // 效果 / FX
            W_DRY: w=language ? 32'ha2b02020 : 32'h44525920; // 原声 / DRY
            W_WAIT: w=language ? 32'h06c92020 : 32'h57414954; // 等待 / WAIT
            W_READY: w=language ? 32'hba0c2020 : 32'h4f4b2020; // 就绪 / OK
            W_ERROR: w=language ? 32'hdc662020 : 32'h45525220; // 故障 / ERR
            W_BLOCK: w=language ? 32'h5bd32020 : 32'h424c4b20; // 遮挡 / BLK
            W_LIGHT: w=language ? 32'ha5902020 : 32'h4c495420; // 受光 / LIT
            W_EMPTY: w=language ? 32'h05eb2020 : 32'h2d2d2d2d; // 空槽 / ----
            W_SAVED: w=language ? 32'hbcb62020 : 32'h53455420; // 已存 / SET
            W_LOAD: w=language ? 32'h9e222020 : 32'h4c4f4144; // 加载 / LOAD
            W_SAVE: w=language ? 32'h8bb62020 : 32'h53415645; // 保存 / SAVE
            W_SLOT: w=language ? 32'heb872020 : 32'h534c4f54; // 槽位 / SLOT
            W_ACTION: w=language ? 32'hd9892020 : 32'h41435420; // 操作 / ACT
            W_MIX: w=language ? 32'hccf3a820 : 32'h4d495820; // 总混合 / MIX
            W_HEALTH: w=language ? 32'h8ec12020 : 32'h484c5448; // 健康 / HLTH
            W_MUTE: w=language ? 32'h68692020 : 32'h4d555445; // 静音 / MUTE
            W_APPLY: w=language ? 32'hbffa2020 : 32'h4f4b2020; // 应用 / OK
            W_TEST_ITEM: w=language ? 32'h6afe2020 : 32'h54455354; // 项目 / TEST
            W_TEST_STATE: w=language ? 32'hf6cb2020 : 32'h53544154; // 状态 / STAT
            W_VOICES: w=language ? 32'hb05c2020 : 32'h564f4943; // 声部 / VOIC
            W_TEST_ERRORS: w=language ? 32'h621b2020 : 32'h45525220; // 错误 / ERR
            W_TEST_INDEX: w=language ? 32'hbea72020 : 32'h4e4f5445; // 序号 / NOTE
            W_TEST_32: w=language ? 32'h33326920 : 32'h33325620; // 32音 / 32V
            W_TEST_FS: w=language ? 32'h5eea2020 : 32'h46532020; // 采样 / FS
            W_TEST_LATENCY: w=language ? 32'hc22c2020 : 32'h4c415420; // 延迟 / LAT
            W_IDLE: w=language ? 32'h05642020 : 32'h49444c45; // 空闲 / IDLE
            W_PREP: w=language ? 32'h96b12020 : 32'h50524550; // 准备 / PREP
            W_RUN: w=language ? 32'h26122020 : 32'h52554e20; // 运行 / RUN
            W_DONE: w=language ? 32'hb7d02020 : 32'h444f4e45; // 完成 / DONE
            W_RESTORE: w=language ? 32'hcdb22020 : 32'h4241434b; // 恢复 / BACK
            default:w=32'h20202020;
        endcase end
    endfunction
    localparam [7:0] L_PLAY=8'd0;
    localparam [7:0] L_ADSR=8'd1;
    localparam [7:0] L_MOD=8'd2;
    localparam [7:0] L_DELAY=8'd3;
    localparam [7:0] L_INPUT=8'd4;
    localparam [7:0] L_LASER=8'd5;
    localparam [7:0] L_MIX=8'd6;
    localparam [7:0] L_PRESETS=8'd7;
    localparam [7:0] L_SYSTEM=8'd8;
    localparam [7:0] L_DIRECTORY=8'd9;
    localparam [7:0] L_APPLY=8'd10;
    localparam [7:0] L_BACK=8'd11;
    localparam [7:0] L_ENTER=8'd12;
    localparam [7:0] L_CONFIRM=8'd13;
    localparam [7:0] L_STOP=8'd14;
    localparam [7:0] L_FAULT=8'd15;
    localparam [7:0] L_BUSY=8'd16;
    localparam [7:0] L_NEW_NOTES=8'd17;
    localparam [7:0] L_LIVE=8'd18;
    localparam [7:0] L_NOMINAL=8'd19;
    localparam [7:0] L_LASER_PLUCK=8'd20;
    localparam [7:0] L_LASER_AB=8'd21;
    localparam [7:0] L_LASER_FX=8'd22;
    localparam [7:0] L_MIX_OFF=8'd23;
    localparam [7:0] L_MIX_ON=8'd24;
    localparam [7:0] L_RAM=8'd25;
    localparam [7:0] L_SAVE=8'd26;
    localparam [7:0] L_LOAD=8'd27;
    localparam [7:0] L_REPLACE=8'd28;
    localparam [7:0] L_EMPTY=8'd29;
    localparam [7:0] L_SAVED=8'd30;
    localparam [7:0] L_LOADED=8'd31;
    localparam [7:0] L_HELP=8'd32;
    localparam [7:0] L_LANG=8'd33;
    localparam [7:0] L_CN=8'd34;
    localparam [7:0] L_EN=8'd35;
    localparam [7:0] L_BLOCK=8'd36;
    localparam [7:0] L_PRESSURE=8'd37;
    localparam [7:0] L_CONFIRM_TITLE=8'd38;
    localparam [7:0] L_K1_APPLY=8'd39;
    localparam [7:0] L_K1_OPEN=8'd40;
    localparam [7:0] L_K1_YES=8'd41;
    localparam [7:0] L_K2_UNDO=8'd42;
    localparam [7:0] L_K2_BACK=8'd43;
    localparam [7:0] L_K2_NO=8'd44;
    localparam [7:0] L_TEST=8'd45;
    localparam [7:0] L_TEST_SINE=8'd46;
    localparam [7:0] L_TEST_FILL=8'd47;
    localparam [7:0] L_TEST_HOLD=8'd48;
    localparam [7:0] L_TEST_RELEASE=8'd49;
    localparam [7:0] L_TEST_DRAIN=8'd50;
    localparam [7:0] L_TEST_DONE=8'd51;
    localparam [7:0] L_TEST_IDLE=8'd52;
    localparam [7:0] L_TEST_WAIT=8'd53;
    localparam [7:0] L_TEST_READY=8'd54;
    localparam [7:0] L_TEST_RESTORE=8'd55;
    localparam [7:0] L_TEST_FAULT=8'd56;
    localparam [7:0] L_TEST_PROBE=8'd57;
    localparam [7:0] L_TEST_RX=8'd58;
    localparam [7:0] L_TEST_FIXED=8'd59;
    localparam [7:0] L_K1_PREP=8'd60;
    localparam [7:0] L_K1_RUN=8'd61;
    localparam [7:0] L_MEASURE=8'd62;
    localparam [7:0] L_K8_STOP=8'd63;
    function [127:0] l;
        input [7:0] id;
        begin case(id)
            L_PLAY: l=language ? 128'hf4b42020202020202020202020202020 : 128'h504c4159202020202020202020202020; // 演奏 / PLAY
            L_ADSR: l=language ? 128'h9f0a2020202020202020202020202020 : 128'h454e56454c4f50452020202020202020; // 包络 / ENVELOPE
            L_MOD: l=language ? 128'h6d6980a61d2020202020202020202020 : 128'h4d4f44554c4154494f4e202020202020; // 颤音与变调 / MODULATION
            L_DELAY: l=language ? 128'hadb02020202020202020202020202020 : 128'h44454c41592020202020202020202020; // 回声 / DELAY
            L_INPUT: l=language ? 128'h2491d69a202020202020202020202020 : 128'h494e5055542020202020202020202020; // 输入控制 / INPUT
            L_LASER: l=language ? 128'hf59020412f4220202020202020202020 : 128'h4c4153455220412f4220202020202020; // 激光 A/B / LASER A/B
            L_MIX: l=language ? 128'hdde8ccc3922020202020202020202020 : 128'h4658204d495820202020202020202020; // 效果总开关 / FX MIX
            L_PRESETS: l=language ? 128'haceb6b18202020202020202020202020 : 128'h50524553455453202020202020202020; // 四槽预设 / PRESETS
            L_SYSTEM: l=language ? 128'h090b2020202020202020202020202020 : 128'h53595354454d20202020202020202020; // 系统 / SYSTEM
            L_DIRECTORY: l=language ? 128'h9d0ffec8202020202020202020202020 : 128'h50414745532020202020202020202020; // 功能目录 / PAGES
            L_APPLY: l=language ? 128'h4b31bffa2020204b32d8612020202020 : 128'h4b31204150504c59204b3220554e444f; // K1应用   K2撤销 / K1 APPLY K2 UNDO
            L_BACK: l=language ? 128'h4b31bffa2020204b3228ad2020202020 : 128'h4b31204150504c59204b32204241434b; // K1应用   K2返回 / K1 APPLY K2 BACK
            L_ENTER: l=language ? 128'h4b3129912020204b3228ad2020202020 : 128'h4b31204f50454e20204b32204241434b; // K1进入   K2返回 / K1 OPEN  K2 BACK
            L_CONFIRM: l=language ? 128'h4b31ff172020204b32a4f12020202020 : 128'h4b31205945532020204b32204e4f2020; // K1确认   K2取消 / K1 YES   K2 NO
            L_STOP: l=language ? 128'h53544f50206869bc8bd2202020202020 : 128'h53544f50204953204c41544348454420; // STOP 静音已保持 / STOP IS LATCHED
            L_FAULT: l=language ? 128'h5d0edc6620c9b2872020202020202020 : 128'h434f4e464947204641554c5420202020; // 配置故障 待复位 / CONFIG FAULT
            L_BUSY: l=language ? 128'hedafbffa201c048c2020202020202020 : 128'h4150504c59494e472e2e2e2020202020; // 正在应用 请稍候 / APPLYING...
            L_NEW_NOTES: l=language ? 128'h6911ecc484e069f9dd20202020202020 : 128'h4e4557204e4f544553204f4e4c592020; // 音色模式仅新音生效 / NEW NOTES ONLY
            L_LIVE: l=language ? 128'ha0e4c6c0e267ff172020202020202020 : 128'h4c4956453a204e4f204150504c592020; // 即时强度无需确认 / LIVE: NO APPLY
            L_NOMINAL: l=language ? 128'he46583e90327868d2020202020202020 : 128'h4e4f4d494e414c2054494d4520202020; // 时间为标称近似值 / NOMINAL TIME
            L_LASER_PLUCK: l=language ? 128'hd1c58afae3e63b692020202020202020 : 128'h504c55434b3a2053454c454354454420; // 拨弦使用既有选音 / PLUCK: SELECTED
            L_LASER_AB: l=language ? 128'h5bd34120a59042202020202020202020 : 128'h424c4f434b2041204c49474854204220; // 遮挡A 受光B / BLOCK A LIGHT B
            L_LASER_FX: l=language ? 128'h41adb02042a2b0202020202020202020 : 128'h41204543484f20422044525920202020; // A回声 B原声 / A ECHO B DRY
            L_MIX_OFF: l=language ? 128'he11fdde8208bfcb26920202020202020 : 128'h445259204b45455053204e4f54455320; // 旁路效果 保留复音 / DRY KEEPS NOTES
            L_MIX_ON: l=language ? 128'h8afae3e6adb0a3de2020202020202020 : 128'h55534553204543484f20504152414d53; // 使用既有回声参数 / USES ECHO PARAMS
            L_RAM: l=language ? 128'h6b1884b652414d202020202020202020 : 128'h5052455345545320494e2052414d2020; // 预设仅存RAM / PRESETS IN RAM
            L_SAVE: l=language ? 128'h8bb6c79bb069a3de2020202020202020 : 128'h5341564520534f554e44202020202020; // 保存当前声音参数 / SAVE SOUND
            L_LOAD: l=language ? 128'h9e22eb93b069a3de2020202020202020 : 128'h4c4f414420534f554e44202020202020; // 加载槽内声音参数 / LOAD SOUND
            L_REPLACE: l=language ? 128'hb914fd3b82eb87202020202020202020 : 128'h5245504c41434520534c4f5420202020; // 将覆盖选中槽位 / REPLACE SLOT
            L_EMPTY: l=language ? 128'heeeb830520e2ef9e2220202020202020 : 128'h454d50545920534c4f54202020202020; // 此槽为空 无法加载 / EMPTY SLOT
            L_SAVED: l=language ? 128'hbc8bb6c79bb069a3de20202020202020 : 128'h534f554e442053415645442020202020; // 已保存当前声音参数 / SOUND SAVED
            L_LOADED: l=language ? 128'hbc9e22b069a3de202020202020202020 : 128'h534f554e44204c4f4144454420202020; // 已加载声音参数 / SOUND LOADED
            L_HELP: l=language ? 128'h4b37fec8204b38686920202020202020 : 128'h4b37205041474553204b382053544f50; // K7目录 K8静音 / K7 PAGES K8 STOP
            L_LANG: l=language ? 128'he5011a16202020202020202020202020 : 128'h4c414e47554147452020202020202020; // 显示语言 / LANGUAGE
            L_CN: l=language ? 128'h82df2020202020202020202020202020 : 128'h82df2020202020202020202020202020; // 中文 / 中文
            L_EN: l=language ? 128'h454e474c495348202020202020202020 : 128'h454e474c495348202020202020202020; // ENGLISH / ENGLISH
            L_BLOCK: l=language ? 128'ha5908342205bd3834120202020202020 : 128'h4c49474854204220424c4f434b204120; // 受光为B 遮挡为A / LIGHT B BLOCK A
            L_PRESSURE: l=language ? 128'ha19c2020202020202020202020202020 : 128'h46535220202020202020202020202020; // 压力 / FSR
            L_CONFIRM_TITLE: l=language ? 128'hff17d989202020202020202020202020 : 128'h434f4e4649524d202020202020202020; // 确认操作 / CONFIRM
            L_K1_APPLY: l=language ? 128'h4b31bffa202020202020202020202020 : 128'h4b31204150504c592020202020202020; // K1应用 / K1 APPLY
            L_K1_OPEN: l=language ? 128'h4b312991202020202020202020202020 : 128'h4b31204f50454e202020202020202020; // K1进入 / K1 OPEN
            L_K1_YES: l=language ? 128'h4b31ff17202020202020202020202020 : 128'h4b312059455320202020202020202020; // K1确认 / K1 YES
            L_K2_UNDO: l=language ? 128'h4b32d861202020202020202020202020 : 128'h4b3220554e444f202020202020202020; // K2撤销 / K2 UNDO
            L_K2_BACK: l=language ? 128'h4b3228ad202020202020202020202020 : 128'h4b32204241434b202020202020202020; // K2返回 / K2 BACK
            L_K2_NO: l=language ? 128'h4b32a4f1202020202020202020202020 : 128'h4b32204e4f2020202020202020202020; // K2取消 / K2 NO
            L_TEST: l=language ? 128'h85abf019202020202020202020202020 : 128'h54455354205041474520202020202020; // 仪器测试 / TEST PAGE
            L_TEST_SINE: l=language ? 128'hedc52034382d37392020202020202020 : 128'h53494e452034382d3739202020202020; // 正弦 48-79 / SINE 48-79
            L_TEST_FILL: l=language ? 128'h40811e69202020202020202020202020 : 128'h46494c4c203332204e4f544553202020; // 逐个起音 / FILL 32 NOTES
            L_TEST_HOLD: l=language ? 128'h8bd23802202020202020202020202020 : 128'h484f4c442038205345434f4e44532020; // 保持8秒 / HOLD 8 SECONDS
            L_TEST_RELEASE: l=language ? 128'h40695fdb202020202020202020202020 : 128'h52454c45415345204f4e452f53544550; // 逐音释放 / RELEASE ONE/STEP
            L_TEST_DRAIN: l=language ? 128'h06c9bb69202020202020202020202020 : 128'h574149542052454c4541534520202020; // 等待尾音 / WAIT RELEASE
            L_TEST_DONE: l=language ? 128'hb7d0a928adcdb2202020202020202020 : 128'h4b3220524553544f5245202020202020; // 完成后返回恢复 / K2 RESTORE
            L_TEST_IDLE: l=language ? 128'h8f96b194c3b520202020202020202020 : 128'h50524550204245464f52452052554e20; // 先准备再开始 / PREP BEFORE RUN
            L_TEST_WAIT: l=language ? 128'h06c95d0ebffa20202020202020202020 : 128'h57414954205245414c204150504c5920; // 等待配置应用 / WAIT REAL APPLY
            L_TEST_READY: l=language ? 128'hba0c2006c9c3b5202020202020202020 : 128'h524541445920544f2052554e20202020; // 就绪 等待开始 / READY TO RUN
            L_TEST_RESTORE: l=language ? 128'hedafcdb2a2a3de202020202020202020 : 128'h524553544f52452053455454494e4753; // 正在恢复原参数 / RESTORE SETTINGS
            L_TEST_FAULT: l=language ? 128'hf019dc66204b38686920202020202020 : 128'h54455354204641554c54202020202020; // 测试故障 K8静音 / TEST FAULT
            L_TEST_PROBE: l=language ? 128'hd4b3d550434d204c52434b2020202020 : 128'h50524f42452050434d204c52434b2020; // 探头接PCM LRCK / PROBE PCM LRCK
            L_TEST_RX: l=language ? 128'hd5dafbbd99696c202020202020202020 : 128'h5258202d3e204c494e45204f55542020; // 接收电平到音频 / RX -> LINE OUT
            L_TEST_FIXED: l=language ? 128'haeb869363020e26715d7202020202020 : 128'h4649584544204e4f5445203630202020; // 固定音60 无需触摸 / FIXED NOTE 60
            L_K1_PREP: l=language ? 128'h4b3196b1202020202020202020202020 : 128'h4b312050524550202020202020202020; // K1准备 / K1 PREP
            L_K1_RUN: l=language ? 128'h4b31c3b5202020202020202020202020 : 128'h4b312052554e20202020202020202020; // K1开始 / K1 RUN
            L_MEASURE: l=language ? 128'h85abf060202020202020202020202020 : 128'h4d454153555245202020202020202020; // 仪器测量 / MEASURE
            L_K8_STOP: l=language ? 128'h4b386869202020202020202020202020 : 128'h4b382053544f50202020202020202020; // K8静音 / K8 STOP
            default:l=128'h20202020202020202020202020202020;
        endcase end
    endfunction
    localparam [15:0] C_KEYS=16'h15d7;
    localparam [15:0] C_PRESSURE=16'ha19c;
// MISEKI_LABELS_END
 function [31:0] a4;
  input [31:0] chars;
  begin a4=chars;end
 endfunction
 function [127:0] a16;
  input [127:0] chars;
  begin a16=chars;end
 endfunction
 function [7:0] hd;
  input [3:0] n;begin hd=n<10 ? 8'h30+n : 8'h41+n-10;end
 endfunction
 function [15:0] dec2;
  input [6:0] n;reg [6:0] u;reg [3:0] t;
  begin
   if(n>=60)begin t=6;u=n-60;end else if(n>=50)begin t=5;u=n-50;end
   else if(n>=40)begin t=4;u=n-40;end else if(n>=30)begin t=3;u=n-30;end
   else if(n>=20)begin t=2;u=n-20;end else if(n>=10)begin t=1;u=n-10;end
   else begin t=0;u=n;end dec2={hd(t),hd(u[3:0])};
  end
 endfunction
 function [31:0] pct;
  input [4:0] n;reg [31:0] chars;
  begin case(n)
   0:chars="  0%";1:chars="  6%";2:chars=" 13%";3:chars=" 19%";
   4:chars=" 25%";5:chars=" 31%";6:chars=" 38%";7:chars=" 44%";
   8:chars=" 50%";9:chars=" 56%";10:chars=" 63%";11:chars=" 69%";
   12:chars=" 75%";13:chars=" 81%";14:chars=" 88%";15:chars=" 94%";
   16:chars="100%";default:chars="RAW?";
  endcase pct=a4(chars);end
 endfunction
 function [31:0] tone;
  input [15:0] n;
  begin case(n)0:tone=w(W_SINE);1:tone=w(W_PULSE);2:tone=w(W_ORGAN);3:tone=w(W_REED);default:tone=a4("RAW?");endcase end
 endfunction
 function [31:0] onoff;
  input enabled;begin onoff=enabled ? w(W_YES):w(W_OFF);end
 endfunction
 function [31:0] value;
  input [3:0] id;input [15:0] raw;
  reg [8:0] mag;reg [15:0] steps;
  begin
   value=a4("RAW?");mag=raw[15] ? (~raw+16'd1):raw;steps=dec2({2'd0,mag[8:4]});
   case(id)
    0,1,3:case(raw)
     0:value=w(W_ZERO);8192:value=w(W_VF);2048:value=w(W_FAST);512:value=w(W_MF);
     128:value=w(W_MED);32:value=w(W_MS);8:value=w(W_SLOW);2:value=w(W_VS);
    endcase
    2:if(raw==16'hffff)value=pct(16);else if(raw[11:0]==0)value=pct({1'b0,raw[15:12]});
    4:if($signed(raw)>=-16'sd256&&$signed(raw)<=16'sd256&&raw[3:0]==0)
       value=a4({raw[15]?8'h2d:8'h2b,steps,8'h20});
    5:value=tone(raw);
    6:case(raw)0:value=w(W_HOLD);1:value=w(W_PLUCK);endcase
    7:case(raw)0:value=w(W_OFF);1:value=w(W_VOLUME);2:value=w(W_PITCH);endcase
    8,13:if(raw<=16)value=pct(raw[4:0]);
    9:if(raw>=1&&raw<=8)value=a4({hd(raw[3:0]),"HZ "});
    10:if(raw<=64)value=a4({dec2(raw[6:0])," U"});
    11:case(raw)0:value=w(W_OFF);1:value=w(W_YES);endcase
    12:case(raw)
     2048:value=a4("  41");4096:value=a4("  83");6144:value=a4(" 125");8192:value=a4(" 167");
     10240:value=a4(" 209");12288:value=a4(" 251");14336:value=a4(" 293");16383:value=a4(" 335");
    endcase
   endcase
  end
 endfunction
 function [127:0] title;
  input [3:0] n;
  begin case(n)
   0:title=l(L_PLAY);1:title=l(L_ADSR);2:title=l(L_MOD);3:title=l(L_DELAY);
   4:title=l(L_INPUT);5:title=l(L_LASER);6:title=l(L_MIX);7:title=l(L_PRESETS);
   8:title=l(L_SYSTEM);10:title=l(L_TEST);default:title=l(L_DIRECTORY);
  endcase end
 endfunction
 function [3:0] ui_field;
  input [3:0] view;input [1:0] slot;
  begin
   ui_field=15;
   case(view)
    0:case(slot)0:ui_field=5;1:ui_field=6;2:ui_field=8;3:ui_field=7;endcase
    1:ui_field={2'd0,slot};
    2:case(slot)0:ui_field=9;1:ui_field=10;3:ui_field=4;endcase
    3:case(slot)0:ui_field=11;1:ui_field=12;2:ui_field=13;endcase
    4:if(slot==0)ui_field=7;
   endcase
  end
 endfunction
 function [7:0] field_label;
  input [3:0] id;
  begin case(id)
   0:field_label=W_ATK;1:field_label=W_DEC;2:field_label=W_SUS;3:field_label=W_REL;
   4:field_label=W_BEND;5:field_label=W_TONE;6:field_label=W_MODE;7:field_label=W_FSR;
   8:field_label=W_VOL;9:field_label=W_RATE;10:field_label=W_MAX;11:field_label=W_ON;
   12:field_label=W_TIME;13:field_label=W_WET;default:field_label=W_ERROR;
  endcase end
 endfunction
 wire [1:0] eff_func=laser_dirty[0]?laser_draft[1:0]:laser_function;
 wire [1:0] eff_mode=laser_dirty[1]?laser_draft[3:2]:laser_mode;
 wire [1:0] eff_a=laser_dirty[2]?laser_draft[5:4]:timbre_a;
 wire [1:0] eff_b=laser_dirty[3]?laser_draft[7:6]:timbre_b;
 wire eff_mix=mix_dirty?mix_draft:mix_enabled;
 function [31:0] polarity;
  input [1:0] mode;
  begin case(mode)0:polarity=w(W_OFF);1:polarity=w(W_HIGH);2:polarity=w(W_LOW);default:polarity=a4("RAW?");endcase end
 endfunction
 function [31:0] laser_func;
  input [1:0] mode;
  begin case(mode)0:laser_func=w(W_PLUCK);1:laser_func=w(W_TIMBRE);2:laser_func=w(W_FX);default:laser_func=a4("RAW?");endcase end
 endfunction
 function [31:0] diagnostic_status;
  input [2:0] status;
  begin case(status)
   0:diagnostic_status=w(W_IDLE);1:diagnostic_status=w(W_PREP);
   2:diagnostic_status=w(W_READY);3:diagnostic_status=w(W_RUN);
   4:diagnostic_status=w(W_DONE);5:diagnostic_status=w(W_RESTORE);
   default:diagnostic_status=w(W_ERROR);
  endcase end
 endfunction
 reg [6:0] column_q;
 reg [31:0] slot_label,slot_value;
 reg [3:0] slot_id;
 reg [3:0] slot_id_q;
 reg [15:0] slot_raw_q;
 reg [31:0] slot_label_q,slot_value_q;
 reg slot_dirty_q,slot_enabled_q;
 reg slot_dirty,slot_enabled;
 wire [1:0] slot=column_q[6:5];
 always @* begin
  slot_id=ui_field(screen,slot);
  slot_label=slot_id_q<14?w(field_label(slot_id_q)):a4("    ");
  slot_value=slot_id_q<14?value(slot_id_q,slot_raw_q):a4("    ");
  slot_dirty=slot_id_q<14?dirty[slot_id_q]:1'b0;slot_enabled=slot_id_q<14;
  case(screen)
   2:if(slot==2)begin slot_label=w(W_LIVE);slot_value=pct(mod_level);slot_enabled=1;end
   3:if(slot==3)begin slot_label=w(W_OUT);slot_value=mix_enabled?w(W_FX):w(W_DRY);end
   4:case(slot)
    1:begin slot_label=w(W_RX);slot_value=polarity(laser_mode);end
    2:begin slot_label=w(W_FSR);slot_value=a4({"X",hd(pressure_level[11:8]),hd(pressure_level[7:4]),hd(pressure_level[3:0])});end
    3:begin slot_label=w(W_KEYS);slot_value=a4({" ",dec2({1'b0,active_count})," "});end
   endcase
   5:begin
    case(slot)
     0:begin slot_label=w(W_FUNC);slot_value=laser_func(eff_func);end
     1:begin slot_label=w(W_RX);slot_value=polarity(eff_mode);end
     2:begin slot_label=w(W_AB_A);slot_value=eff_func==2?w(W_FX):tone({14'd0,eff_a});end
     3:begin slot_label=w(W_AB_B);slot_value=eff_func==2?w(W_DRY):tone({14'd0,eff_b});end
    endcase
    slot_dirty=laser_dirty[slot];slot_enabled=eff_func!=2||slot<2;
   end
   6:begin
    case(slot)
     0:begin slot_label=w(W_MIX);slot_value=onoff(eff_mix);end
     1:begin slot_label=w(W_OUT);slot_value=onoff(mix_enabled);end
     2:begin slot_label=w(W_KEYS);slot_value=a4({" ",dec2({1'b0,active_count})," "});end
     3:begin slot_label=w(W_MODE);slot_value=value(6,drafts[6*16+:16]);end
    endcase
    slot_dirty=slot==0&&mix_dirty;slot_enabled=slot==0;
   end
   7:begin
    slot_label=a4({" ",hd({2'd0,slot}+1'b1),"  "});slot_value=w(preset_valid[slot]?W_SAVED:W_EMPTY);
    slot_dirty=0;slot_enabled=0;
   end
   8:begin
    case(slot)
     0:begin slot_label=w(W_LANG);slot_value=language_preview?a4(" CN "):a4(" EN ");end
     1:begin slot_label=w(W_HEALTH);slot_value=w(healthy?W_READY:W_ERROR);end
     2:begin slot_label=w(W_MUTE);slot_value=onoff(mute);end
     3:begin slot_label=w(W_APPLY);slot_value=w(fault?W_ERROR:busy?W_WAIT:W_READY);end
    endcase
    slot_dirty=slot==0&&language_dirty;slot_enabled=slot==0;
   end
   10:begin
    case(slot)
     0:begin slot_label=w(W_TEST_ITEM);slot_value=w(diag_selection==0?W_TEST_32:diag_selection==1?W_TEST_FS:W_TEST_LATENCY);end
     1:begin slot_label=w(W_TEST_STATE);slot_value=diagnostic_status(diag_status);end
     2:begin slot_label=w(W_VOICES);slot_value=a4({" ",dec2({1'b0,active_count})," "});end
     3:begin
      slot_label=w(diag_selection==0?W_TEST_INDEX:diag_selection==2?W_RX:W_TEST_ERRORS);
      if(diag_selection==0)slot_value=diag_status==3?a4({" ",dec2({2'b0,diag_index}+7'd1)," "}):a4(" -- ");
      else if(diag_selection==2)slot_value=w(!laser_level_valid?W_WAIT:laser_blocked?W_BLOCK:W_LIGHT);
      else slot_value=a4({" ",hd(diag_errors[7:4]),hd(diag_errors[3:0])," "});
     end
    endcase
    slot_dirty=0;slot_enabled=slot==0&&diag_status==0;
   end
  endcase
 end
 // All coordinates are native OLED pixels copied from the approved HTML.
 // A byte may contain the tail of one text line and the start of another.
 // Seven sequential layers share one font port.
 function [31:0] compact;
  input [31:0] t;
  begin
   if(t[31:8]==24'h202020)compact={t[7:0],24'h202020};
   else if(t[31:16]==16'h2020)compact={t[15:0],16'h2020};
   else if(t[31:24]==8'h20)compact={t[23:0],8'h20};else compact=t;
  end
 endfunction
 function [2:0] text_length;
  input [31:0] t;
  begin
   if(t[7:0]!=8'h20)text_length=4;
   else if(t[15:8]!=8'h20)text_length=3;
   else if(t[23:16]!=8'h20)text_length=2;
   else if(t[31:24]!=8'h20)text_length=1;else text_length=0;
  end
 endfunction
 function [4:0] duration_length;
  input [15:0] raw;
  begin case(raw)
   0:duration_length=1;8192:duration_length=4;2048:duration_length=7;
   512:duration_length=10;128:duration_length=13;32:duration_length=16;
   8:duration_length=19;default:duration_length=22;
  endcase end
 endfunction
 reg [3:0] state=0;
 reg [2:0] layer;
 reg [2:0] page_q;
 reg [7:0] accumulator;
 reg [127:0] row,row_q,details;
 reg [127:0] title_q,details_q;
 reg [3:0] dirty_count;integer dirty_index;
 always @* begin
  dirty_count=0;
  for(dirty_index=0;dirty_index<14;dirty_index=dirty_index+1)dirty_count=dirty_count+dirty[dirty_index];
  for(dirty_index=0;dirty_index<4;dirty_index=dirty_index+1)dirty_count=dirty_count+laser_dirty[dirty_index];
  dirty_count=dirty_count+language_dirty+mix_dirty;
 end
 reg [31:0] piece;
 reg [2:0] piece_length;
 reg [7:0] origin_x,origin_x_q;
 reg [5:0] origin_y,origin_y_q;
 reg text_inverse,text_inverse_q;
 reg [7:0] codepoint_q;
 reg [2:0] glyph_column_q;
 reg [7:0] text_offset;
 reg [15:0] shifted_glyph;
 reg [7:0] glyph_byte;
 reg [3:0] menu_start,menu_item;
 reg [127:0] menu_title;
 reg [15:0] bend_raw;
 reg [8:0] bend_mag;
 reg [23:0] fraction;
 wire [7:0] glyph;
 // Keep the font lookup and pixel alignment on separate clock paths.
 reg [7:0] glyph_q;
 miseki_font_v1 font(.codepoint(codepoint_q),.column(glyph_column_q),.data(glyph));
 always @* begin
  menu_start=menu_selection<3?0:menu_selection>7?5:menu_selection-2;
  menu_item=menu_start+layer-1'b1;menu_title=title(menu_item==9?4'd10:menu_item);
  bend_raw=drafts[4*16+:16];bend_mag=bend_raw[15]?(~bend_raw+16'd1):bend_raw;
  case(bend_mag[6:4])0:fraction="000";1:fraction="125";2:fraction="250";3:fraction="375";
   4:fraction="500";5:fraction="625";6:fraction="750";default:fraction="875";endcase
  details=a16("                ");
  case(screen)
   2:case(focus)
    0:details=a16({"RATE ",hd(drafts[9*16+:4])," HZ       "});
    1:details=a16({"DEPTH ",dec2(drafts[10*16+:7]),"/128 ST "});
    2:details=l(L_LIVE);
    3:details=a16({"BEND ",bend_raw[15]?8'h2d:8'h2b,hd({2'd0,bend_mag[8:7]}),".",fraction," ST  "});
   endcase
   3:details=drafts[11*16+:16]!=0?l(L_NOMINAL):a16("BYPASSED        ");
   4:details=l(L_BLOCK);
   5:details=l(eff_func==0?L_LASER_PLUCK:eff_func==1?L_LASER_AB:L_LASER_FX);
   6:details=l(eff_mix?L_MIX_ON:L_MIX_OFF);
   8:details=l(L_RAM);
   10:begin
    case(diag_selection)
     0:details=a16({"SINE 48-79 E=",hd(diag_errors[7:4]),hd(diag_errors[3:0])," "});
     1:details=a16("NOM 48828.125HZ ");
     default:details=l(L_TEST_RX);
    endcase
   end
  endcase
  row=a16("                ");origin_x=2;origin_y=0;text_inverse=0;
  piece=compact(layer==1?slot_label_q:slot_value_q);piece_length=text_length(piece);
  case(layer)
   0:begin
    row=title_q;
    if(screen==7&&preset_pending)row=language?l(L_CONFIRM_TITLE):a16("CONFIRM         ");
    if(column_q>=((mute||fault)?95:busy?119:screen==7&&!editing?103:111))begin
     origin_x=(mute||fault)?95:busy?119:screen==7&&!editing?103:111;
     row=mute?a16("STOP            "):fault?a16("ERR             "):busy?a16("?               "):editing?a16({"*",hd(dirty_count),"              "}):screen==7?a16("RAM             "):a16("OK              ");
     text_inverse=mute||busy||editing;
    end
   end
   1,2:begin
    origin_x={1'b0,column_q[6:5],5'd0}+((4-piece_length)<<2);
    origin_y=layer==1?11:23;
    row={piece,{12{8'h20}}};
    text_inverse=layer==1&&slot_enabled_q&&focus==column_q[6:5];
    if(screen==7)begin
     origin_y=layer==1?12:28;text_inverse=layer==1&&preset_slot==column_q[6:5];
     if(preset_pending)begin
      text_inverse=0;origin_x=2;origin_y=layer==1?15:29;
      row=layer==1?{w(preset_save?W_SAVE:W_LOAD),a4({" ",hd({2'd0,preset_slot}+1'b1),"  "}),{8{8'h20}}}:l(preset_save?(preset_valid[preset_slot]?L_REPLACE:L_SAVE):L_LOAD);
     end
    end
   end
   3:begin
    origin_y=34;row=details_q;
    if(screen==0)row=language?{C_KEYS,a4({dec2({1'b0,active_count}),"  "}),{10{8'h20}}}:a16({"KEYS",dec2({1'b0,active_count}),"          "});
    if(screen==1||screen==7)row=a16("                ");
   end
   4:begin
    origin_y=45;
    case(screen)
     0:row=language?{C_PRESSURE,compact(pct({1'b0,pressure_level[11:8]})),{10{8'h20}}}:{a4("FSR "),compact(pct({1'b0,pressure_level[11:8]})),{8{8'h20}}};
     4:row=pressure_valid?l(L_HELP):l(L_FAULT);
     5:row=laser_busy?l(L_BUSY):laser_mode==0?{w(W_RX),w(W_OFF),{8{8'h20}}}:l(L_LASER_AB);
     6:row=l(L_HELP);
     7:begin row={w(preset_save?W_SAVE:W_LOAD),a4({" ",hd({2'd0,preset_slot}+1'b1),"  "}),{8{8'h20}}};
      if(preset_pending)begin origin_y=43;row=l(L_RAM);end
     end
     8:row=a16("EVENT REFRESH   ");
     10:begin
      case(diag_status)
       0:row=l(L_TEST_IDLE);1:row=l(L_TEST_WAIT);4:row=l(L_TEST_DONE);
       5:row=l(L_TEST_RESTORE);6,7:row=l(L_TEST_FAULT);
       default:begin
        if(diag_selection==1)row=l(L_TEST_PROBE);
        else if(diag_selection==2)row=l(L_TEST_FIXED);
        else if(diag_status==2)row=l(L_TEST_READY);
        else case(diag_state)
         3:row=l(L_TEST_FILL);4:row=l(L_TEST_HOLD);
         5:row=l(L_TEST_RELEASE);6:row=l(L_TEST_DRAIN);
         default:row=l(L_TEST_WAIT);
        endcase
       end
      endcase
     end
    endcase
   end
   6:begin
    origin_y=57;
    row=language?l(L_K1_APPLY):a16("K1 APPLY        ");
    if(screen==9)row=language?l(L_K1_OPEN):a16("K1 OPEN         ");
    if(preset_pending)row=language?l(L_K1_YES):a16("K1 YES          ");
    if(screen==10)begin
     case(diag_status)
      0:row=l(L_K1_PREP);
      2:row=l(diag_selection==0?L_K1_RUN:L_MEASURE);
      3:row=l(L_K8_STOP);
      4:row=a16("                ");
      default:row={w(W_WAIT),{12{8'h20}}};
     endcase
    end
    if(column_q>=(language?95:71))begin
     origin_x=language?95:71;
     row=language?(editing?l(L_K2_UNDO):l(L_K2_BACK)):editing?a16("K2 UNDO         "):a16("K2 BACK         ");
     if(preset_pending)begin origin_x=language?95:87;row=language?l(L_K2_NO):a16("K2 NO           ");end
    end
   end
  endcase
  if(screen==9&&layer>=1&&layer<=5)begin
   case(layer)1:origin_y=11;2:origin_y=20;3:origin_y=29;4:origin_y=38;default:origin_y=47;endcase
   origin_x=19;row=menu_title;
   text_inverse=menu_item==menu_selection;
   if(column_q<18)begin origin_x=2;row=menu_item==9?{"10",{14{8'h20}}}:{hd(menu_item+1'b1),{15{8'h20}}};end
  end
  if(screen==10&&layer==0&&!mute&&!fault&&!busy)begin
   row=title_q;text_inverse=0;
   if(column_q>=95)begin origin_x=95;row=a16("DIAG            ");end
  end
  if(screen!=9&&layer==5)row=a16("                ");
  text_offset={1'b0,column_q}-origin_x_q;
  shifted_glyph={8'd0,glyph_q}<<origin_y_q[2:0];
  if(page_q==origin_y_q[5:3])glyph_byte=shifted_glyph[7:0];
  else if({1'b0,page_q}=={1'b0,origin_y_q[5:3]}+1'b1)glyph_byte=shifted_glyph[15:8];
  else glyph_byte=0;
 end
 // Static 53x18 icon, sampled once from the approved HTML wave() function.
 // It is a font-like display asset.
 function [17:0] wave_column;
  input [1:0] timbre;input [5:0] x;
  begin case({timbre,x})
   8'd0:wave_column=18'h00200;
   8'd1:wave_column=18'h00180;
   8'd2:wave_column=18'h00060;
   8'd3:wave_column=18'h00010;
   8'd4:wave_column=18'h00208;
   8'd5:wave_column=18'h00004;
   8'd6:wave_column=18'h00002;
   8'd7:wave_column=18'h00002;
   8'd8:wave_column=18'h00202;
   8'd9:wave_column=18'h00004;
   8'd10:wave_column=18'h00008;
   8'd11:wave_column=18'h00030;
   8'd12:wave_column=18'h002c0;
   8'd13:wave_column=18'h00300;
   8'd14:wave_column=18'h00400;
   8'd15:wave_column=18'h01800;
   8'd16:wave_column=18'h06200;
   8'd17:wave_column=18'h08000;
   8'd18:wave_column=18'h10000;
   8'd19:wave_column=18'h20000;
   8'd20:wave_column=18'h20200;
   8'd21:wave_column=18'h20000;
   8'd22:wave_column=18'h10000;
   8'd23:wave_column=18'h08000;
   8'd24:wave_column=18'h06200;
   8'd25:wave_column=18'h01000;
   8'd26:wave_column=18'h00c00;
   8'd27:wave_column=18'h00300;
   8'd28:wave_column=18'h002c0;
   8'd29:wave_column=18'h00020;
   8'd30:wave_column=18'h00018;
   8'd31:wave_column=18'h00004;
   8'd32:wave_column=18'h00202;
   8'd33:wave_column=18'h00002;
   8'd34:wave_column=18'h00002;
   8'd35:wave_column=18'h00004;
   8'd36:wave_column=18'h00208;
   8'd37:wave_column=18'h00010;
   8'd38:wave_column=18'h00060;
   8'd39:wave_column=18'h00180;
   8'd40:wave_column=18'h00200;
   8'd41:wave_column=18'h00c00;
   8'd42:wave_column=18'h03000;
   8'd43:wave_column=18'h0c000;
   8'd44:wave_column=18'h10200;
   8'd45:wave_column=18'h20000;
   8'd46:wave_column=18'h20000;
   8'd47:wave_column=18'h20000;
   8'd48:wave_column=18'h10200;
   8'd49:wave_column=18'h08000;
   8'd50:wave_column=18'h04000;
   8'd51:wave_column=18'h02000;
   8'd52:wave_column=18'h01a00;
   8'd64:wave_column=18'h00202;
   8'd65:wave_column=18'h00002;
   8'd66:wave_column=18'h00002;
   8'd67:wave_column=18'h00002;
   8'd68:wave_column=18'h00202;
   8'd69:wave_column=18'h00002;
   8'd70:wave_column=18'h00002;
   8'd71:wave_column=18'h00002;
   8'd72:wave_column=18'h00202;
   8'd73:wave_column=18'h00002;
   8'd74:wave_column=18'h00002;
   8'd75:wave_column=18'h00002;
   8'd76:wave_column=18'h00202;
   8'd77:wave_column=18'h001fe;
   8'd78:wave_column=18'h3fe00;
   8'd79:wave_column=18'h20000;
   8'd80:wave_column=18'h20200;
   8'd81:wave_column=18'h20000;
   8'd82:wave_column=18'h20000;
   8'd83:wave_column=18'h20000;
   8'd84:wave_column=18'h20200;
   8'd85:wave_column=18'h20000;
   8'd86:wave_column=18'h20000;
   8'd87:wave_column=18'h20000;
   8'd88:wave_column=18'h20200;
   8'd89:wave_column=18'h20000;
   8'd90:wave_column=18'h3fc00;
   8'd91:wave_column=18'h003fe;
   8'd92:wave_column=18'h00202;
   8'd93:wave_column=18'h00002;
   8'd94:wave_column=18'h00002;
   8'd95:wave_column=18'h00002;
   8'd96:wave_column=18'h00202;
   8'd97:wave_column=18'h00002;
   8'd98:wave_column=18'h00002;
   8'd99:wave_column=18'h00002;
   8'd100:wave_column=18'h00202;
   8'd101:wave_column=18'h00002;
   8'd102:wave_column=18'h00002;
   8'd103:wave_column=18'h001fe;
   8'd104:wave_column=18'h3fe00;
   8'd105:wave_column=18'h20000;
   8'd106:wave_column=18'h20000;
   8'd107:wave_column=18'h20000;
   8'd108:wave_column=18'h20200;
   8'd109:wave_column=18'h20000;
   8'd110:wave_column=18'h20000;
   8'd111:wave_column=18'h20000;
   8'd112:wave_column=18'h20200;
   8'd113:wave_column=18'h20000;
   8'd114:wave_column=18'h20000;
   8'd115:wave_column=18'h20000;
   8'd116:wave_column=18'h20200;
   8'd128:wave_column=18'h00200;
   8'd129:wave_column=18'h00180;
   8'd130:wave_column=18'h00060;
   8'd131:wave_column=18'h00018;
   8'd132:wave_column=18'h00204;
   8'd133:wave_column=18'h00004;
   8'd134:wave_column=18'h00008;
   8'd135:wave_column=18'h00010;
   8'd136:wave_column=18'h00220;
   8'd137:wave_column=18'h00040;
   8'd138:wave_column=18'h00080;
   8'd139:wave_column=18'h00100;
   8'd140:wave_column=18'h00200;
   8'd141:wave_column=18'h00200;
   8'd142:wave_column=18'h00200;
   8'd143:wave_column=18'h00400;
   8'd144:wave_column=18'h00600;
   8'd145:wave_column=18'h00800;
   8'd146:wave_column=18'h01000;
   8'd147:wave_column=18'h06000;
   8'd148:wave_column=18'h08200;
   8'd149:wave_column=18'h10000;
   8'd150:wave_column=18'h10000;
   8'd151:wave_column=18'h08000;
   8'd152:wave_column=18'h04200;
   8'd153:wave_column=18'h03000;
   8'd154:wave_column=18'h00c00;
   8'd155:wave_column=18'h00300;
   8'd156:wave_column=18'h002c0;
   8'd157:wave_column=18'h00030;
   8'd158:wave_column=18'h00008;
   8'd159:wave_column=18'h00004;
   8'd160:wave_column=18'h00204;
   8'd161:wave_column=18'h00008;
   8'd162:wave_column=18'h00010;
   8'd163:wave_column=18'h00060;
   8'd164:wave_column=18'h00280;
   8'd165:wave_column=18'h00100;
   8'd166:wave_column=18'h00100;
   8'd167:wave_column=18'h00200;
   8'd168:wave_column=18'h00200;
   8'd169:wave_column=18'h00200;
   8'd170:wave_column=18'h00400;
   8'd171:wave_column=18'h00800;
   8'd172:wave_column=18'h01200;
   8'd173:wave_column=18'h02000;
   8'd174:wave_column=18'h04000;
   8'd175:wave_column=18'h08000;
   8'd176:wave_column=18'h10200;
   8'd177:wave_column=18'h10000;
   8'd178:wave_column=18'h08000;
   8'd179:wave_column=18'h06000;
   8'd180:wave_column=18'h01a00;
   8'd192:wave_column=18'h00300;
   8'd193:wave_column=18'h000c0;
   8'd194:wave_column=18'h00030;
   8'd195:wave_column=18'h00008;
   8'd196:wave_column=18'h00208;
   8'd197:wave_column=18'h00010;
   8'd198:wave_column=18'h00020;
   8'd199:wave_column=18'h00020;
   8'd200:wave_column=18'h00210;
   8'd201:wave_column=18'h00010;
   8'd202:wave_column=18'h00008;
   8'd203:wave_column=18'h00010;
   8'd204:wave_column=18'h00260;
   8'd205:wave_column=18'h00380;
   8'd206:wave_column=18'h00c00;
   8'd207:wave_column=18'h03000;
   8'd208:wave_column=18'h04200;
   8'd209:wave_column=18'h08000;
   8'd210:wave_column=18'h04000;
   8'd211:wave_column=18'h04000;
   8'd212:wave_column=18'h02200;
   8'd213:wave_column=18'h04000;
   8'd214:wave_column=18'h04000;
   8'd215:wave_column=18'h08000;
   8'd216:wave_column=18'h04200;
   8'd217:wave_column=18'h03000;
   8'd218:wave_column=18'h00c00;
   8'd219:wave_column=18'h00380;
   8'd220:wave_column=18'h00260;
   8'd221:wave_column=18'h00010;
   8'd222:wave_column=18'h00008;
   8'd223:wave_column=18'h00010;
   8'd224:wave_column=18'h00210;
   8'd225:wave_column=18'h00020;
   8'd226:wave_column=18'h00010;
   8'd227:wave_column=18'h00010;
   8'd228:wave_column=18'h00208;
   8'd229:wave_column=18'h00010;
   8'd230:wave_column=18'h00020;
   8'd231:wave_column=18'h001c0;
   8'd232:wave_column=18'h00600;
   8'd233:wave_column=18'h01800;
   8'd234:wave_column=18'h06000;
   8'd235:wave_column=18'h08000;
   8'd236:wave_column=18'h04200;
   8'd237:wave_column=18'h04000;
   8'd238:wave_column=18'h02000;
   8'd239:wave_column=18'h02000;
   8'd240:wave_column=18'h04200;
   8'd241:wave_column=18'h08000;
   8'd242:wave_column=18'h08000;
   8'd243:wave_column=18'h04000;
   8'd244:wave_column=18'h03200;
   default:wave_column=0;endcase end
 endfunction
 // Decorations are masks at native coordinates.
 reg [7:0] decoration;
 (* syn_romstyle="logic" *) wire [23:0] wave_bits={6'd0,wave_column(drafts[5*16+:2],column_q-7'd72)}<<2;
 reg [5:0] menu_highlight_y,scroll_y;
 always @* begin
  case(menu_selection-menu_start)0:menu_highlight_y=10;1:menu_highlight_y=19;2:menu_highlight_y=28;3:menu_highlight_y=37;default:menu_highlight_y=46;endcase
  case(menu_start)0:scroll_y=11;1:scroll_y=15;2:scroll_y=19;3:scroll_y=23;4:scroll_y=27;default:scroll_y=31;endcase
 end
 integer bit_index;
 reg [5:0] y;
 always @* begin
  decoration=0;
  for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin
   y={page_q,3'b000}+bit_index;
   if(y==8||y==55)decoration[bit_index]=1;
   if(screen!=9&&!(screen==7&&preset_pending))begin
    if(y==31&&screen!=7)decoration[bit_index]=1;
    if(column_q[4:0]==31&&column_q!=127&&y>=20&&y<=22&&screen!=7)decoration[bit_index]=1;
    if(y>=10&&y<=19&&slot_enabled_q&&focus==column_q[6:5])decoration[bit_index]=1;
    if(y==21&&slot_dirty_q&&column_q[4:0]>=4&&column_q[4:0]<=27)decoration[bit_index]=1;
    if(screen==7)begin
     if(y>=11&&y<=20&&preset_slot==column_q[6:5])decoration[bit_index]=1;
     if(column_q[4:0]==31&&column_q!=127&&y>=23&&y<=25)decoration[bit_index]=1;
    end
   end
   if(screen==0&&column_q>=72&&column_q<=124&&y>=34&&y<=51&&wave_bits[y-32])decoration[bit_index]=1;
   if(y<8&&(mute||busy||editing)&&column_q>=((mute||fault)?94:busy?118:110))decoration[bit_index]=1;
   if(screen==9)begin
    if(column_q<124&&y>=menu_highlight_y&&y<menu_highlight_y+9)decoration[bit_index]=1;
    if(column_q==126&&y>=11&&y<=53&&(y==11||y==14||y==17||y==20||y==23||y==26||y==29||y==32||y==35||y==38||y==41||y==44||y==47||y==50||y==53||y>=scroll_y&&y<scroll_y+23))decoration[bit_index]=1;
   end
  end
 end
 // Static curve coordinates are calculated by a small, shared unsigned divider.
 // The divider and Bresenham walker run only while servicing an OLED byte.
 reg [1:0] boundary,segment;
 reg [6:0] ax,dx,rx;
 reg [6:0] length_a,length_d,length_r,total_length;
 reg [6:0] divisor,remainder,quotient;
 reg [13:0] dividend;
 reg [3:0] divide_bit;
 reg [7:0] trial;
 reg [6:0] quotient_next;
 reg [6:0] rounded;
 reg [6:0] line_x,line_end_x;
 reg [5:0] line_y,line_end_y,hold_y;
 reg signed [8:0] line_error;
 reg [6:0] delta_x,delta_y;
 reg direction_y;
 reg signed [9:0] doubled_error;
 reg [7:0] point_mask;
 always @* begin
  trial={remainder,dividend[13]};
  quotient_next={quotient[5:0],trial>={1'b0,divisor}};
  rounded=quotient_next+((trial>={1'b0,divisor}?trial-divisor:trial)*2>={1'b0,divisor});
  doubled_error=$signed(line_error)*2;
  point_mask=page_q==line_y[5:3]?(8'b1<<line_y[2:0]):8'd0;
  if(segment==focus||line_x==line_end_x&&line_y==line_end_y||line_x==3&&line_y==52)begin
   if({page_q,3'b000}<=line_y+1'b1&&{page_q,3'b000}+7>=line_y+1'b1)point_mask=point_mask|(8'b1<<((line_y+1'b1)&7));
  end
 end
 always @(posedge clk)begin
  valid<=0;
  if(reset)begin state<=0;data<=0;accumulator<=0;end
  else case(state)
   0:if(request)begin
    page_q<=page;column_q<=column;layer<=0;state<=1;accumulator<=0;
    title_q<=title(screen);details_q<=details;
   end
   // Field selection, formatting, and pixel layout are separate display clocks.
   // The immutable OLED snapshot stays fixed for the complete request.
   1:begin slot_id_q<=slot_id;slot_raw_q<=drafts[slot_id*16+:16];state<=9;end
   9:begin
    slot_label_q<=slot_label;slot_value_q<=slot_value;
    slot_dirty_q<=slot_dirty;slot_enabled_q<=slot_enabled;state<=10;
   end
   10:begin row_q<=row;origin_x_q<=origin_x;origin_y_q<=origin_y;text_inverse_q<=text_inverse;state<=2;end
   2:begin
    codepoint_q<=text_offset<128?row_q[127-text_offset[6:3]*8 -:8]:8'h20;
    glyph_column_q<=text_offset[2:0];state<=3;
   end
   3:begin glyph_q<=glyph;state<=8;end
   8:begin
    if(layer==0)accumulator<=text_inverse_q?(decoration^glyph_byte):(decoration|glyph_byte);
    else accumulator<=text_inverse_q?(accumulator^glyph_byte):(accumulator|glyph_byte);
    if(layer==6)begin
     if(screen==1)begin
      length_a<=duration_length(drafts[0*16+:16]);length_d<=duration_length(drafts[1*16+:16]);length_r<=duration_length(drafts[3*16+:16]);
      total_length<=duration_length(drafts[0*16+:16])+duration_length(drafts[1*16+:16])+duration_length(drafts[3*16+:16])+24;
      hold_y<=52-({1'b0,drafts[2*16+12+:4]}+{1'b0,drafts[2*16+12+:4],3'b0}+3)/8;
      if(drafts[2*16+:16]==16'hffff)hold_y<=34;
      boundary<=0;state<=4;
     end else begin data<=text_inverse_q?(accumulator^glyph_byte):(accumulator|glyph_byte);valid<=1;state<=0;end
    end else begin layer<=layer+1'b1;state<=1;end
   end
   4:begin
    divisor<=total_length;remainder<=0;quotient<=0;divide_bit<=13;
    case(boundary)
     0:dividend<=({7'd0,length_a}<<7)-({7'd0,length_a}<<2)-({7'd0,length_a}<<1)-length_a;
     1:dividend<=(({7'd0,length_a}+length_d)<<7)-(({7'd0,length_a}+length_d)<<2)-(({7'd0,length_a}+length_d)<<1)-length_a-length_d;
     default:dividend<=(({7'd0,total_length}-length_r)<<7)-(({7'd0,total_length}-length_r)<<2)-(({7'd0,total_length}-length_r)<<1)-total_length+length_r;
    endcase
    state<=5;
   end
   5:begin
    remainder<=trial>={1'b0,divisor}?trial-divisor:trial;
    quotient<=quotient_next;dividend<={dividend[12:0],1'b0};
    if(divide_bit==0)begin
     case(boundary)0:ax<=3+rounded;1:dx<=3+rounded;default:rx<=3+rounded;endcase
     if(boundary==2)begin segment<=0;line_x<=3;line_y<=52;state<=6;end
     else begin boundary<=boundary+1'b1;state<=4;end
    end else divide_bit<=divide_bit-1'b1;
   end
   6:begin
    case(segment)
     0:begin line_end_x<=ax;line_end_y<=34;delta_x<=ax-3;delta_y<=18;direction_y<=0;line_error<=$signed({2'd0,ax})-21;end
     1:begin line_end_x<=dx;line_end_y<=hold_y;delta_x<=dx-ax;delta_y<=hold_y-34;direction_y<=1;line_error<=$signed({2'd0,dx})-$signed({2'd0,ax})-$signed({3'd0,hold_y})+34;end
     2:begin line_end_x<=rx;line_end_y<=hold_y;delta_x<=rx-dx;delta_y<=0;direction_y<=1;line_error<=$signed({2'd0,rx})-$signed({2'd0,dx});end
     3:begin line_end_x<=124;line_end_y<=52;delta_x<=124-rx;delta_y<=52-hold_y;direction_y<=1;line_error<=72-$signed({2'd0,rx})+$signed({3'd0,hold_y});end
    endcase state<=7;
   end
   7:begin
    if(column_q==line_x||(column_q+1'b1==line_x&&(line_x==line_end_x&&line_y==line_end_y||line_x==3&&line_y==52)))accumulator<=accumulator|point_mask;
    if(line_x==line_end_x&&line_y==line_end_y)begin
     if(segment==3)begin data<=accumulator|((column_q==line_x||column_q+1'b1==line_x)?point_mask:8'd0)|(page_q==6&&column_q>=3&&column_q<=125&&column_q[1:0]==3?8'h20:8'h00);valid<=1;state<=0;end
     else begin segment<=segment+1'b1;state<=6;end
    end else begin
     if(doubled_error>=-$signed({3'd0,delta_y}))line_x<=line_x+1'b1;
     if(doubled_error<=$signed({3'd0,delta_x}))line_y<=direction_y?line_y+1'b1:line_y-1'b1;
     if(doubled_error>=-$signed({3'd0,delta_y})&&doubled_error<=$signed({3'd0,delta_x}))line_error<=line_error+$signed({2'd0,delta_x})-$signed({2'd0,delta_y});
     else if(doubled_error>=-$signed({3'd0,delta_y}))line_error<=line_error-$signed({2'd0,delta_y});
     else line_error<=line_error+$signed({2'd0,delta_x});
    end
   end
  endcase
 end
endmodule
