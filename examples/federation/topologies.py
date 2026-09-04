#!/usr/bin/env python3
"""What a federated qnnt registry converges to, in four peer topologies.

    python3 examples/federation/topologies.py            # every check
    python3 examples/federation/topologies.py converge   # just the directory
    python3 examples/federation/topologies.py deliver resilience
    python3 examples/federation/topologies.py clocks --forget   # includes a 5 min wait

Six sites, each a separate process with its own registry port and its own federation port,
so a topology is nothing but a set of QNNT_PEERS lists:

    star    B,C,D,E all dial A. A dials nobody.
    ring    A->B->C->D->E->A
    mesh    every site dials every other
    hybrid  A=B=C meshed, D dials A, E dials D  (a chain hanging off a mesh)

SITE Z is the control, and it is what makes the rest mean anything: it carries the cluster
key but has no peers and nobody dials it. It must see only its own topic, and nothing may
see its topic. Without it, "every site sees every topic" would equally be the result of
every probe accidentally reading one shared registry -- the easiest way for a test like this
to pass while proving nothing.

FOUR CHECKS, because they fail independently:

  converge    does the DIRECTORY reach every site? Expected reachability is the transitive
              closure over the UNDIRECTED graph: an exchange pushes local entries and then
              pulls the peer's over the same connection, so a one-way peer list should still
              give two-way visibility.
  deliver     does DATA actually cross? A converged directory with no delivery would be a
              hollow pass, and the hop count is printed so it is visible that throughput
              does not depend on it.
  resilience  what does each topology SURVIVE? Measured as the ability to learn something
              NEW after a site is killed, which isolates connectivity from expiry. Judging
              it by whether the dead site's topic vanished measures the wrong thing -- see
              `clocks`.
  clocks      federation's two expiry clocks, read from the registry's own answer to `sub`.
"""
import glob, os, socket, subprocess, sys, time

REPO = os.getcwd()
HERE = os.path.dirname(os.path.abspath(__file__))
NODE = os.path.join(HERE, "node.py")
KEY = "federation-topology-test"
REG_BASE = 23300
FED_BASE = 23400
SITES = "ABCDEZ"
LIB = None

def reg(site): return REG_BASE + SITES.index(site)
def fed(site): return FED_BASE + SITES.index(site)
def topic(site): return f"fed/{site.lower()}/beacon"

TOPOLOGIES = {
    "star":   {"A": [], "B": ["A"], "C": ["A"], "D": ["A"], "E": ["A"], "Z": []},
    "ring":   {"A": ["B"], "B": ["C"], "C": ["D"], "D": ["E"], "E": ["A"], "Z": []},
    "mesh":   {s: [o for o in "ABCDE" if o != s] for s in "ABCDE"} | {"Z": []},
    "hybrid": {"A": ["B", "C"], "B": ["A", "C"], "C": ["A", "B"],
               "D": ["A"], "E": ["D"], "Z": []},
}

# From federation.zig. Named here so a change there shows up as a failing expectation
# rather than as a test that quietly measures something else.
SERVE_UNTIL_S = 30    # fed_serve_until_us  -- withheld from subscribers after this
FORGET_AFTER_S = 300  # fed_forget_after_us -- removed from the directory after this
SYNC_INTERVAL_S = 5   # fed_sync_interval_ms


# -- graph ----------------------------------------------------------------------------

def undirected_reachable(spec):
    adj = {n: set() for n in spec}
    for n, peers in spec.items():
        for p in peers:
            adj[n].add(p); adj[p].add(n)
    out = {}
    for start in spec:
        seen, stack = {start}, [start]
        while stack:
            for nxt in adj[stack.pop()]:
                if nxt not in seen:
                    seen.add(nxt); stack.append(nxt)
        out[start] = seen
    return out


