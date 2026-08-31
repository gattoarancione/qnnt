/*
 * The Zig demo nodes (src/node-0..4) rewritten against the C ABI.
 *
 *   ./node-c 0                    publish test/topic-a @100Hz and test/topic-b @20Hz
 *   ./node-c 1                    publish test/topic-c @1kHz, subscribe test/topic-a
 *   ./node-c 2                    subscribe test/topic-b and test/topic-c
 *   ./node-c 3 [period_us] [size] TLD load generator on test/bench
 *   ./node-c 4 [report_ms]        TLD benchmark subscriber on test/bench
 *
 * Topics and rates match the Zig nodes, so any mix interoperates: a C role 0 feeding a
 * Python role 2 is the same system as five Zig nodes.
 *
 * Node-4's decoder microbenchmark is not reproduced here; it measures the Zig decoder in
 * isolation and belongs with it.
 */
#include <qnnt.h>

#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr)                                                                     \
    do {                                                                                \
        qnnt_status _s = (expr);                                                          \
        if (_s != QNNT_OK) {                                                              \
            fprintf(stderr, "%s failed: %s\n", #expr, qnnt_status_name(_s));              \
            return 1;                                                                     \
        }                                                                                 \
    } while (0)

#define TOPIC_A "test/topic-a"
#define TOPIC_B "test/topic-b"
#define TOPIC_C "test/topic-c"
#define TOPIC_BENCH "test/bench"

/* Sources hand back storage that outlives the call, so string literals are ideal. */
static const uint8_t *source_a(const char *t, size_t tl, size_t *len, void *u) {
    (void)t; (void)tl; (void)u;
    *len = 6;
    return (const uint8_t *)"ciao!\n";
}

static const uint8_t *source_b(const char *t, size_t tl, size_t *len, void *u) {
    (void)t; (void)tl; (void)u;
    *len = 6;
    return (const uint8_t *)"!oaic\n";
}

static const uint8_t *source_c(const char *t, size_t tl, size_t *len, void *u) {
    (void)t; (void)tl; (void)u;
    *len = 6;
    return (const uint8_t *)"hola!\n";
}

static void idle_until_stopped(void) {
    while (!qnnt_stop_requested()) qnnt_sleep_ms(1000);
}

/* --- role 0: two scheduled publishers ---------------------------------------- */

static int role0(void) {
    CHECK(qnnt_publisher_start(TOPIC_A, strlen(TOPIC_A), source_a, 10000, NULL)); /* 100 Hz */
    CHECK(qnnt_publisher_start(TOPIC_B, strlen(TOPIC_B), source_b, 50000, NULL)); /*  20 Hz */
    printf("node-c 0: publishing %s @100Hz, %s @20Hz\n", TOPIC_A, TOPIC_B);
    idle_until_stopped();
    return 0;
}

/* --- role 1: publish one topic, consume another ------------------------------ */

/* Only ever touched by this topic's subscriber thread, so no synchronisation needed. */
static uint64_t prev_a_us;

static void on_topic_a(const char *topic, size_t topic_len, const uint8_t *data, size_t len,
                       void *user) {
    (void)user;
    const uint64_t us = (uint64_t)qnnt_now_micros();
    const uint64_t delta = prev_a_us ? us - prev_a_us : 0;
    prev_a_us = us;
    printf("[%" PRIu64 ".%03" PRIu64 "] (+%" PRIu64 "us) node-c 1 received on %.*s: %.*s",
           us / 1000, us % 1000, delta, (int)topic_len, topic, (int)len, (const char *)data);
}

static int role1(void) {
    CHECK(qnnt_publisher_start(TOPIC_C, strlen(TOPIC_C), source_c, 1000, NULL)); /* 1 kHz */
    CHECK(qnnt_subscribe(TOPIC_A, strlen(TOPIC_A), on_topic_a, NULL));
    printf("node-c 1: publishing %s @1kHz, subscribed to %s\n", TOPIC_C, TOPIC_A);
    idle_until_stopped();
    return 0;
}

/* --- role 2: one handler, two subscriptions, told apart by user data --------- */

struct feed {
    const char *label;
    uint64_t prev_us;
    uint64_t count;
};

static void on_feed(const char *topic, size_t topic_len, const uint8_t *data, size_t len,
                    void *user) {
    struct feed *feed = user;
    const uint64_t us = (uint64_t)qnnt_now_micros();
    const uint64_t delta = feed->prev_us ? us - feed->prev_us : 0;
    feed->prev_us = us;
    feed->count++;
    printf("[%" PRIu64 ".%03" PRIu64 "] (+%" PRIu64 "us) node-c 2 feed %s #%" PRIu64
           " on %.*s: %.*s",
           us / 1000, us % 1000, delta, feed->label, feed->count, (int)topic_len, topic,
           (int)len, (const char *)data);
}

static int role2(void) {
    static struct feed feed_b = {.label = "b"};
    static struct feed feed_c = {.label = "c"};
    CHECK(qnnt_subscribe(TOPIC_B, strlen(TOPIC_B), on_feed, &feed_b));
    CHECK(qnnt_subscribe(TOPIC_C, strlen(TOPIC_C), on_feed, &feed_c));
    printf("node-c 2: subscribed to %s and %s\n", TOPIC_B, TOPIC_C);
    idle_until_stopped();
    return 0;
}

/* --- role 3: TLD load generator ---------------------------------------------- */

static qnnt_tld_encoder *bench_enc;
static uint8_t *bench_payload;
static size_t bench_payload_len;
static uint64_t bench_seq;
static atomic_ullong bench_sent, bench_bytes;

static const uint8_t *bench_source(const char *t, size_t tl, size_t *len, void *u) {
    (void)t; (void)tl; (void)u;

    qnnt_tld_encoder_reset(bench_enc);
    size_t obj;
    if (qnnt_tld_begin_object(bench_enc, &obj) != QNNT_TLD_OK) return NULL;
    qnnt_tld_write_string(bench_enc, (const uint8_t *)"seq", 3);
    qnnt_tld_write_u64(bench_enc, ++bench_seq);
    qnnt_tld_write_string(bench_enc, (const uint8_t *)"t", 1);
    qnnt_tld_write_u64(bench_enc, (uint64_t)qnnt_now_micros());
    qnnt_tld_write_string(bench_enc, (const uint8_t *)"data", 4);
    qnnt_tld_write_buffer(bench_enc, bench_payload, bench_payload_len);
    if (qnnt_tld_end_object(bench_enc, obj) != QNNT_TLD_OK) return NULL;

    const uint8_t *bytes = qnnt_tld_encoder_bytes(bench_enc, len);
    atomic_fetch_add(&bench_sent, 1);
    atomic_fetch_add(&bench_bytes, *len);
    return bytes;
}

static int role3(uint64_t period_us, size_t payload_bytes) {
    bench_enc = qnnt_tld_encoder_create();
    if (!bench_enc) return 1;

    bench_payload = malloc(payload_bytes ? payload_bytes : 1);
    if (!bench_payload) return 1;
    bench_payload_len = payload_bytes;
    /* Cycles every byte value, so 0x0A and 0xFF are in there: a benchmark that only moved
     * text would not be exercising what TLD framing is for. */
    for (size_t i = 0; i < payload_bytes; i++) bench_payload[i] = (uint8_t)i;

    size_t frame_len = 0;
    (void)bench_source(TOPIC_BENCH, strlen(TOPIC_BENCH), &frame_len, NULL);
    atomic_store(&bench_sent, 0);
    atomic_store(&bench_bytes, 0);
    bench_seq = 0;

    if (period_us == 0) {
        printf("node-c 3: %zuB payload, %zuB frames, unpaced\n", payload_bytes, frame_len);
    } else {
        printf("node-c 3: %zuB payload, %zuB frames, %" PRIu64 "us period (%.1f Hz)\n",
               payload_bytes, frame_len, period_us, 1e6 / (double)period_us);
    }

    CHECK(qnnt_publisher_start(TOPIC_BENCH, strlen(TOPIC_BENCH), bench_source, period_us, NULL));

    unsigned long long last = 0, last_bytes = 0;
    int64_t last_us = qnnt_now_micros();
    while (!qnnt_stop_requested()) {
        qnnt_sleep_ms(1000);
        const int64_t now = qnnt_now_micros();
        const unsigned long long sent = atomic_load(&bench_sent);
        const unsigned long long bytes = atomic_load(&bench_bytes);
        const double secs = (double)(now - last_us) / 1e6;
        printf("node-c 3 sent %.0f frames/s (%.1f KB/s), %llu total\n",
               (double)(sent - last) / secs, (double)(bytes - last_bytes) / secs / 1024.0, sent);
        last = sent; last_bytes = bytes; last_us = now;
    }
    return 0;
}

/* --- role 4: TLD benchmark subscriber ---------------------------------------- */

#define BUCKET_US 4
#define BUCKETS 4096

static struct {
    uint64_t frames, wire_bytes, payload_bytes, lat_sum, lat_min, lat_max;
    uint64_t hist[BUCKETS], overflow;
    uint64_t total, gaps, bad_payload, errors, expected_seq;
    uint64_t window_start_us, report_us;
} st;

static uint64_t percentile(double p) {
    uint64_t total = st.overflow;
    for (int i = 0; i < BUCKETS; i++) total += st.hist[i];
    if (total == 0) return 0;
    const uint64_t target = (uint64_t)((double)total * p);
    uint64_t seen = 0;
    for (int i = 0; i < BUCKETS; i++) {
        seen += st.hist[i];
        if (seen >= target) return (uint64_t)(i + 1) * BUCKET_US;
    }
    return (uint64_t)BUCKETS * BUCKET_US;
}

static void report(uint64_t now_us) {
    const double secs = (double)(now_us - st.window_start_us) / 1e6;
    if (secs <= 0) return;
    printf("node-c 4 %.0f frames/s | wire %.1f KB/s | lat us min %" PRIu64 " mean %.0f p50 %"
           PRIu64 " p99 %" PRIu64 " max %" PRIu64 " | gaps %" PRIu64 " badpay %" PRIu64
           " err %" PRIu64 " | %" PRIu64 " total\n",
           (double)st.frames / secs, (double)st.wire_bytes / secs / 1024.0,
           st.frames ? st.lat_min : 0,
           st.frames ? (double)st.lat_sum / (double)st.frames : 0.0,
           percentile(0.50), percentile(0.99), st.lat_max,
           st.gaps, st.bad_payload, st.errors, st.total);

    st.frames = st.wire_bytes = st.payload_bytes = st.lat_sum = st.lat_max = 0;
    st.lat_min = UINT64_MAX;
    memset(st.hist, 0, sizeof st.hist);
    st.overflow = 0;
    st.window_start_us = now_us;
}

static void on_bench_frame(const char *topic, size_t topic_len, const qnnt_tld_frame *frame,
                           void *user) {
    (void)topic; (void)topic_len; (void)user;

    uint64_t sent_us = 0, seq = 0, payload_len = 0;
    qnnt_tld_iter it;
    if (qnnt_tld_object_iter(frame, &it) != QNNT_TLD_OK) { st.errors++; return; }
    for (;;) {
        const uint8_t *key; size_t key_len; qnnt_tld_frame value; bool have;
        if (qnnt_tld_object_next(&it, &key, &key_len, &value, &have) != QNNT_TLD_OK) {
            st.errors++;
            return;
        }
        if (!have) break;
        if (key_len == 3 && memcmp(key, "seq", 3) == 0) {
            qnnt_tld_as_u64(&value, &seq);
        } else if (key_len == 1 && key[0] == 't') {
            qnnt_tld_as_u64(&value, &sent_us);
        } else if (key_len == 4 && memcmp(key, "data", 4) == 0) {
            const uint8_t *p; size_t l;
            if (qnnt_tld_as_buffer(&value, &p, &l) == QNNT_TLD_OK) {
                payload_len = l;
                for (size_t i = 0; i < l; i++) {
                    if (p[i] != (uint8_t)i) { st.bad_payload++; break; }
                }
            }
        }
    }

    if (st.expected_seq != 0 && seq > st.expected_seq) st.gaps += seq - st.expected_seq;
    st.expected_seq = seq + 1;

    const uint64_t now_us = (uint64_t)qnnt_now_micros();
    const uint64_t latency = now_us > sent_us ? now_us - sent_us : 0;

    st.total++;
    st.frames++;
    st.wire_bytes += frame->raw_len;
    st.payload_bytes += payload_len;
    st.lat_sum += latency;
    if (latency < st.lat_min) st.lat_min = latency;
    if (latency > st.lat_max) st.lat_max = latency;
    const uint64_t bucket = latency / BUCKET_US;
    if (bucket < BUCKETS) st.hist[bucket]++; else st.overflow++;

    if (st.window_start_us == 0) st.window_start_us = now_us;
    if (now_us - st.window_start_us >= st.report_us) report(now_us);
}

static int role4(uint64_t report_ms) {
    st.lat_min = UINT64_MAX;
    st.report_us = report_ms * 1000;
    CHECK(qnnt_subscribe_frames(TOPIC_BENCH, strlen(TOPIC_BENCH), on_bench_frame, NULL));
    printf("node-c 4: benchmarking %s, reporting every %" PRIu64 "ms\n", TOPIC_BENCH, report_ms);
    idle_until_stopped();
    return 0;
}

/* --- dispatch ---------------------------------------------------------------- */

int main(int argc, char **argv) {
    /* Line-buffered even when redirected. Otherwise stdout is block-buffered to a file and
     * a demo that prints a banner then loops forever appears to produce nothing at all. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    const int role = argc > 1 ? atoi(argv[1]) : 0;

    /* The library reads no environment of its own, by design, so an example that wants a
     * port from one has to read it and pass it. Matches python/nodes.py, which is what
     * lets the two find each other. */
    /* Every QNNT_* variable, handled by the library so all four languages agree. */
    qnnt_configure_from_environment();

    if (qnnt_init() != QNNT_OK) { fprintf(stderr, "qnnt_init failed\n"); return 1; }
    printf("node-c %d: registry port %u\n", role, qnnt_registry_port());
    qnnt_install_signal_handlers(); /* Ctrl-C asks for a clean stop */

    int rc;
    switch (role) {
    case 0: rc = role0(); break;
    case 1: rc = role1(); break;
    case 2: rc = role2(); break;
    case 3: rc = role3(argc > 2 ? strtoull(argv[2], NULL, 10) : 1000,
                       argc > 3 ? (size_t)strtoull(argv[3], NULL, 10) : 64); break;
    case 4: rc = role4(argc > 2 ? strtoull(argv[2], NULL, 10) : 1000); break;
    default:
        fprintf(stderr, "usage: %s <0..4> [args]\n", argv[0]);
        rc = 2;
    }

    qnnt_deinit();
    return rc;
}
