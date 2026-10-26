// iPSX2Rumble.mm — DualShock 2 vibration on the connected game controller (ARC)
// SPDX-License-Identifier: GPL-3.0+
//
// [iPSX2 #17] A PS2 game drives the DualShock 2's two motors: a large, variable-speed one (low
// frequency) and a small on/off one (high frequency). PadDualshock2::Poll hands every update to
// iPSX2_UpdatePadVibration, and the motors are played on the controller through the GameController
// framework's haptics (CoreHaptics): large motor on the left handle, small on the right, as PCSX2's
// SDL backend does elsewhere. iPadOS offers haptics only for some controllers (PlayStation, Xbox,
// ...). For the others controller.haptics is nil, an app has no other way to reach their motors,
// and iPSX2_ControllerRumbleStatus says so.
//
// All CoreHaptics work runs on one serial queue, so the emulator thread never waits on it. The
// emulator thread only publishes the wanted levels (quantized, so the per-frame repeats cost
// nothing) and wakes the queue when they change. A watchdog stops the motors when the game stops
// sending updates (paused, loading, VM stopped).

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>

#include "iPSX2Rumble.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>

// ---------------------------------------------------------------------------------------------
// One haptics engine with a continuous player: one motor, or both handles together.

@interface iPSX2RumbleMotor : NSObject
@property (nonatomic, strong, nullable) CHHapticEngine* engine;
@property (nonatomic, strong, nullable) id<CHHapticPatternPlayer> player;
@property (nonatomic, assign) float sharpness;
@property (nonatomic, assign) BOOL playing;
// Set from CoreHaptics' handlers (any thread) when the engine stopped or was reset.
@property (atomic, assign) BOOL dead;
@end

@implementation iPSX2RumbleMotor

+ (nullable instancetype)motorWithController:(GCController*)controller
                                    locality:(GCHapticsLocality)locality
                                   sharpness:(float)sharpness
{
    GCDeviceHaptics* haptics = controller.haptics;
    if (!haptics)
        return nil;
    CHHapticEngine* engine = [haptics createEngineWithLocality:locality];
    if (!engine)
        return nil;
    NSError* error = nil;
    if (![engine startAndReturnError:&error]) {
        fprintf(stderr, "@@RUMBLE@@ couldn't start the %s haptics engine: %s\n", locality.UTF8String,
            error ? error.localizedDescription.UTF8String : "?");
        return nil;
    }

    iPSX2RumbleMotor* motor = [[iPSX2RumbleMotor alloc] init];
    motor.engine = engine;
    motor.sharpness = sharpness;
    __weak iPSX2RumbleMotor* weakMotor = motor;
    engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        weakMotor.dead = YES; // rebuilt on the next update
    };
    engine.resetHandler = ^{
        weakMotor.dead = YES;
    };
    return motor;
}

- (BOOL)setIntensity:(float)intensity
{
    NSError* error = nil;
    if (intensity <= 0.0f) {
        if (self.player && self.playing)
            [self.player stopAtTime:CHHapticTimeImmediate error:&error];
        self.playing = NO;
        return YES;
    }

    if (!self.engine)
        return NO;

    if (!self.player) {
        NSArray<CHHapticEventParameter*>* params = @[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0f],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:self.sharpness],
        ];
        CHHapticEvent* event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                             parameters:params
                                                           relativeTime:0
                                                               duration:GCHapticDurationInfinite];
        CHHapticPattern* pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        if (!pattern)
            return NO;
        self.player = [self.engine createPlayerWithPattern:pattern error:&error];
        if (!self.player)
            return NO;
        self.playing = NO;
    }

    CHHapticDynamicParameter* level =
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                                        value:intensity
                                                 relativeTime:0];
    if (![self.player sendParameters:@[level] atTime:CHHapticTimeImmediate error:&error])
        return NO;
    if (!self.playing) {
        if (![self.player startAtTime:CHHapticTimeImmediate error:&error])
            return NO;
        self.playing = YES;
    }
    return YES;
}

