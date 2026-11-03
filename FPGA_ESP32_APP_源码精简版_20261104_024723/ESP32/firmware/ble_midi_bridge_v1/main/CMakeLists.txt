idf_component_register(
    SRCS "../../ble_uart_bridge_v1/main/main.c"
         "../../ble_uart_bridge_v1/main/bridge_protocol.c"
         "../../ble_uart_bridge_v1/main/bridge_selftest.c"
         "combined_uart.c" "combined_transport.c"
    INCLUDE_DIRS "." "../../ble_uart_bridge_v1/main"
    REQUIRES bt nvs_flash esp_driver_uart esp_timer)
target_compile_definitions(${COMPONENT_LIB} PRIVATE
    BRIDGE_COMBINED=1 BRIDGE_MIDI_FPGA_BUILD=0x50314d06)
