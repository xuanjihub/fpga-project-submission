#include "bridge_protocol.h"
#include <string.h>

uint16_t bridge_u16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1]<<8)); }
uint32_t bridge_u32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24); }
void bridge_put16(uint8_t *p, uint16_t v) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
void bridge_put32(uint8_t *p, uint32_t v) { bridge_put16(p,(uint16_t)v); bridge_put16(p+2,(uint16_t)(v>>16)); }
uint16_t bridge_crc(const uint8_t *p, size_t length)
{
    uint16_t crc=0xffff;
    for(size_t i=0;i<length;i++) { crc^=(uint16_t)p[i]<<8;
        for(unsigned bit=0;bit<8;bit++) crc=(uint16_t)((crc&0x8000)?(crc<<1)^0x1021:crc<<1); }
    return crc;
}
void bridge_info(uint8_t *p)
{
#ifdef BRIDGE_COMBINED
    static const uint8_t info[11]={1,0,5,0,1,0x31,0x31,0x4e,20,11,0xff};
#else
    static const uint8_t info[11]={1,0,4,0,4,0x37,0x30,0x4e,20,11,0xff};
#endif
    memcpy(p,info,11);
}
bool bridge_fpga_build_supported(uint32_t build)
{
    return build==EXPECTED_FPGA_BUILD || build==MISEKI_FPGA_BUILD ||
           build==INSTRUMENT_TEST_FPGA_BUILD
#ifdef BRIDGE_COMBINED
           || build==UINT32_C(0x50314d06)
#endif
           ;
}

void bridge_uart2_arbiter_init(bridge_uart2_arbiter *a)
{
    if(a) memset(a,0,sizeof(*a));
}
bool bridge_uart2_try_acquire(bridge_uart2_arbiter *a,bridge_uart2_owner owner,
                              uint32_t *token)
{
    if(!a || !token || (owner!=BRIDGE_UART2_OWNER_BLE &&
                        owner!=BRIDGE_UART2_OWNER_PC_MIDI) ||
       a->owner!=BRIDGE_UART2_OWNER_NONE) return false;
    uint32_t next=a->next_token+1;
    if(next==0) next=1;
    a->next_token=next; a->token=next; a->owner=owner; *token=next;
    return true;
}
bool bridge_uart2_release(bridge_uart2_arbiter *a,bridge_uart2_owner owner,
                          uint32_t token)
{
    if(!a || owner==BRIDGE_UART2_OWNER_NONE || a->owner!=owner ||
       token==0 || a->token!=token) return false;
    a->owner=BRIDGE_UART2_OWNER_NONE; a->token=0;
    return true;
}
bool bridge_uart2_is_busy(const bridge_uart2_arbiter *a)
{ return a && a->owner!=BRIDGE_UART2_OWNER_NONE; }

