#ifndef N11_COMBINED_UART_H
#define N11_COMBINED_UART_H
#include "bridge_protocol.h"

/* The worker alone calls these callbacks. Reads wait at most 10ms; now_ms is
 * monotonic modulo 2^32. Heartbeats have no FPGA response, but still finish
 * transmitting before the next transaction may flush the input. */
typedef struct {
    void *context;
    uint32_t (*now_ms)(void *context);
    bool (*flush)(void *context);
    bool (*write)(void *context, const uint8_t *bytes, size_t length);
    int (*read)(void *context, uint8_t *byte);
    bool (*tx_done)(void *context);
} combined_uart_io;
typedef struct {
    bridge_uart2_owner owner;
    unsigned deadline_ms;
    uint8_t request[FRAME_SIZE]; /* BLE: complete B2 v1; MIDI: complete B3 v2 */
} combined_uart_job;
typedef struct { bool ok; uint8_t response[FRAME_SIZE]; } combined_uart_result;

void combined_uart_run(const combined_uart_job *job, const combined_uart_io *io,
                        combined_uart_result *result);
#endif
