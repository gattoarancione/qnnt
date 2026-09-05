#!/usr/bin/env python3
"""What happens to a host when the node holding the registry dies.

    python3 examples/registry/failover.py

The directory is host-local and lives in ONE elected process: every node loops on binding
the registry port, and whoever gets it serves while the rest stand by and re-probe every
`registry_probe_interval_ms` (2s). So the holder is a single point of failure for a host,
and the interesting questions are what that actually costs.

Roles are kept in separate processes so the answers are not confounded:

    A   holds the registry, publishes nothing
    B   publishes the topic at 10 Hz
    C   subscribes before the kill and keeps counting across it

Then A is killed, and four things are measured:

  1. how long until a standby takes the role
  2. how long until the topic RESOLVES again -- which is a separate question, because the
     new holder starts with an EMPTY directory and has to wait for publishers to refresh
  3. whether an ESTABLISHED subscription survives -- it should, since the registry is how
     two nodes were introduced and not how they talk
  4. whether the port is ever observed vacant

Timing is jittery -- it depends where each standby is in its bind-retry cycle -- so this
takes `--runs N` and reports the distribution. Drawing a conclusion from a single run is
how this test twice produced a confident and wrong answer during development.

Measured on one host, loopback, after the warm-standby change: role taken in 0.2s, topic
resolvable in the same 0.2s, delivery never paused. Before it, the outage was 2.0s -- and
shortening the bind retry alone did not improve that at all, because a new holder had
nothing to serve until publishers re-registered.

"""
import glob, os, re, socket, subprocess, sys, time

REPO = os.getcwd()
PORT = 24100
TOPIC = "core/failover/beacon"
PROBE_INTERVAL_S = 2  # registry_probe_interval_ms in lib/qnnt.zig
LIB = None


def env():
    e = dict(os.environ)
    e["QNNT_REGISTRY_PORT"] = str(PORT)
    e.pop("QNNT_CLUSTER_KEY", None)
    e.pop("QNNT_PEERS", None)
    e["QNNT_FEDERATION_PORT"] = "0"
    if LIB:
        e["QNNT_LIBRARY"] = LIB
    return e


def spawn(script, log):
    return subprocess.Popen([sys.executable, "-c", script], env=env(), cwd=REPO,
                            stdout=open(log, "w"), stderr=subprocess.STDOUT, text=True)


IDLE = """
import sys, time
sys.path.insert(0, "python"); import qnnt
with qnnt.Node() as n:
    print("up", flush=True)
    while True: time.sleep(0.5)
"""

PUBLISHER = f"""
import sys, time
sys.path.insert(0, "python"); import qnnt
with qnnt.Node() as n:
    n.publisher("{TOPIC}")
    print("up", flush=True)
    seq = 0
    while True:
        seq += 1
        n.publish_object("{TOPIC}", {{"seq": seq}})
        time.sleep(0.1)
"""

SUBSCRIBER = f"""
import sys, time
sys.path.insert(0, "python"); import qnnt
with qnnt.Node() as n:
    n.subscribe("{TOPIC}", frames=True)
    print("up", flush=True)
    while True:
        got = sum(1 for _ in n.poll(timeout=0.5))
        print(f"TICK {{time.time():.3f}} {{got}}", flush=True)
"""


def registry(command):
    """Ask the registry directly. None means nobody is listening -- the role is vacant.

    The trailing newline is the command terminator, and omitting it is not a small
    mistake: the registry waits for the rest of the line and replies with its banner
    alone, which parses as an empty answer and looks exactly like "topic unknown".
    """
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=3)
    except OSError:
        return None
    s.sendall((command if command.endswith("\n") else command + "\n").encode())
    # Read until the reply's terminator, NOT until the socket times out. The registry keeps
    # the connection open after answering, so waiting for a close added the full socket
    # timeout to every successful probe -- which silently inflated every timing this
    # harness reported by about two seconds. `# end` exists precisely so a client need not
    # wait: FEDERATION-PLAN.md phase 1 measured it at 81.6ms -> 0.22ms per command.
    s.settimeout(3)
    data = b""
    ends = 0
    while ends < 2:                    # one for the banner, one for the reply
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        data += chunk
        ends = data.count(b"# end")
    s.close()
    lines = [l for l in data.decode(errors="replace").splitlines()
             if l and not l.startswith("#")]
    return lines[-1] if lines else ""


def ever_held(log):
    """Whether this node has EVER acquired the role.

    Not the same as "holds it now", and the difference bit once: reading this after
    terminating the other nodes showed two of them as holders, because shutting one down
    frees the port and the survivor grabs it before it exits too. Anything that wants the
    outcome of the takeover has to sample before the teardown.
    """
    return "role acquired" in open(log).read()


