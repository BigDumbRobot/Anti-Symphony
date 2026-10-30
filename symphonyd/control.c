// Device control and OSC for symphonyd.
//
// Keeps a cached copy of every setting it knows (see buildParams), refreshes it from the box,
// and serves it over OSC (UDP). Clients send /symphony/subscribe to receive every change,
// including changes made on the front panel. Everything runs on the main thread.
#include "control.h"
#include "osc.h"
#include <CoreAudio/CoreAudio.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

void logf_(const char *fmt, ...);   // symphonyd.c

typedef enum {
    K_ATTEN,   // byte = attenuation in dB (0..64); OSC float dB (0 .. -64)
    K_BOOL,    // 0/1; OSC int
    K_INT,     // raw byte; OSC int
    K_FADER,   // byte = dB + 48; OSC float dB (-48 .. 0)
    K_PAN,     // byte 0..127, 64 = centre; OSC float -1 .. 1
    K_ROUTE,   // routing: addr = destination, value = source; OSC int
    K_REF,     // analog I/O type (reference level); OSC int
} Kind;

typedef struct {
    char path[64];
    uint8_t cmd, len;
    uint32_t addr;
    Kind kind;
    bool fast;        // refresh every tick (front-panel controls)
    bool readonly;
    bool known;
    int value;
    int recheck;      // ticks until a written value is read back
} Param;

#define MAX_PARAMS 512
#define SLOW_PER_TICK 40
#define SUB_SECONDS 60.0
#define MAX_SUBS 16

static Param gP[MAX_PARAMS];
static int gN, gNext;
static SymDev gDev;
static int gSock = -1;
static uint32_t gRate;

typedef struct { struct sockaddr_storage a; socklen_t len; double expires; } Sub;
static Sub gSubs[MAX_SUBS];

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// ---- parameter table ----

static Param *add(Kind k, uint8_t cmd, uint32_t addr, uint8_t len, bool fast, bool ro, const char *fmt, ...) {
    if (gN == MAX_PARAMS) return NULL;
    Param *p = &gP[gN++];
    memset(p, 0, sizeof *p);
    p->kind = k; p->cmd = cmd; p->addr = addr; p->len = len; p->fast = fast; p->readonly = ro;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(p->path, sizeof p->path, fmt, ap);
    va_end(ap);
    return p;
}

// Monitor output index for dim (0xE7) and mono (0xE8): main = 2, headphone n = n - 1.
static void buildParams(int boardType) {
    gN = 0;
    add(K_ATTEN, 0x26, 0, 1, true, false, "/symphony/monitor/main/level");
    add(K_BOOL,  0x27, 0, 1, true, false, "/symphony/monitor/main/mute");
    add(K_BOOL,  0xE7, 2, 1, true, false, "/symphony/monitor/main/dim");
    add(K_BOOL,  0xE8, 2, 1, true, false, "/symphony/monitor/main/mono");
    add(K_INT,   0xE9, 0, 1, true, false, "/symphony/monitor/speakerset");
    add(K_INT,   0x25, 0, 1, false, false, "/symphony/monitor/main/mode");
    add(K_INT,   0x2A, 0, 1, true, false, "/symphony/monitor/frontpanel");
    for (int h = 1; h <= 2; h++) {
        add(K_ATTEN, 0x23, h - 1, 1, true, false, "/symphony/monitor/hp/%d/level", h);
        add(K_BOOL,  0x24, h - 1, 1, true, false, "/symphony/monitor/hp/%d/mute", h);
        add(K_BOOL,  0xE7, h - 1, 1, true, false, "/symphony/monitor/hp/%d/dim", h);
        add(K_BOOL,  0xE8, h - 1, 1, true, false, "/symphony/monitor/hp/%d/mono", h);
    }
    add(K_INT, 0x54, 0, 1, false, false, "/symphony/monitor/hp/assign");

    // Analog I/O on board 1 (8x8 boards: 8 channels).
    int analog = (boardType == 2 || boardType == 3) ? 8 : 0;
    for (int c = 1; c <= analog; c++) {
        add(K_REF,  0x60, (uint32_t)(c - 1), 1, false, false, "/symphony/io/analog/in/%d/ref", c);
        add(K_REF,  0x60, 0x80000000u | (uint32_t)(c - 1), 1, false, false, "/symphony/io/analog/out/%d/ref", c);
        add(K_BOOL, 0x22, (uint32_t)(c - 1), 1, false, false, "/symphony/io/analog/in/%d/softlimit", c);
    }
    if (boardType == 3) add(K_BOOL, 0x34, 0, 1, false, false, "/symphony/io/optical/spdif");

    // Routing, by destination ID (see docs/protocol.md).
    for (int d = 0x00; d <= 0x2F; d++) add(K_ROUTE, 0x31, (uint32_t)d, 1, false, false, "/symphony/route/%d", d);
    for (int d = 0xB0; d <= 0xB7; d++) add(K_ROUTE, 0x31, (uint32_t)d, 1, false, false, "/symphony/route/%d", d);

    // Mixers 1 and 2: inputs 1-16, master (0x20) and software return (0x21).
    static const char *names[] = {"fader", "pan", "solo", "mute"};
    static const Kind kinds[] = {K_FADER, K_PAN, K_BOOL, K_BOOL};
    for (int m = 1; m <= 2; m++) {
        for (int i = 0; i < 18; i++) {
            uint32_t in = i < 16 ? (uint32_t)i : (i == 16 ? 0x20u : 0x21u);
            char who[16];
            if (i < 16) snprintf(who, sizeof who, "in/%d", i + 1);
            else snprintf(who, sizeof who, "%s", i == 16 ? "master" : "return");
            for (int f = 0; f < 4; f++)
                add(kinds[f], (uint8_t)(0xB0 + f), (uint32_t)m << 16 | in, 1, false, false,
                    "/symphony/mixer/%d/%s/%s", m, who, names[f]);
        }
    }

    add(K_INT, 0x50, 0, 4, false, true, "/symphony/clock/source");
    add(K_INT, 0x51, 0, 5, false, true, "/symphony/clock/external");
}

