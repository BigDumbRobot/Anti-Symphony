# Command Line Tools are enough (no Xcode needed).
CC      = clang
CFLAGS  = -O2 -Wall -Wextra -Wno-unused-parameter -Ilib
LDLIBS  = -framework IOKit -framework CoreFoundation

all: build/symphonyd build/symctl build/usbdesc build/avbbridge

build:
	mkdir -p build

SYMPHONYD_SRC = symphonyd/symphonyd.c symphonyd/control.c symphonyd/osc.c lib/symusb.c

build/symphonyd: $(SYMPHONYD_SRC) symphonyd/control.h symphonyd/osc.h lib/symusb.h | build
	$(CC) $(CFLAGS) $(SYMPHONYD_SRC) -o $@ $(LDLIBS) -framework CoreAudio

build/symctl: tools/symctl/symctl.c lib/symusb.c lib/symusb.h | build
	$(CC) $(CFLAGS) tools/symctl/symctl.c lib/symusb.c -o $@ $(LDLIBS)

build/avbbridge: avbbridge/avbbridge.c | build
	$(CC) $(CFLAGS) avbbridge/avbbridge.c -o $@ -framework CoreAudio -framework CoreFoundation

build/usbdesc: tools/usbdesc/usbdesc.c | build
	$(CC) $(CFLAGS) tools/usbdesc/usbdesc.c -o $@ $(LDLIBS)

install: all
	symphonyd/install.sh

uninstall:
	symphonyd/uninstall.sh

clean:
	rm -rf build

.PHONY: all install uninstall clean
