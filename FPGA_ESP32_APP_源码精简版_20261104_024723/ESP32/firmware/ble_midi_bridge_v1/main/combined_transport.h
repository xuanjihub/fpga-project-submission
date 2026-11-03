#ifndef N11_COMBINED_TRANSPORT_H
#define N11_COMBINED_TRANSPORT_H
#include "esp_err.h"
#include "bridge_protocol.h"
esp_err_t combined_transport_init(void);
bool combined_ble_exchange(uint8_t opcode,const uint8_t *extra,uint8_t length,
                           unsigned deadline_ms,fpga_state *state,uint8_t *status);
#endif
