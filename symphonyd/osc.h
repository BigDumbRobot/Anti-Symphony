// Minimal OSC 1.0 messages: int32 (i), float32 (f) and string (s) arguments. No bundles.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define OSC_MAX_ARGS 8

typedef struct {
    char type;          // 'i', 'f' or 's'
    int32_t i;
    float f;
    const char *s;      // points into the parsed buffer
} OscArg;

typedef struct {
    const char *path;   // points into the parsed buffer
    int argc;
    OscArg argv[OSC_MAX_ARGS];
} OscMsg;

// Parses one message. The buffer must stay alive while the message is used.
bool osc_parse(const uint8_t *buf, size_t len, OscMsg *m);

// Builds a message. types is a string of 'i', 'f', 's', followed by matching values
// (int, double, const char *). Returns the length, or 0 if it doesn't fit.
size_t osc_build(uint8_t *buf, size_t cap, const char *path, const char *types, ...);

// Builds a message whose arguments are n floats (n <= 64), e.g. a set of meter levels.
size_t osc_build_floats(uint8_t *buf, size_t cap, const char *path, const float *v, int n);

// Numeric value of an argument (i or f), for handlers that accept either.
double osc_num(const OscArg *a);
