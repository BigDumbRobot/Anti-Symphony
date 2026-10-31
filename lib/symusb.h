// symusb: shared USB access to the Apogee Symphony I/O Mk1 (vendor control protocol).
// Used by symctl and symphonyd. See docs/protocol.md.
//
// Every request goes through an allowlist: firmware, DFU and reset commands can't be sent.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

#define SYM_VID 0x0C60
#define SYM_PID 0x0010
#define SYM_READY_MAGIC 0xDAE5C4A1u   // what command 0xFF returns once the box has booted

typedef IOUSBDeviceInterface650 **SymDev;

// Name of an allowed command, or NULL. mode is 'r' or 'w'.
const char *sym_cmd_name(uint8_t cmd, char mode);

// Matching dictionary for the Symphony (consumed by IOService* calls, like any matching dict).
CFMutableDictionaryRef sym_matching(void);

// Open a device interface for a matched service, or the first Symphony found. NULL on failure.
SymDev sym_open(io_service_t svc);
SymDev sym_open_first(void);
void sym_close(SymDev dev);

// Vendor requests. Return bytes transferred, or -1 (see sym_last_error()).
int sym_read(SymDev dev, uint8_t cmd, uint32_t addr, void *buf, uint16_t len);
int sym_write(SymDev dev, uint8_t cmd, uint32_t addr, const void *buf, uint16_t len);
IOReturn sym_last_error(void);

// Resets the USB connection (same as unplugging and replugging). A standard USB operation,
// not a vendor request. Used to recover a box that stopped answering. 0 = ok, -1 = failed.
int sym_reenumerate(io_service_t svc);

// 1 = box has booted, 0 = not yet, -1 = request failed.
int sym_system_ready(SymDev dev);

// Host-ready handshake (command 0xDD, "preference load lock": 0 = host ready).
// Until a host clears it, the front panel shows "!" and the box doesn't act as a USB interface.
// get: 1 = host ready, 0 = not, -1 = request failed.
// set: writes and reads back, retrying like Apogee's daemon (10 tries, 5 ms). 0 = ok, -1 = failed.
int sym_get_host_ready(SymDev dev);
int sym_set_host_ready(SymDev dev, bool ready);
