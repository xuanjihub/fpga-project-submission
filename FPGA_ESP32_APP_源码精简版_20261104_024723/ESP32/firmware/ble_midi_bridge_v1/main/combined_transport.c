/* USB MIDI and BLE submit to one FIFO. Only uart_owner touches UART2.
 * Each producer has at most one queued/in-flight transaction and its own
 * completion queue, so continuous traffic cannot starve the other producer.
 * BLE CAS read and write are separate jobs; FPGA revisions detect changes
 * between them. A disconnect leaves the other source's session intact. */
#include "combined_transport.h"
#include "combined_uart.h"
#include <string.h>
#include <stdlib.h>
#include "driver/uart.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

_Static_assert(MIDI_FPGA_BUILD==0x50314d06,"combined firmware requires D06");
static QueueHandle_t requests,ble_results,midi_results;

static uint32_t now_ms(void *ctx)
{ (void)ctx; return (uint32_t)(esp_timer_get_time()/1000); }
static bool flush(void *ctx)
{ (void)ctx; return uart_flush_input(UART_NUM_2)==ESP_OK; }
static bool write_frame(void *ctx,const uint8_t *bytes,size_t length)
{ (void)ctx; return uart_write_bytes(UART_NUM_2,bytes,length)==(int)length; }
static int read_byte(void *ctx,uint8_t *byte)
{ (void)ctx; return uart_read_bytes(UART_NUM_2,byte,1,pdMS_TO_TICKS(10)); }
static bool tx_done(void *ctx)
{ (void)ctx; return uart_wait_tx_done(UART_NUM_2,pdMS_TO_TICKS(20))==ESP_OK; }

