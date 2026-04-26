#import "ABPassThroughEngine.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>

NSString *const ABPassThroughEngineErrorDomain = @"ABPassThroughEngineError";

static NSError *ABPassThroughBuildAdapterError(NSInteger code, NSString *operation, NSString *message) {
    return [NSError errorWithDomain:ABPassThroughEngineErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey : message,
                               @"operation" : operation,
                           }];
}

static BOOL ABPassThroughEnsureStructuredErrorOnFailure(BOOL succeeded, NSError **error, NSInteger fallbackCode,
                                                        NSString *operation, NSString *message) {
    if (succeeded) {
        return YES;
    }
    if (error != NULL && *error == nil) {
        *error = ABPassThroughBuildAdapterError(fallbackCode, operation, message);
    }
    return NO;
}

static BOOL ABPassThroughGetDefaultOutputDevice(AudioDeviceID *outID) {
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 size = (UInt32)sizeof(deviceID);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &deviceID);
    if (st != noErr) {
        return NO;
    }
    *outID = deviceID;
    return YES;
}

static void ABPassThroughLogSpeakerPathDiagnostics(AVAudioEngine *engine, BOOL quiet) {
    if (quiet || engine == nil) {
        return;
    }

    AudioDeviceID deviceID = kAudioObjectUnknown;
    if (!ABPassThroughGetDefaultOutputDevice(&deviceID)) {
        fprintf(stderr, "[audiobridge] speaker path: unable to read default output device\n");
        return;
    }

    NSString *name = @"(unknown)";
    {
        AudioObjectPropertyAddress nameAddr = {
            .mSelector = kAudioDevicePropertyDeviceNameCFString,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain,
        };
        CFStringRef nameRef = NULL;
        UInt32 nameSize = (UInt32)sizeof(nameRef);
        OSStatus st = AudioObjectGetPropertyData(deviceID, &nameAddr, 0, NULL, &nameSize, &nameRef);
        if (st == noErr && nameRef != NULL) {
            name = (__bridge_transfer NSString *)nameRef;
        }
    }

    double nominalHz = 0;
    BOOL haveNominal = NO;
    {
        AudioObjectPropertyAddress rateAddr = {
            .mSelector = kAudioDevicePropertyNominalSampleRate,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain,
        };
        Float64 nominal = 0;
        UInt32 rateSize = (UInt32)sizeof(nominal);
        OSStatus st = AudioObjectGetPropertyData(deviceID, &rateAddr, 0, NULL, &rateSize, &nominal);
        if (st == noErr) {
            nominalHz = nominal;
            haveNominal = YES;
        }
    }

    UInt32 caOutChannels = 0;
    BOOL haveChannels = NO;
    {
        AudioObjectPropertyAddress cfgAddr = {
            .mSelector = kAudioDevicePropertyStreamConfiguration,
            .mScope = kAudioObjectPropertyScopeOutput,
            .mElement = kAudioObjectPropertyElementMain,
        };
        UInt32 dataSize = 0;
        OSStatus st = AudioObjectGetPropertyDataSize(deviceID, &cfgAddr, 0, NULL, &dataSize);
        if (st == noErr && dataSize >= sizeof(AudioBufferList)) {
            UInt8 *bytes = (UInt8 *)calloc(1, (size_t)dataSize);
            if (bytes != NULL) {
                st = AudioObjectGetPropertyData(deviceID, &cfgAddr, 0, NULL, &dataSize, bytes);
                if (st == noErr) {
                    const AudioBufferList *list = (const AudioBufferList *)bytes;
                    UInt32 total = 0;
                    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
                        total += list->mBuffers[i].mNumberChannels;
                    }
                    caOutChannels = total;
                    haveChannels = YES;
                }
                free(bytes);
            }
        }
    }

    AVAudioFormat *outFmt = [engine.outputNode outputFormatForBus:0];
    double avSr = outFmt.sampleRate;
    AVAudioChannelCount avCh = outFmt.channelCount;

    NSString *line = [NSString
        stringWithFormat:
            @"[audiobridge] speaker path: default_output_id=%u name=%@ nominal_sample_rate_hz=%@ "
            @"ca_output_stream_channels=%@ av_output_format_sample_rate_hz=%.0f av_output_format_channels=%u",
            (unsigned int)deviceID,
            name,
            haveNominal ? [NSString stringWithFormat:@"%.0f", nominalHz] : @"?",
            haveChannels ? [NSString stringWithFormat:@"%u", (unsigned int)caOutChannels] : @"?",
            avSr,
            (unsigned int)avCh];
    const char *utf8 = line.UTF8String;
    fprintf(stderr, "%s\n", utf8 != NULL ? utf8 : "[audiobridge] speaker path: (encoding error)");
}

