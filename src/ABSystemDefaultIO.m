#import "ABSystemDefaultIO.h"

#import <dispatch/dispatch.h>
#import <stdatomic.h>

NSString *const ABSystemDefaultIOErrorDomain = @"ABSystemDefaultIOError";

static NSError *ABSystemDefaultIONSError(OSStatus status, NSString *message) {
    return [NSError errorWithDomain:ABSystemDefaultIOErrorDomain
                               code:(NSInteger)status
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   [NSString stringWithFormat:@"%@ (OSStatus %d)", message, (int)status],
                           }];
}

static BOOL ABSystemDefaultIOGetDefaultDevice(AudioObjectPropertySelector selector,
                                              AudioDeviceID *outDeviceID,
                                              NSError **error) {
    if (outDeviceID == NULL) {
        return NO;
    }
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 size = (UInt32)sizeof(deviceID);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &deviceID);
    if (st != noErr) {
        if (error) {
            *error = ABSystemDefaultIONSError(st, @"Failed to read default audio device");
        }
        return NO;
    }
    *outDeviceID = deviceID;
    return YES;
}

static BOOL ABSystemDefaultIOSetDefaultDevice(AudioObjectPropertySelector selector,
                                              AudioDeviceID deviceID,
                                              NSError **error) {
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 size = (UInt32)sizeof(deviceID);
    OSStatus st = AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, size, &deviceID);
    if (st != noErr) {
        if (error) {
            *error = ABSystemDefaultIONSError(st, @"Failed to set default audio device");
        }
        return NO;
    }
    return YES;
}

@interface ABSystemDefaultIO ()
@property (nonatomic, readwrite) AudioDeviceID savedInputDeviceID;
@property (nonatomic, readwrite) AudioDeviceID savedOutputDeviceID;
@property (nonatomic, readwrite) BOOL didChangeInput;
@property (nonatomic, readwrite) BOOL didChangeOutput;
- (void)ab_enqueueDebouncedRebuildForDefaultDeviceChange;
@end

static OSStatus ABSystemDefaultIOHardwareDefaultListener(AudioObjectID objectID,
                                                         UInt32 addressCount,
                                                         const AudioObjectPropertyAddress *addresses,
                                                         void *clientData) {
    (void)objectID;
    (void)addressCount;
    (void)addresses;
    ABSystemDefaultIO *io = (__bridge ABSystemDefaultIO *)clientData;
    [io ab_enqueueDebouncedRebuildForDefaultDeviceChange];
    return noErr;
}

@implementation ABSystemDefaultIO {
    void (^_debounceRebuildBlock)(void);
    _Atomic uint64_t _debounceGeneration;
    BOOL _inputListenerRegistered;
    BOOL _outputListenerRegistered;
}

+ (BOOL)readDefaultInput:(AudioDeviceID *)outDeviceID error:(NSError **)error {
    return ABSystemDefaultIOGetDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, outDeviceID, error);
}

+ (BOOL)readDefaultOutput:(AudioDeviceID *)outDeviceID error:(NSError **)error {
    return ABSystemDefaultIOGetDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, outDeviceID, error);
}

+ (BOOL)setDefaultInput:(AudioDeviceID)deviceID error:(NSError **)error {
    return ABSystemDefaultIOSetDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, deviceID, error);
}

+ (BOOL)setDefaultOutput:(AudioDeviceID)deviceID error:(NSError **)error {
    return ABSystemDefaultIOSetDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, deviceID, error);
}

- (BOOL)saveAndSetInput:(AudioDeviceID)deviceID error:(NSError **)error {
    AudioDeviceID current = kAudioObjectUnknown;
    if (![ABSystemDefaultIO readDefaultInput:&current error:error]) {
        return NO;
    }
    self.savedInputDeviceID = current;
    if (current != deviceID) {
        if (![ABSystemDefaultIO setDefaultInput:deviceID error:error]) {
            return NO;
        }
        self.didChangeInput = YES;
    } else {
        self.didChangeInput = NO;
    }
    return YES;
}

- (BOOL)saveAndSetOutput:(AudioDeviceID)deviceID error:(NSError **)error {
    AudioDeviceID current = kAudioObjectUnknown;
    if (![ABSystemDefaultIO readDefaultOutput:&current error:error]) {
        return NO;
    }
    self.savedOutputDeviceID = current;
    if (current != deviceID) {
        if (![ABSystemDefaultIO setDefaultOutput:deviceID error:error]) {
            return NO;
        }
        self.didChangeOutput = YES;
    } else {
        self.didChangeOutput = NO;
    }
    return YES;
}

- (void)restoreAll {
    if (self.didChangeInput) {
        NSError *restoreError = nil;
        if ([ABSystemDefaultIO setDefaultInput:self.savedInputDeviceID error:&restoreError]) {
            self.didChangeInput = NO;
        }
    }
    if (self.didChangeOutput) {
        NSError *restoreError = nil;
        if ([ABSystemDefaultIO setDefaultOutput:self.savedOutputDeviceID error:&restoreError]) {
            self.didChangeOutput = NO;
        }
    }
}

- (void)dealloc {
    [self removeAllListeners];
}

- (void)ab_enqueueDebouncedRebuildForDefaultDeviceChange {
    uint64_t token = atomic_fetch_add_explicit(&_debounceGeneration, 1, memory_order_relaxed) + 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC * 0.08)),
                       dispatch_get_main_queue(), ^{
                           if (atomic_load_explicit(&_debounceGeneration, memory_order_relaxed) != token) {
                               return;
                           }
                           void (^block)(void) = _debounceRebuildBlock;
                           if (block) {
                               block();
                           }
                       });
    });
}

- (void)registerForFloatingInput:(BOOL)floatingInput
                  floatingOutput:(BOOL)floatingOutput
                    rebuildBlock:(void (^)(void))rebuildBlock {
    [self removeAllListeners];
    if ((!floatingInput && !floatingOutput) || rebuildBlock == nil) {
        return;
    }
    _debounceRebuildBlock = [rebuildBlock copy];

    AudioObjectPropertyAddress inputAddress = {
        .mSelector = kAudioHardwarePropertyDefaultInputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress outputAddress = {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    void *client = (__bridge void *)self;
    if (floatingInput) {
        if (AudioObjectAddPropertyListener(kAudioObjectSystemObject, &inputAddress,
                                             ABSystemDefaultIOHardwareDefaultListener,
                                             client) == noErr) {
            _inputListenerRegistered = YES;
        }
    }
    if (floatingOutput) {
        if (AudioObjectAddPropertyListener(kAudioObjectSystemObject, &outputAddress,
                                             ABSystemDefaultIOHardwareDefaultListener,
                                             client) == noErr) {
            _outputListenerRegistered = YES;
        }
    }
}

- (void)removeAllListeners {
    AudioObjectPropertyAddress inputAddress = {
        .mSelector = kAudioHardwarePropertyDefaultInputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress outputAddress = {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    void *client = (__bridge void *)self;
    if (_inputListenerRegistered) {
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &inputAddress,
                                          ABSystemDefaultIOHardwareDefaultListener, client);
        _inputListenerRegistered = NO;
    }
    if (_outputListenerRegistered) {
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &outputAddress,
                                          ABSystemDefaultIOHardwareDefaultListener, client);
        _outputListenerRegistered = NO;
    }
    atomic_fetch_add_explicit(&_debounceGeneration, 1, memory_order_relaxed);
    _debounceRebuildBlock = nil;
}

@end
