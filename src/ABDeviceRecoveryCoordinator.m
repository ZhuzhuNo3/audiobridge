#import "ABDeviceRecoveryCoordinator.h"

@interface ABDeviceRecoveryCoordinator ()
@property(nonatomic, strong) id<ABDeviceRecoveryEndpoint> endpoint;
@property(nonatomic, assign, readwrite) BOOL compensationEnabled;
@property(nonatomic, copy) void (^sleepHandler)(NSTimeInterval delaySeconds);
@property(nonatomic, copy, nullable) void (^successTailHook)(void);
@property(nonatomic, assign) BOOL recoveryInFlight;
@property(nonatomic, assign) BOOL pendingRecoveryRequested;
@property(nonatomic, assign) NSTimeInterval nextRecoveryDelaySeconds;
@end

@implementation ABDeviceRecoveryCoordinator

- (instancetype)initWithEndpoint:(id<ABDeviceRecoveryEndpoint>)endpoint {
    return [self initWithEndpoint:endpoint sleepHandler:nil successTailHook:nil];
}

- (instancetype)initWithEndpoint:(id<ABDeviceRecoveryEndpoint>)endpoint
                    sleepHandler:(void (^)(NSTimeInterval delaySeconds))sleepHandler {
    self = [super init];
    if (self) {
        _endpoint = endpoint;
        _compensationEnabled = NO;
        _nextRecoveryDelaySeconds = 0.2;
        _successTailHook = nil;
        if (sleepHandler != nil) {
            _sleepHandler = [sleepHandler copy];
        } else {
            _sleepHandler = ^(NSTimeInterval delaySeconds) {
                [NSThread sleepForTimeInterval:delaySeconds];
            };
        }
    }
    return self;
}

- (instancetype)initWithEndpoint:(id<ABDeviceRecoveryEndpoint>)endpoint
                    sleepHandler:(void (^)(NSTimeInterval delaySeconds))sleepHandler
                 successTailHook:(void (^)(void))successTailHook {
    self = [self initWithEndpoint:endpoint sleepHandler:sleepHandler];
    if (self) {
        self.successTailHook = [successTailHook copy];
    }
    return self;
}

- (BOOL)startWithError:(NSError **)error {
    BOOL started = [self.endpoint ab_start:error];
    if (started) {
        self.compensationEnabled = YES;
    }
    return started;
}

- (ABDeviceRecoveryResult)recoverAfterUnexpectedStopWithResult:(NSError **)error {
    if (!self.compensationEnabled) {
        return ABDeviceRecoveryResultCompensationDisabled;
    }
    @synchronized(self) {
        if (self.recoveryInFlight) {
            self.pendingRecoveryRequested = YES;
            return ABDeviceRecoveryResultCoalescedInFlight;
        }
        self.recoveryInFlight = YES;
        self.pendingRecoveryRequested = NO;
    }

    while (YES) {
        BOOL rebuildSucceeded = [self.endpoint ab_rebuild:error];
        if (rebuildSucceeded) {
            self.nextRecoveryDelaySeconds = 0.2;
            if (self.successTailHook != nil) {
                self.successTailHook();
            }
            BOOL shouldConsumePending = NO;
            @synchronized(self) {
                shouldConsumePending = self.pendingRecoveryRequested;
                self.pendingRecoveryRequested = NO;
                if (!shouldConsumePending) {
                    self.recoveryInFlight = NO;
                }
            }
            if (shouldConsumePending) {
                continue;
            }
            return ABDeviceRecoveryResultRecovered;
        }

        NSTimeInterval delaySeconds = self.nextRecoveryDelaySeconds;
        self.sleepHandler(delaySeconds);
        NSTimeInterval doubledDelay = delaySeconds * 2.0;
        self.nextRecoveryDelaySeconds = doubledDelay > 5.0 ? 5.0 : doubledDelay;
    }
}

- (BOOL)recoverAfterUnexpectedStopWithError:(NSError **)error {
    ABDeviceRecoveryResult result = [self recoverAfterUnexpectedStopWithResult:error];
    return result == ABDeviceRecoveryResultRecovered;
}

- (void)stop {
    [self.endpoint ab_stop];
}

@end
