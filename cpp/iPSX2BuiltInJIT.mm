// iPSX2BuiltInJIT.mm — built-in JIT (see iPSX2BuiltInJIT.h)
// SPDX-License-Identifier: GPL-3.0+
//
// A process can't attach a debugger to itself, so iPSX2 starts an app extension of its own
// through NSExtension (the way Husk's built-in StikJIT and LiveContainer start theirs) and
// sends it iPSX2's PID and the pairing file. StikJIT, compiled into the helper, attaches to
// iPSX2 over LocalDevVPN and runs legacy.js, the same script StikDebug runs for iPSX2.
// iPSX2 notices the attach, does its usual brk #0x69 handshake (iPSX2_ActivateBuiltInJIT),
// legacy.js detaches, and the helper's request ends.
//
// Compiled with ARC (see CMakeLists.txt). Everything here runs on the main thread.

#import "iPSX2BuiltInJIT.h"

#include <TargetConditionals.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

#include "common/Darwin/DarwinMisc.h"

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
// ios_main.mm
extern "C" int iPSX2_ActivateBuiltInJIT(void);
extern "C" bool iPSX2_VMThreadWasCreated(void);

static NSString* const kStatusDidChange = @"iPSX2BuiltInJITStatusDidChange";
static NSString* const kDidFinish = @"iPSX2BuiltInJITDidFinish";
static NSString* const kHelperFile = @"iPSX2JITHelper.appex";
static NSString* const kRequestKey = @"ipsx2-jit-request";
static NSString* const kResponseKey = @"ipsx2-jit-response";
static NSString* const kEnableAtLaunchKey = @"iPSX2BuiltInJITAtLaunch";
static NSString* const kErrorDomain = @"iPSX2BuiltInJIT";
// The first attempt also downloads Apple's Developer Disk Image, so allow plenty of time.
static const NSTimeInterval kAttachTimeout = 180;

#pragma mark - State

static BOOL s_busy = NO;
static NSString* s_status = nil;
static NSString* s_error = nil;
static iPSX2BuiltInJITProblem s_problem = iPSX2BuiltInJITProblemNoProblem;
static NSString* s_setupCheck = nil;
static BOOL s_launchAttemptDone = NO;
static NSDate* s_openedLocalDevVPNAt = nil;

// The running enable attempt.
static BOOL s_attempting = NO;
static BOOL s_attachHandled = NO;
static BOOL s_wasDebuggedAtStart = NO;
static BOOL s_helperPending = NO;
static NSTimer* s_attachTimer = nil;
static NSDate* s_attachDeadline = nil;

static void JITLog(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);
static void JITLog(NSString* format, ...)
{
    va_list args;
    va_start(args, format);
    NSString* line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    // stderr is pcsx2_log.txt in the Documents folder.
    fprintf(stderr, "@@JIT_BUILTIN@@ %s\n", line.UTF8String);
}

static void PostChange(void)
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kStatusDidChange object:nil];
}

static void PostFinished(BOOL success)
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kDidFinish
                                                        object:nil
                                                      userInfo:@{ @"success": @(success) }];
}

#pragma mark - Checks

static BOOL IsCSDebugged(void)
{
#if TARGET_OS_SIMULATOR
    return YES;
#else
    uint32_t flags = 0;
    return csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & 0x10000000u) != 0;
#endif
}

static BOOL JITIsOn(void)
{
    // Same rule as iPSX2Bridge.jitStatus: debugged, and the iOS 26+ handshake did not fail.
    return IsCSDebugged() && DarwinMisc::GetTXMRegistrationState() >= 0;
}

static NSString* HelperIdentifier(void)
{
    // Read from the helper itself: some signing apps change bundle identifiers.
    NSURL* plugIns = NSBundle.mainBundle.builtInPlugInsURL;
    if (!plugIns)
        return nil;
    NSBundle* helper = [NSBundle bundleWithURL:[plugIns URLByAppendingPathComponent:kHelperFile]];
    return helper.bundleIdentifier;
}

