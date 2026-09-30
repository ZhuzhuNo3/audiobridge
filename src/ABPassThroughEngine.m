#import "ABPassThroughEngine.h"

#import "ABDiagSnapshot.h"
#import "ABHALPassThroughIO.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
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

static NSString *ABPassThroughDeviceName(AudioDeviceID deviceID) {
    if (deviceID == kAudioObjectUnknown) {
        return @"(unknown)";
    }
    AudioObjectPropertyAddress nameAddr = {
        .mSelector = kAudioDevicePropertyDeviceNameCFString,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    CFStringRef nameRef = NULL;
    UInt32 nameSize = (UInt32)sizeof(nameRef);
    OSStatus st = AudioObjectGetPropertyData(deviceID, &nameAddr, 0, NULL, &nameSize, &nameRef);
    if (st == noErr && nameRef != NULL) {
        return (__bridge_transfer NSString *)nameRef;
    }
    return @"(unknown)";
}

static BOOL ABPassThroughReadUnitCurrentDevice(AudioUnit unit, AudioDeviceID *outID) {
    if (unit == NULL || outID == NULL) {
        return NO;
    }
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 size = (UInt32)sizeof(deviceID);
    OSStatus st = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, &size);
    if (st != noErr) {
        return NO;
    }
    *outID = deviceID;
    return YES;
}

static BOOL ABPassThroughSetUnitCurrentDevice(AudioUnit unit, AudioDeviceID deviceID, OSStatus *outStatus) {
    if (unit == NULL) {
        if (outStatus != NULL) {
            *outStatus = kAudioUnitErr_FailedInitialization;
        }
        return NO;
    }
    OSStatus st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, (UInt32)sizeof(deviceID));
    if (outStatus != NULL) {
        *outStatus = st;
    }
    return st == noErr;
}

static void ABPassThroughLogSpeakerPathDiagnostics(AVAudioEngine *engine, BOOL quiet, AudioDeviceID intentDeviceID) {
    if (quiet || engine == nil) {
        return;
    }

    AudioDeviceID actualOut = kAudioObjectUnknown;
    AudioDeviceID actualIn = kAudioObjectUnknown;
    BOOL haveActualOut = ABPassThroughReadUnitCurrentDevice(engine.outputNode.audioUnit, &actualOut);
    BOOL haveActualIn = ABPassThroughReadUnitCurrentDevice(engine.inputNode.audioUnit, &actualIn);

    AudioDeviceID deviceID = kAudioObjectUnknown;
    if (haveActualOut) {
        deviceID = actualOut;
    } else if (haveActualIn) {
        deviceID = actualIn;
    } else if (intentDeviceID != kAudioObjectUnknown) {
        deviceID = intentDeviceID;
    } else if (!ABPassThroughGetDefaultOutputDevice(&deviceID)) {
        ABLogInfo(@"speaker path: unable to read actual or default output device");
        return;
    }

    NSString *name = ABPassThroughDeviceName(deviceID);

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

    ABLogInfo(@"speaker path: bound_device_id=%u actual_out_device_id=%@ actual_in_device_id=%@ "
              @"actual_device_name=%@ nominal_sample_rate_hz=%@ ca_output_stream_channels=%@ "
              @"av_output_format_sample_rate_hz=%.0f av_output_format_channels=%u",
              (unsigned int)intentDeviceID,
              haveActualOut ? [NSString stringWithFormat:@"%u", (unsigned int)actualOut] : @"unread",
              haveActualIn ? [NSString stringWithFormat:@"%u", (unsigned int)actualIn] : @"unread", name,
              haveNominal ? [NSString stringWithFormat:@"%.0f", nominalHz] : @"?",
              haveChannels ? [NSString stringWithFormat:@"%u", (unsigned int)caOutChannels] : @"?", avSr,
              (unsigned int)avCh);
}

