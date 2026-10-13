//
//  DeckLinkBridge.h
//  DisplayOut
//
//  Objective-C facade over the Blackmagic DeckLink C++ API so it can be used from Swift.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// A video format (resolution + frame rate) supported by a device's output.
@interface DLDisplayMode : NSObject
@property (nonatomic, readonly) uint32_t modeID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) int64_t frameDuration;
@property (nonatomic, readonly) int64_t timeScale;
@property (nonatomic, readonly) BOOL interlaced;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A connected DeckLink / UltraStudio device that has a video output.
@interface DLDevice : NSObject
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, copy) NSString *modelName;
@property (nonatomic, readonly, copy) NSArray<DLDisplayMode *> *modes;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Tracks device arrival and removal. `devices` and `devicesChanged` are used on the main thread.
@interface DLDeviceManager : NSObject
/// NO when the Desktop Video drivers are not installed.
@property (nonatomic, readonly) BOOL driverAvailable;
@property (nonatomic, readonly, copy) NSArray<DLDevice *> *devices;
@property (nonatomic, copy, nullable) void (^devicesChanged)(void);
- (void)start;
- (void)stop;
@end

typedef struct {
    uint64_t completed;   // frames the hardware has finished with
    uint64_t late;        // frames displayed late
    uint64_t dropped;     // frames the hardware dropped
    uint64_t skipped;     // captured frames discarded because no buffer was free
} DLOutputStats;

/// Drives scheduled playback on one device. Feed it frames with -sendPixelBuffer:; the most
/// recent one is repeated at the output frame rate until a newer one arrives.
@interface DLOutput : NSObject
@property (nonatomic, readonly) DLOutputStats stats;
/// When YES, -stop leaves a black frame on the output instead of the last frame sent.
@property (nonatomic) BOOL blanksOnStop;
/// e.g. "8-bit BGRA" or "8-bit YUV"; empty until started.
@property (nonatomic, readonly, copy) NSString *pixelFormatName;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDevice:(DLDevice *)device NS_SWIFT_NAME(init(device:));
- (BOOL)startWithMode:(DLDisplayMode *)mode error:(NSError **)error NS_SWIFT_NAME(start(mode:));
- (void)stop;
/// Accepts a 32BGRA buffer of any size; it is centred (and cropped if larger) in the output
/// frame. Safe to call from any thread.
- (void)sendPixelBuffer:(CVPixelBufferRef)pixelBuffer NS_SWIFT_NAME(send(_:));
@end

NS_ASSUME_NONNULL_END
