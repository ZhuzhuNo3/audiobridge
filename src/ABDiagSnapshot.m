#import "ABDiagSnapshot.h"

#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/time.h>

static BOOL g_diagEnabled = NO;
static BOOL g_diagSessionQuiet = NO;

void ABDiagSetEnabled(BOOL enabled) {
    g_diagEnabled = enabled;
}

BOOL ABDiagIsEnabled(void) {
    return g_diagEnabled;
}

void ABDiagSetSessionQuiet(BOOL quiet) {
    g_diagSessionQuiet = quiet;
}

BOOL ABDiagSessionQuiet(void) {
    return g_diagSessionQuiet;
}

static const char *ABLogLevelName(ABLogLevel level) {
    switch (level) {
        case ABLogLevelDebug:
            return "DEBUG";
        case ABLogLevelInfo:
            return "INFO";
        case ABLogLevelWarn:
            return "WARN";
        case ABLogLevelError:
            return "ERROR";
    }
    return "INFO";
}

static const char *ABLogBasename(const char *file) {
    if (file == NULL) {
        return "unknown";
    }
    const char *slash = strrchr(file, '/');
    return slash != NULL ? slash + 1 : file;
}

void ABLogWrite(ABLogLevel level, const char *file, int line, NSString *message) {
    if (g_diagSessionQuiet) {
        return;
    }
    if (level == ABLogLevelDebug && !g_diagEnabled) {
        return;
    }

    struct timeval tv;
    gettimeofday(&tv, NULL);
    time_t seconds = tv.tv_sec;
    struct tm local;
    localtime_r(&seconds, &local);
    int millis = (int)(tv.tv_usec / 1000);

    const char *msgUTF8 = message.UTF8String;
    fprintf(stderr, "%04d-%02d-%02d %02d:%02d:%02d.%03d  %s:%d  %s  %s\n", local.tm_year + 1900, local.tm_mon + 1,
            local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec, millis, ABLogBasename(file), line,
            ABLogLevelName(level), msgUTF8 != NULL ? msgUTF8 : "(encoding error)");
}

@implementation ABDiagDeviceContext
@end

@implementation ABDiagEngineContext
@end

static void ABDiagAppendKV(NSMutableString *out, NSString *key, NSString *value) {
    if (out.length > 0) {
        [out appendString:@" "];
    }
    [out appendFormat:@"%@=%@", key, value];
}

static NSString *ABDiagEscapeToken(NSString *raw) {
    if (raw.length == 0) {
        return @"\"\"";
    }
    BOOL needsQuote = NO;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c <= 0x20 || c == '=' || c == '"' || c == '\\') {
            needsQuote = YES;
            break;
        }
    }
    if (!needsQuote) {
        return raw;
    }
    NSMutableString *escaped = [NSMutableString stringWithCapacity:raw.length + 2];
    [escaped appendString:@"\""];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == '"' || c == '\\') {
            [escaped appendFormat:@"\\%C", c];
        } else if (c == '\n') {
            [escaped appendString:@"\\n"];
        } else {
            [escaped appendFormat:@"%C", c];
        }
    }
    [escaped appendString:@"\""];
    return escaped;
}

static NSString *ABDiagDeviceName(AudioDeviceID deviceID) {
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

static BOOL ABDiagReadDefaultDevice(AudioObjectPropertySelector selector, AudioDeviceID *outID) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
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

static BOOL ABDiagReadUInt32Prop(AudioDeviceID deviceID, AudioObjectPropertySelector selector,
                                 AudioObjectPropertyScope scope, UInt32 *outValue) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(deviceID, &address)) {
        return NO;
    }
    UInt32 size = (UInt32)sizeof(UInt32);
    UInt32 value = 0;
    OSStatus st = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &value);
    if (st != noErr) {
        return NO;
    }
    *outValue = value;
    return YES;
}

static BOOL ABDiagReadFloat32Prop(AudioDeviceID deviceID, AudioObjectPropertySelector selector,
                                  AudioObjectPropertyScope scope, Float32 *outValue) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(deviceID, &address)) {
        return NO;
    }
    UInt32 size = (UInt32)sizeof(Float32);
    Float32 value = 0;
    OSStatus st = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &value);
    if (st != noErr) {
        return NO;
    }
    *outValue = value;
    return YES;
}