@implementation ABPassThroughEngine {
    AVAudioEngine *_currentEngine;
    ABHALPassThroughIO *_halIO;
    NSUInteger _recoveryRebuildAttemptCount;
    BOOL _configuredQuiet;
    BOOL _configuredDiag;
    BOOL _hasConfiguredRuntimeParameters;
    NSUInteger _configChangeSeq;
    NSUInteger _rebuildSeq;
    NSTimeInterval _configChangeUnixTs;
    NSTimeInterval _rebuildUnixTs;
    id _configChangeObserver;
    AudioDeviceID _boundDeviceID;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _boundDeviceID = kAudioObjectUnknown;
    }
    return self;
}

- (AudioDeviceID)boundDeviceID {
    return _boundDeviceID;
}

- (void)setBoundDeviceID:(AudioDeviceID)boundDeviceID {
    _boundDeviceID = boundDeviceID;
}

- (ABDiagEngineContext *)ab_diagEngineContext {
    ABDiagEngineContext *ctx = [[ABDiagEngineContext alloc] init];
    ctx.engine = _currentEngine;
    ctx.halAudioUnit = _halIO.audioUnit;
    ctx.halIsRunning = _halIO.isRunning;
    ctx.abIsActive = (_currentEngine != nil) || (_halIO != nil && _halIO.isRunning);
    ctx.rebuildAttemptCount = _recoveryRebuildAttemptCount;
    ctx.configChangeSeq = _configChangeSeq;
    ctx.rebuildSeq = _rebuildSeq;
    ctx.configChangeUnixTs = _configChangeUnixTs;
    ctx.rebuildUnixTs = _rebuildUnixTs;
    return ctx;
}

- (ABDiagEngineContext *)diagEngineContext {
    return [self ab_diagEngineContext];
}

- (BOOL)diagEngineIsRunning {
    if (_halIO != nil) {
        return _halIO.isRunning;
    }
    return _currentEngine != nil && _currentEngine.isRunning;
}

- (void)ab_tearDownConfigChangeObserver {
    if (_configChangeObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:_configChangeObserver];
        _configChangeObserver = nil;
    }
}

- (void)ab_installConfigChangeObserverForEngine:(AVAudioEngine *)engine {
    [self ab_tearDownConfigChangeObserver];
    if (!_configuredDiag || engine == nil) {
        return;
    }
    __weak ABPassThroughEngine *weakSelf = self;
    _configChangeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioEngineConfigurationChangeNotification
                    object:engine
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
                    ABPassThroughEngine *strongSelf = weakSelf;
                    if (strongSelf == nil) {
                        return;
                    }
                    strongSelf->_configChangeSeq += 1;
                    strongSelf->_configChangeUnixTs = [[NSDate date] timeIntervalSince1970];
                    ABDiagEmitEvent(@"config_change", @"engine_configuration_change", nil,
                                    [strongSelf ab_diagEngineContext], @{
                                        @"config_change_seq" :
                                            [NSString stringWithFormat:@"%lu", (unsigned long)strongSelf->_configChangeSeq],
                                    });
                }];
}

static void ABPassThroughLogHALPathDiagnostics(ABHALPassThroughIO *halIO, BOOL quiet, AudioDeviceID intentDeviceID) {
    if (quiet || halIO == nil) {
        return;
    }
    AudioDeviceID actual = kAudioObjectUnknown;
    BOOL haveActual = [halIO readCurrentDeviceID:&actual];
    AudioDeviceID deviceID = haveActual ? actual : intentDeviceID;
    NSString *name = ABPassThroughDeviceName(deviceID);

    double nominalHz = 0;
    BOOL haveNominal = NO;
    if (deviceID != kAudioObjectUnknown) {
        AudioObjectPropertyAddress rateAddr = {
            .mSelector = kAudioDevicePropertyNominalSampleRate,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain,
        };
        Float64 nominal = 0;
        UInt32 rateSize = (UInt32)sizeof(nominal);
        if (AudioObjectGetPropertyData(deviceID, &rateAddr, 0, NULL, &rateSize, &nominal) == noErr) {
            nominalHz = nominal;
            haveNominal = YES;
        }
    }

    ABLogInfo(@"speaker path: io_transport=hal bound_device_id=%u actual_out_device_id=%@ actual_in_device_id=%@ "
              @"actual_device_name=%@ nominal_sample_rate_hz=%@ hal_running=%d",
              (unsigned int)intentDeviceID,
              haveActual ? [NSString stringWithFormat:@"%u", (unsigned int)actual] : @"unread",
              haveActual ? [NSString stringWithFormat:@"%u", (unsigned int)actual] : @"unread", name,
              haveNominal ? [NSString stringWithFormat:@"%.0f", nominalHz] : @"?", halIO.isRunning);
}

