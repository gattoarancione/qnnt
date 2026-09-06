// The C++ logic the viewers depend on, tested without Qt.
//
// Run by `zig build test`: it needs no Qt, no hub and no robot, because everything it
// checks was deliberately kept free of them. That matters -- the Qt executables are built
// only when -Dqt= is passed, so anything testable only through them would in practice never
// be tested at all, which is how this side of the repository ended up with no coverage.
//
// What it does NOT cover is stated plainly rather than implied: the Qt classes themselves,
// the QML bindings, and the frame decode in the LiDAR and camera viewers. Those still have
// none.

#include "../examples/ugv/steering.hpp"
#include "../examples/dirigera/devices.hpp"
#include "../examples/dirigera/frames.hpp"
#include "../examples/can/frames.hpp"

#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

namespace {

int failures = 0;
int checks = 0;

void check(bool ok, const char* what)
{
    ++checks;
    if (!ok) {
        ++failures;
        std::printf("  FAIL  %s\n", what);
    }
}

void near(double got, double want, const char* what)
{
    ++checks;
    if (std::abs(got - want) > 1e-9) {
        ++failures;
        std::printf("  FAIL  %s: got %.6f, wanted %.6f\n", what, got, want);
    }
}

// -- differential steering ------------------------------------------------------------

void steering()
{
    using namespace ugv;

    // Straight ahead: both tracks together, no turn component at all.
    const Tracks ahead = mix(1.0, 0.0, 1.0);
    near(ahead.left, 1.0, "forward drives the left track");
    near(ahead.right, 1.0, "forward drives the right track");
    near(driveAxis(ahead), 1.0, "forward reads as full drive");
    near(steerAxis(ahead), 0.0, "forward reads as no steer");

    // THE sign convention, and the one that was wrong on screen: a right turn drives the
    // left track forward and the right track back, so steerAxis must be POSITIVE.
    const Tracks right = mix(0.0, 1.0, 1.0);
    near(right.left, 1.0, "a right turn drives the left track forward");
    near(right.right, -1.0, "a right turn drives the right track back");
    near(steerAxis(right), 1.0, "a right turn reads as positive steer");
    near(driveAxis(right), 0.0, "a turn in place is no net drive");

    const Tracks left = mix(0.0, -1.0, 1.0);
    near(left.left, -1.0, "a left turn drives the left track back");
    near(steerAxis(left), -1.0, "a left turn reads as negative steer");

    const Tracks back = mix(-1.0, 0.0, 1.0);
    near(driveAxis(back), -1.0, "reverse reads as negative drive");

    // Normalised, not clipped. Asking for full forward plus half a turn wants 1.5 and 0.5;
    // clipping the first to 1.0 would leave the second at 0.5 and quietly straighten the
    // curve. Keeping the RATIO is the whole point, so that is what is asserted.
    const Tracks curve = mix(1.0, 0.5, 1.0);
    check(curve.left <= 1.0 && curve.right <= 1.0, "a normalised curve stays in range");
    near(curve.left / curve.right, 3.0, "normalising keeps the ratio between the tracks");
    check(std::abs(curve.left / curve.right - 2.0) > 1e-9,
          "clipping would have flattened the ratio to 2.0");

    // Throttle scales the pair without changing the shape of the turn.
    const Tracks slow = mix(0.0, 1.0, 0.25);
    near(slow.left, 0.25, "throttle scales the left track");
    near(slow.right, -0.25, "throttle scales the right track");
    near(steerAxis(slow) / steerAxis(right), 0.25, "throttle scales steer proportionally");

    // Stopped is stopped, whatever the throttle.
    const Tracks stopped = mix(0.0, 0.0, 1.0);
    near(stopped.left, 0.0, "no input, no left");
    near(stopped.right, 0.0, "no input, no right");

    // The axes invert the mix exactly when nothing was normalised away.
    const Tracks mixed = mix(0.5, 0.25, 1.0);
    near(driveAxis(mixed), 0.5, "driveAxis recovers the forward input");
    near(steerAxis(mixed), 0.25, "steerAxis recovers the turn input");
}

// -- hub device classification ---------------------------------------------------------

void devices()
{
    using namespace dirigera;

    check(roleFor("light") == Role::Light, "a light is an actuator");
    check(roleFor("outlet") == Role::Light, "an outlet is an actuator");
    check(roleFor("blinds") == Role::Light, "blinds are an actuator");
    check(roleFor("motionSensor") == Role::Presence, "a motion sensor is presence");
    check(roleFor("lightSensor") == Role::Ambient, "a light sensor is a measurement");
    check(roleFor("environmentSensor") == Role::Ambient, "an environment sensor measures");
    check(roleFor("lightController") == Role::Control, "a remote is an input");
    check(roleFor("gateway") == Role::Other, "the hub itself is not operable");

    // An unknown type must not fall into the first branch and appear among the lights,
    // which is what a chain of if-statements does when the last one is not a default.
    check(roleFor("quantumToaster") == Role::Other, "an unknown type is Other, not a light");
    check(roleFor("") == Role::Other, "an empty type is Other");
    check(roleFor("Light") == Role::Other, "the hub's spelling is exact, not case-folded");

    // One physical sensor, one row: a VALLHORN's light-sensor half is folded into its
    // motion twin, because on its own it is a nameless roomless duplicate.
    check(!ownRow(Role::Ambient, true), "a light meter with a motion twin is folded in");
    check(ownRow(Role::Ambient, false), "a light meter on its own keeps its row");
    check(ownRow(Role::Light, false), "lights always get a row");
    check(ownRow(Role::Presence, true), "a motion sensor keeps its row even when paired");
    check(ownRow(Role::Control, false), "remotes get a row");
    check(!ownRow(Role::Other, false), "the gateway is not shown");
}

// -- motion as an event ------------------------------------------------------------------

void motion()
{
    using namespace dirigera;
    const long long second = 1'000'000;
    const long long hold = 30 * second;

    MotionEdge m;
    check(!m.ever, "a fresh sensor has never fired");
    check(!m.recent(0, hold), "and is not recent");

    // A rising edge is the event worth timestamping.
    check(m.update(true, 10 * second), "first detection is a rising edge");
    check(m.ever, "it is remembered");
    check(m.recent(10 * second, hold), "and reads as recent immediately");

    // Staying detected must NOT restart the clock: the hub repeats readings, and a sensor
    // held in front of would otherwise always look like it just fired.
    check(!m.update(true, 20 * second), "a repeated detection is not a new edge");
    check(m.last_us == 10 * second, "and does not move the timestamp");

    // Falling is not an edge either, and the hold keeps the indicator steady across the
    // hub clearing the flag on its own schedule.
    check(!m.update(false, 25 * second), "clearing is not a rising edge");
    check(m.recent(25 * second, hold), "still recent while inside the hold");
    check(m.recent(39 * second, hold), "still recent at the edge of the hold");
    check(!m.recent(41 * second, hold), "no longer recent past the hold");

    // A second trip is a new edge and restarts it.
    check(m.update(true, 50 * second), "a later detection is a fresh edge");
    check(m.last_us == 50 * second, "and moves the timestamp");
    check(m.recent(60 * second, hold), "recent again from the new edge");
}

// -- the language boundary ----------------------------------------------------------------

std::vector<std::uint8_t> readGolden(const char* path)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) return {};
    return { std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>() };
}

