/* A complete qnnt node in C: publish TOLD frames on a schedule, consume them two ways. */
#include <qnnt.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define CHECK(expr)                                                                    \
    do {                                                                               \
        qnnt_status _s = (expr);                                                        \
        if (_s != QNNT_OK) {                                                            \
            printf("FAIL %s:%d: %s -> %s\n", __FILE__, __LINE__, #expr,                 \
                   qnnt_status_name(_s));                                               \
            return 1;                                                                   \
        }                                                                               \
    } while (0)

static const char TOPIC[] = "test/c-node";

/* Counters for the glob section below. The pattern callback fires on the subscriber's own
 * thread, one thread per joined topic, so these are atomic. */
static atomic_ullong g_bus_one, g_bus_two, g_bus_miss;

static void on_bus(const char *topic, size_t topic_len, const uint8_t *data, size_t data_len,
                   void *user) {
    (void)data; (void)data_len; (void)user;
    /* The callback is told which topic it came from, which is what makes one handler
     * enough for a whole pattern. */
    if (topic_len == strlen("test/c-bus/one") && memcmp(topic, "test/c-bus/one", topic_len) == 0)
        atomic_fetch_add(&g_bus_one, 1);
    else if (topic_len == strlen("test/c-bus/two") && memcmp(topic, "test/c-bus/two", topic_len) == 0)
        atomic_fetch_add(&g_bus_two, 1);
    else
        atomic_fetch_add(&g_bus_miss, 1);
}

/* The source encodes into a long-lived encoder, so its bytes outlive the call. */
static told_encoder *g_enc;
static uint64_t g_seq;

static const uint8_t *source(const char *topic, size_t topic_len, size_t *out_len, void *user) {
    (void)topic; (void)topic_len;
    unsigned long long *sent = user;

    told_encoder_reset(g_enc);
    size_t obj;
    if (told_begin_object(g_enc, &obj) != TOLD_OK) return NULL;
    told_write_string(g_enc, (const uint8_t *)"seq", 3);
    told_write_u64(g_enc, ++g_seq);
    told_write_string(g_enc, (const uint8_t *)"payload", 7);
    /* Bytes hostile to line framing, on purpose. */
    const uint8_t raw[] = {0x0A, 0xFF, 0x00};
    told_write_buffer(g_enc, raw, sizeof raw);
    if (told_end_object(g_enc, obj) != TOLD_OK) return NULL;

    (*sent)++;
    return told_encoder_bytes(g_enc, out_len);
}

/* Callback mode: runs on a library thread, so keep it to atomics. */
static atomic_ullong g_callback_frames;
static atomic_ullong g_callback_seq_sum;

static void on_frame(const char *topic, size_t topic_len, const told_frame *frame, void *user) {
    (void)topic; (void)topic_len; (void)user;

    told_iter it;
    if (told_object_iter(frame, &it) != TOLD_OK) return;
    for (;;) {
        const uint8_t *key; size_t key_len; told_frame value; bool have;
        if (told_object_next(&it, &key, &key_len, &value, &have) != TOLD_OK) return;
        if (!have) break;
        if (key_len == 3 && memcmp(key, "seq", 3) == 0) {
            uint64_t n;
            if (told_as_u64(&value, &n) == TOLD_OK)
                atomic_fetch_add(&g_callback_seq_sum, n);
        }
    }
    atomic_fetch_add(&g_callback_frames, 1);
}

