// Network services of a console that is offline (issue #1, from the second patch there): nifm (no internet), ssl,
// bsd:u (sockets) and ldn:u (local wireless, no network found). Before, sm handed the game a logging stub for them,
// which answers without the objects the game asks for (CreateGeneralService, CreateRequest...): the game used a null
// session and closed when opening local wireless, Mystery Gift or internet co-op. Now those screens open and wait;
// local wireless and the GO Park settings leave with B, the Mystery Gift / internet screens keep their spinner (the
// game polls RecvFrom with no timeout and no cancel there: nothing to download without Nintendo's servers).
// Command shapes as in switchbrew (nn::nifm IGeneralService / IRequest, nn::ldn, bsd).
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../ipc.h"

// An event the game can wait on, signalled already: nothing will ever happen, so a wait on it ends at once.
static uint32_t signalled_event(void) {
    uint32_t w, r;
    KEvent *ev = kernel_create_event_pair(&w, &r);
    pthread_mutex_lock(&g_klock);
    kernel_signal(ev);
    pthread_mutex_unlock(&g_klock);
    return r;
}

// ------------------------------------------------------------------ nifm:u
static void nifm_request(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    switch (req->cmd) {
    case 0: OUT(uint32_t, 0) = 1; resp_size(resp, 4); break;  // GetRequestState: free (done, not accepted)
    case 1: {  // GetResult: no internet connection (2110-0300); LARECOMP_NIFM_ERROR=<result> for experiments
        const char *e = getenv("LARECOMP_NIFM_ERROR");
        resp->result = e && *e ? (uint32_t)strtoul(e, NULL, 0) : MAKE_RESULT(110, 300);
        break;
    }
    case 2:  // GetSystemEventReadableHandles: two events
        resp->copy_handles[resp->ncopy++] = signalled_event();
        resp->copy_handles[resp->ncopy++] = signalled_event();
        break;
    case 4: break;  // Submit: done at once (GetRequestState)
    default: LOG("[nifm] IRequest cmd %u (ok)\n", req->cmd);
    }
}

static void nifm_general(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    switch (req->cmd) {
    case 1: memset(resp->data, 0, 4); resp_size(resp, 4); break;                               // GetClientId
    case 4: ipc_return_object(resp, service_new("IRequest", nifm_request, NULL)); break;      // CreateRequest
    case 18: memset(resp->data, 0, 4); resp_size(resp, 4); break;                              // GetInternetConnectionStatus
    default: LOG("[nifm] IGeneralService cmd %u (ok)\n", req->cmd);
    }
}

SERVICE("nifm:u", nifm_u) {
    (void)s;
    if (req->cmd == 5) ipc_return_object(resp, service_new("IGeneralService", nifm_general, NULL));  // CreateGeneralService
    else LOG("[nifm] nifm:u cmd %u (ok)\n", req->cmd);
}

// ------------------------------------------------------------------ ssl (no TLS)
static void ssl_context(Service *s, IpcReq *req, IpcResp *resp) {
    (void)s;
    LOG("[ssl] ISslContext cmd %u (ok, no TLS)\n", req->cmd);
    memset(resp->data, 0, 0x10);
    resp_size(resp, 0x10);
}

SERVICE("ssl", ssl) {
    (void)s;
    if (req->cmd == 0) ipc_return_object(resp, service_new("ISslContext", ssl_context, NULL));  // CreateContext
    else LOG("[ssl] cmd %u (ok)\n", req->cmd);
}

