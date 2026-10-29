// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 dongx.
#include <stdint.h>
#include <sys/types.h>

/// Activate a process while asking macOS to bring forward only its front window.
int32_t WSActivateFrontWindowOnly(pid_t pid);
