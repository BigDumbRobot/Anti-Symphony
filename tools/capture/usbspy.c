// usbspy: logs every USB control request a process sends through IOUSBLib.
// Load with DYLD_INSERT_LIBRARIES into an ad-hoc signed copy of Apogee's daemon.
// It only observes: every call is passed through unchanged.
//
// Log: one line per request to $USBSPY_LOG (default /tmp/usbspy.log)
//   <ms> <dev|ifN> <sync|async> bm=.. req=.. val=.. idx=.. len=.. [-> done=.. ret=..] data...
//
// Build: clang -dynamiclib -framework IOKit -framework CoreFoundation usbspy.c -o usbspy.dylib
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

static FILE *gLog;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static double gT0;

static double nowMs(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

static void openLog(void) {
    if (gLog) return;
    const char *p = getenv("USBSPY_LOG");
    gLog = fopen(p ? p : "/tmp/usbspy.log", "a");
    if (gLog) setvbuf(gLog, NULL, _IOLBF, 0);
    gT0 = nowMs();
}

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    pthread_mutex_lock(&gLock);
    openLog();
    if (gLog) {
        va_list ap; va_start(ap, fmt);
        fprintf(gLog, "%10.1f ", nowMs() - gT0);
        vfprintf(gLog, fmt, ap);
        va_end(ap);
    }
    pthread_mutex_unlock(&gLock);
}

static void hex(char *out, size_t cap, const void *buf, size_t n) {
    const unsigned char *b = buf;
    size_t o = 0;
    if (!buf) { snprintf(out, cap, "-"); return; }
    for (size_t i = 0; i < n && o + 4 < cap; i++) o += snprintf(out + o, cap - o, "%02x", b[i]);
    if (o == 0) out[0] = 0;
}

static void logReq(const char *who, const char *kind, UInt8 bm, UInt8 req, UInt16 val, UInt16 idx,
                   UInt16 len, const void *data, UInt32 done, IOReturn ret, int after) {
    char h[2048];
    // OUT data is known before the call; IN data only after it completes.
    int isIn = (bm & 0x80) != 0;
    if ((isIn && after) || (!isIn && !after)) hex(h, sizeof h, data, isIn ? done : len);
    else h[0] = 0;
    if (after)
        logf_("%s %s bm=%02x req=%02x val=%04x idx=%04x len=%u -> done=%u ret=%08x %s\n",
              who, kind, bm, req, val, idx, len, done, ret, h);
    else
        logf_("%s %s bm=%02x req=%02x val=%04x idx=%04x len=%u submit %s\n",
              who, kind, bm, req, val, idx, len, h);
}

// ---------- device requests ----------

typedef IOReturn (*DevReqFn)(void *self, IOUSBDevRequest *r);
typedef IOReturn (*DevReqAsyncFn)(void *self, IOUSBDevRequest *r, IOAsyncCallback1 cb, void *ref);
typedef IOReturn (*DevReqTOFn)(void *self, IOUSBDevRequestTO *r);
typedef IOReturn (*DevReqAsyncTOFn)(void *self, IOUSBDevRequestTO *r, IOAsyncCallback1 cb, void *ref);

static DevReqFn oDevReq; static DevReqAsyncFn oDevReqAsync;
static DevReqTOFn oDevReqTO; static DevReqAsyncTOFn oDevReqAsyncTO;

typedef struct {
    IOAsyncCallback1 cb; void *ref; const char *who;
    UInt8 bm, req; UInt16 val, idx, len; void *data;
} AsyncCtx;

static void asyncDone(void *refcon, IOReturn result, void *arg0) {
    AsyncCtx *c = refcon;
    UInt32 done = (UInt32)(uintptr_t)arg0;
    logReq(c->who, "async", c->bm, c->req, c->val, c->idx, c->len, c->data, done, result, 1);
    IOAsyncCallback1 cb = c->cb; void *ref = c->ref;
    free(c);
    if (cb) cb(ref, result, arg0);
}

static AsyncCtx *mkCtx(const char *who, IOAsyncCallback1 cb, void *ref, UInt8 bm, UInt8 req,
                       UInt16 val, UInt16 idx, UInt16 len, void *data) {
    AsyncCtx *c = calloc(1, sizeof *c);
    c->cb = cb; c->ref = ref; c->who = who;
    c->bm = bm; c->req = req; c->val = val; c->idx = idx; c->len = len; c->data = data;
    return c;
}