@implementation ABPassThroughEngine {
    AVAudioEngine *_currentEngine;
    NSUInteger _recoveryRebuildAttemptCount;
    BOOL _configuredQuiet;
    BOOL _hasConfiguredRuntimeParameters;
}

- (BOOL)ab_connectPrepareStartEngine:(AVAudioEngine *)engine error:(NSError **)error {
    AVAudioInputNode *input = engine.inputNode;
    AVAudioMixerNode *mixer = engine.mainMixerNode;
    [engine connect:input to:mixer format:nil];
    mixer.outputVolume = 1.0;
    [engine prepare];
    NSError *local = nil;
    if (![engine startAndReturnError:&local]) {
        if (error) {
            *error = local;
        }
        return NO;
    }
    return YES;
}

- (BOOL)startWithError:(NSError **)error {
    return [self startWithQuiet:NO error:error];
}

- (BOOL)startWithQuiet:(BOOL)quiet error:(NSError **)error {
    _configuredQuiet = quiet;
    _hasConfiguredRuntimeParameters = YES;
    [self stop];
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    if (![self ab_connectPrepareStartEngine:engine error:error]) {
        return NO;
    }
    _currentEngine = engine;
    ABPassThroughLogSpeakerPathDiagnostics(engine, quiet);
    return YES;
}

- (void)configureRecoveryWithQuiet:(BOOL)quiet {
    _configuredQuiet = quiet;
    _hasConfiguredRuntimeParameters = YES;
}

- (void)stop {
    AVAudioEngine *engine = _currentEngine;
    if (engine == nil) {
        return;
    }
    [engine stop];
    _currentEngine = nil;
}

- (BOOL)rebuildForRouteChangeWithQuiet:(BOOL)quiet error:(NSError **)error {
    AVAudioEngine *previous = _currentEngine;
    NSDate *t0 = [NSDate date];
    if (previous != nil) {
        [previous stop];
        _currentEngine = nil;
    }
    NSTimeInterval stopSeconds = [[NSDate date] timeIntervalSinceDate:t0];
    long long stopWallMs = (long long)llround(stopSeconds * 1000.0);
    if (!quiet) {
        fprintf(stderr, "[audiobridge] route rebuild: stop_wall_ms=%lld\n", stopWallMs);
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    if (![self ab_connectPrepareStartEngine:engine error:error]) {
        return NO;
    }
    _currentEngine = engine;
    ABPassThroughLogSpeakerPathDiagnostics(engine, quiet);
    return YES;
}

- (BOOL)ab_start:(NSError **)error {
    BOOL quiet = _hasConfiguredRuntimeParameters ? _configuredQuiet : NO;
    BOOL started = [self startWithQuiet:quiet error:error];
    return ABPassThroughEnsureStructuredErrorOnFailure(started, error, 1001, @"ab_start",
                                                       @"Pass-through adapter start failed.");
}

- (BOOL)ab_rebuild:(NSError **)error {
    _recoveryRebuildAttemptCount += 1;
    BOOL quiet = _hasConfiguredRuntimeParameters ? _configuredQuiet : NO;
    BOOL rebuilt = [self rebuildForRouteChangeWithQuiet:quiet error:error];
    return ABPassThroughEnsureStructuredErrorOnFailure(rebuilt, error, 1002, @"ab_rebuild",
                                                       @"Pass-through adapter rebuild failed.");
}

- (void)ab_stop {
    [self stop];
}

- (BOOL)ab_isActive {
    return _currentEngine != nil;
}

- (NSUInteger)recoveryRebuildAttemptCount {
    return _recoveryRebuildAttemptCount;
}

@end
