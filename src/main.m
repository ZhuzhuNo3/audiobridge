#import <CoreAudio/CoreAudio.h>
#import <errno.h>
#import <Foundation/Foundation.h>
#import <getopt.h>
#import <signal.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#import "ABDeviceQuery.h"
#import "ABDeviceRecoveryCoordinator.h"
#import "ABPassThroughEngine.h"
#import "ABStdoutPCMWriter.h"
#import "ABSystemDefaultIO.h"

static volatile sig_atomic_t g_stop = 0;

static ABSystemDefaultIO *g_streamingSystemIO = nil;
static ABPassThroughEngine *g_streamingPassEngine = nil;
static ABStdoutPCMWriter *g_streamingPCMWriter = nil;

@interface ABRecoveryRuntimeContext : NSObject
@property(nonatomic, assign) BOOL active;
@property(nonatomic, copy) NSString *triggerSource;
@property(nonatomic, assign) NSUInteger attemptBase;
@property(nonatomic, assign) NSUInteger retryDelayCount;
@property(nonatomic, assign) NSTimeInterval lastDelaySeconds;
@end

@implementation ABRecoveryRuntimeContext
@end

@interface ABIntegrationFakeRecoveryEndpoint : NSObject <ABDeviceRecoveryEndpoint>
@property(nonatomic, strong) NSMutableArray<NSNumber *> *rebuildOutcomes;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, assign) NSUInteger recoveryRebuildAttemptCount;
@property(nonatomic, copy, nullable) void (^onRebuild)(void);
@end

@implementation ABIntegrationFakeRecoveryEndpoint

- (instancetype)init {
    self = [super init];
    if (self) {
        _rebuildOutcomes = [[NSMutableArray alloc] init];
        _active = NO;
        _recoveryRebuildAttemptCount = 0;
    }
    return self;
}

- (BOOL)ab_start:(NSError **)error {
    (void)error;
    self.active = YES;
    return YES;
}

- (BOOL)ab_rebuild:(NSError **)error {
    self.recoveryRebuildAttemptCount += 1;
    if (self.onRebuild != nil) {
        self.onRebuild();
    }
    BOOL shouldSucceed = YES;
    if (self.rebuildOutcomes.count > 0) {
        shouldSucceed = [self.rebuildOutcomes.firstObject boolValue];
        [self.rebuildOutcomes removeObjectAtIndex:0];
    }
    if (!shouldSucceed && error != NULL) {
        *error = [NSError errorWithDomain:@"ABIntegrationFakeRecoveryEndpoint"
                                     code:1
                                 userInfo:@{
                                     NSLocalizedDescriptionKey : @"simulated rebuild failure",
                                 }];
    }
    self.active = shouldSucceed;
    return shouldSucceed;
}

- (void)ab_stop {
    self.active = NO;
}

- (BOOL)ab_isActive {
    return self.active;
}

@end

static NSUInteger ABRuntimeRebuildAttemptCountForEndpoint(id endpoint) {
    if ([endpoint respondsToSelector:@selector(recoveryRebuildAttemptCount)]) {
        return (NSUInteger)[endpoint recoveryRebuildAttemptCount];
    }
    return 0;
}

