// shmbench -- delivering messages to local subscribers: Unix sockets vs shared memory.
//
// Lossless modes, the guarantee qnnt gives today:
//
//   unix      the publisher writes every message down every subscriber's Unix stream socket, one
//             write per subscriber, and subscribers read through a 64 KiB buffer -- qnnt on one
//             host today. The slowest subscriber throttles the publisher.
//   tcp       the same as unix, over loopback TCP, set up as qnnt sets up TCP: default buffers and
//             Nagle left on. The baseline remote subscribers and older nodes use. SHMB_NODELAY=1
//             turns Nagle off, to see how much of TCP's small-message figure is coalescing.
//
//   SHMB_BATCH=N  (unix and tcp) packs up to N messages, or 64 KiB, into one write, and always
//             flushes before a paced publisher sleeps -- coalescing done by the publisher itself,
//             which a Unix socket never does on its own. Nothing waits longer than one tick.
//   ringcopy  one ring of variable-length records in shared memory. The publisher writes each
//             message once, straight into the ring. A subscriber copies a record out, releases it
//             by advancing its read position, then processes the copy.
//   ringzero  the same ring, processed in place and released afterwards -- safe zero-copy: the
//             publisher cannot reuse a record until every subscriber has moved past it, so there
//             is nothing to reference-count and no allocator to fragment.
//   auto      starts every subscriber on its socket and hands over to a ring the first time a
//             message reaches the threshold: the publisher creates a segment, sends each
//             subscriber a marker carrying its file descriptor, and only then publishes that
//             message -- into the ring. A message too big for the ring hands back to the socket
//             and straight on to a bigger ring. After a quiet window with nothing large, a
//             "back to the socket" record hands back for good and the segment is released.
//             Order holds across every switch because each marker sits in the stream between
//             the last message of one path and the first of the other.
//
//   Wakeups are an eventcount: a subscriber announces it is about to sleep, re-checks, and only
//   then blocks; the publisher wakes only those that announced. A busy stream makes no system
//   calls. A publisher facing a full ring sleeps the same way until a subscriber frees space.
//
// Latest-wins modes, for a sensor topic (fixed-size frames, 4 slots, the publisher never blocks):
//
//   copy      the subscriber copies the newest frame out and checks it was not overwritten
//   inplace   the subscriber reads it in place and validates after; a frame overwritten while it
//             was being read is discarded. NOT safe behind a callback, which is why ringzero exists.
//
// Every mode does the same work per message: the publisher fills it, each subscriber sums every
// byte of it. Nothing spins; every wait blocks in the kernel, so CPU time compares fairly.
//
// usage: shmbench <unix|tcp|ringcopy|ringzero|auto|copy|inplace> <subscribers> [hz, 0 = flat out] [seconds] [bytes]
//        shmbench sweep [seconds per run]
//        shmbench handover [seconds per run] [threshold bytes] [quiet seconds]
//        a single run also takes [workload: fixed|step|mixed|grow] [quiet seconds] after [bytes]
#define _GNU_SOURCE
#include <errno.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAXS 8
#define SLOTS 4
#define END UINT64_MAX
#define RHDR 24 /* ring record: u32 length | u32 flags | u64 seq | u64 time ready */
#define F_END 1u
#define F_TO_SOCKET 2u
#define PAD 0xFFFFFFFFu
#define IHDR 24 /* stream item: u32 length | u32 kind | u64 seq | u64 time ready */
enum { K_DATA = 1, K_BELL, K_TO_RING, K_END };

enum { M_UNIX, M_TCP, M_RCOPY, M_RZERO, M_AUTO, M_COPY, M_INPLACE, M_COUNT };
static const char *names[M_COUNT] = {"unix", "tcp", "ringcopy", "ringzero", "auto", "copy", "inplace"};

enum { W_FIXED, W_STEP, W_MIXED, W_GROW, W_COUNT };
static const char *wnames[W_COUNT] = {"fixed", "step", "mixed", "grow"};

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static void sleep_until(uint64_t t) {
    uint64_t n = now_ns();
    if (t <= n) return;
    struct timespec d = {.tv_sec = (time_t)((t - n) / 1000000000ull), .tv_nsec = (long)((t - n) % 1000000000ull)};
    while (nanosleep(&d, &d) && errno == EINTR) {}
}

static size_t align8(size_t n) { return (n + 7) & ~(size_t)7; }

