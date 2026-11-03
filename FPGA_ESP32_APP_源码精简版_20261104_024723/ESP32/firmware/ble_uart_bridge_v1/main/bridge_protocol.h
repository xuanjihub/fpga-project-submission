#ifndef N07_BRIDGE_PROTOCOL_H
#define N07_BRIDGE_PROTOCOL_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { FRAME_SIZE=20, PAYLOAD_SIZE=11, BLE_MAGIC=0xb1, UART_MAGIC=0xb2,
       OP_PING=1, OP_INFO=2, OP_STATE=0x10, OP_MASTER=0x11,
       OP_TIMBRE=0x12, OP_TIMBRE_SET=0x13,
       OP_ATTACK=0x14, OP_ATTACK_SET=0x15,
       OP_DECAY=0x16, OP_DECAY_SET=0x17,
       OP_SUSTAIN=0x18, OP_SUSTAIN_SET=0x19,
       OP_RELEASE=0x1a, OP_RELEASE_SET=0x1b,
       OP_ERROR=0xff, STATUS_OK=0, STATUS_OPCODE=1, STATUS_VERSION=2,
       STATUS_PAYLOAD=3, STATUS_ID_CONFLICT=4, STATUS_UNAVAILABLE=0x10,
       STATUS_BUSY=0x11, STATUS_CONFLICT=0x12, STATUS_CANCELLED=0x13,
       STATUS_FAULT=0x14, STATUS_UNKNOWN=0x15 };

/* PC USB/UART MIDI ingress is a separate, versioned transport with its own magic.
 * The first firmware consuming these commands also exposes the matching FPGA
 * endpoint. Existing BLE builds retain D04. An isolated MIDI profile opts in
 * explicitly. */
#ifndef BRIDGE_MIDI_FPGA_BUILD
#define BRIDGE_MIDI_FPGA_BUILD 0x50314d04
#endif
enum {
    MIDI_PC_MAGIC=0xb3, MIDI_PROTOCOL_VERSION=2,
    MIDI_NOTE_ON_BATCH=0x20, MIDI_NOTE_OFF_BATCH=0x21,
    MIDI_ALL_NOTES_OFF=0x22, MIDI_HEARTBEAT=0x23, MIDI_HELLO=0x24,
    MIDI_DRAIN_STATUS=0x25,
    MIDI_RESPONSE_ERROR=0xff,
    MIDI_STATUS_FULL=0x16, MIDI_STATUS_DUPLICATE=0x17,
    MIDI_STATUS_UNKNOWN_OFF=0x18, MIDI_STATUS_BAD_EVENT=0x19,
    MIDI_STATUS_STALE_SESSION=0x1a, MIDI_STATUS_SEQUENCE=0x1b,
    MIDI_ID_MIN=0xa000, MIDI_ID_MAX=0xbfff,
    MIDI_PAYLOAD_SIZE=8,
    MIDI_FPGA_BUILD=BRIDGE_MIDI_FPGA_BUILD,
    MIDI_VOICES=32, MIDI_CAPABILITIES=0x0f,
    MIDI_SESSION_NO_SESSION=0, MIDI_SESSION_ACTIVE=1,
    MIDI_SESSION_QUIESCING=2, MIDI_SESSION_DRAINED=3,
    MIDI_SESSION_FAULT=4
};

typedef enum {
    BRIDGE_UART2_OWNER_NONE=0,
    BRIDGE_UART2_OWNER_BLE=1,
    BRIDGE_UART2_OWNER_PC_MIDI=2
} bridge_uart2_owner;

/* Portable ownership policy used by RTOS transports. The caller serializes
 * access (ESP uses a FreeRTOS mutex). Tokens prevent a late completion from
 * releasing a newer transaction. */
typedef struct {
    bridge_uart2_owner owner;
    uint32_t next_token;
    uint32_t token;
} bridge_uart2_arbiter;

void bridge_uart2_arbiter_init(bridge_uart2_arbiter *arbiter);
bool bridge_uart2_try_acquire(bridge_uart2_arbiter *arbiter,
                              bridge_uart2_owner owner, uint32_t *token);
bool bridge_uart2_release(bridge_uart2_arbiter *arbiter,
                          bridge_uart2_owner owner, uint32_t token);
bool bridge_uart2_is_busy(const bridge_uart2_arbiter *arbiter);

bool bridge_midi_frame(uint8_t *frame, uint8_t opcode, uint8_t status,
                       uint16_t request_id, uint32_t session_token,
                       const uint8_t *payload,
                       uint8_t length);
bool bridge_midi_frame_valid(const uint8_t *frame, size_t length, bool request);
bool bridge_midi_request_valid(const uint8_t *frame, size_t length);
bool bridge_midi_response_valid(const uint8_t *request,
                                const uint8_t *response);