/// Do the C++ structs still agree with the Zig ones, field by field?
///
/// This is the check that nothing else makes. A renamed or retyped field is not a compile
/// error on either side and not a runtime error either: TLD ignores a key the receiving
/// struct does not declare, and the TLD_DEFINE_MAP macros leave a member the frame did not
/// carry exactly as its constructor left it. So the failure mode is a station showing
/// plausible defaults -- a light that reports itself uncontrollable, a sensor with no room.
///
/// The bytes were packed by Zig from examples/dirigera/frames.zig's canonical values, and
/// a Zig test asserts they still pack to exactly these bytes. So the two sides are pinned
/// to one artefact, and either drifting fails.
void boundary()
{
    const auto device_bytes = readGolden("examples/dirigera/testdata/device_frame.tld");
    check(!device_bytes.empty(), "the device golden frame is readable");
    if (device_bytes.empty()) return;

    const auto d = qnnt::tld::unpack<dirigera::DeviceFrame>(device_bytes);

    // Every field, because checking a few would let the others drift. The values are all
    // distinct in the canonical frame, so a pair of fields swapped between the languages
    // cannot compare equal anyway.
    check(d.id == "abc123_1", "id crosses");
    check(d.type == "light", "type crosses");
    check(d.name == "Hall light", "name crosses");
    check(d.room == "Room A", "room crosses");
    check(d.model == "TRADFRI bulb E27", "model crosses");
    check(d.reachable, "reachable crosses");
    check(d.is_on.has_value() && *d.is_on, "is_on crosses");
    check(d.light_level.has_value() && *d.light_level == 57, "light_level crosses");
    check(d.color_temperature.has_value() && *d.color_temperature == 2842,
          "color_temperature crosses");
    check(d.battery.has_value() && *d.battery == 91, "battery crosses");
    check(d.is_detected.has_value() && !*d.is_detected, "is_detected crosses as false");
    check(d.illuminance.has_value() && *d.illuminance == 314, "illuminance crosses");
    check(d.controllable, "controllable crosses");
    check(d.can_set_on, "can_set_on crosses");
    check(d.can_set_level, "can_set_level crosses");
    check(d.can_set_temperature, "can_set_temperature crosses");
    check(d.temperature_min.has_value() && *d.temperature_min == 2202,
          "temperature_min crosses");
    check(d.temperature_max.has_value() && *d.temperature_max == 4000,
          "temperature_max crosses");
    check(d.relation == "rel-77", "relation crosses");

    // A present-but-false optional must not read the same as an absent one. Without this,
    // a field the C++ side stopped declaring would look identical to one carrying false,
    // and half the checks above would pass through the bug.
    check(d.is_detected.has_value(), "an optional carrying false is PRESENT, not absent");
    check(d.can_set_on && d.can_set_level && d.can_set_temperature,
          "every plain bool is true, so a dropped one would read false and be caught");

    // The command the station SENDS. A mismatch here is a click that silently does
    // nothing, which is the least visible failure of the three.
    const auto command_bytes = readGolden("examples/dirigera/testdata/light_command.tld");
    check(!command_bytes.empty(), "the command golden frame is readable");
    if (command_bytes.empty()) return;

    const auto c = qnnt::tld::unpack<dirigera::LightCommand>(command_bytes);
    check(c.id == "abc123_1", "command id crosses");
    check(c.on.has_value() && *c.on, "command on crosses");
    check(c.level.has_value() && *c.level == 42, "command level crosses");
    check(c.kelvin.has_value() && *c.kelvin == 2700, "command kelvin crosses");

    // And what C++ packs is what Zig would: the same bytes, so the direction the station
    // actually uses is pinned too, not just the one it reads.
    dirigera::LightCommand mine;
    mine.id = "abc123_1";
    mine.on = true;
    mine.level = 42;
    mine.kelvin = 2700;
    const auto repacked = qnnt::tld::pack(mine);
    check(repacked.size() == command_bytes.size() &&
              std::equal(repacked.begin(), repacked.end(), command_bytes.begin()),
          "C++ packs a command to the same bytes Zig does");
}