static BOOL ABRunSharedRecoveryPipeline(ABDeviceRecoveryCoordinator *coordinator,
                                        id<ABDeviceRecoveryEndpoint> endpoint,
                                        ABRecoveryRuntimeContext *runtimeContext,
                                        NSString *triggerSource,
                                        NSError **error) {
    runtimeContext.active = YES;
    runtimeContext.triggerSource = triggerSource;
    runtimeContext.retryDelayCount = 0;
    runtimeContext.lastDelaySeconds = 0;
    runtimeContext.attemptBase = ABRuntimeRebuildAttemptCountForEndpoint(endpoint);

    const char *sourceUTF8 = triggerSource.UTF8String;
    fprintf(stderr, "[audiobridge] recovery: trigger_source=%s state=begin\n",
            sourceUTF8 != NULL ? sourceUTF8 : "unknown");

    ABDeviceRecoveryResult result = [coordinator recoverAfterUnexpectedStopWithResult:error];
    NSUInteger attempts = ABRuntimeRebuildAttemptCountForEndpoint(endpoint) - runtimeContext.attemptBase;
    if (attempts == 0) {
        attempts = 1;
    }

    if (result == ABDeviceRecoveryResultRecovered) {
        fprintf(stderr,
                "[audiobridge] recovery: trigger_source=%s state=streaming_restored attempt=%lu delay_count=%lu\n",
                sourceUTF8 != NULL ? sourceUTF8 : "unknown",
                (unsigned long)attempts,
                (unsigned long)runtimeContext.retryDelayCount);
    } else if (result == ABDeviceRecoveryResultCoalescedInFlight) {
        fprintf(stderr,
                "[audiobridge] recovery: trigger_source=%s state=coalesced_inflight attempt=%lu delay_count=%lu failure_summary=recovery already in flight\n",
                sourceUTF8 != NULL ? sourceUTF8 : "unknown",
                (unsigned long)attempts,
                (unsigned long)runtimeContext.retryDelayCount);
    } else if (result == ABDeviceRecoveryResultCompensationDisabled) {
        fprintf(stderr,
                "[audiobridge] recovery: trigger_source=%s state=failed attempt=%lu delay_count=%lu failure_summary=compensation disabled\n",
                sourceUTF8 != NULL ? sourceUTF8 : "unknown",
                (unsigned long)attempts,
                (unsigned long)runtimeContext.retryDelayCount);
    } else {
        NSString *summary = error != NULL && *error != nil ? (*error).localizedDescription : @"rebuild failed";
        const char *summaryUTF8 = summary.UTF8String;
        fprintf(stderr,
                "[audiobridge] recovery: trigger_source=%s state=failed attempt=%lu delay_count=%lu failure_summary=%s\n",
                sourceUTF8 != NULL ? sourceUTF8 : "unknown",
                (unsigned long)attempts,
                (unsigned long)runtimeContext.retryDelayCount,
                summaryUTF8 != NULL ? summaryUTF8 : "unknown");
    }

    runtimeContext.active = NO;
    return result == ABDeviceRecoveryResultRecovered;
}

static int ABRunIntegrationRecoveryLifecycleScenario(void) {
    ABIntegrationFakeRecoveryEndpoint *successEndpoint = [[ABIntegrationFakeRecoveryEndpoint alloc] init];
    [successEndpoint.rebuildOutcomes addObjectsFromArray:@[ @NO, @YES ]];
    ABRecoveryRuntimeContext *successContext = [[ABRecoveryRuntimeContext alloc] init];
    ABDeviceRecoveryCoordinator *successCoordinator =
        [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:successEndpoint
                                                 sleepHandler:^(NSTimeInterval delaySeconds) {
                                                     if (successContext.active) {
                                                         successContext.retryDelayCount += 1;
                                                         successContext.lastDelaySeconds = delaySeconds;
                                                         const char *sourceUTF8 = successContext.triggerSource.UTF8String;
                                                         fprintf(stderr,
                                                                 "[audiobridge] recovery: trigger_source=%s attempt=%lu delay_seconds=%.1f state=retry_wait\n",
                                                                 sourceUTF8 != NULL ? sourceUTF8 : "unknown",
                                                                 (unsigned long)(successContext.retryDelayCount + 1),
                                                                 delaySeconds);
                                                     }
                                                 }];

    NSError *error = nil;
    if (![successCoordinator startWithError:&error]) {
        return 1;
    }
    __block ABDeviceRecoveryCoordinator *successCoordinatorBlock = successCoordinator;
    __block ABIntegrationFakeRecoveryEndpoint *successEndpointBlock = successEndpoint;
    __block ABRecoveryRuntimeContext *probeContext = [[ABRecoveryRuntimeContext alloc] init];
    __block BOOL injectedCoalescedProbe = NO;
    successEndpoint.onRebuild = ^{
        if (injectedCoalescedProbe) {
            return;
        }
        injectedCoalescedProbe = YES;
        NSError *nestedError = nil;
        (void)ABRunSharedRecoveryPipeline(successCoordinatorBlock, successEndpointBlock, probeContext,
                                          @"listener_coalesced_probe", &nestedError);
    };
    if (!ABRunSharedRecoveryPipeline(successCoordinator, successEndpoint, successContext,
                                     @"listener_default_change", &error)) {
        return 1;
    }

    ABIntegrationFakeRecoveryEndpoint *failureEndpoint = [[ABIntegrationFakeRecoveryEndpoint alloc] init];
    ABRecoveryRuntimeContext *failureContext = [[ABRecoveryRuntimeContext alloc] init];
    ABDeviceRecoveryCoordinator *failureCoordinator =
        [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:failureEndpoint
                                                 sleepHandler:^(NSTimeInterval delaySeconds) {
                                                     (void)delaySeconds;
                                                 }];
    error = nil;
    (void)ABRunSharedRecoveryPipeline(failureCoordinator, failureEndpoint, failureContext, @"heartbeat_inactive",
                                      &error);
    return 0;
}

