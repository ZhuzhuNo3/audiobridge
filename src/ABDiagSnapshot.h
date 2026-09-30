#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ABLogLevel) {
    ABLogLevelDebug = 0,
    ABLogLevelInfo = 1,
    ABLogLevelWarn = 2,
    ABLogLevelError = 3,
};

/// Session-level DEBUG detail channel (`-d`). Gated together with quiet: emits only when enabled and not quiet.
FOUNDATION_EXPORT void ABDiagSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL ABDiagIsEnabled(void);

/// Session quiet (`-q`). When YES, all runtime logs (INFO/WARN/ERROR/DEBUG) are no-ops.
FOUNDATION_EXPORT void ABDiagSetSessionQuiet(BOOL quiet);
FOUNDATION_EXPORT BOOL ABDiagSessionQuiet(void);

/// Unified runtime log line: `YYYY-MM-DD HH:MM:SS.mmm  FILE:LINE  LEVEL  message`.
/// DEBUG requires diag enabled and non-quiet; other levels require non-quiet only.
FOUNDATION_EXPORT void ABLogWrite(ABLogLevel level, const char *file, int line, NSString *message);

#define ABLogDebug(fmt, ...)                                                                                           \
    ABLogWrite(ABLogLevelDebug, __FILE__, __LINE__, [NSString stringWithFormat:(fmt), ##__VA_ARGS__])
#define ABLogInfo(fmt, ...)                                                                                            \
    ABLogWrite(ABLogLevelInfo, __FILE__, __LINE__, [NSString stringWithFormat:(fmt), ##__VA_ARGS__])
#define ABLogWarn(fmt, ...)                                                                                            \
    ABLogWrite(ABLogLevelWarn, __FILE__, __LINE__, [NSString stringWithFormat:(fmt), ##__VA_ARGS__])
#define ABLogError(fmt, ...)                                                                                           \
    ABLogWrite(ABLogLevelError, __FILE__, __LINE__, [NSString stringWithFormat:(fmt), ##__VA_ARGS__])

/// Optional configuration / binding context owned by the speaker path caller.
@interface ABDiagDeviceContext : NSObject
@property(nonatomic, assign) BOOL inputConfigured;
@property(nonatomic, assign) BOOL outputConfigured;
@property(nonatomic, assign) AudioDeviceID configInputDeviceID;
@property(nonatomic, assign) AudioDeviceID configOutputDeviceID;
@property(nonatomic, assign) AudioDeviceID boundDeviceID;
@property(nonatomic, assign) AudioDeviceID aggregateDeviceID;
@property(nonatomic, assign) BOOL configWaiting;
@property(nonatomic, assign) BOOL floatingInputListenerRegistered;
@property(nonatomic, assign) BOOL floatingOutputListenerRegistered;
@property(nonatomic, assign) AudioDeviceID savedInputDeviceID;
@property(nonatomic, assign) AudioDeviceID savedOutputDeviceID;
@property(nonatomic, assign) BOOL didChangeInput;
@property(nonatomic, assign) BOOL didChangeOutput;
@end

/// Engine fields supplied by `ABPassThroughEngine` (seq ownership stays there).
@interface ABDiagEngineContext : NSObject
@property(nonatomic, strong, nullable) AVAudioEngine *engine;
/// When Aggregate I/O uses HAL instead of `AVAudioEngine`, the live unit for CurrentDevice readback.
@property(nonatomic, assign, nullable) AudioUnit halAudioUnit;
@property(nonatomic, assign) BOOL halIsRunning;
@property(nonatomic, assign) BOOL abIsActive;
@property(nonatomic, assign) NSUInteger rebuildAttemptCount;
@property(nonatomic, assign) NSUInteger configChangeSeq;
@property(nonatomic, assign) NSUInteger rebuildSeq;
@property(nonatomic, assign) NSTimeInterval configChangeUnixTs;
@property(nonatomic, assign) NSTimeInterval rebuildUnixTs;
@property(nonatomic, copy, nullable) NSString *lastRenderSummary;
@end

/// Captures the shared `device` section as `key=value` fragments (no leading spaces).
/// System defaults use `system_default_in_*` / `system_default_out_*` (not engine bind).
/// Intent Aggregate/duplex id is `bound_device_id`; actual AU CurrentDevice is under the engine section.
FOUNDATION_EXPORT NSString *ABDiagCaptureDeviceSection(ABDiagDeviceContext *_Nullable ctx);

/// Captures the shared `engine` section; seq / active flags come from `ctx`.
/// When an `AVAudioEngine` or HAL unit is present, emits `actual_*_device_id` from CurrentDevice readback.
FOUNDATION_EXPORT NSString *ABDiagCaptureEngineSection(ABDiagEngineContext *_Nullable ctx);

/// Emits a DEBUG event/snapshot line in the unified format. No-op when diag disabled or quiet.
FOUNDATION_EXPORT void ABDiagEmit(NSString *kind, NSString *reason, NSString *_Nullable triggerSource,
                                  ABDiagDeviceContext *_Nullable deviceCtx, ABDiagEngineContext *_Nullable engineCtx,
                                  NSDictionary<NSString *, NSString *> *_Nullable extra);

/// Convenience wrappers.
FOUNDATION_EXPORT void ABDiagEmitEvent(NSString *reason, NSString *_Nullable triggerSource,
                                       ABDiagDeviceContext *_Nullable deviceCtx,
                                       ABDiagEngineContext *_Nullable engineCtx,
                                       NSDictionary<NSString *, NSString *> *_Nullable extra);

FOUNDATION_EXPORT void ABDiagEmitSnapshot(NSString *reason, NSString *_Nullable triggerSource,
                                          ABDiagDeviceContext *_Nullable deviceCtx,
                                          ABDiagEngineContext *_Nullable engineCtx,
                                          NSDictionary<NSString *, NSString *> *_Nullable extra);

/// Thin event (HAL / debounce): reason + fields only; no heavy property reads.
FOUNDATION_EXPORT void ABDiagEmitThinEvent(NSString *reason, NSDictionary<NSString *, NSString *> *_Nullable fields);

NS_ASSUME_NONNULL_END