static size_t pow2_at_least(size_t n) {
    size_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

/* ---- shared state ----------------------------------------------------------------------- */

typedef struct {
    uint64_t produced, t_start, t_stop;
    uint64_t ups, downs, grows, pause_max, pause_total; /* auto: handovers and what they cost */
    uint64_t delivered[MAXS], missed[MAXS], torn[MAXS], errors[MAXS];
    uint64_t lat[MAXS][64]; /* log2 of nanoseconds */
} stats_t;

typedef struct { _Atomic uint64_t seq; uint64_t t_ready; char pad[48]; } slot_hdr;
typedef struct { _Atomic uint64_t published; char pad[56]; slot_hdr slot[SLOTS]; } slots_t;

typedef struct { _Atomic uint64_t pos; _Atomic uint32_t sleeping; char pad[52]; } sub_ctl;
typedef struct {
    _Atomic uint64_t head; /* bytes written and published */
    char p0[56];
    _Atomic uint32_t pub_sleeping;
    char p1[60];
    sub_ctl sub[MAXS];
} rring_t;
#define CTL_BYTES 4096 /* the ring's control block, ahead of its data in one segment */

typedef struct { int mode, subs, workload; double hz, seconds, quiet; size_t size, threshold; } cfg_t;
typedef struct {
    double per_sub, gbps, cpu, p50_us, p99_us, pause_max_us;
    uint64_t missed, torn, errors, ups, downs, grows;
} result_t;

static cfg_t cfg;
static stats_t *st;
static slots_t *slots;
static rring_t *rr;   /* the ring in use: inherited for ringcopy/ringzero, swapped by auto */
static uint8_t *data; /* slot frames, or the ring's data */
static size_t rcap;
static int fds[MAXS][2]; /* [0] publisher end, [1] subscriber end */
static volatile uint64_t sink;

static uint64_t checksum(const uint8_t *p, size_t n) {
    uint64_t s = 0, w;
    for (size_t i = 0; i + 8 <= n; i += 8) { memcpy(&w, p + i, 8); s += w; }
    return s;
}

static void record(int s, uint64_t t_ready) {
    uint64_t ns = now_ns() - t_ready;
    st->lat[s][ns ? 63 - __builtin_clzll(ns) : 0]++;
    st->delivered[s]++;
}

/* Every sequence exactly once and in order, and the payload the one written for it. */
static void check(int s, uint64_t seq, uint64_t *want, const uint8_t *payload, size_t len) {
    if (seq != *want || (len && payload[0] != (uint8_t)(seq & 0xff))) st->errors[s]++;
    *want = seq + 1;
}

static int full(int fd, const void *b, size_t n, int rd) {
    uint8_t *p = (uint8_t *)b;
    while (n) {
        ssize_t k = rd ? read(fd, p, n) : write(fd, p, n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return -1;
        p += k;
        n -= (size_t)k;
    }
    return 0;
}

static void drain(int fd) {
    uint8_t b[64];
    while (recv(fd, b, sizeof b, MSG_DONTWAIT) > 0) {}
}

/* ---- workloads -------------------------------------------------------------------------- */

static size_t max_size(void) {
    switch (cfg.workload) {
    case W_STEP: return 1 << 20;
    case W_MIXED: return 4 << 20;
    case W_GROW: return 8 << 20;
    default: return cfg.size;
    }
}

/* `frac` is how far through the run the publisher is, 0..1. */
static size_t size_for(uint64_t seq, double frac) {
    switch (cfg.workload) {
    case W_STEP: return frac < 1.0 / 3 || frac >= 2.0 / 3 ? 256 : 1 << 20; /* small, large, small */
    case W_MIXED: return seq % 100 == 0 ? 4 << 20 : 256; /* telemetry with an occasional snapshot */
    case W_GROW: { /* 1 KiB doubling to 8 MiB over the run */
        int step = (int)(frac * 14);
        return (size_t)1024 << (step > 13 ? 13 : step);
    }
    default: return cfg.size;
    }
}

/* ---- the stream: items with a kind and a length, and file descriptors riding along ------- */

static void item_header(uint8_t *h, uint32_t kind, uint64_t seq, size_t len) {
    uint32_t l = (uint32_t)len;
    uint64_t t = now_ns();
    memcpy(h, &l, 4);
    memcpy(h + 4, &kind, 4);
    memcpy(h + 8, &seq, 8);
    memcpy(h + 16, &t, 8);
}

/* Send an item with a file descriptor attached to its first byte. */
static int send_with_fd(int sock, const uint8_t *buf, size_t len, int fd) {
    struct iovec iov = {.iov_base = (void *)buf, .iov_len = len};
    union { char buf[CMSG_SPACE(sizeof(int))]; struct cmsghdr align; } ctl;
    memset(&ctl, 0, sizeof ctl);
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl.buf, .msg_controllen = sizeof ctl.buf};
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &fd, sizeof(int));
    ssize_t k;
    while ((k = sendmsg(sock, &msg, 0)) < 0 && errno == EINTR) {}
    if (k <= 0) return -1;
    return (size_t)k < len ? full(sock, buf + k, len - (size_t)k, 0) : 0;
}

typedef struct {
    int fd;
    uint8_t *buf;
    size_t cap, have, at;
    int fdq[8], nfd;
} reader_t;