static void ABStreamingArmShutdownContext(ABSystemDefaultIO *systemIO, ABPassThroughEngine *passEngine,
                                          ABStdoutPCMWriter *pcmWriter) {
    g_streamingSystemIO = systemIO;
    g_streamingPassEngine = passEngine;
    g_streamingPCMWriter = pcmWriter;
}

// Registered while streaming so tap/audio error paths (e.g. ABStdoutPCMWriter) can tear down on the main queue.
// Must only be called from the main thread.
void ABShutdownStreaming(void) {
    ABSystemDefaultIO *io = g_streamingSystemIO;
    ABPassThroughEngine *pass = g_streamingPassEngine;
    ABStdoutPCMWriter *pcm = g_streamingPCMWriter;
    g_streamingSystemIO = nil;
    g_streamingPassEngine = nil;
    g_streamingPCMWriter = nil;

    if (io != nil) {
        [io removeAllListeners];
    }
    if (pass != nil) {
        [pass stop];
    }
    if (pcm != nil) {
        [pcm stop];
    }
    if (io != nil) {
        [io restoreAll];
    }
}

static void ABStreamingHandleSignal(int sig) {
    (void)sig;
    g_stop = 1;
}

static BOOL ABStringContainsBuiltInNameHeuristic(NSString *string) {
    if (string.length == 0) {
        return NO;
    }
    return [string rangeOfString:@"Built-in" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

/// Speaker path only: warns once before the first engine start when both device names look like built-in I/O.
static void ABSpeakerMaybeWarnBuiltInFeedback(ABDeviceQuery *query, BOOL inputPinned, UInt32 resolvedInputID,
                                              BOOL outputPinned, UInt32 resolvedOutputID, BOOL quiet) {
    if (quiet) {
        return;
    }

    NSString *inputName = nil;
    NSString *outputName = nil;

    if (inputPinned) {
        BOOL foundListed = NO;
        for (ABListedDevice *device in query.inputCapableDevices) {
            if (device.deviceID == resolvedInputID) {
                inputName = device.name;
                foundListed = YES;
                break;
            }
        }
        if (!foundListed) {
            inputName = [ABDeviceQuery deviceNameForAudioDeviceID:resolvedInputID];
        }
    } else {
        AudioDeviceID defaultInput = kAudioObjectUnknown;
        NSError *readError = nil;
        if ([ABSystemDefaultIO readDefaultInput:&defaultInput error:&readError]) {
            inputName = [ABDeviceQuery deviceNameForAudioDeviceID:defaultInput];
        }
    }

    if (outputPinned) {
        BOOL foundListed = NO;
        for (ABListedDevice *device in query.outputCapableDevices) {
            if (device.deviceID == resolvedOutputID) {
                outputName = device.name;
                foundListed = YES;
                break;
            }
        }
        if (!foundListed) {
            outputName = [ABDeviceQuery deviceNameForAudioDeviceID:resolvedOutputID];
        }
    } else {
        AudioDeviceID defaultOutput = kAudioObjectUnknown;
        NSError *readError = nil;
        if ([ABSystemDefaultIO readDefaultOutput:&defaultOutput error:&readError]) {
            outputName = [ABDeviceQuery deviceNameForAudioDeviceID:defaultOutput];
        }
    }

    if (inputName.length == 0 || outputName.length == 0) {
        return;
    }
    if (!ABStringContainsBuiltInNameHeuristic(inputName) || !ABStringContainsBuiltInNameHeuristic(outputName)) {
        return;
    }

    fprintf(stderr,
            "[audiobridge] warning: built-in input and output are selected; acoustic feedback is possible — use "
            "headphones or lower monitoring volume.\n");
}

/// Speaker streaming path: `quiet` suppresses routine stderr from the engine and the built-in feedback heuristic.
static int ABRunSpeakerStreaming(ABDeviceQuery *query, NSString *optInput, NSString *optOutput, UInt32 resolvedInputID,
                                 UInt32 resolvedOutputID, BOOL quiet) {
    BOOL floatingInput = (optInput == nil);
    BOOL floatingOutput = (optOutput == nil);
    BOOL inputPinned = !floatingInput;
    BOOL outputPinned = !floatingOutput;

    ABSystemDefaultIO *systemIO = [[ABSystemDefaultIO alloc] init];
    if (optInput != nil) {
        NSError *pinError = nil;
        if (![systemIO saveAndSetInput:resolvedInputID error:&pinError]) {
            NSString *message = pinError.localizedDescription ?: @"Could not set default input device.";
            const char *utf8 = message.UTF8String;
            fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "Could not set default input device.");
            return 1;
        }
    }
    if (optOutput != nil) {
        NSError *pinError = nil;
        if (![systemIO saveAndSetOutput:resolvedOutputID error:&pinError]) {
            NSString *message = pinError.localizedDescription ?: @"Could not set default output device.";
            const char *utf8 = message.UTF8String;
            fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "Could not set default output device.");
            [systemIO restoreAll];
            return 1;
        }
    }

    ABPassThroughEngine *passEngine = [[ABPassThroughEngine alloc] init];
    [passEngine configureRecoveryWithQuiet:quiet];
    ABRecoveryRuntimeContext *runtimeContext = [[ABRecoveryRuntimeContext alloc] init];
    ABDeviceRecoveryCoordinator *coordinator =
        [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:passEngine
                                                 sleepHandler:^(NSTimeInterval delaySeconds) {
                                                     if (runtimeContext.active) {
                                                         runtimeContext.retryDelayCount += 1;
                                                         runtimeContext.lastDelaySeconds = delaySeconds;
                                                         const char *sourceUTF8 = runtimeContext.triggerSource.UTF8String;
                                                         fprintf(stderr,
                                                                 "[audiobridge] recovery: trigger_source=%s attempt=%lu delay_seconds=%.1f state=retry_wait\n",
                                                                 sourceUTF8 != NULL ? sourceUTF8 : "unknown",
                                                                 (unsigned long)(runtimeContext.retryDelayCount + 1),
                                                                 delaySeconds);
                                                     }
                                                     [NSThread sleepForTimeInterval:delaySeconds];
                                                 }];
    ABStreamingArmShutdownContext(systemIO, passEngine, nil);

    __block BOOL heartbeatPaused = NO;
    __block ABDeviceRecoveryCoordinator *coordinatorBlock = coordinator;
    __block ABPassThroughEngine *passEngineBlock = passEngine;
    __block ABRecoveryRuntimeContext *runtimeContextBlock = runtimeContext;

    [systemIO registerForFloatingInput:floatingInput
                      floatingOutput:floatingOutput
                        rebuildBlock:^{
                            heartbeatPaused = YES;
                            NSError *recoveryError = nil;
                            (void)ABRunSharedRecoveryPipeline(coordinatorBlock, passEngineBlock, runtimeContextBlock,
                                                              @"listener_default_change", &recoveryError);
                            heartbeatPaused = NO;
                        }];

    ABSpeakerMaybeWarnBuiltInFeedback(query, inputPinned, resolvedInputID, outputPinned, resolvedOutputID, quiet);

    NSError *startError = nil;
    if (![coordinator startWithError:&startError]) {
        NSString *message = startError.localizedDescription ?: @"Engine start failed.";
        const char *utf8 = message.UTF8String;
        fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "Engine start failed.");
        ABShutdownStreaming();
        return 1;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = ABStreamingHandleSignal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    NSTimer *wakeTimer = [NSTimer timerWithTimeInterval:0.2
                                                repeats:YES
                                                  block:^(__unused NSTimer *timer) {
                                                  }];
    [[NSRunLoop mainRunLoop] addTimer:wakeTimer forMode:NSRunLoopCommonModes];
    NSTimer *heartbeatTimer = [NSTimer timerWithTimeInterval:0.5
                                                     repeats:YES
                                                       block:^(__unused NSTimer *timer) {
                                                           if (heartbeatPaused) {
                                                               return;
                                                           }
                                                           if (![passEngineBlock ab_isActive]) {
                                                               NSError *recoveryError = nil;
                                                               (void)ABRunSharedRecoveryPipeline(
                                                                   coordinatorBlock, passEngineBlock,
                                                                   runtimeContextBlock, @"heartbeat_inactive",
                                                                   &recoveryError);
                                                           }
                                                       }];
    [[NSRunLoop mainRunLoop] addTimer:heartbeatTimer forMode:NSRunLoopCommonModes];

    while (!g_stop) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }

    [heartbeatTimer invalidate];
    [wakeTimer invalidate];
    ABShutdownStreaming();
    return 0;
}

