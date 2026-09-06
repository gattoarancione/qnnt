// What travels on the gateway's topics, as the station reads it -- and the parts of the
// station that are not Qt.
//
// The counterpart of examples/can/frame.zig, and the two must agree FIELD BY FIELD. Neither
// side errors when they do not: TLD ignores a key the receiving struct does not declare,
// and the macros below leave a member the frame did not carry exactly as its constructor
// left it. A renamed field is a frame that arrives with identifier 0 and no payload, drawn
// on screen as a real one. examples/cpp_logic_test.cpp pins the agreement to
// testdata/can_frame.tld, packed by the Zig side.
//
// Everything below the struct is here rather than in station.cpp for the same reason the
// LiDAR and camera viewers were criticised for NOT doing it: a function that needs a
// QGuiApplication to reach is a function with no tests. Topic parsing, formatting and the
// rate estimate are ordinary C++ and are tested as such.

#ifndef QNNT_CAN_FRAMES_HPP
#define QNNT_CAN_FRAMES_HPP

#include "qnnt_tld.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace can {

/// Mirrors Frame in examples/can/frame.zig. The identifier is already masked and the Linux
/// flag bits are named fields: what is on the wire is a CAN frame, not a `struct can_frame`.
struct Frame {
    std::uint32_t id{};
    bool ext{};
    bool rtr{};
    bool err{};
    /// CAN FD rather than classic CAN. NOT derivable from the length: eight bytes or fewer
    /// is legal in both formats, and the two are different frames to a controller.
    bool fd{};
    /// Bit rate switch, and the transmitter's error state. Both belong to the FD data phase
    /// and mean nothing on a classic frame.
    bool brs{};
    bool esi{};
    /// The payload LENGTH in bytes. 0-8 for classic CAN; for CAN FD one of `fd_lengths`.
    std::uint8_t dlc{};
    std::vector<std::uint8_t> data;
    std::int64_t us{};
    TLD_DEFINE_MAP(id, ext, rtr, err, fd, brs, esi, dlc, data, us)
};

/// The payload lengths CAN FD can express. Mirrors fd_lengths in examples/can/frame.zig:
/// there is nothing between 8 and 12, or 24 and 32.
inline constexpr std::uint8_t fd_lengths[] = {0, 1, 2, 3, 4, 5, 6, 7, 8,
                                              12, 16, 20, 24, 32, 48, 64};

[[nodiscard]] inline bool validFdLength(std::uint8_t len)
{
    return std::find(std::begin(fd_lengths), std::end(fd_lengths), len) != std::end(fd_lengths);
}

/// `can/<bus>/<gateway>` split into its two names. Empty `bus` means the topic is not one
/// of ours -- the station subscribes to a glob, and a glob can match more than intended if
/// somebody publishes a `can/...` topic that is not a gateway's.
struct Origin {
    std::string bus;
    std::string gateway;

    [[nodiscard]] bool valid() const { return !bus.empty() && !gateway.empty(); }
};

/// Mirrors nodeOf() in frame.zig, and rejects the same shapes: a missing segment, an empty
/// one, or an extra one. Three segments exactly, because a bus or gateway name containing a
/// '/' would make `can/a/b/c` ambiguous, and frame.zig's validName refuses those at the
/// source.
[[nodiscard]] inline Origin parseTopic(const std::string& topic)
{
    constexpr std::string_view prefix = "can/";
    if (topic.rfind(prefix, 0) != 0) return {};

    const auto rest = topic.substr(prefix.size());
    const auto slash = rest.find('/');
    if (slash == std::string::npos) return {};

    Origin o{rest.substr(0, slash), rest.substr(slash + 1)};
    if (o.gateway.find('/') != std::string::npos) return {};
    if (o.bus.empty() || o.gateway.empty()) return {};
    return o;
}

/// "0x123" for a standard identifier, "0x1ABCDEF" for an extended one. Width follows the
/// kind rather than the value: a standard id is three hex digits and an extended one eight,
/// so the two are distinguishable at a glance even when the numbers coincide.
[[nodiscard]] inline std::string formatId(std::uint32_t id, bool ext)
{
    char buf[16];
    std::snprintf(buf, sizeof buf, ext ? "0x%08X" : "0x%03X", id);
    return buf;
}

/// "A1 0A 0D" -- the form every CAN tool prints, so it can be compared with candump output
/// by eye.
[[nodiscard]] inline std::string formatData(const std::vector<std::uint8_t>& data)
{
    std::string out;
    out.reserve(data.size() * 3);
    for (std::size_t i = 0; i < data.size(); ++i) {
        char buf[4];
        std::snprintf(buf, sizeof buf, i ? " %02X" : "%02X", data[i]);
        out += buf;
    }
    return out;
}

/// "E" extended, "R" remote, "F" CAN FD, "B" bit rate switch, "P" error-passive
/// transmitter, "!" error frame -- nothing at all for an ordinary classic data frame,
/// which is most of them.
///
/// F is not decoration. A reader has to be able to tell an 8-byte FD frame from an 8-byte
/// classic one, and nothing else on the row says which it is.
[[nodiscard]] inline std::string formatFlags(const Frame& f)
{
    std::string out;
    if (f.ext) out += 'E';
    if (f.rtr) out += 'R';
    if (f.fd) out += 'F';
    if (f.brs) out += 'B';
    if (f.esi) out += 'P';
    if (f.err) out += '!';
    return out;
}

