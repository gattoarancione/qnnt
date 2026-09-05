"""The gateway's qnnt half, with no kernel involved.

A CAN gateway is two halves: a SocketCAN interface, and a set of qnnt topics carrying what
it read. Only the first needs a kernel with CAN support -- and on a machine that has none
(Docker Desktop's LinuxKit kernel, for one) the second is still worth testing, because it is
where the design lives: the topic layout, the glob subscription, the federated directory
that lets a gateway find peers it was never told about, and the frame format itself.

So this speaks exactly the topics examples/can/gateway.zig speaks, publishing the same TLD
frames on `can/<bus>/<name>` and joining `can/<bus>/*`, and reports who it heard from. Run
it in place of the gateways (docker/can.sh wire) and the answer is the same shape: which
hosts reached which bus.

It is also a cross-language check on the wire format. These frames are packed by Python and
unpacked by Python here, but a gateway on the same bus reads them with the Zig struct in
examples/can/frame.zig -- so a field renamed on one side shows up as a gateway that receives
and silently discards.

    wire_check.py <name> --bus powertrain --bus body --tag 0xA1 --seconds 8
"""
import sys, time
sys.path.insert(0, "python")
import qnnt


def can_frame(tag: int, seq: int, us: int) -> dict:
    """The fields of examples/can/frame.zig's Frame, by the same names."""
    return {
        "id": 0x100 + (tag & 0xFF),
        "ext": False,
        "rtr": False,
        "err": False,
        "dlc": 8,
        # 0x0A and 0x0D in the payload on purpose: a CAN payload is arbitrary bytes, and a
        # text topic would split and rejoin these frames into garbage.
        "data": bytes([tag, seq & 0xFF, (seq >> 8) & 0xFF, 0x0A, 0x0D, 0xDE, 0xAD, 0xBE]),
        "us": us,
    }


def main() -> int:
    name = sys.argv[1]
    buses, tag, seconds = [], 0, 8.0
    for i, a in enumerate(sys.argv):
        if a == "--bus":
            buses.append(sys.argv[i + 1])
        elif a == "--tag":
            tag = int(sys.argv[i + 1], 0)
        elif a == "--seconds":
            seconds = float(sys.argv[i + 1])
    if not buses:
        print("wire_check.py: no --bus given", file=sys.stderr)
        return 2

    with qnnt.Node() as node:
        mine = {}
        for bus in buses:
            topic = f"can/{bus}/{name}"
            mine[bus] = topic
            node.publisher(topic)
            # The same call the gateway makes. Peers are never named: a gateway that joins
            # later is found because its topic appears in the federated directory.
            node.subscribe_pattern(f"can/{bus}/*", frames=True, rescan=0.25)

        # seen[bus][origin] = count. The origin is the last topic segment, which is how a
        # gateway tells another host's frames from the ones it published itself.
        seen: dict[str, dict[str, int]] = {b: {} for b in buses}
        malformed = 0

        # Paced, at a rate a CAN bus could actually carry. An unpaced loop publishes tens of
        # thousands of frames a second, which is not what this is measuring: it saturates
        # every core in every container and starves the federation exchange that the check
        # is actually about. The first run of this file did exactly that and the result was
        # a mesh that looked broken.
        seq, end = 0, time.time() + seconds
        while time.time() < end:
            for bus, topic in mine.items():
                node.publish(topic, qnnt.tld.dumps(can_frame(tag, seq, int(time.time() * 1e6))))
            seq += 1
            time.sleep(0.02)  # 50 Hz per bus

            for msg in node.poll(timeout=0.2):
                parts = msg.topic.split("/")
                if len(parts) != 3 or parts[0] != "can":
                    malformed += 1
                    continue
                bus, origin = parts[1], parts[2]
                try:
                    frame = msg.value()
                    # Enough of the shape to catch a rename or a type change, which is the
                    # failure this would otherwise miss entirely.
                    assert set(frame) == {"id", "ext", "rtr", "err", "dlc", "data", "us"}
                    assert isinstance(frame["data"], bytes) and len(frame["data"]) == frame["dlc"]
                except Exception:
                    malformed += 1
                    continue
                seen.setdefault(bus, {})
                seen[bus][origin] = seen[bus].get(origin, 0) + 1

        for bus in buses:
            origins = seen.get(bus, {})
            # One line per bus, greppable: which hosts reached this bus, and how often.
            print(f"RESULT {name} bus={bus} sent={seq} "
                  f"origins={','.join(sorted(origins)) or 'none'} "
                  f"counts={';'.join(f'{k}={v}' for k, v in sorted(origins.items())) or 'none'} "
                  f"malformed={malformed}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