static BOOL ABDiagReadFloat64Prop(AudioDeviceID deviceID, AudioObjectPropertySelector selector, Float64 *outValue) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(deviceID, &address)) {
        return NO;
    }
    UInt32 size = (UInt32)sizeof(Float64);
    Float64 value = 0;
    OSStatus st = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &value);
    if (st != noErr) {
        return NO;
    }
    *outValue = value;
    return YES;
}

static BOOL ABDiagReadStreamChannelCount(AudioDeviceID deviceID, AudioObjectPropertyScope scope, UInt32 *outChannels) {
    AudioObjectPropertyAddress cfgAddr = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(deviceID, &cfgAddr)) {
        return NO;
    }
    UInt32 dataSize = 0;
    OSStatus st = AudioObjectGetPropertyDataSize(deviceID, &cfgAddr, 0, NULL, &dataSize);
    if (st != noErr || dataSize < sizeof(AudioBufferList)) {
        return NO;
    }
    UInt8 *bytes = (UInt8 *)calloc(1, (size_t)dataSize);
    if (bytes == NULL) {
        return NO;
    }
    st = AudioObjectGetPropertyData(deviceID, &cfgAddr, 0, NULL, &dataSize, bytes);
    BOOL ok = NO;
    if (st == noErr) {
        const AudioBufferList *list = (const AudioBufferList *)bytes;
        UInt32 total = 0;
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
            total += list->mBuffers[i].mNumberChannels;
        }
        *outChannels = total;
        ok = YES;
    }
    free(bytes);
    return ok;
}

static void ABDiagAppendOptionalBool(NSMutableString *out, NSString *key, BOOL readable, BOOL value) {
    if (!readable) {
        ABDiagAppendKV(out, key, @"unread");
        return;
    }
    ABDiagAppendKV(out, key, value ? @"1" : @"0");
}

static void ABDiagAppendOptionalUInt(NSMutableString *out, NSString *key, BOOL readable, UInt32 value) {
    if (!readable) {
        ABDiagAppendKV(out, key, @"unread");
        return;
    }
    ABDiagAppendKV(out, key, [NSString stringWithFormat:@"%u", (unsigned int)value]);
}

static void ABDiagAppendOptionalDouble(NSMutableString *out, NSString *key, BOOL readable, double value) {
    if (!readable) {
        ABDiagAppendKV(out, key, @"unread");
        return;
    }
    ABDiagAppendKV(out, key, [NSString stringWithFormat:@"%.6g", value]);
}

static void ABDiagAppendDeviceSide(NSMutableString *out, NSString *prefix, AudioDeviceID deviceID) {
    UInt32 alive = 0;
    BOOL haveAlive = ABDiagReadUInt32Prop(deviceID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal,
                                          &alive);
    ABDiagAppendOptionalBool(out, [prefix stringByAppendingString:@"_alive"], haveAlive, alive != 0);

    UInt32 running = 0;
    BOOL haveRunning =
        ABDiagReadUInt32Prop(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal,
                             &running);
    ABDiagAppendOptionalBool(out, [prefix stringByAppendingString:@"_running_somewhere"], haveRunning, running != 0);

    Float64 nominal = 0;
    BOOL haveNominal = ABDiagReadFloat64Prop(deviceID, kAudioDevicePropertyNominalSampleRate, &nominal);
    ABDiagAppendOptionalDouble(out, [prefix stringByAppendingString:@"_nominal_sr"], haveNominal, nominal);

    // Stream channel scope: system_default_in uses input; system_default_out uses output.
    AudioObjectPropertyScope streamScope = ([prefix hasSuffix:@"_in"] || [prefix isEqualToString:@"in"])
                                               ? kAudioObjectPropertyScopeInput
                                               : kAudioObjectPropertyScopeOutput;
    UInt32 channels = 0;
    BOOL haveChannels = ABDiagReadStreamChannelCount(deviceID, streamScope, &channels);
    ABDiagAppendOptionalUInt(out, [prefix stringByAppendingString:@"_ca_channels"], haveChannels, channels);
}

