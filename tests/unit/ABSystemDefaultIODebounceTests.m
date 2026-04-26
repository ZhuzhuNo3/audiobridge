#import <Foundation/Foundation.h>

#import "ABSystemDefaultIO.h"

@interface ABSystemDefaultIO (ABTestingHooks)
- (void)ab_enqueueDebouncedRebuildForDefaultDeviceChange;
@end

static BOOL ABSpinMainRunLoopFor(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                                  beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        }
    }
    return YES;
}

static int ABTestDebounceCoalescesBurstsWithinEightyMilliseconds(void) {
    ABSystemDefaultIO *io = [[ABSystemDefaultIO alloc] init];
    __block NSUInteger callbackCount = 0;
    [io registerForFloatingInput:YES
                  floatingOutput:NO
                    rebuildBlock:^{
                        callbackCount += 1;
                    }];

    [io ab_enqueueDebouncedRebuildForDefaultDeviceChange];
    ABSpinMainRunLoopFor(0.03);
    [io ab_enqueueDebouncedRebuildForDefaultDeviceChange];
    ABSpinMainRunLoopFor(0.03);
    [io ab_enqueueDebouncedRebuildForDefaultDeviceChange];

    ABSpinMainRunLoopFor(0.03);
    if (callbackCount != 0) {
        fprintf(stderr, "expected no callback before 80ms quiet period, got %lu\n",
                (unsigned long)callbackCount);
        [io removeAllListeners];
        return 1;
    }

    ABSpinMainRunLoopFor(0.12);
    if (callbackCount != 1) {
        fprintf(stderr, "expected exactly one coalesced callback, got %lu\n",
                (unsigned long)callbackCount);
        [io removeAllListeners];
        return 1;
    }

    [io removeAllListeners];
    return 0;
}

static int ABTestRemoveAllListenersCancelsPendingDebouncedCallback(void) {
    ABSystemDefaultIO *io = [[ABSystemDefaultIO alloc] init];
    __block NSUInteger callbackCount = 0;
    [io registerForFloatingInput:NO
                  floatingOutput:YES
                    rebuildBlock:^{
                        callbackCount += 1;
                    }];

    [io ab_enqueueDebouncedRebuildForDefaultDeviceChange];
    ABSpinMainRunLoopFor(0.02);
    [io removeAllListeners];
    ABSpinMainRunLoopFor(0.10);

    if (callbackCount != 0) {
        fprintf(stderr, "expected removeAllListeners to cancel pending callback, got %lu\n",
                (unsigned long)callbackCount);
        return 1;
    }
    return 0;
}

int main(void) {
    @autoreleasepool {
        int failed = 0;
        failed |= ABTestDebounceCoalescesBurstsWithinEightyMilliseconds();
        failed |= ABTestRemoveAllListenersCancelsPendingDebouncedCallback();
        if (failed != 0) {
            fprintf(stderr, "ABSystemDefaultIODebounceTests failed\n");
        }
        return failed;
    }
}