/* One more read into the buffer, collecting any descriptors that arrived with it. */
static int reader_fill(reader_t *r) {
    if (r->at && r->cap - r->have < 64 * 1024) {
        memmove(r->buf, r->buf + r->at, r->have - r->at);
        r->have -= r->at;
        r->at = 0;
    }
    struct iovec iov = {.iov_base = r->buf + r->have, .iov_len = r->cap - r->have};
    union { char buf[CMSG_SPACE(4 * sizeof(int))]; struct cmsghdr align; } ctl;
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl.buf, .msg_controllen = sizeof ctl.buf};
    ssize_t k;
    while ((k = recvmsg(r->fd, &msg, 0)) < 0 && errno == EINTR) {}
    if (k <= 0) return -1;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
        size_t n = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        for (size_t i = 0; i < n && r->nfd < 8; i++) memcpy(&r->fdq[r->nfd++], CMSG_DATA(c) + i * sizeof(int), sizeof(int));
    }
    r->have += (size_t)k;
    return 0;
}

/* The next whole item, or NULL when the stream ends. Valid until the next call. */
static const uint8_t *reader_next(reader_t *r) {
    for (;;) {
        if (r->have - r->at >= IHDR) {
            uint32_t len;
            memcpy(&len, r->buf + r->at, 4);
            if (r->have - r->at >= IHDR + (size_t)len) {
                const uint8_t *item = r->buf + r->at;
                r->at += IHDR + len;
                return item;
            }
        }
        if (reader_fill(r)) return NULL;
    }
}

/* While on the ring, the socket only carries bells -- and, after a hand-back, the items that
 * follow it. Wait for anything to arrive; consume a bell, leave everything else for later. */
static void reader_wait_bell(reader_t *r) {
    while (r->have - r->at < IHDR)
        if (reader_fill(r)) return;
    uint32_t kind;
    memcpy(&kind, r->buf + r->at + 4, 4);
    if (kind == K_BELL) r->at += IHDR;
}

static int reader_take_fd(reader_t *r) {
    if (!r->nfd) return -1;
    int fd = r->fdq[0];
    memmove(r->fdq, r->fdq + 1, (size_t)--r->nfd * sizeof(int));
    return fd;
}

/* ---- the ring --------------------------------------------------------------------------- */

static void ring_wake(int s) {
    if (cfg.mode == M_AUTO) { /* the stream is the doorbell: a bell is an item like any other */
        uint8_t h[IHDR];
        item_header(h, K_BELL, 0, 0);
        full(fds[s][0], h, IHDR, 0);
    } else {
        send(fds[s][0], "b", 1, MSG_DONTWAIT);
    }
}

static uint64_t ring_min_pos(void) {
    uint64_t minp = UINT64_MAX;
    for (int s = 0; s < cfg.subs; s++) {
        uint64_t p = atomic_load_explicit(&rr->sub[s].pos, memory_order_acquire);
        if (p < minp) minp = p;
    }
    return minp;
}

/* Sleep until every subscriber leaves at least `room` bytes free past `head`. */
static void ring_wait_room(uint64_t head, size_t room) {
    for (;;) {
        if (head + room - ring_min_pos() <= rcap) return;
        atomic_store(&rr->pub_sleeping, 1);
        atomic_thread_fence(memory_order_seq_cst);
        if (head + room - ring_min_pos() > rcap) {
            struct pollfd pf[MAXS];
            for (int s = 0; s < cfg.subs; s++) pf[s] = (struct pollfd){.fd = fds[s][0], .events = POLLIN};
            poll(pf, (nfds_t)cfg.subs, 10);
            for (int s = 0; s < cfg.subs; s++) if (pf[s].revents & POLLIN) drain(fds[s][0]);
        }
        atomic_store(&rr->pub_sleeping, 0);
    }
}

static void ring_publish(uint64_t seq, size_t len, uint32_t flags) {
    size_t need = align8(RHDR + len);
    uint64_t head = atomic_load_explicit(&rr->head, memory_order_relaxed); /* the only writer */
    size_t off = head & (rcap - 1), contig = rcap - off;
    ring_wait_room(head, need + (contig < need ? contig : 0));
    if (contig < need) { /* no room before the end: mark the gap and start over at 0 */
        uint32_t pad = PAD;
        memcpy(data + off, &pad, 4);
        head += contig;
        off = 0;
    }
    uint8_t *r = data + off;
    uint32_t l = (uint32_t)len;
    if (len) memset(r + RHDR, (int)(seq & 0xff), len);
    uint64_t t = now_ns();
    memcpy(r, &l, 4);
    memcpy(r + 4, &flags, 4);
    memcpy(r + 8, &seq, 8);
    memcpy(r + 16, &t, 8);
    atomic_store_explicit(&rr->head, head + need, memory_order_release);
    atomic_thread_fence(memory_order_seq_cst);
    for (int s = 0; s < cfg.subs; s++)
        if (atomic_load_explicit(&rr->sub[s].sleeping, memory_order_relaxed)) ring_wake(s);
}