#define LOGSYNC(who, R, call) ({ \
    logReq(who, "sync", (R)->bmRequestType, (R)->bRequest, (R)->wValue, (R)->wIndex, (R)->wLength, (R)->pData, 0, 0, 0); \
    IOReturn _r = call; \
    logReq(who, "sync", (R)->bmRequestType, (R)->bRequest, (R)->wValue, (R)->wIndex, (R)->wLength, (R)->pData, (R)->wLenDone, _r, 1); \
    _r; })

static IOReturn hDevReq(void *s, IOUSBDevRequest *r) { return LOGSYNC("dev", r, oDevReq(s, r)); }
static IOReturn hDevReqTO(void *s, IOUSBDevRequestTO *r) { return LOGSYNC("dev", r, oDevReqTO(s, r)); }
static IOReturn hDevReqAsync(void *s, IOUSBDevRequest *r, IOAsyncCallback1 cb, void *ref) {
    logReq("dev", "async", r->bmRequestType, r->bRequest, r->wValue, r->wIndex, r->wLength, r->pData, 0, 0, 0);
    AsyncCtx *c = mkCtx("dev", cb, ref, r->bmRequestType, r->bRequest, r->wValue, r->wIndex, r->wLength, r->pData);
    IOReturn ret = oDevReqAsync(s, r, asyncDone, c);
    if (ret) { logf_("dev async submit failed %08x\n", ret); free(c); }
    return ret;
}
static IOReturn hDevReqAsyncTO(void *s, IOUSBDevRequestTO *r, IOAsyncCallback1 cb, void *ref) {
    logReq("dev", "async", r->bmRequestType, r->bRequest, r->wValue, r->wIndex, r->wLength, r->pData, 0, 0, 0);
    AsyncCtx *c = mkCtx("dev", cb, ref, r->bmRequestType, r->bRequest, r->wValue, r->wIndex, r->wLength, r->pData);
    IOReturn ret = oDevReqAsyncTO(s, r, asyncDone, c);
    if (ret) { logf_("dev asyncTO submit failed %08x\n", ret); free(c); }
    return ret;
}

// ---------- interface requests and pipes ----------

typedef IOReturn (*IfReqFn)(void *self, UInt8 pipe, IOUSBDevRequest *r);
typedef IOReturn (*IfReqAsyncFn)(void *self, UInt8 pipe, IOUSBDevRequest *r, IOAsyncCallback1 cb, void *ref);
typedef IOReturn (*IfReqTOFn)(void *self, UInt8 pipe, IOUSBDevRequestTO *r);
typedef IOReturn (*IfReqAsyncTOFn)(void *self, UInt8 pipe, IOUSBDevRequestTO *r, IOAsyncCallback1 cb, void *ref);
typedef IOReturn (*PipeFn)(void *self, UInt8 pipe, void *buf, UInt32 *size);
typedef IOReturn (*WPipeFn)(void *self, UInt8 pipe, void *buf, UInt32 size);
typedef IOReturn (*PipeAsyncFn)(void *self, UInt8 pipe, void *buf, UInt32 size, IOAsyncCallback1 cb, void *ref);

static IfReqFn oIfReq; static IfReqAsyncFn oIfReqAsync;
static IfReqTOFn oIfReqTO; static IfReqAsyncTOFn oIfReqAsyncTO;
static PipeFn oReadPipe; static WPipeFn oWritePipe;
static PipeAsyncFn oReadPipeAsync, oWritePipeAsync;

