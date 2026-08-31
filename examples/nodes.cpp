// The Zig demo nodes (src/node-0..4) in C++.
//
//   ./node-cpp 0                    publish test/topic-a @100Hz and test/topic-b @20Hz
//   ./node-cpp 1                    publish test/topic-c @1kHz, subscribe test/topic-a
//   ./node-cpp 2                    subscribe test/topic-b and test/topic-c
//   ./node-cpp 3 [period_us] [size] TLD load generator on test/bench
//   ./node-cpp 4 [report_ms]        TLD benchmark subscriber on test/bench
//
// The node API is used through its C interface -- the C++ wrapper covers the TLD codec,
// which is where the RAII and range-based iteration earn their keep, and that is what
// roles 3 and 4 use. Topics and rates match the Zig nodes, so any mix interoperates.

#include <qnnt.h>
#include <qnnt_tld.hpp>

#include <array>
#include <atomic>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace tld = qnnt::tld;

namespace {

constexpr std::string_view TOPIC_A = "test/topic-a";
constexpr std::string_view TOPIC_B = "test/topic-b";
constexpr std::string_view TOPIC_C = "test/topic-c";
constexpr std::string_view TOPIC_BENCH = "test/bench";

bool check(qnnt_status status, const char* what) {
    if (status == QNNT_OK) return true;
    std::fprintf(stderr, "%s failed: %s\n", what, qnnt_status_name(status));
    return false;
}

void idleUntilStopped() {
    while (!qnnt_stop_requested()) qnnt_sleep_ms(1000);
}

/// Sources return storage that outlives the call, so a literal is exactly right.
template <const std::string_view& Text>
const std::uint8_t* literalSource(const char*, std::size_t, std::size_t* len, void*) {
    *len = Text.size();
    return reinterpret_cast<const std::uint8_t*>(Text.data());
}

constexpr std::string_view CIAO = "ciao!\n";
constexpr std::string_view OAIC = "!oaic\n";
constexpr std::string_view HOLA = "hola!\n";

// --- role 0 -------------------------------------------------------------------

int role0() {
    if (!check(qnnt_publisher_start(TOPIC_A.data(), TOPIC_A.size(), literalSource<CIAO>, 10'000,
                                    nullptr), "publisher topic-a")) return 1;
    if (!check(qnnt_publisher_start(TOPIC_B.data(), TOPIC_B.size(), literalSource<OAIC>, 50'000,
                                    nullptr), "publisher topic-b")) return 1;
    std::printf("node-cpp 0: publishing %.*s @100Hz, %.*s @20Hz\n",
                (int)TOPIC_A.size(), TOPIC_A.data(), (int)TOPIC_B.size(), TOPIC_B.data());
    idleUntilStopped();
    return 0;
}

// --- role 1 -------------------------------------------------------------------

/// Per-subscription state, reached only through the user pointer.
struct Feed {
    std::string label;
    std::uint64_t prev_us = 0;
    std::uint64_t count = 0;
};

void onFeed(const char* topic, std::size_t topic_len, const std::uint8_t* data, std::size_t len,
            void* user) {
    auto* feed = static_cast<Feed*>(user);
    const auto us = static_cast<std::uint64_t>(qnnt_now_micros());
    const auto delta = feed->prev_us ? us - feed->prev_us : 0;
    feed->prev_us = us;
    feed->count++;
    std::printf("[%" PRIu64 ".%03" PRIu64 "] (+%" PRIu64 "us) node-cpp 2 feed %s #%" PRIu64
                " on %.*s: %.*s",
                us / 1000, us % 1000, delta, feed->label.c_str(), feed->count,
                (int)topic_len, topic, (int)len, reinterpret_cast<const char*>(data));
}

/// Role 1 prints in the same shape as the Zig node-1, so their output can be diffed.
void onTopicA(const char* topic, std::size_t topic_len, const std::uint8_t* data,
              std::size_t len, void* user) {
    auto* prev_us = static_cast<std::uint64_t*>(user);
    const auto us = static_cast<std::uint64_t>(qnnt_now_micros());
    const auto delta = *prev_us ? us - *prev_us : 0;
    *prev_us = us;
    std::printf("[%" PRIu64 ".%03" PRIu64 "] (+%" PRIu64 "us) node-cpp 1 received on %.*s: %.*s",
                us / 1000, us % 1000, delta, (int)topic_len, topic, (int)len,
                reinterpret_cast<const char*>(data));
}

int role1() {
    static std::uint64_t prev_a_us = 0;
    if (!check(qnnt_publisher_start(TOPIC_C.data(), TOPIC_C.size(), literalSource<HOLA>, 1'000,
                                    nullptr), "publisher topic-c")) return 1;
    if (!check(qnnt_subscribe(TOPIC_A.data(), TOPIC_A.size(), onTopicA, &prev_a_us),
               "subscribe topic-a")) return 1;
    std::printf("node-cpp 1: publishing %.*s @1kHz, subscribed to %.*s\n",
                (int)TOPIC_C.size(), TOPIC_C.data(), (int)TOPIC_A.size(), TOPIC_A.data());
    idleUntilStopped();
    return 0;
}

// --- role 2 -------------------------------------------------------------------

int role2() {
    static Feed feed_b{.label = "b"};
    static Feed feed_c{.label = "c"};
    if (!check(qnnt_subscribe(TOPIC_B.data(), TOPIC_B.size(), onFeed, &feed_b),
               "subscribe topic-b")) return 1;
    if (!check(qnnt_subscribe(TOPIC_C.data(), TOPIC_C.size(), onFeed, &feed_c),
               "subscribe topic-c")) return 1;
    std::printf("node-cpp 2: subscribed to %.*s and %.*s\n",
                (int)TOPIC_B.size(), TOPIC_B.data(), (int)TOPIC_C.size(), TOPIC_C.data());
    idleUntilStopped();
    return 0;
}

// --- role 3 -------------------------------------------------------------------

struct Generator {
    tld::Encoder encoder;
    std::vector<std::uint8_t> payload;
    std::uint64_t seq = 0;
    std::atomic<std::uint64_t> sent{0};
    std::atomic<std::uint64_t> bytes{0};
};

Generator* g_generator = nullptr;

const std::uint8_t* benchSource(const char*, std::size_t, std::size_t* len, void*) {
    auto& gen = *g_generator;
    gen.encoder.reset();
    try {
        auto obj = gen.encoder.beginObject();
        gen.encoder.key("seq");
        gen.encoder.writeUint(++gen.seq);
        gen.encoder.key("t");
        gen.encoder.writeUint(static_cast<std::uint64_t>(qnnt_now_micros()));
        gen.encoder.key("data");
        gen.encoder.writeBuffer(gen.payload);
        obj.close();
    } catch (const tld::Error&) {
        return nullptr;
    }

    const auto bytes = gen.encoder.bytes();
    *len = bytes.size();
    gen.sent.fetch_add(1, std::memory_order_relaxed);
    gen.bytes.fetch_add(bytes.size(), std::memory_order_relaxed);
    return bytes.data();
}

int role3(std::uint64_t period_us, std::size_t payload_bytes) {
    static Generator gen;
    g_generator = &gen;

    gen.payload.resize(payload_bytes);
    // Cycles every byte value, so 0x0A and 0xFF are present on purpose.
    for (std::size_t i = 0; i < payload_bytes; i++) gen.payload[i] = static_cast<std::uint8_t>(i);

    std::size_t frame_len = 0;
    (void)benchSource(nullptr, 0, &frame_len, nullptr);
    gen.sent.store(0);
    gen.bytes.store(0);
    gen.seq = 0;

    if (period_us == 0) {
        std::printf("node-cpp 3: %zuB payload, %zuB frames, unpaced\n", payload_bytes, frame_len);
    } else {
        std::printf("node-cpp 3: %zuB payload, %zuB frames, %" PRIu64 "us period (%.1f Hz)\n",
                    payload_bytes, frame_len, period_us, 1e6 / static_cast<double>(period_us));
    }

    if (!check(qnnt_publisher_start(TOPIC_BENCH.data(), TOPIC_BENCH.size(), benchSource,
                                    period_us, nullptr), "publisher bench")) return 1;

    std::uint64_t last = 0, last_bytes = 0;
    auto last_us = qnnt_now_micros();
    while (!qnnt_stop_requested()) {
        qnnt_sleep_ms(1000);
        const auto now = qnnt_now_micros();
        const auto sent = gen.sent.load(std::memory_order_relaxed);
        const auto bytes = gen.bytes.load(std::memory_order_relaxed);
        const double secs = static_cast<double>(now - last_us) / 1e6;
        std::printf("node-cpp 3 sent %.0f frames/s (%.1f KB/s), %" PRIu64 " total\n",
                    static_cast<double>(sent - last) / secs,
                    static_cast<double>(bytes - last_bytes) / secs / 1024.0, sent);
        last = sent;
        last_bytes = bytes;
        last_us = now;
    }
    return 0;
}

// --- role 4 -------------------------------------------------------------------

constexpr std::size_t BUCKET_US = 4;
constexpr std::size_t BUCKETS = 4096;

struct Stats {
    std::uint64_t frames = 0, wire_bytes = 0, lat_sum = 0, lat_max = 0;
    std::uint64_t lat_min = UINT64_MAX;
    std::array<std::uint64_t, BUCKETS> hist{};
    std::uint64_t overflow = 0;
    std::uint64_t total = 0, gaps = 0, bad_payload = 0, errors = 0, expected_seq = 0;
    std::uint64_t window_start_us = 0, report_us = 1'000'000;

