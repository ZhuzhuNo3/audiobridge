#import <CoreAudio/CoreAudio.h>
#import <errno.h>
#import <Foundation/Foundation.h>
#import <getopt.h>
#import <signal.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#import "ABDeviceQuery.h"
#import "ABDeviceRecoveryCoordinator.h"
#import "ABDiagSnapshot.h"
#import "ABAggregateDevice.h"
#import "ABPassThroughEngine.h"
#import "ABStdoutPCMWriter.h"
#import "ABSystemDefaultIO.h"

static volatile sig_atomic_t g_stop = 0;

static ABSystemDefaultIO *g_streamingSystemIO = nil;
static ABPassThroughEngine *g_streamingPassEngine = nil;
static ABStdoutPCMWriter *g_streamingPCMWriter = nil;
static ABAggregateDevice *g_streamingAggregate = nil;
static BOOL g_streamingSpeakerDiag = NO;
static BOOL g_streamingInputPinned = NO;
static BOOL g_streamingOutputPinned = NO;
static BOOL g_streamingConfigWaiting = NO;
static AudioDeviceID g_streamingConfigInputID = kAudioObjectUnknown;
static AudioDeviceID g_streamingConfigOutputID = kAudioObjectUnknown;
static AudioDeviceID g_streamingBoundDeviceID = kAudioObjectUnknown;

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
    ABLogInfo(@"recovery trigger_source=%s state=begin", sourceUTF8 != NULL ? sourceUTF8 : "unknown");

    ABDeviceRecoveryResult result = [coordinator recoverAfterUnexpectedStopWithResult:error];
    NSUInteger attempts = ABRuntimeRebuildAttemptCountForEndpoint(endpoint) - runtimeContext.attemptBase;
    if (attempts == 0) {
        attempts = 1;
    }

    NSString *diagState = @"failed";
    if (result == ABDeviceRecoveryResultRecovered) {
        diagState = @"streaming_restored";
        ABLogInfo(@"recovery trigger_source=%s state=streaming_restored attempt=%lu delay_count=%lu",
                  sourceUTF8 != NULL ? sourceUTF8 : "unknown", (unsigned long)attempts,
                  (unsigned long)runtimeContext.retryDelayCount);
    } else if (result == ABDeviceRecoveryResultCoalescedInFlight) {
        diagState = @"coalesced_inflight";
        ABLogInfo(@"recovery trigger_source=%s state=coalesced_inflight attempt=%lu delay_count=%lu "
                  @"failure_summary=recovery already in flight",
                  sourceUTF8 != NULL ? sourceUTF8 : "unknown", (unsigned long)attempts,
                  (unsigned long)runtimeContext.retryDelayCount);
    } else if (result == ABDeviceRecoveryResultCompensationDisabled) {
        diagState = @"failed";
        ABLogInfo(@"recovery trigger_source=%s state=failed attempt=%lu delay_count=%lu "
                  @"failure_summary=compensation disabled",
                  sourceUTF8 != NULL ? sourceUTF8 : "unknown", (unsigned long)attempts,
                  (unsigned long)runtimeContext.retryDelayCount);
    } else {
        diagState = @"failed";
        NSString *summary = error != NULL && *error != nil ? (*error).localizedDescription : @"rebuild failed";
        const char *summaryUTF8 = summary.UTF8String;
        ABLogInfo(@"recovery trigger_source=%s state=failed attempt=%lu delay_count=%lu failure_summary=%s",
                  sourceUTF8 != NULL ? sourceUTF8 : "unknown", (unsigned long)attempts,
                  (unsigned long)runtimeContext.retryDelayCount, summaryUTF8 != NULL ? summaryUTF8 : "unknown");
    }

    if (ABDiagIsEnabled() && [endpoint isKindOfClass:[ABPassThroughEngine class]]) {
        ABPassThroughEngine *pass = (ABPassThroughEngine *)endpoint;
        NSMutableDictionary<NSString *, NSString *> *extra = [NSMutableDictionary dictionary];
        extra[@"recovery_state"] = diagState;
        extra[@"attempt"] = [NSString stringWithFormat:@"%lu", (unsigned long)attempts];
        extra[@"delay_count"] =
            [NSString stringWithFormat:@"%lu", (unsigned long)runtimeContext.retryDelayCount];
        if (result != ABDeviceRecoveryResultRecovered && error != NULL && *error != nil) {
            extra[@"error_domain"] = (*error).domain ?: @"";
            extra[@"error_code"] = [NSString stringWithFormat:@"%ld", (long)(*error).code];
        }
        ABDiagEmitEvent([@"recovery_" stringByAppendingString:diagState], triggerSource, nil,
                        [pass diagEngineContext], extra);
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
                                                         ABLogInfo(@"recovery trigger_source=%s attempt=%lu delay_seconds=%.1f "
                                                                   @"state=retry_wait",
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

static void ABStreamingArmSpeakerDiagContext(BOOL diag, BOOL inputPinned, BOOL outputPinned) {
    g_streamingSpeakerDiag = diag;
    g_streamingInputPinned = inputPinned;
    g_streamingOutputPinned = outputPinned;
}

static void ABStreamingArmBindContext(ABAggregateDevice *aggregate, AudioDeviceID boundID,
                                      AudioDeviceID configIn, AudioDeviceID configOut, BOOL configWaiting) {
    g_streamingAggregate = aggregate;
    g_streamingBoundDeviceID = boundID;
    g_streamingConfigInputID = configIn;
    g_streamingConfigOutputID = configOut;
    g_streamingConfigWaiting = configWaiting;
}

static BOOL ABDeviceIsAlive(AudioDeviceID deviceID) {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyDeviceIsAlive,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 alive = 0;
    UInt32 size = (UInt32)sizeof(alive);
    OSStatus st = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &alive);
    return st == noErr && alive != 0;
}

/// Stable identity for a configured side: CLI string and/or Device UID captured at bind time.
static NSString *ABSpeakerCaptureDeviceUID(AudioDeviceID deviceID) {
    return [ABDeviceQuery deviceUIDForAudioDeviceID:deviceID];
}

/// Re-resolve one configured side from original -i/-o string, then Device UID, then sticky id if still alive.
static BOOL ABSpeakerReresolveOneConfiguredID(ABDeviceQuery *query, NSString *optString, NSString *stableUID,
                                              BOOL isInput, UInt32 *inoutDeviceID) {
    if (query == NULL || inoutDeviceID == NULL) {
        return NO;
    }
    UInt32 found = 0;
    if (optString.length > 0) {
        NSError *resolveError = nil;
        if (isInput) {
            if ([query resolveInputString:optString intoDeviceID:&found error:&resolveError]) {
                *inoutDeviceID = found;
                return YES;
            }
        } else {
            BOOL isStdout = NO;
            if ([query resolveOutputString:optString intoDeviceID:&found isStdout:&isStdout error:&resolveError] &&
                !isStdout) {
                *inoutDeviceID = found;
                return YES;
            }
        }
    }
    if (stableUID.length > 0) {
        if ([query resolveUID:stableUID amongInputCapable:isInput intoDeviceID:&found]) {
            *inoutDeviceID = found;
            return YES;
        }
    }
    if (ABDeviceIsAlive(*inoutDeviceID)) {
        return YES;
    }
    return NO;
}

/// Refresh hardware lists and update configured AudioDeviceIDs from string/UID identity.
/// Returns YES only when every configured side resolves to a live device.
static BOOL ABSpeakerReresolveConfiguredIDs(ABDeviceQuery *query, BOOL inputPinned, NSString *optInput,
                                            NSString *inputUID, UInt32 *inoutInputID, BOOL outputPinned,
                                            NSString *optOutput, NSString *outputUID, UInt32 *inoutOutputID) {
    if (query == NULL) {
        return NO;
    }
    [query refresh];
    if (inputPinned) {
        if (inoutInputID == NULL) {
            return NO;
        }
        if (!ABSpeakerReresolveOneConfiguredID(query, optInput, inputUID, YES, inoutInputID)) {
            return NO;
        }
        if (!ABDeviceIsAlive(*inoutInputID)) {
            return NO;
        }
    }
    if (outputPinned) {
        if (inoutOutputID == NULL) {
            return NO;
        }
        if (!ABSpeakerReresolveOneConfiguredID(query, optOutput, outputUID, NO, inoutOutputID)) {
            return NO;
        }
        if (!ABDeviceIsAlive(*inoutOutputID)) {
            return NO;
        }
    }
    return YES;
}

/// True when config-wait owns the intentional stop; heartbeat must not run recovery.
static BOOL ABSpeakerConfigWaitSuppressesRecovery(BOOL configWaiting) {
    return configWaiting;
}

static ABDiagDeviceContext *ABSpeakerMakeDeviceContext(ABSystemDefaultIO *systemIO, BOOL inputPinned,
                                                       BOOL outputPinned) {
    ABDiagDeviceContext *ctx = [[ABDiagDeviceContext alloc] init];
    ctx.inputConfigured = inputPinned;
    ctx.outputConfigured = outputPinned;
    ctx.configInputDeviceID = g_streamingConfigInputID;
    ctx.configOutputDeviceID = g_streamingConfigOutputID;
    ctx.boundDeviceID = g_streamingBoundDeviceID;
    ctx.aggregateDeviceID = g_streamingAggregate != nil ? g_streamingAggregate.aggregateDeviceID : kAudioObjectUnknown;
    ctx.configWaiting = g_streamingConfigWaiting;
    ctx.floatingInputListenerRegistered = systemIO.floatingInputListenerRegistered;
    ctx.floatingOutputListenerRegistered = systemIO.floatingOutputListenerRegistered;
    ctx.savedInputDeviceID = systemIO.savedInputDeviceID;
    ctx.savedOutputDeviceID = systemIO.savedOutputDeviceID;
    ctx.didChangeInput = systemIO.didChangeInput;
    ctx.didChangeOutput = systemIO.didChangeOutput;
    return ctx;
}

// Registered while streaming so tap/audio error paths (e.g. ABStdoutPCMWriter) can tear down on the main queue.
// Must only be called from the main thread.
void ABShutdownStreaming(void) {
    ABSystemDefaultIO *io = g_streamingSystemIO;
    ABPassThroughEngine *pass = g_streamingPassEngine;
    ABStdoutPCMWriter *pcm = g_streamingPCMWriter;
    ABAggregateDevice *aggregate = g_streamingAggregate;
    BOOL speakerDiag = g_streamingSpeakerDiag && pass != nil && ABDiagIsEnabled();
    BOOL inputPinned = g_streamingInputPinned;
    BOOL outputPinned = g_streamingOutputPinned;
    // Clear endpoint ownership first so re-entrant shutdown cannot double-stop.
    // Keep bind/wait globals until after pre_teardown so the before snapshot still
    // reflects the live binding (bound_device_id / aggregate_id / config_waiting).
    g_streamingSystemIO = nil;
    g_streamingPassEngine = nil;
    g_streamingPCMWriter = nil;
    g_streamingSpeakerDiag = NO;

    if (speakerDiag && io != nil && pass != nil) {
        ABDiagEmitEvent(@"shutdown", @"pre_teardown", ABSpeakerMakeDeviceContext(io, inputPinned, outputPinned),
                        [pass diagEngineContext], @{@"phase" : @"before"});
    }

    g_streamingAggregate = nil;
    g_streamingConfigWaiting = NO;
    g_streamingBoundDeviceID = kAudioObjectUnknown;

    if (io != nil) {
        [io removeAllListeners];
    }
    if (pass != nil) {
        [pass stop];
    }
    if (pcm != nil) {
        [pcm stop];
    }
    if (aggregate != nil) {
        [aggregate destroy];
        if (ABDiagIsEnabled()) {
            ABDiagEmitEvent(@"aggregate_destroy", @"shutdown", nil, nil, nil);
        }
    }
    if (io != nil) {
        [io restoreAll];
    }

    if (speakerDiag && io != nil && pass != nil) {
        // Read-only after stop: keep engine-owned seq; do not invent zeros via nil ctx.
        ABDiagEmitEvent(@"shutdown", @"post_teardown", ABSpeakerMakeDeviceContext(io, inputPinned, outputPinned),
                        [pass diagEngineContext], @{@"phase" : @"after"});
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

    ABLogWarn(@"built-in input and output are selected; acoustic feedback is possible — use headphones or "
              @"lower monitoring volume.");
}

/// Resolve logical in/out ids for A2: configured id or current system default.
static BOOL ABSpeakerResolveLogicalIO(BOOL inputConfigured, UInt32 resolvedInputID, BOOL outputConfigured,
                                      UInt32 resolvedOutputID, AudioDeviceID *outIn, AudioDeviceID *outOut,
                                      NSError **error) {
    AudioDeviceID inID = kAudioObjectUnknown;
    AudioDeviceID outID = kAudioObjectUnknown;
    if (inputConfigured) {
        inID = resolvedInputID;
    } else if (![ABSystemDefaultIO readDefaultInput:&inID error:error]) {
        return NO;
    }
    if (outputConfigured) {
        outID = resolvedOutputID;
    } else if (![ABSystemDefaultIO readDefaultOutput:&outID error:error]) {
        return NO;
    }
    if (inID == kAudioObjectUnknown || outID == kAudioObjectUnknown) {
        if (error) {
            *error = [NSError errorWithDomain:@"ABSpeakerStreaming"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : @"Could not resolve input/output device ids.",
                                     }];
        }
        return NO;
    }
    *outIn = inID;
    *outOut = outID;
    return YES;
}

/// Compose Aggregate or direct duplex bind. On failure does not modify system defaults.
static BOOL ABSpeakerEstablishBinding(AudioDeviceID logicalIn, AudioDeviceID logicalOut,
                                      ABAggregateDevice *__autoreleasing *outAggregate, AudioDeviceID *outBoundID,
                                      NSError **error) {
    if (outAggregate == NULL || outBoundID == NULL) {
        return NO;
    }
    *outAggregate = nil;
    *outBoundID = kAudioObjectUnknown;
    if ([ABAggregateDevice shouldBindDirectlyWithInputDeviceID:logicalIn outputDeviceID:logicalOut]) {
        *outBoundID = logicalIn;
        if (ABDiagIsEnabled()) {
            ABDiagEmitEvent(@"device_bind_direct", nil, nil, nil, @{
                @"bound_device_id" : [NSString stringWithFormat:@"%u", (unsigned int)logicalIn],
                @"aggregate" : @"0",
            });
        }
        return YES;
    }
    ABAggregateDevice *agg = [ABAggregateDevice createWithInputDeviceID:logicalIn
                                                         outputDeviceID:logicalOut
                                                                  error:error];
    if (agg == nil) {
        ABLogError(@"aggregate_create_failed in=%u out=%u", (unsigned int)logicalIn, (unsigned int)logicalOut);
        return NO;
    }
    *outAggregate = agg;
    *outBoundID = agg.aggregateDeviceID;
    if (ABDiagIsEnabled()) {
        ABDiagEmitEvent(@"aggregate_create", nil, nil, nil, @{
            @"aggregate_id" : [NSString stringWithFormat:@"%u", (unsigned int)agg.aggregateDeviceID],
            @"sub_in_id" : [NSString stringWithFormat:@"%u", (unsigned int)logicalIn],
            @"sub_out_id" : [NSString stringWithFormat:@"%u", (unsigned int)logicalOut],
        });
    }
    return YES;
}

static void ABSpeakerDestroyBinding(ABAggregateDevice *__autoreleasing *aggregateRef) {
    if (aggregateRef == NULL || *aggregateRef == nil) {
        return;
    }
    [*aggregateRef destroy];
    if (ABDiagIsEnabled()) {
        ABDiagEmitEvent(@"aggregate_destroy", @"rebinding", nil, nil, nil);
    }
    *aggregateRef = nil;
}

@interface ABSpeakerAliveWatch : NSObject
@property(nonatomic, assign) AudioDeviceID deviceID;
@property(nonatomic, assign) BOOL lastAlive;
@property(nonatomic, copy) void (^onEdge)(BOOL alive);
- (void)start;
- (void)stop;
@end

@implementation ABSpeakerAliveWatch {
    BOOL _listening;
}

static OSStatus ABSpeakerAliveListener(AudioObjectID objectID, UInt32 addressCount,
                                       const AudioObjectPropertyAddress *addresses, void *clientData) {
    (void)objectID;
    (void)addressCount;
    (void)addresses;
    ABSpeakerAliveWatch *watch = (__bridge ABSpeakerAliveWatch *)clientData;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL alive = ABDeviceIsAlive(watch.deviceID);
        if (alive == watch.lastAlive) {
            return;
        }
        watch.lastAlive = alive;
        if (watch.onEdge != nil) {
            watch.onEdge(alive);
        }
    });
    return noErr;
}

