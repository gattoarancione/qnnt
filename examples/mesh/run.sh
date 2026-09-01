#!/usr/bin/env bash
#
# Start every mesh node, wait, and report each one's verdict. See SCHEMA.txt.
#
#   zig build mesh                                  # four nodes
#   zig build mesh -Dqt=/path/to/Qt/6.10.3/macos    # and the Qt one
#   bash examples/mesh/run.sh
#
# Each node publishes its own topic and verifies what it receives from the others, so the
# mesh checks itself: this script only launches them and collects exit codes. A node that
# was not built is skipped and the others are told to expect one peer fewer.
#
#   MESH_SECONDS=9   how long the nodes run
#   MESH_NEED=5      samples required from each peer
#   MESH_PORT=22470  registry port, so this does not collide with another node on the host

set -u
cd "$(dirname "$0")/../.." || exit 1

SECONDS_TO_RUN="${MESH_SECONDS:-9}"
NEED="${MESH_NEED:-5}"
PORT="${MESH_PORT:-22470}"
BIN=zig-out/bin
LOGS=$(mktemp -d)

export QNNT_REGISTRY_PORT="$PORT"
export MESH_SECONDS="$SECONDS_TO_RUN"
export MESH_NEED="$NEED"

case "$(uname -s)" in
Darwin) LIB="$PWD/$BIN/../lib/libqnnt_c.dylib" ;;
*) LIB="$PWD/$BIN/../lib/libqnnt_c.so" ;;
esac
export QNNT_LIBRARY="$LIB"

# Qt's frameworks are not on the default search path when the binary is run from here.
if [ -n "${QT_PATH:-}" ]; then
    export DYLD_FRAMEWORK_PATH="$QT_PATH/lib"
    export LD_LIBRARY_PATH="$QT_PATH/lib:${LD_LIBRARY_PATH:-}"
fi

# The roster of languages actually starting, so each node expects only these. Without it a
# node absent from the build makes every other node fail waiting for it.
roster=""
[ -x "$BIN/mesh-zig" ] && roster="$roster,zig"
[ -x "$BIN/mesh-c" ] && roster="$roster,c"
[ -x "$BIN/mesh-cpp" ] && roster="$roster,cpp"
roster="$roster,python"
[ -x "$BIN/mesh-qt" ] && roster="$roster,qt"
export MESH_PEERS="${roster#,}"

names=()
pids=()

start() {
    local name=$1
    shift
    "$@" > "$LOGS/$name.log" 2>&1 &
    pids+=($!)
    names+=("$name")
}

echo "mesh: registry port $PORT, ${SECONDS_TO_RUN}s, at least $NEED samples per peer"
echo "mesh: roster $MESH_PEERS"

[ -x "$BIN/mesh-zig" ] && start zig "$BIN/mesh-zig" "$((SECONDS_TO_RUN * 1000))" "$NEED" \
    || echo "mesh: mesh-zig not built, skipping"
[ -x "$BIN/mesh-c" ] && start c "$BIN/mesh-c" "$((SECONDS_TO_RUN * 1000))" "$NEED" \
    || echo "mesh: mesh-c not built, skipping"
[ -x "$BIN/mesh-cpp" ] && start cpp "$BIN/mesh-cpp" "$((SECONDS_TO_RUN * 1000))" "$NEED" \
    || echo "mesh: mesh-cpp not built, skipping"
start python python3 -u examples/mesh/node.py
[ -x "$BIN/mesh-qt" ] && start qt "$BIN/mesh-qt" "$((SECONDS_TO_RUN * 1000))" "$NEED" \
    || echo "mesh: mesh-qt not built (needs -Dqt=...), skipping"

echo "mesh: started ${#pids[@]} node(s): ${names[*]}"
echo

failed=0
for i in "${!pids[@]}"; do
    wait "${pids[$i]}"
    status=$?
    name="${names[$i]}"
    if [ "$status" -ne 0 ]; then
        failed=$((failed + 1))
        echo "=== $name: EXIT $status ==="
        grep -E "^$name:|Traceback|Error|error" "$LOGS/$name.log" | tail -12
    else
        echo "=== $name: ok ==="
        grep -E "^$name: from" "$LOGS/$name.log"
    fi
done

echo
if [ "$failed" -eq 0 ]; then
    echo "mesh: every node verified every peer"
else
    echo "mesh: $failed node(s) FAILED -- full logs in $LOGS"
    exit 1
fi
rm -rf "$LOGS"
