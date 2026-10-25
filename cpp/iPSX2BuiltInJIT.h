// iPSX2BuiltInJIT.h — built-in JIT: iPSX2 turns JIT on itself instead of opening StikDebug
// SPDX-License-Identifier: GPL-3.0+
//
// iPSX2 starts its own helper (PlugIns/iPSX2JITHelper.appex, StikJIT compiled in). The
// helper attaches to iPSX2 over LocalDevVPN, exactly as StikDebug does, and runs legacy.js.
// Needs this device's pairing file (the one StikDebug uses) and LocalDevVPN connected.
//
// Call everything on the main thread. Every change posts "iPSX2BuiltInJITStatusDidChange";
// every finished attempt also posts "iPSX2BuiltInJITDidFinish" with
// userInfo @{ @"success": @(BOOL) }.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What stopped the last attempt, so the UI can offer the matching fix.
typedef NS_ENUM(NSInteger, iPSX2BuiltInJITProblem) {
    iPSX2BuiltInJITProblemNoProblem = 0,
    /// Nothing answered at LocalDevVPN's address: the VPN is off.
    iPSX2BuiltInJITProblemNotConnected,
    /// The device closed the connection: it no longer accepts this pairing file.
    iPSX2BuiltInJITProblemPairingRejected,
    /// No pairing file has been imported yet.
    iPSX2BuiltInJITProblemNoPairingFile,
    /// A game already started without JIT since iPSX2 was opened; iPSX2 must be reopened.
    iPSX2BuiltInJITProblemRestartNeeded,
    /// The helper can't run in this installation (see unavailableReason).
    iPSX2BuiltInJITProblemUnavailable,
    iPSX2BuiltInJITProblemOther,
};

@interface iPSX2BuiltInJIT : NSObject

/// nil when built-in JIT can be used here; otherwise why not (simulator, helper missing, ...).
@property (class, nonatomic, readonly, nullable) NSString *unavailableReason;
/// A valid pairing file is stored in Documents/StikJIT/pairingFile.plist.
@property (class, nonatomic, readonly) BOOL hasPairingFile;
/// JIT is on for this launch (by the built-in helper or by StikDebug).
@property (class, nonatomic, readonly) BOOL isJITOn;
/// An attempt (or a setup check) is running.
@property (class, nonatomic, readonly) BOOL isBusy;
/// Progress while busy, "JIT is on." after success.
@property (class, nonatomic, readonly, nullable) NSString *statusText;
/// Why the last attempt failed.
@property (class, nonatomic, readonly, nullable) NSString *errorText;
@property (class, nonatomic, readonly) iPSX2BuiltInJITProblem problem;
/// Result of the last Check Setup.
@property (class, nonatomic, readonly, nullable) NSString *setupCheckText;
/// Turn JIT on automatically each time iPSX2 opens (default YES).
@property (class, nonatomic) BOOL enableAtLaunch;

/// Validates and stores a remote pairing file picked in the Files app.
+ (BOOL)importPairingFileFromURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(importPairingFile(from:));
+ (void)removePairingFile;

/// Starts the helper and turns JIT on. Does nothing while busy or when JIT is already on.
+ (void)enable;
/// Checks LocalDevVPN and the Developer Disk Image (downloading/mounting it) without enabling JIT.
+ (void)checkSetup;
/// Deletes the cached Developer Disk Image so the next attempt downloads it again.
+ (void)resetDeveloperDiskImage;

@property (class, nonatomic, readonly) BOOL isLocalDevVPNInstalled;
/// LocalDevVPN's tunnel (a utun interface in 10.7.0.0/16) is up right now.
@property (class, nonatomic, readonly) BOOL isLocalDevVPNConnected;
/// When the tunnel is down, enable opens LocalDevVPN for a moment to connect it (default YES).
@property (class, nonatomic) BOOL autoConnectLocalDevVPN;
/// Opens LocalDevVPN so it connects and comes back to iPSX2 (or its App Store page).
+ (void)openLocalDevVPN;

/// Scene delegate: iPSX2 became active (first time: turn JIT on if enableAtLaunch).
+ (void)applicationDidBecomeActive;

/// Game start: turns JIT on (or waits for the running attempt) while showing progress over
/// `presenter`, then calls completion(jitOn, cancelled) once the alert is gone.
+ (void)enableWithProgressFrom:(UIViewController *)presenter
                    completion:(void (^)(BOOL jitOn, BOOL cancelled))completion;

@end

NS_ASSUME_NONNULL_END
