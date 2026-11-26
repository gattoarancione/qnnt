/*
 * The C node of the five-language mesh. See SCHEMA.txt.
 *
 *   zig build mesh && bash examples/mesh/run.sh
 *
 * Publishes mesh/c and subscribes to the other four topics. C has neither templates nor
 * reflection, so the schema is a descriptor table -- and it is C's limits that shaped the
 * schema in the first place: fixed strings, a fixed-length array, an explicit blob length.
 */

#include "qnnt.h"
#include "told.h"

#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ME "c"
#define MY_TOPIC "mesh/c"

static const struct {
    const char *name;
    const char *topic;
} peers[] = {
    {"zig", "mesh/zig"},
    {"cpp", "mesh/cpp"},
    {"python", "mesh/python"},
    {"qt", "mesh/qt"},
};
#define PEER_COUNT (sizeof peers / sizeof peers[0])

typedef struct {
    uint8_t channel;
    double value;
    bool valid;
} reading;

static const told_field reading_fields[] = {
    TOLD_FIELD(reading, channel, TOLD_F_U8),
    TOLD_FIELD(reading, value, TOLD_F_F64),
    TOLD_FIELD(reading, valid, TOLD_F_BOOL),
};
static const told_desc reading_desc = TOLD_DESC("Reading", reading_fields, 1);

typedef struct {
    double x;
    double y;
} mesh_origin;

static const told_field origin_fields[] = {
    TOLD_FIELD(mesh_origin, x, TOLD_F_F64),
    TOLD_FIELD(mesh_origin, y, TOLD_F_F64),
};
static const told_desc origin_desc = TOLD_DESC("Origin", origin_fields, 1);

typedef struct {
    uint64_t seq;
    char source[16];
    int32_t mode;
    int32_t count;
    float temp;
    uint8_t blob[8];
    size_t blob_len;
    mesh_origin origin;
    reading readings[3];
} sample;

/* The blob's length is a C implementation detail -- no other language has a field for it,
 * and none is sent: TOLD_FIELD_BYTES names the member that holds it. */
static const told_field sample_fields[] = {
    TOLD_FIELD(sample, seq, TOLD_F_U64),
    TOLD_FIELD_STRING(sample, source),
    TOLD_FIELD(sample, mode, TOLD_F_I32),
    TOLD_FIELD(sample, count, TOLD_F_I32),
    TOLD_FIELD(sample, temp, TOLD_F_F32),
    TOLD_FIELD_BYTES(sample, blob, blob_len),
    TOLD_FIELD_STRUCT(sample, origin, &origin_desc),
    TOLD_FIELD_ARRAY_STRUCT(sample, readings, &reading_desc),
};
static const told_desc sample_desc = TOLD_DESC("Sample", sample_fields, 1);

static sample expected(uint64_t seq, const char *source) {
    sample s;
    memset(&s, 0, sizeof s);
    s.seq = seq;
    snprintf(s.source, sizeof s.source, "%s", source);
    s.mode = (int32_t)(seq % 3);
    s.count = -(int32_t)seq;
    s.temp = 36.5f;
    s.blob[0] = 0x00;
    s.blob[1] = 0xFF;
    s.blob[2] = 0x0A;
    s.blob_len = 3;
    s.origin.x = 1.5;
    s.origin.y = -2.5;
    for (int i = 0; i < 3; ++i) {
        s.readings[i].channel = (uint8_t)(i + 1);
        s.readings[i].value = (double)(seq * 10 + (uint64_t)i);
        s.readings[i].valid = (i != 1);
    }
    return s;
}

/* run.sh sets MESH_PEERS to the languages it actually started, so the mesh works with any
 * subset: build without -Dqt and the other nodes stop waiting for a Qt peer. */
static bool peer_present(const char *name) {
    const char *list = getenv("MESH_PEERS");
    if (list == NULL || *list == '\0') return true;

    const size_t len = strlen(name);
    for (const char *p = list; *p != '\0';) {
        while (*p == ' ' || *p == ',') ++p;
        const char *start = p;
        while (*p != '\0' && *p != ',') ++p;
        size_t span = (size_t)(p - start);
        while (span > 0 && start[span - 1] == ' ') --span;
        if (span == len && strncmp(start, name, len) == 0) return true;
    }
    return false;
}

typedef struct {
    const char *name;
    bool expected;
    uint64_t received;
    uint64_t first_seq;
    uint64_t last_seq;
    uint64_t problems;
} peer_state;

static peer_state states[PEER_COUNT];