/* One record, read in place or copied out, and released. Returns its flags. */
static uint32_t ring_consume(int s, uint64_t *pos, uint64_t *want, uint8_t *copy) {
    size_t off = *pos & (rcap - 1);
    uint32_t len, flags;
    memcpy(&len, data + off, 4);
    if (len == PAD) { *pos += rcap - off; return 0; }
    uint64_t seq, t;
    memcpy(&flags, data + off + 4, 4);
    memcpy(&seq, data + off + 8, 8);
    memcpy(&t, data + off + 16, 8);
    const uint8_t *p = data + off + RHDR;
    uint64_t next = *pos + align8(RHDR + len);
    sub_ctl *me = &rr->sub[s];
    if (flags) { /* END or TO_SOCKET: no payload, just release it */
        atomic_store_explicit(&me->pos, next, memory_order_release);
        *pos = next;
        return flags;
    }
    if (copy) {
        memcpy(copy, p, len);
        atomic_store_explicit(&me->pos, next, memory_order_release); /* released before use */
        check(s, seq, want, copy, len);
        sink += checksum(copy, len);
    } else {
        check(s, seq, want, p, len);
        sink += checksum(p, len);
        atomic_store_explicit(&me->pos, next, memory_order_release); /* released after use */
    }
    record(s, t);
    *pos = next;
    return 0;
}

/* After releasing records: wake a publisher waiting for room. */
static void ring_released(int fd) {
    atomic_thread_fence(memory_order_seq_cst);
    if (atomic_load_explicit(&rr->pub_sleeping, memory_order_relaxed)) {
        if (cfg.mode == M_AUTO) full(fd, "b", 1, 0);
        else send(fd, "b", 1, MSG_DONTWAIT);
    }
}

static void ring_subscriber(int s) {
    int fd = fds[s][1];
    sub_ctl *me = &rr->sub[s];
    uint8_t *copy = cfg.mode == M_RCOPY ? malloc(max_size() ? max_size() : 8) : NULL;
    uint64_t pos = 0, want = 1;
    for (;;) {
        uint64_t head = atomic_load_explicit(&rr->head, memory_order_acquire);
        if (pos == head) { /* announce, re-check, and only then sleep */
            atomic_store(&me->sleeping, 1);
            atomic_thread_fence(memory_order_seq_cst);
            if (atomic_load(&rr->head) == pos) {
                uint8_t b;
                recv(fd, &b, 1, 0);
                drain(fd);
            }
            atomic_store(&me->sleeping, 0);
            continue;
        }
        while (pos < head)
            if (ring_consume(s, &pos, &want, copy) & F_END) { free(copy); return; }
        ring_released(fd);
    }
}

/* ---- auto: socket first, ring once a message is large ------------------------------------ */

/* A segment for one ring: control block, then data. memfd on Linux, which is not bounded by
 * /dev/shm (64 MB in a container); shm_open on macOS, unlinked at once so no name outlives it. */
static int make_segment(size_t bytes) {
    int fd;
#ifdef __linux__
    fd = memfd_create("shmbench-ring", MFD_CLOEXEC);
#else
    static int n;
    char name[32];
    snprintf(name, sizeof name, "/shmb.%d.%d", getpid(), n++);
    fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd >= 0) shm_unlink(name);
#endif
    if (fd < 0 || ftruncate(fd, (off_t)bytes)) { perror("segment"); exit(1); }
    return fd;
}

static void map_ring(int fd, size_t cap) {
    uint8_t *base = mmap(0, CTL_BYTES + cap, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) { perror("mmap"); exit(1); }
    rr = (rring_t *)base;
    data = base + CTL_BYTES;
    rcap = cap;
}

static void unmap_ring(void) {
    munmap(rr, CTL_BYTES + rcap);
    rr = NULL;
}

static int on_ring;
static size_t largest;
static uint64_t last_large;

static void upgrade(size_t len) {
    if (len > largest) largest = len;
    size_t cap = pow2_at_least(8 * align8(RHDR + largest));
    if (cap < (4u << 20)) cap = 4u << 20;
    int fd = make_segment(CTL_BYTES + cap);
    map_ring(fd, cap);
    memset(rr, 0, sizeof *rr);
    uint8_t item[IHDR + 8];
    uint64_t c = cap;
    item_header(item, K_TO_RING, 0, 8);
    memcpy(item + IHDR, &c, 8);
    for (int s = 0; s < cfg.subs; s++)
        if (send_with_fd(fds[s][0], item, sizeof item, fd)) exit(1);
    close(fd); /* the subscribers hold their own copies now */
    on_ring = 1;
    st->ups++;
}

static void downgrade(void) {
    ring_publish(0, 0, F_TO_SOCKET);
    ring_wait_room(atomic_load(&rr->head), rcap); /* everyone has read past the hand-back */
    unmap_ring();
    on_ring = 0;
    st->downs++;
}

