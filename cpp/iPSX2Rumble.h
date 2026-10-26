// iPSX2Rumble.h — DualShock 2 vibration on the connected game controller
// SPDX-License-Identifier: GPL-3.0+
//
// [iPSX2 #17] See iPSX2Rumble.mm. Every function can be called from any thread unless noted.

#pragma once

#include <stdbool.h>

#ifdef __OBJC__
@class NSString;
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Start following controller connections (main thread, once at launch; later calls do nothing).
void iPSX2_RumbleInit(void);

/// Motor update from PadDualshock2::Poll (emulator thread), intensities 0..1. Only pad 0 is played.
void iPSX2_UpdatePadVibration(unsigned int pad_index, float large_intensity, float small_intensity);

/// Stop both motors now (VM shutdown, app leaving the foreground).
void iPSX2_StopControllerRumble(void);

/// User settings: vibration on/off and strength (1 = as the game asks, up to 2).
void iPSX2_SetControllerRumbleConfig(bool enabled, float strength);

/// Short test pattern: large motor, then small motor (Settings › Game Controller).
void iPSX2_TestControllerRumble(void);

/// Main thread. 0 = no controller, 1 = iPadOS offers no haptics for this controller,
/// 2 = vibration available.
int iPSX2_ControllerRumbleStatus(void);

#ifdef __OBJC__
/// Main thread. Name of the controller vibration goes to, or nil if none is connected.
NSString* _Nullable iPSX2_ControllerRumbleName(void);
#endif

#ifdef __cplusplus
}
#endif
