// mbench -- two local transport models, P producers to S consumers, every message to every consumer.
//
//   async  : sockets (tcp or unix), variable-length frames [size/2, 3*size/2], producers never
//            wait for consumers beyond what the kernel buffers. qnnt's model.
//   ring   : shared memory, one ring of fixed-size slots per producer, read by every consumer;
//            the producer waits while the slowest consumer is a full ring behind (lossless).
//
// Both sides do the same work per message: the producer fills the payload, the consumer sums
// every byte of it. So the ring cannot win by never touching the data.
//
// usage: mbench <tcp|unix|ring> <mean_payload> [producers] [consumers] [MB per stream]
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAXP 8
#define MAXC 8
#define SLOTS 64
#define HDR 24 /* seq u64 | send time u64 | payload length u32 | producer u32 */

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static void relax(unsigned *spins) {
    if (++*spins < 64) {
#if defined(__aarch64__)
        __asm__ volatile("yield");
#elif defined(__x86_64__)
        __asm__ volatile("pause");
#endif
    } else {
        *spins = 0;
        sched_yield();
    }
}

typedef struct { _Atomic uint64_t v; char pad[56]; } padded;

typedef struct {
    padded head;          /* next sequence the producer will write */
    padded tail[MAXC];    /* next sequence each consumer will read */
} ring_ctl;

typedef struct {
    _Atomic int listening, connected, go;
    int port[MAXC];
    char path[MAXC][64];
    uint64_t t_start, t_end[MAXC];
    uint64_t bytes[MAXC], msgs[MAXC], errors[MAXC];
    uint64_t lat[MAXC][64]; /* log2(ns) buckets */
} shared_t;

static shared_t *sh;
static ring_ctl *rings;
static uint8_t *ring_data; /* MAXP rings of SLOTS slots */
static int P = 2, S = 2;
static size_t mean, lo, hi, slot_size;
static uint64_t N;
static int mode; /* 0 tcp, 1 unix, 2 ring */

static size_t len_of(int producer, uint64_t seq) {
    if (mode == 2) return mean; /* fixed chunks */
    uint64_t x = seq * 0x9E3779B97F4A7C15ull ^ (uint64_t)(producer + 1) * 0xBF58476D1CE4E5B9ull;
    x ^= x >> 31;
    x *= 0x94D049BB133111EBull;
    x ^= x >> 29;
    return lo + (size_t)(x % (hi - lo + 1));
}

static void fill(uint8_t *m, int producer, uint64_t seq, size_t len) {
    uint64_t t = now_ns();
    uint32_t l = (uint32_t)len, p = (uint32_t)producer;
    memcpy(m, &seq, 8);
    memcpy(m + 8, &t, 8);
    memcpy(m + 16, &l, 4);
    memcpy(m + 20, &p, 4);
    memset(m + HDR, (int)(seq & 0xff), len);
}

/* Read the message: check its sequence, sum its payload, record its age. */
static uint64_t sink;
static void consume(int c, const uint8_t *m, uint64_t want_seq, uint64_t *lat) {
    uint64_t seq, t;
    uint32_t len;
    memcpy(&seq, m, 8);
    memcpy(&t, m + 8, 8);
    memcpy(&len, m + 16, 4);
    uint64_t sum = 0, w;
    size_t i = 0;
    for (; i + 8 <= len; i += 8) { memcpy(&w, m + HDR + i, 8); sum += w; }
    for (; i < len; i++) sum += m[HDR + i];
    sink += sum;
    uint64_t age = now_ns() - t;
    lat[age ? 63 - __builtin_clzll(age) : 0]++;
    if (seq != want_seq || m[HDR] != (uint8_t)(seq & 0xff)) __atomic_add_fetch(&sh->errors[c], 1, __ATOMIC_RELAXED);
    __atomic_add_fetch(&sh->bytes[c], len, __ATOMIC_RELAXED);
}

/* ---- async sockets ---------------------------------------------------------------------- */

static int write_all(int fd, const uint8_t *b, size_t n) {
    while (n) {
        ssize_t k = write(fd, b, n);
        if (k <= 0) return -1;
        b += k;
        n -= (size_t)k;
    }
    return 0;
}

static void widen(int fd) {
    int sz = 1 << 20;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
}

typedef struct { int c, fd; uint64_t lat[64]; } conn_arg;