static BOOL ABParseStrictPositiveDecimalInt(NSString *string, long *outValue) {
    if (string == nil || outValue == NULL) {
        return NO;
    }
    const char *cstr = string.UTF8String;
    if (cstr == NULL) {
        return NO;
    }
    errno = 0;
    char *endPointer = NULL;
    long value = strtol(cstr, &endPointer, 10);
    if (endPointer == cstr || *endPointer != '\0' || errno == ERANGE || value <= 0) {
        return NO;
    }
    *outValue = value;
    return YES;
}

/// Stdout PCM path: optional `registerDefaultInputListener` follows the system default input (Phase 7.2).
static int ABRunStdoutPCMStreaming(NSString *optInput, UInt32 resolvedInputID, NSString *optRateString, BOOL quiet,
                                   BOOL registerDefaultInputListener) {
    double targetSampleRateHz = 0;
    if (optRateString != nil) {
        long parsedHz = 0;
        if (!ABParseStrictPositiveDecimalInt(optRateString, &parsedHz)) {
            fprintf(stderr, "audiobridge: --rate / -r must be a positive integer.\n");
            return 1;
        }
        targetSampleRateHz = (double)parsedHz;
    }

    ABSystemDefaultIO *systemIO = [[ABSystemDefaultIO alloc] init];
    if (optInput != nil) {
        NSError *pinError = nil;
        if (![systemIO saveAndSetInput:resolvedInputID error:&pinError]) {
            NSString *message = pinError.localizedDescription ?: @"Could not set default input device.";
            const char *utf8 = message.UTF8String;
            fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "Could not set default input device.");
            return 1;
        }
    }

    ABStdoutPCMWriter *pcmWriter = [[ABStdoutPCMWriter alloc] initWithStdoutFile:stdout];
    [pcmWriter configureRecoveryWithTargetSampleRateHz:targetSampleRateHz quiet:quiet];
    ABRecoveryRuntimeContext *runtimeContext = [[ABRecoveryRuntimeContext alloc] init];
    ABDeviceRecoveryCoordinator *coordinator =
        [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:pcmWriter
                                                 sleepHandler:^(NSTimeInterval delaySeconds) {
                                                     if (runtimeContext.active) {
                                                         runtimeContext.retryDelayCount += 1;
                                                         runtimeContext.lastDelaySeconds = delaySeconds;
                                                         const char *sourceUTF8 = runtimeContext.triggerSource.UTF8String;
                                                         fprintf(stderr,
                                                                 "[audiobridge] recovery: trigger_source=%s attempt=%lu delay_seconds=%.1f state=retry_wait\n",
                                                                 sourceUTF8 != NULL ? sourceUTF8 : "unknown",
                                                                 (unsigned long)(runtimeContext.retryDelayCount + 1),
                                                                 delaySeconds);
                                                     }
                                                     [NSThread sleepForTimeInterval:delaySeconds];
                                                 }];
    ABStreamingArmShutdownContext(systemIO, nil, pcmWriter);

    NSError *startError = nil;
    if (![coordinator startWithError:&startError]) {
        NSString *message = startError.localizedDescription ?: @"PCM stdout engine start failed.";
        const char *utf8 = message.UTF8String;
        fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "PCM stdout engine start failed.");
        ABShutdownStreaming();
        return 1;
    }

    __block BOOL heartbeatPaused = NO;
    __block ABDeviceRecoveryCoordinator *coordinatorBlock = coordinator;
    __block ABStdoutPCMWriter *pcmWriterBlock = pcmWriter;
    __block ABRecoveryRuntimeContext *runtimeContextBlock = runtimeContext;

    if (registerDefaultInputListener) {
        [systemIO registerForFloatingInput:YES
                          floatingOutput:NO
                            rebuildBlock:^{
                                heartbeatPaused = YES;
                                NSError *recoveryError = nil;
                                (void)ABRunSharedRecoveryPipeline(coordinatorBlock, pcmWriterBlock, runtimeContextBlock,
                                                                  @"listener_default_change", &recoveryError);
                                heartbeatPaused = NO;
                            }];
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = ABStreamingHandleSignal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    NSTimer *wakeTimer = [NSTimer timerWithTimeInterval:0.2
                                                repeats:YES
                                                  block:^(__unused NSTimer *timer) {
                                                  }];
    [[NSRunLoop mainRunLoop] addTimer:wakeTimer forMode:NSRunLoopCommonModes];
    NSTimer *heartbeatTimer = [NSTimer timerWithTimeInterval:0.5
                                                     repeats:YES
                                                       block:^(__unused NSTimer *timer) {
                                                           if (heartbeatPaused) {
                                                               return;
                                                           }
                                                           if (![pcmWriterBlock ab_isActive]) {
                                                               NSError *recoveryError = nil;
                                                               (void)ABRunSharedRecoveryPipeline(
                                                                   coordinatorBlock, pcmWriterBlock,
                                                                   runtimeContextBlock, @"heartbeat_inactive",
                                                                   &recoveryError);
                                                           }
                                                       }];
    [[NSRunLoop mainRunLoop] addTimer:heartbeatTimer forMode:NSRunLoopCommonModes];

    while (!g_stop) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }

    [heartbeatTimer invalidate];
    [wakeTimer invalidate];
    ABShutdownStreaming();
    return 0;
}

