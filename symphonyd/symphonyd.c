// symphonyd: keeps an Apogee Symphony I/O Mk1 working as a USB audio interface on macOS
// versions Apogee no longer supports.
//
// The box only acts as a USB interface once a host tells it the host is ready (command 0xDD = 0);
// until then its front panel shows "!". Apogee's daemon did this; on Tahoe nothing does.
// Apple's own USB audio driver then handles the audio.
//
// What this does, mirroring Apogee's symphonyIOUSBDaemon:
//   - when a Symphony appears: wait for it to finish booting (0xFF = DAE5C4A1), then send host-ready;
//   - every 1.3 s: check host-ready is still set and send it again if the box dropped it
//     (front-panel power cycle, mode change);
//   - before the Mac sleeps: clear host-ready; after wake: wait for the box, then set it again;
//   - unplug and replug are handled by IOKit notifications.
//
// Runs as a user LaunchAgent (no root needed). Logs to stderr; launchd sends that to
// ~/Library/Logs/symphonyd.log. -v also logs every status change the box reports.
//
// It also serves every setting over OSC (docs/osc.md): by default on 127.0.0.1:7100, so only
// this Mac can reach it. --osc-bind 0.0.0.0 opens it to the network (e.g. Companion on another machine).
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <dispatch/dispatch.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include "symusb.h"
#include "control.h"

#define POLL_SECONDS 1.3          // Apogee polls parameter updates about this often
#define MAX_UNITS 4
#define MAX_FAILURES 5            // consecutive failed polls before reopening the device
#define BOOT_WARN_SECONDS 20.0
#define HANGS_BEFORE_RESET 2      // reopen cycles that fail before resetting the USB connection
#define RESET_MIN_SECONDS 60.0

typedef enum { WAIT_BOOT, ACTIVE } State;

typedef struct {
    bool used;
    uint64_t regID;
    uint32_t location;
    io_service_t svc;
    SymDev dev;
    State state;
    int failures;
    double waitingSince;
    bool warnedBoot, warnedOpen, announced;
    int hangs;                    // consecutive reopen cycles with no answer from the box
    double lastReset;
    uint8_t params[12];
    bool haveParams;
} Unit;

static Unit gUnits[MAX_UNITS];
static bool gVerbose, gAsleep;
static CFRunLoopTimerRef gTimer;
static io_connect_t gRootPort;

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

void logf_(const char *fmt, ...) {
    char stamp[32];
    time_t t = time(NULL);
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(stderr, "%s ", stamp);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}
#define LOG(u, fmt, ...) logf_("[Symphony@%08x] " fmt, (u)->location, ##__VA_ARGS__)

static void pollSoon(double seconds) {
    if (gTimer) CFRunLoopTimerSetNextFireDate(gTimer, CFAbsoluteTimeGetCurrent() + seconds);
}

static uint32_t locationOf(io_service_t svc) {
    uint32_t v = 0;
    CFTypeRef r = IORegistryEntryCreateCFProperty(svc, CFSTR(kUSBDevicePropertyLocationID), NULL, 0);
    if (r) {
        if (CFGetTypeID(r) == CFNumberGetTypeID()) CFNumberGetValue(r, kCFNumberSInt32Type, &v);
        CFRelease(r);
    }
    return v;
}

static void closeDev(Unit *u) {
    ctl_detach(u->dev);
    sym_close(u->dev);
    u->dev = NULL;
}

static void resetToWaitBoot(Unit *u) {
    u->state = WAIT_BOOT;
    u->waitingSince = now();
    u->warnedBoot = false;
    u->failures = 0;
}

static void announce(Unit *u) {
    uint8_t fw[3] = {0}, id[8] = {0};
    sym_read(u->dev, 0xA0, 0, fw, 3);
    sym_read(u->dev, 0xC0, 0, id, 8);
    LOG(u, "firmware %02x%02x%02x, unique ID %02x%02x%02x%02x%02x%02x%02x%02x",
        fw[0], fw[1], fw[2], id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7]);
    u->announced = true;
}

