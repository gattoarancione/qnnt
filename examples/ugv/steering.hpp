// Differential steering, as arithmetic.
//
// Split out of pilot.cpp so it can be tested without Qt, an event loop or a robot. What is
// here is the whole of the conversion from what an operator asks for to what the two tracks
// are told; the Qt class above it only collects input and publishes the result.
//
// The sign convention is stated once, here, and everything else derives from it. Getting it
// wrong is not a compile error and not visibly wrong on a stationary robot -- the pad
// indicator in the QML once ran backwards for exactly this reason, because it re-derived
// the same quantity a second time instead of using the one the C++ had already computed.

#ifndef QNNT_UGV_STEERING_HPP
#define QNNT_UGV_STEERING_HPP

#include <algorithm>
#include <cmath>

namespace ugv {

/// What the two tracks are told, each a fraction of full scale in [-1, 1]. The bridge
/// scales these by the robot's own max_speed; nothing here knows what that is.
struct Tracks {
    double left{};
    double right{};
};

/// Turn an operator's two axes into two track speeds.
///
/// `forward` is positive away from the operator, `turn` is positive to the RIGHT. A right
/// turn therefore drives the left track forward and the right track back.
///
/// The magnitude is NORMALISED rather than clipped. Full forward and full turn together ask
/// for 2.0 on one track, and clipping that to 1.0 while the other stays at 0.0 would quietly
/// straighten the turn -- the robot would drive nearly straight when the operator asked for
/// a hard curve. Dividing both by the peak keeps the ratio and loses only speed.
inline Tracks mix(double forward, double turn, double throttle)
{
    double left = forward + turn;
    double right = forward - turn;

    const double peak = std::max(std::abs(left), std::abs(right));
    if (peak > 1.0) {
        left /= peak;
        right /= peak;
    }

    return { left * throttle, right * throttle };
}

/// How fast, forward positive: the MEAN of the two tracks.
inline double driveAxis(Tracks t) { return (t.left + t.right) / 2.0; }

/// How hard it is turning, right positive: their DIFFERENCE. A right turn is left +1 and
/// right -1, so the difference that means "turning right" is (left - right) -- written the
/// other way round it moves against the operator's input.
inline double steerAxis(Tracks t) { return (t.left - t.right) / 2.0; }

} // namespace ugv

#endif
