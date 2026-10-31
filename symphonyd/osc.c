#include "osc.h"
#include <stdarg.h>
#include <string.h>

static size_t pad4(size_t n) { return (n + 3) & ~(size_t)3; }

// Reads a NUL-terminated, 4-byte-padded string at *pos. Returns NULL if malformed.
static const char *readString(const uint8_t *buf, size_t len, size_t *pos) {
    const char *s = (const char *)buf + *pos;
    size_t max = len - *pos;
    size_t n = strnlen(s, max);
    if (n == max) return NULL;
    *pos += pad4(n + 1);
    if (*pos > len) return NULL;
    return s;
}

static uint32_t be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

bool osc_parse(const uint8_t *buf, size_t len, OscMsg *m) {
    memset(m, 0, sizeof *m);
    if (len < 4 || len % 4 || buf[0] != '/') return false;
    size_t pos = 0;
    if (!(m->path = readString(buf, len, &pos))) return false;
    if (pos == len) return true;                       // no type tag: no arguments
    const char *types = readString(buf, len, &pos);
    if (!types || types[0] != ',') return false;
    for (const char *t = types + 1; *t; t++) {
        if (m->argc == OSC_MAX_ARGS) return false;
        OscArg *a = &m->argv[m->argc++];
        a->type = *t;
        switch (*t) {
        case 'i':
            if (pos + 4 > len) return false;
            a->i = (int32_t)be32(buf + pos);
            a->f = (float)a->i;
            pos += 4;
            break;
        case 'f': {
            if (pos + 4 > len) return false;
            uint32_t u = be32(buf + pos);
            memcpy(&a->f, &u, 4);
            a->i = (int32_t)a->f;
            pos += 4;
            break;
        }
        case 's':
            if (!(a->s = readString(buf, len, &pos))) return false;
            break;
        case 'T': a->type = 'i'; a->i = 1; a->f = 1; break;
        case 'F': a->type = 'i'; a->i = 0; a->f = 0; break;
        default:
            return false;                              // unsupported type
        }
    }
    return true;
}

static bool put(uint8_t *buf, size_t cap, size_t *pos, const void *data, size_t n, size_t padded) {
    if (*pos + padded > cap) return false;
    memcpy(buf + *pos, data, n);
    memset(buf + *pos + n, 0, padded - n);
    *pos += padded;
    return true;
}

static bool putString(uint8_t *buf, size_t cap, size_t *pos, const char *s) {
    size_t n = strlen(s);
    return put(buf, cap, pos, s, n, pad4(n + 1));
}

static bool put32(uint8_t *buf, size_t cap, size_t *pos, uint32_t v) {
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    return put(buf, cap, pos, b, 4, 4);
}

size_t osc_build(uint8_t *buf, size_t cap, const char *path, const char *types, ...) {
    size_t pos = 0;
    char tags[OSC_MAX_ARGS + 2] = ",";
    if (strlen(types) > OSC_MAX_ARGS) return 0;
    strcat(tags, types);
    if (!putString(buf, cap, &pos, path) || !putString(buf, cap, &pos, tags)) return 0;
    va_list ap;
    va_start(ap, types);
    bool ok = true;
    for (const char *t = types; *t && ok; t++) {
        if (*t == 'i') ok = put32(buf, cap, &pos, (uint32_t)va_arg(ap, int));
        else if (*t == 'f') {
            float f = (float)va_arg(ap, double);
            uint32_t u;
            memcpy(&u, &f, 4);
            ok = put32(buf, cap, &pos, u);
        } else if (*t == 's') ok = putString(buf, cap, &pos, va_arg(ap, const char *));
        else ok = false;
    }
    va_end(ap);
    return ok ? pos : 0;
}

size_t osc_build_floats(uint8_t *buf, size_t cap, const char *path, const float *v, int n) {
    char tags[66] = ",";
    if (n < 0 || n > 64) return 0;
    for (int i = 0; i < n; i++) tags[i + 1] = 'f';
    tags[n + 1] = 0;
    size_t pos = 0;
    if (!putString(buf, cap, &pos, path) || !putString(buf, cap, &pos, tags)) return 0;
    for (int i = 0; i < n; i++) {
        uint32_t u;
        memcpy(&u, &v[i], 4);
        if (!put32(buf, cap, &pos, u)) return 0;
    }
    return pos;
}

double osc_num(const OscArg *a) {
    return a->type == 'f' ? a->f : a->i;
}