/* Validate and translate complete PC B3 MIDI requests to FPGA UART B2,
 * then validate a B2 response against the original B3 request and translate
 * it back. CRC is recalculated after changing the magic byte. */
bool bridge_midi_to_uart(const uint8_t *pc_request, uint8_t *uart_request);
bool bridge_uart_to_midi(const uint8_t *pc_request,
                         const uint8_t *uart_response,
                         uint8_t *pc_response);
typedef struct { uint8_t bytes[FRAME_SIZE]; size_t count; uint32_t last_ms; } midi_stream;
bool bridge_midi_stream_byte(midi_stream *stream, uint8_t byte, uint32_t now_ms,
                             uint8_t *frame);
typedef struct {
    uint32_t generation;
    uint32_t session_token;
    uint16_t last_sequence;
    bool cached, pending;
    uint8_t request[FRAME_SIZE], response[FRAME_SIZE];
} midi_session;
typedef enum { MIDI_BEGIN_REJECT, MIDI_BEGIN_BUSY, MIDI_BEGIN_WAIT,
               MIDI_BEGIN_RESPONSE, MIDI_BEGIN_UART,
               MIDI_BEGIN_FIRE_AND_FORGET } midi_begin_result;
void bridge_midi_session_clear(midi_session *session);
midi_begin_result bridge_midi_begin(midi_session *session, bool worker_busy,
                                    const uint8_t *request, size_t length,
                                    uint8_t *response);
bool bridge_midi_complete(midi_session *session, uint32_t generation,
                          const uint8_t *response);

#define EXPECTED_FPGA_BUILD UINT32_C(0x50314b03)
#define MISEKI_FPGA_BUILD UINT32_C(0x50314d03)
#define INSTRUMENT_TEST_FPGA_BUILD UINT32_C(0x50314d05)
bool bridge_fpga_build_supported(uint32_t build);
/* Keep the published leading fields in place for legacy initializers. Only
 * the field selected by the current opcode is meaningful after a UART read. */
typedef struct {
    uint32_t build; uint16_t revision; uint8_t master; uint8_t timbre;
    uint8_t adsr[4];
} fpga_state;
typedef struct {
    uint32_t generation;
    bool cached, pending;
    uint8_t request[FRAME_SIZE], response[FRAME_SIZE];
} bridge_session;
typedef struct { uint8_t bytes[FRAME_SIZE]; size_t count; uint32_t last_ms; } uart_stream;
typedef enum { BEGIN_REJECT, BEGIN_BUSY, BEGIN_WAIT, BEGIN_RESPONSE, BEGIN_UART } begin_result;

uint16_t bridge_crc(const uint8_t *bytes, size_t length);
uint16_t bridge_u16(const uint8_t *bytes);
uint32_t bridge_u32(const uint8_t *bytes);
void bridge_put16(uint8_t *bytes, uint16_t value);
void bridge_put32(uint8_t *bytes, uint32_t value);
void bridge_info(uint8_t *payload);
bool bridge_frame_valid(const uint8_t *frame, size_t length, uint8_t magic, bool request);
void bridge_frame(uint8_t *frame, uint8_t magic, uint8_t opcode,
                  uint8_t status, uint16_t id, const uint8_t *payload, uint8_t length);
void bridge_session_clear(bridge_session *session);
begin_result bridge_begin(bridge_session *session, bool worker_busy,
                          const uint8_t *request, size_t length,
                          uint8_t *response);
bool bridge_complete(bridge_session *session, uint32_t generation,
                     const uint8_t *response);
void bridge_response(const uint8_t *request, uint8_t status,
                     const fpga_state *state, uint8_t *response);
bool bridge_stream_byte(uart_stream *stream, uint8_t byte, uint32_t now_ms,
                        uint8_t *frame);
bool bridge_uart_reply(const uint8_t *frame, uint8_t request_opcode,
                       uint16_t id, uint32_t nonce, fpga_state *state,
                       uint8_t *status);
bool bridge_cas_matches(const uint8_t *request, const fpga_state *state);
bool bridge_ack_matches(const fpga_state *before, const fpga_state *after,
                        uint8_t desired, bool timbre);
bool bridge_parameter_ack_matches(const fpga_state *before, const fpga_state *after,
                                  uint8_t desired, uint8_t opcode);
typedef bool (*bridge_exchange_fn)(uint8_t opcode,const uint8_t *extra,
                                  uint8_t extra_length,unsigned deadline_ms,
                                  fpga_state *state,uint8_t *status,void *context);
void bridge_execute(const uint8_t *request,bridge_exchange_fn exchange,
                    void *context,uint8_t *response);
int bridge_selftest(void);
#endif