- (void)shutdown
{
    if (self.player) {
        [self.player cancelAndReturnError:nil];
        self.player = nil;
    }
    if (self.engine) {
        [self.engine stopWithCompletionHandler:nil];
        self.engine = nil;
    }
    self.playing = NO;
}

@end

// ---------------------------------------------------------------------------------------------

static dispatch_queue_t s_queue;

// Rumble-queue state.
static GCController* s_controller;       // where vibration goes (picked on the main thread)
static iPSX2RumbleMotor* s_large;        // left handle, or the only engine
static iPSX2RumbleMotor* s_small;        // right handle; nil when one engine plays both motors
static int s_appliedLarge = 0;           // levels the motors are playing (0..1000)
static int s_appliedSmall = 0;
static int64_t s_buildFailedAtMs = INT64_MIN / 2;
static dispatch_source_t s_watchdog;
static bool s_loggedFirstRequest = false;

// Shared with the emulator and main threads.
static std::atomic<bool> s_enabled{true};
static std::atomic<float> s_strength{1.0f};
static std::atomic<int> s_wantLarge{0};  // what the game asks for, after the settings (0..1000)
static std::atomic<int> s_wantSmall{0};
static std::atomic<bool> s_applyQueued{false};
static std::atomic<int64_t> s_lastUpdateMs{0};
static std::atomic<int64_t> s_testUntilMs{0};

static int64_t NowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

static int Quantize(float value)
{
    if (!(value > 0.0f)) // also NaN
        return 0;
    return static_cast<int>(std::lround(std::min(value, 1.0f) * 1000.0f));
}

static void EnsureQueue()
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_queue = dispatch_queue_create("iPSX2.rumble", DISPATCH_QUEUE_SERIAL);
    });
}

static void ReleaseMotorsOnQueue()
{
    [s_large shutdown];
    [s_small shutdown];
    s_large = nil;
    s_small = nil;
    s_appliedLarge = 0;
    s_appliedSmall = 0;
}

static bool MotorsAliveOnQueue()
{
    return s_large && !s_large.dead && (!s_small || !s_small.dead);
}

static bool BuildMotorsOnQueue()
{
    if (MotorsAliveOnQueue())
        return true;

    ReleaseMotorsOnQueue();
    if (!s_controller || !s_controller.haptics)
        return false;
    const int64_t now = NowMs();
    if (now - s_buildFailedAtMs < 2000)
        return false;

    NSSet<GCHapticsLocality>* localities = s_controller.haptics.supportedLocalities;
    if ([localities containsObject:GCHapticsLocalityLeftHandle] &&
        [localities containsObject:GCHapticsLocalityRightHandle]) {
        s_large = [iPSX2RumbleMotor motorWithController:s_controller locality:GCHapticsLocalityLeftHandle sharpness:0.3f];
        s_small = [iPSX2RumbleMotor motorWithController:s_controller locality:GCHapticsLocalityRightHandle sharpness:0.8f];
        if (s_large && s_small) {
            fprintf(stderr, "@@RUMBLE@@ motors ready: left handle = large motor, right handle = small motor\n");
            return true;
        }
        ReleaseMotorsOnQueue();
    }

    // One engine plays both motors.
    for (GCHapticsLocality locality in @[GCHapticsLocalityHandles, GCHapticsLocalityDefault, GCHapticsLocalityAll]) {
        s_large = [iPSX2RumbleMotor motorWithController:s_controller locality:locality sharpness:0.5f];
        if (s_large) {
            fprintf(stderr, "@@RUMBLE@@ motors ready: one engine (%s) for both motors\n", locality.UTF8String);
            return true;
        }
    }

    s_buildFailedAtMs = now;
    fprintf(stderr, "@@RUMBLE@@ couldn't create a haptics engine for the controller\n");
    return false;
}

static void UpdateWatchdogOnQueue(bool active);