def hop_counts(spec, source):
    adj = {n: set() for n in spec}
    for n, peers in spec.items():
        for p in peers:
            adj[n].add(p); adj[p].add(n)
    dist, frontier, step = {source: 0}, [source], 0
    while frontier:
        step += 1
        nxt = []
        for cur in frontier:
            for n in adj[cur]:
                if n not in dist:
                    dist[n] = step; nxt.append(n)
        frontier = nxt
    return dist


# -- processes ------------------------------------------------------------------------

def site_env(site, spec):
    env = dict(os.environ)
    env["QNNT_REGISTRY_PORT"] = str(reg(site))
    env["QNNT_FEDERATION_PORT"] = str(fed(site))
    env["QNNT_CLUSTER_KEY"] = KEY
    env["QNNT_ADVERTISE_ADDR"] = "127.0.0.1"
    peers = ",".join(f"127.0.0.1:{fed(p)}" for p in spec[site])
    if peers: env["QNNT_PEERS"] = peers
    else: env.pop("QNNT_PEERS", None)
    if LIB: env["QNNT_LIBRARY"] = LIB
    return env


def app_env(site):
    """An ordinary application on a site: no key, no federation of its own."""
    env = dict(os.environ)
    env["QNNT_REGISTRY_PORT"] = str(reg(site))
    env.pop("QNNT_CLUSTER_KEY", None)
    env.pop("QNNT_PEERS", None)
    env["QNNT_FEDERATION_PORT"] = "0"
    if LIB: env["QNNT_LIBRARY"] = LIB
    return env


