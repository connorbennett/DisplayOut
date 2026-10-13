//
//  DeckLinkBridge.mm
//  DisplayOut
//

#import "DeckLinkBridge.h"
#include "SDK/DeckLinkAPI.h"

#include <atomic>
#include <deque>
#include <mutex>
#include <vector>

static const int kPoolSize = 6;
static const size_t kPrerollFrames = 3;

static NSError *DLMakeError(NSString *message, HRESULT hr) {
    NSString *text = hr == S_OK ? message : [NSString stringWithFormat:@"%@ (0x%08X)", message, (unsigned)hr];
    return [NSError errorWithDomain:@"DeckLink" code:hr userInfo:@{NSLocalizedDescriptionKey: text}];
}

static bool DLIsEqualIID(REFIID a, REFIID b) {
    return memcmp(&a, &b, sizeof(REFIID)) == 0;
}

static NSString *DLTakeString(CFStringRef string) {
    return string ? (__bridge_transfer NSString *)string : @"";
}

#pragma mark - DLDisplayMode

@implementation DLDisplayMode

- (instancetype)initWithMode:(IDeckLinkDisplayMode *)mode {
    if ((self = [super init])) {
        CFStringRef name = NULL;
        mode->GetName(&name);
        _name = DLTakeString(name);
        _modeID = mode->GetDisplayMode();
        _width = mode->GetWidth();
        _height = mode->GetHeight();
        BMDTimeValue duration = 1;
        BMDTimeScale scale = 30;
        mode->GetFrameRate(&duration, &scale);
        _frameDuration = duration;
        _timeScale = scale;
        BMDFieldDominance dominance = mode->GetFieldDominance();
        _interlaced = dominance == bmdLowerFieldFirst || dominance == bmdUpperFieldFirst;
    }
    return self;
}

@end

#pragma mark - DLDevice

@interface DLDevice ()
@property (nonatomic, readonly) IDeckLink *deckLink;
@property (nonatomic, readonly) IDeckLinkOutput *output;
@end

@implementation DLDevice

/// Returns nil for devices without a usable video output (e.g. capture-only hardware).
- (nullable instancetype)initWithDeckLink:(IDeckLink *)deckLink {
    if (!(self = [super init])) return nil;

    IDeckLinkOutput *output = NULL;
    if (deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&output) != S_OK || !output) return nil;
    _output = output;
    _deckLink = deckLink;
    _deckLink->AddRef();

    CFStringRef string = NULL;
    deckLink->GetDisplayName(&string);
    _displayName = DLTakeString(string);
    string = NULL;
    deckLink->GetModelName(&string);
    _modelName = DLTakeString(string);

    NSMutableArray<DLDisplayMode *> *modes = [NSMutableArray array];
    IDeckLinkDisplayModeIterator *iterator = NULL;
    if (output->GetDisplayModeIterator(&iterator) == S_OK && iterator) {
        IDeckLinkDisplayMode *mode = NULL;
        while (iterator->Next(&mode) == S_OK && mode) {
            [modes addObject:[[DLDisplayMode alloc] initWithMode:mode]];
            mode->Release();
            mode = NULL;
        }
        iterator->Release();
    }
    _modes = [modes copy];
    return _modes.count > 0 ? self : nil;
}

- (void)dealloc {
    if (_output) _output->Release();
    if (_deckLink) _deckLink->Release();
}

@end

#pragma mark - DLDeviceManager

@interface DLDeviceManager ()
- (void)deckLinkArrived:(IDeckLink *)deckLink;
- (void)deckLinkRemoved:(IDeckLink *)deckLink;
@end

class DLDeviceCallback : public IDeckLinkDeviceNotificationCallback {
public:
    explicit DLDeviceCallback(DLDeviceManager *manager) : _manager(manager), _refCount(1) {}

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (DLIsEqualIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID)) || DLIsEqualIID(iid, IID_IDeckLinkDeviceNotificationCallback)) {
            *ppv = this;
            AddRef();
            return S_OK;
        }
        *ppv = NULL;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++_refCount; }
    ULONG Release() override {
        ULONG count = --_refCount;
        if (count == 0) delete this;
        return count;
    }

    // Called on a DeckLink API thread; hop to main where the device list lives.
    HRESULT DeckLinkDeviceArrived(IDeckLink *deckLink) override {
        deckLink->AddRef();
        DLDeviceManager *manager = _manager;
        dispatch_async(dispatch_get_main_queue(), ^{
            [manager deckLinkArrived:deckLink];
            deckLink->Release();
        });
        return S_OK;
    }
    HRESULT DeckLinkDeviceRemoved(IDeckLink *deckLink) override {
        deckLink->AddRef();
        DLDeviceManager *manager = _manager;
        dispatch_async(dispatch_get_main_queue(), ^{
            [manager deckLinkRemoved:deckLink];
            deckLink->Release();
        });
        return S_OK;
    }

