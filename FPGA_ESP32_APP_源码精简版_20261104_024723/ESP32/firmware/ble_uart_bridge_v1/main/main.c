/* ESP-IDF v5.5.5 NimBLE + UART APIs. The host task alone owns BLE/session
 * state. One bounded worker exchanges UART frames, then posts completion to
 * the NimBLE event queue. */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "esp_err.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "driver/uart.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "bridge_protocol.h"
#ifdef BRIDGE_COMBINED
#include "combined_transport.h"
#define BRIDGE_IDENTITY "fw=0.5.0 build=4E313101 stage=1"
#else
#define BRIDGE_IDENTITY "fw=0.4.0 build=4E303704 stage=1"
#endif

static const char *TAG="N07_UART";
static const char DEVICE_NAME[]="FPGA-BLE-N07";
static const ble_uuid128_t SERVICE_UUID=BLE_UUID128_INIT(
  0x9d,0xd6,0xa0,0xa5,0x29,0xd3,0xb6,0x8d,0x1a,0x4f,0xf4,0x24,0x0d,0xee,0x1d,0x4a);
static const ble_uuid128_t INFO_UUID=BLE_UUID128_INIT(
  0x9e,0xd6,0xa0,0xa5,0x29,0xd3,0xb6,0x8d,0x1a,0x4f,0xf4,0x24,0x0d,0xee,0x1d,0x4a);
static const ble_uuid128_t COMMAND_UUID=BLE_UUID128_INIT(
  0x9f,0xd6,0xa0,0xa5,0x29,0xd3,0xb6,0x8d,0x1a,0x4f,0xf4,0x24,0x0d,0xee,0x1d,0x4a);
static const ble_uuid128_t RESULT_UUID=BLE_UUID128_INIT(
  0xa0,0xd6,0xa0,0xa5,0x29,0xd3,0xb6,0x8d,0x1a,0x4f,0xf4,0x24,0x0d,0xee,0x1d,0x4a);

typedef struct { uint32_t generation; uint8_t request[20]; } uart_job;
static struct { uint16_t connection; bool subscribed,worker_busy; bridge_session session; } host;
static QueueHandle_t jobs;
static struct ble_npl_event completed_event;
/* Worker writes before enqueue; host reads only in completion callback. A new
 * job cannot be admitted until that callback clears worker_busy. */
static struct { uint32_t generation; uint8_t response[20]; } completed;
static uint8_t own_addr_type;
static uint16_t result_handle;

