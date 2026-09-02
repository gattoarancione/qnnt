// The C++ node of the five-language mesh. See SCHEMA.txt.
//
//   zig build mesh && bash examples/mesh/run.sh
//
// Publishes mesh/cpp and subscribes to the other four topics. Uses the C ABI directly for
// the node and the TLD_DEFINE_MAP macros for the schema; the Qt node next door does the
// same thing through the QObject wrapper, with Qt types in the struct.

#include "qnnt.h"
#include "qnnt_tld.hpp"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr const char* kMe = "cpp";
constexpr const char* kMyTopic = "mesh/cpp";

struct PeerInfo {
    const char* name;
    const char* topic;
};
constexpr PeerInfo kPeers[] = {
    {"zig", "mesh/zig"},
    {"c", "mesh/c"},
    {"python", "mesh/python"},
    {"qt", "mesh/qt"},
};

enum class Mode : std::int32_t { idle = 0, running = 1, faulted = 2 };
TLD_ADD_ENUM(Mode)

struct Reading {
    std::uint8_t channel{};
    double value{};
    bool valid{};
    TLD_DEFINE_MAP(channel, value, valid)
};

struct Origin {
    double x{};
    double y{};
    TLD_DEFINE_MAP(x, y)
};

struct Sample {
    std::uint64_t seq{};
    std::string source;
    Mode mode{Mode::idle};
    std::int32_t count{};
    float temp{};
    std::vector<std::uint8_t> blob;
    Origin origin;
    std::vector<Reading> readings;
    TLD_DEFINE_MAP(seq, source, mode, count, temp, blob, origin, readings)
};

Sample expected(std::uint64_t seq, const char* source) {
    Sample s;
    s.seq = seq;
    s.source = source;
    s.mode = static_cast<Mode>(seq % 3);
    s.count = -static_cast<std::int32_t>(seq);
    s.temp = 36.5f;
    s.blob = {0x00, 0xFF, 0x0A};
    s.origin = Origin{1.5, -2.5};
    s.readings.reserve(3);
    for (std::uint8_t i = 0; i < 3; ++i) {
        s.readings.push_back(Reading{static_cast<std::uint8_t>(i + 1),
                                     static_cast<double>(seq * 10 + i), i != 1});
    }
    return s;
}

/// run.sh sets MESH_PEERS to the languages it actually started, so the mesh works with any
/// subset: build without -Dqt and the other nodes stop waiting for a Qt peer.
bool peerPresent(const char* name) {
    const char* list = std::getenv("MESH_PEERS");
    if (list == nullptr || *list == '\0') return true;
    const std::string wanted{list};
    std::size_t start = 0;
    while (start <= wanted.size()) {
        const std::size_t comma = wanted.find(',', start);
        std::string piece = wanted.substr(start, comma == std::string::npos
                                                     ? std::string::npos
                                                     : comma - start);
        while (!piece.empty() && piece.front() == ' ') piece.erase(piece.begin());
        while (!piece.empty() && piece.back() == ' ') piece.pop_back();
        if (piece == name) return true;
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
    return false;
}

struct PeerState {
    const char* name;
    bool expected = true;
    std::atomic<std::uint64_t> received{0};
    std::atomic<std::uint64_t> first_seq{0};
    std::atomic<std::uint64_t> last_seq{0};
    std::atomic<std::uint64_t> problems{0};
};

PeerState g_peers[std::size(kPeers)];

/// Called on the subscriber's own thread, one per topic, so each slot has a single writer.
void onFrame(const char*, std::size_t, const qnnt_tld_frame* raw, void* user) {
    auto* peer = static_cast<PeerState*>(user);
    bool bad = false;
    std::uint64_t seq = 0;

    try {
        const Sample got = qnnt::tld::unpack<Sample>(qnnt::tld::Frame{*raw});
        seq = got.seq;
        const Sample want = expected(seq, peer->name);

        if (got.source != want.source || got.mode != want.mode || got.count != want.count) bad = true;
        // temp crosses as a 32-bit float, so compare with a tolerance; the f64 fields are
        // compared exactly because they survive exactly.
        if (std::fabs(got.temp - want.temp) > 1e-6f) bad = true;
        if (got.blob != want.blob) bad = true;
        if (got.origin.x != want.origin.x || got.origin.y != want.origin.y) bad = true;
        if (got.readings.size() != want.readings.size()) {
            bad = true;
        } else {
            for (std::size_t i = 0; i < got.readings.size(); ++i) {
                if (got.readings[i].channel != want.readings[i].channel) bad = true;
                if (got.readings[i].value != want.readings[i].value) bad = true;
                if (got.readings[i].valid != want.readings[i].valid) bad = true;
            }
        }
    } catch (const qnnt::tld::Error&) {
        bad = true;
    }

    const std::uint64_t previous = peer->last_seq.exchange(seq);
    // A gap inside the run means loss; attaching late just sets the baseline.
    if (previous != 0 && seq != previous + 1) bad = true;
    if (previous == 0) peer->first_seq.store(seq);

    peer->received.fetch_add(1);
    if (bad) peer->problems.fetch_add(1);
}

std::vector<std::uint8_t> g_out;
std::uint64_t g_seq = 0;

/// The scheduler starts ticking when qnnt_publisher_start is called, which is before the
/// roster has connected -- so the gate lives here rather than in main. Returning nullptr
/// skips a tick without consuming a sequence number, which is what keeps seq 1 the first
/// sample anybody sees.
std::atomic<bool> g_gate_open{false};

const std::uint8_t* sourceFn(const char*, std::size_t, std::size_t* out_len, void*) {
    if (!g_gate_open.load()) {
        *out_len = 0;
        return nullptr;
    }
    ++g_seq;
    g_out = qnnt::tld::pack(expected(g_seq, kMe));
    *out_len = g_out.size();
    return g_out.data();
}

} // namespace

