// Device control and OSC for symphonyd. See docs/osc.md for the address space.
#pragma once
#include <stdbool.h>
#include "symusb.h"

// Opens the OSC socket. bindAddr is an IPv4 address ("127.0.0.1" = this Mac only).
bool ctl_init(const char *bindAddr, int port);

// The box is ready (host ready sent): read every setting and start serving it.
void ctl_attach(SymDev dev, int boardType);
// The box went away or is being reopened.
void ctl_detach(SymDev dev);
// Called on every poll tick (about 1.3 s).
void ctl_tick(void);
