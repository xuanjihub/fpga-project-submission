open_project miseki_panel.gprj
set_option -output_base_name miseki_panel
set_option -include_path {../audio_modulation_v1/src}
set_option -top_module miseki_board_top
set_option -user_code 50314D06
# Timing-priority placement and bounded fanout.
set_option -opt_goal auto
set_option -map_option 1
set_option -timing_driven 1
set_option -place_option 3
set_option -route_option 1
set_option -route_maxfan 16
set_option -replicate_resources 0
run all
run close
puts "MISEKI_BUILD_COMMAND_RETURNED 50314D06"
flush stdout
exit 0
