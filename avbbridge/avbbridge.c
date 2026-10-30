// avbbridge: puts the Symphony I/O's channels on an AVB network, using the Mac as the AVB endpoint.
//
// The Symphony Mk1 has no AVB hardware, so the Mac does the networking: macOS's built-in AVB
// support (avbutil --virtual-audio enable <if>) or a connected AVB device gives a Core Audio
// device on the AVB network. This program joins that device and the Symphony in a private
// aggregate device and copies audio between them:
//
//   Symphony inputs 1..N   -> AVB outputs 1..N   (the Symphony's inputs appear on the network)
//   AVB inputs 1..N        -> Symphony outputs 1..N (network audio plays out of the Symphony)
//
// One clock leads (default: the Symphony); the other is drift-corrected by Core Audio.
// If the AVB network's clock also drives the Symphony's word clock input, use --clock avb.
//
// It reconnects by itself when either device disappears and comes back.
//
//   avbbridge --list                         list audio devices and their transport
//   avbbridge [--avb <name>] [--channels N] [--clock symphony|avb] [--no-to-avb] [--no-from-avb]
//
// --avb matches part of a device name; without it the first AVB device is used.
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define AGG_UID CFSTR("ca.arraymusic.avbbridge")
#define AGG_NAME CFSTR("Symphony AVB Bridge")

static const char *gAvbName;      // NULL = first AVB device
static const char *gSymName = "Symphony";
static UInt32 gChannels = 16;
static bool gClockAvb, gToAvb = true, gFromAvb = true;

static AudioObjectID gAgg;
static AudioDeviceIOProcID gProc;
static CFStringRef gSymUID, gAvbUID;
static bool gWarnedMissing;

// Channel layout inside the aggregate, filled in at setup (read by the IO thread).
static UInt32 gSymIn, gSymOut, gAvbIn, gAvbOut, gCopyToAvb, gCopyFromAvb;

static void logf_(const char *fmt, ...) {
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

// ---- Core Audio helpers ----

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector s, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = {s, sc, kAudioObjectPropertyElementMain};
    return a;
}

static UInt32 deviceList(AudioObjectID *ids, UInt32 max) {
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 sz = max * sizeof *ids;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids)) return 0;
    return sz / sizeof *ids;
}

static CFStringRef copyString(AudioObjectID id, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = addr(sel, kAudioObjectPropertyScopeGlobal);
    CFStringRef s = NULL;
    UInt32 sz = sizeof s;
    if (AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, &s)) return NULL;
    return s;
}

static void cstr(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

static UInt32 u32(AudioObjectID id, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = addr(sel, kAudioObjectPropertyScopeGlobal);
    UInt32 v = 0, sz = sizeof v;
    AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, &v);
    return v;
}

static UInt32 channelCount(AudioObjectID id, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(id, &a, 0, NULL, &sz) || !sz) return 0;
    AudioBufferList *l = malloc(sz);
    UInt32 n = 0;
    if (!AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, l))
        for (UInt32 i = 0; i < l->mNumberBuffers; i++) n += l->mBuffers[i].mNumberChannels;
    free(l);
    return n;
}

static Float64 rate(AudioObjectID id) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    Float64 r = 0;
    UInt32 sz = sizeof r;
    AudioObjectGetPropertyData(id, &a, 0, NULL, &sz, &r);
    return r;
}

static OSStatus setRate(AudioObjectID id, Float64 r) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(id, &a, 0, NULL, sizeof r, &r);
}

static AudioObjectID deviceForUID(CFStringRef uid) {
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 sz = sizeof id;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof uid, &uid, &sz, &id);
    return id;
}

static const char *transportName(UInt32 t) {
    switch (t) {
    case kAudioDeviceTransportTypeAVB: return "AVB";
    case kAudioDeviceTransportTypeUSB: return "USB";
    case kAudioDeviceTransportTypeBuiltIn: return "built-in";
    case kAudioDeviceTransportTypeAggregate: return "aggregate";
    case kAudioDeviceTransportTypeVirtual: return "virtual";
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt";
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth";
    default: return "other";
    }
}