static void session_reset(void)
{
    host.connection=BLE_HS_CONN_HANDLE_NONE;
    host.subscribed=false;
    bridge_session_clear(&host.session);
    /* An old worker must finish draining even though this session is gone. */
}
static int notify_result(const uint8_t response[20])
{
    struct os_mbuf *om=ble_hs_mbuf_from_flat(response,20);
    if(!om) return BLE_ATT_ERR_INSUFFICIENT_RES;
    /* Consumed by NimBLE on all outcomes; NOTIFY_TX may run synchronously. */
    return ble_gatts_notify_custom(host.connection,result_handle,om)==0
           ?0:BLE_ATT_ERR_INSUFFICIENT_RES;
}
static void worker_completed(struct ble_npl_event *event)
{
    (void)event;
    host.worker_busy=false;
    /* Commit before notify, including UNKNOWN, to prevent a notification
     * failure/retry from issuing the same UART SET a second time. */
    if(bridge_complete(&host.session,completed.generation,completed.response) &&
       host.connection!=BLE_HS_CONN_HANDLE_NONE && host.subscribed) {
        int rc=notify_result(host.session.response);
        if(rc) ESP_LOGW(TAG,"completion notify failed rc=%d; result cached",rc);
    }
}
static int command_write(uint16_t connection,struct os_mbuf *input)
{
    uint8_t request[20],response[20]; uint16_t actual=0;
    if(connection!=host.connection || !host.subscribed) return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    if(OS_MBUF_PKTLEN(input)!=20) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if(ble_hs_mbuf_to_flat(input,request,20,&actual)!=0 || actual!=20)
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    bridge_session before=host.session;
    begin_result action=bridge_begin(&host.session,host.worker_busy,request,20,response);
    if(action==BEGIN_REJECT) return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    if(action==BEGIN_BUSY) return BLE_ATT_ERR_INSUFFICIENT_RES;
    if(action==BEGIN_WAIT) return 0; /* identical pending retry: no new UART */
    if(action==BEGIN_RESPONSE) return notify_result(response);
    uart_job job={.generation=host.session.generation};
    memcpy(job.request,request,20);
    host.worker_busy=true;
    if(xQueueSend(jobs,&job,0)!=pdTRUE) {
        host.worker_busy=false; host.session=before;
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    return 0; /* Transport only. Business response follows worker completion. */
}
static int access_characteristic(uint16_t connection,uint16_t attribute,
                                  struct ble_gatt_access_ctxt *ctxt,void *argument)
{
    (void)attribute;
    if((uintptr_t)argument==1 && ctxt->op==BLE_GATT_ACCESS_OP_READ_CHR) {
        uint8_t info[11]; bridge_info(info);
        return os_mbuf_append(ctxt->om,info,11)==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if((uintptr_t)argument==2 && ctxt->op==BLE_GATT_ACCESS_OP_WRITE_CHR)
        return command_write(connection,ctxt->om);
    return BLE_ATT_ERR_REQ_NOT_SUPPORTED;
}
static const struct ble_gatt_chr_def characteristics[]={
    {.uuid=&INFO_UUID.u,.access_cb=access_characteristic,.arg=(void*)1,.flags=BLE_GATT_CHR_F_READ},
    {.uuid=&COMMAND_UUID.u,.access_cb=access_characteristic,.arg=(void*)2,.flags=BLE_GATT_CHR_F_WRITE},
    {.uuid=&RESULT_UUID.u,.access_cb=access_characteristic,.arg=(void*)3,.flags=BLE_GATT_CHR_F_NOTIFY,.val_handle=&result_handle},
    {0}
};
static const struct ble_gatt_svc_def services[]={
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=&SERVICE_UUID.u,.characteristics=characteristics},{0}
};

/* Only the worker calls UART APIs. A random nonce plus bridge-local ID
 * prevents delayed replies from old BLE sessions from satisfying a new
 * transaction. */
static bool exchange(uint8_t opcode,const uint8_t *extra,uint8_t extra_length,
                      unsigned deadline_ms,fpga_state *state,uint8_t *status,void *context)
{
    (void)context;
#ifdef BRIDGE_COMBINED
    return combined_ble_exchange(opcode,extra,extra_length,deadline_ms,state,status);
#else
    static uint16_t next_id;
    static uint32_t previous_nonce;
    uint8_t payload[11],request[20],reply[20]; uart_stream stream={0};
    uint8_t observed[20]; unsigned observed_count=0,received_bytes=0,received_frames=0;
    uint32_t nonce;
    do { nonce=esp_random(); } while(nonce==previous_nonce);
    previous_nonce=nonce;
    uint16_t id=++next_id;
    bridge_put32(payload,nonce);
    if(extra_length) memcpy(payload+4,extra,extra_length);
    bridge_frame(request,UART_MAGIC,opcode,0,id,payload,(uint8_t)(extra_length+4));
    (void)uart_flush_input(UART_NUM_2);
    int64_t deadline=esp_timer_get_time()+(int64_t)deadline_ms*1000;
    if(uart_write_bytes(UART_NUM_2,request,20)!=20) return false;
    while(esp_timer_get_time()<deadline) {
        uint8_t byte;
        int n=uart_read_bytes(UART_NUM_2,&byte,1,pdMS_TO_TICKS(10));
        if(n<0) return false;
        int64_t received_at=esp_timer_get_time();
        if(received_at>=deadline) break;
        if(n==1) {
            if(observed_count<sizeof(observed)) observed[observed_count++]=byte;
            received_bytes++;
            if(bridge_stream_byte(&stream,byte,(uint32_t)(received_at/1000),reply)) {
                received_frames++;
                if(bridge_uart_reply(reply,opcode,id,nonce,state,status)) return true;
            }
        }
    }
    ESP_LOGW(TAG,"UART timeout op=%02x id=%u rx_bytes=%u valid_frames=%u",
             (unsigned)opcode,(unsigned)id,received_bytes,received_frames);
    ESP_LOG_BUFFER_HEX_LEVEL(TAG,request,sizeof(request),ESP_LOG_WARN);
    if(observed_count) ESP_LOG_BUFFER_HEX_LEVEL(TAG,observed,observed_count,ESP_LOG_WARN);
    return false;
#endif
}
static void perform_job(const uart_job *job,uint8_t response[20])
{
    /* A missing or inconsistent ACK after an attempted SET is cached as
     * OUTCOME_UNKNOWN. */
    bridge_execute(job->request,exchange,NULL,response);
}
static void uart_worker(void *argument)
{
    (void)argument; uart_job job;
    for(;;) if(xQueueReceive(jobs,&job,portMAX_DELAY)==pdTRUE) {
        perform_job(&job,completed.response); completed.generation=job.generation;
        ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&completed_event);
    }
}
static int gap_event(struct ble_gap_event *event,void *argument);
static void advertise(void)
{
    struct ble_hs_adv_fields fields={0},scan={0}; struct ble_gap_adv_params params={0};
    if(host.connection!=BLE_HS_CONN_HANDLE_NONE || ble_gap_adv_active()) return;
    fields.flags=BLE_HS_ADV_F_DISC_GEN|BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128=&SERVICE_UUID; fields.num_uuids128=1; fields.uuids128_is_complete=1;
    int rc=ble_gap_adv_set_fields(&fields);
    scan.name=(const uint8_t*)DEVICE_NAME; scan.name_len=sizeof(DEVICE_NAME)-1; scan.name_is_complete=1;
    if(!rc) rc=ble_gap_adv_rsp_set_fields(&scan);
    params.conn_mode=BLE_GAP_CONN_MODE_UND; params.disc_mode=BLE_GAP_DISC_MODE_GEN;
    params.itvl_min=BLE_GAP_ADV_FAST_INTERVAL1_MIN; params.itvl_max=BLE_GAP_ADV_FAST_INTERVAL1_MAX;
    if(!rc) rc=ble_gap_adv_start(own_addr_type,NULL,BLE_HS_FOREVER,&params,gap_event,NULL);
    if(rc) ESP_LOGE(TAG,"advertising failed rc=%d",rc);
    else ESP_LOGI(TAG,"N07_UART_BLE_READY " BRIDGE_IDENTITY "; FPGA link requires GET_STATE/GET_TIMBRE/GET_ADSR_FIELD");
}
static int gap_event(struct ble_gap_event *event,void *argument)
{
    (void)argument;
    switch(event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if(event->connect.status) advertise();
        else if(host.connection!=BLE_HS_CONN_HANDLE_NONE)
            (void)ble_gap_terminate(event->connect.conn_handle,BLE_ERR_REM_USER_CONN_TERM);
        else { session_reset(); host.connection=event->connect.conn_handle; }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        if(event->disconnect.conn.conn_handle==host.connection) { session_reset(); advertise(); }
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if(event->subscribe.conn_handle==host.connection && event->subscribe.attr_handle==result_handle) {
            bool subscribed=event->subscribe.cur_notify!=0;
            if(host.subscribed&&!subscribed) bridge_session_clear(&host.session);
            host.subscribed=subscribed;
        }
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE: advertise(); break;
    default: break;
    }
    return 0;
}
static void host_reset(int reason) { session_reset(); ESP_LOGE(TAG,"BLE reset reason=%d",reason); }
static void host_sync(void)
{
    int rc=ble_hs_util_ensure_addr(0);
    if(!rc) rc=ble_hs_id_infer_auto(0,&own_addr_type);
    if(rc) ESP_LOGE(TAG,"BLE identity failed rc=%d",rc); else advertise();
}
static void host_task(void *arg) { (void)arg; nimble_port_run(); nimble_port_freertos_deinit(); }
void app_main(void)
{
    int test=bridge_selftest();
    if(test) { ESP_LOGE(TAG,"N07_UART_SELFTEST_FAIL line=%d",test); return; }
    ESP_LOGI(TAG,"N07_UART_SELFTEST_PASS " BRIDGE_IDENTITY);
    session_reset();
    esp_err_t error=nvs_flash_init();
    if(error!=ESP_OK) { ESP_LOGE(TAG,"NVS failed %s; no erase",esp_err_to_name(error)); return; }
#ifdef BRIDGE_COMBINED
    error=combined_transport_init();
#else
    const uart_config_t config={.baud_rate=115200,.data_bits=UART_DATA_8_BITS,
        .parity=UART_PARITY_DISABLE,.stop_bits=UART_STOP_BITS_1,
        .flow_ctrl=UART_HW_FLOWCTRL_DISABLE,.source_clk=UART_SCLK_DEFAULT};
    error=uart_param_config(UART_NUM_2,&config);
    if(error==ESP_OK) error=uart_set_pin(UART_NUM_2,17,16,UART_PIN_NO_CHANGE,UART_PIN_NO_CHANGE);
    if(error==ESP_OK) error=uart_driver_install(UART_NUM_2,256,0,0,NULL,0);
#endif
    if(error!=ESP_OK) { ESP_LOGE(TAG,"UART init failed %s",esp_err_to_name(error)); return; }
    jobs=xQueueCreate(1,sizeof(uart_job));
    if(!jobs) { ESP_LOGE(TAG,"worker queue allocation failed"); return; }
    error=nimble_port_init();
    if(error!=ESP_OK) { ESP_LOGE(TAG,"NimBLE init failed %s",esp_err_to_name(error)); return; }
    ble_npl_event_init(&completed_event,worker_completed,NULL);
    ble_hs_cfg.reset_cb=host_reset; ble_hs_cfg.sync_cb=host_sync;
    ble_svc_gap_init(); ble_svc_gatt_init();
    int rc=ble_svc_gap_device_name_set(DEVICE_NAME);
    if(!rc) rc=ble_gatts_count_cfg(services);
    if(!rc) rc=ble_gatts_add_svcs(services);
    if(rc) { ESP_LOGE(TAG,"GATT init failed rc=%d",rc); return; }
    if(xTaskCreate(uart_worker,"n07_uart",4096,NULL,4,NULL)!=pdPASS) {
        ESP_LOGE(TAG,"UART worker allocation failed"); return;
    }
    nimble_port_freertos_init(host_task);
}