static void *socket_reader(void *a_) {
    conn_arg *a = a_;
    size_t cap = 64 * 1024 + 2 * (hi + HDR);
    uint8_t *buf = malloc(cap);
    size_t have = 0, at = 0;
    for (uint64_t seq = 0; seq < N; seq++) {
        /* ensure a header, then the whole message, compacting when the tail runs out */
        for (int need_hdr = 1;; need_hdr = 0) {
            size_t want = HDR;
            if (have - at >= HDR) { uint32_t l; memcpy(&l, buf + at + 16, 4); want = HDR + l; }
            if (have - at >= want) break;
            if (at && cap - have < 64 * 1024) { memmove(buf, buf + at, have - at); have -= at; at = 0; }
            ssize_t k = read(a->fd, buf + have, cap - have);
            if (k <= 0) { free(buf); return NULL; }
            have += (size_t)k;
            (void)need_hdr;
        }
        uint32_t l;
        memcpy(&l, buf + at + 16, 4);
        consume(a->c, buf + at, seq, a->lat);
        at += HDR + l;
    }
    free(buf);
    return NULL;
}

static void socket_consumer(int c) {
    int ls;
    if (mode == 1) {
        struct sockaddr_un u = {0};
        u.sun_family = AF_UNIX;
        snprintf(sh->path[c], sizeof sh->path[c], "/tmp/mbench-%d-%d.sock", getppid(), c);
        strcpy(u.sun_path, sh->path[c]);
        unlink(u.sun_path);
        ls = socket(AF_UNIX, SOCK_STREAM, 0);
        if (bind(ls, (struct sockaddr *)&u, sizeof u)) { perror("bind"); _exit(1); }
    } else {
        struct sockaddr_in in = {0};
        in.sin_family = AF_INET;
        in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        socklen_t sl = sizeof in;
        ls = socket(AF_INET, SOCK_STREAM, 0);
        if (bind(ls, (struct sockaddr *)&in, sl)) { perror("bind"); _exit(1); }
        getsockname(ls, (struct sockaddr *)&in, &sl);
        sh->port[c] = ntohs(in.sin_port);
    }
    listen(ls, 64);
    atomic_fetch_add(&sh->listening, 1);

    conn_arg args[MAXP];
    pthread_t th[MAXP];
    for (int p = 0; p < P; p++) {
        args[p].c = c;
        args[p].fd = accept(ls, NULL, NULL);
        memset(args[p].lat, 0, sizeof args[p].lat);
        if (mode == 1) widen(args[p].fd);
    }
    for (int p = 0; p < P; p++) pthread_create(&th[p], NULL, socket_reader, &args[p]);
    for (int p = 0; p < P; p++) {
        pthread_join(th[p], NULL);
        for (int b = 0; b < 64; b++) sh->lat[c][b] += args[p].lat[b];
    }
    sh->msgs[c] = N * (uint64_t)P;
    sh->t_end[c] = now_ns();
    if (mode == 1) unlink(sh->path[c]);
}

static void socket_producer(int p) {
    while (atomic_load(&sh->listening) < S) usleep(1000);
    int fd[MAXC];
    for (int c = 0; c < S; c++) {
        if (mode == 1) {
            struct sockaddr_un u = {0};
            u.sun_family = AF_UNIX;
            strcpy(u.sun_path, sh->path[c]);
            fd[c] = socket(AF_UNIX, SOCK_STREAM, 0);
            widen(fd[c]);
            if (connect(fd[c], (struct sockaddr *)&u, sizeof u)) { perror("connect"); _exit(1); }
        } else {
            struct sockaddr_in in = {0};
            in.sin_family = AF_INET;
            in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            in.sin_port = htons((uint16_t)sh->port[c]);
            fd[c] = socket(AF_INET, SOCK_STREAM, 0);
            if (connect(fd[c], (struct sockaddr *)&in, sizeof in)) { perror("connect"); _exit(1); }
        }
    }
    atomic_fetch_add(&sh->connected, 1);
    while (!atomic_load(&sh->go)) usleep(100);

    uint8_t *m = malloc(HDR + hi);
    for (uint64_t seq = 0; seq < N; seq++) {
        size_t len = len_of(p, seq);
        fill(m, p, seq, len);
        for (int c = 0; c < S; c++) /* like qnnt's publishAll: one write per subscriber */
            if (write_all(fd[c], m, HDR + len)) _exit(1);
    }
    free(m);
}

/* ---- synchronous ring ------------------------------------------------------------------- */

typedef struct { int c, p; uint64_t lat[64]; } ring_arg;

static void *ring_reader(void *a_) {
    ring_arg *a = a_;
    ring_ctl *r = &rings[a->p];
    uint8_t *data = ring_data + (size_t)a->p * SLOTS * slot_size;
    unsigned spins = 0;
    for (uint64_t seq = 0; seq < N;) {
        uint64_t head = atomic_load_explicit(&r->head.v, memory_order_acquire);
        if (head == seq) { relax(&spins); continue; }
        for (; seq < head; seq++) consume(a->c, data + (seq % SLOTS) * slot_size, seq, a->lat);
        atomic_store_explicit(&r->tail[a->c].v, seq, memory_order_release);
    }
    return NULL;
}

