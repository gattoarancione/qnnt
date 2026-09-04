// A REAL ZED on Linux, reading into the shared region the driver reads from.
//
//   zig build zed -Dcamera -Doptimize=ReleaseFast
//   ./zig-out/bin/zed-v4l2                    # then camera-sensor --model zed2i as usual
//
// The Linux twin of zed_uvc.m: same shared region, same layout, same driver on the other
// side, different capture API. Between them the handoff is now implemented three times in
// three languages -- Zig, Objective-C and C -- which is what makes it a contract rather
// than an arrangement one program has with itself.
//
// WHAT IT CANNOT DO, and it is the same caveat as on macOS: it does not produce depth.
//
// A ZED's depth is the ZED SDK's stereo matcher, which runs on an NVIDIA GPU. Over V4L2 the
// camera hands over the raw side-by-side stereo pair and nothing else, so the mono plane
// here is genuinely the camera's left image at its real rate and real jitter, and the depth
// plane is ZERO throughout -- which the chain already treats as "no depth here", the normal
// condition for a stereo camera over much of any frame.
//
// It writes no calibration block either: the factory intrinsics live in a per-serial file
// the SDK fetches, so the driver's own nominal values are the honest fallback and its "no
// calibration within the wait" notice is the correct outcome.
//
// The camera offers exactly one V4L2 mode here -- 1344x376 YUYV at 15 fps, which is
// 2x672x376 side by side. Not the 1920x1080 at 30 the spec table headlines: that mode goes
// through the SDK's own access path, not through V4L2. This asks the device rather than
// believing the table, which is the habit that caught the fallback-intrinsics bug.

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// ---------------------------------------------------------------- the shared region layout
//
// Mirrored from examples/zed/shm.zig, as zed_uvc.m mirrors it. The duplication is the
// point: three implementations of one layout is what proves the layout is specified. Any
// change to the offsets there has to be made in all three, and the magic and version are
// what stop a mismatch from being read as data.

static const char kMagic[8] = { 'Z', 'E', 'D', 'S', 'H', 'M', '1', 0 };
static const uint32_t kVersion = 1;

#define HEADER_BYTES     4096
#define SENSORS_SLOTS    512
#define SENSORS_BYTES    64
#define SENSORS_REGION   (SENSORS_SLOTS * SENSORS_BYTES)
#define SLOT_HEADER      16
#define SLOTS            4

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

#define BUFFER_COUNT     4

static size_t round_up(size_t n, size_t to) { return (n + to - 1) / to * to; }
static size_t slot_stride(int w, int h) {
    return round_up((size_t)SLOT_HEADER + (size_t)w * h * 3, 4096);
}
static size_t total_bytes(int w, int h) {
    return HEADER_BYTES + SENSORS_REGION + (size_t)SLOTS * slot_stride(w, h);
}

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

// ---------------------------------------------------------------------------------- state

static uint8_t *g_region = NULL;
static size_t g_region_bytes = 0;
static const char *g_region_path = NULL;

static void cleanup(void) {
    if (g_region) munmap(g_region, g_region_bytes);
    if (g_region_path) unlink(g_region_path);
}

static void on_signal(int sig) {
    (void)sig;
    cleanup();
    _exit(0);
}