// 1 = get-task-allow present, 0 = explicitly false, -1 = can't tell.
static int GetTaskAllowState(void)
{
    static int s_state = -2;
    if (s_state != -2)
        return s_state;
    s_state = -1;
    typedef CFTypeRef (*CreateFromSelfFn)(CFAllocatorRef);
    typedef CFTypeRef (*CopyValueFn)(CFTypeRef, CFStringRef, CFErrorRef*);
    void* security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    CreateFromSelfFn createFromSelf = security ? (CreateFromSelfFn)dlsym(security, "SecTaskCreateFromSelf") : NULL;
    CopyValueFn copyValue = security ? (CopyValueFn)dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
    if (createFromSelf && copyValue)
    {
        CFTypeRef task = createFromSelf(kCFAllocatorDefault);
        if (task)
        {
            CFTypeRef value = copyValue(task, CFSTR("get-task-allow"), NULL);
            if (value == (CFTypeRef)kCFBooleanTrue)
                s_state = 1;
            else if (value == (CFTypeRef)kCFBooleanFalse)
                s_state = 0;
            if (value)
                CFRelease(value);
            CFRelease(task);
        }
    }
    return s_state;
}

static NSString* UnavailableReason(void)
{
#if TARGET_OS_SIMULATOR
    return @"Built-in JIT works only on a real iPhone or iPad.";
#else
    if (![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){ 17, 4, 0 }])
        return @"Built-in JIT needs iOS 17.4 or later. Open iPSX2 from StikDebug instead.";
    if (getenv("LC_HOME_PATH"))
        return @"Built-in JIT can't run inside LiveContainer. Open iPSX2 from StikDebug instead.";
    if (!HelperIdentifier())
        return @"This copy of iPSX2 doesn't include its JIT helper. The app or service that signed it may "
               @"have removed app extensions. Open iPSX2 from StikDebug instead.";
    if (GetTaskAllowState() == 0)
        return @"This copy of iPSX2 was signed without get-task-allow, so nothing can attach to it to turn "
               @"on JIT (StikDebug can't either). It needs to be signed with a development certificate.";
    return nil;
#endif
}

#pragma mark - Pairing file

static NSString* DocumentsPath(void)
{
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static NSString* PairingDirectory(void)
{
    return [DocumentsPath() stringByAppendingPathComponent:@"StikJIT"];
}

static NSString* PairingPath(void)
{
    return [PairingDirectory() stringByAppendingPathComponent:@"pairingFile.plist"];
}

// A remote pairing (RPPairing) file, the kind StikDebug and StikJIT use: an Ed25519 key pair
// and the host identifier the device paired with (see idevice's rp_pairing_file.rs).
static BOOL IsRemotePairingFile(NSData* data)
{
    if (data.length == 0)
        return NO;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![plist isKindOfClass:NSDictionary.class])
        return NO;
    NSDictionary* dict = (NSDictionary*)plist;
    id publicKey = dict[@"public_key"];
    id privateKey = dict[@"private_key"];
    id identifier = dict[@"identifier"];
    return [publicKey isKindOfClass:NSData.class] && ((NSData*)publicKey).length == 32 &&
           [privateKey isKindOfClass:NSData.class] && ((NSData*)privateKey).length == 32 &&
           [identifier isKindOfClass:NSString.class] && ((NSString*)identifier).length > 0;
}

static NSError* PairingError(NSString* message)
{
    return [NSError errorWithDomain:kErrorDomain code:10 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static BOOL StorePairing(NSData* data, NSError** error)
{
    if (!IsRemotePairingFile(data))
    {
        if (error)
            *error = PairingError(@"That file isn't a remote pairing file (it needs public_key, private_key and "
                                  @"identifier). Use the pairingFile.plist from StikDebug's folder in the Files app "
                                  @"(On My iPad › StikDebug), or make one with the StikDebug pairing-file guide.");
        return NO;
    }
    NSError* fsError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:PairingDirectory()
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&fsError] ||
        ![data writeToFile:PairingPath() options:NSDataWritingAtomic error:&fsError])
    {
        if (error)
            *error = fsError;
        return NO;
    }
    return YES;
}

static NSData* ReadPairingFile(void)
{
    NSData* data = [NSData dataWithContentsOfFile:PairingPath()];
    if (data && IsRemotePairingFile(data))
        return data;
    // Also accept a pairing file copied into iPSX2's own folder with the Files app.
    for (NSString* name in @[ @"pairingFile.plist", @"rp_pairing_file.plist" ])
    {
        NSString* loose = [DocumentsPath() stringByAppendingPathComponent:name];
        NSData* candidate = [NSData dataWithContentsOfFile:loose];
        if (candidate && IsRemotePairingFile(candidate) && StorePairing(candidate, NULL))
        {
            [[NSFileManager defaultManager] removeItemAtPath:loose error:NULL];
            JITLog(@"moved %@ from Documents into Documents/StikJIT", name);
            return candidate;
        }
    }
    return nil;
}

