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

} // namespace

int main()
{
    std::printf("qnnt C++ logic checks\n");
    steering();
    devices();
    motion();
    boundary();

    if (failures == 0) {
        std::printf("  all %d C++ logic checks passed\n", checks);
        return 0;
    }
    std::printf("  %d of %d C++ logic checks FAILED\n", failures, checks);
    return 1;
}