static uint32_t midi_token(const uint8_t *f,bool response)
{
    uint32_t high=response?f[7]:f[3];
    return (high<<24) | ((uint32_t)f[17]<<16) | ((uint32_t)f[16]<<8) | f[15];
}
static void midi_store_token(uint8_t *f,uint32_t token,bool response)
{
    if(response) f[7]=(uint8_t)(token>>24);
    else f[3]=(uint8_t)(token>>24);
    f[15]=(uint8_t)token; f[16]=(uint8_t)(token>>8); f[17]=(uint8_t)(token>>16);
}
static bool midi_request_opcode(uint8_t op)
{
    return op==MIDI_NOTE_ON_BATCH || op==MIDI_NOTE_OFF_BATCH ||
           op==MIDI_ALL_NOTES_OFF || op==MIDI_HEARTBEAT ||
           op==MIDI_HELLO || op==MIDI_DRAIN_STATUS;
}
bool bridge_midi_frame(uint8_t *f,uint8_t op,uint8_t status,uint16_t id,
                       uint32_t token,const uint8_t *payload,uint8_t length)
{
    bool response=(op>=0x80 || op==MIDI_RESPONSE_ERROR);
    if(!f || (response ? length>7 : length>MIDI_PAYLOAD_SIZE) ||
       (length && !payload)) return false;
    memset(f,0,FRAME_SIZE); f[0]=MIDI_PC_MAGIC; f[1]=MIDI_PROTOCOL_VERSION;
    f[2]=op; f[3]=status; bridge_put16(f+4,id);
    f[6]=(uint8_t)(response ? length+1 : length);
    if(length) memcpy(f+(response ? 8 : 7),payload,length);
    midi_store_token(f,token,response);
    bridge_put16(f+18,bridge_crc(f,18));
    return true;
}
bool bridge_midi_frame_valid(const uint8_t *f,size_t length,bool request)
{
    if(!f || length!=FRAME_SIZE || f[0]!=MIDI_PC_MAGIC ||
       f[1]!=MIDI_PROTOCOL_VERSION || f[6]>(request?MIDI_PAYLOAD_SIZE:8) ||
       bridge_crc(f,18)!=bridge_u16(f+18)) return false;
    size_t start=request?7:8;
    size_t end=request?15:15;
    size_t used=request?(size_t)f[6]:(size_t)(f[6]-1);
    if(!request && f[6]==0) return false;
    for(size_t i=start+used;i<end;i++) if(f[i]) return false;
    return true;
}
bool bridge_midi_request_valid(const uint8_t *f,size_t length)
{
    if(!bridge_midi_frame_valid(f,length,true) || !midi_request_opcode(f[2])) return false;
    /* IDs are little-endian bytes 4..5; token fields occupy 3 and 15..17. */
    uint16_t seq=bridge_u16(f+4); uint8_t n=f[6]; uint32_t token=midi_token(f,false);
    if(f[2]==MIDI_HELLO) return seq!=0 && n==0 && token!=0;
    if(f[2]==MIDI_HEARTBEAT) return seq==0 && n==0 && token!=0;
    if(f[2]==MIDI_DRAIN_STATUS) return seq!=0 && n==0;
    if(seq==0 || token==0) return false;
    if(f[2]==MIDI_ALL_NOTES_OFF) return n==0;
    if(f[2]==MIDI_NOTE_ON_BATCH) {
        if(n!=4 && n!=7) return false;
        uint64_t packed=0; for(uint8_t i=0;i<n;i++) packed|=(uint64_t)f[7+i]<<(8*i);
        uint8_t count=n==4?1:2; if((packed>>(27*count))!=0) return false;
        for(uint8_t i=0;i<count;i++) {
            uint32_t event=(uint32_t)((packed>>(27*i))&0x07ffffffu);
            uint16_t id=(uint16_t)(MIDI_ID_MIN+(event&0x1fffu));
            uint8_t velocity=(uint8_t)((event>>20)&0x7fu);
            if(velocity==0) return false;
            for(uint8_t j=0;j<i;j++)
                if(id==(uint16_t)(MIDI_ID_MIN+((packed>>(27*j))&0x1fffu))) return false;
        }
        return true;
    }
    if(f[2]==MIDI_NOTE_OFF_BATCH) {
        uint8_t count=n==2?1:n==4?2:n==5?3:n==7?4:0;
        if(count==0) return false;
        uint64_t packed=0; for(uint8_t i=0;i<n;i++) packed|=(uint64_t)f[7+i]<<(8*i);
        if((packed>>(13*count))!=0) return false;
        for(uint8_t i=0;i<count;i++)
            for(uint8_t j=0;j<i;j++)
                if(((packed>>(13*i))&0x1fffu)==((packed>>(13*j))&0x1fffu)) return false;
        return true;
    }
    return false;
}
static bool midi_error_status(uint8_t status)
{
    return (status>=STATUS_OPCODE && status<=STATUS_ID_CONFLICT) ||
           (status>=STATUS_UNAVAILABLE && status<=STATUS_UNKNOWN) ||
           (status>=MIDI_STATUS_FULL && status<=MIDI_STATUS_SEQUENCE);
}
bool bridge_midi_response_valid(const uint8_t *q,const uint8_t *r)
{
    if(!bridge_midi_request_valid(q,FRAME_SIZE) ||
       !bridge_midi_frame_valid(r,FRAME_SIZE,false) || r[1]!=q[1] ||
       bridge_u16(r+4)!=bridge_u16(q+4) ||
       (r[2]!=(uint8_t)(q[2]|0x80) && r[2]!=MIDI_RESPONSE_ERROR)) return false;
    uint32_t qt=midi_token(q,false),rt=midi_token(r,true);
    if(q[2]!=MIDI_HELLO && !(q[2]==MIDI_DRAIN_STATUS && qt==0) && qt!=rt) return false;
    if(r[2]==MIDI_RESPONSE_ERROR) {
        if(r[3]==STATUS_BUSY && q[2]==MIDI_HELLO)
            return rt!=0 && r[6]==8 && r[8]<=MIDI_SESSION_FAULT &&
                   bridge_u32(r+9)==MIDI_FPGA_BUILD &&
                   r[13]==MIDI_VOICES && r[14]==MIDI_CAPABILITIES;
        return midi_error_status(r[3]) && r[6]==1;
    }
    if(r[3]!=STATUS_OK) return false;
    if(q[2]==MIDI_HELLO) {
        return rt!=0 && r[6]==8 && r[8]<=MIDI_SESSION_FAULT &&
               bridge_u32(r+9)==MIDI_FPGA_BUILD &&
               r[13]==MIDI_VOICES && r[14]==MIDI_CAPABILITIES;
    }
    if(q[2]==MIDI_ALL_NOTES_OFF)
        return r[6]==2 && (r[8]==MIDI_SESSION_QUIESCING || r[8]==MIDI_SESSION_DRAINED);
    if(q[2]==MIDI_DRAIN_STATUS)
        return r[6]==4 && r[8]<=MIDI_SESSION_FAULT &&
               (r[8]!=MIDI_SESSION_QUIESCING || bridge_u16(r+9)!=0);
    return r[6]==1;
}
static void midi_translate_magic(const uint8_t *src,uint8_t magic,uint8_t *dst)
{
    memcpy(dst,src,FRAME_SIZE);
    dst[0]=magic;
    bridge_put16(dst+18,bridge_crc(dst,18));
}
bool bridge_midi_to_uart(const uint8_t *q,uint8_t *u)
{
    if(!u || !bridge_midi_request_valid(q,FRAME_SIZE)) return false;
    midi_translate_magic(q,UART_MAGIC,u);
    return true;
}
bool bridge_uart_to_midi(const uint8_t *q,const uint8_t *u,uint8_t *r)
{
    uint8_t translated_response[FRAME_SIZE];
    if(!r || !bridge_midi_request_valid(q,FRAME_SIZE) ||
       !u || u[0]!=UART_MAGIC || u[1]!=MIDI_PROTOCOL_VERSION ||
       bridge_crc(u,18)!=bridge_u16(u+18))
        return false;
    midi_translate_magic(u,MIDI_PC_MAGIC,translated_response);
    if(!bridge_midi_response_valid(q,translated_response)) return false;
    memcpy(r,translated_response,FRAME_SIZE);
    return true;
}
bool bridge_midi_stream_byte(midi_stream *s,uint8_t byte,uint32_t now,uint8_t *frame)
{
    if(!s || !frame) return false;
    if(s->count && (uint32_t)(now-s->last_ms)>=30) s->count=0;
    s->last_ms=now;
    if(!s->count && byte!=MIDI_PC_MAGIC) return false;
    s->bytes[s->count++]=byte;
    if(s->count<FRAME_SIZE) return false;
    if(bridge_midi_request_valid(s->bytes,FRAME_SIZE)) {
        memcpy(frame,s->bytes,FRAME_SIZE); s->count=0; return true;
    }
    size_t offset=1;
    while(offset<FRAME_SIZE && s->bytes[offset]!=MIDI_PC_MAGIC) offset++;
    s->count=FRAME_SIZE-offset;
    memmove(s->bytes,s->bytes+offset,s->count);
    return false;
}
static void midi_error_frame(const uint8_t *q,uint8_t status,uint8_t *r)
{ bridge_midi_frame(r,MIDI_RESPONSE_ERROR,status,bridge_u16(q+4),
                    midi_token(q,false),NULL,0); }