static IOReturn hIfReq(void *s, UInt8 p, IOUSBDevRequest *r) { return LOGSYNC("if", r, oIfReq(s, p, r)); }
static IOReturn hIfReqTO(void *s, UInt8 p, IOUSBDevRequestTO *r) { return LOGSYNC("if", r, oIfReqTO(s, p, r)); }
static IOReturn hIfReqAsync(void *s, UInt8 p, IOUSBDevRequest *r, IOAsyncCallback1 cb, void *ref) {
    logReq("if", "async", r->bmRequestType, r->bRequest, r->wValue, r->wIndex, r->wLength, r->pData, 0, 0, 0);
    AsyncCtx *c = mkCtx("if", cb, ref, r->bmRequestType, r->bRequest, r->wValue, r->wIndex, r->wLength, r->pData);
    IOReturn ret = oIfReqAsync(s, p, r, asyncDone, c);
    if (ret) free(c);
    return ret;
}
static IOReturn hIfReqAsyncTO(void *s, UInt8 p, IOUSBDevRequestTO *r, IOAsyncCallback1 cb, void *ref) {
    logReq("if", "async", r->bmRequestType, r->bRequest, r->wValue, r->wIndex, r->wLength, r->pData, 0, 0, 0);
    AsyncCtx *c = mkCtx("if", cb, ref, r->bmRequestType, r->bRequest, r->wValue, r->wIndex, r->wLength, r->pData);
    IOReturn ret = oIfReqAsyncTO(s, p, r, asyncDone, c);
    if (ret) free(c);
    return ret;
}
static IOReturn hReadPipe(void *s, UInt8 p, void *b, UInt32 *n) {
    IOReturn r = oReadPipe(s, p, b, n);
    char h[2048]; hex(h, sizeof h, b, n ? *n : 0);
    logf_("pipe%u read ret=%08x %s\n", p, r, h);
    return r;
}
static IOReturn hWritePipe(void *s, UInt8 p, void *b, UInt32 n) {
    char h[2048]; hex(h, sizeof h, b, n);
    logf_("pipe%u write %s\n", p, h);
    return oWritePipe(s, p, b, n);
}
static IOReturn hReadPipeAsync(void *s, UInt8 p, void *b, UInt32 n, IOAsyncCallback1 cb, void *ref) {
    logf_("pipe%u readAsync size=%u\n", p, n);
    return oReadPipeAsync(s, p, b, n, cb, ref);
}
static IOReturn hWritePipeAsync(void *s, UInt8 p, void *b, UInt32 n, IOAsyncCallback1 cb, void *ref) {
    char h[2048]; hex(h, sizeof h, b, n);
    logf_("pipe%u writeAsync %s\n", p, h);
    return oWritePipeAsync(s, p, b, n, cb, ref);
}

// ---------- vtable patching ----------

static int writable(void *addr, size_t n) {
    long pg = sysconf(_SC_PAGESIZE);
    uintptr_t start = (uintptr_t)addr & ~(uintptr_t)(pg - 1);
    uintptr_t end = ((uintptr_t)addr + n + pg - 1) & ~(uintptr_t)(pg - 1);
    return mprotect((void *)start, end - start, PROT_READ | PROT_WRITE) == 0;
}

// Saves the original only the first time, and only patches a slot that still holds it.
#define PATCH(vt, T, field, orig, hook) do { \
    void **slot = (void **)((char *)(vt) + offsetof(T, field)); \
    if (*slot != (void *)(hook)) { \
        if (!orig) orig = (__typeof__(orig))*slot; \
        if (*slot == (void *)orig) *slot = (void *)(hook); \
        else logf_("slot " #field " holds an unexpected function, left alone\n"); \
    } \
} while (0)

static void patchDevice(void *iface) {
    IOUSBDeviceInterface182 *vt = *(IOUSBDeviceInterface182 **)iface;
    if (!writable(vt, sizeof *vt)) { logf_("mprotect device vtable failed\n"); return; }
    PATCH(vt, IOUSBDeviceInterface182, DeviceRequest, oDevReq, hDevReq);
    PATCH(vt, IOUSBDeviceInterface182, DeviceRequestAsync, oDevReqAsync, hDevReqAsync);
    PATCH(vt, IOUSBDeviceInterface182, DeviceRequestTO, oDevReqTO, hDevReqTO);
    PATCH(vt, IOUSBDeviceInterface182, DeviceRequestAsyncTO, oDevReqAsyncTO, hDevReqAsyncTO);
    logf_("patched device vtable %p\n", (void *)vt);
}

static void patchInterface(void *iface) {
    IOUSBInterfaceInterface182 *vt = *(IOUSBInterfaceInterface182 **)iface;
    if (!writable(vt, sizeof *vt)) { logf_("mprotect interface vtable failed\n"); return; }
    PATCH(vt, IOUSBInterfaceInterface182, ControlRequest, oIfReq, hIfReq);
    PATCH(vt, IOUSBInterfaceInterface182, ControlRequestAsync, oIfReqAsync, hIfReqAsync);
    PATCH(vt, IOUSBInterfaceInterface182, ControlRequestTO, oIfReqTO, hIfReqTO);
    PATCH(vt, IOUSBInterfaceInterface182, ControlRequestAsyncTO, oIfReqAsyncTO, hIfReqAsyncTO);
    PATCH(vt, IOUSBInterfaceInterface182, ReadPipe, oReadPipe, hReadPipe);
    PATCH(vt, IOUSBInterfaceInterface182, WritePipe, oWritePipe, hWritePipe);
    PATCH(vt, IOUSBInterfaceInterface182, ReadPipeAsync, oReadPipeAsync, hReadPipeAsync);
    PATCH(vt, IOUSBInterfaceInterface182, WritePipeAsync, oWritePipeAsync, hWritePipeAsync);
    logf_("patched interface vtable %p\n", (void *)vt);
}

