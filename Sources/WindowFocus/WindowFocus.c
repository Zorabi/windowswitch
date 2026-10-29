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
