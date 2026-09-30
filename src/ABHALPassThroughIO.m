#import "ABHALPassThroughIO.h"

#import <stdlib.h>
#import <string.h>

NSString *const ABHALPassThroughIOErrorDomain = @"ABHALPassThroughIOError";

typedef struct {
    AudioUnit unit;
    AudioBufferList *scratch;
    UInt32 scratchBytes;
    UInt32 scratchFrames;
    UInt32 inputChannels;
    UInt32 outputChannels;
} ABHALPassThroughRenderState;

@implementation ABHALPassThroughIO {
    AudioUnit _unit;
    AudioDeviceID _boundDeviceID;
    BOOL _running;
    ABHALPassThroughRenderState _render;
}

- (AudioDeviceID)boundDeviceID {
    return _boundDeviceID;
}

- (BOOL)isRunning {
    return _running;
}

- (AudioUnit)audioUnit {
    return _unit;
}

static NSError *ABHALError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ABHALPassThroughIOErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

+ (BOOL)deviceIsAggregate:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioObjectPropertyClass,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    AudioClassID classID = 0;
    UInt32 size = (UInt32)sizeof(classID);
    OSStatus st = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &classID);
    return st == noErr && classID == kAudioAggregateDeviceClassID;
}

static void ABHALFreeScratch(ABHALPassThroughRenderState *state) {
    if (state == NULL) {
        return;
    }
    if (state->scratch != NULL) {
        free(state->scratch);
        state->scratch = NULL;
    }
    state->scratchBytes = 0;
    state->scratchFrames = 0;
}

/// Allocates mismatch-path scratch once at start. Must not be called from the render callback.
static BOOL ABHALAllocateScratch(ABHALPassThroughRenderState *state, UInt32 channels, UInt32 frames,
                                 UInt32 bytesPerFrame) {
    if (state == NULL || channels == 0 || frames == 0 || bytesPerFrame == 0) {
        return NO;
    }
    UInt32 header = (UInt32)(sizeof(AudioBufferList) + sizeof(AudioBuffer) * (channels > 0 ? channels - 1 : 0));
    UInt32 dataBytes = channels * frames * bytesPerFrame;
    UInt32 total = header + dataBytes;
    ABHALFreeScratch(state);
    void *mem = calloc(1, total);
    if (mem == NULL) {
        return NO;
    }
    state->scratch = (AudioBufferList *)mem;
    state->scratchBytes = total;
    state->scratchFrames = frames;
    return YES;
}

static void ABHALSilenceOutput(AudioBufferList *ioData) {
    if (ioData == NULL) {
        return;
    }
    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        if (ioData->mBuffers[b].mData != NULL) {
            memset(ioData->mBuffers[b].mData, 0, ioData->mBuffers[b].mDataByteSize);
        }
    }
}

static OSStatus ABHALRenderCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames,
                                    AudioBufferList *ioData) {
    (void)inBusNumber;
    ABHALPassThroughRenderState *state = (ABHALPassThroughRenderState *)inRefCon;
    if (state == NULL || state->unit == NULL || ioData == NULL) {
        return noErr;
    }

    // Fast path: identical layout — render input (element 1) directly into output buffers.
    if (state->inputChannels == state->outputChannels && state->inputChannels > 0) {
        return AudioUnitRender(state->unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
    }

    // Mono→stereo (or other mismatch): pull input into preallocated scratch, then upmix/copy.
    // Realtime contract: no heap allocation or free on this path.
    UInt32 inCh = state->inputChannels > 0 ? state->inputChannels : 1;
    UInt32 bytesPerFrame = 4; // float32
    if (ioData->mNumberBuffers > 0 && ioData->mBuffers[0].mDataByteSize > 0 && inNumberFrames > 0) {
        bytesPerFrame = ioData->mBuffers[0].mDataByteSize / inNumberFrames / (ioData->mBuffers[0].mNumberChannels > 0
                                                                                  ? ioData->mBuffers[0].mNumberChannels
                                                                                  : 1);
        if (bytesPerFrame == 0) {
            bytesPerFrame = 4;
        }
    }
    UInt32 header = (UInt32)(sizeof(AudioBufferList) + sizeof(AudioBuffer) * (inCh > 0 ? inCh - 1 : 0));
    UInt32 need = header + inCh * inNumberFrames * bytesPerFrame;
    if (state->scratch == NULL || state->scratchFrames < inNumberFrames || state->scratchBytes < need) {
        ABHALSilenceOutput(ioData);
        return kAudioUnitErr_TooManyFramesToProcess;
    }

    AudioBufferList *scratch = state->scratch;
    scratch->mNumberBuffers = inCh;
    UInt8 *dataBase = (UInt8 *)scratch + header;
    for (UInt32 i = 0; i < inCh; i++) {
        scratch->mBuffers[i].mNumberChannels = 1;
        scratch->mBuffers[i].mDataByteSize = inNumberFrames * bytesPerFrame;
        scratch->mBuffers[i].mData = dataBase + i * inNumberFrames * bytesPerFrame;
    }

    OSStatus st = AudioUnitRender(state->unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, scratch);
    if (st != noErr) {
        ABHALSilenceOutput(ioData);
        return noErr;
    }

    // Client format is non-interleaved float: one buffer per channel.
    float *in0 = (float *)scratch->mBuffers[0].mData;
    if (in0 == NULL) {
        return noErr;
    }
    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        float *out = (float *)ioData->mBuffers[b].mData;
        if (out == NULL) {
            continue;
        }
        UInt32 chInBuf = ioData->mBuffers[b].mNumberChannels;
        if (chInBuf <= 1) {
            memcpy(out, in0, (size_t)inNumberFrames * sizeof(float));
        } else {
            // Interleaved multi-channel buffer: duplicate mono into each frame slot.
            for (UInt32 f = 0; f < inNumberFrames; f++) {
                float s = in0[f];
                for (UInt32 c = 0; c < chInBuf; c++) {
                    out[f * chInBuf + c] = s;
                }
            }
        }
    }
    return noErr;
}