// On macOS, the C runtime supplies argv as UTF-8. Arguments that are not valid
// UTF-8 are rejected so device names and flags cannot be mis-parsed silently.

NSString *const ABArgumentsErrorDomain = @"ABArgumentsError";

enum { AB_OPT_LIST_ALL = 256, AB_OPT_INTEGRATION_RECOVERY_LIFECYCLE = 257 };

NSArray<NSString *> *ABArgumentsFromArgcArgv(int argc, const char **argv, NSError **outError) {
    if (argc < 0 || argv == NULL) {
        if (outError) {
            *outError = [NSError errorWithDomain:ABArgumentsErrorDomain
                                            code:1
                                        userInfo:@{
                                            NSLocalizedDescriptionKey : @"Invalid argc or argv.",
                                        }];
        }
        return nil;
    }

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
    for (int i = 0; i < argc; i++) {
        const char *cstr = argv[i];
        if (cstr == NULL) {
            if (outError) {
                *outError = [NSError errorWithDomain:ABArgumentsErrorDomain
                                                code:2
                                            userInfo:@{
                                                NSLocalizedDescriptionKey :
                                                    [NSString stringWithFormat:@"Argument %d is NULL.", i],
                                            }];
            }
            return nil;
        }
        NSString *s = [NSString stringWithCString:cstr encoding:NSUTF8StringEncoding];
        if (s == nil) {
            if (outError) {
                *outError = [NSError errorWithDomain:ABArgumentsErrorDomain
                                                code:3
                                            userInfo:@{
                                                NSLocalizedDescriptionKey : [NSString
                                                    stringWithFormat:
                                                        @"Argument %d is not valid UTF-8 (macOS argv is UTF-8).",
                                                        i],
                                            }];
            }
            return nil;
        }
        [args addObject:s];
    }
    return [args copy];
}

