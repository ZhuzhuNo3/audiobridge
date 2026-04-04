#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <stdio.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ABDeviceQueryErrorDomain;

typedef NS_ENUM(NSInteger, ABDeviceQueryErrorCode) {
    ABDeviceQueryErrorInvalidInputHyphen = 1,
    ABDeviceQueryErrorResolutionAmbiguous = 2,
    ABDeviceQueryErrorResolutionNone = 3,
};

/// Immutable entry in an ordered device list from Core Audio hardware enumeration.
@interface ABListedDevice : NSObject

@property (nonatomic, readonly) UInt32 deviceID;
@property (nonatomic, readonly, copy) NSString *name;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

/// Queries Core Audio for hardware devices and classifies them by input/output stream capability.
@interface ABDeviceQuery : NSObject

/// Refreshes from hardware, then prints the `--list-all` table to `fp` (stderr or any `FILE *`).
+ (void)printFullDeviceListToFile:(FILE *)fp;

/// Prints up to `maxIn` / `maxOut` devices as decimal id, tab, then name (same order as the full list), then a line pointing to `audiobridge --list-all`.
+ (void)printDevicePreviewToFile:(FILE *)fp maxInputs:(NSUInteger)maxIn maxOutputs:(NSUInteger)maxOut;

/// Ordered devices that expose at least one input stream (see `kAudioDevicePropertyStreamConfiguration`, input scope).
@property (nonatomic, copy, readonly) NSArray<ABListedDevice *> *inputCapableDevices;

/// Ordered devices that expose at least one output stream (same property, output scope).
@property (nonatomic, copy, readonly) NSArray<ABListedDevice *> *outputCapableDevices;

/// Refreshes `inputCapableDevices` and `outputCapableDevices` from the current hardware device list. Before the first refresh, both lists are empty.
- (void)refresh;

/// Core Audio device name for `deviceID`, or a short fallback string if the query fails.
+ (NSString *)deviceNameForAudioDeviceID:(AudioDeviceID)deviceID;

/// Resolves `-i` / `--input` value per design **Value resolution** using the current `inputCapableDevices` (call `refresh` first). `-` is invalid.
- (BOOL)resolveInputString:(NSString *)string
            intoDeviceID:(UInt32 *)outDeviceID
                     error:(NSError * _Nullable *)error;

/// Resolves `-o` / `--output` value. `-` sets `*isStdout = YES` and returns YES (`outDeviceID` is cleared to 0). Otherwise uses `outputCapableDevices` like `resolveInputString:intoDeviceID:error:`.
- (BOOL)resolveOutputString:(NSString *)string
             intoDeviceID:(UInt32 *)outDeviceID
                   isStdout:(BOOL *)isStdout
                      error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END
