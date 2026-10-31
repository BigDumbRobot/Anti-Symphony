// symtest: audio test instrument for the Symphony I/O (used by tests/hwtest.py).
//
// Opens the Symphony through Core Audio, plays sine tones on chosen output channels and
// measures every input channel. Driven by commands on stdin, one per line; every command
// answers with one line on stdout.
//
//   tone <ch> <hz> <dBFS>      play a tone on output channel ch (1-based)
//   off <ch> | alloff          stop one / all tones
//   measure <ms> <settle_ms>   wait settle_ms, capture ms, report (JSON):
//                              {"rate":R,"rms":[dB x16],"tones":{"<hz>":[dB x16],...}}
//                              tone levels are the amplitude of that frequency in dBFS
//   rate                       report the device sample rate
//   reopen                     restart audio (after a sample rate change)
//   quit
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXCH 16
#define RING (96000 * 2)    // 2 s at 96 kHz

static AudioObjectID gDev;
static AudioDeviceIOProcID gProc;
static double gRate;

static double gFreq[MAXCH], gAmp[MAXCH], gPhase[MAXCH];   // written by main, read by IO
static float gRing[MAXCH][RING];
static _Atomic unsigned long gWrite;                      // total frames written

static OSStatus io(AudioObjectID d, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *it,
                   AudioBufferList *out, const AudioTimeStamp *ot, void *ctx) {
    if (out && out->mNumberBuffers) {
        AudioBuffer *b = &out->mBuffers[0];
        float *p = b->mData;
        UInt32 ch = b->mNumberChannels, frames = b->mDataByteSize / 4 / (ch ? ch : 1);
        memset(p, 0, b->mDataByteSize);
        for (UInt32 c = 0; c < ch && c < MAXCH; c++) {
            if (gAmp[c] <= 0) continue;
            double step = 2 * M_PI * gFreq[c] / gRate, ph = gPhase[c], a = gAmp[c];
            for (UInt32 f = 0; f < frames; f++) {
                p[f * ch + c] = (float)(a * sin(ph));
                ph += step;
                if (ph > 2 * M_PI) ph -= 2 * M_PI;
            }
            gPhase[c] = ph;
        }
    }
    if (in && in->mNumberBuffers) {
        const AudioBuffer *b = &in->mBuffers[0];
        const float *p = b->mData;
        UInt32 ch = b->mNumberChannels, frames = b->mDataByteSize / 4 / (ch ? ch : 1);
        unsigned long w = atomic_load(&gWrite);
        for (UInt32 f = 0; f < frames; f++) {
            unsigned long i = (w + f) % RING;
            for (UInt32 c = 0; c < MAXCH; c++) gRing[c][i] = c < ch ? p[f * ch + c] : 0;
        }
        atomic_store(&gWrite, w + frames);
    }
    return 0;
}

static AudioObjectID findSymphony(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID ids[128];
    UInt32 sz = sizeof ids;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids)) return 0;
    for (UInt32 i = 0; i < sz / sizeof *ids; i++) {
        AudioObjectPropertyAddress na = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CFStringRef n = NULL;
        UInt32 s = sizeof n;
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &s, &n) || !n) continue;
        char buf[256];
        CFStringGetCString(n, buf, sizeof buf, kCFStringEncodingUTF8);
        CFRelease(n);
        if (strstr(buf, "Symphony")) return ids[i];
    }
    return 0;
}

static int start(void) {
    if (!(gDev = findSymphony())) { fprintf(stderr, "symtest: Symphony not found\n"); return -1; }
    AudioObjectPropertyAddress ra = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 s = sizeof gRate;
    AudioObjectGetPropertyData(gDev, &ra, 0, NULL, &s, &gRate);
    atomic_store(&gWrite, 0);
    OSStatus e = AudioDeviceCreateIOProcID(gDev, io, NULL, &gProc);
    if (!e) e = AudioDeviceStart(gDev, gProc);
    if (e) fprintf(stderr, "symtest: Core Audio error %d\n", (int)e);
    return e ? -1 : 0;
}

static void stop(void) {
    if (!gProc) return;
    AudioDeviceStop(gDev, gProc);
    AudioDeviceDestroyIOProcID(gDev, gProc);
    gProc = NULL;
}