- (void)start {
    if (_listening || self.deviceID == kAudioObjectUnknown) {
        return;
    }
    self.lastAlive = ABDeviceIsAlive(self.deviceID);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyDeviceIsAlive,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    OSStatus st = AudioObjectAddPropertyListener(self.deviceID, &address, ABSpeakerAliveListener,
                                                 (__bridge void *)self);
    _listening = (st == noErr);
}

- (void)stop {
    if (!_listening) {
        return;
    }
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyDeviceIsAlive,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    (void)AudioObjectRemovePropertyListener(self.deviceID, &address, ABSpeakerAliveListener,
                                            (__bridge void *)self);
    _listening = NO;
}

- (void)dealloc {
    [self stop];
}

@end

@interface ABSpeakerOutputPropertyWatch : NSObject
@property(nonatomic, assign) AudioDeviceID deviceID;
@property(nonatomic, copy) void (^onMuteOrVolume)(void);
@property(nonatomic, copy) void (^onAlive)(BOOL alive);
- (void)start;
- (void)stop;
@end

@implementation ABSpeakerOutputPropertyWatch {
    BOOL _listening;
    BOOL _lastMuteReadable;
    BOOL _lastMute;
    BOOL _lastVolumeReadable;
    Float32 _lastVolume;
    BOOL _lastAlive;
}