#pragma mark - Helper progress (Darwin notifications from the helper)

static NSString* ProgressPrefix(void)
{
    static NSString* s_prefix = nil;
    if (!s_prefix)
        s_prefix = [NSString stringWithFormat:@"%@.jit-progress.%d", NSBundle.mainBundle.bundleIdentifier ?: @"iPSX2", getpid()];
    return s_prefix;
}

static NSDictionary<NSString*, NSString*>* ProgressTexts(void)
{
    static NSDictionary<NSString*, NSString*>* s_texts = nil;
    if (!s_texts)
        s_texts = @{
            @"connecting": @"Connecting to this device through LocalDevVPN…",
            @"checking-ddi": @"Checking Apple's Developer Disk Image…",
            @"downloading-ddi": @"Downloading Apple's Developer Disk Image. This happens once and can take a minute…",
            @"mounting-ddi": @"Mounting the Developer Disk Image…",
            @"verifying-ddi": @"Checking the Developer Disk Image…",
            @"ready": @"Developer Disk Image ready.",
            @"attaching": @"Attaching to iPSX2…",
        };
    return s_texts;
}

static void ProgressCallback(CFNotificationCenterRef center, void* observer, CFNotificationName name, const void* object, CFDictionaryRef userInfo)
{
    (void)center; (void)observer; (void)object; (void)userInfo;
    NSString* full = (__bridge NSString*)name;
    NSString* prefix = ProgressPrefix();
    if (full.length <= prefix.length + 1)
        return;
    NSString* stage = [full substringFromIndex:prefix.length + 1];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* text = ProgressTexts()[stage];
        JITLog(@"helper: %@", stage);
        if (!text || !s_busy || s_attachHandled)
            return;
        s_status = text;
        PostChange();
    });
}

static void RegisterProgressObservers(void)
{
    static BOOL s_registered = NO;
    if (s_registered)
        return;
    s_registered = YES;
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    for (NSString* stage in ProgressTexts())
    {
        NSString* name = [NSString stringWithFormat:@"%@.%@", ProgressPrefix(), stage];
        CFNotificationCenterAddObserver(center, (__bridge const void*)ProgressPrefix(), ProgressCallback,
                                        (__bridge CFStringRef)name, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

#pragma mark - Talking to the helper (private NSExtension API)

@protocol iPSX2NSExtensionFactory <NSObject>
+ (id)extensionWithIdentifier:(NSString*)identifier error:(NSError**)error;
@end

@protocol iPSX2NSExtensionRequests <NSObject>
- (void)beginExtensionRequestWithInputItems:(NSArray*)inputItems completion:(void (^)(NSUUID* requestIdentifier))completion;
- (int)pidForRequestIdentifier:(NSUUID*)requestIdentifier;
- (void)setRequestCompletionBlock:(void (^)(NSUUID* requestIdentifier, NSArray* extensionItems))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID* requestIdentifier, NSError* error))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID* requestIdentifier))block;
@end

typedef void (^iPSX2HelperCompletion)(NSDictionary* _Nullable response, NSString* _Nullable failure);

/// One request to the helper, from its start to its one result.
@interface iPSX2JITHelperRequest : NSObject
@property (nonatomic, strong) id extension; // the NSExtension, kept alive for the request
@property (nonatomic, copy) NSString* operation;
@property (nonatomic, copy, nullable) iPSX2HelperCompletion completion;
@end

@implementation iPSX2JITHelperRequest
@end

static NSMutableArray<iPSX2JITHelperRequest*>* RunningRequests(void)
{
    static NSMutableArray<iPSX2JITHelperRequest*>* s_running = nil;
    if (!s_running)
        s_running = [NSMutableArray array];
    return s_running;
}

static void FinishHelperRequest(iPSX2JITHelperRequest* request, NSData* payload, NSString* failure)
{
    if (!request || !request.completion)
        return; // the first result counts
    iPSX2HelperCompletion completion = request.completion;
    request.completion = nil;
    [RunningRequests() removeObject:request];

    NSDictionary* response = nil;
    if (payload.length)
    {
        id json = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
        if ([json isKindOfClass:NSDictionary.class])
            response = json;
    }
    if (!response && !failure)
        failure = @"iPSX2's JIT helper finished without an answer.";
    completion(response, failure);
}

