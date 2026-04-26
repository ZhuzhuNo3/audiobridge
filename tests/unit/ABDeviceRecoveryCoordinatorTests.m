#import <Foundation/Foundation.h>

#import "ABDeviceRecoveryCoordinator.h"

void ABShutdownStreaming(void) {
}

@interface ABDeviceRecoveryCoordinator (ABTestingHooks)
- (instancetype)initWithEndpoint:(id<ABDeviceRecoveryEndpoint>)endpoint
                    sleepHandler:(nullable void (^)(NSTimeInterval delaySeconds))sleepHandler
                 successTailHook:(nullable void (^)(void))successTailHook;
@end

@interface ABFakeRecoveryEndpoint : NSObject <ABDeviceRecoveryEndpoint>
@property(nonatomic, assign) BOOL startShouldSucceed;
@property(nonatomic, assign) BOOL rebuildShouldSucceed;
@property(nonatomic, assign) BOOL active;
@property(nonatomic, assign) NSUInteger startCalls;
@property(nonatomic, assign) NSUInteger rebuildCalls;
@property(nonatomic, assign) NSUInteger stopCalls;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *rebuildOutcomes;
@property(nonatomic, copy, nullable) void (^onRebuild)(void);
@end

@implementation ABFakeRecoveryEndpoint

- (instancetype)init {
    self = [super init];
    if (self) {
        _rebuildOutcomes = [[NSMutableArray alloc] init];
    }
    return self;
}

- (BOOL)ab_start:(NSError **)error {
    (void)error;
    self.startCalls += 1;
    self.active = self.startShouldSucceed;
    return self.startShouldSucceed;
}

- (BOOL)ab_rebuild:(NSError **)error {
    (void)error;
    self.rebuildCalls += 1;
    if (self.onRebuild != nil) {
        self.onRebuild();
    }
    BOOL shouldSucceed = self.rebuildShouldSucceed;
    if (self.rebuildOutcomes.count > 0) {
        shouldSucceed = [self.rebuildOutcomes.firstObject boolValue];
        [self.rebuildOutcomes removeObjectAtIndex:0];
    }
    self.active = shouldSucceed;
    return shouldSucceed;
}

- (void)ab_stop {
    self.stopCalls += 1;
    self.active = NO;
}

- (BOOL)ab_isActive {
    return self.active;
}

@end

static int ABTestStartupFailureExitsWithoutRetry(void) {
    ABFakeRecoveryEndpoint *endpoint = [[ABFakeRecoveryEndpoint alloc] init];
    endpoint.startShouldSucceed = NO;
    ABDeviceRecoveryCoordinator *coordinator =
        [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:endpoint];

    NSError *error = nil;
    BOOL started = [coordinator startWithError:&error];

    if (started) {
        fprintf(stderr, "expected startup to fail\n");
        return 1;
    }
    if (endpoint.startCalls != 1) {
        fprintf(stderr, "expected exactly one start attempt, got %lu\n", (unsigned long)endpoint.startCalls);
        return 1;
    }
    if (endpoint.rebuildCalls != 0) {
        fprintf(stderr, "expected no rebuild attempts before first success, got %lu\n",
                (unsigned long)endpoint.rebuildCalls);
        return 1;
    }
    if (coordinator.compensationEnabled) {
        fprintf(stderr, "expected compensation to remain disabled after first startup failure\n");
        return 1;
    }
    BOOL recovered = [coordinator recoverAfterUnexpectedStopWithError:&error];
    if (recovered) {
        fprintf(stderr, "expected recoverAfterUnexpectedStopWithError to return NO before first success\n");
        return 1;
    }
    if (coordinator.compensationEnabled) {
        fprintf(stderr, "expected compensation to stay disabled after rejected recovery\n");
        return 1;
    }
    if (endpoint.rebuildCalls != 0) {
        fprintf(stderr, "expected rejected recovery to avoid rebuild calls, got %lu\n",
                (unsigned long)endpoint.rebuildCalls);
        return 1;
    }
    return 0;
}

static int ABTestCompensationEnabledOnlyAfterFirstStartupSuccess(void) {
    ABFakeRecoveryEndpoint *endpoint = [[ABFakeRecoveryEndpoint alloc] init];
    endpoint.startShouldSucceed = YES;
    endpoint.rebuildShouldSucceed = YES;
    ABDeviceRecoveryCoordinator *coordinator =
        [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:endpoint];

    NSError *error = nil;
    if (![coordinator startWithError:&error]) {
        fprintf(stderr, "expected startup to succeed\n");
        return 1;
    }
    if (![coordinator recoverAfterUnexpectedStopWithError:&error]) {
        fprintf(stderr, "expected recovery to run after startup success\n");
        return 1;
    }
    if (endpoint.rebuildCalls != 1) {
        fprintf(stderr, "expected one rebuild attempt, got %lu\n", (unsigned long)endpoint.rebuildCalls);
        return 1;
    }
    return 0;
}