static uint8_t *batch_buf;
static size_t batch_used, batch_count, batch_max;

static void batch_flush(void) {
    if (!batch_used) return;
    for (int s = 0; s < cfg.subs; s++)
        if (full(fds[s][0], batch_buf, batch_used, 0)) exit(1);
    batch_used = batch_count = 0;
}

static void socket_publish(uint8_t *m, uint64_t seq, size_t len) {
    memset(m + IHDR, (int)(seq & 0xff), len);
    item_header(m, K_DATA, seq, len);
    if (batch_max > 1 && IHDR + len <= 32 * 1024) { /* small: coalesce */
        if (batch_used + IHDR + len > 64 * 1024) batch_flush();
        memcpy(batch_buf + batch_used, m, IHDR + len);
        batch_used += IHDR + len;
        if (++batch_count >= batch_max) batch_flush();
        return;
    }
    batch_flush(); /* order: anything queued goes first */
    for (int s = 0; s < cfg.subs; s++) /* like publishAll: one write per subscriber */
        if (full(fds[s][0], m, IHDR + len, 0)) exit(1);
}

static void auto_publish(uint8_t *m, uint64_t seq, size_t len) {
    uint64_t now = now_ns();
    if (len > cfg.threshold / 4) last_large = now;
    uint64_t t0 = now;
    int switched = 1;
    if (!on_ring && len >= cfg.threshold) {
        upgrade(len);
    } else if (on_ring && align8(RHDR + len) > rcap / 2) { /* too big for this ring: a bigger one */
        downgrade();
        upgrade(len);
        st->grows++;
    } else if (on_ring && now - last_large > (uint64_t)(cfg.quiet * 1e9)) {
        downgrade(); /* quiet for long enough: give the memory back */
    } else {
        switched = 0;
    }
    if (switched) {
        uint64_t pause = now_ns() - t0;
        st->pause_total += pause;
        if (pause > st->pause_max) st->pause_max = pause;
    }
    if (on_ring) ring_publish(seq, len, 0);
    else socket_publish(m, seq, len);
}

/* A subscriber for unix and auto alike: unix simply never receives a marker. */
static void stream_subscriber(int s) {
    reader_t r = {.fd = fds[s][1], .cap = 64 * 1024 + 2 * (IHDR + max_size())};
    r.buf = malloc(r.cap);
    uint64_t want = 1, pos = 0;
    int ringed = 0;
    for (;;) {
        if (!ringed) {
            const uint8_t *item = reader_next(&r);
            if (!item) break;
            uint32_t len, kind;
            uint64_t seq, t;
            memcpy(&len, item, 4);
            memcpy(&kind, item + 4, 4);
            memcpy(&seq, item + 8, 8);
            memcpy(&t, item + 16, 8);
            if (kind == K_END) break;
            if (kind == K_DATA) {
                check(s, seq, &want, item + IHDR, len);
                sink += checksum(item + IHDR, len);
                record(s, t);
            } else if (kind == K_TO_RING) {
                uint64_t cap;
                memcpy(&cap, item + IHDR, 8);
                int fd = reader_take_fd(&r);
                if (fd < 0) { st->errors[s]++; break; }
                map_ring(fd, cap);
                close(fd);
                pos = 0;
                ringed = 1;
            } /* a bell left over from the ring: nothing to do */
            continue;
        }

        sub_ctl *me = &rr->sub[s];
        uint64_t head = atomic_load_explicit(&rr->head, memory_order_acquire);
        if (pos == head) {
            atomic_store(&me->sleeping, 1);
            atomic_thread_fence(memory_order_seq_cst);
            if (atomic_load(&rr->head) == pos) reader_wait_bell(&r);
            atomic_store(&me->sleeping, 0);
            continue;
        }
        uint32_t flags = 0;
        while (pos < head && !(flags = ring_consume(s, &pos, &want, NULL))) {}
        ring_released(r.fd);
        if (flags & F_END) break;
        if (flags & F_TO_SOCKET) { /* back to the socket, exactly where the publisher went */
            unmap_ring();
            ringed = 0;
        }
    }
    free(r.buf);
}

/* ---- latest-wins slots ------------------------------------------------------------------ */