static void SetMotorsOnQueue(int large, int small)
{
    if (large <= 0 && small <= 0) {
        if (s_large)
            [s_large setIntensity:0.0f];
        if (s_small)
            [s_small setIntensity:0.0f];
        s_appliedLarge = 0;
        s_appliedSmall = 0;
        UpdateWatchdogOnQueue(false);
        return;
    }

    if (large == s_appliedLarge && small == s_appliedSmall && MotorsAliveOnQueue())
        return;
    if (!BuildMotorsOnQueue())
        return;

    BOOL ok;
    if (s_small) {
        ok = [s_large setIntensity:large / 1000.0f];
        ok = [s_small setIntensity:small / 1000.0f] && ok;
    } else {
        // One engine: the small motor is only a light buzz on a real DualShock 2.
        ok = [s_large setIntensity:std::max(large, small * 3 / 4) / 1000.0f];
    }
    if (!ok) {
        // The engine went away (app in the background, controller reset): rebuild next time.
        s_large.dead = YES;
        s_appliedLarge = -1;
        s_appliedSmall = -1;
        return;
    }
    s_appliedLarge = large;
    s_appliedSmall = small;
    UpdateWatchdogOnQueue(true);
}

static void ApplyOnQueue()
{
    if (NowMs() < s_testUntilMs.load(std::memory_order_relaxed))
        return; // the test pattern has the motors
    const int large = s_wantLarge.load(std::memory_order_relaxed);
    const int small = s_wantSmall.load(std::memory_order_relaxed);
    if (!s_loggedFirstRequest && (large > 0 || small > 0)) {
        s_loggedFirstRequest = true;
        fprintf(stderr, "@@RUMBLE@@ game started vibration (large=%d small=%d /1000); controller=\"%s\" haptics=%s\n",
            large, small, s_controller ? (s_controller.vendorName.UTF8String ?: "?") : "none",
            (s_controller && s_controller.haptics) ? "yes" : "no");
    }
    SetMotorsOnQueue(large, small);
}

static void WatchdogTickOnQueue()
{
    const int64_t now = NowMs();
    if (now < s_testUntilMs.load(std::memory_order_relaxed))
        return;
    if (now - s_lastUpdateMs.load(std::memory_order_relaxed) < 300)
        return;
    // The game stopped sending motor updates (paused, loading, VM stopped): stop the motors.
    s_wantLarge.store(0, std::memory_order_relaxed);
    s_wantSmall.store(0, std::memory_order_relaxed);
    SetMotorsOnQueue(0, 0);
}

static void UpdateWatchdogOnQueue(bool active)
{
    if (active && !s_watchdog) {
        s_watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, s_queue);
        dispatch_source_set_timer(s_watchdog, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
            100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(s_watchdog, ^{
            WatchdogTickOnQueue();
        });
        dispatch_resume(s_watchdog);
    } else if (!active && s_watchdog) {
        dispatch_source_cancel(s_watchdog);
        s_watchdog = nil;
    }
}

static void ScheduleApply()
{
    EnsureQueue();
    if (s_applyQueued.exchange(true, std::memory_order_acq_rel))
        return;
    dispatch_async(s_queue, ^{
        s_applyQueued.store(false, std::memory_order_release);
        ApplyOnQueue();
    });
}

// Main thread. The controller that reports haptics wins; otherwise the current one.
static GCController* PickController()
{
    GCController* current = GCController.current;
    if (current.haptics)
        return current;
    for (GCController* controller in GCController.controllers) {
        if (controller.haptics)
            return controller;
    }
    return current ?: GCController.controllers.firstObject;
}