/* One subscriber thread per topic, so each slot has a single writer. */
static void on_frame(const char *topic, size_t topic_len, const told_frame *frame,
                     void *user) {
    (void)topic;
    (void)topic_len;
    peer_state *peer = (peer_state *)user;

    sample got;
    memset(&got, 0, sizeof got);
    bool bad = false;

    if (told_unpack_struct(frame, &sample_desc, &got) != TOLD_OK) {
        bad = true;
    } else {
        const sample want = expected(got.seq, peer->name);
        if (strcmp(got.source, want.source) != 0) bad = true;
        if (got.mode != want.mode || got.count != want.count) bad = true;
        /* temp crosses as a 32-bit float: compare with a tolerance, unlike the f64 fields. */
        if (fabsf(got.temp - want.temp) > 1e-6f) bad = true;
        if (got.blob_len != want.blob_len ||
            memcmp(got.blob, want.blob, got.blob_len) != 0) {
            bad = true;
        }
        if (got.origin.x != want.origin.x || got.origin.y != want.origin.y) bad = true;
        for (int i = 0; i < 3; ++i) {
            if (got.readings[i].channel != want.readings[i].channel) bad = true;
            if (got.readings[i].value != want.readings[i].value) bad = true;
            if (got.readings[i].valid != want.readings[i].valid) bad = true;
        }
    }

    /* A gap inside the run means loss; attaching late only sets the baseline. */
    if (peer->last_seq != 0 && got.seq != peer->last_seq + 1) bad = true;
    if (peer->last_seq == 0) peer->first_seq = got.seq;
    peer->last_seq = got.seq;

    peer->received += 1;
    if (bad) peer->problems += 1;
}

static told_encoder *encoder = NULL;
static uint64_t out_seq = 0;

/* The scheduler starts ticking when qnnt_publisher_start is called, which is before the
 * roster has connected -- so the gate lives in the source callback rather than in main.
 * Returning NULL skips a tick without consuming a sequence number, which is what keeps
 * seq 1 the first sample anybody sees. */
static volatile bool gate_open = false;

static const uint8_t *source_fn(const char *topic, size_t topic_len, size_t *out_len,
                                void *user) {
    (void)topic;
    (void)topic_len;
    (void)user;

    if (!gate_open) {
        *out_len = 0;
        return NULL;
    }

    out_seq += 1;
    told_encoder_reset(encoder);
    const sample s = expected(out_seq, ME);
    if (told_pack_struct(encoder, &sample_desc, &s) != TOLD_OK) {
        *out_len = 0;
        return NULL;
    }
    return told_encoder_bytes(encoder, out_len);
}

int main(int argc, char **argv) {
    const long run_ms = argc > 1 ? strtol(argv[1], NULL, 10) : 9000;
    const unsigned long need = argc > 2 ? strtoul(argv[2], NULL, 10) : 5;

    encoder = told_encoder_create();
    if (encoder == NULL) return 1;

    qnnt_configure_from_environment();
    if (qnnt_init() != QNNT_OK) {
        printf("%s: failed to start\n", ME);
        return 1;
    }
    qnnt_install_signal_handlers();

    if (qnnt_publisher_start(MY_TOPIC, strlen(MY_TOPIC), &source_fn, 200000, NULL) !=
        QNNT_OK) {
        printf("%s: failed to publish %s\n", ME, MY_TOPIC);
        return 1;
    }

    size_t expecting = 0;
    for (size_t i = 0; i < PEER_COUNT; ++i) {
        states[i].name = peers[i].name;
        states[i].expected = peer_present(peers[i].name);
        if (!states[i].expected) continue;
        ++expecting;
        if (qnnt_subscribe_frames(peers[i].topic, strlen(peers[i].topic), &on_frame,
                                  &states[i]) != QNNT_OK) {
            printf("%s: failed to subscribe %s\n", ME, peers[i].topic);
            return 1;
        }
    }

    printf("%s: publishing %s, subscribed to %zu peers\n", ME, MY_TOPIC, expecting);
    fflush(stdout);

    /* All of them, not just the first: this node knows how many peers the roster says are
     * coming, and waiting for the last one means every peer sees seq 1. */
    if (qnnt_wait_for_subscribers(MY_TOPIC, strlen(MY_TOPIC), expecting, 5000)) {
        printf("%s: all %zu subscribers on %s, publishing\n", ME, expecting, MY_TOPIC);
    } else {
        printf("%s: only %zu of %zu subscribers after 5s, publishing anyway\n", ME,
               qnnt_subscriber_count(MY_TOPIC, strlen(MY_TOPIC)), expecting);
    }
    gate_open = true;
    fflush(stdout);

    const int64_t deadline = qnnt_now_micros() + (int64_t)run_ms * 1000;
    while (!qnnt_stop_requested() && qnnt_now_micros() < deadline) qnnt_sleep_ms(200);

    bool failed = false;
    for (size_t i = 0; i < PEER_COUNT; ++i) {
        if (!states[i].expected) continue;
        const bool ok = states[i].received >= need && states[i].problems == 0;
        if (!ok) failed = true;
        printf("%s: from %-7s %3llu samples, seq %llu..%llu, %llu problem(s) %s\n", ME,
               states[i].name, (unsigned long long)states[i].received,
               (unsigned long long)states[i].first_seq,
               (unsigned long long)states[i].last_seq,
               (unsigned long long)states[i].problems, ok ? "ok" : "FAILED");
    }

    printf("%s: %s\n", ME, failed ? "FAILED" : "all peers verified");
    fflush(stdout);
    qnnt_deinit();
    told_encoder_destroy(encoder);
    return failed ? 1 : 0;
}