private:
    virtual ~DLDeviceCallback() {}
    __weak DLDeviceManager *_manager;
    std::atomic<ULONG> _refCount;
};

@implementation DLDeviceManager {
    IDeckLinkDiscovery *_discovery;
    DLDeviceCallback *_callback;
    NSMutableArray<DLDevice *> *_devices;
}

- (instancetype)init {
    if ((self = [super init])) {
        _devices = [NSMutableArray array];
        _discovery = CreateDeckLinkDiscoveryInstance();
        _driverAvailable = _discovery != NULL;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_discovery) _discovery->Release();
}

- (NSArray<DLDevice *> *)devices {
    return [_devices copy];
}

- (void)start {
    if (!_discovery || _callback) return;
    _callback = new DLDeviceCallback(self);
    _discovery->InstallDeviceNotifications(_callback);
}

- (void)stop {
    if (!_callback) return;
    _discovery->UninstallDeviceNotifications();
    _callback->Release();
    _callback = NULL;
}

- (void)deckLinkArrived:(IDeckLink *)deckLink {
    for (DLDevice *device in _devices) {
        if (device.deckLink == deckLink) return;
    }
    DLDevice *device = [[DLDevice alloc] initWithDeckLink:deckLink];
    if (!device) return;
    [_devices addObject:device];
    if (self.devicesChanged) self.devicesChanged();
}

- (void)deckLinkRemoved:(IDeckLink *)deckLink {
    NSUInteger index = [_devices indexOfObjectPassingTest:^BOOL(DLDevice *device, NSUInteger idx, BOOL *stop) {
        return device.deckLink == deckLink;
    }];
    if (index == NSNotFound) return;
    [_devices removeObjectAtIndex:index];
    if (self.devicesChanged) self.devicesChanged();
}

@end

#pragma mark - DLOutput

@interface DLOutput ()
- (void)frameCompletedWithResult:(BMDOutputFrameCompletionResult)result;
@end

class DLOutputCallback : public IDeckLinkVideoOutputCallback {
public:
    explicit DLOutputCallback(DLOutput *owner) : _owner(owner), _refCount(1) {}

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (DLIsEqualIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID)) || DLIsEqualIID(iid, IID_IDeckLinkVideoOutputCallback)) {
            *ppv = this;
            AddRef();
            return S_OK;
        }
        *ppv = NULL;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++_refCount; }
    ULONG Release() override {
        ULONG count = --_refCount;
        if (count == 0) delete this;
        return count;
    }

    HRESULT ScheduledFrameCompleted(IDeckLinkVideoFrame *completedFrame, BMDOutputFrameCompletionResult result) override {
        [_owner frameCompletedWithResult:result];
        return S_OK;
    }
    HRESULT ScheduledPlaybackHasStopped() override { return S_OK; }

private:
    virtual ~DLOutputCallback() {}
    __weak DLOutput *_owner;
    std::atomic<ULONG> _refCount;
};

struct DLPoolFrame {
    IDeckLinkMutableVideoFrame *frame;
    int pending;  // times this frame is currently queued in the hardware
};

static void DLFillBlack(IDeckLinkMutableVideoFrame *frame) {
    void *bytes = NULL;
    if (frame->GetBytes(&bytes) != S_OK || !bytes) return;
    size_t length = (size_t)frame->GetRowBytes() * (size_t)frame->GetHeight();
    if (frame->GetPixelFormat() == bmdFormat8BitYUV) {
        const uint8_t uyvy[4] = {0x80, 0x10, 0x80, 0x10};
        memset_pattern4(bytes, uyvy, length);
    } else {
        const uint8_t bgra[4] = {0x00, 0x00, 0x00, 0xFF};
        memset_pattern4(bytes, bgra, length);
    }
}

@implementation DLOutput {
    DLDevice *_device;
    IDeckLinkOutput *_output;
    DLOutputCallback *_callback;

    // Used when the hardware can't take BGRA directly: capture -> _scratch (BGRA) -> pool (YUV).
    IDeckLinkVideoConversion *_converter;
    IDeckLinkMutableVideoFrame *_scratch;

    std::mutex _sendMutex;   // serialises send/start/stop; never taken by the hardware callback
    std::mutex _stateMutex;  // guards everything below; shared with the hardware callback
    std::vector<DLPoolFrame> _pool;
    std::deque<int> _inFlight;  // pool indices in the order they were scheduled
    int _latest;                // pool index of the newest complete frame
    int _lastWritten;
    BOOL _running;
    BMDTimeValue _frameDuration;
    BMDTimeScale _timeScale;
    BMDTimeValue _nextTime;

    long _width;
    long _height;

    std::atomic<uint64_t> _completed;
    std::atomic<uint64_t> _late;
    std::atomic<uint64_t> _dropped;
    std::atomic<uint64_t> _skipped;
}