NSString *ABDiagCaptureDeviceSection(ABDiagDeviceContext *ctx) {
    NSMutableString *out = [NSMutableString string];

    AudioDeviceID inID = kAudioObjectUnknown;
    BOOL haveIn = ABDiagReadDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, &inID);
    if (haveIn) {
        ABDiagAppendKV(out, @"system_default_in_id", [NSString stringWithFormat:@"%u", (unsigned int)inID]);
        ABDiagAppendKV(out, @"system_default_in_name", ABDiagEscapeToken(ABDiagDeviceName(inID)));
        ABDiagAppendDeviceSide(out, @"system_default_in", inID);
    } else {
        ABDiagAppendKV(out, @"system_default_in_id", @"unread");
        ABDiagAppendKV(out, @"system_default_in_name", @"unread");
        ABDiagAppendKV(out, @"system_default_in_alive", @"unread");
        ABDiagAppendKV(out, @"system_default_in_running_somewhere", @"unread");
        ABDiagAppendKV(out, @"system_default_in_nominal_sr", @"unread");
        ABDiagAppendKV(out, @"system_default_in_ca_channels", @"unread");
    }

    AudioDeviceID outID = kAudioObjectUnknown;
    BOOL haveOut = ABDiagReadDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, &outID);
    if (haveOut) {
        ABDiagAppendKV(out, @"system_default_out_id", [NSString stringWithFormat:@"%u", (unsigned int)outID]);
        ABDiagAppendKV(out, @"system_default_out_name", ABDiagEscapeToken(ABDiagDeviceName(outID)));
        ABDiagAppendDeviceSide(out, @"system_default_out", outID);

        UInt32 mute = 0;
        BOOL haveMute =
            ABDiagReadUInt32Prop(outID, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, &mute);
        ABDiagAppendOptionalBool(out, @"system_default_out_mute", haveMute, mute != 0);

        Float32 volume = 0;
        BOOL haveVolume =
            ABDiagReadFloat32Prop(outID, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, &volume);
        ABDiagAppendOptionalDouble(out, @"system_default_out_volume", haveVolume, (double)volume);

        UInt32 transport = 0;
        BOOL haveTransport =
            ABDiagReadUInt32Prop(outID, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport);
        if (haveTransport) {
            ABDiagAppendKV(out, @"system_default_out_transport",
                           [NSString stringWithFormat:@"0x%08x", (unsigned int)transport]);
        } else {
            ABDiagAppendKV(out, @"system_default_out_transport", @"unread");
        }

        pid_t hog = -1;
        AudioObjectPropertyAddress hogAddr = {
            .mSelector = kAudioDevicePropertyHogMode,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain,
        };
        if (AudioObjectHasProperty(outID, &hogAddr)) {
            UInt32 hogSize = (UInt32)sizeof(hog);
            OSStatus st = AudioObjectGetPropertyData(outID, &hogAddr, 0, NULL, &hogSize, &hog);
            if (st == noErr) {
                ABDiagAppendKV(out, @"system_default_out_hog_pid", [NSString stringWithFormat:@"%d", (int)hog]);
            } else {
                ABDiagAppendKV(out, @"system_default_out_hog_pid", @"unread");
            }
        } else {
            ABDiagAppendKV(out, @"system_default_out_hog_pid", @"unread");
        }
    } else {
        ABDiagAppendKV(out, @"system_default_out_id", @"unread");
        ABDiagAppendKV(out, @"system_default_out_name", @"unread");
        ABDiagAppendKV(out, @"system_default_out_alive", @"unread");
        ABDiagAppendKV(out, @"system_default_out_running_somewhere", @"unread");
        ABDiagAppendKV(out, @"system_default_out_nominal_sr", @"unread");
        ABDiagAppendKV(out, @"system_default_out_ca_channels", @"unread");
        ABDiagAppendKV(out, @"system_default_out_mute", @"unread");
        ABDiagAppendKV(out, @"system_default_out_volume", @"unread");
        ABDiagAppendKV(out, @"system_default_out_transport", @"unread");
        ABDiagAppendKV(out, @"system_default_out_hog_pid", @"unread");
    }

    if (ctx != nil) {
        ABDiagAppendKV(out, @"config_in", ctx.inputConfigured ? @"1" : @"0");
        ABDiagAppendKV(out, @"config_out", ctx.outputConfigured ? @"1" : @"0");
        ABDiagAppendKV(out, @"config_in_id",
                       [NSString stringWithFormat:@"%u", (unsigned int)ctx.configInputDeviceID]);
        ABDiagAppendKV(out, @"config_out_id",
                       [NSString stringWithFormat:@"%u", (unsigned int)ctx.configOutputDeviceID]);
        // Intent bind id (Aggregate or duplex entity). Actual AU CurrentDevice is under engine section.
        ABDiagAppendKV(out, @"bound_device_id",
                       [NSString stringWithFormat:@"%u", (unsigned int)ctx.boundDeviceID]);
        ABDiagAppendKV(out, @"aggregate_id",
                       [NSString stringWithFormat:@"%u", (unsigned int)ctx.aggregateDeviceID]);
        ABDiagAppendKV(out, @"config_waiting", ctx.configWaiting ? @"1" : @"0");
        ABDiagAppendKV(out, @"listener_in_registered", ctx.floatingInputListenerRegistered ? @"1" : @"0");
        ABDiagAppendKV(out, @"listener_out_registered", ctx.floatingOutputListenerRegistered ? @"1" : @"0");
    }

    return [out copy];
}

