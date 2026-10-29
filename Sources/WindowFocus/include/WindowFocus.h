// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
#include <stdint.h>
#include <sys/types.h>

/// Activate a process while asking macOS to bring forward only its front window.
int32_t WSActivateFrontWindowOnly(pid_t pid);

/// Activate only the given window after validating its owning process.
/// Returns unimpErr when the optional WindowServer entry point is unavailable.
int32_t WSActivateWindow(pid_t pid, uint32_t windowID);

/// Request key focus for this window using an optional targeted WindowServer event.
/// Does not post a paired mouse-up or change the cursor position.
int32_t WSMakeWindowKey(pid_t pid, uint32_t windowID);