- (instancetype)initWithDevice:(DLDevice *)device {
    if ((self = [super init])) {
        _device = device;
        _output = device.output;
        _output->AddRef();
        _callback = new DLOutputCallback(self);
        _pixelFormatName = @"";
    }
    return self;
}

- (void)dealloc {
    [self stop];
    _callback->Release();
    _output->Release();
}

- (DLOutputStats)stats {
    return (DLOutputStats){_completed.load(), _late.load(), _dropped.load(), _skipped.load()};
}

- (BOOL)startWithMode:(DLDisplayMode *)mode error:(NSError **)error {
    std::lock_guard<std::mutex> send(_sendMutex);
    if (_running) return YES;

    // Prefer handing BGRA straight to the hardware; fall back to converting to 8-bit YUV.
    BMDPixelFormat pixelFormat = bmdFormat8BitBGRA;
    BMDDisplayModeSupport support = bmdDisplayModeNotSupported;
    HRESULT hr = _output->DoesSupportVideoMode(mode.modeID, pixelFormat, bmdVideoOutputFlagDefault, &support, NULL);
    if (hr != S_OK || support == bmdDisplayModeNotSupported) {
        pixelFormat = bmdFormat8BitYUV;
        support = bmdDisplayModeNotSupported;
        hr = _output->DoesSupportVideoMode(mode.modeID, pixelFormat, bmdVideoOutputFlagDefault, &support, NULL);
        if (hr != S_OK || support == bmdDisplayModeNotSupported) {
            if (error) *error = DLMakeError([NSString stringWithFormat:@"%@ can't output %@.", _device.displayName, mode.name], S_OK);
            return NO;
        }
    }

    hr = _output->EnableVideoOutput(mode.modeID, bmdVideoOutputFlagDefault);
    if (hr != S_OK) {
        if (error) *error = DLMakeError(@"Couldn't enable video output. The device may be in use by another application.", hr);
        return NO;
    }

    _width = mode.width;
    _height = mode.height;
    _frameDuration = mode.frameDuration;
    _timeScale = mode.timeScale;
    _completed = 0;
    _late = 0;
    _dropped = 0;
    _skipped = 0;

    BOOL ok = YES;
    int32_t rowBytes = (int32_t)_width * (pixelFormat == bmdFormat8BitYUV ? 2 : 4);
    for (int i = 0; i < kPoolSize && ok; i++) {
        IDeckLinkMutableVideoFrame *frame = NULL;
        hr = _output->CreateVideoFrame((int32_t)_width, (int32_t)_height, rowBytes, pixelFormat, bmdFrameFlagDefault, &frame);
        ok = hr == S_OK && frame;
        if (ok) {
            DLFillBlack(frame);
            _pool.push_back({frame, 0});
        }
    }
    if (ok && pixelFormat != bmdFormat8BitBGRA) {
        _converter = CreateVideoConversionInstance();
        hr = _output->CreateVideoFrame((int32_t)_width, (int32_t)_height, (int32_t)_width * 4, bmdFormat8BitBGRA, bmdFrameFlagDefault, &_scratch);
        ok = _converter && hr == S_OK && _scratch;
        if (ok) DLFillBlack(_scratch);
    }

    if (ok) {
        std::lock_guard<std::mutex> state(_stateMutex);
        _output->SetScheduledFrameCompletionCallback(_callback);
        _latest = 0;
        _lastWritten = 0;
        _nextTime = 0;
        _running = YES;
        for (size_t i = 0; i < kPrerollFrames; i++) [self scheduleLatestLocked];
        ok = _inFlight.size() == kPrerollFrames;
    }
    if (ok) {
        hr = _output->StartScheduledPlayback(0, _timeScale, 1.0);
        ok = hr == S_OK;
    }
    if (!ok) {
        [self teardown];
        if (error) *error = DLMakeError(@"Couldn't start playback on the device.", hr);
        return NO;
    }

    _pixelFormatName = pixelFormat == bmdFormat8BitBGRA ? @"8-bit BGRA" : @"8-bit YUV";
    return YES;
}

- (void)stop {
    std::lock_guard<std::mutex> send(_sendMutex);
    if (!_running) return;
    [self teardown];
}