static Param *find(const char *path) {
    for (int i = 0; i < gN; i++)
        if (!strcmp(gP[i].path, path)) return &gP[i];
    return NULL;
}

static double toOsc(const Param *p) {
    switch (p->kind) {
    case K_ATTEN: return -(double)p->value;
    case K_FADER: return p->value - 48.0;
    case K_PAN:   return (p->value - 64) / 64.0;
    default:      return p->value;
    }
}

static bool isFloat(const Param *p) {
    return p->kind == K_ATTEN || p->kind == K_FADER || p->kind == K_PAN;
}

static int clampi(long v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : (int)v; }

static int fromOsc(const Param *p, double x) {
    switch (p->kind) {
    case K_ATTEN: return clampi(lround(-x), 0, 64);
    case K_FADER: return clampi(lround(x + 48), 0, 48);
    case K_PAN:   return clampi(lround(64 + x * 64), 0, 127);
    case K_BOOL:  return x != 0;
    default:      return clampi(lround(x), 0, 255);
    }
}

// ---- OSC output ----

static void sendTo(const struct sockaddr_storage *a, socklen_t len, const uint8_t *buf, size_t n) {
    if (gSock >= 0 && n) sendto(gSock, buf, n, 0, (const struct sockaddr *)a, len);
}

static size_t buildValue(uint8_t *buf, size_t cap, const Param *p) {
    if (isFloat(p)) return osc_build(buf, cap, p->path, "f", toOsc(p));
    return osc_build(buf, cap, p->path, "i", (int)toOsc(p));
}

static void broadcast(const uint8_t *buf, size_t n) {
    double t = now();
    for (int i = 0; i < MAX_SUBS; i++)
        if (gSubs[i].len && gSubs[i].expires > t) sendTo(&gSubs[i].a, gSubs[i].len, buf, n);
}

static void broadcastParam(const Param *p) {
    uint8_t buf[128];
    broadcast(buf, buildValue(buf, sizeof buf, p));
}

static void sendState(const struct sockaddr_storage *a, socklen_t len) {
    uint8_t buf[128];
    sendTo(a, len, buf, osc_build(buf, sizeof buf, "/symphony/connected", "i", gDev ? 1 : 0));
    if (!gDev) return;
    sendTo(a, len, buf, osc_build(buf, sizeof buf, "/symphony/clock/rate", "f", (double)gRate));
    for (int i = 0; i < gN; i++)
        if (gP[i].known) sendTo(a, len, buf, buildValue(buf, sizeof buf, &gP[i]));
}

static void sendError(const struct sockaddr_storage *a, socklen_t len, const char *path, const char *why) {
    uint8_t buf[256];
    sendTo(a, len, buf, osc_build(buf, sizeof buf, "/symphony/error", "ss", path, why));
}

// ---- device access ----

static bool readParam(Param *p) {
    uint8_t b[16] = {0};
    if (sym_read(gDev, p->cmd, p->addr, b, p->len) < 1) return false;
    int v = b[0];
    if (!p->known || v != p->value) {
        p->value = v;
        p->known = true;
        broadcastParam(p);
    }
    return true;
}