static int ABTestRecoveryBackoffSequenceCapsAtFiveSeconds(void) {
    ABFakeRecoveryEndpoint *endpoint = [[ABFakeRecoveryEndpoint alloc] init];
    endpoint.startShouldSucceed = YES;
    [endpoint.rebuildOutcomes addObjectsFromArray:@[
        @NO, @NO, @NO, @NO, @NO, @NO, @NO, @YES
    ]];

    NSMutableArray<NSNumber *> *recordedDelays = [[NSMutableArray alloc] init];
    ABDeviceRecoveryCoordinator *coordinator =
        [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:endpoint
                                                 sleepHandler:^(NSTimeInterval delaySeconds) {
                                                     [recordedDelays addObject:@(delaySeconds)];
                                                 }];

    NSError *error = nil;
    if (![coordinator startWithError:&error]) {
        fprintf(stderr, "expected startup to succeed before backoff test\n");
        return 1;
    }
    if (![coordinator recoverAfterUnexpectedStopWithError:&error]) {
        fprintf(stderr, "expected recovery loop to eventually succeed\n");
        return 1;
    }

    NSArray<NSNumber *> *expectedDelays = @[
        @0.2, @0.4, @0.8, @1.6, @3.2, @5.0, @5.0
    ];
    if (![recordedDelays isEqualToArray:expectedDelays]) {
        fprintf(stderr, "unexpected backoff sequence\n");
        return 1;
    }
    if (endpoint.rebuildCalls != 8) {
        fprintf(stderr, "expected eight rebuild attempts, got %lu\n", (unsigned long)endpoint.rebuildCalls);
        return 1;
    }
    return 0;
}

static int ABTestRecoveryCoalescesPendingTriggerDuringSingleFlight(void) {
    ABFakeRecoveryEndpoint *endpoint = [[ABFakeRecoveryEndpoint alloc] init];
    endpoint.startShouldSucceed = YES;
    endpoint.rebuildShouldSucceed = YES;

    __block ABDeviceRecoveryCoordinator *coordinator = nil;
    __block BOOL injectedPendingSignals = NO;
    endpoint.onRebuild = ^{
        if (injectedPendingSignals) {
            return;
        }
        injectedPendingSignals = YES;
        NSError *nestedError = nil;
        (void)[coordinator recoverAfterUnexpectedStopWithError:&nestedError];
        (void)[coordinator recoverAfterUnexpectedStopWithError:&nestedError];
        (void)[coordinator recoverAfterUnexpectedStopWithError:&nestedError];
    };

    coordinator = [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:endpoint];
    NSError *error = nil;
    if (![coordinator startWithError:&error]) {
        fprintf(stderr, "expected startup to succeed before pending coalescing test\n");
        return 1;
    }
    if (![coordinator recoverAfterUnexpectedStopWithError:&error]) {
        fprintf(stderr, "expected recovery to succeed with pending trigger\n");
        return 1;
    }
    if (endpoint.rebuildCalls != 2) {
        fprintf(stderr, "expected exactly two rebuilds (single-flight + one pending), got %lu\n",
                (unsigned long)endpoint.rebuildCalls);
        return 1;
    }
    return 0;
}

static int ABTestRecoveryResultDistinguishesCoalescedInFlight(void) {
    ABFakeRecoveryEndpoint *endpoint = [[ABFakeRecoveryEndpoint alloc] init];
    endpoint.startShouldSucceed = YES;
    endpoint.rebuildShouldSucceed = YES;

    __block ABDeviceRecoveryCoordinator *coordinator = nil;
    __block ABDeviceRecoveryResult nestedResult = ABDeviceRecoveryResultRecovered;
    __block BOOL injectedPending = NO;
    endpoint.onRebuild = ^{
        if (injectedPending) {
            return;
        }
        injectedPending = YES;
        NSError *nestedError = nil;
        nestedResult = [coordinator recoverAfterUnexpectedStopWithResult:&nestedError];
    };

    coordinator = [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:endpoint];
    NSError *error = nil;
    if (![coordinator startWithError:&error]) {
        fprintf(stderr, "expected startup to succeed before result distinction test\n");
        return 1;
    }
    ABDeviceRecoveryResult primary = [coordinator recoverAfterUnexpectedStopWithResult:&error];
    if (primary != ABDeviceRecoveryResultRecovered) {
        fprintf(stderr, "expected primary result to be recovered, got %lu\n", (unsigned long)primary);
        return 1;
    }
    if (nestedResult != ABDeviceRecoveryResultCoalescedInFlight) {
        fprintf(stderr, "expected nested result to be coalesced-inflight, got %lu\n", (unsigned long)nestedResult);
        return 1;
    }
    return 0;
}