static char **ABCopyNSStringArrayToCArgv(NSArray<NSString *> *arguments, NSUInteger *outCount) {
    NSUInteger n = arguments.count;
    char **cargv = (char **)calloc(n + 1, sizeof(char *));
    if (cargv == NULL) {
        return NULL;
    }
    for (NSUInteger i = 0; i < n; i++) {
        const char *utf8 = [arguments[i] UTF8String];
        const char *src = utf8 != NULL ? utf8 : "";
        char *copy = strdup(src);
        if (copy == NULL) {
            for (NSUInteger j = 0; j < i; j++) {
                free(cargv[j]);
            }
            free(cargv);
            return NULL;
        }
        cargv[i] = copy;
    }
    cargv[n] = NULL;
    if (outCount) {
        *outCount = n;
    }
    return cargv;
}

static void ABFreeCArgv(char **cargv, NSUInteger count) {
    if (cargv == NULL) {
        return;
    }
    for (NSUInteger i = 0; i < count; i++) {
        free(cargv[i]);
    }
    free(cargv);
}

/// Parses options into out-parameters. On failure prints to stderr and returns a non-zero exit code (2).
static int ABParseOptionsFromArguments(NSArray<NSString *> *arguments, BOOL *outWantHelp, BOOL *outListAll,
                                       BOOL *outIntegrationRecoveryLifecycle, BOOL *outForce, BOOL *outQuiet,
                                       NSString *__autoreleasing *outOptInput, NSString *__autoreleasing *outOptOutput,
                                       NSString *__autoreleasing *outOptRate) {
    NSUInteger argc = 0;
    char **cargv = ABCopyNSStringArrayToCArgv(arguments, &argc);
    if (cargv == NULL) {
        fprintf(stderr, "audiobridge: out of memory.\n");
        return 2;
    }

    optind = 1;
    opterr = 0;

    BOOL wantHelp = NO;
    BOOL listAll = NO;
    BOOL integrationRecoveryLifecycle = NO;
    BOOL force = NO;
    BOOL quiet = NO;
    NSString *optInput = nil;
    NSString *optOutput = nil;
    NSString *optRate = nil;

    static struct option longopts[] = {
        {"help", no_argument, NULL, 'h'},
        {"force", no_argument, NULL, 'f'},
        {"input", required_argument, NULL, 'i'},
        {"output", required_argument, NULL, 'o'},
        {"rate", required_argument, NULL, 'r'},
        {"quiet", no_argument, NULL, 'q'},
        {"list-all", no_argument, NULL, AB_OPT_LIST_ALL},
        {"integration-recovery-lifecycle", no_argument, NULL, AB_OPT_INTEGRATION_RECOVERY_LIFECYCLE},
        {NULL, 0, NULL, 0},
    };

    int ch;
    while ((ch = getopt_long((int)argc, cargv, "hfi:o:r:q", longopts, NULL)) != -1) {
        switch (ch) {
            case 'h':
                wantHelp = YES;
                break;
            case 'f':
                force = YES;
                break;
            case 'i':
                optInput = [NSString stringWithUTF8String:optarg];
                break;
            case 'o':
                optOutput = [NSString stringWithUTF8String:optarg];
                break;
            case 'r':
                optRate = [NSString stringWithUTF8String:optarg];
                break;
            case 'q':
                quiet = YES;
                break;
            case AB_OPT_LIST_ALL:
                listAll = YES;
                break;
            case AB_OPT_INTEGRATION_RECOVERY_LIFECYCLE:
                integrationRecoveryLifecycle = YES;
                break;
            case '?':
            default:
                fprintf(stderr, "audiobridge: unknown or invalid option.\n");
                ABFreeCArgv(cargv, argc);
                return 2;
        }
    }

    if (optind < (int)argc) {
        fprintf(stderr, "audiobridge: unexpected argument.\n");
        ABFreeCArgv(cargv, argc);
        return 2;
    }

    ABFreeCArgv(cargv, argc);

    *outWantHelp = wantHelp;
    *outListAll = listAll;
    *outIntegrationRecoveryLifecycle = integrationRecoveryLifecycle;
    *outForce = force;
    *outQuiet = quiet;
    *outOptInput = optInput;
    *outOptOutput = optOutput;
    *outOptRate = optRate;
    return 0;
}