static BOOL ABDiagReadUnitCurrentDevice(AudioUnit unit, AudioDeviceID *outID) {
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

NSString *ABDiagCaptureEngineSection(ABDiagEngineContext *ctx) {
    NSMutableString *out = [NSMutableString string];
    AVAudioEngine *engine = ctx != nil ? ctx.engine : nil;
    AudioUnit halUnit = ctx != nil ? ctx.halAudioUnit : NULL;
    BOOL present = engine != nil;
    BOOL halPresent = halUnit != NULL;
    ABDiagAppendKV(out, @"engine_present", present ? @"1" : @"0");
    ABDiagAppendKV(out, @"ab_is_active", (ctx != nil && ctx.abIsActive) ? @"1" : @"0");
    BOOL isRunning = (present && engine.isRunning) || (halPresent && ctx.halIsRunning);
    ABDiagAppendKV(out, @"is_running", isRunning ? @"1" : @"0");
    if (halPresent) {
        ABDiagAppendKV(out, @"io_transport", @"hal");
    } else if (present) {
        ABDiagAppendKV(out, @"io_transport", @"avaudioengine");
    } else {
        ABDiagAppendKV(out, @"io_transport", @"none");
    }

    if (present) {
        AVAudioFormat *inFmt = [engine.inputNode inputFormatForBus:0];
        AVAudioFormat *outFmt = [engine.outputNode outputFormatForBus:0];
        ABDiagAppendKV(out, @"av_in_sr", [NSString stringWithFormat:@"%.0f", inFmt.sampleRate]);
        ABDiagAppendKV(out, @"av_in_ch", [NSString stringWithFormat:@"%u", (unsigned int)inFmt.channelCount]);
        ABDiagAppendKV(out, @"av_out_sr", [NSString stringWithFormat:@"%.0f", outFmt.sampleRate]);
        ABDiagAppendKV(out, @"av_out_ch", [NSString stringWithFormat:@"%u", (unsigned int)outFmt.channelCount]);
        ABDiagAppendKV(out, @"mixer_output_volume",
                       [NSString stringWithFormat:@"%.6g", (double)engine.mainMixerNode.outputVolume]);

        // Authoritative engine bind: AudioUnit CurrentDevice readback (not system default).
        AudioDeviceID actualOut = kAudioObjectUnknown;
        AudioDeviceID actualIn = kAudioObjectUnknown;
        BOOL haveActualOut = ABDiagReadUnitCurrentDevice(engine.outputNode.audioUnit, &actualOut);
        BOOL haveActualIn = ABDiagReadUnitCurrentDevice(engine.inputNode.audioUnit, &actualIn);
        if (haveActualOut) {
            ABDiagAppendKV(out, @"actual_out_device_id",
                           [NSString stringWithFormat:@"%u", (unsigned int)actualOut]);
            ABDiagAppendKV(out, @"actual_out_device_name", ABDiagEscapeToken(ABDiagDeviceName(actualOut)));
        } else {
            ABDiagAppendKV(out, @"actual_out_device_id", @"unread");
            ABDiagAppendKV(out, @"actual_out_device_name", @"unread");
        }
        if (haveActualIn) {
            ABDiagAppendKV(out, @"actual_in_device_id", [NSString stringWithFormat:@"%u", (unsigned int)actualIn]);
            ABDiagAppendKV(out, @"actual_in_device_name", ABDiagEscapeToken(ABDiagDeviceName(actualIn)));
        } else {
            ABDiagAppendKV(out, @"actual_in_device_id", @"unread");
            ABDiagAppendKV(out, @"actual_in_device_name", @"unread");
        }
        if (haveActualOut && haveActualIn && actualOut == actualIn) {
            ABDiagAppendKV(out, @"actual_device_id", [NSString stringWithFormat:@"%u", (unsigned int)actualOut]);
            ABDiagAppendKV(out, @"actual_device_name", ABDiagEscapeToken(ABDiagDeviceName(actualOut)));
        } else if (haveActualOut) {
            ABDiagAppendKV(out, @"actual_device_id", [NSString stringWithFormat:@"%u", (unsigned int)actualOut]);
            ABDiagAppendKV(out, @"actual_device_name", ABDiagEscapeToken(ABDiagDeviceName(actualOut)));
        } else if (haveActualIn) {
            ABDiagAppendKV(out, @"actual_device_id", [NSString stringWithFormat:@"%u", (unsigned int)actualIn]);
            ABDiagAppendKV(out, @"actual_device_name", ABDiagEscapeToken(ABDiagDeviceName(actualIn)));
        } else {
            ABDiagAppendKV(out, @"actual_device_id", @"unread");
            ABDiagAppendKV(out, @"actual_device_name", @"unread");
        }
    } else if (halPresent) {
        ABDiagAppendKV(out, @"av_in_sr", @"unread");
        ABDiagAppendKV(out, @"av_in_ch", @"unread");
        ABDiagAppendKV(out, @"av_out_sr", @"unread");
        ABDiagAppendKV(out, @"av_out_ch", @"unread");
        ABDiagAppendKV(out, @"mixer_output_volume", @"unread");

        AudioDeviceID actual = kAudioObjectUnknown;
        BOOL haveActual = ABDiagReadUnitCurrentDevice(halUnit, &actual);
        if (haveActual) {
            NSString *idStr = [NSString stringWithFormat:@"%u", (unsigned int)actual];
            NSString *name = ABDiagEscapeToken(ABDiagDeviceName(actual));
            ABDiagAppendKV(out, @"actual_out_device_id", idStr);
            ABDiagAppendKV(out, @"actual_out_device_name", name);
            ABDiagAppendKV(out, @"actual_in_device_id", idStr);
            ABDiagAppendKV(out, @"actual_in_device_name", name);
            ABDiagAppendKV(out, @"actual_device_id", idStr);
            ABDiagAppendKV(out, @"actual_device_name", name);
        } else {
            ABDiagAppendKV(out, @"actual_out_device_id", @"unread");
            ABDiagAppendKV(out, @"actual_out_device_name", @"unread");
            ABDiagAppendKV(out, @"actual_in_device_id", @"unread");
            ABDiagAppendKV(out, @"actual_in_device_name", @"unread");
            ABDiagAppendKV(out, @"actual_device_id", @"unread");
            ABDiagAppendKV(out, @"actual_device_name", @"unread");
        }
    } else {
        ABDiagAppendKV(out, @"av_in_sr", @"unread");
        ABDiagAppendKV(out, @"av_in_ch", @"unread");
        ABDiagAppendKV(out, @"av_out_sr", @"unread");
        ABDiagAppendKV(out, @"av_out_ch", @"unread");
        ABDiagAppendKV(out, @"mixer_output_volume", @"unread");
        ABDiagAppendKV(out, @"actual_out_device_id", @"unread");
        ABDiagAppendKV(out, @"actual_out_device_name", @"unread");
        ABDiagAppendKV(out, @"actual_in_device_id", @"unread");
        ABDiagAppendKV(out, @"actual_in_device_name", @"unread");
        ABDiagAppendKV(out, @"actual_device_id", @"unread");
        ABDiagAppendKV(out, @"actual_device_name", @"unread");
    }

    if (ctx != nil && ctx.lastRenderSummary.length > 0) {
        ABDiagAppendKV(out, @"last_render", ABDiagEscapeToken(ctx.lastRenderSummary));
    } else {
        ABDiagAppendKV(out, @"last_render", @"unread");
    }

    NSUInteger rebuildAttempts = ctx != nil ? ctx.rebuildAttemptCount : 0;
    NSUInteger configSeq = ctx != nil ? ctx.configChangeSeq : 0;
    NSUInteger rebuildSeq = ctx != nil ? ctx.rebuildSeq : 0;
    ABDiagAppendKV(out, @"rebuild_attempt_count", [NSString stringWithFormat:@"%lu", (unsigned long)rebuildAttempts]);
    ABDiagAppendKV(out, @"config_change_seq", [NSString stringWithFormat:@"%lu", (unsigned long)configSeq]);
    ABDiagAppendKV(out, @"rebuild_seq", [NSString stringWithFormat:@"%lu", (unsigned long)rebuildSeq]);

    if (ctx != nil && ctx.configChangeUnixTs > 0) {
        ABDiagAppendKV(out, @"config_change_ts", [NSString stringWithFormat:@"%.3f", ctx.configChangeUnixTs]);
    } else {
        ABDiagAppendKV(out, @"config_change_ts", @"unread");
    }
    if (ctx != nil && ctx.rebuildUnixTs > 0) {
        ABDiagAppendKV(out, @"rebuild_ts", [NSString stringWithFormat:@"%.3f", ctx.rebuildUnixTs]);
    } else {
        ABDiagAppendKV(out, @"rebuild_ts", @"unread");
    }

    return [out copy];
}

static void ABDiagWriteDebugMessage(const char *file, int line, NSString *message) {
    ABLogWrite(ABLogLevelDebug, file, line, message);
}

void ABDiagEmit(NSString *kind, NSString *reason, NSString *triggerSource, ABDiagDeviceContext *deviceCtx,
                ABDiagEngineContext *engineCtx, NSDictionary<NSString *, NSString *> *extra) {
    if (!g_diagEnabled || g_diagSessionQuiet) {
        return;
    }

    NSMutableString *message = [NSMutableString string];
    ABDiagAppendKV(message, @"kind", ABDiagEscapeToken(kind ?: @"event"));
    ABDiagAppendKV(message, @"reason", ABDiagEscapeToken(reason ?: @"unknown"));
    if (triggerSource.length > 0) {
        ABDiagAppendKV(message, @"trigger_source", ABDiagEscapeToken(triggerSource));
    }

    NSString *device = ABDiagCaptureDeviceSection(deviceCtx);
    if (device.length > 0) {
        if (message.length > 0) {
            [message appendString:@" "];
        }
        [message appendString:device];
    }
    NSString *engine = ABDiagCaptureEngineSection(engineCtx);
    if (engine.length > 0) {
        if (message.length > 0) {
            [message appendString:@" "];
        }
        [message appendString:engine];
    }

    if (extra != nil) {
        NSArray<NSString *> *keys = [[extra allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *key in keys) {
            NSString *value = extra[key];
            ABDiagAppendKV(message, key, ABDiagEscapeToken(value ?: @""));
        }
    }

    ABDiagWriteDebugMessage(__FILE__, __LINE__, message);
}

void ABDiagEmitEvent(NSString *reason, NSString *triggerSource, ABDiagDeviceContext *deviceCtx,
                     ABDiagEngineContext *engineCtx, NSDictionary<NSString *, NSString *> *extra) {
    ABDiagEmit(@"event", reason, triggerSource, deviceCtx, engineCtx, extra);
}

void ABDiagEmitSnapshot(NSString *reason, NSString *triggerSource, ABDiagDeviceContext *deviceCtx,
                        ABDiagEngineContext *engineCtx, NSDictionary<NSString *, NSString *> *extra) {
    ABDiagEmit(@"snapshot", reason, triggerSource, deviceCtx, engineCtx, extra);
}

void ABDiagEmitThinEvent(NSString *reason, NSDictionary<NSString *, NSString *> *fields) {
    if (!g_diagEnabled || g_diagSessionQuiet) {
        return;
    }
    NSMutableString *message = [NSMutableString string];
    ABDiagAppendKV(message, @"kind", @"event");
    ABDiagAppendKV(message, @"reason", ABDiagEscapeToken(reason ?: @"unknown"));
    if (fields != nil) {
        NSArray<NSString *> *keys = [[fields allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *key in keys) {
            NSString *value = fields[key];
            ABDiagAppendKV(message, key, ABDiagEscapeToken(value ?: @""));
        }
    }
    ABDiagWriteDebugMessage(__FILE__, __LINE__, message);
}