int main(void) {
    unsigned long long sent = 0;

    g_enc = told_encoder_create();
    if (!g_enc) { printf("FAIL: encoder\n"); return 1; }

    /* Our own registry, so this demo is independent of anything else running. */
    CHECK(qnnt_set_registry_port(22301));

    /* Small handler stacks, so every registry connection this demo makes runs on one. Below
     * the floor is refused; an accepted size comes back rounded up to a page. */
    if (qnnt_set_handler_stack_bytes(4096) == QNNT_OK) {
        printf("FAIL: a 4 KiB handler stack was accepted\n");
        return 1;
    }
    CHECK(qnnt_set_handler_stack_bytes(200000));
    if (qnnt_handler_stack_bytes() < 200000) {
        printf("FAIL: handler stack %zu, asked for 200000\n", qnnt_handler_stack_bytes());
        return 1;
    }

    /* Local sockets are on by default; a relative directory is refused, not created
     * somewhere surprising. */
    if (!qnnt_local_sockets() || qnnt_set_socket_dir("relative/dir") == QNNT_OK) {
        printf("FAIL: local socket defaults\n");
        return 1;
    }

    CHECK(qnnt_init());
    printf("registry port %u\n", qnnt_registry_port());
    if (qnnt_set_handler_stack_bytes(0) == QNNT_OK) {
        printf("FAIL: the handler stack changed under a running node\n");
        return 1;
    }
    /* Not installing signal handlers: this demo exits on its own. */

    CHECK(qnnt_publisher_start(TOPIC, strlen(TOPIC), source, 1000 /* us -> 1 kHz */, &sent));

    /* Both modes on the same topic at once. */
    CHECK(qnnt_subscribe_frames(TOPIC, strlen(TOPIC), on_frame, NULL));
    CHECK(qnnt_queue_reserve(512));
    CHECK(qnnt_subscribe_queue(TOPIC, strlen(TOPIC), QNNT_QUEUE_FRAMES));

    printf("publishing %s at 1 kHz; consumer wakes every 100ms\n", TOPIC);

    /* Drain batches on this thread -- the pattern a binding would use. */
    qnnt_message batch[256];
    unsigned long long polled = 0, polls = 0, bytes = 0;
    uint64_t first_us = 0, last_us = 0;

    /* A real consumer does work between drains. Sleeping first lets messages accumulate,
     * which is the whole point: one crossing carries a hundred messages instead of one.
     * Polling in a tight loop instead would return a single message each time and show
     * nothing about batching. */
    for (int i = 0; i < 10; i++) {
        qnnt_sleep_ms(100);
        size_t count = 0;
        CHECK(qnnt_poll(batch, 256, 0 /* already have data */, &count));
        polls++;
        for (size_t j = 0; j < count; j++) {
            if (batch[j].topic_len != strlen(TOPIC) ||
                memcmp(batch[j].topic, TOPIC, batch[j].topic_len) != 0) {
                printf("FAIL: wrong topic on a queued message\n");
                return 1;
            }
            /* The queued bytes are a real TOLD frame; decode to prove the copy is intact. */
            told_frame frame;
            if (told_decode(batch[j].data, batch[j].data_len, &frame) != TOLD_OK) {
                printf("FAIL: queued payload did not decode\n");
                return 1;
            }
            if (first_us == 0) first_us = batch[j].received_us;
            last_us = batch[j].received_us;
            bytes += batch[j].data_len;
            polled++;
        }
    }

    printf("published    %llu\n", sent);
    printf("callback got %llu frames (seq sum %llu)\n",
           (unsigned long long)atomic_load(&g_callback_frames),
           (unsigned long long)atomic_load(&g_callback_seq_sum));
    printf("queue got    %llu messages in %llu polls (%.1f per poll), %llu bytes\n",
           polled, polls, (double)polled / (double)polls, bytes);
    printf("queue span   %.2fs, dropped %llu\n",
           (double)(last_us - first_us) / 1e6, (unsigned long long)qnnt_queue_dropped());

    if (polled == 0) { printf("FAIL: queue delivered nothing\n"); return 1; }
    if (atomic_load(&g_callback_frames) == 0) { printf("FAIL: callback delivered nothing\n"); return 1; }

    /* A zero timeout must return promptly whether or not anything is waiting. */
    size_t count = 0;
    int64_t t0 = qnnt_now_micros();
    CHECK(qnnt_poll(batch, 256, 0, &count));
    int64_t elapsed = qnnt_now_micros() - t0;
    printf("non-blocking poll returned %zu in %lldus\n", count, (long long)elapsed);
    if (elapsed > 50000) { printf("FAIL: zero timeout blocked\n"); return 1; }

    /* --- a glob subscription ------------------------------------------------------
     *
     * One handler for every topic matching a pattern, including topics created after the
     * subscription started -- 'test/c-busy' is next to them and must be left alone. */
    CHECK(qnnt_publisher_start("test/c-bus/one", strlen("test/c-bus/one"), NULL, 0, NULL));
    CHECK(qnnt_publisher_start("test/c-busy", strlen("test/c-busy"), NULL, 0, NULL));
    CHECK(qnnt_subscribe_pattern("test/c-bus/*", strlen("test/c-bus/*"), on_bus, NULL, 200));

    /* Created after the pattern is running: reaching us proves the rescan found it. */
    CHECK(qnnt_publisher_start("test/c-bus/two", strlen("test/c-bus/two"), NULL, 0, NULL));

    for (int i = 0; i < 100 &&
                    (atomic_load(&g_bus_one) == 0 || atomic_load(&g_bus_two) == 0); i++) {
        CHECK(qnnt_publish("test/c-bus/one", strlen("test/c-bus/one"), (const uint8_t *)"tick\n", 5));
        CHECK(qnnt_publish("test/c-bus/two", strlen("test/c-bus/two"), (const uint8_t *)"tick\n", 5));
        CHECK(qnnt_publish("test/c-busy", strlen("test/c-busy"), (const uint8_t *)"tick\n", 5));
        qnnt_sleep_ms(100);
    }

    printf("glob got     one=%llu two=%llu near-miss=%llu\n",
           (unsigned long long)atomic_load(&g_bus_one),
           (unsigned long long)atomic_load(&g_bus_two),
           (unsigned long long)atomic_load(&g_bus_miss));
    if (atomic_load(&g_bus_one) == 0) { printf("FAIL: glob missed a topic present at the start\n"); return 1; }
    if (atomic_load(&g_bus_two) == 0) { printf("FAIL: glob missed a topic that appeared later\n"); return 1; }
    if (atomic_load(&g_bus_miss) != 0) { printf("FAIL: glob took a topic it should not match\n"); return 1; }

    /* The same matcher the subscription used, exposed so a consumer can ask the question
     * itself -- routing a message, or filtering out its own traffic. */
    #define MATCHES(pat, top) qnnt_topic_matches(pat, strlen(pat), top, strlen(top))
    if (!MATCHES("test/c-bus/*", "test/c-bus/one") ||
        !MATCHES("test/c-bus/*", "test/c-bus/deep/er") ||  /* '*' crosses '/' */
        !MATCHES("test/?-bus/one", "test/c-bus/one") ||
        !MATCHES("*", "anything") ||
        MATCHES("test/c-bus/*", "test/c-busy") ||
        MATCHES("test/c-bus/*", "other/c-bus/one") ||
        MATCHES("test/?-bus/one", "test/cc-bus/one")) {
        printf("FAIL: qnnt_topic_matches disagrees with the subscription\n");
        return 1;
    }
    #undef MATCHES

    qnnt_deinit();
    told_encoder_destroy(g_enc);
    printf("OK\n");
    return 0;
}
