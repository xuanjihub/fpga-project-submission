#include "bridge_protocol.h"
#include <string.h>
#define CHECK(x) do { if(!(x)) return __LINE__; } while(0)

static void repair(uint8_t *frame) { bridge_put16(frame+18,bridge_crc(frame,18)); }
static void master_request(uint8_t *frame,uint16_t id,uint16_t revision,uint8_t master)
{
    uint8_t payload[7]; bridge_put32(payload,EXPECTED_FPGA_BUILD);
    bridge_put16(payload+4,revision); payload[6]=master;
    bridge_frame(frame,BLE_MAGIC,OP_MASTER,0,id,payload,7);
}
static void timbre_request(uint8_t *frame,uint16_t id,uint16_t revision,uint8_t timbre)
{
    uint8_t payload[7]; bridge_put32(payload,EXPECTED_FPGA_BUILD);
    bridge_put16(payload+4,revision); payload[6]=timbre;
    bridge_frame(frame,BLE_MAGIC,OP_TIMBRE_SET,0,id,payload,7);
}
typedef struct {
    unsigned calls; bool fail_read,fail_set,bad_call;
    bool timbre; uint8_t expected_value;
    uint8_t get_opcode;
    uint8_t read_status,set_status;
    fpga_state read_state,set_state;
} exchange_mock;
static bool mock_exchange(uint8_t opcode,const uint8_t *extra,uint8_t length,
                          unsigned deadline,fpga_state *state,uint8_t *status,void *context)
{
    exchange_mock *mock=context; mock->calls++;
    uint8_t read_opcode=mock->get_opcode ? mock->get_opcode : mock->timbre?OP_TIMBRE:OP_STATE;
    uint8_t set_opcode=(uint8_t)(read_opcode+1);
    if(opcode==read_opcode) {
        if(mock->calls!=1 || length!=0 || extra!=NULL || deadline!=250) mock->bad_call=true;
        *state=mock->read_state; *status=mock->read_status; return !mock->fail_read;
    }
    if(opcode!=set_opcode || mock->calls!=2 || length!=3 || deadline!=500 ||
       bridge_u16(extra)!=mock->read_state.revision || extra[2]!=mock->expected_value) mock->bad_call=true;
    *state=mock->set_state; *status=mock->set_status; return !mock->fail_set;
}
static void adsr_request(uint8_t *frame,uint8_t field,uint16_t id,uint16_t revision,uint8_t value)
{
    uint8_t payload[7]; bridge_put32(payload,EXPECTED_FPGA_BUILD);
    bridge_put16(payload+4,revision); payload[6]=value;
    bridge_frame(frame,BLE_MAGIC,(uint8_t)(OP_ATTACK_SET+field*2),0,id,payload,7);
}
static int adsr_selftest(void)
{
    for(uint8_t field=0;field<4;field++) {
        uint8_t get=(uint8_t)(OP_ATTACK+field*2),set=(uint8_t)(get+1);
        uint8_t limit=field==2 ? 16 : 7;
        uint8_t q[20],r[20],other[20],payload[11],frame[20],status=255;
        bridge_session session={0};
        /* Poison unrelated fields so the ACK only depends on the current
         * parameter's independent UART read. */
        fpga_state before,after,decoded;
        memset(&before,0xa5,sizeof(before)); memset(&after,0x5a,sizeof(after));
        before.build=after.build=EXPECTED_FPGA_BUILD;
        before.revision=0xffff; after.revision=0;
        before.adsr[field]=0; after.adsr[field]=limit;
        CHECK(bridge_parameter_ack_matches(&before,&after,limit,set));
        after.revision=0xffff; after.adsr[field]=0;
        CHECK(bridge_parameter_ack_matches(&before,&after,0,set));
        CHECK(!bridge_parameter_ack_matches(&before,&after,limit,set));
        after.revision=0; after.adsr[field]=limit; after.build^=1;
        CHECK(!bridge_parameter_ack_matches(&before,&after,limit,set)); after.build^=1;
        CHECK(!bridge_parameter_ack_matches(&before,&after,(uint8_t)(limit+1),set));

        bridge_frame(q,BLE_MAGIC,get,0,1000,NULL,0);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_UART);
        bridge_response(q,STATUS_OK,&before,r);
        CHECK(bridge_complete(&session,session.generation,r));
        CHECK(r[2]==(uint8_t)(get|0x80) && r[3]==STATUS_OK && r[6]==7 &&
              bridge_u32(r+7)==EXPECTED_FPGA_BUILD && bridge_u16(r+11)==0xffff && r[13]==0);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE);
        for(uint8_t edge=0;edge<2;edge++) {
            uint8_t value=edge ? limit : 0;
            adsr_request(q,field,(uint16_t)(1010+edge),0xffff,value);
            CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_UART);
            after.revision=edge ? 0 : 0xffff; after.adsr[field]=value;
            bridge_response(q,STATUS_OK,&after,r);
            CHECK(bridge_complete(&session,session.generation,r));
            CHECK(r[2]==(uint8_t)(set|0x80) && r[13]==value);
        }
        bridge_frame(q,BLE_MAGIC,get,0,1020,(const uint8_t*)"x",1);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_PAYLOAD);
        adsr_request(q,field,1021,0xffff,(uint8_t)(limit+1));
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_PAYLOAD);
        adsr_request(q,field,1022,0xffff,0); q[6]=6; q[13]=0; repair(q);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_PAYLOAD);
        adsr_request(q,field,1023,0xffff,0); q[6]=8; repair(q);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_PAYLOAD);
        adsr_request(q,field,1024,0xffff,0); bridge_put32(q+7,EXPECTED_FPGA_BUILD^1); repair(q);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_CONFLICT);

        /* Shared public revision means a change to MASTER/TIMBRE or another
         * ADSR field invalidates this parameter's stale expected revision. */
        adsr_request(q,field,1030,0xffff,limit);
        exchange_mock mock={.expected_value=limit,.get_opcode=get,
                            .read_state=before,.set_state=after};
        bridge_execute(q,mock_exchange,&mock,r);
        CHECK(mock.calls==2 && !mock.bad_call && r[3]==STATUS_OK && r[13]==limit && bridge_u16(r+11)==0);
        mock.calls=0; mock.read_state.revision=0;
        bridge_execute(q,mock_exchange,&mock,r);
        CHECK(mock.calls==1 && r[3]==STATUS_CONFLICT);
        mock.calls=0; mock.read_state=before; mock.read_state.build^=1;
        bridge_execute(q,mock_exchange,&mock,r);
        CHECK(mock.calls==1 && r[3]==STATUS_CONFLICT);
        mock.calls=0; mock.read_state=before; mock.fail_read=true;
        bridge_execute(q,mock_exchange,&mock,r);
        CHECK(mock.calls==1 && r[3]==STATUS_UNAVAILABLE && r[6]==0);
        mock.calls=0; mock.fail_read=false; mock.fail_set=true;
        bridge_execute(q,mock_exchange,&mock,r);
        CHECK(mock.calls==2 && r[3]==STATUS_UNKNOWN && r[6]==0);
        /* UNKNOWN is cached before notification, so a duplicate SET is answered
         * from the cache. Different bytes with its ID remain a conflict. */
        bridge_session_clear(&session);
        CHECK(bridge_begin(&session,false,q,20,other)==BEGIN_UART);
        uint32_t generation=session.generation;
        CHECK(bridge_begin(&session,true,q,20,other)==BEGIN_WAIT);
        CHECK(bridge_complete(&session,generation,r)); memcpy(frame,r,20);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && memcmp(frame,r,20)==0);
        memcpy(other,q,20); other[13]=0; repair(other);
        CHECK(bridge_begin(&session,false,other,20,r)==BEGIN_RESPONSE && r[3]==STATUS_ID_CONFLICT);
        bridge_session_clear(&session);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_UART);
        generation=session.generation; bridge_session_clear(&session);
        CHECK(!bridge_complete(&session,generation,r));
        CHECK(bridge_begin(&session,true,q,20,r)==BEGIN_BUSY);
        mock.calls=0; mock.fail_set=false; mock.set_state.revision=1;
        bridge_execute(q,mock_exchange,&mock,r);
        CHECK(mock.calls==2 && r[3]==STATUS_UNKNOWN && r[6]==0);
        for(uint8_t business=STATUS_BUSY;business<=STATUS_UNKNOWN;business++) {
            mock.calls=0; mock.set_status=business;
            bridge_execute(q,mock_exchange,&mock,r);
            CHECK(mock.calls==2 && r[3]==business && r[6]==7);
        }
        mock.calls=0; mock.set_status=STATUS_OK; mock.set_state=before; mock.expected_value=0;
        adsr_request(q,field,1031,0xffff,0);
        bridge_execute(q,mock_exchange,&mock,r);
        CHECK(mock.calls==2 && r[3]==STATUS_OK && bridge_u16(r+11)==0xffff && r[13]==0);
        mock.calls=0; bridge_frame(q,BLE_MAGIC,get,0,1032,NULL,0);
        bridge_execute(q,mock_exchange,&mock,r);
        CHECK(mock.calls==1 && !mock.bad_call && r[2]==(uint8_t)(get|0x80) && r[13]==0);

        /* Independently framed UART replies: all identity and range gates
         * must pass before writing only the selected field in state. */
        bridge_put32(payload,0x89abcdef); bridge_put32(payload+4,EXPECTED_FPGA_BUILD);
        bridge_put16(payload+8,65535); payload[10]=limit;
        for(uint8_t writing=0;writing<2;writing++) {
            uint8_t op=(uint8_t)(get+writing);
            bridge_frame(frame,UART_MAGIC,(uint8_t)(op|0x80),0,1040,payload,11);
            memset(&decoded,0x9b,sizeof(decoded));
            CHECK(bridge_uart_reply(frame,op,1040,0x89abcdef,&decoded,&status));
            CHECK(decoded.adsr[field]==limit && status==STATUS_OK);
            for(uint8_t n=0;n<4;n++) if(n!=field) CHECK(decoded.adsr[n]==0x9b);
            CHECK(decoded.master==0x9b && decoded.timbre==0x9b);
            CHECK(!bridge_uart_reply(frame,op,1041,0x89abcdef,&decoded,&status));
            CHECK(!bridge_uart_reply(frame,op,1040,0x89abcdee,&decoded,&status));
            for(unsigned mutation=0;mutation<6;mutation++) {
                memcpy(other,frame,20);
                const unsigned positions[]={1,2,6,11,17,3};
                const uint8_t values[]={2,(uint8_t)((op^2)|0x80),10,0,(uint8_t)(limit+1),0x16};
                other[positions[mutation]]=values[mutation]; repair(other);
                CHECK(!bridge_uart_reply(other,op,1040,0x89abcdef,&decoded,&status));
            }
            memcpy(other,frame,20); other[18]^=1;
            CHECK(!bridge_uart_reply(other,op,1040,0x89abcdef,&decoded,&status));
            /* FF protocol diagnostics always return MASTER, independent of the
             * requested field: MASTER=16 is legal for a failed A/D/R command,
             * while MASTER=5 leaves the ADSR fields untouched. */
            for(uint8_t master_case=0;master_case<2;master_case++) {
                uint8_t master=master_case ? 5 : 16;
                payload[10]=master;
                for(uint8_t diagnostic=STATUS_OPCODE;diagnostic<=STATUS_ID_CONFLICT;diagnostic++) {
                    bridge_frame(other,UART_MAGIC,OP_ERROR,diagnostic,1040,payload,11);
                    memset(&decoded,0x9b,sizeof(decoded));
                    CHECK(bridge_uart_reply(other,op,1040,0x89abcdef,&decoded,&status));
                    CHECK(decoded.build==EXPECTED_FPGA_BUILD && decoded.revision==65535 &&
                          decoded.master==master && decoded.timbre==0x9b && status==diagnostic);
                    for(uint8_t n=0;n<4;n++) CHECK(decoded.adsr[n]==0x9b);
                }
            }
            payload[10]=17;
            bridge_frame(other,UART_MAGIC,OP_ERROR,STATUS_PAYLOAD,1040,payload,11);
            CHECK(!bridge_uart_reply(other,op,1040,0x89abcdef,&decoded,&status));
            payload[10]=limit;
        }
    }
    return 0;
}
int bridge_selftest(void)
{
    /* Golden CRC vector for this frame. */
#ifdef BRIDGE_COMBINED
    static const uint8_t info_expected[20]={0xb1,1,0x82,0,1,0,11,1,0,5,0,1,0x31,0x31,0x4e,20,11,0xff,0x11,0x22};
#else
    static const uint8_t info_expected[20]={0xb1,1,0x82,0,1,0,11,1,0,4,0,4,0x37,0x30,0x4e,20,11,0xff,0x25,0x97};
#endif
    static const uint8_t uart_golden[20]={0xb2,1,0x90,0,1,0,11,0x78,0x56,0x34,0x12,3,0x4b,0x31,0x50,0x34,0x12,8,0x00,0x02};
    uint8_t q[20],r[20],other[20],payload[11],received[20],timbre_uart[20],timbre_payload[11];
    bridge_session session={0},before;
    fpga_state state,before_state={EXPECTED_FPGA_BUILD,0xffff,8,2,{0}},after_state={EXPECTED_FPGA_BUILD,0,9,3,{0}};
    uint8_t status=255; uart_stream stream={0};
    CHECK(bridge_crc((const uint8_t*)"123456789",9)==0x29b1);
    bridge_info(payload); CHECK(payload[0]==1 && payload[10]==0xff);
    bridge_frame(q,BLE_MAGIC,OP_INFO,0,1,NULL,0);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE);
    CHECK(memcmp(r,info_expected,20)==0);
    CHECK(bridge_frame_valid(q,20,BLE_MAGIC,true));
    for(size_t length=0;length<20;length++) CHECK(!bridge_frame_valid(q,length,BLE_MAGIC,true));
    CHECK(!bridge_frame_valid(q,21,BLE_MAGIC,true));
    for(size_t i=0;i<20;i++) for(unsigned bit=0;bit<8;bit++) {
        memcpy(other,q,20); other[i]^=(uint8_t)(1u<<bit);
        CHECK(!bridge_frame_valid(other,20,BLE_MAGIC,true));
    }
    memcpy(other,q,20); other[3]=1; repair(other);
    CHECK(!bridge_frame_valid(other,20,BLE_MAGIC,true));
    other[3]=0; other[6]=12; repair(other);
    CHECK(!bridge_frame_valid(other,20,BLE_MAGIC,true));
    other[6]=0; other[17]=1; repair(other);
    CHECK(!bridge_frame_valid(other,20,BLE_MAGIC,true));
    before=session;
    CHECK(bridge_begin(&session,false,other,20,r)==BEGIN_REJECT);
    CHECK(memcmp(&before,&session,sizeof(session))==0);

    for(uint8_t length=0;length<=11;length++) {
        for(uint8_t i=0;i<length;i++) payload[i]=i;
        bridge_frame(q,BLE_MAGIC,OP_PING,0,(uint16_t)(100+length),payload,length);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE);
        CHECK(r[2]==0x81 && r[3]==0 && r[6]==length && memcmp(r+7,payload,length)==0);
    }
    bridge_frame(q,BLE_MAGIC,OP_STATE,0,200,NULL,0);
    CHECK(bridge_begin(&session,true,q,20,r)==BEGIN_BUSY);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_UART);
    CHECK(session.pending && !session.cached);
    before=session;
    CHECK(bridge_begin(&session,true,q,20,r)==BEGIN_WAIT);
    CHECK(memcmp(&before,&session,sizeof(session))==0);
    bridge_frame(other,BLE_MAGIC,OP_STATE,0,201,NULL,0);
    CHECK(bridge_begin(&session,true,other,20,r)==BEGIN_BUSY);
    CHECK(memcmp(&before,&session,sizeof(session))==0);
    memcpy(other,q,20); other[2]=OP_INFO; repair(other);
    CHECK(bridge_begin(&session,true,other,20,r)==BEGIN_BUSY);
    CHECK(memcmp(&before,&session,sizeof(session))==0);
    bridge_response(q,STATUS_UNKNOWN,NULL,r);
    CHECK(!bridge_complete(&session,session.generation+1,r));
    CHECK(session.pending);
    CHECK(bridge_complete(&session,session.generation,r));
    CHECK(session.cached && !session.pending);
    memcpy(received,r,20);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE);
    CHECK(memcmp(received,r,20)==0); /* UNKNOWN retry cannot dispatch UART */
    before=session;
    memcpy(other,q,20); other[2]=OP_INFO; repair(other);
    CHECK(bridge_begin(&session,false,other,20,r)==BEGIN_RESPONSE);
    CHECK(r[2]==OP_ERROR && r[3]==STATUS_ID_CONFLICT);
    CHECK(memcmp(&session,&before,sizeof(session))==0);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE);
    CHECK(memcmp(received,r,20)==0);

    /* Disconnect/unsubscribe invalidates completion even if a connection handle
     * is reused. An old worker still blocks requests until its completion. */
    bridge_frame(q,BLE_MAGIC,OP_STATE,0,202,NULL,0);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_UART);
    uint32_t old_generation=session.generation;
    bridge_session_clear(&session);
    CHECK(!bridge_complete(&session,old_generation,r));
    CHECK(bridge_begin(&session,true,q,20,r)==BEGIN_BUSY);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_UART);
    bridge_response(q,STATUS_UNAVAILABLE,NULL,r);
    CHECK(bridge_complete(&session,session.generation,r));

    for(unsigned version=0;version<256;version++) if(version!=1) {
        bridge_frame(q,BLE_MAGIC,OP_STATE,0,(uint16_t)(300+version),NULL,0);
        q[1]=(uint8_t)version; repair(q);
        CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE);
        CHECK(r[2]==OP_ERROR && r[3]==STATUS_VERSION && r[6]==0 && r[1]==1);
    }
    bridge_frame(q,BLE_MAGIC,0x7f,0,600,NULL,0);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_OPCODE);
    bridge_frame(q,BLE_MAGIC,OP_STATE,0,601,(const uint8_t*)"x",1);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_PAYLOAD);
    master_request(q,602,0xffff,17);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_PAYLOAD);
    master_request(q,603,0xffff,9); q[7]^=1; repair(q);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_CONFLICT);
    master_request(q,604,0xffff,9);
    CHECK(bridge_cas_matches(q,&before_state));
    CHECK(!bridge_cas_matches(q,&after_state));
    CHECK(bridge_ack_matches(&before_state,&after_state,9,false)); /* wrap */
    after_state.revision=0xffff; after_state.master=8;
    CHECK(bridge_ack_matches(&before_state,&after_state,8,false)); /* same-value no commit */
    CHECK(!bridge_ack_matches(&before_state,&after_state,9,false));

    /* TIMBRE uses the same CAS/revision contract as MASTER, but keeps its
     * value and response opcode independent.  Exercise GET, SET, validation,
     * and the revision wrap at the BLE session boundary. */
    bridge_frame(q,BLE_MAGIC,OP_TIMBRE,0,605,NULL,0);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_UART);
    fpga_state timbre_read={EXPECTED_FPGA_BUILD,12,8,1,{0}};
    bridge_response(q,STATUS_OK,&timbre_read,r);
    CHECK(bridge_complete(&session,session.generation,r));
    CHECK(r[2]==(uint8_t)(OP_TIMBRE|0x80) && r[3]==STATUS_OK &&
          bridge_u32(r+7)==EXPECTED_FPGA_BUILD && bridge_u16(r+11)==12 && r[13]==1);
    timbre_request(q,606,12,3);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_UART);
    fpga_state timbre_after={EXPECTED_FPGA_BUILD,13,8,3,{0}};
    bridge_response(q,STATUS_OK,&timbre_after,r);
    CHECK(bridge_complete(&session,session.generation,r));
    CHECK(r[2]==(uint8_t)(OP_TIMBRE_SET|0x80) && r[13]==3 && bridge_u16(r+11)==13);
    bridge_frame(q,BLE_MAGIC,OP_TIMBRE,0,607,(const uint8_t*)"x",1);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_PAYLOAD);
    timbre_request(q,608,12,4);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_PAYLOAD);
    timbre_request(q,609,12,3); bridge_put32(q+7,EXPECTED_FPGA_BUILD^1); repair(q);
    CHECK(bridge_begin(&session,false,q,20,r)==BEGIN_RESPONSE && r[3]==STATUS_CONFLICT);
    fpga_state timbre_wrap_before={EXPECTED_FPGA_BUILD,0xffff,8,2,{0}};
    fpga_state timbre_wrap_after={EXPECTED_FPGA_BUILD,0,8,3,{0}};
    CHECK(bridge_ack_matches(&timbre_wrap_before,&timbre_wrap_after,3,true));
    timbre_wrap_after.revision=0xffff; timbre_wrap_after.timbre=2;
    CHECK(bridge_ack_matches(&timbre_wrap_before,&timbre_wrap_after,2,true));
    CHECK(!bridge_ack_matches(&timbre_wrap_before,&timbre_wrap_after,3,true));

    /* UART TIMBRE replies reject a wrong build, nonce, opcode, or value while
     * accepting both GET_TIMBRE and SET_TIMBRE response opcodes. */
    bridge_put32(timbre_payload,0x12345678);
    bridge_put32(timbre_payload+4,EXPECTED_FPGA_BUILD);
    bridge_put16(timbre_payload+8,0xffff); timbre_payload[10]=3;
    bridge_frame(timbre_uart,UART_MAGIC,(uint8_t)(OP_TIMBRE|0x80),0,7,timbre_payload,11);
    CHECK(bridge_uart_reply(timbre_uart,OP_TIMBRE,7,0x12345678,&state,&status));
    CHECK(status==STATUS_OK && state.build==EXPECTED_FPGA_BUILD &&
          state.revision==0xffff && state.timbre==3);
    timbre_uart[2]=(uint8_t)(OP_TIMBRE_SET|0x80); repair(timbre_uart);
    CHECK(bridge_uart_reply(timbre_uart,OP_TIMBRE_SET,7,0x12345678,&state,&status));
    timbre_uart[2]=(uint8_t)(OP_MASTER|0x80); repair(timbre_uart);
    CHECK(!bridge_uart_reply(timbre_uart,OP_TIMBRE,7,0x12345678,&state,&status));
    timbre_uart[2]=(uint8_t)(OP_TIMBRE|0x80); timbre_uart[7]^=1; repair(timbre_uart);
    CHECK(!bridge_uart_reply(timbre_uart,OP_TIMBRE,7,0x12345678,&state,&status));
    timbre_uart[7]^=1; bridge_put32(timbre_uart+11,EXPECTED_FPGA_BUILD^1); repair(timbre_uart);
    CHECK(!bridge_uart_reply(timbre_uart,OP_TIMBRE,7,0x12345678,&state,&status));
    bridge_put32(timbre_uart+11,EXPECTED_FPGA_BUILD); timbre_uart[17]=4; repair(timbre_uart);
    CHECK(!bridge_uart_reply(timbre_uart,OP_TIMBRE,7,0x12345678,&state,&status));

    CHECK(bridge_uart_reply(uart_golden,OP_STATE,1,0x12345678,&state,&status));
    CHECK(status==0 && state.build==EXPECTED_FPGA_BUILD && state.revision==0x1234 && state.master==8);
    CHECK(!bridge_uart_reply(uart_golden,OP_MASTER,1,0x12345678,&state,&status));
    CHECK(!bridge_uart_reply(uart_golden,OP_STATE,2,0x12345678,&state,&status));
    CHECK(!bridge_uart_reply(uart_golden,OP_STATE,1,0x12345679,&state,&status));
    for(unsigned field=0;field<6;field++) {
        memcpy(other,uart_golden,20);
        const unsigned positions[]={1,3,6,7,11,17};
        other[positions[field]]=field==1?0x16:(field==5?17:0);
        repair(other);
        CHECK(!bridge_uart_reply(other,OP_STATE,1,0x12345678,&state,&status));
    }
    for(unsigned value=STATUS_BUSY;value<=STATUS_UNKNOWN;value++) {
        memcpy(other,uart_golden,20); other[3]=(uint8_t)value; repair(other);
        CHECK(bridge_uart_reply(other,OP_STATE,1,0x12345678,&state,&status));
        CHECK(status==value);
    }
    /* Garbage, corrupt-frame resynchronization, and interbyte timeout. */
    CHECK(!bridge_stream_byte(&stream,0,0,received));
    for(size_t i=0;i<20;i++) CHECK(bridge_stream_byte(&stream,uart_golden[i],(uint32_t)i,received)==(i==19));
    CHECK(memcmp(received,uart_golden,20)==0);
    for(size_t i=0;i<10;i++) CHECK(!bridge_stream_byte(&stream,uart_golden[i],(uint32_t)(30+i),received));
    for(size_t i=0;i<20;i++) CHECK(bridge_stream_byte(&stream,uart_golden[i],(uint32_t)(100+i),received)==(i==19));
    CHECK(!bridge_stream_byte(&stream,UART_MAGIC,200,received));
    CHECK(!bridge_stream_byte(&stream,0,201,received));
    for(size_t i=0;i<20;i++) CHECK(bridge_stream_byte(&stream,uart_golden[i],(uint32_t)(202+i),received)==(i==19));
    CHECK(memcmp(received,uart_golden,20)==0);
    /* The transaction path invokes exactly one preflight and at most one SET. */
    master_request(q,700,0xffff,9);
    exchange_mock mock={.expected_value=9,
                        .read_state={EXPECTED_FPGA_BUILD,0xffff,8,2,{0}},
                        .set_state={EXPECTED_FPGA_BUILD,0,9,2,{0}}};
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==2 && !mock.bad_call && r[3]==STATUS_OK && r[6]==7);
    mock.calls=0; mock.fail_read=true;
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==1 && r[3]==STATUS_UNAVAILABLE && r[6]==0);
    mock.calls=0; mock.fail_read=false; mock.read_state.revision=10;
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==1 && r[3]==STATUS_CONFLICT && r[6]==7);
    mock.calls=0; mock.read_state.revision=0xffff; mock.read_status=STATUS_BUSY;
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==1 && r[3]==STATUS_BUSY);
    mock.calls=0; mock.read_status=STATUS_OK; mock.fail_set=true;
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==2 && r[3]==STATUS_UNKNOWN && r[6]==0);
    mock.calls=0; mock.fail_set=false; mock.set_state.revision=1;
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==2 && r[3]==STATUS_UNKNOWN && r[6]==0);
    mock.calls=0; mock.set_status=STATUS_CANCELLED;
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==2 && r[3]==STATUS_CANCELLED && r[6]==7);
    mock.calls=0; mock.set_status=STATUS_UNKNOWN;
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==2 && r[3]==STATUS_UNKNOWN && r[6]==7);
    mock.calls=0; mock.read_status=STATUS_OPCODE;
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==1 && r[2]==0x91 && r[3]==STATUS_UNAVAILABLE && r[6]==0);
    mock.calls=0; mock.read_status=STATUS_OK; mock.set_status=STATUS_ID_CONFLICT;
    bridge_execute(q,mock_exchange,&mock,r);
    CHECK(mock.calls==2 && r[2]==0x91 && r[3]==STATUS_UNKNOWN && r[6]==0);

    /* The TIMBRE transaction follows the same one-read/one-set rule. A changed
     * value wraps revision at 0xffff; writing the current value keeps revision
     * unchanged. */
    timbre_request(q,701,0xffff,3);
    exchange_mock timbre_mock={.timbre=true,.expected_value=3,
                                .read_state={EXPECTED_FPGA_BUILD,0xffff,8,2,{0}},
                                .set_state={EXPECTED_FPGA_BUILD,0,8,3,{0}}};
    bridge_execute(q,mock_exchange,&timbre_mock,r);
    CHECK(timbre_mock.calls==2 && !timbre_mock.bad_call &&
          r[2]==(uint8_t)(OP_TIMBRE_SET|0x80) && r[3]==STATUS_OK && r[6]==7 &&
          bridge_u16(r+11)==0 && r[13]==3);
    timbre_request(q,702,0xffff,2);
    timbre_mock.calls=0; timbre_mock.bad_call=false; timbre_mock.expected_value=2;
    timbre_mock.read_state.revision=0xffff; timbre_mock.read_state.timbre=2;
    timbre_mock.set_state.revision=0xffff; timbre_mock.set_state.timbre=2;
    bridge_execute(q,mock_exchange,&timbre_mock,r);
    CHECK(timbre_mock.calls==2 && !timbre_mock.bad_call && r[3]==STATUS_OK &&
          bridge_u16(r+11)==0xffff && r[13]==2);
    timbre_request(q,703,0xffff,3);
    timbre_mock.calls=0; timbre_mock.bad_call=false; timbre_mock.expected_value=3;
    timbre_mock.read_status=STATUS_OK; timbre_mock.set_status=STATUS_UNKNOWN;
    timbre_mock.fail_set=true;
    bridge_execute(q,mock_exchange,&timbre_mock,r);
    CHECK(timbre_mock.calls==2 && r[2]==(uint8_t)(OP_TIMBRE_SET|0x80) &&
          r[3]==STATUS_UNKNOWN && r[6]==0);
    timbre_mock.calls=0; timbre_mock.bad_call=false; timbre_mock.fail_set=false;
    timbre_mock.set_status=STATUS_UNKNOWN;
    bridge_execute(q,mock_exchange,&timbre_mock,r);
    CHECK(timbre_mock.calls==2 && r[2]==(uint8_t)(OP_TIMBRE_SET|0x80) &&
          r[3]==STATUS_UNKNOWN && r[6]==7);
    timbre_mock.calls=0; timbre_mock.read_status=STATUS_UNKNOWN;
    bridge_execute(q,mock_exchange,&timbre_mock,r);
    CHECK(timbre_mock.calls==1 && r[2]==(uint8_t)(OP_TIMBRE_SET|0x80) &&
          r[3]==STATUS_UNKNOWN && r[6]==7);
    return adsr_selftest();
}
