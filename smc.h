// AppleSMC access shared by the menu bar app and the fan helper.

#ifndef TURBOBAR_SMC_H
#define TURBOBAR_SMC_H

#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { kFanAuto = 0, kFanMinPercent = 25, kMaxFans = 4 };

// The message layout AppleSMC expects.
typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } version;
    struct { uint16_t version, length; uint32_t cpu, gpu, mem; } limits;
    struct { uint32_t size, type; uint8_t attributes; } info;
    uint8_t result, status, command;
    uint32_t data32;
    uint8_t bytes[32];
} SMCMessage;
_Static_assert(sizeof(SMCMessage) == 80, "AppleSMC message layout");

enum { kSMCSelector = 2, kSMCReadBytes = 5, kSMCWriteBytes = 6, kSMCReadInfo = 9 };

typedef struct {
    int index;
    uint32_t speedKey;
    float min, max, rpm;
} Fan;

static io_connect_t gSMC;
static Fan gFans[kMaxFans];
static int gFanCount;

static inline uint32_t FourCC(const char *s) {
    return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3];
}

static inline bool SMCSend(const SMCMessage *in, SMCMessage *out) {
    size_t outSize = sizeof *out;
    return IOConnectCallStructMethod(gSMC, kSMCSelector, in, sizeof *in, out, &outSize) == kIOReturnSuccess
        && out->result == 0;
}

static inline bool SMCCall(uint32_t key, uint8_t command, uint32_t size, SMCMessage *out) {
    SMCMessage in = {.key = key, .command = command};
    in.info.size = size;
    return SMCSend(&in, out);
}

static inline bool SMCReadFloat(uint32_t key, float *value) {
    SMCMessage message;
    if (!SMCCall(key, kSMCReadBytes, sizeof(float), &message)) return false;
    memcpy(value, message.bytes, sizeof(float));
    return true;
}

// Temperatures use sp78: signed fixed point with 8 fraction bits.
static inline bool SMCReadCelsius(uint32_t key, double *celsius) {
    SMCMessage message;
    if (!SMCCall(key, kSMCReadBytes, 2, &message)) return false;
    *celsius = (int16_t)(message.bytes[0] << 8 | message.bytes[1]) / 256.0;
    return true;
}

// Writing needs root, so only the helper calls this.
static inline bool SMCWrite(uint32_t key, const void *value, uint32_t size) {
    SMCMessage in = {.key = key, .command = kSMCWriteBytes};
    SMCMessage out;
    in.info.size = size;
    memcpy(in.bytes, value, size);
    return SMCSend(&in, &out);
}

static inline uint32_t FanKey(int index, const char *suffix) {
    char name[6];
    snprintf(name, sizeof name, "F%d%s", index, suffix);
    return FourCC(name);
}

static inline void OpenFans(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return;
    kern_return_t opened = IOServiceOpen(service, mach_task_self(), 0, &gSMC);
    IOObjectRelease(service);
    if (opened != KERN_SUCCESS) return;

    SMCMessage message;
    if (!SMCCall(FourCC("FNum"), kSMCReadBytes, 1, &message)) return;
    int count = message.bytes[0] < kMaxFans ? message.bytes[0] : kMaxFans;

    for (int i = 0; i < count; i++) {
        Fan fan = {.index = i, .speedKey = FanKey(i, "Ac")};
        if (!SMCCall(fan.speedKey, kSMCReadInfo, 0, &message) || message.info.type != FourCC("flt ")) continue;
        if (!SMCReadFloat(FanKey(i, "Mn"), &fan.min) || !SMCReadFloat(FanKey(i, "Mx"), &fan.max)) continue;
        if (fan.max <= fan.min) continue;
        gFans[gFanCount++] = fan;
    }
}

static inline bool FansAreManual(void) {
    SMCMessage message;
    return gFanCount > 0
        && SMCCall(FanKey(gFans[0].index, "Md"), kSMCReadBytes, 1, &message)
        && message.bytes[0] == 1;
}

#endif