/// ioctl, retried through EINTR. A signal arriving during a dequeue is ordinary in a program
/// that shuts down on Ctrl-C, and treating it as a failure would make a clean stop look like
/// a device error.
static int xioctl(int fd, unsigned long req, void *arg) {
    int r;
    do {
        r = ioctl(fd, req, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

// ------------------------------------------------------------------------- finding the ZED

/// Find the ZED's capture node by asking the kernel for device names, rather than assuming
/// /dev/video2. The number depends on what else is plugged in -- on the machine this was
/// written against, video0 and video1 are a built-in webcam and the ZED is video2 and
/// video3, of which only one accepts the format.
static int open_zed(char *path_out, size_t path_len, struct v4l2_format *fmt_out) {
    for (int i = 0; i < 64; ++i) {
        char name_path[128];
        snprintf(name_path, sizeof name_path, "/sys/class/video4linux/video%d/name", i);

        FILE *f = fopen(name_path, "r");
        if (!f) continue;
        char name[128] = { 0 };
        if (!fgets(name, sizeof name, f)) { fclose(f); continue; }
        fclose(f);
        // /sys names come with a trailing newline, which lands in the middle of the banner.
        name[strcspn(name, "\n")] = 0;
        if (!strstr(name, "ZED")) continue;

        char dev[64];
        snprintf(dev, sizeof dev, "/dev/video%d", i);
        int fd = open(dev, O_RDWR | O_NONBLOCK);
        if (fd < 0) {
            printf("  %s: %s (%s)\n", dev, strerror(errno),
                   errno == EACCES ? "add your user to the 'video' group" : "in use?");
            continue;
        }

        struct v4l2_capability cap;
        memset(&cap, 0, sizeof cap);
        if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0 ||
            !(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE) ||
            !(cap.capabilities & V4L2_CAP_STREAMING)) {
            close(fd);
            continue;
        }

        // Ask what it offers rather than asserting a size. The ZED exposes two nodes and
        // only one of them takes this format.
        struct v4l2_fmtdesc desc;
        memset(&desc, 0, sizeof desc);
        desc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        int best_w = 0, best_h = 0;
        for (desc.index = 0; xioctl(fd, VIDIOC_ENUM_FMT, &desc) == 0; ++desc.index) {
            if (desc.pixelformat != V4L2_PIX_FMT_YUYV) continue;
            struct v4l2_frmsizeenum sz;
            memset(&sz, 0, sizeof sz);
            sz.pixel_format = desc.pixelformat;
            for (sz.index = 0; xioctl(fd, VIDIOC_ENUM_FRAMESIZES, &sz) == 0; ++sz.index) {
                if (sz.type != V4L2_FRMSIZE_TYPE_DISCRETE) continue;
                if ((int)sz.discrete.width > best_w) {
                    best_w = (int)sz.discrete.width;
                    best_h = (int)sz.discrete.height;
                }
            }
        }
        if (best_w == 0) { close(fd); continue; }

        struct v4l2_format fmt;
        memset(&fmt, 0, sizeof fmt);
        fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        fmt.fmt.pix.width = (unsigned)best_w;
        fmt.fmt.pix.height = (unsigned)best_h;
        fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
        fmt.fmt.pix.field = V4L2_FIELD_NONE;
        if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) { close(fd); continue; }

        // The driver may hand back something other than what was asked for, and using the
        // request instead of the reply is how a stride ends up wrong.
        if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) { close(fd); continue; }

        snprintf(path_out, path_len, "%s", dev);
        *fmt_out = fmt;
        printf("zed-v4l2: %s on %s\n", name, dev);
        return fd;
    }
    return -1;
}