- (void)ab_noteSuccessfulStartOrRebuildWithReason:(NSString *)reason
                                       stopWallMs:(NSNumber *)stopWallMs
                                            quiet:(BOOL)quiet {
    _rebuildSeq += 1;
    _rebuildUnixTs = [[NSDate date] timeIntervalSince1970];
    if (_configuredDiag) {
        NSMutableDictionary<NSString *, NSString *> *extra = [NSMutableDictionary dictionary];
        if (stopWallMs != nil) {
            extra[@"stop_wall_ms"] = [NSString stringWithFormat:@"%lld", (long long)stopWallMs.longLongValue];
        }
        if (_halIO != nil) {
            extra[@"io_transport"] = @"hal";
        } else {
            extra[@"io_transport"] = @"avaudioengine";
        }
        ABDiagEmitEvent(reason, nil, nil, [self ab_diagEngineContext], extra);
    }
    if (_halIO != nil) {
        ABPassThroughLogHALPathDiagnostics(_halIO, quiet, _boundDeviceID);
    } else {
        ABPassThroughLogSpeakerPathDiagnostics(_currentEngine, quiet, _boundDeviceID);
    }
}

/// Reads back AudioUnit CurrentDevice on both I/O sides and requires match to `intentID`.
- (BOOL)ab_verifyActualCurrentDevice:(AudioDeviceID)intentID
                            onEngine:(AVAudioEngine *)engine
                               error:(NSError **)error {
    AudioUnit outputUnit = engine.outputNode.audioUnit;
    AudioUnit inputUnit = engine.inputNode.audioUnit;

    AudioDeviceID actualOut = kAudioObjectUnknown;
    AudioDeviceID actualIn = kAudioObjectUnknown;
    BOOL haveOut = ABPassThroughReadUnitCurrentDevice(outputUnit, &actualOut);
    BOOL haveIn = ABPassThroughReadUnitCurrentDevice(inputUnit, &actualIn);

    if (!haveOut) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(
                1107, @"device_bind", @"Unable to read back output AudioUnit CurrentDevice after bind.");
        }
        ABLogError(@"device_bind_failed side=output reason=readback_failed bound_device_id=%u",
                   (unsigned int)intentID);
        return NO;
    }
    if (actualOut != intentID) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(
                1108, @"device_bind",
                [NSString stringWithFormat:
                              @"Output CurrentDevice mismatch: intent=%u actual=%u.",
                          (unsigned int)intentID, (unsigned int)actualOut]);
        }
        ABLogError(@"device_bind_mismatch side=output bound_device_id=%u actual_device_id=%u actual_name=%@",
                   (unsigned int)intentID, (unsigned int)actualOut, ABPassThroughDeviceName(actualOut));
        return NO;
    }

    if (inputUnit == NULL) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(1103, @"device_bind",
                                                    @"Input AudioUnit unavailable for CurrentDevice bind.");
        }
        ABLogError(@"device_bind_failed side=input reason=missing_audio_unit device_id=%u",
                   (unsigned int)intentID);
        return NO;
    }
    if (!haveIn) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(
                1109, @"device_bind", @"Unable to read back input AudioUnit CurrentDevice after bind.");
        }
        ABLogError(@"device_bind_failed side=input reason=readback_failed bound_device_id=%u",
                   (unsigned int)intentID);
        return NO;
    }
    if (actualIn != intentID) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(
                1110, @"device_bind",
                [NSString stringWithFormat:
                              @"Input CurrentDevice mismatch: intent=%u actual=%u.",
                          (unsigned int)intentID, (unsigned int)actualIn]);
        }
        ABLogError(@"device_bind_mismatch side=input bound_device_id=%u actual_device_id=%u actual_name=%@",
                   (unsigned int)intentID, (unsigned int)actualIn, ABPassThroughDeviceName(actualIn));
        return NO;
    }

    if (actualOut != actualIn) {
        ABLogWarn(@"device_bind_sides_differ bound_device_id=%u actual_out=%u actual_in=%u",
                  (unsigned int)intentID, (unsigned int)actualOut, (unsigned int)actualIn);
    }
    return YES;
}

