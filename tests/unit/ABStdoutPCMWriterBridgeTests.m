#import <Foundation/Foundation.h>

#import "ABStdoutPCMWriter.h"

void ABShutdownStreaming(void) {
}

@interface ABStdoutPCMWriterSpy : ABStdoutPCMWriter
@property(nonatomic, assign) NSUInteger startEngineCalls;
@property(nonatomic, assign) double lastTargetSampleRateHz;
@property(nonatomic, assign) BOOL lastQuiet;
@property(nonatomic, assign) BOOL stubbedStartResult;
@end

@implementation ABStdoutPCMWriterSpy

- (BOOL)ab_startEngineWithTargetSampleRateHz:(double)targetSampleRateHz quiet:(BOOL)quiet error:(NSError **)error {
    (void)error;
    self.startEngineCalls += 1;
    self.lastTargetSampleRateHz = targetSampleRateHz;
    self.lastQuiet = quiet;
    return self.stubbedStartResult;
}

@end

static int ABTestBridgeStartUsesPreservedRuntimeParameters(void) {
    ABStdoutPCMWriterSpy *writer = [[ABStdoutPCMWriterSpy alloc] initWithStdoutFile:stdout];
    writer.stubbedStartResult = YES;

    NSError *error = nil;
    if (![writer startWithTargetSampleRateHz:48000 quiet:YES error:&error]) {
        fprintf(stderr, "expected initial configured start to succeed\n");
        return 1;
    }
    if (![writer ab_start:&error]) {
        fprintf(stderr, "expected bridge start to succeed\n");
        return 1;
    }
    if (writer.lastTargetSampleRateHz != 48000) {
        fprintf(stderr, "expected bridge start to preserve targetSampleRateHz=48000, got %.0f\n",
                writer.lastTargetSampleRateHz);
        return 1;
    }
    if (!writer.lastQuiet) {
        fprintf(stderr, "expected bridge start to preserve quiet=YES\n");
        return 1;
    }
    return 0;
}

static int ABTestBridgeRebuildUsesPreservedRuntimeParameters(void) {
    ABStdoutPCMWriterSpy *writer = [[ABStdoutPCMWriterSpy alloc] initWithStdoutFile:stdout];
    writer.stubbedStartResult = YES;

    NSError *error = nil;
    if (![writer startWithTargetSampleRateHz:44100 quiet:YES error:&error]) {
        fprintf(stderr, "expected initial configured start to succeed\n");
        return 1;
    }
    if (![writer ab_rebuild:&error]) {
        fprintf(stderr, "expected bridge rebuild to succeed\n");
        return 1;
    }
    if (writer.lastTargetSampleRateHz != 44100) {
        fprintf(stderr, "expected bridge rebuild to preserve targetSampleRateHz=44100, got %.0f\n",
                writer.lastTargetSampleRateHz);
        return 1;
    }
    if (!writer.lastQuiet) {
        fprintf(stderr, "expected bridge rebuild to preserve quiet=YES\n");
        return 1;
    }
    return 0;
}

int main(void) {
    @autoreleasepool {
        int failed = 0;
        failed |= ABTestBridgeStartUsesPreservedRuntimeParameters();
        failed |= ABTestBridgeRebuildUsesPreservedRuntimeParameters();
        if (failed != 0) {
            fprintf(stderr, "ABStdoutPCMWriterBridgeTests failed\n");
        }
        return failed;
    }
}