static void ring_consumer(int c) {
    ring_arg args[MAXP];
    pthread_t th[MAXP];
    for (int p = 0; p < P; p++) {
        args[p] = (ring_arg){.c = c, .p = p};
        pthread_create(&th[p], NULL, ring_reader, &args[p]);
    }
    for (int p = 0; p < P; p++) {
        pthread_join(th[p], NULL);
        for (int b = 0; b < 64; b++) sh->lat[c][b] += args[p].lat[b];
    }
    sh->msgs[c] = N * (uint64_t)P;
    sh->t_end[c] = now_ns();
}

static void ring_producer(int p) {
    atomic_fetch_add(&sh->connected, 1);
    while (!atomic_load(&sh->go)) usleep(100);
    ring_ctl *r = &rings[p];
    uint8_t *data = ring_data + (size_t)p * SLOTS * slot_size;
    uint64_t min_tail = 0;
    unsigned spins = 0;
    for (uint64_t seq = 0; seq < N; seq++) {
        while (seq - min_tail >= SLOTS) { /* full: wait for the slowest consumer */
            uint64_t m = UINT64_MAX;
            for (int c = 0; c < S; c++) {
                uint64_t t = atomic_load_explicit(&r->tail[c].v, memory_order_acquire);
                if (t < m) m = t;
            }
            min_tail = m;
            if (seq - min_tail >= SLOTS) relax(&spins);
        }
        fill(data + (seq % SLOTS) * slot_size, p, seq, mean);
        atomic_store_explicit(&r->head.v, seq + 1, memory_order_release);
    }
}

/* ---- run -------------------------------------------------------------------------------- */

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: mbench <tcp|unix|ring> <mean_payload> [P] [S] [MB per stream]\n"); return 2; }
    mode = !strcmp(argv[1], "tcp") ? 0 : !strcmp(argv[1], "unix") ? 1 : 2;
    mean = strtoull(argv[2], 0, 10);
    if (argc > 3) P = atoi(argv[3]);
    if (argc > 4) S = atoi(argv[4]);
    double mb = argc > 5 ? atof(argv[5]) : 256;
    lo = mean / 2 ? mean / 2 : 1;
    hi = mean + mean / 2;
    N = (uint64_t)(mb * 1e6 / (double)mean);
    if (N > 3000000) N = 3000000;
    if (N < 2000) N = 2000;
    slot_size = (HDR + mean + 63) & ~(size_t)63;

    sh = mmap(0, sizeof *sh, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    memset(sh, 0, sizeof *sh);
    if (mode == 2) {
        rings = mmap(0, sizeof(ring_ctl) * MAXP, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
        ring_data = mmap(0, (size_t)P * SLOTS * slot_size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
        memset(rings, 0, sizeof(ring_ctl) * MAXP);
    }

    pid_t kids[MAXP + MAXC];
    int nk = 0;
    for (int c = 0; c < S; c++) if (!(kids[nk++] = fork())) { mode == 2 ? ring_consumer(c) : socket_consumer(c); _exit(0); }
    for (int p = 0; p < P; p++) if (!(kids[nk++] = fork())) { mode == 2 ? ring_producer(p) : socket_producer(p); _exit(0); }

    while (atomic_load(&sh->connected) < P) usleep(1000);
    usleep(20000);
    sh->t_start = now_ns();
    atomic_store(&sh->go, 1);
    for (int i = 0; i < nk; i++) waitpid(kids[i], 0, 0);

    struct rusage ru;
    getrusage(RUSAGE_CHILDREN, &ru);
    double cpu = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;

    uint64_t end = 0, bytes = 0, msgs = 0, errs = 0, hist[64] = {0}, total = 0;
    for (int c = 0; c < S; c++) {
        if (sh->t_end[c] > end) end = sh->t_end[c];
        bytes += sh->bytes[c];
        msgs += sh->msgs[c];
        errs += sh->errors[c];
        for (int b = 0; b < 64; b++) { hist[b] += sh->lat[c][b]; total += sh->lat[c][b]; }
    }
    double secs = (end - sh->t_start) / 1e9;
    uint64_t run = 0;
    int p50 = 0, p99 = 0;
    for (int b = 0; b < 64; b++) {
        run += hist[b];
        if (!p50 && run * 2 >= total) p50 = b;
        if (!p99 && run * 100 >= total * 99) { p99 = b; break; }
    }
    printf("%-5s %7zu  %dx%d  %11.0f msg/s %8.0f MB/s  cpu %5.2fs = %5.2f s/GB  age p50 <%6.1fus p99 <%7.1fus  err %llu\n",
           argv[1], mean, P, S, msgs / secs, bytes / secs / 1e6, cpu, cpu / (bytes / 1e9),
           (double)(1ull << (p50 + 1)) / 1e3, (double)(1ull << (p99 + 1)) / 1e3, (unsigned long long)errs);
    return errs != 0;
}
