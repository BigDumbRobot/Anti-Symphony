// symctl: talk to an Apogee Symphony I/O Mk1 over USB using its vendor control protocol.
// See docs/protocol.md. Only commands on the allowlist below can be sent; firmware,
// DFU and reset commands are deliberately absent.
//
//   symctl dump                         read every known status value
//   symctl read  <cmd> <addr> <len>     raw read, e.g. symctl read 0x26 0 1
//   symctl write <cmd> <addr> <hex>     raw write, e.g. symctl write 0x27 0 01
//
// Build: clang -O2 -framework IOKit -framework CoreFoundation symctl.c -o symctl
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define APOGEE_VID 0x0C60
#define SYMPHONY_PID 0x0010

// Commands we know and allow. r = may read, w = may write.
static const struct { unsigned char cmd; const char *rw; const char *name; } kAllowed[] = {
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
    {0x51, "r",  "external clock status"},
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
    {0xDD, "r",  "preference load lock"},
    {0xDE, "r",  "preference settings"},
    {0xE7, "rw", "dim"},
    {0xE8, "rw", "sum to mono"},
    {0xE9, "rw", "active speaker set"},
    {0xFF, "r",  "system ready"},
};

static const char *allowed(unsigned cmd, char mode) {
    for (size_t i = 0; i < sizeof kAllowed / sizeof *kAllowed; i++)
        if (kAllowed[i].cmd == cmd && strchr(kAllowed[i].rw, mode)) return kAllowed[i].name;
    return NULL;
}

static IOUSBDeviceInterface **gDev;

static int intProp(io_service_t s, CFStringRef key) {
    int val = -1;
    CFTypeRef r = IORegistryEntryCreateCFProperty(s, key, NULL, 0);
    if (r) {
        if (CFGetTypeID(r) == CFNumberGetTypeID()) CFNumberGetValue(r, kCFNumberIntType, &val);
        CFRelease(r);
    }
    return val;
}

static int openSymphony(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it)) return -1;
    io_service_t svc;
    while ((svc = IOIteratorNext(it))) {
        if (intProp(svc, CFSTR("idVendor")) == APOGEE_VID && intProp(svc, CFSTR("idProduct")) == SYMPHONY_PID) {
            IOCFPlugInInterface **plug = NULL; SInt32 score;
            if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                                  &plug, &score) == KERN_SUCCESS && plug) {
                (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&gDev);
                (*plug)->Release(plug);
            }
        }
        IOObjectRelease(svc);
        if (gDev) break;
    }
    IOObjectRelease(it);
    return gDev ? 0 : -1;
}

// Returns bytes transferred, or -1.
static int request(int write, unsigned cmd, unsigned addr, void *data, unsigned len) {
    if (!allowed(cmd, write ? 'w' : 'r')) {
        fprintf(stderr, "refusing %s of command 0x%02x: not on the allowlist\n", write ? "write" : "read", cmd);
        return -1;
    }
    IOUSBDevRequestTO r = {0};
    r.bmRequestType = write ? 0x40 : 0xC0;
    r.bRequest = (UInt8)cmd;
    r.wValue = (UInt16)(addr >> 16);
    r.wIndex = (UInt16)(addr & 0xFFFF);
    r.wLength = (UInt16)len;
    r.pData = data;
    r.noDataTimeout = 500;
    r.completionTimeout = 1000;
    IOReturn ret = kIOReturnError;
    for (int attempt = 0; attempt < 3; attempt++) {
        ret = (*gDev)->DeviceRequestTO(gDev, &r);
        if (ret == kIOReturnSuccess) return (int)r.wLenDone;
    }
    fprintf(stderr, "command 0x%02x addr 0x%x failed: 0x%08x\n", cmd, addr, ret);
    return -1;
}

static void printHex(const unsigned char *b, int n) {
    for (int i = 0; i < n; i++) printf("%02x", b[i]);
}

static void show(unsigned cmd, unsigned addr, unsigned len) {
    unsigned char buf[64] = {0};
    int n = request(0, cmd, addr, buf, len);
    printf("  %02x %-8x %-30s ", cmd, addr, allowed(cmd, 'r'));
    if (n < 0) { printf("(failed)\n"); return; }
    printHex(buf, n);
    if (n == 1) printf("  (%d)", (signed char)buf[0]);
    printf("\n");
}

static int dump(void) {
    printf("identity\n");
    show(0xFF, 0, 4);
    for (unsigned t = 0; t < 3; t++) show(0xA0, t, 3);
    show(0xA1, 0, 1); show(0xA1, 1, 1);
    show(0xC0, 0, 8);
    show(0x37, 0, 1);
    printf("status\n");
    show(0x28, 1, 12);
    show(0x50, 0, 4);
    show(0x51, 0, 5);
    show(0x52, 0, 2);
    show(0x53, 0, 1);
    printf("monitoring\n");
    show(0x25, 0, 1); show(0x26, 0, 1); show(0x27, 0, 1);
    for (unsigned h = 0; h < 2; h++) { show(0x23, h, 1); show(0x24, h, 1); }
    for (unsigned o = 0; o < 3; o++) { show(0xE7, o, 1); show(0xE8, o, 1); }
    show(0xE9, 0, 1); show(0x54, 0, 1); show(0x2A, 0, 1);
    printf("inputs (first 8)\n");
    for (unsigned c = 0; c < 8; c++) {
        show(0xC3, c, 1); show(0xC6, c, 1); show(0x60, c, 1); show(0x60, 0x80000000u | c, 1);
    }
    printf("routing (first 32 destinations)\n");
    for (unsigned d = 0; d < 32; d++) show(0x31, d, 1);
    return 0;
}

static unsigned long num(const char *s) { return strtoul(s, NULL, 0); }

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: symctl dump | read <cmd> <addr> <len> | write <cmd> <addr> <hexbytes>\n");
        return 2;
    }
    if (openSymphony()) { fprintf(stderr, "Symphony I/O (0c60:0010) not found\n"); return 1; }

    if (!strcmp(argv[1], "dump")) return dump();
    if (!strcmp(argv[1], "read") && argc == 5) {
        unsigned char buf[256] = {0};
        unsigned len = (unsigned)num(argv[4]);
        if (len > sizeof buf) return 2;
        int n = request(0, (unsigned)num(argv[2]), (unsigned)num(argv[3]), buf, len);
        if (n < 0) return 1;
        printHex(buf, n); printf("\n");
        return 0;
    }
    if (!strcmp(argv[1], "write") && argc == 5) {
        unsigned char buf[256];
        size_t hl = strlen(argv[4]);
        if (hl % 2 || hl / 2 > sizeof buf) { fprintf(stderr, "bad hex\n"); return 2; }
        for (size_t i = 0; i < hl / 2; i++) { unsigned v; sscanf(argv[4] + 2 * i, "%2x", &v); buf[i] = (unsigned char)v; }
        int n = request(1, (unsigned)num(argv[2]), (unsigned)num(argv[3]), buf, (unsigned)(hl / 2));
        return n < 0;
    }
    fprintf(stderr, "bad arguments\n");
    return 2;
}
