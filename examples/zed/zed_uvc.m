// A REAL ZED reading into the shared region the driver reads from.
//
//   clang -fobjc-arc -O2 -framework AVFoundation -framework Foundation -framework CoreMedia \
//         -framework CoreVideo -o zig-out/bin/zed-uvc examples/zed/zed_uvc.m
//   ./zig-out/bin/zed-uvc                     # then camera-sensor --model zed2i as usual
//
// This is fake-zed's replacement when a camera is actually plugged in: same shared region,
// same layout, same driver on the other side. Written in Objective-C because the capture API
// is AVFoundation, which makes it a useful test of its own -- the handoff has to be a
// contract two languages can both implement, not an arrangement one Zig program has with
// itself.
//
// WHAT IT CANNOT DO, and this is the whole caveat: it does not produce depth.
//
// A ZED's depth is the ZED SDK's proprietary stereo matcher, needs CUDA, and there is no ZED
// SDK for macOS. Over UVC the camera hands over the raw side-by-side stereo pair and nothing
// else. So the mono plane here is genuinely the camera's left image, at the camera's real
// rate and real jitter, and the depth plane is ZERO throughout -- which the chain already
// treats as "no depth here", the normal condition for a stereo camera over much of any
// frame. Everything except the depth VALUES is exercised against real hardware.
//
// It also writes no calibration block. The factory intrinsics live in a per-serial file the
// SDK fetches, which is not on this machine, so the driver's own nominal values are the
// honest fallback and its "no calibration within the wait" notice is the correct outcome.
//
// One mode is offered here and it is not the one the spec table headlines: 1344x376 at
// 15 fps, which is 2x672x376 side by side. The camera can do 1080p30 through the SDK; it
// cannot through this path. Ask the camera what it has rather than believing a table.

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// ---------------------------------------------------------------- the shared region layout
//
// Mirrored from examples/zed/shm.zig. The duplication is real and deliberate: this file is
// the second implementation of that contract, which is what makes the contract worth having.
// Any change to the offsets there has to be made here, and the magic and version are what
// stop a mismatch from being read as data.

static const char kMagic[8] = { 'Z', 'E', 'D', 'S', 'H', 'M', '1', 0 };
static const uint32_t kVersion = 1;

#define HEADER_BYTES     4096
#define SENSORS_SLOTS    512
#define SENSORS_BYTES    64
#define SENSORS_REGION   (SENSORS_SLOTS * SENSORS_BYTES)
#define SLOT_HEADER      16

#define OFF_MAGIC        0
#define OFF_VERSION      8
#define OFF_SLOTS        12
#define OFF_WIDTH        16
#define OFF_HEIGHT       18
#define OFF_FPS          20
#define OFF_MODEL        22
#define OFF_HAS_SENSORS  23
#define OFF_PAYLOAD_LEN  24
#define OFF_SLOT_STRIDE  28
#define OFF_PUBLISHED    32

// zed.Model.zed_2i
#define MODEL_ZED_2I     1

static size_t round_up(size_t n, size_t to) { return (n + to - 1) / to * to; }

static size_t slot_stride(int w, int h) {
    return round_up((size_t)SLOT_HEADER + (size_t)w * h * 3, 4096);
}

static size_t total_bytes(int w, int h, uint32_t slots) {
    return HEADER_BYTES + SENSORS_REGION + slots * slot_stride(w, h);
}

// ---------------------------------------------------------------------------- the producer

@interface ZedProducer : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic) uint8_t *region;
@property (nonatomic) size_t regionBytes;
@property (nonatomic) int fd;
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) uint32_t slots;
@property (nonatomic) uint64_t seq;
@property (nonatomic) uint64_t reported;
@property (nonatomic) uint64_t lastReportUs;
@property (nonatomic) uint64_t lastFrameUs;
@property (nonatomic) uint64_t gapMinUs;
@property (nonatomic) uint64_t gapMaxUs;
@property (nonatomic, copy) NSString *path;
@end

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)(ts.tv_nsec / 1000);
}

@implementation ZedProducer