static BOOL ABSpeakerReadMute(AudioDeviceID deviceID, BOOL *outMute) {
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyMute,
        .mScope = kAudioObjectPropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(deviceID, &address)) {
        return NO;
    }
    UInt32 mute = 0;
    UInt32 size = (UInt32)sizeof(mute);
    if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &mute) != noErr) {
        return NO;
    }
    *outMute = mute != 0;
    return YES;
}

static BOOL ABSpeakerReadVolume(AudioDeviceID deviceID, Float32 *outVolume) {
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyVolumeScalar,
        .mScope = kAudioObjectPropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(deviceID, &address)) {
        return NO;
    }
    Float32 volume = 0;
    UInt32 size = (UInt32)sizeof(volume);
    if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &volume) != noErr) {
        return NO;
    }
    *outVolume = volume;
    return YES;
}

static OSStatus ABSpeakerOutputPropertyListener(AudioObjectID objectID, UInt32 addressCount,
                                                const AudioObjectPropertyAddress *addresses, void *clientData) {
    (void)objectID;
    ABSpeakerOutputPropertyWatch *watch = (__bridge ABSpeakerOutputPropertyWatch *)clientData;
    BOOL muteTouched = NO;
    BOOL volumeTouched = NO;
    BOOL aliveTouched = NO;
    for (UInt32 i = 0; i < addressCount; i++) {
        AudioObjectPropertySelector sel = addresses[i].mSelector;
        if (sel == kAudioDevicePropertyMute) {
            muteTouched = YES;
        } else if (sel == kAudioDevicePropertyVolumeScalar) {
            volumeTouched = YES;
        } else if (sel == kAudioDevicePropertyDeviceIsAlive) {
            aliveTouched = YES;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (muteTouched || volumeTouched) {
            BOOL mute = NO;
            BOOL muteReadable = ABSpeakerReadMute(watch.deviceID, &mute);
            Float32 volume = 0;
            BOOL volumeReadable = ABSpeakerReadVolume(watch.deviceID, &volume);
            BOOL changed = NO;
            if (muteReadable != watch->_lastMuteReadable || (muteReadable && mute != watch->_lastMute)) {
                changed = YES;
            }
            if (volumeReadable != watch->_lastVolumeReadable ||
                (volumeReadable && volume != watch->_lastVolume)) {
                changed = YES;
            }
            watch->_lastMuteReadable = muteReadable;
            watch->_lastMute = mute;
            watch->_lastVolumeReadable = volumeReadable;
            watch->_lastVolume = volume;
            if (changed && watch.onMuteOrVolume != nil) {
                watch.onMuteOrVolume();
            }
        }
        if (aliveTouched) {
            BOOL alive = ABDeviceIsAlive(watch.deviceID);
            if (alive != watch->_lastAlive) {
                watch->_lastAlive = alive;
                if (watch.onAlive != nil) {
                    watch.onAlive(alive);
                }
            }
        }
    });
    return noErr;
}

