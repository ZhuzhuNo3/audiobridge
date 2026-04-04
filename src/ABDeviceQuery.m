#import "ABDeviceQuery.h"

#import <CoreAudio/CoreAudio.h>
#import <errno.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>

NSString *const ABDeviceQueryErrorDomain = @"ABDeviceQueryError";

@interface ABListedDevice ()
- (instancetype)initWithDeviceID:(UInt32)deviceID name:(NSString *)name;
@end

@implementation ABListedDevice

- (instancetype)initWithDeviceID:(UInt32)deviceID name:(NSString *)name {
    self = [super init];
    if (self) {
        _deviceID = deviceID;
        _name = [name copy];
    }
    return self;
}

@end

static NSArray<NSNumber *> *ABCopyHardwareDeviceIDs(void) {
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    UInt32 dataSize = 0;
    OSStatus status =
        AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &dataSize);
    if (status != noErr || dataSize == 0) {
        return @[];
    }

    NSUInteger count = dataSize / sizeof(AudioObjectID);
    AudioObjectID *deviceIDs = (AudioObjectID *)calloc(count, sizeof(AudioObjectID));
    if (deviceIDs == NULL) {
        return @[];
    }

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &dataSize, deviceIDs);
    if (status != noErr) {
        free(deviceIDs);
        return @[];
    }

    NSUInteger actualCount = dataSize / sizeof(AudioObjectID);
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:actualCount];
    for (NSUInteger i = 0; i < actualCount; i++) {
        [result addObject:@(deviceIDs[i])];
    }
    free(deviceIDs);
    return result;
}

static BOOL ABDeviceHasStreamsInScope(AudioObjectID deviceID, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL, &dataSize);
    if (status != noErr || dataSize < sizeof(AudioBufferList)) {
        return NO;
    }

    UInt8 *bytes = (UInt8 *)calloc(1, (size_t)dataSize);
    if (bytes == NULL) {
        return NO;
    }

    status = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &dataSize, bytes);
    BOOL hasStreams = NO;
    if (status == noErr) {
        const AudioBufferList *list = (const AudioBufferList *)bytes;
        hasStreams = list->mNumberBuffers > 0;
    }
    free(bytes);
    return hasStreams;
}

static NSString *ABCopyDeviceName(AudioObjectID deviceID) {
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyDeviceNameCFString,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    CFStringRef nameRef = NULL;
    UInt32 dataSize = (UInt32)sizeof(nameRef);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &dataSize, &nameRef);
    if (status != noErr || nameRef == NULL) {
        return [NSString stringWithFormat:@"Device %u", (unsigned int)deviceID];
    }
    return (__bridge_transfer NSString *)nameRef;
}

static void ABFprintDeviceLine(FILE *fp, UInt32 deviceID, NSString *name) {
    fprintf(fp, "%u\t", (unsigned int)deviceID);
    const char *utf8 = name.length > 0 ? name.UTF8String : "";
    if (utf8 == NULL) {
        utf8 = "";
    }
    fputs(utf8, fp);
    fputc('\n', fp);
}

static BOOL ABStringIsNonEmptyAllASCIIDigits(NSString *string) {
    if (string.length == 0) {
        return NO;
    }
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar character = [string characterAtIndex:i];
        if (character < '0' || character > '9') {
            return NO;
        }
    }
    return YES;
}

static BOOL ABParseDecimalUInt32(NSString *string, UInt32 *outValue) {
    const char *cstr = string.UTF8String;
    if (cstr == NULL) {
        return NO;
    }
    errno = 0;
    char *endPointer = NULL;
    unsigned long value = strtoul(cstr, &endPointer, 10);
    if (endPointer == cstr || *endPointer != '\0') {
        return NO;
    }
    if (errno == ERANGE || value > UINT32_MAX) {
        return NO;
    }
    *outValue = (UInt32)value;
    return YES;
}

static NSArray<ABListedDevice *> *ABDevicesWithNameContainingSubstring(NSArray<ABListedDevice *> *devices,
                                                                         NSString *substring) {
    NSMutableArray<ABListedDevice *> *hits = [NSMutableArray array];
    for (ABListedDevice *device in devices) {
        NSRange range = [device.name rangeOfString:substring];
        if (range.location != NSNotFound) {
            [hits addObject:device];
        }
    }
    return hits;
}

static NSString *ABCandidateLinesForDevices(NSArray<ABListedDevice *> *devices) {
    NSMutableString *buffer = [NSMutableString string];
    NSUInteger limit = MIN((NSUInteger)10, devices.count);
    for (NSUInteger i = 0; i < limit; i++) {
        ABListedDevice *device = devices[i];
        [buffer appendFormat:@"%u\t%@\n", (unsigned int)device.deviceID, device.name];
    }
    return buffer;
}

static BOOL ABResolveSpecifierAgainstDevices(NSArray<ABListedDevice *> *devices,
                                             NSString *string,
                                             NSString *directionNoun,
                                             UInt32 *outDeviceID,
                                             NSError **error) {
    if (ABStringIsNonEmptyAllASCIIDigits(string)) {
        UInt32 parsed = 0;
        if (ABParseDecimalUInt32(string, &parsed)) {
            for (ABListedDevice *device in devices) {
                if (device.deviceID == parsed) {
                    *outDeviceID = parsed;
                    return YES;
                }
            }
        }
    }

    NSArray<ABListedDevice *> *matches = ABDevicesWithNameContainingSubstring(devices, string);
    if (matches.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:ABDeviceQueryErrorDomain
                                         code:ABDeviceQueryErrorResolutionNone
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : [NSString stringWithFormat:
                                             @"No %@ device matches \"%@\". Use `audiobridge --list-all` to list devices.",
                                             directionNoun, string],
                                     }];
        }
        return NO;
    }
    if (matches.count > 1) {
        if (error) {
            NSString *candidates = ABCandidateLinesForDevices(matches);
            *error = [NSError errorWithDomain:ABDeviceQueryErrorDomain
                                         code:ABDeviceQueryErrorResolutionAmbiguous
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : [NSString stringWithFormat:
                                             @"Multiple %@ devices match \"%@\". Up to 10 candidates:\n%@",
                                             directionNoun, string, candidates],
                                     }];
        }
        return NO;
    }

    *outDeviceID = matches.firstObject.deviceID;
    return YES;
}