// ------------------------------------------------------------------ bsd:u (sockets)
// A quiet local network: sockets open, bind and take options; what is sent goes nowhere and nothing ever arrives
// (receive / accept: EAGAIN, poll / select: nothing ready after their timeout, capped); a connect fails with
// ENETUNREACH (no internet). Sword's local wireless layer (Y-Comm, also started by the Mystery Gift menu) opens UDP
// sockets on the local network it creates; when they failed (ENETDOWN) it gave up with error 2618-0006, restarted
// every second, and that closed the Mystery Gift menu. LARECOMP_BSD_OLD=1: the old answers (no socket at all).
static void bsd_ret(IpcResp *resp, int32_t ret, int32_t err) { OUT(int32_t, 0) = ret; OUT(int32_t, 4) = err; resp_size(resp, 8); }
SERVICE("bsd:u", bsd_u) {
    (void)s;
    static int old = -1;
    static int next_fd = 3;
    if (old < 0) old = getenv("LARECOMP_BSD_OLD") != NULL;
    if (old) {
        switch (req->cmd) {
        case 2: case 3: bsd_ret(resp, -1, 100); break;  // Socket: ENETDOWN (Linux errno values, switchbrew)
        case 9: bsd_ret(resp, 1, 0); break;             // RecvFrom: one zero byte
        default: LOG("[bsd] bsd:u cmd %u (ok)\n", req->cmd);
        }
        return;
    }
    switch (req->cmd) {
    case 0: OUT(int32_t, 0) = 0; resp_size(resp, 4); break;   // RegisterClient
    case 1: OUT(int32_t, 0) = 0; resp_size(resp, 4); break;   // StartMonitoring
    case 2: case 3: case 27: bsd_ret(resp, __atomic_fetch_add(&next_fd, 1, __ATOMIC_RELAXED), 0); break;  // Socket(Exempt) / Duplicate
    case 5: case 6: {  // Select / Poll: nothing ready; wait the timeout (Poll: ms in the input; capped at 50 ms)
        int32_t ms = req->cmd == 6 && req->data_size >= 8 ? IN(int32_t, 4) : 10;
        if (ms < 0 || ms > 50) ms = 50;
        if (ms > 0) plat_sleep_until_ns(plat_now_ns() + (uint64_t)ms * 1000000u);
        if (req->cmd == 6 && req->nb) {  // (Poll: the pollfds back, revents 0)
            IpcBuf *in = req->na ? &req->a[0] : req->nx ? &req->x[0] : NULL, *out = &req->b[0];
            if (in && in->addr != out->addr) memcpy((void *)(uintptr_t)out->addr, (const void *)(uintptr_t)in->addr, in->size < out->size ? in->size : out->size);
            for (uint64_t k = 0; k + 8 <= out->size; k += 8) *(int16_t *)(uintptr_t)(out->addr + k + 6) = 0;
        }
        bsd_ret(resp, 0, 0);
        break;
    }
    case 8: case 9: case 12: case 25: bsd_ret(resp, -1, 11); break;   // Recv / RecvFrom / Accept / Read: EAGAIN
    case 10: case 11: case 24: {                                      // Send / SendTo / Write: all of it, nowhere
        int64_t n = req->na ? (int64_t)req->a[0].size : req->nx ? (int64_t)req->x[0].size : 0;
        bsd_ret(resp, (int32_t)n, 0);
        break;
    }
    case 14: bsd_ret(resp, -1, 101); break;                           // Connect: ENETUNREACH
    case 15: case 16: {                                               // GetPeerName / GetSockName: 169.254.1.1
        for (int i = 0; i < req->nb + req->nc; i++) {
            IpcBuf *b = i < req->nb ? &req->b[i] : &req->c[i - req->nb];
            if (b->size >= 8) {
                uint8_t *p = (uint8_t *)(uintptr_t)b->addr;
                memset(p, 0, b->size);
                p[0] = 16, p[1] = 2;                                  // sin_len, AF_INET
                p[4] = 169, p[5] = 254, p[6] = 1, p[7] = 1;
            }
        }
        OUT(int32_t, 0) = 0; OUT(int32_t, 4) = 0; OUT(uint32_t, 8) = 16; resp_size(resp, 12);
        break;
    }
    case 17: OUT(int32_t, 0) = 0; OUT(int32_t, 4) = 0; OUT(uint32_t, 8) = 0; resp_size(resp, 12); break;  // GetSockOpt
    case 7: case 13: case 18: case 19: case 20: case 21: case 22: case 23: case 26:  // Sysctl Bind Listen Ioctl Fcntl SetSockOpt Shutdown(All) Close
        bsd_ret(resp, 0, 0);
        break;
    default: LOG("[bsd] bsd:u cmd %u (ok)\n", req->cmd); bsd_ret(resp, 0, 0);
    }
}