- (void)start {
    if (_listening || self.deviceID == kAudioObjectUnknown) {
        return;
    }
    _lastMuteReadable = ABSpeakerReadMute(self.deviceID, &_lastMute);
    _lastVolumeReadable = ABSpeakerReadVolume(self.deviceID, &_lastVolume);
    _lastAlive = ABDeviceIsAlive(self.deviceID);

    AudioObjectPropertyAddress selectors[3] = {
        {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
        {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
        {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    BOOL any = NO;
    for (int i = 0; i < 3; i++) {
        OSStatus st = AudioObjectAddPropertyListener(self.deviceID, &selectors[i], ABSpeakerOutputPropertyListener,
                                                     (__bridge void *)self);
        if (st == noErr) {
            any = YES;
        }
    }
    _listening = any;
}

- (void)stop {
    if (!_listening) {
        return;
    }
    AudioObjectPropertyAddress selectors[3] = {
        {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
        {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
        {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    for (int i = 0; i < 3; i++) {
        (void)AudioObjectRemovePropertyListener(self.deviceID, &selectors[i], ABSpeakerOutputPropertyListener,
                                                (__bridge void *)self);
    }
    _listening = NO;
}

- (void)dealloc {
    [self stop];
}

@end

/// Watches `kAudioHardwarePropertyDevices` and coalesces bursts with the same 80 ms quiet window
/// used by floating default-device listeners.
@interface ABSpeakerHardwareDevicesWatch : NSObject
@property(nonatomic, copy) void (^onChange)(void);
- (void)start;
- (void)stop;
@end

@implementation ABSpeakerHardwareDevicesWatch {
    BOOL _listening;
    _Atomic uint64_t _debounceGeneration;
}

static OSStatus ABSpeakerHardwareDevicesListener(AudioObjectID objectID, UInt32 addressCount,
                                                 const AudioObjectPropertyAddress *addresses, void *clientData) {
    (void)objectID;
    (void)addressCount;
    (void)addresses;
    ABSpeakerHardwareDevicesWatch *watch = (__bridge ABSpeakerHardwareDevicesWatch *)clientData;
    uint64_t token = atomic_fetch_add_explicit(&watch->_debounceGeneration, 1, memory_order_relaxed) + 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC * 0.08)), dispatch_get_main_queue(), ^{
            if (atomic_load_explicit(&watch->_debounceGeneration, memory_order_relaxed) != token) {
                return;
            }
            if (watch.onChange != nil) {
                watch.onChange();
            }
        });
    });
    return noErr;
}

- (void)start {
    if (_listening) {
        return;
    }
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    OSStatus st = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &address,
                                                 ABSpeakerHardwareDevicesListener, (__bridge void *)self);
    _listening = (st == noErr);
}

- (void)stop {
    atomic_fetch_add_explicit(&_debounceGeneration, 1, memory_order_relaxed);
    if (!_listening) {
        return;
    }
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    (void)AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &address, ABSpeakerHardwareDevicesListener,
                                            (__bridge void *)self);
    _listening = NO;
    self.onChange = nil;
}

- (void)dealloc {
    [self stop];
}

@end

/// Speaker streaming path: `quiet` suppresses all runtime stderr. `diag` opens DEBUG events when not quiet.
static int ABRunSpeakerStreaming(ABDeviceQuery *query, NSString *optInput, NSString *optOutput, UInt32 resolvedInputID,
                                 UInt32 resolvedOutputID, BOOL quiet, BOOL diag) {
    BOOL floatingInput = (optInput == nil);
    BOOL floatingOutput = (optOutput == nil);
    BOOL inputPinned = !floatingInput;
    BOOL outputPinned = !floatingOutput;

    ABDiagSetEnabled(diag);
    ABDiagSetSessionQuiet(quiet);
    if (diag && !quiet) {
        NSMutableDictionary<NSString *, NSString *> *flags = [NSMutableDictionary dictionary];
        flags[@"diag"] = @"1";
        flags[@"quiet"] = quiet ? @"1" : @"0";
        flags[@"floating_in"] = floatingInput ? @"1" : @"0";
        flags[@"floating_out"] = floatingOutput ? @"1" : @"0";
        flags[@"resolved_in_id"] =
            inputPinned ? [NSString stringWithFormat:@"%u", (unsigned int)resolvedInputID] : @"default";
        flags[@"resolved_out_id"] =
            outputPinned ? [NSString stringWithFormat:@"%u", (unsigned int)resolvedOutputID] : @"default";
        ABDiagEmitEvent(@"cli_flags", nil, nil, nil, flags);
    }

    ABSystemDefaultIO *systemIO = [[ABSystemDefaultIO alloc] init];
    systemIO.diagEnabled = diag && !quiet;

    NSError *resolveError = nil;
    AudioDeviceID logicalIn = kAudioObjectUnknown;
    AudioDeviceID logicalOut = kAudioObjectUnknown;
    if (!ABSpeakerResolveLogicalIO(inputPinned, resolvedInputID, outputPinned, resolvedOutputID, &logicalIn,
                                   &logicalOut, &resolveError)) {
        NSString *message = resolveError.localizedDescription ?: @"Could not resolve devices.";
        const char *utf8 = message.UTF8String;
        fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "Could not resolve devices.");
        return 1;
    }

    ABAggregateDevice *aggregate = nil;
    AudioDeviceID boundID = kAudioObjectUnknown;
    NSError *bindError = nil;
    if (!ABSpeakerEstablishBinding(logicalIn, logicalOut, &aggregate, &boundID, &bindError)) {
        NSString *message = bindError.localizedDescription ?: @"Could not create Aggregate / bind devices.";
        const char *utf8 = message.UTF8String;
        ABLogError(@"%@", message);
        fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "Could not create Aggregate / bind devices.");
        return 1;
    }

    ABPassThroughEngine *passEngine = [[ABPassThroughEngine alloc] init];
    passEngine.boundDeviceID = boundID;
    [passEngine configureRecoveryWithQuiet:quiet diag:diag];
    ABRecoveryRuntimeContext *runtimeContext = [[ABRecoveryRuntimeContext alloc] init];
    ABDeviceRecoveryCoordinator *coordinator =
        [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:passEngine
                                                 sleepHandler:^(NSTimeInterval delaySeconds) {
                                                     if (runtimeContext.active) {
                                                         runtimeContext.retryDelayCount += 1;
                                                         runtimeContext.lastDelaySeconds = delaySeconds;
                                                         const char *sourceUTF8 = runtimeContext.triggerSource.UTF8String;
                                                         ABLogInfo(@"recovery trigger_source=%s attempt=%lu delay_seconds=%.1f "
                                                                   @"state=retry_wait",
                                                                   sourceUTF8 != NULL ? sourceUTF8 : "unknown",
                                                                   (unsigned long)(runtimeContext.retryDelayCount + 1),
                                                                   delaySeconds);
                                                     }
                                                     [NSThread sleepForTimeInterval:delaySeconds];
                                                 }];
    ABStreamingArmShutdownContext(systemIO, passEngine, nil);
    ABStreamingArmSpeakerDiagContext(diag, inputPinned, outputPinned);
    ABStreamingArmBindContext(aggregate, boundID, logicalIn, logicalOut, NO);

    __block BOOL heartbeatPaused = NO;
    __block BOOL configWaiting = NO;
    __block ABDeviceRecoveryCoordinator *coordinatorBlock = coordinator;
    __block ABPassThroughEngine *passEngineBlock = passEngine;
    __block ABRecoveryRuntimeContext *runtimeContextBlock = runtimeContext;
    __block ABSystemDefaultIO *systemIOBlock = systemIO;
    __block ABDeviceQuery *queryBlock = query;
    __block BOOL inputPinnedBlock = inputPinned;
    __block BOOL outputPinnedBlock = outputPinned;
    __block NSString *optInputBlock = optInput;
    __block NSString *optOutputBlock = optOutput;
    __block NSString *inputUIDBlock = inputPinned ? ABSpeakerCaptureDeviceUID(resolvedInputID) : nil;
    __block NSString *outputUIDBlock = outputPinned ? ABSpeakerCaptureDeviceUID(resolvedOutputID) : nil;
    __block UInt32 resolvedInputIDBlock = resolvedInputID;
    __block UInt32 resolvedOutputIDBlock = resolvedOutputID;
    __block ABAggregateDevice *aggregateBlock = aggregate;
    __block AudioDeviceID boundIDBlock = boundID;
    __block AudioDeviceID logicalInBlock = logicalIn;
    __block AudioDeviceID logicalOutBlock = logicalOut;
    __block NSTimeInterval lastZombieEmitTs = 0;
    __block NSMutableArray<ABSpeakerAliveWatch *> *aliveWatches = [NSMutableArray array];
    __block ABSpeakerOutputPropertyWatch *outputPropertyWatch = nil;
    __block ABSpeakerHardwareDevicesWatch *devicesWatch = nil;

    void (^installOutputPropertyWatch)(AudioDeviceID outID) = ^(AudioDeviceID outID) {
        [outputPropertyWatch stop];
        outputPropertyWatch = nil;
        if (outID == kAudioObjectUnknown) {
            return;
        }
        ABSpeakerOutputPropertyWatch *watch = [[ABSpeakerOutputPropertyWatch alloc] init];
        watch.deviceID = outID;
        watch.onMuteOrVolume = ^{
            if (!ABDiagIsEnabled()) {
                return;
            }
            ABDiagEmitEvent(@"out_mute_or_volume_change", @"hal_property_listener",
                            ABSpeakerMakeDeviceContext(systemIOBlock, inputPinnedBlock, outputPinnedBlock),
                            [passEngineBlock diagEngineContext], @{
                                @"device_id" : [NSString stringWithFormat:@"%u", (unsigned int)outID],
                            });
        };
        watch.onAlive = ^(BOOL alive) {
            if (!ABDiagIsEnabled()) {
                return;
            }
            ABDiagEmitEvent(@"device_alive_change", @"hal_property_listener",
                            ABSpeakerMakeDeviceContext(systemIOBlock, inputPinnedBlock, outputPinnedBlock),
                            [passEngineBlock diagEngineContext], @{
                                @"device_id" : [NSString stringWithFormat:@"%u", (unsigned int)outID],
                                @"alive" : alive ? @"1" : @"0",
                            });
        };
        [watch start];
        outputPropertyWatch = watch;
    };

    __block void (^onConfiguredAliveEdge)(AudioDeviceID deviceID, BOOL alive);
    __block void (^installConfiguredAliveWatches)(void);

    BOOL (^rebuildBindingAndStart)(NSString *reason) = ^BOOL(NSString *reason) {
        ABSpeakerDestroyBinding(&aggregateBlock);
        boundIDBlock = kAudioObjectUnknown;
        passEngineBlock.boundDeviceID = kAudioObjectUnknown;
        ABStreamingArmBindContext(nil, kAudioObjectUnknown, logicalInBlock, logicalOutBlock, configWaiting);
        NSError *localError = nil;
        AudioDeviceID nextIn = kAudioObjectUnknown;
        AudioDeviceID nextOut = kAudioObjectUnknown;
        if (!ABSpeakerResolveLogicalIO(inputPinnedBlock, resolvedInputIDBlock, outputPinnedBlock,
                                       resolvedOutputIDBlock, &nextIn, &nextOut, &localError)) {
            ABLogError(@"rebinding resolve failed: %@", localError.localizedDescription ?: @"unknown");
            return NO;
        }
        logicalInBlock = nextIn;
        logicalOutBlock = nextOut;
        AudioDeviceID nextBound = kAudioObjectUnknown;
        ABAggregateDevice *nextAgg = nil;
        if (!ABSpeakerEstablishBinding(nextIn, nextOut, &nextAgg, &nextBound, &localError)) {
            ABLogError(@"rebinding establish failed: %@", localError.localizedDescription ?: @"unknown");
            return NO;
        }
        aggregateBlock = nextAgg;
        boundIDBlock = nextBound;
        passEngineBlock.boundDeviceID = nextBound;
        ABStreamingArmBindContext(aggregateBlock, boundIDBlock, logicalInBlock, logicalOutBlock, configWaiting);
        NSError *startErr = nil;
        if (![passEngineBlock startWithQuiet:YES error:&startErr]) {
            ABLogError(@"rebinding engine start failed: %@", startErr.localizedDescription ?: @"unknown");
            ABSpeakerDestroyBinding(&aggregateBlock);
            boundIDBlock = kAudioObjectUnknown;
            passEngineBlock.boundDeviceID = kAudioObjectUnknown;
            ABStreamingArmBindContext(nil, kAudioObjectUnknown, logicalInBlock, logicalOutBlock, configWaiting);
            return NO;
        }
        installOutputPropertyWatch(logicalOutBlock);
        if (ABDiagIsEnabled()) {
            ABDiagEmitEvent(@"stream_reattach", reason,
                            ABSpeakerMakeDeviceContext(systemIOBlock, inputPinnedBlock, outputPinnedBlock),
                            [passEngineBlock diagEngineContext], nil);
        }
        return YES;
    };

    void (^enterConfigWait)(NSString *reason) = ^(NSString *reason) {
        if (configWaiting) {
            return;
        }
        [passEngineBlock stop];
        ABSpeakerDestroyBinding(&aggregateBlock);
        configWaiting = YES;
        g_streamingConfigWaiting = YES;
        ABStreamingArmBindContext(nil, kAudioObjectUnknown, logicalInBlock, logicalOutBlock, YES);
        if (ABDiagIsEnabled()) {
            ABDiagEmitEvent(@"config_wait", reason,
                            ABSpeakerMakeDeviceContext(systemIOBlock, inputPinnedBlock, outputPinnedBlock),
                            [passEngineBlock diagEngineContext], nil);
        }
    };

    void (^leaveConfigWaitAndReattach)(NSString *reason) = ^(NSString *reason) {
        if (!configWaiting) {
            return;
        }
        UInt32 nextInputID = resolvedInputIDBlock;
        UInt32 nextOutputID = resolvedOutputIDBlock;
        if (!ABSpeakerReresolveConfiguredIDs(queryBlock, inputPinnedBlock, optInputBlock, inputUIDBlock,
                                             &nextInputID, outputPinnedBlock, optOutputBlock, outputUIDBlock,
                                             &nextOutputID)) {
            return;
        }
        BOOL idsChanged = (nextInputID != resolvedInputIDBlock) || (nextOutputID != resolvedOutputIDBlock);
        resolvedInputIDBlock = nextInputID;
        resolvedOutputIDBlock = nextOutputID;
        if (idsChanged) {
            installConfiguredAliveWatches();
        }
        heartbeatPaused = YES;
        if (rebuildBindingAndStart(reason)) {
            configWaiting = NO;
            g_streamingConfigWaiting = NO;
            ABStreamingArmBindContext(aggregateBlock, boundIDBlock, logicalInBlock, logicalOutBlock, NO);
            if (ABDiagIsEnabled()) {
                ABDiagEmitEvent(@"config_resume", reason,
                                ABSpeakerMakeDeviceContext(systemIOBlock, inputPinnedBlock, outputPinnedBlock),
                                [passEngineBlock diagEngineContext], nil);
            }
        }
        heartbeatPaused = NO;
    };

    onConfiguredAliveEdge = ^(AudioDeviceID deviceID, BOOL alive) {
        if (ABDiagIsEnabled()) {
            ABDiagEmitEvent(@"config_device_alive_edge", @"hal_property_listener",
                            ABSpeakerMakeDeviceContext(systemIOBlock, inputPinnedBlock, outputPinnedBlock),
                            [passEngineBlock diagEngineContext], @{
                                @"device_id" : [NSString stringWithFormat:@"%u", (unsigned int)deviceID],
                                @"alive" : alive ? @"1" : @"0",
                            });
        }
        if (!alive) {
            enterConfigWait(@"configured_device_unalive");
        } else {
            leaveConfigWaitAndReattach(@"configured_device_alive");
        }
    };

    installConfiguredAliveWatches = ^{
        for (ABSpeakerAliveWatch *watch in aliveWatches) {
            [watch stop];
        }
        [aliveWatches removeAllObjects];
        if (inputPinnedBlock && resolvedInputIDBlock != kAudioObjectUnknown &&
            resolvedInputIDBlock != 0) {
            ABSpeakerAliveWatch *watch = [[ABSpeakerAliveWatch alloc] init];
            watch.deviceID = resolvedInputIDBlock;
            UInt32 watchedID = resolvedInputIDBlock;
            watch.onEdge = ^(BOOL alive) {
                onConfiguredAliveEdge(watchedID, alive);
            };
            [watch start];
            [aliveWatches addObject:watch];
        }
        if (outputPinnedBlock && resolvedOutputIDBlock != kAudioObjectUnknown &&
            resolvedOutputIDBlock != 0) {
            ABSpeakerAliveWatch *watch = [[ABSpeakerAliveWatch alloc] init];
            watch.deviceID = resolvedOutputIDBlock;
            UInt32 watchedID = resolvedOutputIDBlock;
            watch.onEdge = ^(BOOL alive) {
                onConfiguredAliveEdge(watchedID, alive);
            };
            [watch start];
            [aliveWatches addObject:watch];
        }
    };

    installConfiguredAliveWatches();

    void (^onHardwareOrDefaultChange)(NSString *reason) = ^(NSString *reason) {
        if (configWaiting) {
            leaveConfigWaitAndReattach(reason);
            return;
        }
        UInt32 nextInputID = resolvedInputIDBlock;
        UInt32 nextOutputID = resolvedOutputIDBlock;
        if ((inputPinnedBlock || outputPinnedBlock) &&
            !ABSpeakerReresolveConfiguredIDs(queryBlock, inputPinnedBlock, optInputBlock, inputUIDBlock,
                                             &nextInputID, outputPinnedBlock, optOutputBlock, outputUIDBlock,
                                             &nextOutputID)) {
            if (inputPinnedBlock) {
                enterConfigWait(@"configured_input_missing_on_device_change");
            } else {
                enterConfigWait(@"configured_output_missing_on_device_change");
            }
            return;
        }
        BOOL stickyIdsChanged = NO;
        if (inputPinnedBlock && nextInputID != resolvedInputIDBlock) {
            resolvedInputIDBlock = nextInputID;
            stickyIdsChanged = YES;
        }
        if (outputPinnedBlock && nextOutputID != resolvedOutputIDBlock) {
            resolvedOutputIDBlock = nextOutputID;
            stickyIdsChanged = YES;
        }
        if (stickyIdsChanged) {
            installConfiguredAliveWatches();
        }
        NSError *logicalError = nil;
        AudioDeviceID nextLogicalIn = kAudioObjectUnknown;
        AudioDeviceID nextLogicalOut = kAudioObjectUnknown;
        if (!ABSpeakerResolveLogicalIO(inputPinnedBlock, resolvedInputIDBlock, outputPinnedBlock,
                                       resolvedOutputIDBlock, &nextLogicalIn, &nextLogicalOut, &logicalError)) {
            ABLogError(@"hardware change logical resolve failed: %@",
                       logicalError.localizedDescription ?: @"unknown");
            enterConfigWait(@"logical_io_unresolved_on_device_change");
            return;
        }
        // Logical identity unchanged (configured sticky ids and/or current defaults): keep the live binding.
        if (nextLogicalIn == logicalInBlock && nextLogicalOut == logicalOutBlock) {
            return;
        }
        if (ABDiagIsEnabled()) {
            ABDiagEmitEvent(@"main_rebind", reason,
                            ABSpeakerMakeDeviceContext(systemIOBlock, inputPinnedBlock, outputPinnedBlock),
                            [passEngineBlock diagEngineContext], nil);
        }
        heartbeatPaused = YES;
        [passEngineBlock stop];
        if (!rebuildBindingAndStart(reason)) {
            enterConfigWait(@"rebind_failed_on_device_change");
        }
        heartbeatPaused = NO;
    };

    devicesWatch = [[ABSpeakerHardwareDevicesWatch alloc] init];
    devicesWatch.onChange = ^{
        // USB re-enumeration only matters when a configured side must rematch by string/UID,
        // or when already in config-wait awaiting that rematch.
        if (configWaiting || inputPinnedBlock || outputPinnedBlock) {
            onHardwareOrDefaultChange(@"devices_list_change");
        }
    };
    [devicesWatch start];

    [systemIO registerForFloatingInput:floatingInput
                      floatingOutput:floatingOutput
                        rebuildBlock:^{
                            onHardwareOrDefaultChange(@"listener_default_change");
                        }];

    ABSpeakerMaybeWarnBuiltInFeedback(query, inputPinned, resolvedInputID, outputPinned, resolvedOutputID, quiet);

    NSError *startError = nil;
    // First start must use coordinator so compensation enables after success.
    // Bound device was already set on the engine.
    if (![coordinator startWithError:&startError]) {
        if (ABDiagIsEnabled()) {
            NSMutableDictionary<NSString *, NSString *> *extra = [NSMutableDictionary dictionary];
            if (startError != nil) {
                extra[@"error_domain"] = startError.domain ?: @"";
                extra[@"error_code"] = [NSString stringWithFormat:@"%ld", (long)startError.code];
            }
            ABDiagEmitEvent(@"stream_start_failed", nil,
                            ABSpeakerMakeDeviceContext(systemIO, inputPinned, outputPinned),
                            [passEngine diagEngineContext], extra);
        }
        NSString *message = startError.localizedDescription ?: @"Engine start failed.";
        const char *utf8 = message.UTF8String;
        fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "Engine start failed.");
        [devicesWatch stop];
        ABShutdownStreaming();
        return 1;
    }
    if (ABDiagIsEnabled()) {
        ABDiagEmitEvent(@"stream_started", nil, ABSpeakerMakeDeviceContext(systemIO, inputPinned, outputPinned),
                        [passEngine diagEngineContext], nil);
    }
    installOutputPropertyWatch(logicalOut);

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
                                                           BOOL active = [passEngineBlock ab_isActive];
                                                           BOOL running = [passEngineBlock diagEngineIsRunning];
                                                           if (ABDiagIsEnabled() && active && !running) {
                                                               NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                                                               if (now - lastZombieEmitTs >= 5.0) {
                                                                   lastZombieEmitTs = now;
                                                                   ABDiagEmitEvent(
                                                                       @"zombie_active_edge", nil,
                                                                       ABSpeakerMakeDeviceContext(systemIOBlock,
                                                                                                  inputPinnedBlock,
                                                                                                  outputPinnedBlock),
                                                                       [passEngineBlock diagEngineContext], nil);
                                                               }
                                                           }
                                                           if (!active) {
                                                               if (ABSpeakerConfigWaitSuppressesRecovery(
                                                                       configWaiting || g_streamingConfigWaiting)) {
                                                                   return;
                                                               }
                                                               if (ABDiagIsEnabled()) {
                                                                   ABDiagEmitSnapshot(
                                                                       @"heartbeat_inactive", @"heartbeat_inactive",
                                                                       ABSpeakerMakeDeviceContext(systemIOBlock,
                                                                                                  inputPinnedBlock,
                                                                                                  outputPinnedBlock),
                                                                       [passEngineBlock diagEngineContext], nil);
                                                               }
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

    for (ABSpeakerAliveWatch *watch in aliveWatches) {
        [watch stop];
    }
    [outputPropertyWatch stop];
    outputPropertyWatch = nil;
    [devicesWatch stop];
    devicesWatch = nil;
    [heartbeatTimer invalidate];
    [wakeTimer invalidate];
    ABShutdownStreaming();
    ABDiagSetEnabled(NO);
    ABDiagSetSessionQuiet(NO);
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

    ABDiagSetSessionQuiet(quiet);

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
                                                         ABLogInfo(@"recovery trigger_source=%s attempt=%lu delay_seconds=%.1f "
                                                                   @"state=retry_wait",
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
    ABDiagSetSessionQuiet(NO);
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
                                       BOOL *outDiag, NSString *__autoreleasing *outOptInput,
                                       NSString *__autoreleasing *outOptOutput, NSString *__autoreleasing *outOptRate) {
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
    BOOL diag = NO;
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
    while ((ch = getopt_long((int)argc, cargv, "hfi:o:r:qd", longopts, NULL)) != -1) {
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
            case 'd':
                diag = YES;
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
    *outDiag = diag;
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
    fputs("  -q, --quiet             Suppress all runtime stderr while streaming (overrides -d); no effect with -h or "
          "--list-all.\n",
          fp);
    fputs("  -d                      Enable DEBUG event-driven speaker diagnostics on stderr (overridden by -q).\n",
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
        BOOL diag = NO;
        NSString *optInput = nil;
        NSString *optOutput = nil;
        NSString *optRate = nil;

        int parseExit = ABParseOptionsFromArguments(arguments, &wantHelp, &listAll, &integrationRecoveryLifecycle,
                                                    &force, &quiet, &diag, &optInput, &optOutput, &optRate);
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
            (void)diag;
            return ABRunStdoutPCMStreaming(optInput, resolvedInputID, optRate, quiet, (optInput == nil));
        }

        return ABRunSpeakerStreaming(query, optInput, optOutput, resolvedInputID, resolvedOutputID, quiet, diag);
    }
}