static void slots_subscriber(int s) {
    int fd = fds[s][1];
    uint8_t *copy = cfg.mode == M_COPY ? malloc(cfg.size) : NULL;
    uint64_t last = 0;
    for (;;) {
        uint64_t bell;
        if (recv(fd, &bell, sizeof bell, 0) != sizeof bell || bell == END) break;
        int stop = 0;
        while (recv(fd, &bell, sizeof bell, MSG_DONTWAIT) == sizeof bell)
            if (bell == END) stop = 1;
        uint64_t seq = atomic_load_explicit(&slots->published, memory_order_acquire);
        if (seq > last) {
            slot_hdr *h = &slots->slot[seq % SLOTS];
            const uint8_t *src = data + (seq % SLOTS) * cfg.size;
            if (atomic_load_explicit(&h->seq, memory_order_acquire) != seq) {
                st->torn[s]++;
            } else {
                uint64_t t_ready = h->t_ready;
                uint64_t sum = cfg.mode == M_COPY ? (memcpy(copy, src, cfg.size), 0) : checksum(src, cfg.size);
                atomic_thread_fence(memory_order_acquire);
                if (atomic_load_explicit(&h->seq, memory_order_relaxed) != seq) {
                    st->torn[s]++;
                } else {
                    sink += cfg.mode == M_COPY ? checksum(copy, cfg.size) : sum;
                    st->missed[s] += seq - last - 1;
                    last = seq;
                    record(s, t_ready);
                }
            }
        }
        if (stop) break;
    }
    free(copy);
}

static void slots_publish(uint64_t seq) {
    slot_hdr *h = &slots->slot[seq % SLOTS];
    atomic_store_explicit(&h->seq, 0, memory_order_release);
    atomic_thread_fence(memory_order_release);
    memset(data + (seq % SLOTS) * cfg.size, (int)(seq & 0xff), cfg.size);
    h->t_ready = now_ns();
    atomic_store_explicit(&h->seq, seq, memory_order_release);
    atomic_store_explicit(&slots->published, seq, memory_order_release);
    for (int s = 0; s < cfg.subs; s++) send(fds[s][0], &seq, sizeof seq, MSG_DONTWAIT);
}

/* ---- one run ---------------------------------------------------------------------------- */

static int is_ring(int mode) { return mode == M_RCOPY || mode == M_RZERO; }
static int is_stream(int mode) { return mode == M_UNIX || mode == M_TCP || mode == M_AUTO; }

