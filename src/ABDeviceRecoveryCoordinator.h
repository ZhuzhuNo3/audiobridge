#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, ABDeviceRecoveryResult) {
    ABDeviceRecoveryResultRecovered = 0,
    ABDeviceRecoveryResultCoalescedInFlight = 1,
    ABDeviceRecoveryResultFailed = 2,
    ABDeviceRecoveryResultCompensationDisabled = 3,
};

@protocol ABDeviceRecoveryEndpoint <NSObject>

- (BOOL)ab_start:(NSError * _Nullable *)error;
- (BOOL)ab_rebuild:(NSError * _Nullable *)error;
- (void)ab_stop;
- (BOOL)ab_isActive;

@end

@interface ABDeviceRecoveryCoordinator : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithEndpoint:(id<ABDeviceRecoveryEndpoint>)endpoint;
- (instancetype)initWithEndpoint:(id<ABDeviceRecoveryEndpoint>)endpoint
                    sleepHandler:(nullable void (^)(NSTimeInterval delaySeconds))sleepHandler NS_DESIGNATED_INITIALIZER;

- (BOOL)startWithError:(NSError * _Nullable *)error;
- (ABDeviceRecoveryResult)recoverAfterUnexpectedStopWithResult:(NSError * _Nullable *)error;
- (BOOL)recoverAfterUnexpectedStopWithError:(NSError * _Nullable *)error;
- (void)stop;

@property(nonatomic, assign, readonly) BOOL compensationEnabled;

@end

NS_ASSUME_NONNULL_END