def main() -> int:
    global LIB
    libs = glob.glob(os.path.join(REPO, "zig-out/lib/libqnnt_c.*"))
    LIB = libs[0] if libs else None

    # A first, so it wins the role.
    a = spawn(IDLE, "/tmp/fo_a.log"); time.sleep(2.5)
    b = spawn(PUBLISHER, "/tmp/fo_b.log"); time.sleep(2.0)
    c = spawn(SUBSCRIBER, "/tmp/fo_c.log"); time.sleep(2.5)

    role = {s: ever_held(f"/tmp/fo_{s}.log") for s in "abc"}
    before = registry(f"sub {TOPIC}")
    print(f"  holder before the kill: {[s.upper() for s, v in role.items() if v] or 'none'}")
    print(f"  the topic resolves to:  {before}")
    if not before.startswith("tcp://"):
        print("  cannot resolve the topic before the kill -- aborting")
        for p in (a, b, c): p.kill()
        return 2

    print("\n  killing the holder\n")
    a.terminate()
    try: a.wait(timeout=5)
    except subprocess.TimeoutExpired: a.kill()
    dead = time.time()

    took_role = took_resolve = None
    vacant = False
    while time.time() - dead < 30:
        answer = registry(f"sub {TOPIC}")
        if answer is None:
            vacant = True
        else:
            if took_role is None:
                took_role = time.time() - dead
            if answer.startswith("tcp://") and took_resolve is None:
                took_resolve = time.time() - dead
                break
        time.sleep(0.2)

    time.sleep(2)

    # Sampled BEFORE the teardown: terminating one of these frees the port, and the other
    # would acquire the role on its way out, which would make both look like the winner.
    took_over = {s: ever_held(f"/tmp/fo_{s}.log") for s in "bc"}
    publisher_took_over = took_over["b"]

    for p in (b, c):
        p.terminate()
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired: p.kill()

    def secs(v): return f"{v:.1f}s" if v is not None else "never"
    print(f"  port observed vacant:            {vacant}")
    print(f"  a standby took the role after:   {secs(took_role)}")
    print(f"  topic resolvable again after:    {secs(took_resolve)}")
    print(f"  who took the role: " +
          "  ".join(f"{s.upper()}={'HOLDER' if took_over[s] else 'standby'}" for s in "bc"))

    ticks = [(float(m.group(1)), int(m.group(2)))
             for m in (re.match(r"TICK ([0-9.]+) (\d+)", l) for l in open("/tmp/fo_c.log"))
             if m]
    across = [(t - dead, n) for t, n in ticks if -3 < t - dead < 12]
    silent = [f"{d:+.1f}s" for d, n in across if n == 0]
    print(f"\n  established subscriber across the kill: {len(across)} polls, "
          f"{sum(n for _, n in across)} messages")
    print(f"  polls that received nothing: {silent or 'none -- delivery never paused'}")

    # Who won the role turns out NOT to change the cost, which was worth checking because
    # the obvious guess is that it would: if the PUBLISHER takes over, its own topic looks
    # like it should already be in the directory it now serves, making resolution
    # immediate. Measured over several runs it is not -- the gap between taking the role
    # and resolving the topic is about one probe interval either way, because a node that
    # acquires the role starts with an empty directory for ITS OWN topics too and
    # re-registers them on its next refresh like everybody else.
    role_to_resolve = None if (took_role is None or took_resolve is None) \
        else took_resolve - took_role
    budget = 2 * PROBE_INTERVAL_S + 2.5

    ok = (took_role is not None and took_resolve is not None
          and took_resolve <= budget and not silent)
    print(f"\n  the publisher won the role: {publisher_took_over}"
          f"   (measured not to matter -- see the source)")
    print(f"  role -> resolvable took a further "
          f"{f'{role_to_resolve:.1f}s' if role_to_resolve is not None else 'n/a'}")
    print(f"\n  {'as expected' if ok else 'UNEXPECTED'}: taking the role costs up to one "
          f"probe interval (~{PROBE_INTERVAL_S}s, depending on")
    print(f"  where in its cycle the standby was), and re-registration costs about one "
          f"more. A host is")
    print(f"  therefore without a usable directory for roughly "
          f"{PROBE_INTERVAL_S * 2}s, whoever takes over,")
    print(f"  while established traffic keeps flowing throughout.")
    return {"role": took_role, "resolve": took_resolve,
            "gap": (took_resolve - took_role) if role_to_resolve is not None else 0.0,
            "publisher": publisher_took_over, "unbroken": not silent, "ok": ok}


def summarise(rows):
    print(f"\n{'='*70}\n  {len(rows)} runs\n{'='*70}")
    print(f"  {'role':>6s} {'resolve':>8s} {'gap':>6s}  who took over   delivery")
    for r in rows:
        print(f"  {r['role']:>6.1f} {r['resolve']:>8.1f} {r['gap']:>6.1f}  "
              f"{'publisher' if r['publisher'] else 'third party':13s} "
              f"{'unbroken' if r['unbroken'] else 'PAUSED'}")

    by_pub = [r for r in rows if r["publisher"]]
    by_other = [r for r in rows if not r["publisher"]]
    print()
    for label, group in (("publisher took over", by_pub), ("third party took over", by_other)):
        if not group:
            continue
        gaps = sorted(r["gap"] for r in group)
        print(f"  {label:22s} n={len(group):2d}  role "
              f"{min(r['role'] for r in group):.1f}-{max(r['role'] for r in group):.1f}s  "
              f"gap {gaps[0]:.1f}-{gaps[-1]:.1f}s")
    paused = [r for r in rows if not r["unbroken"]]
    print(f"\n  established delivery paused in {len(paused)} of {len(rows)} runs")
    print(f"  directory unavailable for {min(r['resolve'] for r in rows):.1f}-"
          f"{max(r['resolve'] for r in rows):.1f}s")
    return not paused and all(r["resolve"] is not None for r in rows)


if __name__ == "__main__":
    runs = 1
    for i, a in enumerate(sys.argv):
        if a == "--runs":
            runs = int(sys.argv[i + 1])
    rows = []
    for n in range(runs):
        if runs > 1:
            print(f"\n--- run {n + 1}/{runs} ---")
        row = main()
        if isinstance(row, dict):
            rows.append(row)
        elif row != 0:
            sys.exit(row)
    sys.exit(0 if (len(rows) < 2 or summarise(rows)) else 1)