/// Set CurrentDevice on every AU used, then read back and require intent match.
/// Same AU and distinct AU paths both re-affirm; never skip input bind when units coincide.
- (BOOL)ab_applyBoundDeviceOnEngine:(AVAudioEngine *)engine error:(NSError **)error {
    if (_boundDeviceID == kAudioObjectUnknown) {
        return YES;
    }
    AudioDeviceID deviceID = _boundDeviceID;

    // Output first, then input: shared-AU duplex formats refresh when input is materialized.
    // Always re-set after input materialization — even when inputUnit == outputUnit — because
    // accessing inputNode can reset a shared AU back to the system default device.
    (void)engine.outputNode;
    AudioUnit outputUnit = engine.outputNode.audioUnit;
    if (outputUnit == NULL) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(1101, @"device_bind",
                                                    @"Output AudioUnit unavailable for CurrentDevice bind.");
        }
        ABLogError(@"device_bind_failed side=output reason=missing_audio_unit device_id=%u",
                   (unsigned int)deviceID);
        return NO;
    }

    OSStatus outSt = noErr;
    if (!ABPassThroughSetUnitCurrentDevice(outputUnit, deviceID, &outSt)) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(
                1102, @"device_bind",
                [NSString stringWithFormat:@"Failed to bind output CurrentDevice id=%u (status=%d).",
                                           (unsigned int)deviceID, (int)outSt]);
        }
        ABLogError(@"device_bind_failed side=output device_id=%u status=%d", (unsigned int)deviceID, (int)outSt);
        return NO;
    }

    (void)engine.inputNode;
    AudioUnit inputUnit = engine.inputNode.audioUnit;
    if (inputUnit == NULL) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(1103, @"device_bind",
                                                    @"Input AudioUnit unavailable for CurrentDevice bind.");
        }
        ABLogError(@"device_bind_failed side=input reason=missing_audio_unit device_id=%u",
                   (unsigned int)deviceID);
        return NO;
    }

    OSStatus inSt = noErr;
    if (!ABPassThroughSetUnitCurrentDevice(inputUnit, deviceID, &inSt)) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(
                1104, @"device_bind",
                [NSString stringWithFormat:@"Failed to bind input CurrentDevice id=%u (status=%d).",
                                           (unsigned int)deviceID, (int)inSt]);
        }
        ABLogError(@"device_bind_failed side=input device_id=%u status=%d", (unsigned int)deviceID, (int)inSt);
        return NO;
    }

    return [self ab_verifyActualCurrentDevice:deviceID onEngine:engine error:error];
}

- (void)ab_emitDeviceBindOkOnEngine:(AVAudioEngine *)engine {
    if (!_configuredDiag || _boundDeviceID == kAudioObjectUnknown) {
        return;
    }
    AudioDeviceID actualOut = kAudioObjectUnknown;
    AudioDeviceID actualIn = kAudioObjectUnknown;
    BOOL haveOut = ABPassThroughReadUnitCurrentDevice(engine.outputNode.audioUnit, &actualOut);
    BOOL haveIn = ABPassThroughReadUnitCurrentDevice(engine.inputNode.audioUnit, &actualIn);
    NSMutableDictionary<NSString *, NSString *> *extra = [NSMutableDictionary dictionary];
    extra[@"bound_device_id"] = [NSString stringWithFormat:@"%u", (unsigned int)_boundDeviceID];
    extra[@"actual_out_device_id"] =
        haveOut ? [NSString stringWithFormat:@"%u", (unsigned int)actualOut] : @"unread";
    extra[@"actual_in_device_id"] =
        haveIn ? [NSString stringWithFormat:@"%u", (unsigned int)actualIn] : @"unread";
    if (haveOut) {
        extra[@"actual_out_device_name"] = ABPassThroughDeviceName(actualOut);
    }
    if (haveIn) {
        extra[@"actual_in_device_name"] = ABPassThroughDeviceName(actualIn);
    }
    if (haveOut && haveIn && actualOut == actualIn) {
        extra[@"actual_device_id"] = [NSString stringWithFormat:@"%u", (unsigned int)actualOut];
        extra[@"actual_device_name"] = ABPassThroughDeviceName(actualOut);
    }
    ABDiagEmitEvent(@"device_bind_ok", nil, nil, [self ab_diagEngineContext], extra);
}

