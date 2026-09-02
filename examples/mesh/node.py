#!/usr/bin/env python3
"""The Python node of the five-language mesh. See SCHEMA.txt.

    zig build mesh && bash examples/mesh/run.sh

Publishes mesh/python and subscribes to the other four topics. The dataclasses below are
the whole schema declaration: field names and annotations are enough for tld.pack and
tld.unpack, so nothing is generated from the C++ or Zig side.
"""

import os
import sys
import time
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "python"))

import qnnt

ME = "python"
MY_TOPIC = "mesh/python"
ALL_PEERS = {"zig": "mesh/zig", "c": "mesh/c", "cpp": "mesh/cpp", "qt": "mesh/qt"}

# run.sh sets MESH_PEERS to the languages it actually started, so the mesh works with any
# subset: build without -Dqt and the others stop waiting for a Qt node.
_present = os.environ.get("MESH_PEERS", "")
if _present:
    _wanted = {name.strip() for name in _present.split(",") if name.strip()}
    PEERS = {name: topic for name, topic in ALL_PEERS.items() if name in _wanted}
else:
    PEERS = dict(ALL_PEERS)

RUN_S = float(os.environ.get("MESH_SECONDS", "9"))
NEED = int(os.environ.get("MESH_NEED", "5"))
INTERVAL_S = 0.2
BLOB = bytes([0x00, 0xFF, 0x0A])


class Mode(IntEnum):
    idle = 0
    running = 1
    faulted = 2


@dataclass
class Reading:
    channel: int
    value: float
    valid: bool


@dataclass
class Origin:
    x: float
    y: float


@dataclass
class Sample:
    seq: int
    source: str
    mode: Mode
    count: int
    temp: float
    blob: bytes
    origin: Origin
    readings: list[Reading]


def expected(seq: int, source: str) -> Sample:
    """Every field derived from the sequence number, so a receiver can check exactly."""
    return Sample(
        seq=seq,
        source=source,
        mode=Mode(seq % 3),
        count=-seq,
        temp=36.5,
        blob=BLOB,
        origin=Origin(1.5, -2.5),
        readings=[Reading(i + 1, float(seq * 10 + i), i != 1) for i in range(3)],
    )


class PeerState:
    def __init__(self, name: str) -> None:
        self.name = name
        self.received = 0
        self.first_seq = 0
        self.last_seq = 0
        self.problems = 0


def check(state: PeerState, got: Sample) -> None:
    want = expected(got.seq, state.name)
    bad = False

    if got.source != want.source or got.mode != want.mode or got.count != want.count:
        bad = True
    # temp is f32 on the wire, so it round-trips through a float32 and back: compare with a
    # tolerance rather than exactly, unlike the f64 fields.
    if abs(got.temp - want.temp) > 1e-6:
        bad = True
    if got.blob != want.blob:
        bad = True
    if got.origin != want.origin:
        bad = True
    if got.readings != want.readings:
        bad = True

    if state.last_seq and got.seq != state.last_seq + 1:
        bad = True  # a gap inside the run; attaching late is fine and sets the baseline
    if not state.last_seq:
        state.first_seq = got.seq
    state.last_seq = got.seq

    state.received += 1
    if bad:
        state.problems += 1


def main() -> int:
    states = {name: PeerState(name) for name in PEERS}

    with qnnt.Node() as node:
        node.publisher(MY_TOPIC)
        # Long enough not to fire during normal 200 ms traffic, short enough to notice a
        # peer that stops. Without this, publisher_stale is never emitted at all.
        node.set_stale_timeout(1500)
        for topic in PEERS.values():
            node.subscribe(topic, frames=True)
        print(f"{ME}: publishing {MY_TOPIC}, subscribed to {len(PEERS)} peers", flush=True)

        # Wait for the first subscriber rather than sleeping a guess: a peer cannot attach
        # until this publisher is registered and its own next registry probe comes round.

        by_topic = {topic: states[name] for name, topic in PEERS.items()}
        seq = 0
        deadline = time.monotonic() + RUN_S
        next_send = time.monotonic()

        # Publishing is gated on the roster being complete, and the gate opens on an event
        # rather than after a sleep: subscriber_connected carries the topic's subscriber
        # count, so this node knows when the last peer has attached. Until then nothing is
        # published, which is what makes seq 1 the first sample every peer sees -- qnnt has
        # no replay, so anything sent earlier would simply be gone.
        publishing = False
        # A floor, in case this node is started alone: publish anyway rather than never.
        gate_deadline = time.monotonic() + 5.0

        while time.monotonic() < deadline:
            now = time.monotonic()

            for event in node.poll_events():
                if event.kind is qnnt.EventKind.subscriber_connected:
                    if event.topic == MY_TOPIC and not publishing:
                        if event.subscribers >= len(PEERS):
                            publishing = True
                            print(f"{ME}: all {event.subscribers} subscribers on "
                                  f"{MY_TOPIC}, publishing", flush=True)
                elif event.kind is qnnt.EventKind.subscriber_disconnected:
                    print(f"{ME}: subscriber left {event.topic} ({event.peer}), "
                          f"{event.subscribers} left", flush=True)
                elif event.kind is qnnt.EventKind.publisher_disconnected:
                    # The subscription reconnects on its own; this is notification only.
                    print(f"{ME}: {event.topic} publisher went away ({event.peer})",
                          flush=True)
                elif event.kind is qnnt.EventKind.publisher_stale:
                    print(f"{ME}: {event.topic} has gone quiet", flush=True)
                elif event.kind is qnnt.EventKind.publisher_resumed:
                    print(f"{ME}: {event.topic} is producing again", flush=True)

            if not publishing and now >= gate_deadline:
                publishing = True
                print(f"{ME}: only {node.subscriber_count(MY_TOPIC)} of {len(PEERS)} "
                      f"subscribers after 5s, publishing anyway", flush=True)

            if publishing and now >= next_send:
                seq += 1
                node.publish_object(MY_TOPIC, expected(seq, ME))
                next_send = now + INTERVAL_S

            # Short poll so publishing stays roughly on its interval; this node does both
            # jobs on one thread, which is what the poll queue is for.
            for message in node.poll(timeout=0.05):
                state = by_topic.get(message.topic)
                if state is None:
                    continue
                try:
                    check(state, message.unpacked(Sample))
                except Exception as err:  # malformed frame, or a shape mismatch
                    state.received += 1
                    state.problems += 1
                    if state.problems == 1:
                        print(f"{ME}: from {state.name}: {type(err).__name__}: {err}",
                              flush=True)

        dropped = node.dropped
        events_dropped = node.events_dropped

    failed = False
    for state in states.values():
        ok = state.received >= NEED and state.problems == 0
        failed = failed or not ok
        print(f"{ME}: from {state.name:<7} {state.received:>3} samples, "
              f"seq {state.first_seq}..{state.last_seq}, "
              f"{state.problems} problem(s) {'ok' if ok else 'FAILED'}", flush=True)

    if dropped:
        print(f"{ME}: {dropped} message(s) dropped by the queue", flush=True)
    if events_dropped:
        print(f"{ME}: {events_dropped} event(s) dropped -- poll_events was not drained "
              f"often enough", flush=True)

    print(f"{ME}: {'FAILED' if failed else 'all peers verified'}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
