#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <stdio.h>

#import "ABAggregateDevice.h"
#import "ABHALPassThroughIO.h"
#import "ABSystemDefaultIO.h"

/// Requires readable system default I/O. Skip-as-pass (return 0 without asserting) is forbidden:
/// `make test-unit` must not go green without executing Aggregate HAL start + readback.
/// Catches the Aggregate-sticky / AVAudioEngine -10875 class of failure:
/// HAL must start on a private Aggregate and CurrentDevice readback must match intent.
static int ABTestHALAggregateStartAndReadback(void) {
    AudioDeviceID defaultIn = kAudioObjectUnknown;
    AudioDeviceID defaultOut = kAudioObjectUnknown;
    NSError *error = nil;
    if (![ABSystemDefaultIO readDefaultInput:&defaultIn error:&error] || defaultIn == kAudioObjectUnknown) {
        fprintf(stderr,
                "FAIL: cannot read default input (HAL Aggregate test requires audio devices; "
                "skip-as-pass is forbidden)\n");
        return 1;
    }
    if (![ABSystemDefaultIO readDefaultOutput:&defaultOut error:&error] || defaultOut == kAudioObjectUnknown) {
        fprintf(stderr,
                "FAIL: cannot read default output (HAL Aggregate test requires audio devices; "
                "skip-as-pass is forbidden)\n");
        return 1;
    }

    AudioDeviceID beforeIn = defaultIn;
    AudioDeviceID beforeOut = defaultOut;

    ABAggregateDevice *agg = [ABAggregateDevice createWithInputDeviceID:defaultIn
                                                         outputDeviceID:defaultOut
                                                                  error:&error];
    if (agg == nil) {
        fprintf(stderr, "Aggregate create failed: %s\n", error.localizedDescription.UTF8String ?: "?");
        return 1;
    }
    AudioDeviceID aggID = agg.aggregateDeviceID;
    if (![ABHALPassThroughIO deviceIsAggregate:aggID]) {
        fprintf(stderr, "created device id=%u not reported as Aggregate class\n", (unsigned)aggID);
        [agg destroy];
        return 1;
    }

    ABHALPassThroughIO *hal = [[ABHALPassThroughIO alloc] init];
    NSError *startError = nil;
    if (![hal startWithDeviceID:aggID error:&startError]) {
        fprintf(stderr, "HAL Aggregate start failed (this is the -10875-class gap): %s\n",
                startError.localizedDescription.UTF8String ?: "?");
        [agg destroy];
        return 1;
    }
    if (!hal.isRunning) {
        fprintf(stderr, "HAL reported not running after start\n");
        [hal stop];
        [agg destroy];
        return 1;
    }
    AudioDeviceID actual = kAudioObjectUnknown;
    if (![hal readCurrentDeviceID:&actual] || actual != aggID) {
        fprintf(stderr, "HAL CurrentDevice readback mismatch intent=%u actual=%u\n", (unsigned)aggID,
                (unsigned)actual);
        [hal stop];
        [agg destroy];
        return 1;
    }

    [hal stop];
    [agg destroy];

    AudioDeviceID afterIn = kAudioObjectUnknown;
    AudioDeviceID afterOut = kAudioObjectUnknown;
    if (![ABSystemDefaultIO readDefaultInput:&afterIn error:&error] ||
        ![ABSystemDefaultIO readDefaultOutput:&afterOut error:&error]) {
        fprintf(stderr, "failed to re-read system defaults after HAL Aggregate test\n");
        return 1;
    }
    if (afterIn != beforeIn || afterOut != beforeOut) {
        fprintf(stderr, "system defaults changed by HAL Aggregate start/stop\n");
        return 1;
    }
    return 0;
}

int main(void) {
    @autoreleasepool {
        int rc = ABTestHALAggregateStartAndReadback();
        if (rc != 0) {
            return rc;
        }
        printf("ABHALPassThroughIOTests: ok\n");
        return 0;
    }
}