/// The CAN station's own logic: what it does to a frame between receiving it and drawing
/// it. None of this needs Qt, and putting it in station.cpp is what would have made it
/// untestable.
void canStation()
{
    std::printf("\nCAN station:\n");

    // -- topics. The station subscribes to `can/*/*`, so it sees whatever matches, and a
    // topic that is not a gateway's must not be drawn as one.
    const auto a = can::parseTopic("can/powertrain/alpha");
    check(a.valid() && a.bus == "powertrain" && a.gateway == "alpha", "a topic splits");
    check(can::parseTopic("can/body/b-2").gateway == "b-2", "a hyphenated gateway splits");
    check(!can::parseTopic("mesh/zig").valid(), "a foreign topic is rejected");
    check(!can::parseTopic("can/powertrain").valid(), "a two-segment topic is rejected");
    check(!can::parseTopic("can/powertrain/").valid(), "an empty gateway is rejected");
    check(!can::parseTopic("can/a/b/c").valid(), "a four-segment topic is rejected");

    // -- formatting. The width says which kind of identifier it is even when the numbers
    // would otherwise look alike.
    check(can::formatId(0x123, false) == "0x123", "a standard id is three digits");
    check(can::formatId(0x123, true) == "0x00000123", "an extended id is eight");
    check(can::formatId(0x1ABCDEF, true) == "0x01ABCDEF", "a large extended id formats");
    check(can::formatData({0xA1, 0x0A, 0x00}) == "A1 0A 00", "a payload formats like candump");
    check(can::formatData({}).empty(), "an empty payload formats to nothing");

    can::Frame flagged;
    flagged.ext = true;
    flagged.err = true;
    check(can::formatFlags(flagged) == "E!", "flags concatenate");
    check(can::formatFlags(can::Frame{}).empty(), "an ordinary frame has no flags");

    // F is what distinguishes an 8-byte FD frame from an 8-byte classic one. Nothing else
    // on the row does, so its absence would make the two indistinguishable on screen.
    can::Frame fd_frame;
    fd_frame.fd = true;
    fd_frame.brs = true;
    check(can::formatFlags(fd_frame) == "FB", "an FD frame says so, with its bitrate switch");
    fd_frame.esi = true;
    check(can::formatFlags(fd_frame) == "FBP", "and an error-passive transmitter");

    // -- the inject box. This one puts frames on a real bus, so what it refuses matters
    // more than what it accepts.
    std::vector<std::uint8_t> bytes;
    check(can::parseHex("A1 0A 0D", bytes) && bytes == std::vector<std::uint8_t>{0xA1, 0x0A, 0x0D},
          "spaced hex parses");
    check(can::parseHex("a10a0d", bytes) && bytes.size() == 3, "unspaced lowercase parses");
    check(can::parseHex("A1,0A:0D", bytes) && bytes.size() == 3, "mixed separators parse");
    check(can::parseHex("", bytes) && bytes.empty(), "empty is a valid empty payload");
    check(!can::parseHex("12 3", bytes), "an odd digit count is refused, not padded");
    check(!can::parseHex("zz", bytes), "non-hex is refused");
    // 64 bytes is the CAN FD limit and the parser's; whether a LENGTH is one FD can
    // express is validFdLength's question, not this one's.
    check(can::parseHex(std::string(128, 'A'), bytes) && bytes.size() == 64,
          "64 bytes parses");
    check(!can::parseHex(std::string(130, 'A'), bytes), "more than 64 bytes is refused");

    // The lengths CAN FD can express. There is nothing between 8 and 12, or 24 and 32:
    // padding a 13-byte payload up to 16 would put three bytes on a bus nobody wrote.
    for (const std::uint8_t n : {0, 1, 8, 12, 16, 20, 24, 32, 48, 64}) {
        check(can::validFdLength(n), "a legal FD length is accepted");
    }
    for (const std::uint8_t n : {9, 10, 11, 13, 17, 25, 33, 49, 63, 65}) {
        check(!can::validFdLength(n), "an illegal FD length is refused");
    }

    // -- the repeat period. This one paces frames onto a real bus, so a value it cannot
    // actually keep is refused rather than rounded into one it can.
    check(can::parsePeriodMs("100") == 100, "a plain period parses");
    check(can::parsePeriodMs(" 20 ") == 20, "surrounding space is ignored");
    check(can::parsePeriodMs("1") == 1, "1 ms is accepted -- a thousand frames a second");
    check(can::parsePeriodMs("60000") == 60000, "and the ceiling");

    // Zero is not a period: Qt reads a zero-interval timer as "whenever idle", which is a
    // busy loop rather than a pace.
    check(can::parsePeriodMs("0") == 0, "zero is refused");
    check(can::parsePeriodMs("60001") == 0, "above the ceiling is refused");
    check(can::parsePeriodMs("") == 0, "empty is refused");
    check(can::parsePeriodMs("10ms") == 0, "a unit suffix is refused rather than guessed");
    check(can::parsePeriodMs("-5") == 0, "a negative is refused");
    check(can::parsePeriodMs("1e3") == 0, "and so is anything not plain digits");

    // -- the rate. The property that matters is that it can FALL: a count-since-start
    // average would report a dead gateway's last healthy rate for ever.
    can::Rate r;
    for (int i = 0; i < 10; ++i) r.tick(1000 + i * 100);  // 10 frames over 900ms
    check(r.total() == 10, "every frame is counted");
    check(r.perSecond(1900) > 5.0, "a live rate is reported");
    check(!r.stale(2000, 5000), "a live source is not stale");

    // Nothing for ten seconds.
    check(r.perSecond(12000) < 1.0, "the rate falls when frames stop");
    check(r.stale(12000, 5000), "silence past the threshold reads as stale");
    check(r.total() == 10, "and the total still says what was seen");

    // -- per-identifier rows, which is what a CAN tool shows instead of a scroll. What
    // makes a row is not the identifier alone.
    can::IdRow row;
    row.id = 0x123;
    can::Frame f;
    f.id = 0x123;
    check(can::sameRow(row, f), "the same identifier lands on the same row");

    // A different frame to every controller on the bus, so folding them into one row would
    // show two conversations interleaved as one.
    f.ext = true;
    check(!can::sameRow(row, f), "an extended id with the same number is a different row");
    f.ext = false;
    f.fd = true;
    check(!can::sameRow(row, f), "the same id sent as CAN FD is a different row");
    f.fd = false;
    f.id = 0x124;
    check(!can::sameRow(row, f), "and so is a different number");

    // Ordering is by identifier, and stable: rate ordering swaps rows under the pointer
    // several times a second, because live rates cross constantly.
    can::IdRow lo, hi;
    lo.id = 0x100;
    hi.id = 0x200;
    check(can::rowPrecedes(lo, hi) && !can::rowPrecedes(hi, lo), "lower identifiers come first");
    hi.id = 0x100;
    hi.ext = true;
    check(can::rowPrecedes(lo, hi), "standard before extended at the same number");
    hi.ext = false;
    hi.fd = true;
    check(can::rowPrecedes(lo, hi), "classic before FD at the same number");
}

