#include "symusb.h"
#include <string.h>
#include <unistd.h>
#include <IOKit/IOCFPlugIn.h>

// Commands we know and allow. r = may read, w = may write.
static const struct { uint8_t cmd; const char *rw; const char *name; } kAllowed[] = {
    {0x03, "w",  "sample rate code"},
    {0x10, "w",  "front panel metering mode"},
    {0x11, "w",  "front panel peak hold"},
    {0x12, "w",  "front panel over hold"},
    {0x13, "w",  "clear front panel meters"},
    {0x20, "rw", "analog I/O type"},
    {0x21, "rw", "digital reference level"},
    {0x22, "rw", "soft limit"},
    {0x23, "rw", "headphone volume"},
    {0x24, "rw", "headphone mute"},
    {0x25, "rw", "speaker output mode"},
    {0x26, "rw", "speaker output volume"},
    {0x27, "rw", "speaker output mute"},
    {0x28, "r",  "parameter updates"},
    {0x2A, "rw", "front panel output selection"},
    {0x2B, "r",  "pop-up needs update"},
    {0x30, "r",  "TDM meter data"},
    {0x31, "rw", "routing"},
    {0x32, "rw", "device channel bank"},
    {0x33, "w",  "identify"},
    {0x34, "rw", "optical is S/PDIF"},
    {0x35, "rw", "S/PDIF coax replace input"},
    {0x36, "rw", "S/PDIF coax mirror output"},
    {0x37, "rw", "prefix"},
    {0x50, "rw", "clock mode"},
    // 0x51 (external clock status) is deliberately absent: reading it crashes the box
    // (hung after 1,540 reads in testing; the box reboots and loses settings).
    {0x52, "r",  "digital input status"},
    {0x53, "rw", "Pro Tools star-sync mode"},
    {0x54, "rw", "headphone assignment"},
    {0x55, "rw", "mixer visibility mask"},
    {0x60, "r",  "current analog I/O type"},
    {0xA0, "r",  "firmware version"},
    {0xA1, "r",  "I/O board type"},
    {0xB0, "rw", "mixer fader"},
    {0xB1, "rw", "mixer pan"},
    {0xB2, "rw", "mixer solo"},
    {0xB3, "rw", "mixer mute"},
    {0xC0, "r",  "unique ID"},
    {0xC3, "rw", "mic gain"},
    {0xC4, "rw", "instrument gain"},
    {0xC5, "rw", "phase invert"},
    {0xC6, "rw", "phantom power"},
    {0xC7, "rw", "mic pre group"},
    {0xC8, "rw", "mic pre insert"},
    {0xC9, "rw", "mic pre insert enable"},
    {0xCA, "rw", "high-pass filter"},
    {0xCD, "r",  "daemon disabled from firmware"},
    {0xDB, "r",  "reset request"},
    {0xDD, "rw", "host ready lock (0 = host ready)"},
    {0xDE, "r",  "preference settings"},
    {0xE7, "rw", "dim"},
    {0xE8, "rw", "sum to mono"},
    {0xE9, "rw", "active speaker set"},
    {0xFF, "r",  "system ready"},
};

static IOReturn gLastError = kIOReturnSuccess;

const char *sym_cmd_name(uint8_t cmd, char mode) {
    for (size_t i = 0; i < sizeof kAllowed / sizeof *kAllowed; i++)
        if (kAllowed[i].cmd == cmd && strchr(kAllowed[i].rw, mode)) return kAllowed[i].name;
    return NULL;
}

IOReturn sym_last_error(void) { return gLastError; }

static void setInt(CFMutableDictionaryRef d, CFStringRef key, int v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

CFMutableDictionaryRef sym_matching(void) {
    CFMutableDictionaryRef d = IOServiceMatching("IOUSBHostDevice");
    if (d) {
        setInt(d, CFSTR(kUSBVendorID), SYM_VID);
        setInt(d, CFSTR(kUSBProductID), SYM_PID);
    }
    return d;
}

SymDev sym_open(io_service_t svc) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    SymDev dev = NULL;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || !plug) { gLastError = kr ? kr : kIOReturnError; return NULL; }
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr || !dev) { gLastError = kIOReturnUnsupported; return NULL; }
    return dev;
}

SymDev sym_open_first(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, sym_matching(), &it) != KERN_SUCCESS) return NULL;
    SymDev dev = NULL;
    io_service_t svc;
    while (!dev && (svc = IOIteratorNext(it))) {
        dev = sym_open(svc);
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return dev;
}

void sym_close(SymDev dev) {
    if (dev) (*dev)->Release(dev);
}

static int request(SymDev dev, bool write, uint8_t cmd, uint32_t addr, void *buf, uint16_t len) {
    if (!sym_cmd_name(cmd, write ? 'w' : 'r')) { gLastError = kIOReturnNotPermitted; return -1; }
    IOUSBDevRequestTO r = {0};
    r.bmRequestType = write ? 0x40 : 0xC0;
    r.bRequest = cmd;
    r.wValue = (UInt16)(addr >> 16);
    r.wIndex = (UInt16)(addr & 0xFFFF);
    r.wLength = len;
    r.pData = buf;
    r.noDataTimeout = 500;
    r.completionTimeout = 1000;
    // Apogee retries twice with a 1 ms pause.
    IOReturn ret = kIOReturnError;
    for (int attempt = 0; attempt < 3; attempt++) {
        r.wLenDone = 0;
        ret = (*dev)->DeviceRequestTO(dev, &r);
        if (ret == kIOReturnSuccess) { gLastError = ret; return (int)r.wLenDone; }
        if (ret == kIOReturnNoDevice) break;   // unplugged: retrying won't help
        usleep(1000);
    }
    gLastError = ret;
    return -1;
}

int sym_read(SymDev dev, uint8_t cmd, uint32_t addr, void *buf, uint16_t len) {
    return request(dev, false, cmd, addr, buf, len);
}

int sym_write(SymDev dev, uint8_t cmd, uint32_t addr, const void *buf, uint16_t len) {
    return request(dev, true, cmd, addr, (void *)buf, len);
}

int sym_system_ready(SymDev dev) {
    uint8_t b[4];
    if (sym_read(dev, 0xFF, 0, b, 4) != 4) return -1;
    uint32_t v = (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3];
    return v == SYM_READY_MAGIC;
}

int sym_get_host_ready(SymDev dev) {
    uint8_t lock;
    if (sym_read(dev, 0xDD, 0, &lock, 1) != 1) return -1;
    return lock == 0;
}

int sym_set_host_ready(SymDev dev, bool ready) {
    uint8_t want = ready ? 0 : 1;
    for (int attempt = 0; attempt < 10; attempt++) {
        uint8_t got = 0xFF;
        if (sym_write(dev, 0xDD, 0, &want, 1) == 1 && sym_read(dev, 0xDD, 0, &got, 1) == 1 && got == want)
            return 0;
        if (gLastError == kIOReturnNoDevice) break;
        usleep(5000);
    }
    return -1;
}

int sym_reenumerate(io_service_t svc) {
    SymDev dev = sym_open(svc);
    if (!dev) return -1;
    IOReturn r = (*dev)->USBDeviceOpenSeize(dev);
    if (r == kIOReturnSuccess) {
        r = (*dev)->USBDeviceReEnumerate(dev, 0);
        (*dev)->USBDeviceClose(dev);
    }
    sym_close(dev);
    gLastError = r;
    return r == kIOReturnSuccess ? 0 : -1;
}
