// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
#include "WindowFocus.h"
#include <ApplicationServices/ApplicationServices.h>

int32_t WSActivateFrontWindowOnly(pid_t pid) {
    ProcessSerialNumber process = {0, 0};
    OSStatus result = GetProcessForPID(pid, &process);
    if (result != noErr) return result;
    return SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly);
}

#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

typedef OSStatus (*WSWindowActivationFunction)(ProcessSerialNumber *, CGWindowID, uint32_t);
typedef OSStatus (*WSWindowKeyFunction)(ProcessSerialNumber *, uint8_t *);
static WSWindowActivationFunction windowActivation;
static WSWindowKeyFunction windowKey;
static pthread_once_t windowActivationOnce = PTHREAD_ONCE_INIT;

static void WSLoadWindowActivation(void) {
    void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    if (library) {
        windowActivation = (WSWindowActivationFunction)dlsym(library, "_SLPSSetFrontProcessWithOptions");
        windowKey = (WSWindowKeyFunction)dlsym(library, "SLPSPostEventRecordTo");
    }
}

static Boolean WSWindowBelongsToProcess(pid_t pid, uint32_t windowID) {
    if (pid <= 0 || windowID == 0) return false;
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID);
    Boolean matches = false;
    if (windows && CFArrayGetCount(windows) == 1) {
        CFDictionaryRef window = (CFDictionaryRef)CFArrayGetValueAtIndex(windows, 0);
        CFNumberRef ownerValue = CFDictionaryGetValue(window, kCGWindowOwnerPID);
        CFNumberRef idValue = CFDictionaryGetValue(window, kCGWindowNumber);
        int32_t owner = 0;
        int32_t actualID = 0;
        matches = ownerValue && idValue &&
            CFNumberGetValue(ownerValue, kCFNumberSInt32Type, &owner) &&
            CFNumberGetValue(idValue, kCFNumberSInt32Type, &actualID) &&
            owner == pid && (uint32_t)actualID == windowID;
    }
    if (windows) CFRelease(windows);
    return matches;
}

int32_t WSActivateWindow(pid_t pid, uint32_t windowID) {
    if (!WSWindowBelongsToProcess(pid, windowID)) return paramErr;
    pthread_once(&windowActivationOnce, WSLoadWindowActivation);
    if (!windowActivation) return unimpErr;
    ProcessSerialNumber process = {0, 0};
    OSStatus result = GetProcessForPID(pid, &process);
    if (result != noErr) return result;
    // User-initiated activation with a specific window. Do not set the all-windows flag.
    return windowActivation(&process, windowID, 0x200);
}

int32_t WSMakeWindowKey(pid_t pid, uint32_t windowID) {
    if (!WSWindowBelongsToProcess(pid, windowID)) return paramErr;
    pthread_once(&windowActivationOnce, WSLoadWindowActivation);
    if (!windowKey) return unimpErr;
    ProcessSerialNumber process = {0, 0};
    OSStatus result = GetProcessForPID(pid, &process);
    if (result != noErr) return result;
    // WindowServer event layout documented by the AltTab/Hammerspoon sources.
    // Address the window by ID and aim outside its content, without moving the cursor.
    // A single down event avoids completing a click. No matching up is posted.
    uint8_t event[0x100] = {0};
    const CGPoint outsideContent = {300000.0, 300000.0};
    event[0x04] = 0xf8;
    event[0x08] = 0x01;
    event[0x3a] = 0x10;
    memcpy(event + 0x3c, &windowID, sizeof(windowID));
    memcpy(event + 0x20, &outsideContent, sizeof(outsideContent));
    return windowKey(&process, event);
}