/* A connected loopback TCP pair, [0] the publisher's accepted end and [1] the subscriber's. */
static int tcp_pair(int sv[2]) {
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in in = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t sl = sizeof in;
    if (ls < 0 || bind(ls, (struct sockaddr *)&in, sl) || listen(ls, 1) || getsockname(ls, (struct sockaddr *)&in, &sl)) return -1;
    sv[1] = socket(AF_INET, SOCK_STREAM, 0);
    if (sv[1] < 0 || connect(sv[1], (struct sockaddr *)&in, sl)) return -1;
    sv[0] = accept(ls, NULL, NULL);
    close(ls);
    if (sv[0] < 0) return -1;
    if (getenv("SHMB_NODELAY")) {
        int one = 1;
        setsockopt(sv[0], IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        setsockopt(sv[1], IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    }
    return 0;
}

static void publisher(void) {
    uint8_t *m = is_stream(cfg.mode) ? malloc(IHDR + max_size()) : NULL;
    uint64_t period = cfg.hz > 0 ? (uint64_t)(1e9 / cfg.hz) : 0;
    uint64_t start = now_ns(), deadline = start, span = (uint64_t)(cfg.seconds * 1e9), stop = start + span;
    st->t_start = start;
    const char *b = getenv("SHMB_BATCH");
    batch_max = (cfg.mode == M_UNIX || cfg.mode == M_TCP) && b ? strtoull(b, 0, 10) : 0;
    if (batch_max > 1) batch_buf = malloc(64 * 1024);
    uint64_t seq = 0;
    for (uint64_t now = start; now < stop; now = now_ns()) {
        if (period) {
            batch_flush(); /* about to sleep: nothing waits beyond this tick */
            deadline += period;
            sleep_until(deadline);
        }
        seq++;
        size_t len = size_for(seq, (double)(now - start) / (double)span);
        if (cfg.mode == M_UNIX || cfg.mode == M_TCP) socket_publish(m, seq, len);
        else if (cfg.mode == M_AUTO) auto_publish(m, seq, len);
        else if (is_ring(cfg.mode)) ring_publish(seq, len, 0);
        else slots_publish(seq);
    }
    batch_flush();
    st->produced = seq;
    st->t_stop = now_ns();
    if (is_stream(cfg.mode) && !on_ring) {
        item_header(m, K_END, 0, 0);
        for (int s = 0; s < cfg.subs; s++) full(fds[s][0], m, IHDR, 0);
    } else if (is_ring(cfg.mode) || on_ring) {
        ring_publish(0, 0, F_END);
    } else {
        uint64_t end = END;
        for (int s = 0; s < cfg.subs; s++) send(fds[s][0], &end, sizeof end, 0); /* blocking: must arrive */
    }
    free(m);
}

static double cpu_seconds(void) {
    struct rusage ru;
    getrusage(RUSAGE_CHILDREN, &ru);
    return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
}

static result_t run(cfg_t c) {
    cfg = c;
    on_ring = 0;
    largest = 0;
    last_large = 0;
    size_t data_bytes = 0;
    st = mmap(0, sizeof *st, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    memset(st, 0, sizeof *st);
    if (is_ring(cfg.mode)) {
        rcap = pow2_at_least(8 * align8(RHDR + max_size()));
        if (rcap < (4u << 20)) rcap = 4u << 20;
        data_bytes = rcap;
        rr = mmap(0, sizeof *rr, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
        memset(rr, 0, sizeof *rr);
    } else if (!is_stream(cfg.mode)) {
        data_bytes = SLOTS * cfg.size;
        slots = mmap(0, sizeof *slots, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
        memset(slots, 0, sizeof *slots);
    }
    if (data_bytes) data = mmap(0, data_bytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);

    for (int s = 0; s < cfg.subs; s++) {
        if (cfg.mode == M_TCP ? tcp_pair(fds[s]) : socketpair(AF_UNIX, is_stream(cfg.mode) ? SOCK_STREAM : SOCK_DGRAM, 0, fds[s])) { perror("socket pair"); exit(1); }
        if (is_stream(cfg.mode) && cfg.mode != M_TCP) { /* qnnt's Unix socket buffers; TCP keeps its defaults, as in qnnt */
            int sz = 1 << 20;
            for (int e = 0; e < 2; e++) {
                setsockopt(fds[s][e], SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
                setsockopt(fds[s][e], SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
            }
        }
    }

    double cpu0 = cpu_seconds();
    pid_t kids[MAXS + 1];
    for (int s = 0; s < cfg.subs; s++)
        if (!(kids[s] = fork())) {
            for (int o = 0; o < cfg.subs; o++) close(fds[o][0]);
            if (is_stream(cfg.mode)) stream_subscriber(s);
            else if (is_ring(cfg.mode)) ring_subscriber(s);
            else slots_subscriber(s);
            _exit(0);
        }
    if (!(kids[cfg.subs] = fork())) {
        for (int o = 0; o < cfg.subs; o++) close(fds[o][1]);
        publisher();
        _exit(0);
    }
    for (int s = 0; s < cfg.subs; s++) { close(fds[s][0]); close(fds[s][1]); }
    for (int i = 0; i <= cfg.subs; i++) waitpid(kids[i], 0, 0);
    double cpu = cpu_seconds() - cpu0;
    double wall = (st->t_stop - st->t_start) / 1e9;

    result_t r = {0};
    uint64_t delivered = 0, hist[64] = {0}, total = 0;
    for (int s = 0; s < cfg.subs; s++) {
        delivered += st->delivered[s];
        r.missed += st->missed[s];
        r.torn += st->torn[s];
        r.errors += st->errors[s];
        for (int b = 0; b < 64; b++) { hist[b] += st->lat[s][b]; total += st->lat[s][b]; }
    }
    /* A lossless subscriber that saw fewer messages than were sent lost some. */
    if (cfg.mode != M_COPY && cfg.mode != M_INPLACE)
        for (int s = 0; s < cfg.subs; s++) r.errors += st->produced - st->delivered[s];
    uint64_t acc = 0;
    int p50 = -1, p99 = -1;
    for (int b = 0; b < 64; b++) {
        acc += hist[b];
        if (p50 < 0 && acc * 2 >= total) p50 = b;
        if (p99 < 0 && acc * 100 >= total * 99) p99 = b;
    }
    r.per_sub = delivered / (double)cfg.subs / wall;
    r.gbps = cfg.workload == W_FIXED ? delivered * (double)cfg.size / wall / 1e9 : 0;
    r.cpu = cpu / wall * 100;
    r.p50_us = p50 < 0 ? 0 : (double)(2ull << p50) / 1e3; /* bucket upper bounds */
    r.p99_us = p99 < 0 ? 0 : (double)(2ull << p99) / 1e3;
    r.ups = st->ups;
    r.downs = st->downs;
    r.grows = st->grows;
    r.pause_max_us = st->pause_max / 1e3;

    munmap(st, sizeof *st);
    if (data_bytes) munmap(data, data_bytes);
    if (is_ring(cfg.mode)) munmap(rr, sizeof *rr);
    else if (!is_stream(cfg.mode)) munmap(slots, sizeof *slots);
    return r;
}

/* ---- the sweeps ------------------------------------------------------------------------- */

static void human(char *out, size_t n) {
    if (n >= 1 << 20) sprintf(out, "%zuM", n >> 20);
    else if (n >= 1 << 10) sprintf(out, "%zuK", n >> 10);
    else sprintf(out, "%zu", n);
}

static void sweep(double seconds) {
    static const size_t sizes[] = {64, 256, 1024, 4096, 16384, 65536, 262144, 1 << 20, 4 << 20, 8 << 20};
    static const int sub_counts[] = {1, 4};
    static const int modes[] = {M_UNIX, M_TCP, M_RCOPY, M_RZERO};
    printf("%6s %4s %-8s | %10s %8s %5s | %8s %5s %9s %9s | %s\n", "size", "subs", "mode", "flat msg/s", "GB/s",
           "cpu%", "paced Hz", "cpu%", "p50 us", "p99 us", "errors");
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        for (size_t j = 0; j < 2; j++) {
            for (size_t k = 0; k < 4; k++) {
                cfg_t c = {.mode = modes[k], .subs = sub_counts[j], .seconds = seconds, .size = sizes[i]};
                result_t flat = run(c);
                c.hz = 2e8 / (double)sizes[i];
                if (c.hz > 10000) c.hz = 10000;
                result_t paced = run(c);
                char sz[16];
                human(sz, sizes[i]);
                printf("%6s %4d %-8s | %10.0f %8.2f %5.0f | %8.0f %5.0f %9.1f %9.1f | %llu\n", sz, sub_counts[j],
                       names[modes[k]], flat.per_sub, flat.gbps, flat.cpu, c.hz, paced.cpu, paced.p50_us,
                       paced.p99_us, (unsigned long long)(flat.errors + paced.errors));
                fflush(stdout);
            }
        }
    }
}

static void handover(double seconds, size_t threshold, double quiet) {
    static const int workloads[] = {W_STEP, W_MIXED, W_GROW};
    static const int sub_counts[] = {1, 4};
    static const int modes[] = {M_UNIX, M_TCP, M_RZERO, M_AUTO};
    printf("threshold %zu B, quiet window %.2f s, %.1f s per run, flat out\n", threshold, quiet, seconds);
    printf("%-6s %4s %-8s | %10s %5s %9s | %4s %4s %4s %11s | %s\n", "load", "subs", "mode", "msg/s each", "cpu%",
           "p99 us", "up", "down", "grow", "max pause", "errors");
    for (size_t w = 0; w < 3; w++) {
        for (size_t j = 0; j < 2; j++) {
            for (size_t k = 0; k < 4; k++) {
                cfg_t c = {.mode = modes[k], .subs = sub_counts[j], .workload = workloads[w], .seconds = seconds,
                           .threshold = threshold, .quiet = quiet, .size = 256};
                result_t r = run(c);
                printf("%-6s %4d %-8s | %10.0f %5.0f %9.1f | %4llu %4llu %4llu %9.1fus | %llu\n", wnames[workloads[w]],
                       sub_counts[j], names[modes[k]], r.per_sub, r.cpu, r.p99_us, (unsigned long long)r.ups,
                       (unsigned long long)r.downs, (unsigned long long)r.grows, r.pause_max_us,
                       (unsigned long long)r.errors);
                fflush(stdout);
            }
        }
    }
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "sweep")) {
        sweep(argc > 2 ? atof(argv[2]) : 1.5);
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "handover")) {
        handover(argc > 2 ? atof(argv[2]) : 2, argc > 3 ? strtoull(argv[3], 0, 10) : 65536, argc > 4 ? atof(argv[4]) : 0.25);
        return 0;
    }
    if (argc < 3) {
        fprintf(stderr,
                "usage: shmbench <unix|tcp|ringcopy|ringzero|auto|copy|inplace> <subscribers> [hz, 0 = flat out] [seconds] [bytes]\n"
                "       shmbench sweep [seconds per run]\n"
                "       shmbench handover [seconds per run] [threshold bytes] [quiet seconds]\n");
        return 2;
    }
    cfg_t c = {.mode = -1, .subs = atoi(argv[2]), .seconds = 3, .size = 6220800, .threshold = 65536, .quiet = 0.25};
    for (int m = 0; m < M_COUNT; m++) if (!strcmp(argv[1], names[m])) c.mode = m;
    if (c.mode < 0 || c.subs < 1 || c.subs > MAXS) return 2;
    if (argc > 3) c.hz = atof(argv[3]);
    if (argc > 4) c.seconds = atof(argv[4]);
    if (argc > 5) c.size = strtoull(argv[5], 0, 10);
    if (argc > 6) for (int w = 0; w < W_COUNT; w++) if (!strcmp(argv[6], wnames[w])) c.workload = w;
    if (argc > 7) c.quiet = atof(argv[7]);
    c.size = c.size < 8 ? 8 : c.size & ~(size_t)7;
    result_t r = run(c);
    printf("%-8s %d sub %5s %8zu B  each got %9.1f/s  total %6.2f GB/s  missed %llu torn %llu errors %llu  "
           "cpu %4.0f%%  latency p50 <%.1fus p99 <%.1fus  handovers up %llu down %llu\n",
           names[c.mode], c.subs, c.hz > 0 ? argv[3] : "max", c.size, r.per_sub, r.gbps, (unsigned long long)r.missed,
           (unsigned long long)r.torn, (unsigned long long)r.errors, r.cpu, r.p50_us, r.p99_us,
           (unsigned long long)r.ups, (unsigned long long)r.downs);
    return r.errors != 0;
}