static int ABTestRecoveryConsumesPendingTriggeredAtSuccessTailWindow(void) {
    ABFakeRecoveryEndpoint *endpoint = [[ABFakeRecoveryEndpoint alloc] init];
    endpoint.startShouldSucceed = YES;
    endpoint.rebuildShouldSucceed = YES;

    __block ABDeviceRecoveryCoordinator *coordinator = nil;
    __block BOOL injectedTailPending = NO;
    coordinator = [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:endpoint
                                                            sleepHandler:nil
                                                         successTailHook:^{
                                                             if (injectedTailPending) {
                                                                 return;
                                                             }
                                                             injectedTailPending = YES;
                                                             NSError *nestedError = nil;
                                                             (void)[coordinator recoverAfterUnexpectedStopWithError:&nestedError];
                                                         }];

    NSError *error = nil;
    if (![coordinator startWithError:&error]) {
        fprintf(stderr, "expected startup to succeed before tail-window test\n");
        return 1;
    }
    if (![coordinator recoverAfterUnexpectedStopWithError:&error]) {
        fprintf(stderr, "expected primary recovery to succeed in tail-window test\n");
        return 1;
    }
    if (endpoint.rebuildCalls != 2) {
        fprintf(stderr, "expected tail-window pending to be consumed once, got %lu rebuilds\n",
                (unsigned long)endpoint.rebuildCalls);
        return 1;
    }
    return 0;
}

static int ABTestListenerAndHeartbeatTriggersShareSingleRecoveryPipeline(void) {
    ABFakeRecoveryEndpoint *endpoint = [[ABFakeRecoveryEndpoint alloc] init];
    endpoint.startShouldSucceed = YES;
    [endpoint.rebuildOutcomes addObjectsFromArray:@[ @NO, @YES, @YES ]];

    NSMutableArray<NSNumber *> *recordedDelays = [[NSMutableArray alloc] init];
    __block ABDeviceRecoveryCoordinator *coordinator = nil;
    __block BOOL heartbeatInjected = NO;
    endpoint.onRebuild = ^{
        if (heartbeatInjected) {
            return;
        }
        heartbeatInjected = YES;
        NSError *nestedError = nil;
        (void)[coordinator recoverAfterUnexpectedStopWithError:&nestedError];
    };

    coordinator = [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:endpoint
                                                            sleepHandler:^(NSTimeInterval delaySeconds) {
                                                                [recordedDelays addObject:@(delaySeconds)];
                                                            }];
    NSError *error = nil;
    if (![coordinator startWithError:&error]) {
        fprintf(stderr, "expected startup to succeed before shared-pipeline test\n");
        return 1;
    }
    if (![coordinator recoverAfterUnexpectedStopWithError:&error]) {
        fprintf(stderr, "expected listener-triggered recovery to converge with heartbeat pending\n");
        return 1;
    }
    if (endpoint.rebuildCalls != 3) {
        fprintf(stderr, "expected three rebuild attempts (fail, success, pending success), got %lu\n",
                (unsigned long)endpoint.rebuildCalls);
        return 1;
    }
    NSArray<NSNumber *> *expectedDelays = @[ @0.2 ];
    if (![recordedDelays isEqualToArray:expectedDelays]) {
        fprintf(stderr, "expected one retry delay for initial failed rebuild before pending success\n");
        return 1;
    }
    return 0;
}

static int ABTestRecoveryResultDistinguishesCompensationDisabled(void) {
    ABFakeRecoveryEndpoint *endpoint = [[ABFakeRecoveryEndpoint alloc] init];
    endpoint.startShouldSucceed = NO;
    ABDeviceRecoveryCoordinator *coordinator =
        [[ABDeviceRecoveryCoordinator alloc] initWithEndpoint:endpoint];

    NSError *error = nil;
    ABDeviceRecoveryResult result = [coordinator recoverAfterUnexpectedStopWithResult:&error];
    if (result != ABDeviceRecoveryResultCompensationDisabled) {
        fprintf(stderr, "expected compensation-disabled result before first successful startup, got %lu\n",
                (unsigned long)result);
        return 1;
    }
    return 0;
}

int main(void) {
    @autoreleasepool {
        int failed = 0;
        failed |= ABTestStartupFailureExitsWithoutRetry();
        failed |= ABTestCompensationEnabledOnlyAfterFirstStartupSuccess();
        failed |= ABTestRecoveryBackoffSequenceCapsAtFiveSeconds();
        failed |= ABTestRecoveryCoalescesPendingTriggerDuringSingleFlight();
        failed |= ABTestRecoveryResultDistinguishesCoalescedInFlight();
        failed |= ABTestRecoveryConsumesPendingTriggeredAtSuccessTailWindow();
        failed |= ABTestListenerAndHeartbeatTriggersShareSingleRecoveryPipeline();
        failed |= ABTestRecoveryResultDistinguishesCompensationDisabled();
        if (failed != 0) {
            fprintf(stderr, "ABDeviceRecoveryCoordinatorTests failed\n");
        }
        return failed;
    }
}
