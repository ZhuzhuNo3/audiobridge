#import "ABAggregateDevice.h"

#import <stdlib.h>
#import <string.h>
#import <uuid/uuid.h>

NSString *const ABAggregateDeviceErrorDomain = @"ABAggregateDeviceError";

@implementation ABAggregateDevice {
    AudioDeviceID _aggregateDeviceID;
    AudioDeviceID _inputSubDeviceID;
    AudioDeviceID _outputSubDeviceID;
    NSString *_aggregateUID;
    BOOL _active;
}

- (AudioDeviceID)aggregateDeviceID {
    return _aggregateDeviceID;
}

- (AudioDeviceID)inputSubDeviceID {
    return _inputSubDeviceID;
}

- (AudioDeviceID)outputSubDeviceID {
    return _outputSubDeviceID;
}

- (NSString *)aggregateUID {
    return _aggregateUID;
}

- (BOOL)isActive {
    return _active;
}

static NSError *ABAggregateError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ABAggregateDeviceErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static NSString *ABAggregateCopyDeviceUID(AudioDeviceID deviceID, NSError **error) {
    if (deviceID == kAudioObjectUnknown) {
        if (error) {
            *error = ABAggregateError(1, @"Invalid AudioDeviceID for Aggregate sub-device.");
        }
        return nil;
    }
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyDeviceUID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    CFStringRef uidRef = NULL;
    UInt32 size = (UInt32)sizeof(uidRef);
    OSStatus st = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &uidRef);
    if (st != noErr || uidRef == NULL) {
        if (error) {
            *error = ABAggregateError(2, [NSString stringWithFormat:@"Failed to read device UID (status=%d).", (int)st]);
        }
        return nil;
    }
    return (__bridge_transfer NSString *)uidRef;
}

static NSDictionary *ABAggregateSubDeviceDict(NSString *uid, BOOL enableDrift) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@kAudioSubDeviceUIDKey] = uid;
    if (enableDrift) {
        dict[@kAudioSubDeviceDriftCompensationKey] = @YES;
    }
    return [dict copy];
}

static BOOL ABAggregateReadNominalSampleRate(AudioDeviceID deviceID, Float64 *outRate) {
    if (outRate == NULL || deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyNominalSampleRate,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    Float64 rate = 0;
    UInt32 size = (UInt32)sizeof(rate);
    OSStatus st = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &rate);
    if (st != noErr || rate <= 0) {
        return NO;
    }
    *outRate = rate;
    return YES;
}

static BOOL ABAggregateSetNominalSampleRate(AudioDeviceID deviceID, Float64 rate) {
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyNominalSampleRate,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 size = (UInt32)sizeof(rate);
    OSStatus st = AudioObjectSetPropertyData(deviceID, &address, 0, NULL, size, &rate);
    return st == noErr;
}

