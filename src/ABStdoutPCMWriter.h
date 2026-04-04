#import <Foundation/Foundation.h>
#import <stdio.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ABStdoutPCMWriterErrorDomain;

/// Captures the default input, converts to interleaved s16le, and writes PCM bytes only to a `FILE *` (typically `stdout`).
@interface ABStdoutPCMWriter : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithStdoutFile:(FILE *)stdoutFile NS_DESIGNATED_INITIALIZER;

/// Starts the engine and tap. If `targetSampleRateHz` is `<= 0`, the destination sample rate matches the input hardware rate.
- (BOOL)startWithTargetSampleRateHz:(double)targetSampleRateHz quiet:(BOOL)quiet error:(NSError * _Nullable *)error;

- (void)stop;

/// Stops the current engine (including tap removal) and starts again with the same target rate policy.
- (BOOL)rebuildForRouteChangeWithTargetSampleRateHz:(double)targetSampleRateHz
                                               quiet:(BOOL)quiet
                                               error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END