// Main thread.
static void ControllersChangedOnMain()
{
    GCController* controller = PickController();
    if (controller) {
        NSMutableArray<NSString*>* names = [NSMutableArray array];
        for (GCHapticsLocality locality in controller.haptics.supportedLocalities)
            [names addObject:locality];
        fprintf(stderr, "@@RUMBLE@@ controller=\"%s\" category=\"%s\" haptics=%s localities=[%s]\n",
            controller.vendorName.UTF8String ?: "?", controller.productCategory.UTF8String ?: "?",
            controller.haptics ? "yes" : "no", [names componentsJoinedByString:@","].UTF8String ?: "");
    } else {
        fprintf(stderr, "@@RUMBLE@@ no game controller connected\n");
    }

    dispatch_async(s_queue, ^{
        if (s_controller == controller)
            return;
        ReleaseMotorsOnQueue();
        UpdateWatchdogOnQueue(false);
        s_controller = controller;
        s_buildFailedAtMs = INT64_MIN / 2;
        ApplyOnQueue();
    });
}

extern "C" void iPSX2_RumbleInit(void)
{
    EnsureQueue();
    static bool s_started = false; // main thread only
    if (s_started)
        return;
    s_started = true;

    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    NSArray<NSNotificationName>* names = @[
        GCControllerDidConnectNotification,
        GCControllerDidDisconnectNotification,
        GCControllerDidBecomeCurrentNotification,
    ];
    for (NSNotificationName name in names) {
        [center addObserverForName:name
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification* note) {
                            ControllersChangedOnMain();
                        }];
    }
    ControllersChangedOnMain();
}

extern "C" void iPSX2_UpdatePadVibration(unsigned int pad_index, float large_intensity, float small_intensity)
{
    if (pad_index != 0)
        return; // the controller is player 1
    s_lastUpdateMs.store(NowMs(), std::memory_order_relaxed);

    int large = 0;
    int small = 0;
    if (s_enabled.load(std::memory_order_relaxed)) {
        const float strength = s_strength.load(std::memory_order_relaxed);
        large = Quantize(large_intensity * strength);
        small = Quantize(small_intensity * strength);
    }
    if (large == s_wantLarge.load(std::memory_order_relaxed) && small == s_wantSmall.load(std::memory_order_relaxed))
        return;
    s_wantLarge.store(large, std::memory_order_relaxed);
    s_wantSmall.store(small, std::memory_order_relaxed);
    ScheduleApply();
}

extern "C" void iPSX2_StopControllerRumble(void)
{
    EnsureQueue();
    s_wantLarge.store(0, std::memory_order_relaxed);
    s_wantSmall.store(0, std::memory_order_relaxed);
    s_testUntilMs.store(0, std::memory_order_relaxed);
    dispatch_async(s_queue, ^{
        SetMotorsOnQueue(0, 0);
    });
}

extern "C" void iPSX2_SetControllerRumbleConfig(bool enabled, float strength)
{
    if (!(strength >= 0.0f)) // also NaN
        strength = 1.0f;
    s_enabled.store(enabled, std::memory_order_relaxed);
    s_strength.store(std::min(strength, 2.0f), std::memory_order_relaxed);
    if (!enabled)
        iPSX2_StopControllerRumble();
}

extern "C" void iPSX2_TestControllerRumble(void)
{
    EnsureQueue();
    const int level = Quantize(s_strength.load(std::memory_order_relaxed));
    s_testUntilMs.store(NowMs() + 1400, std::memory_order_relaxed);
    dispatch_async(s_queue, ^{
        SetMotorsOnQueue(level, 0); // large motor
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), s_queue, ^{
        SetMotorsOnQueue(0, level); // small motor
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC), s_queue, ^{
        SetMotorsOnQueue(0, 0);
        s_testUntilMs.store(0, std::memory_order_relaxed);
        ApplyOnQueue(); // back to whatever the game asks for
    });
}

extern "C" int iPSX2_ControllerRumbleStatus(void)
{
    GCController* controller = PickController();
    if (!controller)
        return 0;
    return controller.haptics ? 2 : 1;
}

extern "C" NSString* _Nullable iPSX2_ControllerRumbleName(void)
{
    GCController* controller = PickController();
    if (!controller)
        return nil;
    return controller.vendorName.length ? controller.vendorName : @"Your controller";
}
