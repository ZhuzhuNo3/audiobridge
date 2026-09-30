#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <stdio.h>

#import "ABAggregateDevice.h"
#import "ABSystemDefaultIO.h"

static BOOL ABAggregateObjectExists(AudioDeviceID deviceID) {
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
    return st == noErr;
}

static int ABTestCreateDestroyRoundTrip(void) {
    AudioDeviceID defaultIn = kAudioObjectUnknown;
    AudioDeviceID defaultOut = kAudioObjectUnknown;
    NSError *error = nil;
    if (![ABSystemDefaultIO readDefaultInput:&defaultIn error:&error] || defaultIn == kAudioObjectUnknown) {
        fprintf(stderr, "skip: cannot read default input\n");
        return 0;
    }
    if (![ABSystemDefaultIO readDefaultOutput:&defaultOut error:&error] || defaultOut == kAudioObjectUnknown) {
        fprintf(stderr, "skip: cannot read default output\n");
        return 0;
    }

    AudioDeviceID beforeIn = defaultIn;
    AudioDeviceID beforeOut = defaultOut;

    ABAggregateDevice *agg = [ABAggregateDevice createWithInputDeviceID:defaultIn
                                                         outputDeviceID:defaultOut
                                                                  error:&error];
    if (agg == nil) {
        fprintf(stderr, "create Aggregate failed: %s\n", error.localizedDescription.UTF8String ?: "?");
        return 1;
    }
    if (agg.aggregateDeviceID == kAudioObjectUnknown || !agg.isActive) {
        fprintf(stderr, "expected non-zero active Aggregate id\n");
        return 1;
    }
    if (!ABAggregateObjectExists(agg.aggregateDeviceID)) {
        fprintf(stderr, "Aggregate id not readable after create\n");
        return 1;
    }
    if (agg.inputSubDeviceID != defaultIn || agg.outputSubDeviceID != defaultOut) {
        fprintf(stderr, "sub-device ids mismatch\n");
        return 1;
    }

    AudioDeviceID createdID = agg.aggregateDeviceID;
    [agg destroy];
    if (agg.isActive || agg.aggregateDeviceID != kAudioObjectUnknown) {
        fprintf(stderr, "expected inactive Aggregate after destroy\n");
        return 1;
    }
    [agg destroy]; // idempotent

    AudioDeviceID afterIn = kAudioObjectUnknown;
    AudioDeviceID afterOut = kAudioObjectUnknown;
    if (![ABSystemDefaultIO readDefaultInput:&afterIn error:&error] ||
        ![ABSystemDefaultIO readDefaultOutput:&afterOut error:&error]) {
        fprintf(stderr, "failed to re-read system defaults after Aggregate destroy\n");
        return 1;
    }
    if (afterIn != beforeIn || afterOut != beforeOut) {
        fprintf(stderr, "system defaults changed by Aggregate create/destroy\n");
        return 1;
    }
    (void)createdID;
    return 0;
}

static int ABTestInvalidCreateFailsWithoutTouchingDefaults(void) {
    AudioDeviceID beforeIn = kAudioObjectUnknown;
    AudioDeviceID beforeOut = kAudioObjectUnknown;
    NSError *error = nil;
    if (![ABSystemDefaultIO readDefaultInput:&beforeIn error:&error] ||
        ![ABSystemDefaultIO readDefaultOutput:&beforeOut error:&error]) {
        fprintf(stderr, "skip: cannot read defaults for invalid-create test\n");
        return 0;
    }

    NSError *createError = nil;
    ABAggregateDevice *agg = [ABAggregateDevice createWithInputDeviceID:kAudioObjectUnknown
                                                         outputDeviceID:beforeOut
                                                                  error:&createError];
    if (agg != nil) {
        fprintf(stderr, "expected create with unknown input to fail\n");
        [agg destroy];
        return 1;
    }
    if (createError == nil) {
        fprintf(stderr, "expected error object on invalid create\n");
        return 1;
    }

    AudioDeviceID afterIn = kAudioObjectUnknown;
    AudioDeviceID afterOut = kAudioObjectUnknown;
    if (![ABSystemDefaultIO readDefaultInput:&afterIn error:&error] ||
        ![ABSystemDefaultIO readDefaultOutput:&afterOut error:&error]) {
        fprintf(stderr, "failed to re-read defaults after invalid create\n");
        return 1;
    }
    if (afterIn != beforeIn || afterOut != beforeOut) {
        fprintf(stderr, "system defaults changed on invalid Aggregate create\n");
        return 1;
    }
    return 0;
}

static int ABTestShouldBindDirectlyRule(void) {
    // Same unknown ids must not claim direct bind.
    if ([ABAggregateDevice shouldBindDirectlyWithInputDeviceID:kAudioObjectUnknown
                                                outputDeviceID:kAudioObjectUnknown]) {
        fprintf(stderr, "unknown ids should not bind directly\n");
        return 1;
    }
    AudioDeviceID defaultIn = kAudioObjectUnknown;
    AudioDeviceID defaultOut = kAudioObjectUnknown;
    NSError *error = nil;
    if (![ABSystemDefaultIO readDefaultInput:&defaultIn error:&error] ||
        ![ABSystemDefaultIO readDefaultOutput:&defaultOut error:&error]) {
        fprintf(stderr, "skip direct-bind rule: cannot read defaults\n");
        return 0;
    }
    BOOL same = (defaultIn == defaultOut);
    BOOL duplex = [ABAggregateDevice deviceIsDuplex:defaultIn];
    BOOL shouldDirect = [ABAggregateDevice shouldBindDirectlyWithInputDeviceID:defaultIn outputDeviceID:defaultOut];
    if (shouldDirect != (same && duplex)) {
        fprintf(stderr, "direct-bind rule mismatch same=%d duplex=%d got=%d\n", same, duplex, shouldDirect);
        return 1;
    }
    if (defaultIn != defaultOut) {
        if ([ABAggregateDevice shouldBindDirectlyWithInputDeviceID:defaultIn outputDeviceID:defaultOut]) {
            fprintf(stderr, "distinct in/out must not bind directly\n");
            return 1;
        }
    }
    return 0;
}

int main(void) {
    @autoreleasepool {
        int failed = 0;
        failed |= ABTestCreateDestroyRoundTrip();
        failed |= ABTestInvalidCreateFailsWithoutTouchingDefaults();
        failed |= ABTestShouldBindDirectlyRule();
        if (failed != 0) {
            fprintf(stderr, "ABAggregateDeviceTests failed\n");
        }
        return failed;
    }
}
