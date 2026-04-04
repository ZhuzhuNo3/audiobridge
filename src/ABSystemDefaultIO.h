#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ABSystemDefaultIOErrorDomain;

/// Reads and writes system-wide default input/output devices (`kAudioHardwarePropertyDefault*`).
@interface ABSystemDefaultIO : NSObject

+ (BOOL)readDefaultInput:(AudioDeviceID *)outDeviceID error:(NSError * _Nullable *)error;
+ (BOOL)readDefaultOutput:(AudioDeviceID *)outDeviceID error:(NSError * _Nullable *)error;
+ (BOOL)setDefaultInput:(AudioDeviceID)deviceID error:(NSError * _Nullable *)error;
+ (BOOL)setDefaultOutput:(AudioDeviceID)deviceID error:(NSError * _Nullable *)error;

/// Values captured by `saveAndSet*`; meaningful when the matching `didChange*` flag is YES.
@property (nonatomic, readonly) AudioDeviceID savedInputDeviceID;
@property (nonatomic, readonly) AudioDeviceID savedOutputDeviceID;
@property (nonatomic, readonly) BOOL didChangeInput;
@property (nonatomic, readonly) BOOL didChangeOutput;

/// Saves the current default input, then sets the system default to `deviceID` when it differs.
- (BOOL)saveAndSetInput:(AudioDeviceID)deviceID error:(NSError * _Nullable *)error;
/// Saves the current default output, then sets the system default to `deviceID` when it differs.
- (BOOL)saveAndSetOutput:(AudioDeviceID)deviceID error:(NSError * _Nullable *)error;
/// Restores defaults that were changed by `saveAndSet*`. Repeated calls are safe.
- (void)restoreAll;

/// Subscribes to default-device changes for directions that are not pinned (`floating* == YES`).
/// The `rebuildBlock` is invoked on the main queue after **80 ms** of quiescence (coalesced).
/// Register/remove from the main thread. `removeAllListeners` is invoked from `-dealloc`.
- (void)registerForFloatingInput:(BOOL)floatingInput
                  floatingOutput:(BOOL)floatingOutput
                    rebuildBlock:(void (^ _Nullable)(void))rebuildBlock;

/// Removes Core Audio listeners, invalidates pending debounced callbacks, and clears the rebuild block.
- (void)removeAllListeners;

@end

NS_ASSUME_NONNULL_END
