`timescale 1ns/1ps
// Miseki frontend system with remote MASTER, TIMBRE and ADSR ingress through
// the single panel config owner.
// Sensor packets follow the existing independently validated snapshot contract.
// All four lanes have panel actions; the sample clock path stays independent
// of UI state.
module miseki_system_v1 #(
    parameter integer CLK_HZ=50000000,
    parameter integer MIDI_ENABLE=0,
    parameter integer LASER_STABLE_CYCLES=25000,
    parameter integer AB_CYCLES=5000,
    parameter integer BUTTON_CYCLES=250000,
    parameter integer BCLK_HALF_PERIOD=8,
    parameter integer OLED_STARTUP_CYCLES=CLK_HZ/20,
    parameter integer OLED_RETRY_CYCLES=CLK_HZ/10,
    parameter integer OLED_FRAME_GAP_CYCLES=CLK_HZ/20,
    parameter integer OLED_LINE_TIMEOUT_CYCLES=CLK_HZ/100,
    parameter integer DIAG_HOLD_FRAMES=CLK_HZ/128,
    parameter integer DIAG_RELEASE_FRAMES=CLK_HZ/4096
) (
    input wire clk, reset, power_reset,
    input wire remote_valid,
    input wire [4:0] remote_master,
    output wire remote_ready, remote_done,
    output wire [7:0] remote_status,
    output wire [15:0] remote_revision,
    output wire [4:0] remote_value,
    input wire remote_timbre_valid,
    input wire [1:0] remote_timbre,
    output wire remote_timbre_ready, remote_timbre_done,
    output wire [7:0] remote_timbre_status,
    output wire [15:0] remote_timbre_revision,
    output wire [1:0] remote_timbre_value,
    input wire remote_adsr_valid,
    input wire [1:0] remote_adsr_field,
    input wire [4:0] remote_adsr_index,
    output wire remote_adsr_ready, remote_adsr_done,
    output wire [7:0] remote_adsr_status,
    output wire [15:0] remote_adsr_revision,
    output wire [4:0] remote_adsr_value,
    input wire midi_event_valid,
    output wire midi_event_ready,
    input wire [1:0] midi_event_op,
    input wire [15:0] midi_event_id,
    input wire [6:0] midi_event_note, midi_event_velocity,
    output wire midi_result_valid,
    output wire [2:0] midi_result_code,
    output wire [15:0] midi_result_id,
    output wire [19:0] adsr_indices,
    output wire [15:0] adsr_revision,
    input wire laser_raw,
    output wire [1:0] laser_mode,
    output wire laser_level_valid, laser_blocked, laser_ready, laser_event, laser_busy,
    output wire [15:0] laser_triggers, laser_dropped,
    input wire [7:0] encoder_ab, keys_n,
    input wire [111:0] touch_input, pressure_input,
    output wire [3:0] encoder_up, encoder_down,
    output wire [7:0] key_press, key_release, key_held,
    output wire [31:0] invalid_counts,
    output wire [3:0] selected,
    output wire [2:0] ui_view,
    output wire [4:0] master_volume,
    output wire [1:0] preset_slot, preset_notice,
    output wire preset_save, preset_pending,
    output wire [3:0] preset_valid,
    output wire editing, configured, config_fault, config_busy,
    output wire [15:0] draft_value,
    output wire [111:0] config_state,
    output wire [47:0] delay_state, actual_delay_state,
    output wire [7:0] master_smooth_level,
    output wire transaction_cancel,
    output wire [31:0] mod_state,
    output wire [4:0] mod_level, mod_applied_level,
    output wire signed [15:0] mod_offset,
    output wire [15:0] config_revision,
    output wire [1:0] config_error, route_mode,
    output wire signed [15:0] effective_bend,
    output wire sample_ce,
    output wire [11:0] gain,
    output wire armed, healthy, mute,
    output wire [31:0] allocated, voice_gate, active,
    output wire [511:0] slot_ids,
    output wire signed [15:0] audio_sample,
    output wire bclk, lrck, dout,
    inout wire oled_scl, oled_sda,
    output wire oled_online, oled_fault,
    output wire [6:0] oled_address,
    output wire [7:0] oled_errors,
    output wire [3:0] oled_last_error,
    output wire [15:0] oled_frames
);
    panel_inputs_v2 #(.AB_CYCLES(AB_CYCLES), .BUTTON_CYCLES(BUTTON_CYCLES)) panel (
        .clk(clk), .reset(reset), .encoder_ab(encoder_ab), .keys_n(keys_n),
        .encoder_up(encoder_up), .encoder_down(encoder_down),
        .key_press(key_press), .key_release(key_release), .key_held(key_held),
        .invalid_counts(invalid_counts)
    );
    wire cfg_valid, cfg_ready, cfg_applied;
    wire [4:0] panel_master_volume;
    wire [7:0] cfg_id;
    wire [15:0] cfg_value;
    wire panel_remote_ready, panel_remote_timbre_ready, panel_remote_adsr_ready;
    wire laser_editing;
    wire [3:0] screen,menu_selection;
    wire [1:0] focus;wire language,language_preview,language_dirty;
    wire [223:0] ui_drafts;wire [13:0] ui_dirty;
    wire [7:0] laser_drafts;wire [3:0] laser_dirty;
    wire mix_draft,mix_dirty;
    wire [1:0] laser_function, timbre_a, timbre_b, ab_field;
    localparam [2:0] DIAG_IDLE=0,DIAG_PREPARE=1,DIAG_READY=2,
        DIAG_RUNNING=3,DIAG_DONE=4,DIAG_RESTORE=5,DIAG_FAULT=6;
    reg [2:0] diag_status;
    reg [1:0] diag_selection;
    reg diag_quiesce,diag_exit,diag_finishing,diag_profile_applied;
    wire diag_auto;wire [2:0] diag_state;wire [4:0] diag_index;wire [7:0] diag_errors;
    wire diagnostic_active,diagnostic_prepared;
    wire diagnostic_session=diag_status!=DIAG_IDLE;
    wire physical_released=touch_input[91:80]==0;
    wire diagnostic_available=configured&&!config_fault&&!config_busy&&!editing&&
        !laser_editing&&!preset_pending&&healthy&&physical_released&&!key_held[7]&&
        !remote_valid&&!remote_timbre_valid&&!remote_adsr_valid;
    wire diagnostic_begin=diag_status==DIAG_PREPARE&&!diagnostic_active&&
        !config_busy&&!transaction_cancel&&healthy&&armed&&!mute&&active==0&&allocated==0;
    wire diagnostic_restore=diag_status==DIAG_RESTORE&&!transaction_cancel&&
        !diag_quiesce&&active==0&&allocated==0;
    wire diagnostic_start_request=diag_status==DIAG_READY&&
        diag_selection==0&&diagnostic_prepared&&healthy&&armed&&!mute&&
        !config_busy&&key_press==8'h01&&key_held[7:1]==0&&encoder_up==encoder_down;
    reg diagnostic_start;
    wire diagnostic_latency=diag_selection==2&&diag_profile_applied&&
        (diag_status==DIAG_PREPARE||diag_status==DIAG_READY);
    wire diagnostic_override=diagnostic_session&&!diag_finishing;
    wire [1:0] audio_laser_mode=diagnostic_override?
        (diagnostic_latency?(laser_mode==2?2'd2:2'd1):2'd0):laser_mode;
    // Only the diagnostic laser path substitutes a fixed C4 selection. The
    // real packet header/health is retained; physical touch is isolated while
    // testing, and replay resumes only after every electrode releases.
    wire [111:0] audio_touch={touch_input[111:92],
        diagnostic_session?(diagnostic_latency?12'd1:12'd0):touch_input[91:80],touch_input[79:0]};
    wire [7:0] controller_keys=diag_exit?8'h40:diagnostic_session?8'd0:key_press;
    always @(posedge clk)begin
        diag_quiesce<=0;
        // Register the complete RUN command before the frozen event producer.
        // Its blocked/reset path still applies immediate health/STOP priority;
        // UI qualification stays off mute's high-fanout combinational cone.
        diagnostic_start<=0;
        if(reset)begin diag_status<=DIAG_IDLE;diag_selection<=0;diag_quiesce<=0;diag_exit<=0;diag_finishing<=0;diag_profile_applied<=0;diagnostic_start<=0;end
        else if(diagnostic_session&&config_fault)begin diag_status<=DIAG_FAULT;diag_quiesce<=1;end
        else if(diagnostic_session&&diag_status!=DIAG_RESTORE&&diag_status!=DIAG_FAULT&&
            (key_press[1]||key_held[7]||!healthy||screen!=10))begin
            diag_status<=DIAG_RESTORE;diag_quiesce<=1;
        end else case(diag_status)
            DIAG_IDLE:begin
                if(screen!=10)diag_selection<=0;
                else if(key_press==8'h01&&diagnostic_available&&encoder_up==encoder_down)begin
                    diag_status<=DIAG_PREPARE;diag_quiesce<=1;diag_finishing<=0;diag_profile_applied<=0;
                end else if(encoder_up[0]!=encoder_down[0])
                    diag_selection<=encoder_up[0]?(diag_selection==2?0:diag_selection+1'b1):
                        (diag_selection==0?2:diag_selection-1'b1);
            end
            DIAG_PREPARE:begin
                if(diagnostic_prepared)diag_profile_applied<=1;
                // LATENCY enables its producer only after the profile ACK,
                // then waits for the source-change ACK and beam rearming.
                if(diag_profile_applied&&!config_busy&&!transaction_cancel&&armed&&!mute&&
                    (diag_selection!=2||laser_ready))diag_status<=DIAG_READY;
            end
            DIAG_READY:begin
                if(diagnostic_start_request)diagnostic_start<=1;
                if(diagnostic_start)diag_status<=DIAG_RUNNING;
            end
            DIAG_RUNNING:if(diag_auto&&diag_state==7&&allocated==0&&active==0)begin
                diag_status<=DIAG_DONE;diag_quiesce<=1;
            end
            DIAG_RESTORE:if(!diagnostic_active&&!config_busy&&!transaction_cancel&&
                physical_released&&healthy&&!key_held[7]&&!diag_quiesce)begin
                // Restore sidebands first, then retain the navigation request
                // until the controller accepts it after the source-change ACK.
                diag_finishing<=1;
                if(diag_finishing&&armed&&!mute)begin
                    diag_exit<=1;
                    if(screen==9)begin diag_status<=DIAG_IDLE;diag_exit<=0;diag_finishing<=0;end
                end
            end
            default:begin end
        endcase
    end
    // The independent laser-page draft also owns local editing until confirmed
    // or cancelled; a remote request is accepted only after that point.
    assign remote_ready = panel_remote_ready && !laser_editing && !diagnostic_session;
    assign remote_timbre_ready = panel_remote_timbre_ready && !laser_editing && !diagnostic_session && !(laser_mode!=0 && laser_function==1);
    assign remote_adsr_ready = panel_remote_adsr_ready && !laser_editing && !diagnostic_session;
    miseki_panel_config_v1 controller (
        .clk(clk), .reset(reset), .encoder_up(encoder_up), .encoder_down(encoder_down),
        .key_press(controller_keys), .cfg_ready(cfg_ready), .cfg_applied(cfg_applied),
        .diagnostic_begin(diagnostic_begin),.diagnostic_restore(diagnostic_restore),
        .diagnostic_latency_profile(diag_selection==2),
        .diagnostic_active(diagnostic_active),.diagnostic_ready(diagnostic_prepared),
        .remote_valid(remote_valid && remote_ready), .remote_master(remote_master),
        .remote_ready(panel_remote_ready), .remote_done(remote_done),
        .remote_status(remote_status), .remote_revision(remote_revision), .remote_value(remote_value),
        .remote_timbre_valid(remote_timbre_valid && remote_timbre_ready), .remote_timbre(remote_timbre),
        .remote_timbre_ready(panel_remote_timbre_ready), .remote_timbre_done(remote_timbre_done),
        .remote_timbre_status(remote_timbre_status), .remote_timbre_revision(remote_timbre_revision),
        .remote_timbre_value(remote_timbre_value),
        .remote_adsr_valid(remote_adsr_valid && remote_adsr_ready),
        .remote_adsr_field(remote_adsr_field), .remote_adsr_index(remote_adsr_index),
        .remote_adsr_ready(panel_remote_adsr_ready), .remote_adsr_done(remote_adsr_done),
        .remote_adsr_status(remote_adsr_status), .remote_adsr_revision(remote_adsr_revision),
        .remote_adsr_value(remote_adsr_value), .adsr_indices(adsr_indices), .adsr_revision(adsr_revision),
        .cfg_revision(config_revision),
        .cfg_error(config_error), .cfg_state(config_state), .route_mode(route_mode),
        .mod_state(mod_state), .delay_state(delay_state), .transaction_cancel(transaction_cancel), .live_clear(mute), .mod_level(mod_level),
        .cfg_valid(cfg_valid), .cfg_id(cfg_id), .cfg_value(cfg_value),
        .screen(screen), .focus(focus), .language(language), .drafts(ui_drafts), .dirty(ui_dirty),
        .language_preview(language_preview), .language_dirty(language_dirty),
        .menu_selection(menu_selection), .sideband_editing(laser_editing),
        .selected(selected), .editing(editing), .initialized(configured),
        .fault(config_fault), .busy(config_busy), .draft_value(draft_value), .ui_view(ui_view),
        .master_volume(panel_master_volume), .preset_slot(preset_slot), .preset_save(preset_save),
        .preset_pending(preset_pending), .preset_valid(preset_valid), .preset_notice(preset_notice)
    );
    wire [1:0] laser_draft;
    wire [5:0] mix_level;
    wire mix_enabled;
    wire laser_changed;
    miseki_panel_control_v1 laser_control (
        .clk(clk), .reset(reset), .ui_view(ui_view), .screen(screen),
        .encoder_up(encoder_up), .encoder_down(encoder_down), .key_press(key_press),
        .configured(configured), .config_busy(config_busy||diagnostic_session), .config_fault(config_fault),
        .transaction_cancel(transaction_cancel), .stop(key_held[7]),
        .mode(laser_mode), .draft(laser_draft), .editing(laser_editing), .changed(laser_changed),
        .function_mode(laser_function), .timbre_a(timbre_a), .timbre_b(timbre_b),
        .mix_enabled(mix_enabled), .field(ab_field),
        .laser_drafts(laser_drafts), .dirty(laser_dirty), .mix_draft(mix_draft), .mix_dirty(mix_dirty)
    );
    // Dedicated all-notes-off key is level-sensitive. Releasing it requires
    // all touch electrodes to be released before the old engine can re-arm.
    // Test events use the same allocator/voices and sample clock as performance.
    ab_board_audio_v1 #(.CLK_HZ(CLK_HZ), .BCLK_HALF_PERIOD(BCLK_HALF_PERIOD),
        .LASER_STABLE_CYCLES(LASER_STABLE_CYCLES),
        .HOLD_FRAMES(DIAG_HOLD_FRAMES), .RELEASE_FRAMES(DIAG_RELEASE_FRAMES),
        .MIDI_ENABLE(MIDI_ENABLE)) audio (
        .clk(clk), .reset(reset), .power_reset(power_reset),
        .key_pressed({key_held[7], diagnostic_start, 1'b0}),
        .laser_mode(audio_laser_mode), .laser_raw(laser_raw),
        .laser_function(diagnostic_override?2'd0:laser_function), .timbre_a(timbre_a), .timbre_b(timbre_b),
        .mix_enabled(diagnostic_override?1'b0:mix_enabled), .mix_level(mix_level),
        .laser_level_valid(laser_level_valid), .laser_blocked(laser_blocked),
        .laser_ready(laser_ready), .laser_event(laser_event), .laser_busy(laser_busy),
        .laser_triggers(laser_triggers), .laser_dropped(laser_dropped),
        .configured(configured && !config_fault), .master_volume(master_volume),
        .external_cancel(config_fault||diag_quiesce||diag_status==DIAG_FAULT), .cfg_cancelled(transaction_cancel),
        .delay_state(delay_state), .actual_delay_state(actual_delay_state),
        .master_smooth_level(master_smooth_level),
        .mod_level(mod_level), .mod_state(mod_state), .mod_offset(mod_offset),
        .mod_applied_level(mod_applied_level),
        .cfg_valid(cfg_valid), .cfg_id(cfg_id), .cfg_value(cfg_value),
        .cfg_ready(cfg_ready), .cfg_applied(cfg_applied), .cfg_error(config_error),
        .cfg_state(config_state), .cfg_revision(config_revision),
        .route_mode(route_mode), .effective_bend(effective_bend),
        .touch_input(audio_touch), .pressure_input(pressure_input),
        .midi_event_valid(midi_event_valid), .midi_event_ready(midi_event_ready),
        .midi_event_op(midi_event_op), .midi_event_id(midi_event_id),
        .midi_event_note(midi_event_note), .midi_event_velocity(midi_event_velocity),
        .midi_result_valid(midi_result_valid), .midi_result_code(midi_result_code),
        .midi_result_id(midi_result_id), .slot_ids(slot_ids),
        .sample_ce(sample_ce), .gain(gain), .armed(armed), .healthy(healthy), .mute(mute),
        .auto_mode(diag_auto), .state(diag_state), .allocated(allocated), .gate(voice_gate), .active(active),
        .test_index(diag_index), .errors(diag_errors), .responses(), .last_result(),
        .fulls(), .duplicates(), .unknowns(), .bads(),
        .sample(audio_sample), .bclk(bclk), .lrck(lrck), .dout(dout)
    );

    // Display observes the same independently validated pressure contract as
    // audio. A failed display is reported here while audio keeps running.
    wire pressure_header_ok = pressure_input[3:0]==1 && pressure_input[11:4]==2 &&
        pressure_input[15:12]==2 && pressure_input[31:24]==0 && pressure_input[23:20]==0 &&
        pressure_input[95:92]==0 && pressure_input[111:108]==0;
    wire display_pressure_valid = pressure_header_ok && pressure_input[16] &&
        !pressure_input[17] && !pressure_input[18];
    miseki_oled_v1 #(.CLK_HZ(CLK_HZ), .STARTUP_CYCLES(OLED_STARTUP_CYCLES),
        .RETRY_CYCLES(OLED_RETRY_CYCLES), .FRAME_GAP_CYCLES(OLED_FRAME_GAP_CYCLES),
        .LINE_TIMEOUT_CYCLES(OLED_LINE_TIMEOUT_CYCLES)) oled (
        .clk(clk), .reset(reset), .screen(screen),
        .focus(screen==5 ? ab_field : screen==6 ? 2'd0 : focus), .language(language),
        .language_preview(language_preview), .language_dirty(language_dirty),
        .drafts(ui_drafts), .dirty(ui_dirty), .mod_level(mod_level),
        .laser_mode(laser_mode), .laser_draft(laser_drafts), .laser_dirty(laser_dirty),
        .laser_function(laser_function), .timbre_a(timbre_a), .timbre_b(timbre_b),
        .mix_enabled(mix_enabled), .mix_draft(mix_draft), .mix_dirty(mix_dirty),
        .laser_level_valid(laser_level_valid), .laser_blocked(laser_blocked),
        .laser_ready(laser_ready), .laser_busy(laser_busy),
        .master_volume(master_volume), .preset_slot(preset_slot), .preset_save(preset_save),
        .preset_pending(preset_pending), .preset_valid(preset_valid), .preset_notice(preset_notice),
        .revision(config_revision), .menu_selection(menu_selection),
        .diag_status(diag_status), .diag_state(diag_state),
        .diag_index(diag_index), .diag_errors(diag_errors),
        .diag_selection(diag_selection),
        .pressure_level(pressure_input[91:80]), .pressure_valid(display_pressure_valid),
        .editing(editing || laser_editing), .busy(config_busy), .fault(config_fault),
        .armed(armed), .healthy(healthy), .mute(mute), .active(active),
        .scl(oled_scl), .sda(oled_sda), .online(oled_online), .display_fault(oled_fault),
        .address(oled_address), .errors(oled_errors), .last_error(oled_last_error), .frames(oled_frames)
    );
endmodule