@implementation ABDeviceQuery {
    NSArray<ABListedDevice *> *_inputCapableDevices;
    NSArray<ABListedDevice *> *_outputCapableDevices;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _inputCapableDevices = @[];
        _outputCapableDevices = @[];
    }
    return self;
}

- (NSArray<ABListedDevice *> *)inputCapableDevices {
    return [_inputCapableDevices copy];
}

- (NSArray<ABListedDevice *> *)outputCapableDevices {
    return [_outputCapableDevices copy];
}

- (void)refresh {
    NSArray<NSNumber *> *ids = ABCopyHardwareDeviceIDs();
    NSMutableArray<ABListedDevice *> *inputs = [NSMutableArray array];
    NSMutableArray<ABListedDevice *> *outputs = [NSMutableArray array];

    for (NSNumber *boxedID in ids) {
        AudioObjectID deviceID = (AudioObjectID)boxedID.unsignedIntValue;

        NSString *name = ABCopyDeviceName(deviceID);

        if (ABDeviceHasStreamsInScope(deviceID, kAudioDevicePropertyScopeInput)) {
            ABListedDevice *entry = [[ABListedDevice alloc] initWithDeviceID:deviceID name:name];
            [inputs addObject:entry];
        }
        if (ABDeviceHasStreamsInScope(deviceID, kAudioDevicePropertyScopeOutput)) {
            ABListedDevice *entry = [[ABListedDevice alloc] initWithDeviceID:deviceID name:name];
            [outputs addObject:entry];
        }
    }

    _inputCapableDevices = [inputs copy];
    _outputCapableDevices = [outputs copy];
}

+ (void)printFullDeviceListToFile:(FILE *)fp {
    ABDeviceQuery *query = [[ABDeviceQuery alloc] init];
    [query refresh];
    fprintf(fp, "# audiobridge device list\n");
    fprintf(fp, "\n");
    fprintf(fp, "INPUT\n");
    for (ABListedDevice *device in query.inputCapableDevices) {
        ABFprintDeviceLine(fp, device.deviceID, device.name);
    }
    fprintf(fp, "\n");
    fprintf(fp, "OUTPUT\n");
    for (ABListedDevice *device in query.outputCapableDevices) {
        ABFprintDeviceLine(fp, device.deviceID, device.name);
    }
}

+ (NSString *)deviceNameForAudioDeviceID:(AudioDeviceID)deviceID {
    return ABCopyDeviceName(deviceID);
}

+ (void)printDevicePreviewToFile:(FILE *)fp maxInputs:(NSUInteger)maxIn maxOutputs:(NSUInteger)maxOut {
    ABDeviceQuery *query = [[ABDeviceQuery alloc] init];
    [query refresh];
    NSArray<ABListedDevice *> *inputs = query.inputCapableDevices;
    NSArray<ABListedDevice *> *outputs = query.outputCapableDevices;

    fprintf(fp, "INPUT\n");
    NSUInteger inLimit = MIN(maxIn, inputs.count);
    for (NSUInteger i = 0; i < inLimit; i++) {
        ABListedDevice *device = inputs[i];
        ABFprintDeviceLine(fp, device.deviceID, device.name);
    }
    fprintf(fp, "\n");
    fprintf(fp, "OUTPUT\n");
    NSUInteger outLimit = MIN(maxOut, outputs.count);
    for (NSUInteger i = 0; i < outLimit; i++) {
        ABListedDevice *device = outputs[i];
        ABFprintDeviceLine(fp, device.deviceID, device.name);
    }
    fprintf(fp, "\n");
    fputs("For the complete device list, run: audiobridge --list-all\n", fp);
}

- (BOOL)resolveInputString:(NSString *)string intoDeviceID:(UInt32 *)outDeviceID error:(NSError **)error {
    if (outDeviceID == NULL) {
        return NO;
    }
    if ([string isEqualToString:@"-"]) {
        if (error) {
            *error = [NSError errorWithDomain:ABDeviceQueryErrorDomain
                                         code:ABDeviceQueryErrorInvalidInputHyphen
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"Input device cannot be \"-\" (stdin is not a supported audio source).",
                                     }];
        }
        return NO;
    }
    return ABResolveSpecifierAgainstDevices(_inputCapableDevices, string, @"input", outDeviceID, error);
}

- (BOOL)resolveOutputString:(NSString *)string
             intoDeviceID:(UInt32 *)outDeviceID
                   isStdout:(BOOL *)isStdout
                      error:(NSError **)error {
    if (outDeviceID == NULL || isStdout == NULL) {
        return NO;
    }
    if ([string isEqualToString:@"-"]) {
        *isStdout = YES;
        *outDeviceID = 0;
        return YES;
    }
    *isStdout = NO;
    return ABResolveSpecifierAgainstDevices(_outputCapableDevices, string, @"output", outDeviceID, error);
}

@end