static void SendToHelper(NSDictionary* request, void (^started)(int pid), iPSX2HelperCompletion completion)
{
    NSString* identifier = HelperIdentifier();
    if (!identifier)
    {
        completion(nil, UnavailableReason() ?: @"iPSX2's JIT helper is missing from this installation.");
        return;
    }
    if (!NSClassFromString(@"NSExtension"))
        dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
    Class factory = NSClassFromString(@"NSExtension");
    if (!factory || ![factory respondsToSelector:@selector(extensionWithIdentifier:error:)])
    {
        completion(nil, @"iOS did not provide the app-extension API iPSX2's JIT helper needs. Open iPSX2 from StikDebug instead.");
        return;
    }

    NSError* error = nil;
    id extension = [(Class<iPSX2NSExtensionFactory>)factory extensionWithIdentifier:identifier error:&error];
    if (!extension)
    {
        completion(nil, [NSString stringWithFormat:@"iOS could not find iPSX2's JIT helper (%@): %@ "
                                                   @"Reinstall iPSX2, keeping its app extensions if your signing app asks.",
                                                   identifier, error.localizedDescription ?: @"unknown error."]);
        return;
    }
    NSData* json = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
    if (!json)
    {
        completion(nil, @"The request for iPSX2's JIT helper could not be encoded.");
        return;
    }

    iPSX2JITHelperRequest* holder = [iPSX2JITHelperRequest new];
    holder.extension = extension;
    holder.operation = request[@"operation"];
    holder.completion = completion;
    [RunningRequests() addObject:holder];

    __weak iPSX2JITHelperRequest* weakHolder = holder;
    id<iPSX2NSExtensionRequests> requests = (id<iPSX2NSExtensionRequests>)extension;
    // These blocks can arrive on any queue.
    [requests setRequestCompletionBlock:^(NSUUID* requestIdentifier, NSArray* extensionItems) {
        (void)requestIdentifier;
        NSData* payload = nil;
        id item = extensionItems.firstObject;
        if ([item isKindOfClass:NSExtensionItem.class])
        {
            id value = ((NSExtensionItem*)item).userInfo[kResponseKey];
            if ([value isKindOfClass:NSData.class])
                payload = value;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            FinishHelperRequest(weakHolder, payload, nil);
        });
    }];
    [requests setRequestCancellationBlock:^(NSUUID* requestIdentifier, NSError* cancelError) {
        (void)requestIdentifier;
        NSString* message = cancelError.localizedDescription ?: @"the request was cancelled.";
        dispatch_async(dispatch_get_main_queue(), ^{
            FinishHelperRequest(weakHolder, nil, [@"iPSX2's JIT helper stopped: " stringByAppendingString:message]);
        });
    }];
    [requests setRequestInterruptionBlock:^(NSUUID* requestIdentifier) {
        (void)requestIdentifier;
        dispatch_async(dispatch_get_main_queue(), ^{
            FinishHelperRequest(weakHolder, nil, @"iPSX2's JIT helper stopped unexpectedly. Try again.");
        });
    }];

    NSExtensionItem* item = [NSExtensionItem new];
    item.userInfo = @{ kRequestKey: json };
    NSString* operation = holder.operation;
    [requests beginExtensionRequestWithInputItems:@[ item ] completion:^(NSUUID* requestIdentifier) {
        dispatch_async(dispatch_get_main_queue(), ^{
            iPSX2JITHelperRequest* strongHolder = weakHolder;
            if (!strongHolder || !strongHolder.completion)
                return;
            if (!requestIdentifier)
            {
                FinishHelperRequest(strongHolder, nil, @"iPSX2's JIT helper did not start. Reinstall iPSX2, keeping its "
                                                       @"app extensions if your signing app asks, or open iPSX2 from StikDebug.");
                return;
            }
            const int pid = [(id<iPSX2NSExtensionRequests>)strongHolder.extension pidForRequestIdentifier:requestIdentifier];
            JITLog(@"%@: started %@ as pid %d", operation, identifier, pid);
            if (started)
                started(pid);
        });
    }];
}

#pragma mark - Results