static double db(double x) { return x > 1e-12 ? 20 * log10(x) : -240; }

// Amplitude of frequency hz in samples x[0..n) (Goertzel with a Hann window), as dBFS.
static double toneDb(const float *x, int n, double hz) {
    double w = 2 * M_PI * hz / gRate, c = 2 * cos(w), s1 = 0, s2 = 0, wsum = 0;
    for (int i = 0; i < n; i++) {
        double win = 0.5 - 0.5 * cos(2 * M_PI * i / (n - 1));
        double s0 = x[i] * win + c * s1 - s2;
        s2 = s1; s1 = s0; wsum += win;
    }
    double re = s1 - s2 * cos(w), im = s2 * sin(w);
    return db(2 * sqrt(re * re + im * im) / wsum);
}

static void measure(int ms, int settleMs) {
    usleep((useconds_t)settleMs * 1000);
    unsigned long from = atomic_load(&gWrite);
    usleep((useconds_t)ms * 1000);
    unsigned long to = atomic_load(&gWrite);
    int n = (int)(to - from);
    if (n > RING) n = RING;
    if (n < 64) { printf("{\"error\":\"no input\"}\n"); fflush(stdout); return; }
    static float buf[RING];
    printf("{\"rate\":%.0f,\"frames\":%d,\"rms\":[", gRate, n);
    for (int c = 0; c < MAXCH; c++) {
        double sum = 0;
        for (int i = 0; i < n; i++) { float v = gRing[c][(from + i) % RING]; sum += v * v; }
        printf("%s%.1f", c ? "," : "", db(sqrt(sum / n) * sqrt(2)));   // as sine-peak dBFS
    }
    printf("],\"tones\":{");
    int first = 1;
    for (int t = 0; t < MAXCH; t++) {
        if (gAmp[t] <= 0) continue;
        bool dup = false;
        for (int u = 0; u < t; u++) if (gAmp[u] > 0 && gFreq[u] == gFreq[t]) dup = true;
        if (dup) continue;
        printf("%s\"%.0f\":[", first ? "" : ",", gFreq[t]);
        first = 0;
        for (int c = 0; c < MAXCH; c++) {
            for (int i = 0; i < n; i++) buf[i] = gRing[c][(from + i) % RING];
            printf("%s%.1f", c ? "," : "", toneDb(buf, n, gFreq[t]));
        }
        printf("]");
    }
    printf("}}\n");
    fflush(stdout);
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (start()) { printf("{\"error\":\"can't open the Symphony\"}\n"); return 1; }
    printf("{\"ok\":\"ready\",\"rate\":%.0f}\n", gRate);
    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        int ch, ms, settle;
        double hz, dbfs;
        if (sscanf(line, "tone %d %lf %lf", &ch, &hz, &dbfs) == 3 && ch >= 1 && ch <= MAXCH) {
            gFreq[ch - 1] = hz;
            gAmp[ch - 1] = pow(10, dbfs / 20);
            printf("{\"ok\":\"tone\"}\n");
        } else if (sscanf(line, "off %d", &ch) == 1 && ch >= 1 && ch <= MAXCH) {
            gAmp[ch - 1] = 0;
            printf("{\"ok\":\"off\"}\n");
        } else if (!strncmp(line, "alloff", 6)) {
            for (int c = 0; c < MAXCH; c++) gAmp[c] = 0;
            printf("{\"ok\":\"alloff\"}\n");
        } else if (sscanf(line, "measure %d %d", &ms, &settle) == 2) {
            measure(ms, settle);
        } else if (!strncmp(line, "rate", 4)) {
            printf("{\"rate\":%.0f}\n", gRate);
        } else if (!strncmp(line, "reopen", 6)) {
            stop();
            printf(start() ? "{\"error\":\"reopen failed\"}\n" : "{\"ok\":\"reopen\",\"rate\":%.0f}\n", gRate);
        } else if (!strncmp(line, "quit", 4)) {
            break;
        } else {
            printf("{\"error\":\"bad command\"}\n");
        }
        fflush(stdout);
    }
    stop();
    return 0;
}