- (BOOL)createRegion:(NSString *)path width:(int)w height:(int)h fps:(int)fps {
    self.width = w;
    self.height = h;
    self.slots = 4;
    self.path = path;
    self.regionBytes = total_bytes(w, h, self.slots);

    int fd = open(path.UTF8String, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { perror("open"); return NO; }
    if (ftruncate(fd, (off_t)self.regionBytes) != 0) { perror("ftruncate"); close(fd); return NO; }

    void *p = mmap(NULL, self.regionBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); close(fd); return NO; }

    self.fd = fd;
    self.region = (uint8_t *)p;

    uint8_t *r = self.region;
    memset(r, 0, HEADER_BYTES);
    *(uint32_t *)(r + OFF_VERSION) = kVersion;
    *(uint32_t *)(r + OFF_SLOTS) = self.slots;
    *(uint16_t *)(r + OFF_WIDTH) = (uint16_t)w;
    *(uint16_t *)(r + OFF_HEIGHT) = (uint16_t)h;
    *(uint16_t *)(r + OFF_FPS) = (uint16_t)fps;
    r[OFF_MODEL] = MODEL_ZED_2I;
    // No IMU through UVC either: the sensors come from the SDK, like depth.
    r[OFF_HAS_SENSORS] = 0;
    *(uint32_t *)(r + OFF_PAYLOAD_LEN) = (uint32_t)((size_t)w * h * 3);
    *(uint32_t *)(r + OFF_SLOT_STRIDE) = (uint32_t)slot_stride(w, h);

    // Magic last, with a release fence, so a driver that opens the file mid-creation sees
    // either no magic or a fully stamped header -- never a half-written geometry it would
    // size its buffers from.
    atomic_thread_fence(memory_order_release);
    memcpy(r + OFF_MAGIC, kMagic, sizeof kMagic);
    return YES;
}

