`timescale 1ns/1ps
// N07.4 UART bridge derived from the frozen laser candidate. One 50 MHz clock domain and the retained S15 sensor
// bus. The N02 panel owns all encoder/button qualification and configuration.
// POR alone resets serial clock cadence; KEY0 is a distinct soft reset.
module miseki_board_top #(
    parameter integer CLK_HZ=50000000,
    parameter integer STARTUP_CYCLES=1048576,
    parameter integer DEBOUNCE_CYCLES=100000,
    parameter integer REPORT_CYCLES=CLK_HZ/10,
    parameter integer LASER_STABLE_CYCLES=25000,
    parameter integer AB_CYCLES=5000,
    parameter integer BUTTON_CYCLES=250000,
    parameter integer SENSOR_I2C_HZ=100000,
    parameter integer BCLK_HALF_PERIOD=8,
    parameter integer OLED_STARTUP_CYCLES=CLK_HZ/20,
    parameter integer OLED_RETRY_CYCLES=CLK_HZ/10,
    parameter integer OLED_FRAME_GAP_CYCLES=CLK_HZ/20,
    parameter integer OLED_LINE_TIMEOUT_CYCLES=CLK_HZ/100
)(
    input wire clk50, reset_n,
    input wire [7:0] encoder_ab, keys_n,
    input wire ble_rx,
    input wire [1:0] laser_rx,
    inout wire adc_scl, adc_sda, oled_scl, oled_sda,
    output wire uart_tx, ble_tx,
    output wire PCM_BCK, PCM_LRCK, PCM_DIN,
    output wire HP_BCK, HP_WS, HP_DIN, PA_EN
);
    wire reset, power_reset;
    wire [2:0] board_pressed;
    s09_control #(.STARTUP_CYCLES(STARTUP_CYCLES),
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) controls (
        .clk(clk50), .key_n({2'b11,reset_n}), .reset(reset),
        .power_reset(power_reset), .pressed(board_pressed)
    );
    // External receivers use the retained two-stage synchronizers. RX0 feeds laser input;
    // RX1 remains an observation; BLE feeds its own bounded UART endpoint.
    (* syn_keep=1 *) reg [2:0] expansion_meta, expansion_sync;
    always @(posedge clk50) begin
        if(reset) begin
            expansion_meta<=3'b111;
            expansion_sync<=3'b111;
        end else begin
            expansion_meta<={laser_rx,ble_rx};
            expansion_sync<=expansion_meta;
        end
    end

    wire adc_strobe, adc_channel;
    wire signed [15:0] adc_raw, raw0, raw1;
    wire [11:0] touch;
    wire mr, mf, mv, tu;
    wire [3:0] me;
    wire [7:0] mec, ae;
    wire [15:0] ms;
    wire [31:0] ma, asq, aec, age0, age1, touch_age;
    wire [1:0] av;
    wire bus_fault_valid;
    wire [39:0] bus_fault_context;
    // This module name is owned by s15_poll_core.v.
    s12_shared_core #(.CLK_HZ(CLK_HZ), .I2C_HZ(SENSOR_I2C_HZ)) core (
        .clk(clk50), .reset(reset), .scl(adc_scl), .sda(adc_sda),
        .touch(touch), .touch_update(tu), .touch_age(touch_age),
        .adc_strobe(adc_strobe), .adc_channel(adc_channel), .adc_raw(adc_raw),
        .m_ready(mr), .m_fault(mf), .m_valid(mv), .m_error(me),
        .m_errors(mec), .m_seq(ms), .m_age(ma), .raw0(raw0), .raw1(raw1),
        .a_valid(av), .a_error(ae), .a_errors(aec), .a_seq(asq),
        .age0(age0), .age1(age1), .bus_fault_valid(bus_fault_valid),
        .bus_fault_context(bus_fault_context)
    );

    // The board owns a monotonically advancing POR-relative timebase.
    // Soft reset leaves diagnostic timestamps and the UART transport running.
    reg [31:0] trace_cycles;
    always @(posedge clk50)
        if(power_reset) trace_cycles<=0;
        else trace_cycles<=trace_cycles+1'b1;
    wire [111:0] touch_input, pressure_input;
    wire touch_stale, touch_usable;
    ble_touch_freshness_v1 #(.CLK_HZ(CLK_HZ)) touch_freshness (
        .clk(clk50), .reset(reset), .touch_update(tu), .m_ready(mr), .m_fault(mf),
        .touch_age(touch_age), .stale(touch_stale), .usable(touch_usable)
    );
    input_snapshot #(.SOURCE(1), .KIND(1)) touch_source (
        .flags({5'b0,touch_stale,mf,touch_usable}), .seq(ms),
        .timestamp(trace_cycles-touch_age), .value({4'b0,touch}),
        .aux(16'd0), .packet(touch_input)
    );
    wire sample_ce;
    wire [11:0] pressure_level;
    wire pressure_valid, pressure_pressed;
    fsr_input #(.CLK_HZ(CLK_HZ)) pressure_source (
        .clk(clk50), .reset(reset), .sample_ce(sample_ce),
        .adc_strobe(adc_strobe && adc_channel), .adc_valid(av[1]),
        .adc_raw(adc_raw), .adc_age(age1), .time_now(trace_cycles),
        .packet(pressure_input), .level(pressure_level), .gain(),
        .level_valid(pressure_valid), .pressed(pressure_pressed)
    );

    wire [1:0] laser_mode;
    wire laser_level_valid, laser_blocked, laser_ready, laser_event, laser_busy;
    wire [15:0] laser_triggers, laser_dropped;
    wire [3:0] encoder_up, encoder_down, selected;
    wire [7:0] key_press, key_release, key_held;
    wire [31:0] invalid_counts, allocated, voice_gate, active;
    wire [511:0] slot_ids;
    wire [1:0] preset_slot, preset_notice, cfg_error, route_mode;
    wire [2:0] ui_view;
    wire [4:0] master_volume;
    wire preset_save, preset_pending;
    wire [3:0] preset_valid;
    wire editing, configured, config_fault, config_busy;
    wire [15:0] draft_value, cfg_revision;
    wire [111:0] cfg_state;
    wire [31:0] mod_state;
    wire [47:0] delay_state, actual_delay_state;
    wire [7:0] master_smooth_level;
    wire transaction_cancel;
    wire [4:0] mod_level, mod_applied_level;
    wire signed [15:0] mod_offset;
    wire signed [15:0] effective_bend, audio_sample;
    wire [11:0] gain;
    wire armed, healthy, mute;
    wire oled_online, oled_fault;
    wire [6:0] oled_address;
    wire [7:0] oled_errors;
    wire [3:0] oled_last_error;
    wire [15:0] oled_frames;
    wire remote_valid, remote_ready, remote_done;
    wire [4:0] remote_master, remote_value;
    wire [7:0] remote_status;
    wire [15:0] remote_revision;
    wire remote_timbre_valid, remote_timbre_ready, remote_timbre_done;
    wire [1:0] remote_timbre, remote_timbre_value;
    wire [7:0] remote_timbre_status;
    wire [15:0] remote_timbre_revision;
    wire remote_adsr_valid, remote_adsr_ready, remote_adsr_done;
    wire [1:0] remote_adsr_field;
    wire [4:0] remote_adsr_index, remote_adsr_value;
    wire [7:0] remote_adsr_status;
    wire [15:0] remote_adsr_revision;
    wire [19:0] adsr_indices;
    wire [15:0] adsr_owner_revision;
    wire config_tx, midi_tx;
    wire midi_event_valid, midi_event_ready, midi_result_valid;
    wire [1:0] midi_event_op;
    wire [15:0] midi_event_id, midi_result_id;
    wire [6:0] midi_event_note, midi_event_velocity;
    wire [2:0] midi_result_code;
    // Control and MIDI use disjoint opcode ranges on the same UART stream.
    // Both TX paths idle high, so the single existing pin can safely combine
    // their responses without adding or moving a board connection.
    assign ble_tx=config_tx & midi_tx;
    wire [1:0] current_timbre;
    assign current_timbre = cfg_state[81:80];
    miseki_uart_endpoint_v1 #(.CLK_HZ(CLK_HZ),.BUILD_ID(32'h50314D06),.MIDI_SHARED(1)) bridge (
        .clk(clk50), .power_reset(power_reset), .owner_reset(reset),
        .rx(expansion_sync[0]), .tx(config_tx),
        .configured(configured), .fault(config_fault), .revision(cfg_revision), .master(master_volume),
        .timbre(current_timbre),
        .remote_valid(remote_valid), .remote_master(remote_master), .remote_ready(remote_ready),
        .remote_done(remote_done), .remote_status(remote_status),
        .remote_revision(remote_revision), .remote_value(remote_value),
        .remote_timbre_valid(remote_timbre_valid), .remote_timbre(remote_timbre),
        .remote_timbre_ready(remote_timbre_ready), .remote_timbre_done(remote_timbre_done),
        .remote_timbre_status(remote_timbre_status), .remote_timbre_revision(remote_timbre_revision),
        .remote_timbre_value(remote_timbre_value),
        .adsr_indices(adsr_indices), .adsr_revision(adsr_owner_revision),
        .remote_adsr_valid(remote_adsr_valid), .remote_adsr_field(remote_adsr_field),
        .remote_adsr_index(remote_adsr_index), .remote_adsr_ready(remote_adsr_ready),
        .remote_adsr_done(remote_adsr_done), .remote_adsr_status(remote_adsr_status),
        .remote_adsr_revision(remote_adsr_revision), .remote_adsr_value(remote_adsr_value)
    );
    midi_uart_endpoint_v1 #(.CLK_HZ(CLK_HZ),.BAUD(115200),.SHARED_AUDIO(1),
        .BUILD_ID(32'h50314D06)) midi (
        .clk(clk50),.reset(reset),.source_cancel(mute),.rx(expansion_sync[0]),.tx(midi_tx),
        .event_valid(midi_event_valid),.event_ready(midi_event_ready),
        .event_op(midi_event_op),.event_id(midi_event_id),
        .event_note(midi_event_note),.event_velocity(midi_event_velocity),
        .event_result_valid(midi_result_valid),.event_result_code(midi_result_code),
        .event_result_id(midi_result_id),.allocated(allocated),.active(active),
        .voice_gate(voice_gate),.slot_ids(slot_ids)
    );
    miseki_system_v1 #(.CLK_HZ(CLK_HZ), .MIDI_ENABLE(1), .LASER_STABLE_CYCLES(LASER_STABLE_CYCLES), .AB_CYCLES(AB_CYCLES),
        .BUTTON_CYCLES(BUTTON_CYCLES), .BCLK_HALF_PERIOD(BCLK_HALF_PERIOD),
        .OLED_STARTUP_CYCLES(OLED_STARTUP_CYCLES), .OLED_RETRY_CYCLES(OLED_RETRY_CYCLES),
        .OLED_FRAME_GAP_CYCLES(OLED_FRAME_GAP_CYCLES),
        .OLED_LINE_TIMEOUT_CYCLES(OLED_LINE_TIMEOUT_CYCLES)) system (
        .clk(clk50), .reset(reset), .power_reset(power_reset),
        .remote_valid(remote_valid), .remote_master(remote_master), .remote_ready(remote_ready),
        .remote_done(remote_done), .remote_status(remote_status),
        .remote_revision(remote_revision), .remote_value(remote_value),
        .remote_timbre_valid(remote_timbre_valid), .remote_timbre(remote_timbre),
        .remote_timbre_ready(remote_timbre_ready), .remote_timbre_done(remote_timbre_done),
        .remote_timbre_status(remote_timbre_status), .remote_timbre_revision(remote_timbre_revision),
        .remote_timbre_value(remote_timbre_value),
        .adsr_indices(adsr_indices), .adsr_revision(adsr_owner_revision),
        .remote_adsr_valid(remote_adsr_valid), .remote_adsr_field(remote_adsr_field),
        .remote_adsr_index(remote_adsr_index), .remote_adsr_ready(remote_adsr_ready),
        .remote_adsr_done(remote_adsr_done), .remote_adsr_status(remote_adsr_status),
        .remote_adsr_revision(remote_adsr_revision), .remote_adsr_value(remote_adsr_value),
        .midi_event_valid(midi_event_valid),.midi_event_ready(midi_event_ready),
        .midi_event_op(midi_event_op),.midi_event_id(midi_event_id),
        .midi_event_note(midi_event_note),.midi_event_velocity(midi_event_velocity),
        .midi_result_valid(midi_result_valid),.midi_result_code(midi_result_code),
        .midi_result_id(midi_result_id),
        .encoder_ab(encoder_ab), .keys_n(keys_n),
        .laser_raw(expansion_sync[1]), .laser_mode(laser_mode),
        .laser_level_valid(laser_level_valid), .laser_blocked(laser_blocked),
        .laser_ready(laser_ready), .laser_event(laser_event), .laser_busy(laser_busy),
        .laser_triggers(laser_triggers), .laser_dropped(laser_dropped),
        .touch_input(touch_input), .pressure_input(pressure_input),
        .encoder_up(encoder_up), .encoder_down(encoder_down),
        .key_press(key_press), .key_release(key_release), .key_held(key_held),
        .invalid_counts(invalid_counts), .selected(selected), .ui_view(ui_view),
        .master_volume(master_volume), .preset_slot(preset_slot), .preset_save(preset_save),
        .preset_pending(preset_pending), .preset_valid(preset_valid), .preset_notice(preset_notice),
        .editing(editing), .configured(configured), .config_fault(config_fault),
        .config_busy(config_busy), .draft_value(draft_value), .config_state(cfg_state),
        .config_revision(cfg_revision), .config_error(cfg_error), .route_mode(route_mode),
        .effective_bend(effective_bend), .sample_ce(sample_ce), .gain(gain),
        .mod_state(mod_state), .mod_level(mod_level), .mod_applied_level(mod_applied_level),
        .mod_offset(mod_offset),
        .delay_state(delay_state), .actual_delay_state(actual_delay_state),
        .master_smooth_level(master_smooth_level), .transaction_cancel(transaction_cancel),
        .armed(armed), .healthy(healthy), .mute(mute), .allocated(allocated),
        .voice_gate(voice_gate), .active(active), .slot_ids(slot_ids), .audio_sample(audio_sample),
        .bclk(PCM_BCK), .lrck(PCM_LRCK), .dout(PCM_DIN),
        .oled_scl(oled_scl), .oled_sda(oled_sda), .oled_online(oled_online),
        .oled_fault(oled_fault), .oled_address(oled_address), .oled_errors(oled_errors),
        .oled_last_error(oled_last_error), .oled_frames(oled_frames)
    );

    laser_diagnostics_v1 #(.CLK_HZ(CLK_HZ),.REPORT_CYCLES(REPORT_CYCLES),.BUILD_ID(32'h50314D06)) diagnostics (
        .clk(clk50),.reset(reset),.power_reset(power_reset),.trace_cycles(trace_cycles),
        .bus_fault_valid(bus_fault_valid),.bus_fault_context(bus_fault_context),
        .touch(touch),.gain(gain),.pressure_level(pressure_level),
        .laser_mode(laser_mode),.laser_level_valid(laser_level_valid),.laser_blocked(laser_blocked),
        .laser_ready(laser_ready),.laser_busy(laser_busy),.laser_triggers(laser_triggers),.laser_dropped(laser_dropped),
        .configured(configured),.pressure_pressed(pressure_pressed),.pressure_valid(pressure_valid),
        .mute(mute),.armed(armed),.healthy(healthy),.audio_sample(audio_sample),
        .effective_bend(effective_bend),.allocated(allocated),.voice_gate(voice_gate),.active(active),
        .mod_state(mod_state),.mod_level(mod_level),.mod_applied_level(mod_applied_level),
        .mod_offset(mod_offset),
        .delay_state(delay_state), .actual_delay_state(actual_delay_state),
        .master_smooth_level(master_smooth_level), .transaction_cancel(transaction_cancel),
        .selected(selected),.ui_view(ui_view),.route_mode(route_mode),.cfg_error(cfg_error),
        .preset_slot(preset_slot),.preset_notice(preset_notice),.master_volume(master_volume),
        .key_held(key_held),.expansion_levels(expansion_sync),.editing(editing),
        .config_fault(config_fault),.config_busy(config_busy),.preset_save(preset_save),
        .preset_pending(preset_pending),.draft_value(draft_value),.cfg_revision(cfg_revision),
        .cfg_state(cfg_state),.invalid_counts(invalid_counts),.preset_valid(preset_valid),
        .oled_online(oled_online),.oled_fault(oled_fault),.oled_address(oled_address),
        .oled_errors(oled_errors),.oled_last_error(oled_last_error),.oled_frames(oled_frames),
        .m_seq(ms),.m_age(ma),.touch_age(touch_age),.a_seq(asq),.a_errors(aec),
        .age0(age0),.age1(age1),.a_valid(av),.a_error(ae),.m_errors(mec),
        .raw0(raw0),.raw1(raw1),.m_ready(mr),.m_fault(mf),.m_valid(mv),
        .touch_usable(touch_usable),.m_error(me),.last_bus_fault(),.bus_fault_count(),
        .report_kind(),.payload(),.report_ce(),.uart_tx(uart_tx)
    );
    assign HP_BCK=1'b0;
    assign HP_WS=1'b0;
    assign HP_DIN=1'b0;
    assign PA_EN=1'b1;
endmodule