/// "A1 0A 0D" or "a1 0a0d" or "A1,0A,0D" -> bytes. False when it is not hex, or longer
/// than a CAN FD frame can carry. Whether that LENGTH is one CAN FD can express is a
/// separate question, asked by validFdLength; this one is about the text.
///
/// Separators are ignored rather than required, because the text being pasted in comes from
/// a candump line, a datasheet or a colleague's message, and each punctuates differently.
/// An odd number of digits is refused rather than padded: "12 3" is a typo, and guessing
/// whether it meant 0x03 or 0x30 puts a frame the operator did not write onto a real bus.
[[nodiscard]] inline bool parseHex(const std::string& text, std::vector<std::uint8_t>& out)
{
    out.clear();
    int hi = -1;
    for (const char c : text) {
        if (c == ' ' || c == ',' || c == ':' || c == '\t' || c == '_') continue;
        int v;
        if (c >= '0' && c <= '9') v = c - '0';
        else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
        else return false;

        if (hi < 0) { hi = v; continue; }
        out.push_back(static_cast<std::uint8_t>((hi << 4) | v));
        hi = -1;
        if (out.size() > 64) return false;
    }
    return hi < 0;  // a trailing half-byte is a typo, not a value
}

/// Frames per second over a sliding window.
///
/// A count-since-start average is useless on a bus: it cannot fall, so a gateway that died
/// two minutes ago still reports the rate it had while alive. A window can fall to zero,
/// which is the thing worth seeing.
class Rate {
public:
    /// `now_ms` is monotonic. Called once per frame. The window is rolled BEFORE the frame
    /// is counted, so a frame never lands in a window that is about to be discarded.
    void tick(std::int64_t now_ms)
    {
        ++count_;
        last_ms_ = now_ms;
        roll(now_ms);
        ++window_count_;
    }

    /// Frames per second over the last window, evaluated at `now_ms` so it decays while
    /// nothing arrives instead of freezing at its last value.
    ///
    /// Const, and therefore does NOT roll the window: only a frame rolls it. Reading a rate
    /// is something the view does many times a second, and a reader that mutated would make
    /// the answer depend on how often it was asked.
    [[nodiscard]] double perSecond(std::int64_t now_ms) const
    {
        if (window_start_ms_ == 0) return 0.0;
        const auto span = now_ms - window_start_ms_;
        if (span <= 0) return 0.0;
        // Two windows with nothing to roll it means nothing has arrived for that long, and
        // the honest answer is zero rather than an ever-shrinking fraction of old news.
        if (span > window_ms * 2) return 0.0;
        return static_cast<double>(window_count_) * 1000.0 / static_cast<double>(span);
    }

    [[nodiscard]] std::uint64_t total() const { return count_; }
    [[nodiscard]] std::int64_t lastMs() const { return last_ms_; }

    /// Nothing for longer than `after_ms`. What "gone" looks like on a bus where a quiet
    /// node and a dead node are the same thing until you put a clock on it.
    [[nodiscard]] bool stale(std::int64_t now_ms, std::int64_t after_ms) const
    {
        return last_ms_ != 0 && now_ms - last_ms_ > after_ms;
    }

private:
    static constexpr std::int64_t window_ms = 2000;

    void roll(std::int64_t now_ms)
    {
        if (window_start_ms_ == 0) { window_start_ms_ = now_ms; return; }
        if (now_ms - window_start_ms_ < window_ms) return;
        // The whole window is discarded at once rather than carried forward. Smoothing
        // would turn a rate that has just dropped to zero into a slow decay, and that
        // transition -- a gateway going away -- is the one worth seeing sharply.
        window_start_ms_ = now_ms;
        window_count_ = 0;
    }

    std::uint64_t count_{};
    std::int64_t last_ms_{};
    std::int64_t window_start_ms_{};
    std::uint64_t window_count_{};
};

/// One CAN identifier seen on one bus: what a CAN tool shows, rather than a scrolling log.
///
/// A bus carries the same few identifiers over and over -- engine speed at 100 Hz, a door
/// switch when somebody opens a door -- so a scroll shows only the fastest of them and a
/// per-identifier table shows the bus.
struct IdRow {
    std::uint32_t id{};
    bool ext{};
    /// Part of the row's KEY, not just something to display: the same identifier sent as
    /// classic and as FD is two conversations, exactly as standard and extended are.
    bool fd{};
    bool rtr{};
    bool err{};
    bool brs{};
    bool esi{};
    std::string gateway;   // the last gateway to publish it
    std::vector<std::uint8_t> data;
    std::uint8_t dlc{};
    Rate rate;
};

/// Where a row for `f` belongs in `rows`, inserting one if this identifier is new.
///
/// Keyed on the identifier AND on `ext`, because 0x123 standard and 0x123 extended are
/// different frames to every controller on the bus, and merging them would show one
/// conversation as two interleaved ones.
[[nodiscard]] inline std::size_t rowFor(std::vector<IdRow>& rows, const Frame& f)
{
    const auto it = std::find_if(rows.begin(), rows.end(), [&](const IdRow& r) {
        return r.id == f.id && r.ext == f.ext && r.fd == f.fd;
    });
    if (it != rows.end()) return static_cast<std::size_t>(it - rows.begin());

    IdRow row;
    row.id = f.id;
    row.ext = f.ext;
    row.fd = f.fd;
    rows.push_back(row);
    return rows.size() - 1;
}

}  // namespace can

#endif  // QNNT_CAN_FRAMES_HPP
