// What a hub device is FOR, and which devices deserve a row of their own.
//
// Split out of home.cpp so it can be tested without Qt or a hub. Grouping by room alone put
// a lamp, an occupancy sensor and a light meter in one list, and they answer three
// unrelated questions; this is the classification that replaced it, plus the rule that
// collapses one physical sensor reported as two devices back into one row.

#ifndef QNNT_DIRIGERA_DEVICES_HPP
#define QNNT_DIRIGERA_DEVICES_HPP

#include <string_view>

namespace dirigera {

/// What a device is for, which is not the same as what it is.
enum class Role {
    Light,     ///< an actuator: you operate it
    Presence,  ///< occupancy: motion, transient, event-driven
    Ambient,   ///< a measurement: illuminance, continuous
    Control,   ///< an input: a remote or dimmer, only its battery is actionable
    Other,     ///< the gateway, and anything a firmware adds later
};

/// Classify by the hub's own `deviceType` spelling.
///
/// An unrecognised type is `Other` rather than a guess: a firmware that adds a device kind
/// should leave it out of the interface until somebody decides where it belongs, not have
/// it appear among the lights because that was the first branch.
inline Role roleFor(std::string_view kind)
{
    if (kind == "light" || kind == "outlet" || kind == "blinds") return Role::Light;
    if (kind == "motionSensor") return Role::Presence;
    if (kind == "lightSensor" || kind == "environmentSensor") return Role::Ambient;
    if (kind == "lightController") return Role::Control;
    return Role::Other;
}

/// Whether this device is shown as a row of its own.
///
/// The one case that is not obvious: a VALLHORN is a single unit on the wall that the hub
/// reports as TWO devices, a motion sensor and a light sensor sharing a relationId. The
/// light-sensor half carries neither a name nor a room, so shown separately it appears as a
/// nameless duplicate. It is folded into its twin's row as a reading instead -- but only
/// when it HAS a twin: a light sensor on its own really is a standalone meter and keeps its
/// row.
///
/// The gateway is not shown at all; it is not a thing to operate or read.
inline bool ownRow(Role role, bool has_presence_twin)
{
    switch (role) {
        case Role::Light:
        case Role::Presence:
        case Role::Control:
            return true;
        case Role::Ambient:
            return !has_presence_twin;
        case Role::Other:
            return false;
    }
    return false;
}

/// Motion as an EVENT rather than a state.
///
/// A sensor reads false almost all the time, and the hub clears `isDetected` on its own
/// schedule, so an interface showing the instantaneous value says "no motion" for a sensor
/// that fired ten seconds ago and flickers between readings. What matters is the rising
/// edge and how long ago it was.
struct MotionEdge {
    bool detected{false};   ///< the last reading
    bool ever{false};       ///< has it ever fired
    long long last_us{0};   ///< when it last rose

    /// Feed a reading. Returns true if this was a RISING edge, which is the moment worth
    /// timestamping; a sensor that stays detected must not keep restarting the clock.
    bool update(bool now_detected, long long now_us)
    {
        const bool rising = now_detected && !detected;
        if (rising) {
            ever = true;
            last_us = now_us;
        }
        detected = now_detected;
        return rising;
    }

    /// Currently detecting, or did so within `hold_us`. The hold is what stops the
    /// indicator flickering between the hub's own clear and the next trip.
    bool recent(long long now_us, long long hold_us) const
    {
        if (detected) return true;
        return ever && (now_us - last_us) < hold_us;
    }
};

} // namespace dirigera

#endif