static BOOL ABHALGetASBD(AudioUnit unit, AudioUnitScope scope, AudioUnitElement element,
                         AudioStreamBasicDescription *outASBD) {
    if (unit == NULL || outASBD == NULL) {
        return NO;
    }
    UInt32 size = (UInt32)sizeof(*outASBD);
    memset(outASBD, 0, sizeof(*outASBD));
    return AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, outASBD, &size) == noErr;
}

static BOOL ABHALSetASBD(AudioUnit unit, AudioUnitScope scope, AudioUnitElement element,
                         const AudioStreamBasicDescription *asbd) {
    if (unit == NULL || asbd == NULL) {
        return NO;
    }
    return AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, asbd,
                                (UInt32)sizeof(*asbd)) == noErr;
}

static AudioStreamBasicDescription ABHALCanonicalFloat(Float64 sampleRate, UInt32 channels) {
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    asbd.mBitsPerChannel = 32;
    asbd.mChannelsPerFrame = channels;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = 4;
    asbd.mBytesPerPacket = 4;
    return asbd;
}

- (void)ab_disposeUnit {
    if (_unit != NULL) {
        AudioOutputUnitStop(_unit);
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
    }
    ABHALFreeScratch(&_render);
    memset(&_render, 0, sizeof(_render));
    _running = NO;
    _boundDeviceID = kAudioObjectUnknown;
}