/// Caller holds _sendMutex but not _stateMutex (the hardware may call back while stopping).
- (void)teardown {
    {
        std::lock_guard<std::mutex> state(_stateMutex);
        _running = NO;
    }
    _output->StopScheduledPlayback(0, NULL, 0);
    _output->SetScheduledFrameCompletionCallback(NULL);
    if (_blanksOnStop && !_pool.empty()) {
        // Playback has stopped, so no pool frame is on air; reuse one to leave black on the output.
        DLFillBlack(_pool[0].frame);
        _output->DisplayVideoFrameSync(_pool[0].frame);
    }
    _output->DisableVideoOutput();
    {
        std::lock_guard<std::mutex> state(_stateMutex);
        for (DLPoolFrame &entry : _pool) entry.frame->Release();
        _pool.clear();
        _inFlight.clear();
    }
    if (_scratch) { _scratch->Release(); _scratch = NULL; }
    if (_converter) { _converter->Release(); _converter = NULL; }
}

/// Queues the newest frame for the next output slot. Caller holds _stateMutex.
- (BOOL)scheduleLatestLocked {
    DLPoolFrame &entry = _pool[_latest];
    if (_output->ScheduleVideoFrame(entry.frame, _nextTime, _frameDuration, _timeScale) != S_OK) return NO;
    entry.pending++;
    _inFlight.push_back(_latest);
    _nextTime += _frameDuration;
    return YES;
}

/// Hardware callback: one queued frame has left the queue, so queue another to replace it.
- (void)frameCompletedWithResult:(BMDOutputFrameCompletionResult)result {
    std::lock_guard<std::mutex> state(_stateMutex);
    // Completions arrive in schedule order, so the oldest in-flight entry is the one that finished.
    if (!_inFlight.empty()) {
        _pool[_inFlight.front()].pending--;
        _inFlight.pop_front();
    }
    if (!_running) return;

    _completed++;
    if (result == bmdOutputFrameDisplayedLate) _late++;
    if (result == bmdOutputFrameDropped) _dropped++;

    if (result == bmdOutputFrameDisplayedLate || result == bmdOutputFrameDropped) {
        // If we've fallen behind the hardware clock, skip ahead rather than queueing frames
        // in the past (which would all be dropped too).
        BMDTimeValue streamTime = 0;
        double speed = 0;
        if (_output->GetScheduledStreamTime(_timeScale, &streamTime, &speed) == S_OK && _nextTime <= streamTime) {
            _nextTime = (streamTime / _frameDuration + 2) * _frameDuration;
        }
    }
    [self scheduleLatestLocked];
}

- (void)sendPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    std::lock_guard<std::mutex> send(_sendMutex);
    if (!_running) return;
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA) return;

    // Pick a pool frame the hardware isn't holding and that isn't the current repeat frame.
    int index = -1;
    {
        std::lock_guard<std::mutex> state(_stateMutex);
        for (int i = 1; i <= kPoolSize; i++) {
            int candidate = (_lastWritten + i) % kPoolSize;
            if (candidate != _latest && _pool[candidate].pending == 0) {
                index = candidate;
                break;
            }
        }
    }
    if (index < 0) {
        _skipped++;
        return;
    }
    _lastWritten = index;

    IDeckLinkMutableVideoFrame *target = _converter ? _scratch : _pool[index].frame;
    void *targetBytes = NULL;
    if (target->GetBytes(&targetBytes) != S_OK || !targetBytes) return;
    size_t targetRowBytes = (size_t)target->GetRowBytes();

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    const uint8_t *source = (const uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
    size_t sourceWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t sourceHeight = CVPixelBufferGetHeight(pixelBuffer);

    // Centre the source in the output frame, cropping whatever doesn't fit. Borders stay black
    // from when the frame was created.
    size_t copyWidth = MIN(sourceWidth, (size_t)_width);
    size_t copyHeight = MIN(sourceHeight, (size_t)_height);
    size_t sourceX = (sourceWidth - copyWidth) / 2;
    size_t sourceY = (sourceHeight - copyHeight) / 2;
    size_t targetX = ((size_t)_width - copyWidth) / 2;
    size_t targetY = ((size_t)_height - copyHeight) / 2;
    if (source) {
        for (size_t row = 0; row < copyHeight; row++) {
            memcpy((uint8_t *)targetBytes + (targetY + row) * targetRowBytes + targetX * 4,
                   source + (sourceY + row) * sourceRowBytes + sourceX * 4,
                   copyWidth * 4);
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    if (_converter && _converter->ConvertFrame(_scratch, _pool[index].frame) != S_OK) return;

    std::lock_guard<std::mutex> state(_stateMutex);
    _latest = index;
    // Normally the completion callback keeps the queue full; top it up if a schedule ever failed.
    while (_inFlight.size() < kPrerollFrames) {
        if (![self scheduleLatestLocked]) break;
    }
}

@end