static void sendHostReady(Unit *u) {
    if (sym_set_host_ready(u->dev, true) == 0) {
        LOG(u, "host ready sent");
        uint8_t board = 0;
        sym_read(u->dev, 0xA1, 0, &board, 1);
        ctl_attach(u->dev, board);
        u->state = ACTIVE;
        u->failures = 0;
        u->haveParams = false;
    } else {
        LOG(u, "host ready failed (0x%08x), will retry", sym_last_error());
        u->failures++;
    }
}

static void watchParams(Unit *u) {
    uint8_t p[12];
    if (sym_read(u->dev, 0x28, 1, p, sizeof p) != sizeof p) { u->failures++; return; }
    if (u->haveParams && memcmp(p, u->params, sizeof p)) {
        uint32_t oldRate = (uint32_t)u->params[0] << 24 | u->params[1] << 16 | u->params[2] << 8 | u->params[3];
        uint32_t rate = (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
        if (rate != oldRate) LOG(u, "sample rate %u -> %u", oldRate, rate);
        if (gVerbose) {
            char hex[25];
            for (int i = 0; i < 12; i++) snprintf(hex + 2 * i, 3, "%02x", p[i]);
            LOG(u, "parameter update %s", hex);
        }
    }
    memcpy(u->params, p, sizeof p);
    u->haveParams = true;
}

static void pollUnit(Unit *u) {
    if (!u->dev) {
        if (!(u->dev = sym_open(u->svc))) {
            if (!u->warnedOpen) { LOG(u, "can't open device yet (0x%08x), retrying", sym_last_error()); u->warnedOpen = true; }
            return;
        }
        u->warnedOpen = false;
        resetToWaitBoot(u);
    }

    if (u->state == WAIT_BOOT) {
        int r = sym_system_ready(u->dev);
        if (r == 1) {
            if (!u->announced) announce(u);
            sendHostReady(u);
        } else {
            if (r < 0) u->failures++;
            if (!u->warnedBoot && now() - u->waitingSince > BOOT_WARN_SECONDS) {
                LOG(u, "still waiting for the box to finish booting");
                u->warnedBoot = true;
            }
        }
    } else {
        int h = sym_get_host_ready(u->dev);
        if (h < 0) {
            u->failures++;
        } else {
            u->failures = 0;
            if (h == 0) {
                LOG(u, "box dropped host ready (power cycle or mode change?); sending again");
                resetToWaitBoot(u);
                pollSoon(0.2);
                return;
            }
            watchParams(u);
        }
    }

    if (u->failures >= MAX_FAILURES) {
        IOReturn e = sym_last_error();
        LOG(u, "%d failed requests in a row (last 0x%08x); reopening", u->failures, e);
        closeDev(u);
        resetToWaitBoot(u);
        // A box that stops answering (seen once in testing) comes back after a USB reset,
        // the same as unplugging it. Do that, but not more than once a minute.
        if (e == kIOReturnNotResponding || e == kIOReturnTimeout || e == kIOUSBTransactionTimeout) {
            if (++u->hangs >= HANGS_BEFORE_RESET && now() - u->lastReset > RESET_MIN_SECONDS) {
                LOG(u, "box not responding; resetting the USB connection");
                u->lastReset = now();
                u->hangs = 0;
                if (sym_reenumerate(u->svc)) LOG(u, "USB reset failed (0x%08x)", sym_last_error());
            }
        }
    } else if (u->state == ACTIVE && u->failures == 0) {
        u->hangs = 0;
    }
}

static void onTimer(CFRunLoopTimerRef t, void *info) {
    if (gAsleep) return;
    for (int i = 0; i < MAX_UNITS; i++)
        if (gUnits[i].used) pollUnit(&gUnits[i]);
    ctl_tick();
}

static void onAttach(void *refcon, io_iterator_t it) {
    io_service_t svc;
    while ((svc = IOIteratorNext(it))) {
        uint64_t id = 0;
        IORegistryEntryGetRegistryEntryID(svc, &id);
        Unit *u = NULL;
        for (int i = 0; i < MAX_UNITS && !u; i++) if (!gUnits[i].used) u = &gUnits[i];
        if (!u) { logf_("ignoring extra Symphony: only %d supported", MAX_UNITS); IOObjectRelease(svc); continue; }
        memset(u, 0, sizeof *u);
        u->used = true;
        u->regID = id;
        u->svc = svc;   // keep the reference
        u->location = locationOf(svc);
        resetToWaitBoot(u);
        LOG(u, "connected");
        pollSoon(0.3);
    }
}

static void onDetach(void *refcon, io_iterator_t it) {
    io_service_t svc;
    while ((svc = IOIteratorNext(it))) {
        uint64_t id = 0;
        IORegistryEntryGetRegistryEntryID(svc, &id);
        for (int i = 0; i < MAX_UNITS; i++) {
            Unit *u = &gUnits[i];
            if (u->used && u->regID == id) {
                LOG(u, "disconnected");
                closeDev(u);
                IOObjectRelease(u->svc);
                memset(u, 0, sizeof *u);
            }
        }
        IOObjectRelease(svc);
    }
}

static void onPower(void *refcon, io_service_t service, natural_t type, void *arg) {
    switch (type) {
    case kIOMessageCanSystemSleep:
        IOAllowPowerChange(gRootPort, (long)arg);
        break;
    case kIOMessageSystemWillSleep:
        // Same as Apogee: release the box before sleep so it isn't left expecting a host.
        for (int i = 0; i < MAX_UNITS; i++) {
            Unit *u = &gUnits[i];
            if (u->used && u->dev && u->state == ACTIVE) {
                if (sym_set_host_ready(u->dev, false) == 0) LOG(u, "released for sleep");
                else LOG(u, "release for sleep failed (0x%08x)", sym_last_error());
            }
        }
        gAsleep = true;
        IOAllowPowerChange(gRootPort, (long)arg);
        break;
    case kIOMessageSystemHasPoweredOn:
        logf_("woke from sleep");
        gAsleep = false;
        for (int i = 0; i < MAX_UNITS; i++)
            if (gUnits[i].used) resetToWaitBoot(&gUnits[i]);
        pollSoon(0.5);
        break;
    default:
        break;
    }
}

static void onSignal(int sig) {
    (void)sig;
}

int main(int argc, char **argv) {
    const char *oscBind = "127.0.0.1";
    int oscPort = 7100;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) gVerbose = true;
        else if (!strcmp(argv[i], "--osc-bind") && i + 1 < argc) oscBind = argv[++i];
        else if (!strcmp(argv[i], "--osc-port") && i + 1 < argc) oscPort = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--version")) { printf("symphonyd %s\n", SYM_VERSION); return 0; }
        else { fprintf(stderr, "usage: symphonyd [-v] [--osc-bind <ipv4>] [--osc-port <port>]\n"); return 2; }
    }
    setvbuf(stderr, NULL, _IOLBF, 0);
    logf_("symphonyd %s starting", SYM_VERSION);
    ctl_init(oscBind, oscPort);   // keeps the handshake running even if OSC can't start

    // USB attach / detach. The first call to each handler arms the notification and picks up
    // anything already connected.
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);
    io_iterator_t attachIt, detachIt;
    if (IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, sym_matching(), onAttach, NULL, &attachIt) ||
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, sym_matching(), onDetach, NULL, &detachIt)) {
        logf_("can't register for USB notifications");
        return 1;
    }
    onDetach(NULL, detachIt);
    onAttach(NULL, attachIt);

    // Sleep / wake.
    IONotificationPortRef pmPort;
    io_object_t pmNotifier;
    gRootPort = IORegisterForSystemPower(NULL, &pmPort, onPower, &pmNotifier);
    if (gRootPort == MACH_PORT_NULL) logf_("can't register for sleep/wake notifications; continuing without");
    else CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(pmPort), kCFRunLoopDefaultMode);

    // Poll timer.
    gTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.3, POLL_SECONDS, 0, 0, onTimer, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), gTimer, kCFRunLoopDefaultMode);

    // Clean exit on SIGTERM (launchctl) and SIGINT (Ctrl-C). Host ready is left set on purpose:
    // audio keeps working while the service restarts.
    signal(SIGTERM, onSignal);
    signal(SIGINT, onSignal);
    dispatch_source_t sigs[2];
    int nums[2] = {SIGTERM, SIGINT};
    for (int i = 0; i < 2; i++) {
        sigs[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, nums[i], 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigs[i], ^{ CFRunLoopStop(CFRunLoopGetMain()); });
        dispatch_resume(sigs[i]);
    }

    CFRunLoopRun();
    logf_("symphonyd stopping");
    return 0;
}
