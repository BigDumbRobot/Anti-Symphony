# Command Line Tools are enough (no Xcode needed).
CC      = clang
VERSION := $(shell cat VERSION)
# The installer builds with WERROR= so a newer compiler's new warnings can't stop a user's build.
WERROR ?= -Werror
CFLAGS  = -O2 -Wall -Wextra $(WERROR) -Wno-unused-parameter -Ilib -DSYM_VERSION='"$(VERSION)"'
LDLIBS  = -framework IOKit -framework CoreFoundation

all: build/symphonyd build/symctl build/usbdesc build/avbbridge build/symtest

build:
	mkdir -p build

SYMPHONYD_SRC = symphonyd/symphonyd.c symphonyd/control.c symphonyd/osc.c lib/symusb.c

build/symphonyd: $(SYMPHONYD_SRC) symphonyd/control.h symphonyd/osc.h lib/symusb.h VERSION | build
	$(CC) $(CFLAGS) $(SYMPHONYD_SRC) -o $@ $(LDLIBS) -framework CoreAudio

build/symctl: tools/symctl/symctl.c lib/symusb.c lib/symusb.h VERSION | build
	$(CC) $(CFLAGS) tools/symctl/symctl.c lib/symusb.c -o $@ $(LDLIBS)

build/avbbridge: avbbridge/avbbridge.c | build
	$(CC) $(CFLAGS) avbbridge/avbbridge.c -o $@ -framework CoreAudio -framework CoreFoundation

build/symtest: tests/symtest.c | build
	$(CC) $(CFLAGS) tests/symtest.c -o $@ -framework CoreAudio -framework CoreFoundation

# Hardware test suite: needs the Symphony with the loopback cables described in tests/README.md.
test: all
	python3 -I tests/hwtest.py

build/usbdesc: tools/usbdesc/usbdesc.c | build
	$(CC) $(CFLAGS) tools/usbdesc/usbdesc.c -o $@ $(LDLIBS)

app:
	app/build.sh

install: all app
	symphonyd/install.sh

uninstall:
	symphonyd/uninstall.sh

# Release zip: app, command-line tools, LaunchAgent and install script.
dist: all app
	rm -rf build/dist && mkdir -p build/dist/Anti-Symphony-$(VERSION)/bin
	cp -R "build/Symphony Control.app" build/dist/Anti-Symphony-$(VERSION)/
	cp build/symphonyd build/symctl build/usbdesc build/dist/Anti-Symphony-$(VERSION)/bin/
	cp README.md docs/osc.md build/dist/Anti-Symphony-$(VERSION)/
	cd build/dist && ditto -c -k --keepParent Anti-Symphony-$(VERSION) ../Anti-Symphony-$(VERSION).zip
	@echo "built: build/Anti-Symphony-$(VERSION).zip"

clean:
	rm -rf build app/.build

.PHONY: all app install uninstall clean test dist
