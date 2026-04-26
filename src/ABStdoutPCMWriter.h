#import <Foundation/Foundation.h>
#import <stdio.h>
#import "ABDeviceRecoveryCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ABStdoutPCMWriterErrorDomain;

/// Captures the default input, converts to interleaved s16le, and writes PCM bytes only to a `FILE *` (typically `stdout`).
@interface ABStdoutPCMWriter : NSObject <ABDeviceRecoveryEndpoint>

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithStdoutFile:(FILE *)stdoutFile NS_DESIGNATED_INITIALIZER;

/// Stores runtime options used by coordinator-driven `ab_start` / `ab_rebuild`.
- (void)configureRecoveryWithTargetSampleRateHz:(double)targetSampleRateHz quiet:(BOOL)quiet;

/// Starts the engine and tap. If `targetSampleRateHz` is `<= 0`, the destination sample rate matches the input hardware rate.
- (BOOL)startWithTargetSampleRateHz:(double)targetSampleRateHz quiet:(BOOL)quiet error:(NSError * _Nullable *)error;

- (void)stop;

/// Stops the current engine (including tap removal) and starts again with the same target rate policy.
- (BOOL)rebuildForRouteChangeWithTargetSampleRateHz:(double)targetSampleRateHz
                                               quiet:(BOOL)quiet
                                               error:(NSError * _Nullable *)error;

/// Total number of rebuild attempts made through the recovery endpoint bridge (`ab_rebuild:`).
@property(nonatomic, assign, readonly) NSUInteger recoveryRebuildAttemptCount;

@end

NS_ASSUME_NONNULL_END