void bridge_midi_session_clear(midi_session *s)
{
    uint32_t generation=s ? s->generation+1 : 0;
    if(!s) return;
    if(generation==0) generation=1;
    memset(s,0,sizeof(*s)); s->generation=generation;
}
midi_begin_result bridge_midi_begin(midi_session *s,bool worker_busy,
                                    const uint8_t *q,size_t length,uint8_t *r)
{
    if(!s || !q || !r || !bridge_midi_request_valid(q,length))
        return MIDI_BEGIN_REJECT;
    if(s->pending) return memcmp(s->request,q,FRAME_SIZE)==0 ?
        MIDI_BEGIN_WAIT : MIDI_BEGIN_BUSY;
    if(worker_busy) return MIDI_BEGIN_BUSY;
    if(s->cached && bridge_u16(s->request+4)==bridge_u16(q+4)) {
        if(memcmp(s->request,q,FRAME_SIZE)==0) memcpy(r,s->response,FRAME_SIZE);
        else midi_error_frame(q,STATUS_ID_CONFLICT,r);
        return MIDI_BEGIN_RESPONSE;
    }
    memcpy(s->request,q,FRAME_SIZE); s->pending=true; s->cached=false;
    return MIDI_BEGIN_UART;
}
bool bridge_midi_complete(midi_session *s,uint32_t generation,const uint8_t *r)
{
    if(!s || !r || !s->pending || s->generation!=generation ||
       !bridge_midi_response_valid(s->request,r)) return false;
    memcpy(s->response,r,FRAME_SIZE); s->pending=false; s->cached=true;
    return true;
}
bool bridge_frame_valid(const uint8_t *f,size_t length,uint8_t magic,bool request)
{
    if(!f || length!=20 || f[0]!=magic || f[6]>11 || (request&&f[3]!=0) ||
       bridge_crc(f,18)!=bridge_u16(f+18)) return false;
    for(size_t i=7+f[6];i<18;i++) if(f[i]) return false;
    return true;
}
void bridge_frame(uint8_t *f,uint8_t magic,uint8_t op,uint8_t status,uint16_t id,const uint8_t *p,uint8_t length)
{
    memset(f,0,20); f[0]=magic; f[1]=1; f[2]=op; f[3]=status;
    bridge_put16(f+4,id); f[6]=length;
    if(length) memcpy(f+7,p,length);
    bridge_put16(f+18,bridge_crc(f,18));
}
static void error_frame(const uint8_t *q,uint8_t status,uint8_t *r)
{ bridge_frame(r,BLE_MAGIC,OP_ERROR,status,bridge_u16(q+4),NULL,0); }
/* A bounded six-parameter catalog. Even opcodes read, their following odd
 * opcodes write the same parameter. */
