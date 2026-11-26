#!/usr/bin/env bash
#
# The CAN station with something to look at, without a CAN interface anywhere.
#
#   zig build can-station -Dqt=/path/to/Qt/6.10.3/macos
#   bash examples/can/demo.sh
#
# Four gateways and two buses, produced by examples/can/wire_check.py rather than read off
# a vcan interface. It publishes exactly the topics and exactly the TOLD frames a real
# gateway publishes, so the station cannot tell the difference -- which is the point: the
# station is a topic consumer, and nothing about it needs a kernel with CAN. For the real
# thing, with gateways on real interfaces, see docker/can.sh.
#
#   powertrain   alpha, bravo, charlie, delta
#   body         alpha, bravo
#
# The second bus is not decoration: charlie and delta must never show under it, though they
# are on the same mesh. What you should see is four gateways on one bus and two on the
# other, each with a rate of its own.
#
# Press Send and a FIFTH gateway appears, named after this station. That is not a bug: the
# station's own topic matches its own `can/*/*` pattern, exactly as documented, and it is
# drawn in amber so it reads as "mine" rather than as a gateway that duplicated.
#
#   CAN_SECONDS=2400   how long the publishers run (the station outlives them; they simply
#                      go quiet, which is worth seeing -- every rate falls to zero and the
#                      gateways grey out)
#   CAN_PORT=22460     registry port, so this does not collide with another node on the host
#   CAN_NAME=station   the name this station publishes under
#
# Everything started here is stopped on the way out, including when the window is closed.

set -u
cd "$(dirname "$0")/../.." || exit 1

SECONDS_TO_RUN="${CAN_SECONDS:-2400}"
PORT="${CAN_PORT:-22460}"
NAME="${CAN_NAME:-station}"
BIN=zig-out/bin

if [ ! -x "$BIN/can-station" ]; then
    echo "can: $BIN/can-station is not built. It needs Qt:"
    echo "  zig build can-station -Dqt=/path/to/Qt/6.10.3/macos"
    exit 1
fi

export QNNT_REGISTRY_PORT="$PORT"

case "$(uname -s)" in
Darwin) export QNNT_LIBRARY="$PWD/zig-out/lib/libqnnt_c.dylib" ;;
*) export QNNT_LIBRARY="$PWD/zig-out/lib/libqnnt_c.so" ;;
esac

# Qt's frameworks are not on the default search path when the binary is run from here.
if [ -n "${QT_PATH:-}" ]; then
    export DYLD_FRAMEWORK_PATH="$QT_PATH/lib"
    export LD_LIBRARY_PATH="$QT_PATH/lib:${LD_LIBRARY_PATH:-}"
fi

pids=()
cleanup() {
    # Closing the window must not leave four publishers talking to nobody. Traps EXIT, so
    # this runs whether the station quit, the terminal was interrupted, or the script ended
    # normally.
    for pid in "${pids[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done
    wait 2>/dev/null
}
trap cleanup EXIT INT TERM

gateway() {
    local name=$1
    shift
    python3 examples/can/wire_check.py "$name" "$@" --seconds "$SECONDS_TO_RUN" \
        > /dev/null 2>&1 &
    pids+=($!)
}

echo "can: registry port $PORT, publishers running for ${SECONDS_TO_RUN}s"
gateway alpha   --bus powertrain --bus body --tag 0xA1
gateway bravo   --bus powertrain --bus body --tag 0xB2
gateway charlie --bus powertrain            --tag 0xC3
gateway delta   --bus powertrain            --tag 0xD4
echo "can: 4 gateways on powertrain, 2 of them also on body"

# The station discovers all of them from the topic names, so it is given nothing but its own
# name -- no bus list, no gateway list, no addresses. Started after a moment so the first
# thing on screen is a populated mesh rather than an empty one; it would find them either
# way, within one rescan.
sleep 2
echo "can: starting the station as '$NAME' -- close the window to stop everything"
"$BIN/can-station" examples/can/main.qml "$NAME"