static bool writeParam(Param *p, int raw) {
    uint8_t b[2];
    bool ok;
    switch (p->kind) {
    case K_ROUTE:
        b[0] = (uint8_t)p->addr; b[1] = (uint8_t)raw;
        ok = sym_write(gDev, 0x31, 0, b, 2) == 2;
        break;
    case K_REF: {
        // Write 0x20 with [type, trim], keeping the trim the box has for that type.
        uint32_t io = p->addr & 0x80000000u, ch = p->addr & 0x7FFF;
        uint8_t t[2] = {0};
        if (sym_read(gDev, 0x20, io | ch << 16 | (uint32_t)raw, t, 2) != 2) return false;
        b[0] = (uint8_t)raw; b[1] = t[1];
        ok = sym_write(gDev, 0x20, io | ch, b, 2) == 2;
        break;
    }
    default:
        b[0] = (uint8_t)raw;
        ok = sym_write(gDev, p->cmd, p->addr, b, 1) == 1;
    }
    // The box applies writes a moment later, so an immediate read-back returns the old value.
    // Trust a successful write; the regular poll corrects the cache if the box disagrees.
    if (ok) {
        p->value = raw;
        p->known = true;
        broadcastParam(p);
        p->recheck = 2;
    }
    return ok;
}

static void readRate(void) {
    uint8_t b[12];
    if (sym_read(gDev, 0x28, 1, b, sizeof b) != sizeof b) return;
    uint32_t r = (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3];
    if (r != gRate) {
        gRate = r;
        uint8_t buf[64];
        broadcast(buf, osc_build(buf, sizeof buf, "/symphony/clock/rate", "f", (double)r));
    }
}

// The sample rate belongs to the Mac side: Apple's driver runs the USB stream, so set it through Core Audio.
static bool setSampleRate(double rate) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectID ids[128];
    UInt32 sz = sizeof ids;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids)) return false;
    for (UInt32 i = 0; i < sz / sizeof *ids; i++) {
        AudioObjectPropertyAddress na = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        AudioObjectPropertyAddress ta = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        CFStringRef name = NULL;
        UInt32 transport = 0, s1 = sizeof name, s2 = sizeof transport;
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &s1, &name) || !name) continue;
        AudioObjectGetPropertyData(ids[i], &ta, 0, NULL, &s2, &transport);
        char buf[256];
        CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        CFRelease(name);
        if (transport != kAudioDeviceTransportTypeUSB || !strstr(buf, "Symphony")) continue;
        AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
        Float64 r = rate;
        return AudioObjectSetPropertyData(ids[i], &ra, 0, NULL, sizeof r, &r) == noErr;
    }
    return false;
}

// ---- OSC input ----

static void subscribe(const struct sockaddr_storage *a, socklen_t len, bool on) {
    Sub *slot = NULL;
    double t = now();
    for (int i = 0; i < MAX_SUBS; i++) {
        if (gSubs[i].len == len && !memcmp(&gSubs[i].a, a, len)) { slot = &gSubs[i]; break; }
    }
    if (!on) { if (slot) memset(slot, 0, sizeof *slot); return; }
    for (int i = 0; i < MAX_SUBS && !slot; i++)
        if (!gSubs[i].len || gSubs[i].expires <= t) slot = &gSubs[i];
    if (!slot) return;
    slot->a = *a;
    slot->len = len;
    slot->expires = t + SUB_SECONDS;
}

static bool endsWith(const char *s, const char *suffix) {
    size_t n = strlen(s), m = strlen(suffix);
    return n > m && !strcmp(s + n - m, suffix);
}

