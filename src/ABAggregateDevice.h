#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ABAggregateDeviceErrorDomain;

/// Creates and destroys a process-private Core Audio Aggregate for a configured input/output pair.
/// Never calls `saveAndSet*` / `setDefault*`.
@interface ABAggregateDevice : NSObject

@property(nonatomic, assign, readonly) AudioDeviceID aggregateDeviceID;
@property(nonatomic, assign, readonly) AudioDeviceID inputSubDeviceID;
@property(nonatomic, assign, readonly) AudioDeviceID outputSubDeviceID;
@property(nonatomic, copy, readonly, nullable) NSString *aggregateUID;

/// YES when this instance currently owns a live aggregate id.
@property(nonatomic, assign, readonly, getter=isActive) BOOL active;

/// Creates a private Aggregate whose sub-devices are `inputDeviceID` and `outputDeviceID`.
/// On failure returns nil and fills `error` without modifying system defaults.
+ (nullable instancetype)createWithInputDeviceID:(AudioDeviceID)inputDeviceID
                                  outputDeviceID:(AudioDeviceID)outputDeviceID
                                           error:(NSError * _Nullable * _Nullable)error;

/// YES when `deviceID` exposes both input and output streams.
+ (BOOL)deviceIsDuplex:(AudioDeviceID)deviceID;

/// Combination rule: same id and duplex → bind that id directly (no Aggregate).
+ (BOOL)shouldBindDirectlyWithInputDeviceID:(AudioDeviceID)inputDeviceID
                             outputDeviceID:(AudioDeviceID)outputDeviceID;

/// Destroys the owned Aggregate if active. Idempotent.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