// Finds a device by name substring, or (name NULL) the first AVB device. Never matches our aggregate.
static AudioObjectID findDevice(const char *name, bool avbOnly) {
    AudioObjectID ids[128];
    UInt32 n = deviceList(ids, 128);
    for (UInt32 i = 0; i < n; i++) {
        UInt32 t = u32(ids[i], kAudioDevicePropertyTransportType);
        if (t == kAudioDeviceTransportTypeAggregate) continue;
        if (avbOnly && !name && t != kAudioDeviceTransportTypeAVB) continue;
        if (name) {
            char buf[256];
            CFStringRef s = copyString(ids[i], kAudioObjectPropertyName);
            cstr(s, buf, sizeof buf);
            if (s) CFRelease(s);
            if (!strstr(buf, name)) continue;
        }
        return ids[i];
    }
    return kAudioObjectUnknown;
}

static int list(void) {
    AudioObjectID ids[128];
    UInt32 n = deviceList(ids, 128);
    for (UInt32 i = 0; i < n; i++) {
        char name[256];
        CFStringRef s = copyString(ids[i], kAudioObjectPropertyName);
        cstr(s, name, sizeof name);
        if (s) CFRelease(s);
        printf("%-40s %-11s %3u in %3u out  %.0f Hz\n", name, transportName(u32(ids[i], kAudioDevicePropertyTransportType)),
               channelCount(ids[i], kAudioObjectPropertyScopeInput), channelCount(ids[i], kAudioObjectPropertyScopeOutput),
               rate(ids[i]));
    }
    return 0;
}

// ---- audio ----

// Channel `idx` (0-based, counted across all buffers) of a buffer list.
static float *chan(const AudioBufferList *l, UInt32 idx, UInt32 *stride, UInt32 *frames) {
    for (UInt32 b = 0; b < l->mNumberBuffers; b++) {
        UInt32 n = l->mBuffers[b].mNumberChannels;
        if (idx < n) {
            if (!l->mBuffers[b].mData || !n) return NULL;
            *stride = n;
            *frames = l->mBuffers[b].mDataByteSize / (sizeof(float) * n);
            return (float *)l->mBuffers[b].mData + idx;
        }
        idx -= n;
    }
    return NULL;
}

static void copy(const AudioBufferList *in, UInt32 inFirst, AudioBufferList *out, UInt32 outFirst, UInt32 count) {
    for (UInt32 c = 0; c < count; c++) {
        UInt32 is, os, inFrames, outFrames;
        float *src = chan(in, inFirst + c, &is, &inFrames);
        float *dst = chan(out, outFirst + c, &os, &outFrames);
        if (!src || !dst) continue;
        UInt32 frames = inFrames < outFrames ? inFrames : outFrames;
        for (UInt32 f = 0; f < frames; f++) dst[f * os] = src[f * is];
    }
}

// Aggregate layout: sub-devices in list order, Symphony first. So inputs are [Symphony | AVB]
// and outputs are [Symphony | AVB].
static OSStatus ioProc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
                       const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx) {
    if (in && out) {
        copy(in, 0, out, gSymOut, gCopyToAvb);        // Symphony in -> AVB out
        copy(in, gSymIn, out, 0, gCopyFromAvb);       // AVB in -> Symphony out
    }
    return noErr;
}

// ---- setup / teardown ----

static void teardown(const char *why) {
    if (!gAgg) return;
    if (gProc) {
        AudioDeviceStop(gAgg, gProc);
        AudioDeviceDestroyIOProcID(gAgg, gProc);
        gProc = NULL;
    }
    AudioHardwareDestroyAggregateDevice(gAgg);
    gAgg = 0;
    if (why) logf_("bridge stopped: %s", why);
}

