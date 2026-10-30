# Command Line Tools are enough (no Xcode needed).
CC      = clang
CFLAGS  = -O2 -Wall -Wextra -Wno-unused-parameter -Ilib
LDLIBS  = -framework IOKit -framework CoreFoundation

all: build/symphonyd build/symctl build/usbdesc

build:
	mkdir -p build

build/symphonyd: symphonyd/symphonyd.c lib/symusb.c lib/symusb.h | build
	$(CC) $(CFLAGS) symphonyd/symphonyd.c lib/symusb.c -o $@ $(LDLIBS)

build/symctl: tools/symctl/symctl.c lib/symusb.c lib/symusb.h | build
	$(CC) $(CFLAGS) tools/symctl/symctl.c lib/symusb.c -o $@ $(LDLIBS)

build/usbdesc: tools/usbdesc/usbdesc.c | build
	$(CC) $(CFLAGS) tools/usbdesc/usbdesc.c -o $@ $(LDLIBS)

install: all
	symphonyd/install.sh

uninstall:
	symphonyd/uninstall.sh

clean:
	rm -rf build

.PHONY: all install uninstall clean