// Wrap the plug-in's QueryInterface so we see which USB interface the caller asks for.
typedef HRESULT (*QIFn)(void *self, REFIID iid, LPVOID *ppv);
static QIFn oQI;

static int iidIn(REFIID iid, const CFUUIDRef *list, size_t n) {
    for (size_t i = 0; i < n; i++) {
        CFUUIDBytes b = CFUUIDGetUUIDBytes(list[i]);
        if (memcmp(&b, &iid, sizeof b) == 0) return 1;
    }
    return 0;
}

static HRESULT hQI(void *self, REFIID iid, LPVOID *ppv) {
    HRESULT r = oQI(self, iid, ppv);
    if (r == S_OK && ppv && *ppv) {
        CFUUIDRef u = CFUUIDCreateFromUUIDBytes(NULL, iid);
        CFStringRef s = CFUUIDCreateString(NULL, u);
        char buf[64]; CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
        CFRelease(s); CFRelease(u);
        // Patch only when the caller asked for a USB device or interface interface
        // (not the plug-in's own IUnknown, whose table is a different shape).
        const CFUUIDRef devIDs[] = { kIOUSBDeviceInterfaceID182, kIOUSBDeviceInterfaceID187,
            kIOUSBDeviceInterfaceID197, kIOUSBDeviceInterfaceID245, kIOUSBDeviceInterfaceID300,
            kIOUSBDeviceInterfaceID320, kIOUSBDeviceInterfaceID500, kIOUSBDeviceInterfaceID650 };
        const CFUUIDRef ifIDs[] = { kIOUSBInterfaceInterfaceID182, kIOUSBInterfaceInterfaceID183,
            kIOUSBInterfaceInterfaceID190, kIOUSBInterfaceInterfaceID192, kIOUSBInterfaceInterfaceID197,
            kIOUSBInterfaceInterfaceID220, kIOUSBInterfaceInterfaceID245, kIOUSBInterfaceInterfaceID300,
            kIOUSBInterfaceInterfaceID500, kIOUSBInterfaceInterfaceID550, kIOUSBInterfaceInterfaceID650,
            kIOUSBInterfaceInterfaceID700 };
        if (iidIn(iid, devIDs, sizeof devIDs / sizeof *devIDs)) {
            logf_("QueryInterface %s (device)\n", buf);
            patchDevice(*ppv);
        } else if (iidIn(iid, ifIDs, sizeof ifIDs / sizeof *ifIDs)) {
            logf_("QueryInterface %s (interface)\n", buf);
            patchInterface(*ppv);
        } else {
            logf_("QueryInterface %s (not patched)\n", buf);
        }
    }
    return r;
}

static kern_return_t my_IOCreatePlugInInterfaceForService(io_service_t svc, CFUUIDRef type, CFUUIDRef iface,
                                                          IOCFPlugInInterface ***plug, SInt32 *score) {
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, type, iface, plug, score);
    if (kr == KERN_SUCCESS && plug && *plug) {
        io_name_t cls = {0};
        IOObjectGetClass(svc, cls);
        logf_("CreatePlugIn on %s\n", cls);
        pthread_mutex_lock(&gLock);
        IOCFPlugInInterface *vt = **plug;
        if (writable(vt, sizeof *vt) && vt->QueryInterface != hQI) {
            if (!oQI) oQI = vt->QueryInterface;
            vt->QueryInterface = hQI;
        }
        pthread_mutex_unlock(&gLock);
    }
    return kr;
}

__attribute__((used)) static struct { const void *rep, *orig; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)my_IOCreatePlugInInterfaceForService, (const void *)IOCreatePlugInInterfaceForService },
};

__attribute__((constructor)) static void init(void) { logf_("usbspy loaded pid %d\n", getpid()); }