// ------------------------------------------------------------------ ldn:u (local wireless)
// A radio that works with nobody around: the states move as on a console (nn::ldn::State: 0 None, 1 Initialized,
// 2 AccessPoint, 3 AccessPointCreated, 4 Station, 5 StationConnected), a scan finds nothing, a network made here is
// never joined. Before, Initialize2 (402: the one Sword uses) answered ok but left the state None: the game's Y-Comm
// took that as a failure, tore the session down and retried every second, and that retry closed the Mystery Gift
// menu a few frames after it opened (the scene wants the radio quiet). LARECOMP_LDN_OLD=1: the old answers.
// The network made here (nn::ldn::NetworkInfo, 0x480 bytes, layout as in yuzu's ldn_types.h): NetworkId (IntentId +
// SessionId) at 0, CommonNetworkInfo at 0x20 (bssid, ssid, channel, link level, type), LdnNetworkInfo at 0x50
// (security, accept policy, node counts at 0x66 / 0x67, 8 NodeInfo of 0x40 from 0x68, advertise data size at 0x26A,
// the data at 0x26C). Its one node is this console: our address (GetIpv4Address), connected, the user name the game
// gave. A zeroed NetworkInfo had no node: the game took the network as lost and failed (Mystery Gift: error 2618-0006).
typedef struct { uint32_t state; uint8_t info[0x480]; } Ldn;
#define LDN_IP 0xA9FE0101u  // 169.254.1.1

static void ldn_make_network(Ldn *u, const uint8_t *in, uint32_t n) {
    memset(u->info, 0, sizeof u->info);
    uint8_t *ni = u->info;
    if (n >= 0x98) {
        memcpy(ni, in + 0x78, 0x10);                     // IntentId (NetworkConfig at 0x78: after SecurityConfig 0x44,
        int16_t ch = *(const int16_t *)(in + 0x88);      //  UserConfig 0x30 and 4 padding bytes)
        *(int16_t *)(ni + 0x20 + 6 + 34) = ch ? ch : 6;  // channel
        ni[0x50 + 0x16] = in[0x8A] ? in[0x8A] : 8;       // node_count_max
        *(uint16_t *)(ni + 0x50 + 0x10) = *(const uint16_t *)in;  // security mode
        memcpy(ni + 0x68 + 10 + 2, in + 0x44, 33);       // node 0 user name
        *(int16_t *)(ni + 0x68 + 0x2E) = *(const int16_t *)(in + 0x8C);  // local communication version
    }
    for (int i = 0; i < 16; i++) ni[0x10 + i] = (uint8_t)(0x5A ^ (i * 37));  // SessionId
    static const uint8_t mac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
    memcpy(ni + 0x20, mac, 6);                           // bssid
    ni[0x20 + 6] = 32;                                   // ssid: 32 characters
    for (int i = 0; i < 32; i++) ni[0x20 + 7 + i] = "0123456789abcdef"[(i * 7) & 15];
    ni[0x20 + 6 + 34 + 2] = 3;                           // link level: good
    ni[0x20 + 6 + 34 + 3] = 2;                           // network type: ldn
    ni[0x50 + 0x17] = 1;                                 // node_count
    uint8_t *node = ni + 0x68;
    *(uint32_t *)node = LDN_IP;
    memcpy(node + 4, mac, 6);
    node[10] = 0;                                        // node id
    node[11] = 1;                                        // connected
}