static iPSX2BuiltInJITProblem ProblemForMessage(NSString* message)
{
    NSString* text = message.lowercaseString ?: @"";
    for (NSString* needle in @[ @"connectionreset", @"connection reset", @"reset by peer", @"device refused connection" ])
        if ([text containsString:needle])
            return iPSX2BuiltInJITProblemPairingRejected;
    for (NSString* needle in @[ @"connectionrefused", @"connection refused", @"timedout", @"timed out", @"networkunreachable",
                                @"network unreachable", @"network is unreachable", @"hostunreachable", @"host unreachable",
                                @"no route", @"could not connect", @"couldn't connect" ])
        if ([text containsString:needle])
            return iPSX2BuiltInJITProblemNotConnected;
    return iPSX2BuiltInJITProblemOther;
}

static NSString* FailureText(NSString* message, iPSX2BuiltInJITProblem problem)
{
    switch (problem)
    {
        case iPSX2BuiltInJITProblemNotConnected:
            return [NSString stringWithFormat:@"iPSX2 couldn't reach this device. Turn on LocalDevVPN, then try again.\n(%@)", message];
        case iPSX2BuiltInJITProblemPairingRejected:
            return [NSString stringWithFormat:@"This device closed the connection, which usually means it no longer accepts this "
                                              @"pairing file. Import the pairing file StikDebug uses now, check LocalDevVPN, then "
                                              @"try again.\n(%@)", message];
        default:
            return message;
    }
}

static void LogHelperResponse(NSDictionary* response, NSString* failure)
{
    if (failure)
        JITLog(@"helper failed: %@", failure);
    if (!response)
        return;
    JITLog(@"helper %@: %@ (txm=%@)", [response[@"success"] boolValue] ? @"succeeded" : @"failed", response[@"message"],
        response[@"txmPresent"] ?: @"unknown");
    id lines = response[@"log"];
    if ([lines isKindOfClass:NSArray.class])
        for (id line in (NSArray*)lines)
            if ([line isKindOfClass:NSString.class])
                JITLog(@"  helper log: %@", line);
}

static NSString* RestartText(void)
{
    return @"A game already started without JIT since iPSX2 was opened. Close iPSX2 completely (swipe it away in the "
           @"app switcher), open it again, and turn on JIT before starting a game.";
}

static void Fail(NSString* message, iPSX2BuiltInJITProblem problem)
{
    s_status = nil;
    s_error = message;
    s_problem = problem;
    JITLog(@"not enabling: %@", message);
    PostChange();
    PostFinished(NO);
}

static void StopAttachTimer(void)
{
    [s_attachTimer invalidate];
    s_attachTimer = nil;
}

static void FinishAttempt(BOOL success, NSString* error, iPSX2BuiltInJITProblem problem)
{
    if (!s_attempting)
        return;
    s_attempting = NO;
    s_busy = NO;
    StopAttachTimer();
    if (success)
    {
        s_status = @"JIT is on.";
        s_error = nil;
        s_problem = iPSX2BuiltInJITProblemNoProblem;
        JITLog(@"JIT is on");
    }
    else
    {
        s_status = nil;
        s_error = error;
        s_problem = problem;
        JITLog(@"attempt failed: %@", error);
    }
    PostChange();
    PostFinished(success);
}