- (void)ab_emitDeviceBindOkOnHAL:(ABHALPassThroughIO *)halIO {
    if (!_configuredDiag || _boundDeviceID == kAudioObjectUnknown || halIO == nil) {
        return;
    }
    AudioDeviceID actual = kAudioObjectUnknown;
    BOOL haveActual = [halIO readCurrentDeviceID:&actual];
    NSMutableDictionary<NSString *, NSString *> *extra = [NSMutableDictionary dictionary];
    extra[@"bound_device_id"] = [NSString stringWithFormat:@"%u", (unsigned int)_boundDeviceID];
    extra[@"io_transport"] = @"hal";
    if (haveActual) {
        NSString *idStr = [NSString stringWithFormat:@"%u", (unsigned int)actual];
        extra[@"actual_out_device_id"] = idStr;
        extra[@"actual_in_device_id"] = idStr;
        extra[@"actual_device_id"] = idStr;
        extra[@"actual_out_device_name"] = ABPassThroughDeviceName(actual);
        extra[@"actual_in_device_name"] = ABPassThroughDeviceName(actual);
        extra[@"actual_device_name"] = ABPassThroughDeviceName(actual);
    } else {
        extra[@"actual_out_device_id"] = @"unread";
        extra[@"actual_in_device_id"] = @"unread";
    }
    ABDiagEmitEvent(@"device_bind_ok", nil, nil, [self ab_diagEngineContext], extra);
}

- (BOOL)ab_startHALPassThroughWithError:(NSError **)error {
    ABHALPassThroughIO *halIO = [[ABHALPassThroughIO alloc] init];
    if (![halIO startWithDeviceID:_boundDeviceID error:error]) {
        ABLogError(@"engine_start_failed reason=hal_aggregate_io bound_device_id=%u",
                   (unsigned int)_boundDeviceID);
        return NO;
    }
    AudioDeviceID actual = kAudioObjectUnknown;
    if (![halIO readCurrentDeviceID:&actual] || actual != _boundDeviceID) {
        [halIO stop];
        if (error) {
            *error = ABPassThroughBuildAdapterError(
                1112, @"device_bind",
                [NSString stringWithFormat:@"HAL Aggregate CurrentDevice mismatch intent=%u actual=%u.",
                                           (unsigned int)_boundDeviceID, (unsigned int)actual]);
        }
        ABLogError(@"device_bind_mismatch side=hal bound_device_id=%u actual_device_id=%u",
                   (unsigned int)_boundDeviceID, (unsigned int)actual);
        return NO;
    }
    if (!halIO.isRunning) {
        [halIO stop];
        if (error) {
            *error = ABPassThroughBuildAdapterError(
                1111, @"engine_start", @"HAL Aggregate I/O inactive after start; refusing zombie active state.");
        }
        ABLogError(@"engine_start_failed reason=hal_inactive_after_start bound_device_id=%u",
                   (unsigned int)_boundDeviceID);
        return NO;
    }
    _halIO = halIO;
    [self ab_emitDeviceBindOkOnHAL:halIO];
    return YES;
}

- (BOOL)ab_bindCurrentDeviceOnEngine:(AVAudioEngine *)engine error:(NSError **)error {
    if (![self ab_applyBoundDeviceOnEngine:engine error:error]) {
        return NO;
    }
    [self ab_emitDeviceBindOkOnEngine:engine];
    return YES;
}