static void ldn_user(Service *s, IpcReq *req, IpcResp *resp) {
    Ldn *u = s->state;
    static int old = -1;
    if (old < 0) old = getenv("LARECOMP_LDN_OLD") != NULL;
    uint32_t st = u ? u->state : 0, to = st;
    switch (req->cmd) {
    case 0: OUT(uint32_t, 0) = st; resp_size(resp, 4); break;                    // GetState
    case 1: case 101: {                                                           // GetNetworkInfo(LatestUpdate)
        const uint8_t *src = u && (st == 3 || st == 5) ? u->info : NULL;
        for (int i = 0; i < req->nc + req->nb; i++) {
            IpcBuf *b = i < req->nc ? &req->c[i] : &req->b[i - req->nc];
            void *dst = (void *)(uintptr_t)b->addr;
            memset(dst, 0, b->size);
            if (i == 0 && src) memcpy(dst, src, b->size < sizeof u->info ? b->size : sizeof u->info);
        }
        break;
    }
    case 2:                                                                       // GetIpv4Address: 169.254.1.1 / 255.255.0.0
        OUT(uint32_t, 0) = LDN_IP; OUT(uint32_t, 4) = 0xFFFF0000u; resp_size(resp, 8); break;
    case 3: OUT(uint16_t, 0) = 0; resp_size(resp, 4); break;                      // GetDisconnectReason: none
    case 100: resp->copy_handles[resp->ncopy++] = signalled_event(); break;       // GetStateChangeEvent
    case 102: OUT(uint16_t, 0) = 0; resp_size(resp, 4); break;                    // Scan: no network found
    case 400: case 402: {                                                         // Initialize / Initialize2
        const char *e = getenv("LARECOMP_LDN_RESULT");  // (research: answer with that error, e.g. 0x2ECB airplane mode)
        if (e && *e) resp->result = (uint32_t)strtoul(e, NULL, 0);
        else if (old ? req->cmd == 400 : true) to = 1;
        break;
    }
    case 401: to = 0; break;                                                      // Finalize
    case 200: if (!old) to = 2; break;                                            // OpenAccessPoint
    case 201: if (!old) to = 1; break;                                            // CloseAccessPoint
    case 202: case 203: if (!old) { to = 3; if (u) ldn_make_network(u, req->data, req->data_size); } break;  // CreateNetwork(Private)
    case 204: if (!old) to = 2; break;                                            // DestroyNetwork
    case 300: if (!old) to = 4; break;                                            // OpenStation
    case 301: if (!old) to = 1; break;                                            // CloseStation
    case 302: case 303: if (!old) resp->result = MAKE_RESULT(203, 64); break;     // Connect: no such network
    case 304: if (!old) to = 4; break;                                            // Disconnect
    case 206: {                                                                   // SetAdvertiseData (A buffer)
        IpcBuf *a = req->na ? &req->a[0] : req->nx ? &req->x[0] : NULL;
        if (u && a) {
            uint16_t n = (uint16_t)(a->size < 0x180 ? a->size : 0x180);
            *(uint16_t *)(u->info + 0x26A) = n;
            memcpy(u->info + 0x26C, (const void *)(uintptr_t)a->addr, n);
        }
        break;
    }
    case 205: case 207: case 208: case 209: case 104: break;            // Reject / advertise data / filters
    default: LOG("[ldn] IUserLocalCommunicationService cmd %u (ok, no wireless)\n", req->cmd);
    }
    if (u && to != st) u->state = to;
}

SERVICE("ldn:u", ldn_u) {
    (void)s;
    if (req->cmd == 0) ipc_return_object(resp, service_new("IUserLocalCommunicationService", ldn_user, calloc(1, sizeof(Ldn))));
    else LOG("[ldn] ldn:u cmd %u (ok)\n", req->cmd);
}