- (void)removeRegion {
    if (self.region) munmap(self.region, self.regionBytes);
    if (self.fd > 0) close(self.fd);
    if (self.path) unlink(self.path.UTF8String);
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sample
       fromConnection:(AVCaptureConnection *)connection {
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (!image) return;

    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    const uint8_t *src = CVPixelBufferGetBaseAddress(image);
    const size_t srcStride = CVPixelBufferGetBytesPerRow(image);
    const size_t srcW = CVPixelBufferGetWidth(image);
    const size_t srcH = CVPixelBufferGetHeight(image);

    if (src && srcW >= (size_t)self.width * 2 && srcH >= (size_t)self.height) {
        const uint64_t t = now_us();
        const uint64_t seq = self.seq + 1;

        uint8_t *r = self.region;
        const size_t stride = *(uint32_t *)(r + OFF_SLOT_STRIDE);
        uint8_t *slot = r + HEADER_BYTES + SENSORS_REGION + (seq % self.slots) * stride;
        *(uint64_t *)(slot + 0) = seq;
        *(uint64_t *)(slot + 8) = t;

        uint8_t *payload = slot + SLOT_HEADER;
        const size_t n = (size_t)self.width * self.height;
        // Depth first in the layout, and it stays zero: there is no depth without the SDK.
        memset(payload, 0, n * 2);
        uint8_t *mono = payload + n * 2;

        // YUY2 is Y0 Cb Y1 Cr per two pixels, so luminance is every other byte. The LEFT
        // eye is the first half of each row -- the pair arrives side by side, and depth on a
        // real ZED is registered to the left image, so that is the one to keep.
        for (int y = 0; y < self.height; ++y) {
            const uint8_t *row = src + (size_t)y * srcStride;
            uint8_t *out = mono + (size_t)y * self.width;
            for (int x = 0; x < self.width; ++x) out[x] = row[(size_t)x * 2];
        }

        // Release after the payload, so a driver that sees this sequence number is
        // guaranteed to see the bytes that go with it.
        atomic_thread_fence(memory_order_release);
        *(volatile uint64_t *)(r + OFF_PUBLISHED) = seq;
        self.seq = seq;

        // Real inter-frame gaps, which is one of the things only real hardware can tell us.
        if (self.lastFrameUs != 0) {
            const uint64_t gap = t - self.lastFrameUs;
            if (self.gapMinUs == 0 || gap < self.gapMinUs) self.gapMinUs = gap;
            if (gap > self.gapMaxUs) self.gapMaxUs = gap;
        }
        self.lastFrameUs = t;

        if (t - self.lastReportUs >= 1000000ull) {
            printf("zed-uvc: %llu frames/s, gap %.1f-%.1f ms, %dx%d left eye, depth absent\n",
                   seq - self.reported,
                   self.gapMinUs / 1000.0, self.gapMaxUs / 1000.0,
                   self.width, self.height);
            fflush(stdout);
            self.reported = seq;
            self.lastReportUs = t;
            self.gapMinUs = 0;
            self.gapMaxUs = 0;
        }
    }

    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
}
@end

static ZedProducer *g_producer = nil;

static void on_signal(int sig) {
    (void)sig;
    [g_producer removeRegion];
    _exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *path = @"/tmp/qnnt-zed2i.shm";
        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--shm") == 0 && i + 1 < argc) path = @(argv[++i]);
        }

        AVCaptureDeviceDiscoverySession *session =
            [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
                                                                  mediaType:AVMediaTypeVideo
                                                                   position:AVCaptureDevicePositionUnspecified];
        AVCaptureDevice *zed = nil;
        for (AVCaptureDevice *d in session.devices) {
            if ([d.localizedName rangeOfString:@"ZED"].location != NSNotFound) { zed = d; break; }
        }
        if (!zed) {
            printf("zed-uvc: no ZED found on USB. Connected? Another process holding it?\n");
            return 1;
        }

        // Ask the camera what it offers rather than assuming: this is the whole reason the
        // spec table's 1080p30 turned out to be unreachable here.
        AVCaptureDeviceFormat *best = nil;
        int bestW = 0;
        for (AVCaptureDeviceFormat *f in zed.formats) {
            CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
            if (dim.width > bestW) { bestW = dim.width; best = f; }
        }
        if (!best) { printf("zed-uvc: the camera offers no usable format\n"); return 1; }

        CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(best.formatDescription);
        double fps = 15.0;
        for (AVFrameRateRange *r in best.videoSupportedFrameRateRanges) fps = r.maxFrameRate;

        // Side by side, so one eye is half the width.
        const int eyeW = dim.width / 2;
        const int eyeH = dim.height;

        printf("zed-uvc: %s\n", zed.localizedName.UTF8String);
        printf("  the camera offers %dx%d at %.0f fps -- one eye is %dx%d\n",
               dim.width, dim.height, fps, eyeW, eyeH);
        printf("  NOT the 1920x1080 at 30 the spec table headlines: that mode needs the ZED\n"
               "  SDK, which does not exist for macOS. Over UVC this is what there is.\n");
        printf("  depth is ABSENT -- it is the SDK's stereo matcher, not the camera's output.\n"
               "  The mono plane is the real left image; the depth plane is zero throughout.\n");

        g_producer = [ZedProducer new];
        if (![g_producer createRegion:path width:eyeW height:eyeH fps:(int)fps]) return 1;
        printf("  -> %s (%.1f MB mapped)\n", path.UTF8String,
               g_producer.regionBytes / 1.0e6);

        signal(SIGINT, on_signal);
        signal(SIGTERM, on_signal);

        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:zed error:&err];
        if (!input) {
            printf("zed-uvc: cannot open the camera: %s\n", err.localizedDescription.UTF8String);
            [g_producer removeRegion];
            return 1;
        }

        AVCaptureSession *capture = [AVCaptureSession new];
        [capture beginConfiguration];
        if ([capture canAddInput:input]) [capture addInput:input];

        AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
        out.alwaysDiscardsLateVideoFrames = YES;
        // 422YpCbCr8 is the yuvs the camera offers; asking for it avoids a conversion that
        // would cost more than the copy this program does.
        out.videoSettings = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_422YpCbCr8_yuvs)
        };
        [out setSampleBufferDelegate:g_producer
                              queue:dispatch_queue_create("zed.capture", DISPATCH_QUEUE_SERIAL)];
        if ([capture canAddOutput:out]) [capture addOutput:out];
        [capture commitConfiguration];

        if ([zed lockForConfiguration:&err]) {
            zed.activeFormat = best;
            [zed unlockForConfiguration];
        }

        [capture startRunning];
        if (!capture.isRunning) {
            printf("zed-uvc: the capture session would not start. Camera permission?\n");
            [g_producer removeRegion];
            return 1;
        }

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