/// The CAN wire format across the language boundary, pinned to bytes packed by Zig from
/// examples/can/frame.zig's canonical frame. A field renamed on either side is not an error
/// anywhere: it is a frame drawn on screen with identifier 0 and no payload.
void canBoundary()
{
    const auto bytes = readGolden("examples/can/testdata/can_frame.tld");
    check(!bytes.empty(), "the CAN golden frame is readable");
    if (bytes.empty()) return;

    const auto f = qnnt::tld::unpack<can::Frame>(bytes);
    check(f.id == 0x1ABCDEF, "id crosses");
    check(f.ext, "ext crosses as true");
    check(!f.rtr, "rtr crosses as false");
    check(!f.err, "err crosses as false");
    check(f.fd, "fd crosses as true");
    check(f.brs, "brs crosses as true");
    check(!f.esi, "esi crosses as false");
    check(f.dlc == 12, "dlc crosses");
    check(f.us == 1700000000123456LL, "us crosses");
    // Twelve bytes: the first length classic CAN cannot express, so a path that quietly
    // downgraded this frame could not have produced it.
    check(f.data == std::vector<std::uint8_t>({0xA1, 0x0A, 0x0D, 0x00, 0xFF, 0xDE, 0xAD,
                                               0x5A, 0x11, 0x22, 0x33, 0x44}),
          "the payload crosses byte for byte, 0x0A and 0x0D included");

    // An empty payload is a legal CAN frame -- DLC 0, and every RTR frame -- and it has to
    // survive a round trip through the C encoder. An empty std::vector's data() may be
    // null, which the C writers rejected as a null pointer rather than reading as the empty
    // buffer that (null, 0) means in C; packing one threw, and in the station that was an
    // uncaught exception taking the window down.
    can::Frame empty;
    empty.id = 0x400;
    empty.dlc = 0;
    const auto empty_bytes = qnnt::tld::pack(empty);
    check(!empty_bytes.empty(), "a frame with no payload packs");
    const auto empty_back = qnnt::tld::unpack<can::Frame>(empty_bytes);
    check(empty_back.id == 0x400 && empty_back.dlc == 0 && empty_back.data.empty(),
          "and unpacks back to an empty payload");

    // 64 bytes through the encoder, which is eight times what classic CAN could carry and
    // the case a fixed 8-byte buffer anywhere on the path would truncate.
    can::Frame big;
    big.id = 0x500;
    big.fd = true;
    big.brs = true;
    big.dlc = 64;
    big.data.resize(64);
    for (std::size_t i = 0; i < big.data.size(); ++i) big.data[i] = std::uint8_t(i);
    const auto big_back = qnnt::tld::unpack<can::Frame>(qnnt::tld::pack(big));
    check(big_back.fd && big_back.brs && big_back.dlc == 64, "a 64-byte FD frame round-trips");
    check(big_back.data == big.data, "with all 64 bytes intact");

    // The same hole, reached through a string rather than a buffer.
    can::Frame rtr;
    rtr.id = 0x201;
    rtr.rtr = true;
    rtr.dlc = 8;   // an RTR frame requests bytes without carrying any
    const auto rtr_back = qnnt::tld::unpack<can::Frame>(qnnt::tld::pack(rtr));
    check(rtr_back.rtr && rtr_back.dlc == 8 && rtr_back.data.empty(),
          "a remote request packs with a length but no data");

    // And the station's own rendering of it, so the golden also pins what reaches a screen.
    check(can::formatId(f.id, f.ext) == "0x01ABCDEF", "the golden frame renders its id");
    check(can::formatData(f.data) == "A1 0A 0D 00 FF DE AD 5A 11 22 33 44", "and its payload");
    check(can::formatFlags(f) == "EFB", "and its flags");
}

} // namespace

int main()
{
    std::printf("qnnt C++ logic checks\n");
    steering();
    devices();
    motion();
    boundary();
    canStation();
    canBoundary();

    if (failures == 0) {
        std::printf("  all %d C++ logic checks passed\n", checks);
        return 0;
    }
    std::printf("  %d of %d C++ logic checks FAILED\n", failures, checks);
    return 1;
}