int main(int argc, char **argv) {
    const char *shm_path = "/tmp/qnnt-zed2i.shm";
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--shm") == 0 && i + 1 < argc) shm_path = argv[++i];
    }

    char dev[64];
    struct v4l2_format fmt;
    int fd = open_zed(dev, sizeof dev, &fmt);
    if (fd < 0) {
        printf("zed-v4l2: no ZED capture node found.\n"
               "  Connected? `lsusb | grep 2b03` should show it.\n"
               "  Permission? /dev/video* usually needs the 'video' group.\n");
        return 1;
    }

    const int srcW = (int)fmt.fmt.pix.width;
    const int srcH = (int)fmt.fmt.pix.height;
    const size_t srcStride = fmt.fmt.pix.bytesperline;

    // Side by side, so one eye is half the width.
    const int eyeW = srcW / 2;
    const int eyeH = srcH;

    struct v4l2_streamparm parm;
    memset(&parm, 0, sizeof parm);
    parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    int fps = 15;
    if (xioctl(fd, VIDIOC_G_PARM, &parm) == 0 && parm.parm.capture.timeperframe.numerator) {
        fps = (int)(parm.parm.capture.timeperframe.denominator /
                    parm.parm.capture.timeperframe.numerator);
    }

    printf("  the camera offers %dx%d YUYV at %d fps -- one eye is %dx%d\n",
           srcW, srcH, fps, eyeW, eyeH);
    printf("  NOT the 1920x1080 at 30 the spec table headlines: that mode goes through the\n"
           "  ZED SDK, which needs an NVIDIA GPU. Over V4L2 this is what there is.\n");
    printf("  depth is ABSENT -- it is the SDK's stereo matcher, not the camera's output.\n"
           "  The mono plane is the real left image; the depth plane is zero throughout.\n");

    // ---- the shared region -------------------------------------------------------------

    g_region_bytes = total_bytes(eyeW, eyeH);
    int rfd = open(shm_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (rfd < 0) { perror("open(shm)"); return 1; }
    if (ftruncate(rfd, (off_t)g_region_bytes) != 0) { perror("ftruncate"); return 1; }

    void *p = mmap(NULL, g_region_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, rfd, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    close(rfd); // the mapping keeps the file alive
    g_region = (uint8_t *)p;
    g_region_path = shm_path;

    memset(g_region, 0, HEADER_BYTES);
    *(uint32_t *)(g_region + OFF_VERSION) = kVersion;
    *(uint32_t *)(g_region + OFF_SLOTS) = SLOTS;
    *(uint16_t *)(g_region + OFF_WIDTH) = (uint16_t)eyeW;
    *(uint16_t *)(g_region + OFF_HEIGHT) = (uint16_t)eyeH;
    *(uint16_t *)(g_region + OFF_FPS) = (uint16_t)fps;
    g_region[OFF_MODEL] = MODEL_ZED_2I;
    // The IMU is on the ZED's HID interface and read by the SDK, not by V4L2. Declaring it
    // absent is what keeps the sensors topic honestly silent rather than empty-but-claimed.
    g_region[OFF_HAS_SENSORS] = 0;
    *(uint32_t *)(g_region + OFF_PAYLOAD_LEN) = (uint32_t)((size_t)eyeW * eyeH * 3);
    *(uint32_t *)(g_region + OFF_SLOT_STRIDE) = (uint32_t)slot_stride(eyeW, eyeH);

    // Magic last, with a release fence, so a driver that opens the file mid-creation sees
    // either no magic or a fully stamped header -- never a half-written geometry it would
    // size its buffers from.
    atomic_thread_fence(memory_order_release);
    memcpy(g_region + OFF_MAGIC, kMagic, sizeof kMagic);

    printf("  -> %s (%.1f MB mapped)\n", shm_path, g_region_bytes / 1.0e6);

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    // ---- capture buffers ----------------------------------------------------------------

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof req);
    req.count = BUFFER_COUNT;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) { perror("VIDIOC_REQBUFS"); cleanup(); return 1; }

    void *bufs[BUFFER_COUNT] = { 0 };
    size_t buf_len[BUFFER_COUNT] = { 0 };
    for (unsigned i = 0; i < req.count; ++i) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) { perror("VIDIOC_QUERYBUF"); cleanup(); return 1; }
        bufs[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
        if (bufs[i] == MAP_FAILED) { perror("mmap(buffer)"); cleanup(); return 1; }
        buf_len[i] = b.length;
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) { perror("VIDIOC_QBUF"); cleanup(); return 1; }
    }

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) { perror("VIDIOC_STREAMON"); cleanup(); return 1; }

    // ---- the loop ------------------------------------------------------------------------

    uint64_t seq = 0, reported = 0, last_report = now_us();
    uint64_t kernel_prev = 0, gap_min = 0, gap_max = 0;
    uint64_t dropped = 0;
    const size_t stride = slot_stride(eyeW, eyeH);
    const size_t n = (size_t)eyeW * eyeH;

    for (;;) {
        // Opened non-blocking, so wait here rather than spinning on EAGAIN.
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        int r = select(fd + 1, &fds, NULL, NULL, &tv);
        if (r < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }
        if (r == 0) {
            printf("zed-v4l2: no frame for 2s -- camera unplugged?\n");
            fflush(stdout);
            continue;
        }

        struct v4l2_buffer b;
        memset(&b, 0, sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        if (xioctl(fd, VIDIOC_DQBUF, &b) < 0) {
            if (errno == EAGAIN) continue;
            perror("VIDIOC_DQBUF");
            break;
        }

        if (b.index < BUFFER_COUNT && bufs[b.index] &&
            buf_len[b.index] >= srcStride * (size_t)srcH) {
            const uint8_t *src = (const uint8_t *)bufs[b.index];
            const uint64_t t = now_us();
            seq += 1;

            uint8_t *slot = g_region + HEADER_BYTES + SENSORS_REGION + (seq % SLOTS) * stride;
            *(uint64_t *)(slot + 0) = seq;
            *(uint64_t *)(slot + 8) = t;

            uint8_t *payload = slot + SLOT_HEADER;
            // Depth first in the layout, and it stays zero: there is no depth without the
            // SDK. Written every frame rather than once, because the slot is reused and last
            // time round it held a different frame's zeros -- cheap, and it keeps the
            // invariant local to the write instead of to the region's history.
            memset(payload, 0, n * 2);
            uint8_t *mono = payload + n * 2;

            // YUYV is Y0 Cb Y1 Cr per two pixels, so luminance is every other byte. The
            // LEFT eye is the first half of each row -- the pair arrives side by side, and a
            // real ZED registers depth to the left image, so that is the one to keep.
            for (int y = 0; y < eyeH; ++y) {
                const uint8_t *row = src + (size_t)y * srcStride;
                uint8_t *out = mono + (size_t)y * eyeW;
                for (int x = 0; x < eyeW; ++x) out[x] = row[(size_t)x * 2];
            }

            // Release after the payload, so a driver that sees this sequence number is
            // guaranteed to see the bytes that go with it.
            atomic_thread_fence(memory_order_release);
            *(volatile uint64_t *)(g_region + OFF_PUBLISHED) = seq;

            // Jitter measured from the KERNEL's capture timestamp rather than from this
            // dequeue: the kernel stamps when the frame arrived, and the difference between
            // the two is exactly the scheduling delay that would otherwise be attributed to
            // the camera. Its epoch is monotonic and not comparable with t above, which is
            // fine -- only the deltas are used.
            const uint64_t kt = (uint64_t)b.timestamp.tv_sec * 1000000ull +
                                (uint64_t)b.timestamp.tv_usec;
            if (kernel_prev != 0 && kt > kernel_prev) {
                const uint64_t gap = kt - kernel_prev;
                if (gap_min == 0 || gap < gap_min) gap_min = gap;
                if (gap > gap_max) gap_max = gap;
            }
            kernel_prev = kt;

            if (b.sequence > seq + dropped) dropped = b.sequence - seq;

            if (t - last_report >= 1000000ull) {
                printf("zed-v4l2: %llu frames/s, kernel gap %.1f-%.1f ms, %dx%d left eye, "
                       "depth absent%s\n",
                       (unsigned long long)(seq - reported),
                       gap_min / 1000.0, gap_max / 1000.0, eyeW, eyeH,
                       dropped ? " (kernel dropped frames)" : "");
                fflush(stdout);
                reported = seq;
                last_report = t;
                gap_min = 0;
                gap_max = 0;
            }
        }

        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) { perror("VIDIOC_QBUF"); break; }
    }

    xioctl(fd, VIDIOC_STREAMOFF, &type);
    for (unsigned i = 0; i < req.count; ++i) {
        if (bufs[i] && bufs[i] != MAP_FAILED) munmap(bufs[i], buf_len[i]);
    }
    close(fd);
    cleanup();
    return 0;
}
