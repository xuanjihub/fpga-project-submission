#include "combined_uart.h"
#include <string.h>

void combined_uart_run(const combined_uart_job *job,const combined_uart_io *io,
                        combined_uart_result *result)
{
    uint8_t request[FRAME_SIZE],window[FRAME_SIZE]; size_t count=0;
    if(!result) return;
    memset(result,0,sizeof(*result));
    if(!job || !io || !io->now_ms || !io->flush || !io->write ||
       !io->read || !io->tx_done || !job->deadline_ms || job->deadline_ms>600) return;
    if(job->owner==BRIDGE_UART2_OWNER_PC_MIDI) {
        if(!bridge_midi_to_uart(job->request,request)) return;
    } else if(job->owner==BRIDGE_UART2_OWNER_BLE) {
        if(!bridge_frame_valid(job->request,FRAME_SIZE,UART_MAGIC,true) ||
           job->request[1]!=1 || job->request[6]<4) return;
        memcpy(request,job->request,FRAME_SIZE);
    } else return;
    uint32_t start=io->now_ms(io->context);
    if(!io->flush(io->context) || !io->write(io->context,request,FRAME_SIZE)) return;
    if(job->owner==BRIDGE_UART2_OWNER_PC_MIDI && request[2]==MIDI_HEARTBEAT) {
        result->ok=io->tx_done(io->context); return;
    }
    while((uint32_t)(io->now_ms(io->context)-start)<job->deadline_ms) {
        uint8_t byte; int n=io->read(io->context,&byte);
        if(n<0) return;
        if((uint32_t)(io->now_ms(io->context)-start)>=job->deadline_ms) return;
        if(n!=1) continue;
        if(!count && byte!=UART_MAGIC) continue;
        window[count++]=byte;
        if(count<FRAME_SIZE) continue;
        if(job->owner==BRIDGE_UART2_OWNER_PC_MIDI) {
            if(bridge_uart_to_midi(job->request,window,result->response)) {
                result->ok=true; return;
            }
        } else {
            fpga_state state; uint8_t status;
            if(bridge_uart_reply(window,request[2],bridge_u16(request+4),
                                 bridge_u32(request+7),&state,&status)) {
                memcpy(result->response,window,FRAME_SIZE); result->ok=true; return;
            }
        }
        /* A frame for the other protocol, a stale token/nonce, a corrupt frame,
         * or an embedded magic is skipped. */
        size_t offset=1;
        while(offset<FRAME_SIZE && window[offset]!=UART_MAGIC) ++offset;
        count=FRAME_SIZE-offset; memmove(window,window+offset,count);
    }
}