+ (nullable instancetype)createWithInputDeviceID:(AudioDeviceID)inputDeviceID
                                  outputDeviceID:(AudioDeviceID)outputDeviceID
                                           error:(NSError **)error {
    if (inputDeviceID == kAudioObjectUnknown || outputDeviceID == kAudioObjectUnknown) {
        if (error) {
            *error = ABAggregateError(1, @"Input and output device ids are required to create an Aggregate.");
        }
        return nil;
    }

    NSError *uidError = nil;
    NSString *inputUID = ABAggregateCopyDeviceUID(inputDeviceID, &uidError);
    if (inputUID == nil) {
        if (error) {
            *error = uidError;
        }
        return nil;
    }
    NSString *outputUID = ABAggregateCopyDeviceUID(outputDeviceID, &uidError);
    if (outputUID == nil) {
        if (error) {
            *error = uidError;
        }
        return nil;
    }

    uuid_t uuidBytes;
    uuid_generate(uuidBytes);
    char uuidCStr[37];
    uuid_unparse_lower(uuidBytes, uuidCStr);
    NSString *aggregateUID = [NSString stringWithFormat:@"audiobridge.aggregate.%s", uuidCStr];
    NSString *aggregateName = [NSString stringWithFormat:@"audiobridge Aggregate %@",
                                                         [[NSString stringWithUTF8String:uuidCStr] substringToIndex:8]];

    BOOL sameDevice = (inputDeviceID == outputDeviceID);
    NSArray *subDevices = nil;
    if (sameDevice) {
        subDevices = @[ ABAggregateSubDeviceDict(inputUID, NO) ];
    } else {
        // Clock / main on output; drift compensation on the input side when distinct.
        subDevices = @[
            ABAggregateSubDeviceDict(outputUID, NO),
            ABAggregateSubDeviceDict(inputUID, YES),
        ];
    }

    NSDictionary *description = @{
        @kAudioAggregateDeviceNameKey : aggregateName,
        @kAudioAggregateDeviceUIDKey : aggregateUID,
        @kAudioAggregateDeviceSubDeviceListKey : subDevices,
        @kAudioAggregateDeviceMainSubDeviceKey : outputUID,
        @kAudioAggregateDeviceClockDeviceKey : outputUID,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
    };

    AudioObjectID aggregateID = kAudioObjectUnknown;
    OSStatus st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description, &aggregateID);
    if (st != noErr || aggregateID == kAudioObjectUnknown) {
        if (error) {
            *error = ABAggregateError(
                3, [NSString stringWithFormat:@"AudioHardwareCreateAggregateDevice failed (status=%d).", (int)st]);
        }
        return nil;
    }

    // Align Aggregate nominal rate to the output device when readable. Do not mutate
    // sub-device rates here (that changes the user's system devices as a side effect).
    Float64 outRate = 0;
    if (ABAggregateReadNominalSampleRate(outputDeviceID, &outRate)) {
        (void)ABAggregateSetNominalSampleRate(aggregateID, outRate);
    }

    ABAggregateDevice *device = [[ABAggregateDevice alloc] init];
    device->_aggregateDeviceID = aggregateID;
    device->_inputSubDeviceID = inputDeviceID;
    device->_outputSubDeviceID = outputDeviceID;
    device->_aggregateUID = [aggregateUID copy];
    device->_active = YES;
    return device;
}

+ (BOOL)deviceIsDuplex:(AudioDeviceID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return NO;
    }
    AudioObjectPropertyAddress inAddr = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope = kAudioObjectPropertyScopeInput,
        .mElement = kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress outAddr = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope = kAudioObjectPropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 inSize = 0;
    UInt32 outSize = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &inAddr, 0, NULL, &inSize) != noErr ||
        inSize < sizeof(AudioBufferList)) {
        return NO;
    }
    if (AudioObjectGetPropertyDataSize(deviceID, &outAddr, 0, NULL, &outSize) != noErr ||
        outSize < sizeof(AudioBufferList)) {
        return NO;
    }
    UInt8 *inBytes = (UInt8 *)calloc(1, (size_t)inSize);
    UInt8 *outBytes = (UInt8 *)calloc(1, (size_t)outSize);
    BOOL duplex = NO;
    if (inBytes != NULL && outBytes != NULL) {
        if (AudioObjectGetPropertyData(deviceID, &inAddr, 0, NULL, &inSize, inBytes) == noErr &&
            AudioObjectGetPropertyData(deviceID, &outAddr, 0, NULL, &outSize, outBytes) == noErr) {
            const AudioBufferList *inList = (const AudioBufferList *)inBytes;
            const AudioBufferList *outList = (const AudioBufferList *)outBytes;
            duplex = (inList->mNumberBuffers > 0 && outList->mNumberBuffers > 0);
        }
    }
    free(inBytes);
    free(outBytes);
    return duplex;
}

+ (BOOL)shouldBindDirectlyWithInputDeviceID:(AudioDeviceID)inputDeviceID
                             outputDeviceID:(AudioDeviceID)outputDeviceID {
    return inputDeviceID != kAudioObjectUnknown && inputDeviceID == outputDeviceID &&
           [self deviceIsDuplex:inputDeviceID];
}

- (void)destroy {
    if (!_active) {
        return;
    }
    AudioObjectID idToDestroy = _aggregateDeviceID;
    _active = NO;
    _aggregateDeviceID = kAudioObjectUnknown;
    if (idToDestroy != kAudioObjectUnknown) {
        (void)AudioHardwareDestroyAggregateDevice(idToDestroy);
    }
}

- (void)dealloc {
    [self destroy];
}

@end