static void handle(const OscMsg *m, const struct sockaddr_storage *from, socklen_t flen) {
    const char *path = m->path;
    uint8_t buf[128];

    if (!strcmp(path, "/symphony/subscribe")) { subscribe(from, flen, true); sendState(from, flen); return; }
    if (!strcmp(path, "/symphony/renew")) { subscribe(from, flen, true); return; }
    if (!strcmp(path, "/symphony/unsubscribe")) { subscribe(from, flen, false); return; }
    if (!strcmp(path, "/symphony/dump")) { sendState(from, flen); return; }

    if (!gDev) { sendError(from, flen, path, "Symphony not connected"); return; }

    if (!strcmp(path, "/symphony/identify")) {
        uint8_t on = m->argc ? osc_num(&m->argv[0]) != 0 : 1;
        sym_write(gDev, 0x33, 0, &on, 1);
        return;
    }
    if (!strcmp(path, "/symphony/clock/rate")) {
        if (!m->argc) { sendTo(from, flen, buf, osc_build(buf, sizeof buf, path, "f", (double)gRate)); return; }
        double r = osc_num(&m->argv[0]);
        if (r != 44100 && r != 48000 && r != 88200 && r != 96000) { sendError(from, flen, path, "rate must be 44100, 48000, 88200 or 96000"); return; }
        if (!setSampleRate(r)) sendError(from, flen, path, "Core Audio refused the rate change");
        return;
    }

    // <param>, <param>/toggle, <param>/inc [step], <param>/dec [step]
    char base[64];
    snprintf(base, sizeof base, "%s", path);
    enum { SET, TOGGLE, INC, DEC } op = SET;
    if (endsWith(base, "/toggle")) { op = TOGGLE; base[strlen(base) - 7] = 0; }
    else if (endsWith(base, "/inc")) { op = INC; base[strlen(base) - 4] = 0; }
    else if (endsWith(base, "/dec")) { op = DEC; base[strlen(base) - 4] = 0; }

    Param *p = find(base);
    if (!p) { sendError(from, flen, path, "unknown address"); return; }
    if (op == SET && !m->argc) {
        if (p->known) sendTo(from, flen, buf, buildValue(buf, sizeof buf, p));
        return;
    }
    if (p->readonly) { sendError(from, flen, path, "read-only"); return; }
    if (!p->known && !readParam(p)) { sendError(from, flen, path, "can't read current value"); return; }

    int raw;
    if (op == TOGGLE) {
        if (p->kind != K_BOOL) { sendError(from, flen, path, "toggle needs an on/off control"); return; }
        raw = !p->value;
    } else if (op == INC || op == DEC) {
        double step = m->argc ? osc_num(&m->argv[0]) : 1.0;
        raw = fromOsc(p, toOsc(p) + (op == INC ? step : -step));
    } else {
        if (m->argv[0].type == 's') { sendError(from, flen, path, "expected a number"); return; }
        raw = fromOsc(p, osc_num(&m->argv[0]));
    }
    if (!writeParam(p, raw))
        sendError(from, flen, path, "the box rejected the change");
}

static void onReadable(void) {
    uint8_t buf[2048];
    for (;;) {
        struct sockaddr_storage from;
        socklen_t flen = sizeof from;
        ssize_t n = recvfrom(gSock, buf, sizeof buf, 0, (struct sockaddr *)&from, &flen);
        if (n <= 0) return;
        OscMsg m;
        if (osc_parse(buf, (size_t)n, &m)) handle(&m, &from, flen);
    }
}

// ---- public ----

bool ctl_init(const char *bindAddr, int port) {
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, bindAddr, &sa.sin_addr) != 1) { logf_("bad OSC bind address %s", bindAddr); return false; }
    gSock = socket(AF_INET, SOCK_DGRAM, 0);
    int one = 1;
    setsockopt(gSock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (gSock < 0 || bind(gSock, (struct sockaddr *)&sa, sizeof sa)) {
        logf_("can't listen for OSC on %s:%d", bindAddr, port);
        if (gSock >= 0) close(gSock);
        gSock = -1;
        return false;
    }
    fcntl(gSock, F_SETFL, O_NONBLOCK);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)gSock, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{ onReadable(); });
    dispatch_resume(src);
    logf_("OSC listening on %s:%d", bindAddr, port);
    return true;
}

void ctl_attach(SymDev dev, int boardType) {
    gDev = dev;
    buildParams(boardType);
    gNext = 0;
    gRate = 0;
    int failed = 0;
    for (int i = 0; i < gN; i++)
        if (!readParam(&gP[i])) failed++;
    readRate();
    logf_("control: %d settings read (board type %d)%s", gN - failed, boardType, failed ? ", some failed" : "");
    uint8_t buf[64];
    broadcast(buf, osc_build(buf, sizeof buf, "/symphony/connected", "i", 1));
}

void ctl_detach(SymDev dev) {
    if (!gDev || gDev != dev) return;
    gDev = NULL;
    for (int i = 0; i < gN; i++) gP[i].known = false;
    uint8_t buf[64];
    broadcast(buf, osc_build(buf, sizeof buf, "/symphony/connected", "i", 0));
}

void ctl_tick(void) {
    if (!gDev) return;
    for (int i = 0; i < gN; i++) {
        Param *p = &gP[i];
        if (p->fast) readParam(p);
        else if (p->recheck && !--p->recheck) readParam(p);
    }
    readRate();
    for (int k = 0; k < SLOW_PER_TICK && gN; k++) {
        Param *p = &gP[gNext];
        gNext = (gNext + 1) % gN;
        if (!p->fast) readParam(p);
    }
}
