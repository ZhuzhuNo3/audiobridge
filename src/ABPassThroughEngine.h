#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import "ABDeviceRecoveryCoordinator.h"
#import "ABDiagSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ABPassThroughEngineErrorDomain;

/// Pass-through from a bound duplex device (Aggregate or same-device I/O).
/// Same-device duplex uses `AVAudioEngine` + `CurrentDevice`.
/// Programmatic Aggregate uses HAL Output Unit passthrough (`ABHALPassThroughIO`) because
/// `AVAudioEngine` restart-after-Aggregate-bind fails with `avfaudio -10875` on macOS.
/// Each route rebuild uses a fresh I/O instance (no in-place `reset`).
@interface ABPassThroughEngine : NSObject <ABDeviceRecoveryEndpoint>

/// Device id used for `kAudioOutputUnitProperty_CurrentDevice` on start/rebuild.
/// `kAudioObjectUnknown` means no bind attempt (legacy / tests); production speaker path always sets a real id.
@property(nonatomic, assign) AudioDeviceID boundDeviceID;

/// Stops any running I/O, then starts the transport for `boundDeviceID`
/// (HAL for Aggregate, `AVAudioEngine` for same-device duplex).
/// When `quiet` is `NO`, logs speaker-path diagnostics to stderr after a successful start.
- (BOOL)startWithQuiet:(BOOL)quiet error:(NSError * _Nullable *)error;

/// Equivalent to `startWithQuiet:NO error:`.
- (BOOL)startWithError:(NSError * _Nullable *)error;

- (void)stop;

/// Stores runtime options used by coordinator-driven `ab_start` / `ab_rebuild`.
- (void)configureRecoveryWithQuiet:(BOOL)quiet diag:(BOOL)diag;

/// Backward-compatible wrapper: `diag` defaults to `NO`.
- (void)configureRecoveryWithQuiet:(BOOL)quiet;

/// Stops current I/O (wall time logged unless `quiet`), then starts a fresh transport for the same bind
/// (HAL Aggregate or duplex `AVAudioEngine`).
- (BOOL)rebuildForRouteChangeWithQuiet:(BOOL)quiet error:(NSError * _Nullable *)error;

/// Snapshot helper for shared diag capture (read-only view of engine + seq fields).
- (ABDiagEngineContext *)diagEngineContext;

/// Whether the underlying I/O reports running (`AVAudioEngine.isRunning` or HAL started).
- (BOOL)diagEngineIsRunning;

/// Total number of rebuild attempts made through the recovery endpoint bridge (`ab_rebuild:`).
@property(nonatomic, assign, readonly) NSUInteger recoveryRebuildAttemptCount;

/// Authoritative diagnostic sequence counters (only meaningful when diag is enabled).
@property(nonatomic, assign, readonly) NSUInteger configChangeSeq;
@property(nonatomic, assign, readonly) NSUInteger rebuildSeq;
@property(nonatomic, assign, readonly) NSTimeInterval configChangeUnixTs;
@property(nonatomic, assign, readonly) NSTimeInterval rebuildUnixTs;

@end

NS_ASSUME_NONNULL_END