static void CheckAttach(BOOL helperFinished)
{
    if (!s_attempting || s_attachHandled)
        return;

    // legacy.js stays attached while it waits for iPSX2's brk #0x69 (P_TRACED). Where TXM is
    // absent StikJIT only attaches and detaches, which leaves CS_DEBUGGED behind.
    const bool traced = DarwinMisc::IsDebuggerAttached();
    const BOOL debugged = IsCSDebugged();
    const BOOL attached = traced || (debugged && (!s_wasDebuggedAtStart || helperFinished));
    if (!attached)
    {
        if (helperFinished)
            FinishAttempt(NO, @"iPSX2's JIT helper finished, but iPSX2 was not attached to. Try again.", iPSX2BuiltInJITProblemOther);
        else if (s_attachDeadline && [s_attachDeadline timeIntervalSinceNow] < 0)
            FinishAttempt(NO, @"iPSX2's JIT helper did not attach within 3 minutes. Check that LocalDevVPN is connected, then try again.",
                          iPSX2BuiltInJITProblemNotConnected);
        return;
    }

    s_attachHandled = YES;
    StopAttachTimer();
    s_status = @"Setting up JIT memory…";
    PostChange();
    JITLog(@"attach noticed (traced=%d debugged=%d helperFinished=%d)", traced ? 1 : 0, debugged ? 1 : 0, helperFinished ? 1 : 0);

    const int result = iPSX2_ActivateBuiltInJIT();
    // When no handshake happened, a script that is still attached waits for one; release it
    // before a game can start (an attached script would swallow the signals fastmem uses).
    const bool releaseScript = result != 1 && s_helperPending && DarwinMisc::IsDebuggerAttached();
    if (result >= 0)
    {
        if (releaseScript)
            DarwinMisc::ReleaseWaitingJITScript();
        FinishAttempt(YES, nil, iPSX2BuiltInJITProblemNoProblem);
    }
    else if (result == -2)
    {
        if (releaseScript)
            DarwinMisc::ReleaseWaitingJITScript();
        FinishAttempt(NO, RestartText(), iPSX2BuiltInJITProblemRestartNeeded);
    }
    else
    {
        FinishAttempt(NO, @"iPSX2's JIT helper attached, but its script did not answer iPSX2's JIT memory request. Try again; "
                          @"if it keeps failing, open iPSX2 from StikDebug with legacy.js instead.",
                      iPSX2BuiltInJITProblemOther);
    }
}

static BOOL ShouldForceScript(void)
{
    // iPSX2 does the brk #0x69 handshake on iOS 26 and later (DarwinMisc::DetectJitMode), so
    // legacy.js must run there even if StikJIT can't tell whether TXM is present. Where it turns
    // out not to be needed, the waiting script is released (DarwinMisc::ReleaseWaitingJITScript).
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26;
}

#pragma mark - iPSX2BuiltInJIT

@implementation iPSX2BuiltInJIT

+ (NSString*)unavailableReason { return UnavailableReason(); }
+ (BOOL)hasPairingFile { return ReadPairingFile() != nil; }
+ (BOOL)isJITOn { return JITIsOn(); }
+ (BOOL)isBusy { return s_busy; }
+ (NSString*)statusText { return s_status; }
+ (NSString*)errorText { return s_error; }
+ (iPSX2BuiltInJITProblem)problem { return s_problem; }
+ (NSString*)setupCheckText { return s_setupCheck; }

+ (BOOL)enableAtLaunch
{
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kEnableAtLaunchKey];
    return value ? [value boolValue] : YES;
}

+ (void)setEnableAtLaunch:(BOOL)enableAtLaunch
{
    [[NSUserDefaults standardUserDefaults] setBool:enableAtLaunch forKey:kEnableAtLaunchKey];
    PostChange();
}

+ (BOOL)importPairingFileFromURL:(NSURL*)url error:(NSError**)error
{
    const BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError* readError = nil;
    NSData* data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    if (scoped)
        [url stopAccessingSecurityScopedResource];
    if (!data)
    {
        if (error)
            *error = readError ?: PairingError(@"That file could not be read.");
        return NO;
    }
    if (!StorePairing(data, error))
        return NO;
    JITLog(@"pairing file imported");
    s_setupCheck = nil;
    if (s_problem == iPSX2BuiltInJITProblemNoPairingFile || s_problem == iPSX2BuiltInJITProblemPairingRejected)
    {
        s_problem = iPSX2BuiltInJITProblemNoProblem;
        s_error = nil;
    }
    PostChange();
    return YES;
}

+ (void)removePairingFile
{
    [[NSFileManager defaultManager] removeItemAtPath:PairingPath() error:NULL];
    s_setupCheck = nil;
    JITLog(@"pairing file removed");
    PostChange();
}