    [[nodiscard]] std::uint64_t percentile(double p) const {
        std::uint64_t count = overflow;
        for (const auto n : hist) count += n;
        if (count == 0) return 0;
        const auto target = static_cast<std::uint64_t>(static_cast<double>(count) * p);
        std::uint64_t seen = 0;
        for (std::size_t i = 0; i < BUCKETS; i++) {
            seen += hist[i];
            if (seen >= target) return (i + 1) * BUCKET_US;
        }
        return BUCKETS * BUCKET_US;
    }

    void report(std::uint64_t now_us) {
        const double secs = static_cast<double>(now_us - window_start_us) / 1e6;
        if (secs <= 0) return;
        std::printf("node-cpp 4 %.0f frames/s | wire %.1f KB/s | lat us min %" PRIu64
                    " mean %.0f p50 %" PRIu64 " p99 %" PRIu64 " max %" PRIu64
                    " | gaps %" PRIu64 " badpay %" PRIu64 " err %" PRIu64 " | %" PRIu64 " total\n",
                    static_cast<double>(frames) / secs,
                    static_cast<double>(wire_bytes) / secs / 1024.0,
                    frames ? lat_min : 0,
                    frames ? static_cast<double>(lat_sum) / static_cast<double>(frames) : 0.0,
                    percentile(0.50), percentile(0.99), lat_max,
                    gaps, bad_payload, errors, total);

        frames = wire_bytes = lat_sum = lat_max = 0;
        lat_min = UINT64_MAX;
        hist.fill(0);
        overflow = 0;
        window_start_us = now_us;
    }
};

Stats g_stats;

void onBenchFrame(const char*, std::size_t, const qnnt_tld_frame* raw, void*) {
    auto& st = g_stats;
    const tld::Frame frame{*raw};

    std::uint64_t sent_us = 0, seq = 0;
    try {
        for (auto field : frame.object()) {
            if (field.key == "seq") {
                seq = field.value.asUint();
            } else if (field.key == "t") {
                sent_us = field.value.asUint();
            } else if (field.key == "data") {
                const auto data = field.value.asBuffer();
                for (std::size_t i = 0; i < data.size(); i++) {
                    if (data[i] != static_cast<std::uint8_t>(i)) {
                        st.bad_payload++;
                        break;
                    }
                }
            }
        }
    } catch (const tld::Error&) {
        st.errors++;
        return;
    }

    if (st.expected_seq != 0 && seq > st.expected_seq) st.gaps += seq - st.expected_seq;
    st.expected_seq = seq + 1;

    const auto now_us = static_cast<std::uint64_t>(qnnt_now_micros());
    const auto latency = now_us > sent_us ? now_us - sent_us : 0;

    st.total++;
    st.frames++;
    st.wire_bytes += frame.size();
    st.lat_sum += latency;
    st.lat_min = std::min(st.lat_min, latency);
    st.lat_max = std::max(st.lat_max, latency);
    const auto bucket = latency / BUCKET_US;
    if (bucket < BUCKETS) st.hist[bucket]++; else st.overflow++;

    if (st.window_start_us == 0) st.window_start_us = now_us;
    if (now_us - st.window_start_us >= st.report_us) st.report(now_us);
}

int role4(std::uint64_t report_ms) {
    g_stats.report_us = report_ms * 1000;
    if (!check(qnnt_subscribe_frames(TOPIC_BENCH.data(), TOPIC_BENCH.size(), onBenchFrame,
                                     nullptr), "subscribe bench")) return 1;
    std::printf("node-cpp 4: benchmarking %.*s, reporting every %" PRIu64 "ms\n",
                (int)TOPIC_BENCH.size(), TOPIC_BENCH.data(), report_ms);
    idleUntilStopped();
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    // Line-buffered even when redirected: otherwise stdout is block-buffered to a file and
    // a demo that prints a banner then loops forever appears to produce nothing at all.
    std::setvbuf(stdout, nullptr, _IOLBF, 0);

    const int role = argc > 1 ? std::atoi(argv[1]) : 0;

    // Federation, same environment contract as nodes.c.
    if (const char* fed = std::getenv("QNNT_FEDERATION_PORT")) {
        if (!check(qnnt_set_federation_port(static_cast<std::uint16_t>(std::strtoul(fed, nullptr, 10))),
                   "set_federation_port")) return 1;
    }
    if (const char* key = std::getenv("QNNT_CLUSTER_KEY")) {
        if (!check(qnnt_set_cluster_key(key), "set_cluster_key")) return 1;
    }
    if (const char* peers = std::getenv("QNNT_PEERS")) {
        std::string list{peers};
        std::size_t pos = 0;
        while (pos <= list.size()) {
            const auto comma = list.find(',', pos);
            auto spec = list.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
            if (!spec.empty()) {
                std::uint16_t pport = 0;
                if (const auto colon = spec.rfind(':'); colon != std::string::npos) {
                    pport = static_cast<std::uint16_t>(std::strtoul(spec.c_str() + colon + 1, nullptr, 10));
                    spec.resize(colon);
                }
                if (!check(qnnt_add_peer(spec.c_str(), pport), "add_peer")) return 1;
            }
            if (comma == std::string::npos) break;
            pos = comma + 1;
        }
    }
    if (const char* adv = std::getenv("QNNT_ADVERTISE_ADDR")) {
        if (!check(qnnt_set_advertise_address(adv), "set_advertise_address")) return 1;
    }
    if (const char* bind = std::getenv("QNNT_BIND_ADDR")) {
        if (!check(qnnt_set_bind_address(bind), "set_bind_address")) return 1;
    }

    // The library reads no environment of its own, so an example wanting the port from
    // one reads it and passes it. Matches nodes.c and python/nodes.py.
    if (const char* port_env = std::getenv("QNNT_REGISTRY_PORT")) {
        const auto port = static_cast<std::uint16_t>(std::strtoul(port_env, nullptr, 10));
        if (!check(qnnt_set_registry_port(port), "set_registry_port")) return 1;
    }

    if (!check(qnnt_init(), "qnnt_init")) return 1;
    std::printf("node-cpp %d: registry port %u\n", role, qnnt_registry_port());
    qnnt_install_signal_handlers();

    int rc;
    switch (role) {
    case 0: rc = role0(); break;
    case 1: rc = role1(); break;
    case 2: rc = role2(); break;
    case 3: rc = role3(argc > 2 ? std::strtoull(argv[2], nullptr, 10) : 1000,
                       argc > 3 ? std::strtoull(argv[3], nullptr, 10) : 64); break;
    case 4: rc = role4(argc > 2 ? std::strtoull(argv[2], nullptr, 10) : 1000); break;
    default:
        std::fprintf(stderr, "usage: %s <0..4> [args]\n", argv[0]);
        rc = 2;
    }

    qnnt_deinit();
    return rc;
}