- (BOOL)startWithDeviceID:(AudioDeviceID)deviceID error:(NSError **)error {
    [self stop];
    if (deviceID == kAudioObjectUnknown) {
        if (error) {
            *error = ABHALError(1, @"HAL pass-through requires a bound AudioDeviceID.");
        }
        return NO;
    }

    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_HALOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0,
    };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (comp == NULL) {
        if (error) {
            *error = ABHALError(2, @"HAL Output AudioComponent unavailable.");
        }
        return NO;
    }

    AudioUnit unit = NULL;
    OSStatus st = AudioComponentInstanceNew(comp, &unit);
    if (st != noErr || unit == NULL) {
        if (error) {
            *error = ABHALError(3, [NSString stringWithFormat:@"AudioComponentInstanceNew failed (status=%d).", (int)st]);
        }
        return NO;
    }

    UInt32 enable = 1;
    st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable,
                              (UInt32)sizeof(enable));
    if (st != noErr) {
        AudioComponentInstanceDispose(unit);
        if (error) {
            *error = ABHALError(4, [NSString stringWithFormat:@"EnableIO input failed (status=%d).", (int)st]);
        }
        return NO;
    }
    st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable,
                              (UInt32)sizeof(enable));
    if (st != noErr) {
        AudioComponentInstanceDispose(unit);
        if (error) {
            *error = ABHALError(5, [NSString stringWithFormat:@"EnableIO output failed (status=%d).", (int)st]);
        }
        return NO;
    }

    st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
                              (UInt32)sizeof(deviceID));
    if (st != noErr) {
        AudioComponentInstanceDispose(unit);
        if (error) {
            *error = ABHALError(
                6, [NSString stringWithFormat:@"HAL CurrentDevice bind failed id=%u (status=%d).",
                                              (unsigned int)deviceID, (int)st]);
        }
        return NO;
    }

    // Hardware formats (device side).
    AudioStreamBasicDescription hwIn = {0};
    AudioStreamBasicDescription hwOut = {0};
    if (!ABHALGetASBD(unit, kAudioUnitScope_Input, 1, &hwIn) || hwIn.mChannelsPerFrame == 0 || hwIn.mSampleRate <= 0) {
        AudioComponentInstanceDispose(unit);
        if (error) {
            *error = ABHALError(7, @"HAL input hardware format unavailable after Aggregate bind.");
        }
        return NO;
    }
    if (!ABHALGetASBD(unit, kAudioUnitScope_Output, 0, &hwOut) || hwOut.mChannelsPerFrame == 0 ||
        hwOut.mSampleRate <= 0) {
        AudioComponentInstanceDispose(unit);
        if (error) {
            *error = ABHALError(8, @"HAL output hardware format unavailable after Aggregate bind.");
        }
        return NO;
    }

    // Client formats: non-interleaved float at the Aggregate's rate; keep native channel counts.
    Float64 rate = hwOut.mSampleRate;
    AudioStreamBasicDescription clientIn = ABHALCanonicalFloat(rate, hwIn.mChannelsPerFrame);
    AudioStreamBasicDescription clientOut = ABHALCanonicalFloat(rate, hwOut.mChannelsPerFrame);
    // Device←client on input element: scope Output / element 1
    if (!ABHALSetASBD(unit, kAudioUnitScope_Output, 1, &clientIn)) {
        AudioComponentInstanceDispose(unit);
        if (error) {
            *error = ABHALError(9, @"Failed to set HAL client input stream format.");
        }
        return NO;
    }
    // Client→device on output element: scope Input / element 0
    if (!ABHALSetASBD(unit, kAudioUnitScope_Input, 0, &clientOut)) {
        AudioComponentInstanceDispose(unit);
        if (error) {
            *error = ABHALError(10, @"Failed to set HAL client output stream format.");
        }
        return NO;
    }

    _render.unit = unit;
    _render.inputChannels = clientIn.mChannelsPerFrame;
    _render.outputChannels = clientOut.mChannelsPerFrame;

    // Cap slice size and preallocate mismatch scratch before the realtime callback runs.
    UInt32 maxFrames = 4096;
    UInt32 maxFramesSize = (UInt32)sizeof(maxFrames);
    OSStatus maxSt =
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames,
                             &maxFramesSize);
    if (maxSt != noErr || maxFrames == 0) {
        maxFrames = 4096;
    }
    if (maxFrames < 4096) {
        maxFrames = 4096;
        (void)AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                   &maxFrames, (UInt32)sizeof(maxFrames));
    }
    if (_render.inputChannels != _render.outputChannels) {
        UInt32 inCh = _render.inputChannels > 0 ? _render.inputChannels : 1;
        if (!ABHALAllocateScratch(&_render, inCh, maxFrames, 4)) {
            AudioComponentInstanceDispose(unit);
            memset(&_render, 0, sizeof(_render));
            if (error) {
                *error = ABHALError(15, @"Failed to preallocate HAL render scratch for channel mismatch.");
            }
            return NO;
        }
    }

    AURenderCallbackStruct cb = {
        .inputProc = ABHALRenderCallback,
        .inputProcRefCon = &_render,
    };
    st = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                              (UInt32)sizeof(cb));
    if (st != noErr) {
        ABHALFreeScratch(&_render);
        AudioComponentInstanceDispose(unit);
        memset(&_render, 0, sizeof(_render));
        if (error) {
            *error = ABHALError(11, [NSString stringWithFormat:@"SetRenderCallback failed (status=%d).", (int)st]);
        }
        return NO;
    }

    st = AudioUnitInitialize(unit);
    if (st != noErr) {
        ABHALFreeScratch(&_render);
        AudioComponentInstanceDispose(unit);
        memset(&_render, 0, sizeof(_render));
        if (error) {
            *error = ABHALError(12, [NSString stringWithFormat:@"AudioUnitInitialize failed (status=%d).", (int)st]);
        }
        return NO;
    }

    st = AudioOutputUnitStart(unit);
    if (st != noErr) {
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        ABHALFreeScratch(&_render);
        memset(&_render, 0, sizeof(_render));
        if (error) {
            *error = ABHALError(13, [NSString stringWithFormat:@"AudioOutputUnitStart failed (status=%d).", (int)st]);
        }
        return NO;
    }

    // Readback gate: refuse silent wrong-device start.
    AudioDeviceID actual = kAudioObjectUnknown;
    UInt32 size = (UInt32)sizeof(actual);
    OSStatus getSt =
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size);
    if (getSt != noErr || actual != deviceID) {
        AudioOutputUnitStop(unit);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        ABHALFreeScratch(&_render);
        memset(&_render, 0, sizeof(_render));
        if (error) {
            *error = ABHALError(
                14, [NSString stringWithFormat:@"HAL CurrentDevice readback mismatch intent=%u actual=%u.",
                                               (unsigned int)deviceID, (unsigned int)actual]);
        }
        return NO;
    }

    _unit = unit;
    _boundDeviceID = deviceID;
    _running = YES;
    return YES;
}

- (void)stop {
    [self ab_disposeUnit];
}

- (BOOL)readCurrentDeviceID:(AudioDeviceID *)outDeviceID {
    if (outDeviceID == NULL || _unit == NULL) {
        return NO;
    }
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 size = (UInt32)sizeof(deviceID);
    OSStatus st =
        AudioUnitGetProperty(_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size);
    if (st != noErr) {
        return NO;
    }
    *outDeviceID = deviceID;
    return YES;
}

- (void)dealloc {
    [self stop];
}

@end