static void ABPrintUsageToFile(FILE *fp) {
    fputs("Usage: audiobridge [options]\n\n", fp);
    fputs("Options:\n", fp);
    fputs("  -h, --help              Show this help, a short device preview, and exit.\n", fp);
    fputs("  -f, --force             Allow streaming when both --input and --output are omitted.\n", fp);
    fputs("  -i, --input <id|name>   Input device (omit to follow the system default input).\n", fp);
    fputs(
        "  -o, --output <id|name>  Output device, or a single \"-\" for interleaved s16le PCM on stdout.\n",
        fp);
    fputs("  -r, --rate <Hz>         Output PCM sample rate; only valid with -o - (stdout mode).\n", fp);
    fputs("  -q, --quiet             Suppress routine stderr while streaming; no effect with -h or --list-all.\n",
          fp);
    fputs("      --list-all          Print every input/output device to stderr and exit.\n", fp);
    fputs("\n", fp);
}

/// Returns 0 if OK, 1 for `-r` misuse, 2 for invalid flag combinations.
static int ABCliValidateCombinations(BOOL listAll, BOOL wantHelp, BOOL integrationRecoveryLifecycle, BOOL force,
                                     NSString *optInput, NSString *optOutput, NSString *optRate) {
    if (integrationRecoveryLifecycle) {
        if (listAll || wantHelp || force || optInput != nil || optOutput != nil || optRate != nil) {
            return 2;
        }
        return 0;
    }

    if (listAll) {
        if (wantHelp || force || optInput != nil || optOutput != nil || optRate != nil) {
            return 2;
        }
        return 0;
    }

    if (wantHelp) {
        if (force || optInput != nil || optOutput != nil || optRate != nil) {
            return 2;
        }
        return 0;
    }

    BOOL stdoutMode = (optOutput != nil && [optOutput isEqualToString:@"-"]);
    if (optRate != nil && !stdoutMode) {
        fprintf(stderr, "audiobridge: --rate / -r is only valid with --output - (stdout PCM mode).\n");
        return 1;
    }

    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSError *error = nil;
        NSArray<NSString *> *arguments = ABArgumentsFromArgcArgv(argc, argv, &error);
        if (arguments == nil) {
            NSString *message = error.localizedDescription ?: @"Invalid command-line arguments.";
            const char *utf8 = message.UTF8String;
            if (utf8 != NULL) {
                fprintf(stderr, "%s\n", utf8);
            } else {
                fprintf(stderr, "Invalid command-line arguments.\n");
            }
            return 2;
        }

        BOOL wantHelp = NO;
        BOOL listAll = NO;
        BOOL integrationRecoveryLifecycle = NO;
        BOOL force = NO;
        BOOL quiet = NO;
        NSString *optInput = nil;
        NSString *optOutput = nil;
        NSString *optRate = nil;

        int parseExit = ABParseOptionsFromArguments(arguments, &wantHelp, &listAll, &integrationRecoveryLifecycle,
                                                    &force, &quiet, &optInput, &optOutput, &optRate);
        if (parseExit != 0) {
            return parseExit;
        }

        int combo = ABCliValidateCombinations(listAll, wantHelp, integrationRecoveryLifecycle, force, optInput,
                                              optOutput, optRate);
        if (combo != 0) {
            return combo;
        }

        if (integrationRecoveryLifecycle) {
            return ABRunIntegrationRecoveryLifecycleScenario();
        }

        if (listAll) {
            [ABDeviceQuery printFullDeviceListToFile:stderr];
            (void)quiet;
            return 0;
        }

        BOOL doubleOmission = (optInput == nil && optOutput == nil && !force);
        BOOL helpMode =
            wantHelp || (arguments.count == 1) || (doubleOmission && !listAll);
        if (helpMode) {
            ABPrintUsageToFile(stderr);
            fputc('\n', stderr);
            [ABDeviceQuery printDevicePreviewToFile:stderr maxInputs:10 maxOutputs:10];
            (void)quiet;
            return 0;
        }

        ABDeviceQuery *query = [[ABDeviceQuery alloc] init];
        [query refresh];

        UInt32 resolvedInputID = 0;
        UInt32 resolvedOutputID = 0;
        BOOL stdoutMode = NO;

        if (optInput != nil) {
            NSError *resolveError = nil;
            if (![query resolveInputString:optInput intoDeviceID:&resolvedInputID error:&resolveError]) {
                NSString *message = resolveError.localizedDescription ?: @"Could not resolve input device.";
                const char *utf8 = message.UTF8String;
                fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "Could not resolve input device.");
                return 1;
            }
        }

        if (optOutput != nil) {
            BOOL isStdout = NO;
            NSError *resolveError = nil;
            if (![query resolveOutputString:optOutput intoDeviceID:&resolvedOutputID isStdout:&isStdout
                                       error:&resolveError]) {
                NSString *message = resolveError.localizedDescription ?: @"Could not resolve output device.";
                const char *utf8 = message.UTF8String;
                fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "Could not resolve output device.");
                return 1;
            }
            stdoutMode = isStdout;
        }

        if (stdoutMode) {
            return ABRunStdoutPCMStreaming(optInput, resolvedInputID, optRate, quiet, (optInput == nil));
        }

        return ABRunSpeakerStreaming(query, optInput, optOutput, resolvedInputID, resolvedOutputID, quiet);
    }
}