+ (void)enable
{
    if (s_busy)
        return;
    if (JITIsOn())
    {
        s_status = @"JIT is on.";
        s_error = nil;
        s_problem = iPSX2BuiltInJITProblemNoProblem;
        PostChange();
        PostFinished(YES);
        return;
    }
    if (NSString* reason = UnavailableReason())
    {
        Fail(reason, iPSX2BuiltInJITProblemUnavailable);
        return;
    }
    if (iPSX2_VMThreadWasCreated())
    {
        Fail(RestartText(), iPSX2BuiltInJITProblemRestartNeeded);
        return;
    }
    NSData* pairing = ReadPairingFile();
    if (!pairing)
    {
        Fail(@"Import your pairing file first: the pairingFile.plist from StikDebug's folder in the Files app "
             @"(On My iPad › StikDebug).", iPSX2BuiltInJITProblemNoPairingFile);
        return;
    }

    s_busy = YES;
    s_attempting = YES;
    s_attachHandled = NO;
    s_helperPending = YES;
    s_wasDebuggedAtStart = IsCSDebugged();
    s_status = @"Starting iPSX2's JIT helper…";
    s_error = nil;
    s_problem = iPSX2BuiltInJITProblemNoProblem;
    PostChange();
    RegisterProgressObservers();

    const BOOL forceScript = ShouldForceScript();
    JITLog(@"enable: pid=%d debuggedAtStart=%d forceScript=%d get-task-allow=%d", getpid(), s_wasDebuggedAtStart ? 1 : 0,
        forceScript ? 1 : 0, GetTaskAllowState());

    // Poll from the start: the attach is what matters, not when the helper's process starts.
    s_attachDeadline = [NSDate dateWithTimeIntervalSinceNow:kAttachTimeout];
    StopAttachTimer();
    s_attachTimer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer* timer) {
        (void)timer;
        CheckAttach(NO);
    }];
    [[NSRunLoop mainRunLoop] addTimer:s_attachTimer forMode:NSRunLoopCommonModes];

    NSDictionary* request = @{
        @"operation": @"enable",
        @"targetPID": @(getpid()),
        @"pairingData": [pairing base64EncodedStringWithOptions:0],
        @"forceScript": @(forceScript),
        @"progressName": ProgressPrefix(),
    };
    SendToHelper(request, ^(int pid) {
        (void)pid;
        if (s_attempting && !s_attachHandled)
        {
            s_status = @"Waiting for iPSX2's JIT helper to attach…";
            PostChange();
        }
    }, ^(NSDictionary* response, NSString* failure) {
        s_helperPending = NO;
        LogHelperResponse(response, failure);
        NSString* message = failure ?: ([response[@"message"] isKindOfClass:NSString.class] ? response[@"message"] : @"Unknown error.");
        const BOOL ok = failure == nil && [response[@"success"] boolValue];
        if (!s_attempting)
            return; // the attempt already ended; this is the helper detaching (or a late error, logged above)
        if (!ok)
        {
            const iPSX2BuiltInJITProblem problem = ProblemForMessage(message);
            FinishAttempt(NO, FailureText(message, problem), problem);
            return;
        }
        // Finished before the attach was noticed: StikJIT attached and detached (no TXM).
        CheckAttach(YES);
    });
}

+ (void)checkSetup
{
    if (s_busy)
        return;
    if (NSString* reason = UnavailableReason())
    {
        s_setupCheck = reason;
        PostChange();
        return;
    }
    NSData* pairing = ReadPairingFile();
    if (!pairing)
    {
        s_setupCheck = @"Import your pairing file first.";
        PostChange();
        return;
    }
    s_busy = YES;
    s_status = @"Checking LocalDevVPN and the Developer Disk Image…";
    s_setupCheck = nil;
    PostChange();
    RegisterProgressObservers();
    NSDictionary* request = @{
        @"operation": @"prepare",
        @"pairingData": [pairing base64EncodedStringWithOptions:0],
        @"progressName": ProgressPrefix(),
    };
    SendToHelper(request, nil, ^(NSDictionary* response, NSString* failure) {
        LogHelperResponse(response, failure);
        s_busy = NO;
        s_status = nil;
        NSString* message = failure ?: ([response[@"message"] isKindOfClass:NSString.class] ? response[@"message"] : @"Unknown error.");
        if (failure == nil && [response[@"success"] boolValue])
        {
            s_setupCheck = [@"Ready. " stringByAppendingString:message];
            if (s_problem != iPSX2BuiltInJITProblemRestartNeeded)
            {
                s_problem = iPSX2BuiltInJITProblemNoProblem;
                s_error = nil;
            }
        }
        else
        {
            s_setupCheck = FailureText(message, ProblemForMessage(message));
        }
        PostChange();
    });
}