static CFDictionaryRef subDevice(CFStringRef uid, bool drift) {
    int one = 1;
    CFNumberRef yes = CFNumberCreate(NULL, kCFNumberIntType, &one);
    const void *keys[] = {CFSTR(kAudioSubDeviceUIDKey), CFSTR(kAudioSubDeviceDriftCompensationKey)};
    const void *vals[] = {uid, yes};
    CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, drift ? 2 : 1, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    CFRelease(yes);
    return d;
}

static bool setup(AudioObjectID sym, AudioObjectID avb) {
    if (gSymUID) CFRelease(gSymUID);
    if (gAvbUID) CFRelease(gAvbUID);
    gSymUID = copyString(sym, kAudioDevicePropertyDeviceUID);
    gAvbUID = copyString(avb, kAudioDevicePropertyDeviceUID);
    if (!gSymUID || !gAvbUID) return false;

    char avbName[256];
    CFStringRef n = copyString(avb, kAudioObjectPropertyName);
    cstr(n, avbName, sizeof avbName);
    if (n) CFRelease(n);

    // Both devices must run at the same rate; follow whichever leads the clock.
    Float64 symRate = rate(sym), avbRate = rate(avb);
    if (symRate != avbRate) {
        AudioObjectID follower = gClockAvb ? sym : avb;
        Float64 want = gClockAvb ? avbRate : symRate;
        if (setRate(follower, want)) {
            logf_("can't match sample rates (Symphony %.0f Hz, %s %.0f Hz)", symRate, avbName, avbRate);
            return false;
        }
        logf_("set %s to %.0f Hz", gClockAvb ? "Symphony" : avbName, want);
    }

    CFDictionaryRef subs[2] = {subDevice(gSymUID, gClockAvb), subDevice(gAvbUID, !gClockAvb)};
    CFArrayRef subList = CFArrayCreate(NULL, (const void **)subs, 2, &kCFTypeArrayCallBacks);
    CFRelease(subs[0]);
    CFRelease(subs[1]);
    int one = 1;
    CFNumberRef yes = CFNumberCreate(NULL, kCFNumberIntType, &one);
    const void *keys[] = {CFSTR(kAudioAggregateDeviceUIDKey), CFSTR(kAudioAggregateDeviceNameKey),
                          CFSTR(kAudioAggregateDeviceIsPrivateKey), CFSTR(kAudioAggregateDeviceSubDeviceListKey),
                          CFSTR(kAudioAggregateDeviceMainSubDeviceKey)};
    const void *vals[] = {AGG_UID, AGG_NAME, yes, subList, gClockAvb ? gAvbUID : gSymUID};
    CFDictionaryRef desc = CFDictionaryCreate(NULL, keys, vals, 5, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFRelease(yes);
    CFRelease(subList);

    OSStatus err = AudioHardwareCreateAggregateDevice(desc, &gAgg);
    CFRelease(desc);
    if (err) { logf_("can't create aggregate device (%d)", (int)err); gAgg = 0; return false; }

    gSymIn = channelCount(sym, kAudioObjectPropertyScopeInput);
    gSymOut = channelCount(sym, kAudioObjectPropertyScopeOutput);
    gAvbIn = channelCount(avb, kAudioObjectPropertyScopeInput);
    gAvbOut = channelCount(avb, kAudioObjectPropertyScopeOutput);
    UInt32 aggIn = channelCount(gAgg, kAudioObjectPropertyScopeInput);
    UInt32 aggOut = channelCount(gAgg, kAudioObjectPropertyScopeOutput);
    if (aggIn != gSymIn + gAvbIn || aggOut != gSymOut + gAvbOut) {
        logf_("aggregate has %u in / %u out, expected %u / %u", aggIn, aggOut, gSymIn + gAvbIn, gSymOut + gAvbOut);
        teardown(NULL);
        return false;
    }
    UInt32 a = gSymIn < gAvbOut ? gSymIn : gAvbOut, b = gAvbIn < gSymOut ? gAvbIn : gSymOut;
    gCopyToAvb = gToAvb ? (a < gChannels ? a : gChannels) : 0;
    gCopyFromAvb = gFromAvb ? (b < gChannels ? b : gChannels) : 0;

    if (AudioDeviceCreateIOProcID(gAgg, ioProc, NULL, &gProc) || AudioDeviceStart(gAgg, gProc)) {
        logf_("can't start audio on the aggregate device");
        gProc = NULL;
        teardown(NULL);
        return false;
    }
    logf_("bridge running at %.0f Hz with %s: Symphony in 1-%u -> AVB out, AVB in 1-%u -> Symphony out; clock from %s",
          rate(gAgg), avbName, gCopyToAvb, gCopyFromAvb, gClockAvb ? "AVB" : "Symphony");
    return true;
}

// Called every 2 s: start the bridge when both devices are present, stop it when one goes.
static void check(CFRunLoopTimerRef t, void *info) {
    if (gAgg) {
        AudioObjectID s = deviceForUID(gSymUID), a = deviceForUID(gAvbUID);
        if (s && a && u32(s, kAudioDevicePropertyDeviceIsAlive) && u32(a, kAudioDevicePropertyDeviceIsAlive)) return;
        teardown(!s || !u32(s, kAudioDevicePropertyDeviceIsAlive) ? "Symphony went away" : "AVB device went away");
    }
    AudioObjectID sym = findDevice(gSymName, false);
    AudioObjectID avb = findDevice(gAvbName, true);
    if (!sym || !avb) {
        if (!gWarnedMissing) {
            logf_("waiting for %s%s%s", sym ? "" : "the Symphony", !sym && !avb ? " and " : "",
                  avb ? "" : (gAvbName ? gAvbName : "an AVB audio device"));
            gWarnedMissing = true;
        }
        return;
    }
    gWarnedMissing = false;
    setup(sym, avb);
}

static void usage(void) {
    fprintf(stderr, "usage: avbbridge --list\n"
                    "       avbbridge [--avb <name>] [--channels N] [--clock symphony|avb] [--no-to-avb] [--no-from-avb]\n");
    exit(2);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--list")) return list();
        else if (!strcmp(argv[i], "--avb") && i + 1 < argc) gAvbName = argv[++i];
        else if (!strcmp(argv[i], "--symphony") && i + 1 < argc) gSymName = argv[++i];
        else if (!strcmp(argv[i], "--channels") && i + 1 < argc) gChannels = (UInt32)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--clock") && i + 1 < argc) {
            const char *c = argv[++i];
            if (!strcmp(c, "avb")) gClockAvb = true;
            else if (strcmp(c, "symphony")) usage();
        }
        else if (!strcmp(argv[i], "--no-to-avb")) gToAvb = false;
        else if (!strcmp(argv[i], "--no-from-avb")) gFromAvb = false;
        else usage();
    }
    setvbuf(stderr, NULL, _IOLBF, 0);

    // Remove a bridge left behind by a crash, so the UID is free.
    AudioObjectID stale = deviceForUID(AGG_UID);
    if (stale) AudioHardwareDestroyAggregateDevice(stale);

    // Core Audio property callbacks need a run loop; use the main one.
    AudioObjectPropertyAddress rl = addr(kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal);
    CFRunLoopRef none = NULL;
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &rl, 0, NULL, sizeof none, &none);

    logf_("avbbridge starting");
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 2.0, 0, 0, check, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopDefaultMode);

    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    int sigs[] = {SIGTERM, SIGINT};
    for (int i = 0; i < 2; i++) {
        dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sigs[i], 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(s, ^{ CFRunLoopStop(CFRunLoopGetMain()); });
        dispatch_resume(s);
    }

    CFRunLoopRun();
    teardown("shutting down");
    return 0;
}