static AVAudioFormat *ABPassThroughFormatFromAudioUnit(AudioUnit unit, AudioUnitScope scope, AudioUnitElement element) {
    if (unit == NULL) {
        return nil;
    }
    AudioStreamBasicDescription asbd = {0};
    UInt32 size = (UInt32)sizeof(asbd);
    OSStatus st = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &asbd, &size);
    if (st != noErr || asbd.mSampleRate <= 0 || asbd.mChannelsPerFrame == 0) {
        return nil;
    }
    return [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
}

- (BOOL)ab_connectPrepareStartEngine:(AVAudioEngine *)engine error:(NSError **)error {
    // Duplex AV path: warm-start on the engine's initial I/O device, then stop / re-init /
    // apply CurrentDevice with readback so the same-device bind sticks after materialization.
    AVAudioInputNode *input = engine.inputNode;
    AVAudioMixerNode *mixer = engine.mainMixerNode;

    AVAudioFormat *inFormat = ABPassThroughFormatFromAudioUnit(input.audioUnit, kAudioUnitScope_Output, 1);
    if (inFormat == nil) {
        inFormat = [input inputFormatForBus:0];
    }
    if (inFormat == nil || inFormat.sampleRate <= 0 || inFormat.channelCount == 0) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(1105, @"engine_start",
                                                    @"Input node format unavailable after device bind.");
        }
        ABLogError(@"engine_start_failed reason=invalid_input_format bound_device_id=%u",
                   (unsigned int)_boundDeviceID);
        return NO;
    }

    AVAudioFormat *canonical =
        [[AVAudioFormat alloc] initStandardFormatWithSampleRate:inFormat.sampleRate channels:inFormat.channelCount];
    if (canonical != nil) {
        inFormat = canonical;
    }

    @try {
        [engine connect:input to:mixer format:inFormat];
    } @catch (NSException *exception) {
        @try {
            [engine connect:input to:mixer format:nil];
        } @catch (NSException *inner) {
            if (error) {
                *error = ABPassThroughBuildAdapterError(
                    1106, @"engine_start",
                    [NSString stringWithFormat:@"Engine connect failed after bind: %@", inner.reason ?: @"unknown"]);
            }
            ABLogError(@"engine_start_failed reason=connect_exception bound_device_id=%u detail=%@",
                       (unsigned int)_boundDeviceID, inner.reason ?: @"unknown");
            return NO;
        }
    }
    mixer.outputVolume = 1.0;
    [engine prepare];
    NSError *local = nil;
    if (![engine startAndReturnError:&local]) {
        if (error) {
            *error = local;
        }
        return NO;
    }

    if (_boundDeviceID == kAudioObjectUnknown) {
        return YES;
    }

    // Stop + re-init AU around CurrentDevice set so same-device duplex bind can stick.
    [engine stop];
    AudioUnit sharedUnit = engine.outputNode.audioUnit;
    if (sharedUnit != NULL) {
        (void)AudioUnitUninitialize(sharedUnit);
    }
    if (![self ab_applyBoundDeviceOnEngine:engine error:error]) {
        return NO;
    }
    if (sharedUnit != NULL) {
        OSStatus initSt = AudioUnitInitialize(sharedUnit);
        if (initSt != noErr) {
            ABLogWarn(@"audio_unit_reinit_after_bind status=%d bound_device_id=%u", (int)initSt,
                      (unsigned int)_boundDeviceID);
        }
    }

    input = engine.inputNode;
    mixer = engine.mainMixerNode;
    inFormat = ABPassThroughFormatFromAudioUnit(input.audioUnit, kAudioUnitScope_Output, 1);
    if (inFormat == nil) {
        inFormat = [input inputFormatForBus:0];
    }
    if (inFormat != nil && inFormat.sampleRate > 0 && inFormat.channelCount > 0) {
        canonical =
            [[AVAudioFormat alloc] initStandardFormatWithSampleRate:inFormat.sampleRate channels:inFormat.channelCount];
        if (canonical != nil) {
            inFormat = canonical;
        }
        @try {
            [engine disconnectNodeInput:mixer];
            [engine connect:input to:mixer format:inFormat];
        } @catch (NSException *exception) {
            @try {
                [engine connect:input to:mixer format:nil];
            } @catch (NSException *inner) {
                ABLogWarn(@"engine_reconnect_after_bind_failed detail=%@", inner.reason ?: @"unknown");
            }
        }
        mixer.outputVolume = 1.0;
    }
    [engine prepare];

    local = nil;
    if (![engine startAndReturnError:&local]) {
        if (error) {
            *error = local;
        }
        ABLogError(@"engine_start_failed reason=restart_after_bind bound_device_id=%u status=%ld",
                   (unsigned int)_boundDeviceID, (long)local.code);
        return NO;
    }

    if (![self ab_verifyActualCurrentDevice:_boundDeviceID onEngine:engine error:error]) {
        [engine stop];
        return NO;
    }
    if (!engine.isRunning) {
        if (error) {
            *error = ABPassThroughBuildAdapterError(
                1111, @"engine_start", @"Engine inactive after device bind; refusing zombie active state.");
        }
        ABLogError(@"engine_start_failed reason=inactive_after_bind bound_device_id=%u",
                   (unsigned int)_boundDeviceID);
        [engine stop];
        return NO;
    }
    [self ab_emitDeviceBindOkOnEngine:engine];
    return YES;
}

