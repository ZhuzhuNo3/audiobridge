#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ABPassThroughEngineErrorDomain;

/// Pass-through from the default input to the default output using `AVAudioEngine`.
/// Each route rebuild uses a new engine instance (no in-place `reset`).
@interface ABPassThroughEngine : NSObject

/// Stops any running engine, then starts a fresh engine with `inputNode` → `mainMixerNode`, `format:nil`.
/// When `quiet` is `NO`, logs speaker-path diagnostics to stderr after a successful start.
- (BOOL)startWithQuiet:(BOOL)quiet error:(NSError * _Nullable *)error;

/// Equivalent to `startWithQuiet:NO error:`.
- (BOOL)startWithError:(NSError * _Nullable *)error;

- (void)stop;

/// Stops the current engine (wall time logged unless `quiet`), then starts a new `AVAudioEngine` with the same graph.
- (BOOL)rebuildForRouteChangeWithQuiet:(BOOL)quiet error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END
