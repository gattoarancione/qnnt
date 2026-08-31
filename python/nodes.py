#!/usr/bin/env python3
"""The Zig demo nodes (src/node-0..4) in Python.

    python3 python/nodes.py 0                    publish test/topic-a @100Hz, test/topic-b @20Hz
    python3 python/nodes.py 1                    publish test/topic-c @1kHz, consume test/topic-a
    python3 python/nodes.py 2                    consume test/topic-b and test/topic-c
    python3 python/nodes.py 3 [period_us] [size] TLD load generator on test/bench
    python3 python/nodes.py 4 [report_ms]        TLD benchmark subscriber on test/bench

Topics and rates match the Zig nodes, so any mix interoperates: a Python role 0 feeding a
C role 2 is the same system as five Zig nodes.

The mechanism differs, deliberately. The Zig and C nodes let the library drive publishers
from its scheduler thread and deliver via callbacks; the Python package exposes neither,
because both mean a library thread calling into CPython -- taking the GIL from a thread it
has never seen, with nowhere to put an exception. So here the publish loop is ours and
delivery is drained with poll(). The observable behaviour is the same; the threads are all
Python's.

One consequence worth seeing rather than hiding: a pure-Python 1 kHz publish loop is at the
mercy of the interpreter and the OS timer, so role 3 reports what it actually achieved
instead of assuming it hit the target.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import qnnt
from qnnt import tld

TOPIC_A, TOPIC_B, TOPIC_C = "test/topic-a", "test/topic-b", "test/topic-c"
TOPIC_BENCH = "test/bench"


def paced(period_s, deadline_fn):
    """Yield once per period against an absolute schedule.

    Sleeping `period` each time round would accumulate the loop's own cost as drift, the
    same reason the library's scheduler paces to a deadline.
    """
    next_at = time.perf_counter()
    while not deadline_fn():
        next_at += period_s
        delay = next_at - time.perf_counter()
        if delay > 0:
            time.sleep(delay)
        else:
            next_at = time.perf_counter()  # fell behind; resynchronise rather than burst
        yield


def stamp(us):
    return f"[{us // 1000}.{us % 1000:03d}]"


# --- role 0 -------------------------------------------------------------------

def role0(node, _args):
    node.publisher(TOPIC_A)
    node.publisher(TOPIC_B)
    print(f"node-py 0: publishing {TOPIC_A} @100Hz, {TOPIC_B} @20Hz")

    # 100 Hz and 20 Hz from one loop: tick at 100 Hz, send topic-b every fifth tick.
    tick = 0
    for _ in paced(0.01, lambda: node.stop_requested):
        node.publish(TOPIC_A, b"ciao!\n")
        tick += 1
        if tick % 5 == 0:
            node.publish(TOPIC_B, b"!oaic\n")


# --- role 1 -------------------------------------------------------------------

def role1(node, _args):
    node.publisher(TOPIC_C)
    node.subscribe(TOPIC_A)
    print(f"node-py 1: publishing {TOPIC_C} @1kHz, subscribed to {TOPIC_A}")

    prev_us = 0
    for _ in paced(0.001, lambda: node.stop_requested):
        node.publish(TOPIC_C, b"hola!\n")
        # Drain without waiting: the publish loop must not stall on an empty queue.
        for msg in node.poll(timeout=0):
            us = msg.received_us
            delta = us - prev_us if prev_us else 0
            prev_us = us
            print(f"{stamp(us)} (+{delta}us) node-py 1 received on {msg.topic}: {msg.text()}",
                  end="")


# --- role 2 -------------------------------------------------------------------

def role2(node, _args):
    node.subscribe(TOPIC_B)
    node.subscribe(TOPIC_C)
    print(f"node-py 2: subscribed to {TOPIC_B} and {TOPIC_C}")

    # Per-topic state, which is what the C and Zig versions carry in the user pointer.
    feeds = {TOPIC_B: {"label": "b", "prev": 0, "count": 0},
             TOPIC_C: {"label": "c", "prev": 0, "count": 0}}

    for msg in node.stream(timeout=0.25):
        feed = feeds.get(msg.topic)
        if feed is None:
            continue
        us = msg.received_us
        delta = us - feed["prev"] if feed["prev"] else 0
        feed["prev"] = us
        feed["count"] += 1
        print(f"{stamp(us)} (+{delta}us) node-py 2 feed {feed['label']} #{feed['count']} "
              f"on {msg.topic}: {msg.text()}", end="")


# --- role 3 -------------------------------------------------------------------

def role3(node, args):
    period_us = int(args[0]) if args else 1000
    payload_bytes = int(args[1]) if len(args) > 1 else 64

    # Cycles every byte value, so 0x0A and 0xFF are present on purpose: a benchmark that
    # only moved text would not be exercising what TLD framing is for.
    payload = bytes(i & 0xFF for i in range(payload_bytes))

    node.publisher(TOPIC_BENCH)
    frame_len = len(tld.dumps({"seq": 1, "t": node.now_micros(), "data": payload}))
    target = "unpaced" if period_us == 0 else f"{period_us}us period ({1e6/period_us:.1f} Hz)"
    print(f"node-py 3: {payload_bytes}B payload, ~{frame_len}B frames, {target}")

    seq = 0
    sent = 0
    sent_bytes = 0
    last_report = time.perf_counter()
    last_sent = last_bytes = 0

    period_s = 0.0 if period_us == 0 else period_us / 1e6
    ticker = paced(period_s, lambda: node.stop_requested) if period_s else None

    while not node.stop_requested:
        if ticker is not None:
            next(ticker)
        seq += 1
        frame = tld.dumps({"seq": seq, "t": node.now_micros(), "data": payload})
        node.publish(TOPIC_BENCH, frame)
        sent += 1
        sent_bytes += len(frame)

        now = time.perf_counter()
        if now - last_report >= 1.0:
            secs = now - last_report
            print(f"node-py 3 sent {(sent - last_sent) / secs:.0f} frames/s "
                  f"({(sent_bytes - last_bytes) / secs / 1024:.1f} KB/s), {sent} total")
            last_report, last_sent, last_bytes = now, sent, sent_bytes


# --- role 4 -------------------------------------------------------------------

def role4(node, args):
    report_s = (int(args[0]) if args else 1000) / 1000.0

    node.subscribe(TOPIC_BENCH, frames=True)
    print(f"node-py 4: benchmarking {TOPIC_BENCH}, reporting every {report_s * 1000:.0f}ms")

    latencies = []
    frames = wire_bytes = 0
    total = gaps = bad_payload = errors = 0
    expected_seq = 0
    window_start = time.perf_counter()

    while not node.stop_requested:
        for msg in node.poll(timeout=0.1):
            try:
                value = msg.value()
            except tld.TldError:
                errors += 1
                continue

            seq = value.get("seq", 0)
            sent_us = value.get("t", 0)
            data = value.get("data", b"")
            if any(byte != (i & 0xFF) for i, byte in enumerate(data)):
                bad_payload += 1

            if expected_seq and seq > expected_seq:
                gaps += seq - expected_seq
            expected_seq = seq + 1

            latencies.append(max(msg.received_us - sent_us, 0))
            frames += 1
            wire_bytes += len(msg.data)
            total += 1

        now = time.perf_counter()
        if now - window_start >= report_s:
            secs = now - window_start
            if latencies:
                ordered = sorted(latencies)
                p50 = ordered[len(ordered) // 2]
                p99 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.99))]
                print(f"node-py 4 {frames / secs:.0f} frames/s | "
                      f"wire {wire_bytes / secs / 1024:.1f} KB/s | "
                      f"lat us min {ordered[0]} mean {sum(ordered) / len(ordered):.0f} "
                      f"p50 {p50} p99 {p99} max {ordered[-1]} | "
                      f"gaps {gaps} badpay {bad_payload} err {errors} | {total} total")
            else:
                print(f"node-py 4 idle (dropped {node.dropped})")
            latencies.clear()
            frames = wire_bytes = 0
            window_start = now


ROLES = {0: role0, 1: role1, 2: role2, 3: role3, 4: role4}


def main():
    argv = sys.argv[1:]
    role = int(argv[0]) if argv else 0
    if role not in ROLES:
        sys.exit(f"usage: {sys.argv[0]} <0..4> [args]")

    # Registry port, addressing and federation all come from the environment, read here
    # and passed in: the library takes values and leaves the source to the caller. Node()
    # applies the same QNNT_* fallbacks, so this only has to name the port explicitly.
    port = os.environ.get("QNNT_REGISTRY_PORT")
    with qnnt.Node(registry_port=int(port) if port else None,
                   queue_capacity=8192,
                   handle_signals=True) as node:
        try:
            ROLES[role](node, argv[1:])
        except KeyboardInterrupt:
            print("\ninterrupted")


if __name__ == "__main__":
    main()
