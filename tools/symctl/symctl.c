// symctl: talk to an Apogee Symphony I/O Mk1 over USB using its vendor control protocol.
// See docs/protocol.md. Only commands on the allowlist in lib/symusb.c can be sent;
// firmware, DFU and reset commands are deliberately absent.
//
//   symctl dump                         read every known status value
//   symctl ready                        send the host-ready handshake (clears the "!")
//   symctl release                      undo it (box shows "!" again)
//   symctl usb-reset                    reset the USB connection (same as unplug/replug)
//   symctl read  <cmd> <addr> <len>     raw read, e.g. symctl read 0x26 0 1
//   symctl write <cmd> <addr> <hex>     raw write, e.g. symctl write 0x27 0 01
//
// Build: make (from the repo root)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "symusb.h"

static SymDev gDev;

static void printHex(const unsigned char *b, int n) {
    for (int i = 0; i < n; i++) printf("%02x", b[i]);
}

static void show(uint8_t cmd, uint32_t addr, uint16_t len) {
    unsigned char buf[64] = {0};
    int n = sym_read(gDev, cmd, addr, buf, len);
    printf("  %02x %-8x %-34s ", cmd, addr, sym_cmd_name(cmd, 'r'));
    if (n < 0) { printf("(failed: 0x%08x)\n", sym_last_error()); return; }
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
    show(0xDD, 0, 1);
    show(0xDB, 0, 1);
    show(0x2B, 0, 1);
    show(0x28, 1, 12);
    show(0x50, 0, 4);
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

static int fail(const char *what, uint8_t cmd) {
    IOReturn e = sym_last_error();
    if (e == kIOReturnNotPermitted)
        fprintf(stderr, "refusing %s of command 0x%02x: not on the allowlist\n", what, cmd);
    else
        fprintf(stderr, "%s of command 0x%02x failed: 0x%08x\n", what, cmd, e);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: symctl dump | ready | release | usb-reset | read <cmd> <addr> <len> | write <cmd> <addr> <hexbytes>\n");
        return 2;
    }
    if (!strcmp(argv[1], "--version")) { printf("symctl %s\n", SYM_VERSION); return 0; }
    if (!strcmp(argv[1], "usb-reset")) {
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, sym_matching());
        if (!svc) { fprintf(stderr, "Symphony I/O (0c60:0010) not found\n"); return 1; }
        int r = sym_reenumerate(svc);
        IOObjectRelease(svc);
        if (r) { fprintf(stderr, "USB reset failed: 0x%08x\n", sym_last_error()); return 1; }
        printf("USB connection reset\n");
        return 0;
    }
    if (!(gDev = sym_open_first())) { fprintf(stderr, "Symphony I/O (0c60:0010) not found\n"); return 1; }

    if (!strcmp(argv[1], "dump")) return dump();
    if (!strcmp(argv[1], "ready") || !strcmp(argv[1], "release")) {
        bool ready = !strcmp(argv[1], "ready");
        if (ready && sym_system_ready(gDev) != 1) { fprintf(stderr, "box has not finished booting\n"); return 1; }
        if (sym_set_host_ready(gDev, ready)) return fail("write", 0xDD);
        printf("host %s\n", ready ? "ready" : "released");
        return 0;
    }
    if (!strcmp(argv[1], "read") && argc == 5) {
        unsigned char buf[256] = {0};
        unsigned long len = num(argv[4]);
        uint8_t cmd = (uint8_t)num(argv[2]);
        if (len > sizeof buf) return 2;
        int n = sym_read(gDev, cmd, (uint32_t)num(argv[3]), buf, (uint16_t)len);
        if (n < 0) return fail("read", cmd);
        printHex(buf, n); printf("\n");
        return 0;
    }
    if (!strcmp(argv[1], "write") && argc == 5) {
        unsigned char buf[256];
        size_t hl = strlen(argv[4]);
        uint8_t cmd = (uint8_t)num(argv[2]);
        if (hl % 2 || hl / 2 > sizeof buf) { fprintf(stderr, "bad hex\n"); return 2; }
        for (size_t i = 0; i < hl / 2; i++) {
            unsigned v;
            if (sscanf(argv[4] + 2 * i, "%2x", &v) != 1) { fprintf(stderr, "bad hex\n"); return 2; }
            buf[i] = (unsigned char)v;
        }
        if (sym_write(gDev, cmd, (uint32_t)num(argv[3]), buf, (uint16_t)(hl / 2)) < 0) return fail("write", cmd);
        return 0;
    }
    fprintf(stderr, "bad arguments\n");
    return 2;
}
