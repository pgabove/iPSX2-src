// iPSX2Bridge.h — ObjC bridge for C++ emulator control
// SPDX-License-Identifier: GPL-3.0+

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, iPSX2EmulatorState) {
    iPSX2EmulatorStateStopped = 0,
    iPSX2EmulatorStateRunning,
    iPSX2EmulatorStatePaused,
    iPSX2EmulatorStateSaving,
    iPSX2EmulatorStateSuspended,
};

typedef NS_ENUM(NSInteger, iPSX2CoreType) {
    iPSX2CoreTypeJIT = 0,
    iPSX2CoreTypeInterpreter = 1,
};

typedef NS_ENUM(NSInteger, iPSX2PadButton) {
    iPSX2PadButtonUp = 0,
    iPSX2PadButtonDown,
    iPSX2PadButtonLeft,
    iPSX2PadButtonRight,
    iPSX2PadButtonCross,
    iPSX2PadButtonCircle,
    iPSX2PadButtonSquare,
    iPSX2PadButtonTriangle,
    iPSX2PadButtonL1,
    iPSX2PadButtonR1,
    iPSX2PadButtonL2,
    iPSX2PadButtonR2,
    iPSX2PadButtonStart,
    iPSX2PadButtonSelect,
    iPSX2PadButtonL3,
    iPSX2PadButtonR3,
};

@interface VMController : NSObject
+ (instancetype)sharedInstance;
- (void)startVMThread;
- (void)requestVMBoot;
- (void)requestVMShutdown;
@property (nonatomic, readonly) BOOL isVMRunning;
@property (nonatomic, readonly) BOOL isVMThreadActive;
@end

@interface iPSX2Bridge : NSObject

// Game render view (for UIViewRepresentable)
+ (nonnull UIView *)gameRenderView;

// Lifecycle
+ (void)saveNVRAM;
+ (void)saveMemoryCards;
+ (void)saveAllState;  // NVM + MC
+ (BOOL)isRunning;

// NVM status
+ (nullable NSDate *)lastNVMSaveDate;
+ (nullable NSString *)nvmFilePath;
+ (BOOL)nvmFileExists;

// Pad input
+ (void)setPadButton:(iPSX2PadButton)button pressed:(BOOL)pressed;
+ (void)setLeftStickX:(float)x Y:(float)y;
+ (void)setRightStickX:(float)x Y:(float)y;

// VM control
+ (void)requestVMStop;
+ (void)setFullScreen:(BOOL)enabled;

// Info
+ (nonnull NSString *)biosName;
+ (nonnull NSString *)buildVersion;
// YES when a debugger (StikDebug) has enabled JIT for this launch. Without it every
// CPU core silently falls back to the interpreter, which is far too slow for 3D games.
+ (BOOL)isJITAvailable;
// 0 = JIT ready, 1 = not opened from StikDebug, 2 = StikDebug attached but no script
// answered iPSX2's JIT request (iOS 26+ needs legacy.js assigned to iPSX2).
+ (NSInteger)jitStatus;

// OSD overlay
+ (void)setPerformanceOverlayVisible:(BOOL)visible;
+ (BOOL)isPerformanceOverlayVisible;
+ (void)applyOsdPreset:(int)preset;  // 0=off, 1=simple, 2=detail, 3=full

// ISO management
+ (nullable NSString *)currentISOPath;
+ (nonnull NSString *)isoDirectory;
+ (nonnull NSString *)documentsDirectory;
+ (nonnull NSArray<NSString *> *)availableISOs;

// [P44] ISO boot
+ (void)bootISO:(nonnull NSString *)isoName;

// [P44] BIOS management
+ (nonnull NSString *)biosDirectory;
+ (nonnull NSArray<NSString *> *)availableBIOSes;
+ (nonnull NSString *)defaultBIOSName;
+ (void)setDefaultBIOS:(nonnull NSString *)biosName;

// [P44] Favorites
+ (BOOL)isFavorite:(nonnull NSString *)isoName;
+ (void)setFavorite:(nonnull NSString *)isoName favorite:(BOOL)favorite;

// [P44] INI generic getter/setter
+ (int)getINIInt:(nonnull NSString *)section key:(nonnull NSString *)key defaultValue:(int)def;
+ (BOOL)getINIBool:(nonnull NSString *)section key:(nonnull NSString *)key defaultValue:(BOOL)def;
+ (float)getINIFloat:(nonnull NSString *)section key:(nonnull NSString *)key defaultValue:(float)def;
+ (nonnull NSString *)getINIString:(nonnull NSString *)section key:(nonnull NSString *)key defaultValue:(nonnull NSString *)def;
+ (void)setINIInt:(nonnull NSString *)section key:(nonnull NSString *)key value:(int)value;
+ (void)setINIBool:(nonnull NSString *)section key:(nonnull NSString *)key value:(BOOL)value;
+ (void)setINIFloat:(nonnull NSString *)section key:(nonnull NSString *)key value:(float)value;
+ (void)setINIString:(nonnull NSString *)section key:(nonnull NSString *)key value:(nonnull NSString *)value;

// [P44] VM lifecycle for menu flow
+ (BOOL)isVMRunning;
+ (BOOL)hasBIOS;
+ (void)requestVMBoot;
+ (void)requestVMShutdown;

// [P53] Gamepad button mapping
+ (void)startButtonCapture;
+ (void)stopButtonCapture;
+ (void)pollGamepadForCapture;  // call from main thread when VM is not running
+ (int)capturedButton;  // returns SDL_GamepadButton or -1
+ (void)setButtonMapping:(int)ps2Index toSDLButton:(int)sdlButton;
+ (int)getButtonMapping:(int)ps2Index;
+ (void)resetButtonMappings;

// [iPSX2 #12] Safe-area insets (points) of the area the game view extends under (status bar,
// window controls). The top on-screen stats are pushed clear of it.
+ (void)setOverlaySafeAreaTop:(CGFloat)top left:(CGFloat)left right:(CGFloat)right;
// [iPSX2 #12] YES while SDL has a physical game controller open.
+ (BOOL)isGamepadConnected;

// [iPSX2 #17] Save states: PCSX2's per-game slot files (Documents/sstates), slots 1-10.
// Modification time (seconds since 1970) of each slot's file, 0 for an empty slot. nil when no
// game with a disc serial is running (BIOS, ELF), since the files are named after the serial.
+ (nullable NSArray<NSNumber *> *)saveStateSlotTimestamps NS_SWIFT_NAME(saveStateSlotTimestamps());
// Queue a save/load on the emulator thread; it runs at the next frame and shows its progress on the
// in-game OSD. iPSX2SaveStateFinished (userInfo: slot, save, ok) follows on the main queue.
// NO if no game is running.
+ (BOOL)saveStateToSlot:(NSInteger)slot NS_SWIFT_NAME(saveState(slot:));
+ (BOOL)loadStateFromSlot:(NSInteger)slot NS_SWIFT_NAME(loadState(slot:));

// [iPSX2 #17] Controller vibration (the DualShock 2 motors, played through iPadOS's controller haptics).
// 0 = no controller, 1 = iPadOS offers no vibration for this controller, 2 = vibration available.
+ (NSInteger)controllerVibrationStatus;
// Name of the controller vibration goes to; nil when none is connected.
+ (nullable NSString *)controllerName;
+ (void)setControllerVibrationEnabled:(BOOL)enabled strength:(float)strength
    NS_SWIFT_NAME(setControllerVibration(enabled:strength:));
// Large motor, then small motor, at the current strength.
+ (void)testControllerVibration;

@end