def start_site(site, spec, publish=False):
    args = [sys.executable, NODE, topic(site)] + (["--publish"] if publish else [])
    return subprocess.Popen(args, env=site_env(site, spec), cwd=REPO,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop(procs):
    for p in procs:
        p.terminate()
    for p in procs:
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired: p.kill()


# -- observation ----------------------------------------------------------------------

def visible(site, pattern="fed/*"):
    """The topics this site's registry knows about."""
    try:
        out = subprocess.run([os.path.join(REPO, "zig-out/bin/qnnt-ls"), pattern],
                             env=app_env(site), cwd=REPO, capture_output=True,
                             text=True, timeout=15).stdout
    except subprocess.TimeoutExpired:
        return set()
    return {l.strip() for l in out.splitlines() if l.strip().startswith("fed/")}


def registry_sub(site, name):
    """Exactly what the registry would tell a subscriber asking for `name`.

    Three answers, mapping onto the two clocks:
        tcp://host:port            servable
        error: topic ... expired   past SERVE_UNTIL_S, withheld
        error: topic ... not found past FORGET_AFTER_S, or never known
    """
    try:
        s = socket.create_connection(("127.0.0.1", reg(site)), timeout=5)
    except OSError as e:
        return f"unreachable ({e})"
    s.sendall(f"sub {name}\n".encode())
    s.settimeout(3)
    data = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk: break
            data += chunk
    except socket.timeout:
        pass
    s.close()
    lines = [l for l in data.decode(errors="replace").splitlines()
             if l and not l.startswith("#")]
    return lines[-1] if lines else "(no answer)"


def classify(answer):
    if answer.startswith("tcp://"): return "served"
    if "expired" in answer: return "withheld"
    if "not found" in answer: return "forgotten"
    return "?"


# -- 1. the directory converges --------------------------------------------------------

def check_converge(name, spec, budget=45.0):
    print(f"\n--- {name}: directory ---")
    for s in SITES:
        print(f"  {s}: peers -> {spec[s] or '(none)'}")

    procs = [start_site(s, spec) for s in SITES]
    want = {s: {topic(t) for t in undirected_reachable(spec)[s]} for s in SITES}

    time.sleep(3)
    start, seen, at = time.time(), {}, None
    while time.time() - start < budget:
        seen = {s: visible(s) for s in SITES}
        if all(seen[s] == want[s] for s in SITES):
            at = time.time() - start
            break
        time.sleep(2)
    stop(procs)

    print(f"\n  {'site':6s} {'sees':>4s}   " + "  ".join(SITES))
    ok = True
    for s in SITES:
        row = []
        for t in SITES:
            has, should = topic(t) in seen[s], topic(t) in want[s]
            row.append(" ok" if has and should else "EXTRA" if has
                       else "MISS" if should else "  .")
            if has != should: ok = False
        print(f"  {s:6s} {len(seen[s]):>4d}   " + "  ".join(f"{c:>3s}" for c in row))

    if at is not None:
        print(f"\n  converged in {at:.1f}s (the sync timer is {SYNC_INTERVAL_S}s, so a "
              f"faster time means change is pushed eagerly)")
    else:
        print(f"\n  DID NOT converge within {budget:.0f}s")
    z_leak = [s for s in "ABCDE" if topic("Z") in seen.get(s, set())]
    z_wrong = sorted(t for t in seen.get("Z", set()) if t != topic("Z"))
    print(f"  control Z: leaked into {z_leak or 'nothing'}, wrongly sees "
          f"{z_wrong or 'nothing'}")
    return ok and at is not None


# -- 2. data crosses -------------------------------------------------------------------

def check_deliver(name, spec, window=8.0):
    print(f"\n--- {name}: delivery of {topic('A')} ---")
    procs = [start_site(s, spec, publish=(s == "A")) for s in SITES]
    time.sleep(6)

    subs = {}
    for site in SITES:
        if site == "A": continue
        subs[site] = subprocess.Popen(
            [sys.executable, NODE, topic("A"), "--subscribe", "--seconds", str(window)],
            env=app_env(site), cwd=REPO, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True)

    got = {}
    for site, p in subs.items():
        try: out, _ = p.communicate(timeout=window + 20)
        except subprocess.TimeoutExpired:
            p.kill(); out = ""
        line = next((l for l in out.splitlines() if l.startswith("RESULT")), "")
        got[site] = int(line.split("received=")[1].split()[0]) if line else 0
    stop(procs)

    hops = hop_counts(spec, "A")
    ok = True
    print(f"\n  {'site':5s} {'hops':>4s} {'msgs':>6s}   verdict")
    for site in "BCDEZ":
        should = site != "Z"
        good = (got.get(site, 0) > 0) == should
        if not good: ok = False
        h = hops.get(site)
        print(f"  {site:5s} {('-' if h is None else h):>4} {got.get(site, 0):>6d}   "
              f"{'ok' if good else ('NO DATA' if should else 'LEAKED')}")
    print("\n  throughput is the same at one hop and two: federation carries the ADDRESS,")
    print("  not the data -- a subscriber connects to the publisher's own socket.")
    return ok


# -- 3. what it survives ---------------------------------------------------------------

RESILIENCE = {
    "star":   ("A", "B", "the hub -- every leaf's only peer"),
    "ring":   ("C", "B", "one site on the loop, leaving a chain"),
    "mesh":   ("A", "B", "one of five, the rest still interconnected"),
    "hybrid": ("D", "B", "the joint between the meshed core and the chained leaf"),
}
NEW_TOPIC = "fed/new/beacon"


def check_resilience(name, spec):
    victim, publisher, why = RESILIENCE[name]
    print(f"\n--- {name}: kill {victim} ({why}) ---")

    procs = {s: start_site(s, spec) for s in SITES}
    time.sleep(6)
    healthy = all(len(visible(s)) == 5 for s in "ABCDE")
    print(f"  converged before the kill: {healthy}")

    procs[victim].terminate()
    try: procs[victim].wait(timeout=5)
    except subprocess.TimeoutExpired: procs[victim].kill()
    del procs[victim]
    time.sleep(3)

    # Something BRAND NEW, so this measures connectivity and not expiry.
    print(f"  {victim} dead; publishing {NEW_TOPIC} at {publisher}")
    newpub = subprocess.Popen([sys.executable, NODE, NEW_TOPIC], env=app_env(publisher),
                              cwd=REPO, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    time.sleep(12)

    survivors = [s for s in SITES if s != victim]
    got = {s: NEW_TOPIC in visible(s, "fed/new/*") for s in survivors}
    stop([newpub] + list(procs.values()))

    survivor_spec = {s: [p for p in peers if p != victim]
                     for s, peers in spec.items() if s != victim}
    reach = undirected_reachable(survivor_spec)
    ok = True
    print(f"\n  {'site':5s} {'learned':>7s} {'implied':>8s}")
    for s in survivors:
        want = publisher in reach[s]
        good = got[s] == want
        if not good: ok = False
        print(f"  {s:5s} {('yes' if got[s] else 'no'):>7s} "
              f"{('yes' if want else 'no'):>8s}{'' if good else '   <-- MISMATCH'}")
    rest = sorted(x for x in reach[publisher] if x != publisher)
    print(f"\n  surviving structure connects {publisher} to {''.join(rest) or 'nothing'}")
    return ok and healthy


# -- 4. the two clocks -----------------------------------------------------------------

def check_clocks(long_run=False):
    print(f"\n--- expiry clocks (star, killing a leaf) ---")
    spec = TOPOLOGIES["star"]
    procs = {s: start_site(s, spec) for s in SITES}
    time.sleep(6)
    print(f"  while E lives, B is told: {registry_sub('B', topic('E'))}")

    procs["E"].terminate()
    try: procs["E"].wait(timeout=5)
    except subprocess.TimeoutExpired: procs["E"].kill()
    del procs["E"]
    killed = time.time()

    print(f"\n  {'age':>7s}  {'listed':6s}  {'registry answer to `sub`':36s}  "
          f"{'state':10s} expected")
    ok = True
    for target in [8, 40] + ([FORGET_AFTER_S + 10] if long_run else []):
        while time.time() - killed < target:
            time.sleep(2)
        age = time.time() - killed
        answer = registry_sub("B", topic("E"))
        state = classify(answer)
        listed = topic("E") in visible("B")
        want = ("served" if age < SERVE_UNTIL_S
                else "withheld" if age < FORGET_AFTER_S else "forgotten")
        good = state == want
        if not good: ok = False
        print(f"  t+{age:4.0f}s  {str(listed):6s}  {answer[:36]:36s}  {state:10s} {want}"
              f"{'' if good else '   <-- MISMATCH'}")
    stop(procs.values())

    print(f"\n  the two clocks are separate, and only the first is visible to a subscriber:")
    print(f"    still LISTED throughout -- removed from the directory at {FORGET_AFTER_S}s")
    print(f"    WITHHELD from `sub` after {SERVE_UNTIL_S}s, so nobody is sent to a dead host")
    if not long_run:
        print(f"  (--forget also waits out the {FORGET_AFTER_S}s removal)")
    return ok


# -- main ------------------------------------------------------------------------------

if __name__ == "__main__":
    libs = glob.glob(os.path.join(REPO, "zig-out/lib/libqnnt*"))
    LIB = libs[0] if libs else None
    if not os.path.exists(os.path.join(REPO, "zig-out/bin/qnnt-ls")):
        print("build first: zig build"); sys.exit(2)

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    long_run = "--forget" in sys.argv
    checks = args or ["converge", "deliver", "resilience", "clocks"]

    results = {}
    for check in checks:
        if check == "clocks":
            results["clocks"] = check_clocks(long_run)
            continue
        fn = {"converge": check_converge, "deliver": check_deliver,
              "resilience": check_resilience}[check]
        for name, spec in TOPOLOGIES.items():
            print(f"\n{'='*74}")
            results[f"{check}/{name}"] = fn(name, spec)

    print(f"\n{'='*74}")
    for k, v in results.items():
        print(f"  {k:22s} {'PASS' if v else 'FAIL'}")
    sys.exit(0 if all(results.values()) else 1)
