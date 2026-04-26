#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#import "ABStdoutPCMWriter.h"

void ABShutdownStreaming(void) {
}

@interface ABStdoutPCMWriterContractSpy : ABStdoutPCMWriter
@property(nonatomic, assign) BOOL stubStartResult;
@property(nonatomic, assign) BOOL stubRebuildResult;
@property(nonatomic, strong, nullable) NSError *stubStartError;
@property(nonatomic, strong, nullable) NSError *stubRebuildError;
@property(nonatomic, assign) NSUInteger startCalls;
@property(nonatomic, assign) NSUInteger rebuildCalls;
@property(nonatomic, assign) NSUInteger stopCalls;
@end

static BOOL ABSetStdoutWriterEngineForTest(ABStdoutPCMWriterContractSpy *writer, id value) {
    @try {
        [writer setValue:value forKey:@"_engine"];
        return YES;
    } @catch (NSException *exception) {
        const char *reason = exception.reason.UTF8String;
        fprintf(stderr, "failed to set _engine for test: %s\n", reason != NULL ? reason : "unknown");
        return NO;
    }
}

@implementation ABStdoutPCMWriterContractSpy

- (BOOL)startWithTargetSampleRateHz:(double)targetSampleRateHz quiet:(BOOL)quiet error:(NSError **)error {
    (void)targetSampleRateHz;
    (void)quiet;
    self.startCalls += 1;
    if (!self.stubStartResult) {
        (void)ABSetStdoutWriterEngineForTest(self, nil);
        if (error != NULL) {
            *error = self.stubStartError;
        }
        return NO;
    }
    (void)ABSetStdoutWriterEngineForTest(self, [[AVAudioEngine alloc] init]);
    return YES;
}

- (BOOL)rebuildForRouteChangeWithTargetSampleRateHz:(double)targetSampleRateHz
                                               quiet:(BOOL)quiet
                                               error:(NSError **)error {
    (void)targetSampleRateHz;
    (void)quiet;
    self.rebuildCalls += 1;
    if (!self.stubRebuildResult) {
        (void)ABSetStdoutWriterEngineForTest(self, nil);
        if (error != NULL) {
            *error = self.stubRebuildError;
        }
        return NO;
    }
    (void)ABSetStdoutWriterEngineForTest(self, [[AVAudioEngine alloc] init]);
    return YES;
}

- (void)stop {
    self.stopCalls += 1;
    (void)ABSetStdoutWriterEngineForTest(self, nil);
}

@end

static int ABTestContractIsActiveLifecycle(void) {
    ABStdoutPCMWriterContractSpy *writer = [[ABStdoutPCMWriterContractSpy alloc] initWithStdoutFile:stdout];
    writer.stubStartResult = YES;

    if ([writer ab_isActive]) {
        fprintf(stderr, "expected inactive before start\n");
        return 1;
    }

    NSError *error = nil;
    if (![writer ab_start:&error]) {
        fprintf(stderr, "expected ab_start to succeed\n");
        return 1;
    }
    if (![writer ab_isActive]) {
        fprintf(stderr, "expected active after successful ab_start\n");
        return 1;
    }

    [writer ab_stop];
    if ([writer ab_isActive]) {
        fprintf(stderr, "expected inactive after ab_stop\n");
        return 1;
    }
    if (writer.stopCalls != 1) {
        fprintf(stderr, "expected ab_stop to call stop once, got %lu\n", (unsigned long)writer.stopCalls);
        return 1;
    }

    return 0;
}

static int ABTestContractStartProvidesStructuredErrorWhenUnderlyingErrorMissing(void) {
    ABStdoutPCMWriterContractSpy *writer = [[ABStdoutPCMWriterContractSpy alloc] initWithStdoutFile:stdout];
    writer.stubStartResult = NO;
    writer.stubStartError = nil;

    NSError *error = nil;
    if ([writer ab_start:&error]) {
        fprintf(stderr, "expected ab_start to fail\n");
        return 1;
    }
    if (error == nil) {
        fprintf(stderr, "expected structured error for failed ab_start\n");
        return 1;
    }
    if (![error.domain isEqualToString:ABStdoutPCMWriterErrorDomain]) {
        fprintf(stderr, "unexpected error domain for ab_start: %s\n", error.domain.UTF8String);
        return 1;
    }
    if (error.code != 1001) {
        fprintf(stderr, "unexpected error code for ab_start: %ld\n", (long)error.code);
        return 1;
    }
    NSString *operation = error.userInfo[@"operation"];
    if (![operation isEqualToString:@"ab_start"]) {
        fprintf(stderr, "expected operation=ab_start in error userInfo\n");
        return 1;
    }
    return 0;
}

static int ABTestContractRebuildPreservesStructuredUnderlyingError(void) {
    ABStdoutPCMWriterContractSpy *writer = [[ABStdoutPCMWriterContractSpy alloc] initWithStdoutFile:stdout];
    writer.stubRebuildResult = NO;
    writer.stubRebuildError = [NSError errorWithDomain:ABStdoutPCMWriterErrorDomain
                                                  code:77
                                              userInfo:@{
                                                  NSLocalizedDescriptionKey : @"simulated rebuild failure",
                                                  @"operation" : @"ab_rebuild"
                                              }];

    NSError *error = nil;
    if ([writer ab_rebuild:&error]) {
        fprintf(stderr, "expected ab_rebuild to fail\n");
        return 1;
    }
    if (error == nil) {
        fprintf(stderr, "expected rebuild error to propagate\n");
        return 1;
    }
    if (error.code != 77) {
        fprintf(stderr, "expected original rebuild error code 77, got %ld\n", (long)error.code);
        return 1;
    }
    if (![error.userInfo[@"operation"] isEqualToString:@"ab_rebuild"]) {
        fprintf(stderr, "expected operation=ab_rebuild to be preserved\n");
        return 1;
    }
    return 0;
}

int main(void) {
    @autoreleasepool {
        int failed = 0;
        failed |= ABTestContractIsActiveLifecycle();
        failed |= ABTestContractStartProvidesStructuredErrorWhenUnderlyingErrorMissing();
        failed |= ABTestContractRebuildPreservesStructuredUnderlyingError();
        if (failed != 0) {
            fprintf(stderr, "ABStdoutPCMWriterContractTests failed\n");
        }
        return failed;
    }
}
