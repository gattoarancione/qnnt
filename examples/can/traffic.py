#!/usr/bin/env python3
"""Put frames on a CAN interface, and see what comes back off one.

Python's socket module speaks SocketCAN natively, so this needs no can-utils and no
python-can -- which matters, because the point of the harness is to check the gateway, not
to check that a package installed.

    traffic.py send  vcan0 --count 20 --id 0x100 --tag 0xA1
    traffic.py watch vcan0 --seconds 5

`send` marks every frame with a one-byte tag, so a watcher on another host can say WHERE a
frame came from rather than only that something arrived.
"""

import argparse
import socket
import struct
import sys
import time

# struct can_frame: id, len, 3 reserved, 8 data. 16 bytes.
CAN_FRAME = struct.Struct("=IB3x8s")
# struct canfd_frame: id, len, flags, 2 reserved, 64 data. 72 bytes. The two sizes are the
# only thing that distinguishes the formats on a socket carrying both -- an 8-byte FD frame
# and an 8-byte classic frame are otherwise identical, and are different frames on a bus.
CANFD_FRAME = struct.Struct("=IBB2x64s")
CAN_MTU = 16
CANFD_MTU = 72

SOL_CAN_RAW = 101
CAN_RAW_FD_FRAMES = 5
CANFD_BRS = 0x01
CANFD_ESI = 0x02

# The lengths CAN FD can express. Nothing between 8 and 12, or 24 and 32.
FD_LENGTHS = (0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64)

CAN_EFF_FLAG = 0x80000000
CAN_RTR_FLAG = 0x40000000
CAN_ERR_FLAG = 0x20000000
CAN_EFF_MASK = 0x1FFFFFFF
CAN_SFF_MASK = 0x000007FF


def open_bus(iface: str, timeout: float | None = None) -> socket.socket:
    try:
        s = socket.socket(socket.PF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    except (AttributeError, OSError) as e:
        sys.exit(f"traffic.py: no CAN support in this kernel ({e}). See docker/README.md.")
    try:
        s.bind((iface,))
    except OSError as e:
        sys.exit(f"traffic.py: cannot bind {iface}: {e}\n"
                 f"  ip link add dev {iface} type vcan && ip link set up {iface}")
    # Ask for CAN FD. Without it the kernel does not deliver FD frames at all -- not
    # truncated, absent -- so a watcher would report a silent bus while FD traffic flowed.
    # Failure is not fatal: an older kernel still carries classic traffic.
    try:
        s.setsockopt(SOL_CAN_RAW, CAN_RAW_FD_FRAMES, 1)
    except OSError:
        pass
    if timeout is not None:
        s.settimeout(timeout)
    return s


def decode(raw: bytes):
    """One frame. WHICH FORMAT IS THE LENGTH OF `raw`, and nothing else."""
    if len(raw) == CANFD_MTU:
        can_id, length, flags, data = CANFD_FRAME.unpack(raw)
        fd, brs, esi = True, bool(flags & CANFD_BRS), bool(flags & CANFD_ESI)
        rtr = False          # CAN FD has no remote frames
    else:
        can_id, length, data = CAN_FRAME.unpack(raw)
        fd, brs, esi = False, False, False
        rtr = bool(can_id & CAN_RTR_FLAG)
    ext = bool(can_id & CAN_EFF_FLAG)
    return {
        "id": can_id & (CAN_EFF_MASK if ext else CAN_SFF_MASK),
        "ext": ext,
        "rtr": rtr,
        "err": bool(can_id & CAN_ERR_FLAG),
        "fd": fd,
        "brs": brs,
        "esi": esi,
        "len": length,
        "data": data[:length],
    }


def cmd_send(args):
    if args.fd and args.len not in FD_LENGTHS:
        sys.exit(f"traffic.py: {args.len} is not a length CAN FD can express: {FD_LENGTHS}")
    if not args.fd and args.len > 8:
        sys.exit(f"traffic.py: classic CAN carries at most 8 bytes; add --fd")

    s = open_bus(args.iface)
    for i in range(args.count):
        # The tag identifies the sender, the counter the frame. Both are readable in the
        # payload of a candump line, which is what makes a failure diagnosable by eye. The
        # rest is a ramp, so a truncated payload is obvious rather than plausible.
        head = bytes([args.tag, i & 0xFF, (i >> 8) & 0xFF, 0xDE, 0xAD, 0xBE, 0xEF, 0x00])
        payload = (head + bytes(range(0x10, 0x10 + max(0, args.len - 8))))[:args.len]
        can_id = args.id + (CAN_EFF_FLAG if args.ext else 0)
        if args.fd:
            flags = CANFD_BRS if args.brs else 0
            s.send(CANFD_FRAME.pack(can_id, args.len, flags, payload))
        else:
            s.send(CAN_FRAME.pack(can_id, args.len, payload))
        if args.gap:
            time.sleep(args.gap)
    kind = "FD" if args.fd else "classic"
    print(f"sent {args.count} {kind} frames on {args.iface} "
          f"id=0x{args.id:X} len={args.len} tag=0x{args.tag:02X}")


def cmd_watch(args):
    s = open_bus(args.iface, timeout=0.5)
    deadline = time.time() + args.seconds
    seen = []
    while time.time() < deadline:
        try:
            raw = s.recv(CANFD_MTU)
        except socket.timeout:
            continue
        f = decode(raw)
        seen.append(f)
        if not args.quiet:
            flags = "".join(c for c, on in (("E", f["ext"]), ("R", f["rtr"]), ("!", f["err"]),
                                            ("F", f["fd"]), ("B", f["brs"])) if on)
            print(f"{args.iface}  {f['id']:03X}{flags:<5} [{f['len']}]  {f['data'].hex(' ')}",
                  flush=True)

    # A summary keyed by the sender tag: which hosts' traffic reached this bus.
    tags = {}
    for f in seen:
        if f["data"]:
            tags[f["data"][0]] = tags.get(f["data"][0], 0) + 1
    print(f"total {len(seen)} frames on {args.iface}; by tag: " +
          (", ".join(f"0x{t:02X}={n}" for t, n in sorted(tags.items())) or "none"))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("send", help="put frames on a bus")
    s.add_argument("iface")
    s.add_argument("--count", type=int, default=10)
    s.add_argument("--id", type=lambda v: int(v, 0), default=0x100)
    s.add_argument("--tag", type=lambda v: int(v, 0), default=0x00,
                   help="first payload byte, identifying the sender")
    s.add_argument("--ext", action="store_true", help="29-bit identifier")
    s.add_argument("--fd", action="store_true", help="CAN FD frame")
    s.add_argument("--brs", action="store_true", help="FD bit rate switch (implies --fd)")
    s.add_argument("--len", type=int, default=8,
                   help="payload length: 0-8 classic, one of %s for FD" % (FD_LENGTHS,))
    s.add_argument("--gap", type=float, default=0.01, help="seconds between frames")
    s.set_defaults(func=cmd_send)

    w = sub.add_parser("watch", help="print what arrives on a bus")
    w.add_argument("iface")
    w.add_argument("--seconds", type=float, default=5.0)
    w.add_argument("--quiet", action="store_true", help="only the summary")
    w.set_defaults(func=cmd_watch)

    args = p.parse_args()
    if getattr(args, "brs", False):
        args.fd = True
    args.func(args)


if __name__ == "__main__":
    main()