- (BOOL)startWithError:(NSError **)error {
    return [self startWithQuiet:NO error:error];
}

- (BOOL)startWithQuiet:(BOOL)quiet error:(NSError **)error {
    _configuredQuiet = quiet;
    _hasConfiguredRuntimeParameters = YES;
    [self stop];

    // Programmatic Aggregate + AVAudioEngine CurrentDevice fails with avfaudio -10875 after sticky bind.
    // HAL Output Unit passthrough is the working Aggregate path without mutating system defaults.
    if (_boundDeviceID != kAudioObjectUnknown && [ABHALPassThroughIO deviceIsAggregate:_boundDeviceID]) {
        if (![self ab_startHALPassThroughWithError:error]) {
            if (_configuredDiag) {
                NSMutableDictionary<NSString *, NSString *> *extra = [NSMutableDictionary dictionary];
                extra[@"io_transport"] = @"hal";
                if (error != NULL && *error != nil) {
                    extra[@"error_domain"] = (*error).domain ?: @"";
                    extra[@"error_code"] = [NSString stringWithFormat:@"%ld", (long)(*error).code];
                }
                ABDiagEmitEvent(@"engine_start", nil, nil, [self ab_diagEngineContext], extra);
            }
            return NO;
        }
        [self ab_noteSuccessfulStartOrRebuildWithReason:@"engine_start" stopWallMs:nil quiet:quiet];
        return YES;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    if (![self ab_connectPrepareStartEngine:engine error:error]) {
        if (_configuredDiag) {
            NSMutableDictionary<NSString *, NSString *> *extra = [NSMutableDictionary dictionary];
            if (error != NULL && *error != nil) {
                extra[@"error_domain"] = (*error).domain ?: @"";
                extra[@"error_code"] = [NSString stringWithFormat:@"%ld", (long)(*error).code];
                NSString *op = (*error).userInfo[@"operation"];
                if ([op isKindOfClass:[NSString class]]) {
                    extra[@"error_operation"] = op;
                }
            }
            ABDiagEmitEvent(@"engine_start", nil, nil, [self ab_diagEngineContext], extra);
        }
        return NO;
    }
    _currentEngine = engine;
    [self ab_installConfigChangeObserverForEngine:engine];
    [self ab_noteSuccessfulStartOrRebuildWithReason:@"engine_start" stopWallMs:nil quiet:quiet];
    return YES;
}

- (void)configureRecoveryWithQuiet:(BOOL)quiet {
    [self configureRecoveryWithQuiet:quiet diag:NO];
}

- (void)configureRecoveryWithQuiet:(BOOL)quiet diag:(BOOL)diag {
    _configuredQuiet = quiet;
    _configuredDiag = diag;
    _hasConfiguredRuntimeParameters = YES;
}

- (void)stop {
    [self ab_tearDownConfigChangeObserver];
    if (_configuredDiag && (_currentEngine != nil || _halIO != nil)) {
        ABDiagEmitEvent(@"engine_stop", nil, nil, [self ab_diagEngineContext], nil);
    }
    if (_halIO != nil) {
        [_halIO stop];
        _halIO = nil;
    }
    AVAudioEngine *engine = _currentEngine;
    if (engine != nil) {
        [engine stop];
        _currentEngine = nil;
    }
}

- (BOOL)rebuildForRouteChangeWithQuiet:(BOOL)quiet error:(NSError **)error {
    NSDate *t0 = [NSDate date];
    [self stop];
    NSTimeInterval stopSeconds = [[NSDate date] timeIntervalSinceDate:t0];
    long long stopWallMs = (long long)llround(stopSeconds * 1000.0);
    if (!quiet) {
        ABLogInfo(@"route rebuild: stop_wall_ms=%lld", stopWallMs);
    }

    _configuredQuiet = quiet;
    _hasConfiguredRuntimeParameters = YES;

    if (_boundDeviceID != kAudioObjectUnknown && [ABHALPassThroughIO deviceIsAggregate:_boundDeviceID]) {
        if (![self ab_startHALPassThroughWithError:error]) {
            if (_configuredDiag) {
                NSMutableDictionary<NSString *, NSString *> *extra = [NSMutableDictionary dictionary];
                extra[@"stop_wall_ms"] = [NSString stringWithFormat:@"%lld", stopWallMs];
                extra[@"rebuild_ok"] = @"0";
                extra[@"io_transport"] = @"hal";
                if (error != NULL && *error != nil) {
                    extra[@"error_domain"] = (*error).domain ?: @"";
                    extra[@"error_code"] = [NSString stringWithFormat:@"%ld", (long)(*error).code];
                }
                ABDiagEmitEvent(@"engine_rebuild_failed", nil, nil, [self ab_diagEngineContext], extra);
            }
            return NO;
        }
        [self ab_noteSuccessfulStartOrRebuildWithReason:@"engine_rebuild_ok" stopWallMs:@(stopWallMs) quiet:quiet];
        return YES;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    if (![self ab_connectPrepareStartEngine:engine error:error]) {
        if (_configuredDiag) {
            NSMutableDictionary<NSString *, NSString *> *extra = [NSMutableDictionary dictionary];
            extra[@"stop_wall_ms"] = [NSString stringWithFormat:@"%lld", stopWallMs];
            extra[@"rebuild_ok"] = @"0";
            if (error != NULL && *error != nil) {
                extra[@"error_domain"] = (*error).domain ?: @"";
                extra[@"error_code"] = [NSString stringWithFormat:@"%ld", (long)(*error).code];
            }
            ABDiagEmitEvent(@"engine_rebuild_failed", nil, nil, [self ab_diagEngineContext], extra);
        }
        return NO;
    }
    _currentEngine = engine;
    [self ab_installConfigChangeObserverForEngine:engine];
    [self ab_noteSuccessfulStartOrRebuildWithReason:@"engine_rebuild_ok" stopWallMs:@(stopWallMs) quiet:quiet];
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
    return _currentEngine != nil || (_halIO != nil && _halIO.isRunning);
}

- (NSUInteger)recoveryRebuildAttemptCount {
    return _recoveryRebuildAttemptCount;
}

- (NSUInteger)configChangeSeq {
    return _configChangeSeq;
}

- (NSUInteger)rebuildSeq {
    return _rebuildSeq;
}

- (NSTimeInterval)configChangeUnixTs {
    return _configChangeUnixTs;
}

- (NSTimeInterval)rebuildUnixTs {
    return _rebuildUnixTs;
}

- (void)dealloc {
    [self ab_tearDownConfigChangeObserver];
}

@end
