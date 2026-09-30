#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ABHALPassThroughIOErrorDomain;

/// Process-local HAL Output Unit duplex bound to a single `AudioDeviceID` (Aggregate or duplex).
/// Used when `AVAudioEngine` cannot start on a programmatically created Aggregate (`avfaudio -10875`).
/// Never calls `saveAndSet*` / `setDefault*`.
@interface ABHALPassThroughIO : NSObject

@property(nonatomic, assign, readonly) AudioDeviceID boundDeviceID;
@property(nonatomic, assign, readonly, getter=isRunning) BOOL running;
@property(nonatomic, assign, readonly, nullable) AudioUnit audioUnit;

/// YES when `deviceID` reports Core Audio Aggregate class.
+ (BOOL)deviceIsAggregate:(AudioDeviceID)deviceID;

/// Opens HAL I/O on `deviceID`, enables input+output, binds CurrentDevice, starts passthrough render.
- (BOOL)startWithDeviceID:(AudioDeviceID)deviceID error:(NSError * _Nullable * _Nullable)error;

/// Stops and disposes the HAL unit. Idempotent.
- (void)stop;

/// Reads `kAudioOutputUnitProperty_CurrentDevice` from the live unit.
- (BOOL)readCurrentDeviceID:(AudioDeviceID *)outDeviceID;

@end

NS_ASSUME_NONNULL_END