int main(int argc, char** argv) {
    const long run_ms = argc > 1 ? std::strtol(argv[1], nullptr, 10) : 9000;
    const unsigned long need = argc > 2 ? std::strtoul(argv[2], nullptr, 10) : 5;

    qnnt_configure_from_environment();
    if (qnnt_init() != QNNT_OK) {
        std::printf("%s: failed to start\n", kMe);
        return 1;
    }
    qnnt_install_signal_handlers();

    if (qnnt_publisher_start(kMyTopic, std::strlen(kMyTopic), &sourceFn, 200000, nullptr) !=
        QNNT_OK) {
        std::printf("%s: failed to publish %s\n", kMe, kMyTopic);
        return 1;
    }

    std::size_t expecting = 0;
    for (std::size_t i = 0; i < std::size(kPeers); ++i) {
        g_peers[i].name = kPeers[i].name;
        g_peers[i].expected = peerPresent(kPeers[i].name);
        if (!g_peers[i].expected) continue;
        ++expecting;
        if (qnnt_subscribe_frames(kPeers[i].topic, std::strlen(kPeers[i].topic), &onFrame,
                                  &g_peers[i]) != QNNT_OK) {
            std::printf("%s: failed to subscribe %s\n", kMe, kPeers[i].topic);
            return 1;
        }
    }

    std::printf("%s: publishing %s, subscribed to %zu peers\n", kMe, kMyTopic, expecting);
    std::fflush(stdout);

    // All of them, not just the first: this node knows how many peers the roster says are
    // coming, and waiting for the last one means every peer sees seq 1.
    if (qnnt_wait_for_subscribers(kMyTopic, std::strlen(kMyTopic), expecting, 5000)) {
        std::printf("%s: all %zu subscribers on %s, publishing\n", kMe, expecting, kMyTopic);
    } else {
        std::printf("%s: only %zu of %zu subscribers after 5s, publishing anyway\n", kMe,
                    qnnt_subscriber_count(kMyTopic, std::strlen(kMyTopic)), expecting);
    }
    g_gate_open.store(true);
    std::fflush(stdout);

    const std::int64_t deadline = qnnt_now_micros() + run_ms * 1000;
    while (!qnnt_stop_requested() && qnnt_now_micros() < deadline) qnnt_sleep_ms(200);

    bool failed = false;
    for (auto& peer : g_peers) {
        if (!peer.expected) continue;
        const auto got = peer.received.load();
        const auto bad = peer.problems.load();
        const bool ok = got >= need && bad == 0;
        failed = failed || !ok;
        std::printf("%s: from %-7s %3llu samples, seq %llu..%llu, %llu problem(s) %s\n", kMe,
                    peer.name, (unsigned long long)got,
                    (unsigned long long)peer.first_seq.load(),
                    (unsigned long long)peer.last_seq.load(), (unsigned long long)bad,
                    ok ? "ok" : "FAILED");
    }

    std::printf("%s: %s\n", kMe, failed ? "FAILED" : "all peers verified");
    std::fflush(stdout);
    qnnt_deinit();
    return failed ? 1 : 0;
}