static bool parameter_opcode(uint8_t op)
{ return op>=OP_STATE && op<=OP_RELEASE_SET; }
static uint8_t parameter_limit(uint8_t op)
{
    uint8_t get=(uint8_t)(op&0xfe);
    return get==OP_STATE || get==OP_SUSTAIN ? 16 : get==OP_TIMBRE ? 3 : 7;
}
static uint8_t parameter_value(const fpga_state *s,uint8_t op)
{
    uint8_t get=(uint8_t)(op&0xfe);
    if(get==OP_STATE) return s->master;
    if(get==OP_TIMBRE) return s->timbre;
    return s->adsr[(get-OP_ATTACK)/2];
}
static void parameter_store(fpga_state *s,uint8_t op,uint8_t value)
{
    uint8_t get=(uint8_t)(op&0xfe);
    if(get==OP_STATE) s->master=value;
    else if(get==OP_TIMBRE) s->timbre=value;
    else s->adsr[(get-OP_ATTACK)/2]=value;
}
void bridge_session_clear(bridge_session *s)
{
    uint32_t generation=s->generation+1;
    memset(s,0,sizeof(*s)); s->generation=generation;
}
begin_result bridge_begin(bridge_session *s,bool worker_busy,const uint8_t *q,size_t length,uint8_t *r)
{
    uint8_t info[11];
    if(!bridge_frame_valid(q,length,BLE_MAGIC,true)) return BEGIN_REJECT;
    if(s->pending) return memcmp(s->request,q,20)==0?BEGIN_WAIT:BEGIN_BUSY;
    if(worker_busy) return BEGIN_BUSY;
    if(s->cached && bridge_u16(s->request+4)==bridge_u16(q+4)) {
        if(memcmp(s->request,q,20)==0) memcpy(r,s->response,20);
        else error_frame(q,STATUS_ID_CONFLICT,r);
        return BEGIN_RESPONSE;
    }
    if(q[1]!=1) error_frame(q,STATUS_VERSION,r);
    else if(q[2]==OP_PING) bridge_frame(r,BLE_MAGIC,0x81,0,bridge_u16(q+4),q+7,q[6]);
    else if(q[2]==OP_INFO) {
        if(q[6]) error_frame(q,STATUS_PAYLOAD,r);
        else { bridge_info(info); bridge_frame(r,BLE_MAGIC,0x82,0,bridge_u16(q+4),info,11); }
    } else if(parameter_opcode(q[2])) {
        bool writing=(q[2]&1)!=0;
        if((!writing&&q[6]!=0) ||
           (writing&&(q[6]!=7 || q[13]>parameter_limit(q[2])))) error_frame(q,STATUS_PAYLOAD,r);
        else if(writing && !bridge_fpga_build_supported(bridge_u32(q+7))) error_frame(q,STATUS_CONFLICT,r);
        else { memcpy(s->request,q,20); s->cached=false; s->pending=true; return BEGIN_UART; }
    } else error_frame(q,STATUS_OPCODE,r);
    memcpy(s->request,q,20); memcpy(s->response,r,20); s->cached=true;
    return BEGIN_RESPONSE;
}
bool bridge_complete(bridge_session *s,uint32_t generation,const uint8_t *r)
{
    if(!s->pending || s->generation!=generation) return false;
    memcpy(s->response,r,20); s->pending=false; s->cached=true; return true;
}
void bridge_response(const uint8_t *q,uint8_t status,const fpga_state *s,uint8_t *r)
{
    uint8_t p[7];
    if(s) {
        bridge_put32(p,s->build); bridge_put16(p+4,s->revision);
        p[6]=parameter_value(s,q[2]);
    }
    bridge_frame(r,BLE_MAGIC,(uint8_t)(q[2]|0x80),status,bridge_u16(q+4),s?p:NULL,s?7:0);
}
bool bridge_stream_byte(uart_stream *s,uint8_t byte,uint32_t now,uint8_t *frame)
{
    if(s->count && (uint32_t)(now-s->last_ms)>=30) s->count=0;
    s->last_ms=now;
    if(!s->count && byte!=UART_MAGIC) return false;
    s->bytes[s->count++]=byte;
    if(s->count<20) return false;
    if(bridge_frame_valid(s->bytes,20,UART_MAGIC,false)) {
        memcpy(frame,s->bytes,20); s->count=0; return true;
    }
    /* A malformed candidate can contain the next frame's magic. Keep only its
     * bounded suffix. */
    size_t offset=1;
    while(offset<20 && s->bytes[offset]!=UART_MAGIC) offset++;
    s->count=20-offset;
    memmove(s->bytes,s->bytes+offset,s->count);
    return false;
}
bool bridge_uart_reply(const uint8_t *f,uint8_t op,uint16_t id,uint32_t nonce,fpga_state *s,uint8_t *status)
{
    if(!parameter_opcode(op) || !bridge_frame_valid(f,20,UART_MAGIC,false) || f[1]!=1 ||
       bridge_u16(f+4)!=id || f[6]!=11 || bridge_u32(f+7)!=nonce ||
       (f[2]!=(uint8_t)(op|0x80)&&f[2]!=OP_ERROR)) return false;
    if(f[2]==OP_ERROR) { if(f[3]<1 || f[3]>4) return false; }
    else if(f[3]!=0 && (f[3]<STATUS_BUSY || f[3]>STATUS_UNKNOWN)) return false;
    if(!bridge_fpga_build_supported(bridge_u32(f+11))) return false;
    /* FPGA protocol diagnostics use the original MASTER state payload even
     * when the rejected request concerned TIMBRE or an ADSR field. */
    uint8_t state_op=f[2]==OP_ERROR ? OP_STATE : op;
    if(f[17]>parameter_limit(state_op)) return false;
    s->build=bridge_u32(f+11); s->revision=bridge_u16(f+15);
    parameter_store(s,state_op,f[17]);
    *status=f[3];
    return true;
}
bool bridge_cas_matches(const uint8_t *q,const fpga_state *s)
{ return bridge_u32(q+7)==s->build && bridge_u16(q+11)==s->revision; }
bool bridge_ack_matches(const fpga_state *before,const fpga_state *after,
                        uint8_t desired,bool timbre)
{
    return bridge_parameter_ack_matches(before,after,desired,timbre ? OP_TIMBRE : OP_STATE);
}
bool bridge_parameter_ack_matches(const fpga_state *before,const fpga_state *after,
                                  uint8_t desired,uint8_t opcode)
{
    if(!parameter_opcode(opcode) || desired>parameter_limit(opcode)) return false;
    uint16_t expected=(uint16_t)(before->revision+(parameter_value(before,opcode)!=desired));
    return after->build==before->build &&
           parameter_value(after,opcode)==desired &&
           after->revision==expected;
}
void bridge_execute(const uint8_t *q,bridge_exchange_fn exchange,void *context,uint8_t *response)
{
    fpga_state before={0},after={0}; uint8_t status;
    if(!parameter_opcode(q[2])) { error_frame(q,STATUS_OPCODE,response); return; }
    uint8_t operation=(uint8_t)(q[2]&0xfe);
    /* UART FF/1..4 is a well-formed protocol diagnostic; report BLE UNAVAILABLE
     * for it. */
    if(!exchange(operation,NULL,0,250,&before,&status,context) ||
       (status!=STATUS_OK && (status<STATUS_BUSY || status>STATUS_UNKNOWN))) {
        bridge_response(q,STATUS_UNAVAILABLE,NULL,response); return;
    }
    if((q[2]&1)==0 || status!=STATUS_OK) {
        bridge_response(q,status,&before,response); return;
    }
    if(!bridge_cas_matches(q,&before)) {
        bridge_response(q,STATUS_CONFLICT,&before,response); return;
    }
    uint8_t extra[3]; bridge_put16(extra,bridge_u16(q+11)); extra[2]=q[13];
    if(!exchange(q[2],extra,3,500,&after,&status,context) ||
       (status!=STATUS_OK && (status<STATUS_BUSY || status>STATUS_UNKNOWN))) {
        bridge_response(q,STATUS_UNKNOWN,NULL,response); return;
    }
    if(status==STATUS_OK && !bridge_parameter_ack_matches(&before,&after,extra[2],q[2])) {
        bridge_response(q,STATUS_UNKNOWN,NULL,response); return;
    }
    bridge_response(q,status,&after,response);
}