+ (void)resetDeveloperDiskImage
{
    if (s_busy || UnavailableReason())
        return;
    s_busy = YES;
    s_status = @"Resetting the Developer Disk Image…";
    PostChange();
    SendToHelper(@{ @"operation": @"resetDDI" }, nil, ^(NSDictionary* response, NSString* failure) {
        LogHelperResponse(response, failure);
        s_busy = NO;
        s_status = nil;
        s_setupCheck = failure ?: ([response[@"message"] isKindOfClass:NSString.class] ? response[@"message"] : nil);
        PostChange();
    });
}

+ (BOOL)isLocalDevVPNInstalled
{
    return [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"localdevvpn://"]];
}

+ (void)openLocalDevVPN
{
    s_openedLocalDevVPNAt = [NSDate date];
    // "scheme" makes LocalDevVPN come back to iPSX2 (ipsx2://) once it is connected.
    NSURL* url = self.isLocalDevVPNInstalled ? [NSURL URLWithString:@"localdevvpn://enable?scheme=ipsx2"]
                                             : [NSURL URLWithString:@"https://apps.apple.com/us/app/localdevvpn/id6755608044"];
    JITLog(@"opening %@", url.absoluteString);
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

+ (void)applicationDidBecomeActive
{
    if (!s_launchAttemptDone)
    {
        s_launchAttemptDone = YES;
        if (self.enableAtLaunch && !JITIsOn() && !UnavailableReason() && !iPSX2_VMThreadWasCreated() && ReadPairingFile())
        {
            JITLog(@"turning JIT on at launch");
            [self enable];
            return;
        }
        PostChange();
        return;
    }
    // Back from LocalDevVPN: try again straight away.
    if (s_openedLocalDevVPNAt && -[s_openedLocalDevVPNAt timeIntervalSinceNow] < 300)
    {
        s_openedLocalDevVPNAt = nil;
        if (!s_busy && !JITIsOn() && !UnavailableReason() && !iPSX2_VMThreadWasCreated() && ReadPairingFile())
        {
            JITLog(@"back from LocalDevVPN: trying again");
            [self enable];
            return;
        }
    }
    PostChange();
}

+ (void)enableWithProgressFrom:(UIViewController*)presenter completion:(void (^)(BOOL jitOn, BOOL cancelled))completion
{
    if (!s_busy)
        [self enable];
    if (!s_busy)
    {
        completion(JITIsOn(), NO);
        return;
    }

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Turning On JIT…"
                                                                   message:s_status ?: @""
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __block id statusObserver = nil;
    __block id finishObserver = nil;
    __block BOOL done = NO;         // finished or cancelled
    __block BOOL presented = NO;    // the alert is on screen
    __block BOOL finishedSuccess = NO;
    void (^removeObservers)(void) = ^{
        if (statusObserver)
            [[NSNotificationCenter defaultCenter] removeObserver:statusObserver];
        if (finishObserver)
            [[NSNotificationCenter defaultCenter] removeObserver:finishObserver];
        statusObserver = nil;
        finishObserver = nil;
    };
    __weak UIAlertController* weakAlert = alert;
    // Dismiss, then report. Before the alert is on screen, the presentation completion does it.
    void (^dismissAndReport)(void) = ^{
        UIAlertController* shown = weakAlert;
        if (shown.presentingViewController)
            [shown dismissViewControllerAnimated:YES completion:^{ completion(finishedSuccess, NO); }];
        else
            completion(finishedSuccess, NO);
    };
    statusObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kStatusDidChange
                                                                       object:nil
                                                                        queue:NSOperationQueue.mainQueue
                                                                   usingBlock:^(NSNotification* note) {
        (void)note;
        if (s_status.length)
            weakAlert.message = s_status;
    }];
    finishObserver = [[NSNotificationCenter defaultCenter] addObserverForName:kDidFinish
                                                                       object:nil
                                                                        queue:NSOperationQueue.mainQueue
                                                                   usingBlock:^(NSNotification* note) {
        if (done)
            return;
        done = YES;
        removeObservers();
        finishedSuccess = [note.userInfo[@"success"] boolValue];
        if (presented)
            dismissAndReport();
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction* action) {
        (void)action;
        if (done)
            return;
        done = YES;
        removeObservers();
        completion(NO, YES);
    }]];
    [presenter presentViewController:alert animated:YES completion:^{
        presented = YES;
        // Cancel can't be tapped before this point, so `done` means the attempt ended while
        // the alert was still appearing.
        if (done)
            dismissAndReport();
    }];
}

@end
