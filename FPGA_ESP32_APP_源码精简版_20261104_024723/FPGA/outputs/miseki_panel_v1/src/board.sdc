create_clock -name clkin -period 20 -waveform {0 10} [get_ports {clk50}]
# Cut only an asynchronous external pad to its own first synchronizer D.
set_false_path -from [get_ports {reset_n}] -to [get_pins {controls/key_meta_0_s2/D}]
set_false_path -from [get_ports {adc_scl}] -to [get_pins {core/bus/scl_meta_s0/D}]
set_false_path -from [get_ports {adc_sda}] -to [get_pins {core/bus/sda_meta_s0/D}]
set_false_path -from [get_ports {oled_scl}] -to [get_pins {system/oled/display/bus/scl_meta_s0/D}]
set_false_path -from [get_ports {oled_sda}] -to [get_pins {system/oled/display/bus/sda_meta_s0/D}]
set_false_path -from [get_ports {ble_rx}] -to [get_pins {expansion_meta_0_s1/D}]
set_false_path -from [get_ports {laser_rx[0]}] -to [get_pins {expansion_meta_1_s1/D}]
set_false_path -from [get_ports {laser_rx[1]}] -to [get_pins {expansion_meta_2_s1/D}]
set_false_path -from [get_ports {encoder_ab[0]}] -to [get_pins {system/panel/input_meta_0_s1/D}]
set_false_path -from [get_ports {keys_n[0]}] -to [get_pins {system/panel/input_meta_8_s1/D}]
set_false_path -from [get_ports {encoder_ab[1]}] -to [get_pins {system/panel/input_meta_1_s1/D}]
set_false_path -from [get_ports {keys_n[1]}] -to [get_pins {system/panel/input_meta_9_s1/D}]
set_false_path -from [get_ports {encoder_ab[2]}] -to [get_pins {system/panel/input_meta_2_s1/D}]
set_false_path -from [get_ports {keys_n[2]}] -to [get_pins {system/panel/input_meta_10_s1/D}]
set_false_path -from [get_ports {encoder_ab[3]}] -to [get_pins {system/panel/input_meta_3_s1/D}]
set_false_path -from [get_ports {keys_n[3]}] -to [get_pins {system/panel/input_meta_11_s1/D}]
set_false_path -from [get_ports {encoder_ab[4]}] -to [get_pins {system/panel/input_meta_4_s1/D}]
set_false_path -from [get_ports {keys_n[4]}] -to [get_pins {system/panel/input_meta_12_s1/D}]
set_false_path -from [get_ports {encoder_ab[5]}] -to [get_pins {system/panel/input_meta_5_s1/D}]
set_false_path -from [get_ports {keys_n[5]}] -to [get_pins {system/panel/input_meta_13_s1/D}]
set_false_path -from [get_ports {encoder_ab[6]}] -to [get_pins {system/panel/input_meta_6_s1/D}]
set_false_path -from [get_ports {keys_n[6]}] -to [get_pins {system/panel/input_meta_14_s1/D}]
set_false_path -from [get_ports {encoder_ab[7]}] -to [get_pins {system/panel/input_meta_7_s1/D}]
set_false_path -from [get_ports {keys_n[7]}] -to [get_pins {system/panel/input_meta_15_s1/D}]
# All meta-to-sync paths remain timed.
report_timing -setup -from [get_regs {controls/key_meta_0_s2}] -to [get_regs {controls/key_sync_0_s2}] -max_paths 1
report_timing -hold -from [get_regs {controls/key_meta_0_s2}] -to [get_regs {controls/key_sync_0_s2}] -max_paths 1
report_timing -setup -from [get_regs {core/bus/scl_meta_s0}] -to [get_regs {core/bus/scl_sync_s0}] -max_paths 1
report_timing -hold -from [get_regs {core/bus/scl_meta_s0}] -to [get_regs {core/bus/scl_sync_s0}] -max_paths 1
report_timing -setup -from [get_regs {core/bus/sda_meta_s0}] -to [get_regs {core/bus/sda_sync_s0}] -max_paths 1
report_timing -hold -from [get_regs {core/bus/sda_meta_s0}] -to [get_regs {core/bus/sda_sync_s0}] -max_paths 1
report_timing -setup -from [get_regs {system/oled/display/bus/scl_meta_s0}] -to [get_regs {system/oled/display/bus/scl_sync_s0}] -max_paths 1
report_timing -hold -from [get_regs {system/oled/display/bus/scl_meta_s0}] -to [get_regs {system/oled/display/bus/scl_sync_s0}] -max_paths 1
report_timing -setup -from [get_regs {system/oled/display/bus/sda_meta_s0}] -to [get_regs {system/oled/display/bus/sda_sync_s0}] -max_paths 1
report_timing -hold -from [get_regs {system/oled/display/bus/sda_meta_s0}] -to [get_regs {system/oled/display/bus/sda_sync_s0}] -max_paths 1
report_timing -setup -from [get_regs {expansion_meta_0_s1}] -to [get_regs {expansion_sync_0_s1}] -max_paths 1
report_timing -hold -from [get_regs {expansion_meta_0_s1}] -to [get_regs {expansion_sync_0_s1}] -max_paths 1
report_timing -setup -from [get_regs {expansion_meta_1_s1}] -to [get_regs {expansion_sync_1_s1}] -max_paths 1
report_timing -hold -from [get_regs {expansion_meta_1_s1}] -to [get_regs {expansion_sync_1_s1}] -max_paths 1
report_timing -setup -from [get_regs {expansion_meta_2_s1}] -to [get_regs {expansion_sync_2_s1}] -max_paths 1
report_timing -hold -from [get_regs {expansion_meta_2_s1}] -to [get_regs {expansion_sync_2_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_0_s1}] -to [get_regs {system/panel/input_sync_0_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_0_s1}] -to [get_regs {system/panel/input_sync_0_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_8_s1}] -to [get_regs {system/panel/input_sync_8_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_8_s1}] -to [get_regs {system/panel/input_sync_8_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_1_s1}] -to [get_regs {system/panel/input_sync_1_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_1_s1}] -to [get_regs {system/panel/input_sync_1_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_9_s1}] -to [get_regs {system/panel/input_sync_9_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_9_s1}] -to [get_regs {system/panel/input_sync_9_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_2_s1}] -to [get_regs {system/panel/input_sync_2_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_2_s1}] -to [get_regs {system/panel/input_sync_2_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_10_s1}] -to [get_regs {system/panel/input_sync_10_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_10_s1}] -to [get_regs {system/panel/input_sync_10_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_3_s1}] -to [get_regs {system/panel/input_sync_3_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_3_s1}] -to [get_regs {system/panel/input_sync_3_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_11_s1}] -to [get_regs {system/panel/input_sync_11_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_11_s1}] -to [get_regs {system/panel/input_sync_11_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_4_s1}] -to [get_regs {system/panel/input_sync_4_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_4_s1}] -to [get_regs {system/panel/input_sync_4_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_12_s1}] -to [get_regs {system/panel/input_sync_12_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_12_s1}] -to [get_regs {system/panel/input_sync_12_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_5_s1}] -to [get_regs {system/panel/input_sync_5_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_5_s1}] -to [get_regs {system/panel/input_sync_5_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_13_s1}] -to [get_regs {system/panel/input_sync_13_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_13_s1}] -to [get_regs {system/panel/input_sync_13_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_6_s1}] -to [get_regs {system/panel/input_sync_6_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_6_s1}] -to [get_regs {system/panel/input_sync_6_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_14_s1}] -to [get_regs {system/panel/input_sync_14_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_14_s1}] -to [get_regs {system/panel/input_sync_14_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_7_s1}] -to [get_regs {system/panel/input_sync_7_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_7_s1}] -to [get_regs {system/panel/input_sync_7_s1}] -max_paths 1
report_timing -setup -from [get_regs {system/panel/input_meta_15_s1}] -to [get_regs {system/panel/input_sync_15_s1}] -max_paths 1
report_timing -hold -from [get_regs {system/panel/input_meta_15_s1}] -to [get_regs {system/panel/input_sync_15_s1}] -max_paths 1
# PCM clocks are data outputs.
set_max_delay 15 -to [get_ports {PCM_BCK PCM_LRCK PCM_DIN}]
set_min_delay 0 -to [get_ports {PCM_BCK PCM_LRCK PCM_DIN}]
report_timing -setup -to [get_ports {PCM_BCK PCM_LRCK PCM_DIN}] -max_paths 10 -max_common_paths 1
report_timing -hold -to [get_ports {PCM_BCK PCM_LRCK PCM_DIN}] -max_paths 10 -max_common_paths 1
set_max_delay 15 -to [get_ports {uart_tx adc_scl adc_sda oled_scl oled_sda}]
# Dedicated asynchronous UART output.
set_max_delay 15 -to [get_ports {ble_tx}]
set_min_delay 0 -to [get_ports {ble_tx}]
report_timing -setup -to [get_ports {ble_tx}] -max_paths 1
report_timing -hold -to [get_ports {ble_tx}] -max_paths 1
# Include true global critical paths in the candidate timing evidence.
report_timing -setup -max_paths 10 -max_common_paths 1
report_timing -hold -max_paths 10 -max_common_paths 1