static void uart_owner(void *arg)
{
    (void)arg; combined_uart_job job;
    bridge_uart2_arbiter arbiter; bridge_uart2_arbiter_init(&arbiter);
    const combined_uart_io io={NULL,now_ms,flush,write_frame,read_byte,tx_done};
    for(;;) if(xQueueReceive(requests,&job,portMAX_DELAY)==pdTRUE) {
        combined_uart_result result={0}; uint32_t token=0;
        bool acquired=bridge_uart2_try_acquire(&arbiter,job.owner,&token);
        configASSERT(acquired);
        if(!acquired) abort();
        combined_uart_run(&job,&io,&result);
        bool released=bridge_uart2_release(&arbiter,job.owner,token);
        configASSERT(released);
        if(!released) abort();
        QueueHandle_t destination=job.owner==BRIDGE_UART2_OWNER_BLE?ble_results:midi_results;
        BaseType_t sent=xQueueSend(destination,&result,0);
        configASSERT(sent==pdTRUE);
        if(sent!=pdTRUE) abort();
    }
}
static bool submit(const combined_uart_job *job,combined_uart_result *result)
{
    QueueHandle_t destination=job->owner==BRIDGE_UART2_OWNER_BLE?ble_results:midi_results;
    /* Ownership and completion are waited without a timeout, so a late
     * completion cannot satisfy the next producer request. The owner itself
     * has a hard 600ms maximum for each UART transaction. */
    if(xQueueSend(requests,job,portMAX_DELAY)!=pdTRUE) return false;
    return xQueueReceive(destination,result,portMAX_DELAY)==pdTRUE && result->ok;
}
bool combined_ble_exchange(uint8_t opcode,const uint8_t *extra,uint8_t length,
                           unsigned deadline_ms,fpga_state *state,uint8_t *status)
{
    static uint16_t next_id; static uint32_t previous_nonce;
    uint32_t nonce; uint8_t payload[11]; combined_uart_result result;
    if(length>7 || (length && !extra)) return false;
    do { nonce=esp_random(); } while(nonce==previous_nonce);
    previous_nonce=nonce; uint16_t id=++next_id;
    bridge_put32(payload,nonce); if(length) memcpy(payload+4,extra,length);
    combined_uart_job job={.owner=BRIDGE_UART2_OWNER_BLE,.deadline_ms=deadline_ms};
    bridge_frame(job.request,UART_MAGIC,opcode,0,id,payload,(uint8_t)(length+4));
    return submit(&job,&result) &&
           bridge_uart_reply(result.response,opcode,id,nonce,state,status);
}
static void pc_reply(const uint8_t *frame)
{ (void)uart_write_bytes(UART_NUM_0,frame,FRAME_SIZE); }
static void service_midi(midi_session *session,const uint8_t *request)
{
    combined_uart_job job={.owner=BRIDGE_UART2_OWNER_PC_MIDI,.deadline_ms=600};
    combined_uart_result result; uint8_t response[FRAME_SIZE];
    memcpy(job.request,request,FRAME_SIZE);
    if(request[2]==MIDI_HEARTBEAT) {
        /* Forward PC heartbeats to keep the watchdog fed. */
        (void)submit(&job,&result); return;
    }
    if(request[2]==MIDI_HELLO) bridge_midi_session_clear(session);
    uint32_t generation=session->generation;
    midi_begin_result action=bridge_midi_begin(session,false,request,FRAME_SIZE,response);
    if(action==MIDI_BEGIN_RESPONSE) { pc_reply(response); return; }
    if(action!=MIDI_BEGIN_UART) return;
    if(submit(&job,&result)) memcpy(response,result.response,FRAME_SIZE);
    else {
        uint32_t token=((uint32_t)request[3]<<24) | ((uint32_t)request[17]<<16) |
                       ((uint32_t)request[16]<<8) | request[15];
        /* An unavailable MIDI ACK is reported as STATUS_UNAVAILABLE; the PC's
         * failsafe DRAIN and FPGA source-specific watchdog still apply. */
        (void)bridge_midi_frame(response,MIDI_RESPONSE_ERROR,STATUS_UNAVAILABLE,
                                bridge_u16(request+4),token,NULL,0);
    }
    if(bridge_midi_complete(session,generation,response)) pc_reply(session->response);
}
static void usb_midi(void *arg)
{
    (void)arg; midi_stream stream={0}; midi_session session={0};
    uint8_t byte,frame[FRAME_SIZE]; bridge_midi_session_clear(&session);
    static const char ready[]="N11_BLE_MIDI_READY fw=0.5.0 build=4E313101 fpga=50314D06 uart2=17/16\n";
    (void)uart_write_bytes(UART_NUM_0,ready,sizeof(ready)-1);
    for(;;) if(uart_read_bytes(UART_NUM_0,&byte,1,pdMS_TO_TICKS(10))==1 &&
              bridge_midi_stream_byte(&stream,byte,now_ms(NULL),frame))
        service_midi(&session,frame);
}
esp_err_t combined_transport_init(void)
{
    requests=xQueueCreate(2,sizeof(combined_uart_job));
    ble_results=xQueueCreate(1,sizeof(combined_uart_result));
    midi_results=xQueueCreate(1,sizeof(combined_uart_result));
    if(!requests || !ble_results || !midi_results) return ESP_ERR_NO_MEM;
    const uart_config_t config={.baud_rate=115200,.data_bits=UART_DATA_8_BITS,
        .parity=UART_PARITY_DISABLE,.stop_bits=UART_STOP_BITS_1,
        .flow_ctrl=UART_HW_FLOWCTRL_DISABLE,.source_clk=UART_SCLK_DEFAULT};
    esp_err_t error=uart_param_config(UART_NUM_0,&config);
    /* With the console disabled, IDF releases GPIO1/3 and ties UART0 RX high.
     * The USB bridge is reconnected explicitly. */
    if(error==ESP_OK) error=uart_set_pin(UART_NUM_0,1,3,UART_PIN_NO_CHANGE,UART_PIN_NO_CHANGE);
    if(error==ESP_OK) error=uart_driver_install(UART_NUM_0,2048,1024,0,NULL,0);
    if(error==ESP_OK) error=uart_param_config(UART_NUM_2,&config);
    if(error==ESP_OK) error=uart_set_pin(UART_NUM_2,17,16,UART_PIN_NO_CHANGE,UART_PIN_NO_CHANGE);
    if(error==ESP_OK) error=uart_driver_install(UART_NUM_2,1024,1024,0,NULL,0);
    if(error!=ESP_OK) return error;
    if(xTaskCreate(uart_owner,"n11_uart_owner",4096,NULL,5,NULL)!=pdPASS) return ESP_ERR_NO_MEM;
    if(xTaskCreate(usb_midi,"n11_usb_midi",4096,NULL,4,NULL)!=pdPASS) return ESP_ERR_NO_MEM;
    return ESP_OK;
}
