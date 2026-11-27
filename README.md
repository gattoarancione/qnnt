<p align="center">
  <img src="qnnt.png" alt="QNNT" width="384">
</p>
<p align="center"><b>QNNT NaNo Transport</b></p>

A pub/sub library for machines that have to talk to each other and to their own
processes, without a broker. Zig core, with C, C++/Qt and Python on the same
implementation.

Three sentences of mental model:

1. A **host-local registry** holds a directory of `topic -> tcp://host:port`.
2. A **publisher** registers its endpoint there; a **subscriber** resolves the topic
   and connects **straight to the publisher**. Data never goes through the registry.
3. **Federation** copies directories between hosts, so a subscriber can resolve a
   topic published on another machine — and then still connects directly to it.

That split is the whole design: the registry is a control plane, and the only thing
on the data path is the two ends of a TCP connection.

```
  registry (loopback, 2222)          federation (2223, between hosts)
        │  directory                        │  directory copies
   ┌────┴────┐                              │
publisher   subscriber ──── TCP ────► publisher   ← the data plane
```

## Requirements

**Zig 0.16 is the only hard requirement.** It builds the library, both tools, the C and C++
bindings, the Zig examples and the whole test suite, on macOS and Linux, with nothing else
installed. `build.zig.zon` declares it, so an older compiler is told rather than left to
produce errors.

The TOLD codec is a git submodule, so clone with `--recursive`, or run
`git submodule update --init` in an existing checkout. Without it nothing builds.

Everything below is needed only for the part of the tree that names it. A missing one
never breaks the rest of the build.

| For | You need | Notes |
|---|---|---|
| The library, tools, tests | **Zig 0.16** | Nothing else. macOS or Linux. |
| The QML stations (`can-station`, `dirigera-home`, `ugv-pilot`, the viewers) | **Qt 6** | Pass the kit: `zig build can-station -Dqt=/Users/you/Qt/6.10.3/macos`. Developed against 6.10.3. Without `-Dqt=` these steps simply are not built. |
| The Python binding | **Python 3.10+** | `python/pyproject.toml` declares it. Finds the freshly built library by itself from a checkout. |
| The DIRIGERA bridge | **OpenSSL 3** | `-Ddirigera-openssl=/opt/homebrew/opt/openssl@3`. The hub speaks TLS 1.2 with ECDSA, which Zig's std TLS does not offer. |
| The multi-host harnesses | **Docker**, plus `nc` and `python3` | `docker/federation.sh`, `docker/can.sh`. Linux binaries are cross-compiled on the host: `zig build -Dtarget=aarch64-linux-gnu`. |
| The CAN gateway | **Linux with `vcan`** | `CONFIG_CAN` + `CONFIG_CAN_VCAN`. The gateway is Linux-only; the *station* that watches it is not. |
| Realtime options | **Linux** | `QNNT_RT_PRIORITY`, `QNNT_LOCK_MEMORY`. Refused elsewhere, with a reason. |

### On macOS SDK 27, patch Zig's bundled `float.h` first

Every `-lc++` link fails on a Mac whose SDK is 27 or newer, which takes the C++ steps
(`node-cpp`, `cpp-logic-test`) down with it:

```
error: sub-compilation of libcxx failed
  .../__random/clamp_to_integral.h:47:58: use of undeclared identifier 'INFINITY'
```

Zig compiles its own libc++ with `-std=c++23`, and C++20 and later turn on
`__has_feature(modules)`. SDK 27's `math.h` reacts by handing `INFINITY` and `NAN` off to
`<float.h>` through `__need_infinity_nan` instead of defining them itself. The Clang that
Xcode ships answers that; the `float.h` bundled with Zig 0.16.0 predates the split, so
nothing defines `INFINITY` and libc++ will not compile. The nullability warnings that bury
the real message are noise — they were always warnings.

No supported knob reaches it: neither `--sysroot` nor `SDKROOT` moves the `-isystem` that
the libc++ sub-compilation uses, and its `-std` is internal. So patch the header:

```sh
tools/patch-zig-float-h.sh
```

It wraps Zig's `float.h` in a `__need_infinity_nan` branch and leaves all 187 original
lines untouched in the `#else`, so only SDK 27's `math.h` ever takes the new path. Note
that it edits the toolchain, not this repo: the change is **machine-wide**, `brew upgrade
zig` reverts it (re-run — it is idempotent and refreshes its own backup), and
`mv float.h.qnnt-orig float.h` next to the header undoes it. Drop the script once Zig
ships a Clang whose `float.h` honours the macro.

Nothing else is affected. The Zig, C and Python sides build and test clean without it.

### On a Mac, prefer colima over Docker Desktop

Docker Desktop's LinuxKit kernel is built **without any CAN subsystem** — `ip link add type
vcan` fails there however many capabilities you grant, so `docker/can.sh` cannot run on it
at all. ([linuxkit#3486](https://github.com/linuxkit/linuxkit/pull/3486) has proposed the
kernel options since March 2020 and is still open.)

colima boots an ordinary Ubuntu kernel, where CAN is a loadable module, and every other
harness behaves identically. One command sets it up:

```sh
brew install colima
docker/colima.sh              # start the VM, load the CAN modules, select the context
docker/colima.sh stop         # when you are done
```

Run it again after every `colima start` — kernel modules do not survive a VM restart, and
that is all it does the second time. The two runtimes keep **separate image stores**, so
rebuild after switching contexts. Details and the traps in `docker/README.md`.

## Quick start

```sh
zig build                       # the library, the tools, the Zig examples
zig build test                  # the whole test suite

zig build run-0                 # a node publishing test/topic-a and test/topic-b
zig build ls -- --tree          # what is published
zig build cat -- test/topic-a   # read it
```

## Key concepts

| Concept | What it means |
|---|---|
| **Registry** | Host-local directory on port 2222. Listens on **loopback only** — it carries the human interface and destructive commands. Elected by whichever node binds the port first. |
| **Directory** | `topic -> endpoint`, plus origin, version, subscriber counts. Refreshed by publishers every 2 s; entries expire when refreshes stop. |
| **Topic** | A `/`-separated name. No hierarchy is enforced; the separator is a convention the tools and globs understand. |
| **Direct data plane** | Subscribers dial publishers. The registry never carries a message. |
| **Local sockets** | On one host, subscribers reach publishers over a Unix socket; between hosts, over TCP. A failed socket falls back to TCP. |
| **Procedure** | A name in the same directory, marked as request/reply rather than a stream. One connection per call; a requester dials the responder directly, as a subscriber dials a publisher. |
| **Federation** | Registries exchange directories over port 2223, gated by `QNNT_CLUSTER_KEY`. Entries carry their origin and version so merges converge without a coordinator. |
| **Warm standby** | Every node keeps a mirrored copy of the directory, so registry takeover is ~0.2 s instead of a rebuild. |
| **Node id** | A random per-process id. Identity for merge rules — never parsed as an address. |

## Features

- Publish/subscribe with no broker and no central process
- **Text** (newline-delimited) or **TOLD frames** (arbitrary bytes) per topic
- **Glob subscriptions** — `subscribePattern("bus/*")` joins matching topics as they appear
- **Callback or queue** delivery; the queue is what the managed-runtime bindings use
- **Per-topic teardown** — `removePublisher` / `removeSubscriber` stop one topic, node stays up
- **Request/reply** — `addResponder` + `request`, with a non-blocking `requestBegin` that returns a ticket
- **Events**: subscriber connected/disconnected, publisher connected/disconnected/stale/resumed
- **Federation** across hosts, any topology, with observed-address substitution
- **Registry failover** with a warm directory mirror
- **Forwardable publisher ports** (`QNNT_PUBLISHER_PORTS`) for firewall and WireGuard setups
- Realtime options on Linux: `SCHED_FIFO` priority, `mlockall`
- One implementation: every binding calls the same Zig core

## TOLD, and what it is for

**[TOLD](https://github.com/gattoarancione/told)** (Typo-Length Data) is the binary format
qnnt uses for structured payloads. It began here as qnnt's TLD and is now a project of its
own, with its own specification and roadmap; qnnt takes it as the `deps/told` submodule. A
frame is one header byte — high nibble type, low nibble modifier — then an optional length
and the data.

It exists because a topic carrying arbitrary bytes cannot be newline-delimited: a CAN
payload or a depth frame contains `0x0A` as freely as any other byte. So framing is a
property of the **topic**, chosen when subscribing:

| | Use |
|---|---|
| `subscribe` | newline-delimited text |
| `subscribeFrames` | TOLD frames — length-prefixed, any bytes |

Decoding is **zero-copy and allocation-free**: `decode` returns a frame borrowing your
bytes, and containers are walked with iterators. Zig code gets it as `Qnnt.Told`; C and
C++ include `told.h` / `told.hpp` and link `libtold` beside `libqnnt_c`; Python uses the
`told` package, bundled in qnnt's wheel.

Every node on a bus must speak the same TOLD version. qnnt follows TOLD 1.1, whose floats
omit their trailing zero bytes, and a node built on qnnt's old TLD (TOLD 1.0) rejects such
a frame — so upgrade all nodes together.

Structs map to TOLD by name in every language — `TOLD_DEFINE_MAP(a, b, c)` in C++,
`@typeInfo` in Zig, dataclasses in Python. Cross-language agreement is pinned by **golden
frames**: TOLD's own `src/testdata/interop.tld`, and qnnt's example frames in
`examples/*/testdata/`, bytes packed by Zig and unpacked and checked by the other side, so
a renamed field fails a test instead of silently arriving as a default.

## The four languages

Same core, same wire, same `QNNT_*` variables.

| | Zig | C | C++ / Qt | Python |
|---|---|---|---|---|
| start | `Qnnt.run()` | `qnnt_init()` | `node->start()` | `qnnt.Node()` |
| publish | `runPublisher` / `publish` | `qnnt_publisher_start` / `qnnt_publish` | `addPublisher` / `publish` | `publisher` / `publish` |
| subscribe (text) | `subscribe` | `qnnt_subscribe` | `addSubscriber` | `subscribe` |
| subscribe (frames) | `subscribeFrames` | `qnnt_subscribe_frames` | `addSubscriber(…, Frames)` | `subscribe(…, frames=True)` |
| subscribe (glob) | `subscribePattern` | `qnnt_subscribe_pattern` | `addSubscriberPattern` | `subscribe_pattern` |
| receive | handler callback | callback or `qnnt_poll` | `messageAvailable` signal | `poll()` / `stream()` |
| pack a struct | `told.packTo` | encoder calls | `publishPacked` | `publish_object` |
| match a topic | `qnnt.topics.globMatch` | `qnnt_topic_matches` | `qnnt_topic_matches` | `topic_matches` |
| config | `configureFromEnvironment` | `qnnt_configure_from_environment` | `configureFromEnvironment` | automatic |

Notes that matter:

- **Python and Qt use the queue**, not callbacks. Crossing into a managed runtime per
  message costs far more than the copy, and no library thread ever enters your runtime.
- **Glob subscription is a separate call**, never `subscribe` noticing a `*`. It costs a
  registry poll and one connection per match, and nobody who does not ask for it pays.
- `*` **crosses `/`** here, unlike a shell glob: `lidar/*` matches `lidar/helios32/scan`.
- **From another Zig package**, add qnnt to `build.zig.zon` (`.qnnt = .{ .path = "../qnnt" }`)
  and import its module. It arrives with TOLD and qnnt's version already wired, so the
  package needs neither as a dependency of its own:
  ```zig
  const qnnt = b.dependency("qnnt", .{ .target = target, .optimize = optimize }).module("qnnt");
  exe.root_module.addImport("qnnt", qnnt); // @import("qnnt").Qnnt, @import("qnnt").Told
  ```

## Tools

```sh
qnnt-ls                       # every topic, one per line — for a pipe
qnnt-ls --tree                # grouped by '/' segment, for eyes
qnnt-ls 'lidar/*'             # globs. QUOTE THEM.
qnnt-ls --subs test/topic-a   # who is subscribed, as the registry reports it

qnnt-cat test/topic-a         # TOLD frames to stdout
qnnt-cat --text 'bus/*'       # text topics, several at once
qnnt-cat --dump 'can/*' > cap # capture with times and topics
qnnt-cat --restore < cap      # replay at the recorded pace
qnnt-cat --publish t < file   # the other direction

qnnt-perf                     # every topic: rates, sizes, bandwidth, misses — live
qnnt-perf --text 'bus/*'      # text topics; framing is not recorded, so say which
qnnt-perf --duration 10 t     # ten seconds, then the summary
qnnt-perf 'lidar/*' | awk ... # piped: tab-separated records on stdout instead

qnnt-ls 'test/*' | xargs qnnt-cat --text     # they compose
```

Data goes to stdout and notices to stderr, so a redirect carries only payload.
`qnnt-perf` reads that the other way round: at a terminal its table goes to stderr,
and piped it writes records to stdout. Misses are counted from a sequence field in the
payload (`seq`, or `--seq <field>`); a topic without one shows `-`, meaning unknown.

The registry speaks a plain line protocol on 2222 — `nc 127.0.0.1 2222`, then:

```
list · sub <topic> · subs <topic> · pub <topic> <uri> · unpub <topic>
epoch · mirror · port <topic> · peers · status · ping · help · quit
```

## Configuration

All optional, all read by `configureFromEnvironment()` — an explicit call, never implicit.

| Variable | Meaning |
|---|---|
| `QNNT_REGISTRY_PORT` | Host-local registry port (default 2222) |
| `QNNT_REGISTRY_ROLE` | `candidate` (default) or `client` — a client is never elected |
| `QNNT_REGISTRY_MIRROR` | `1` (default) or `0` — keep a warm directory copy |
| `QNNT_ADVERTISE_ADDR` | The address remote subscribers should dial |
| `QNNT_BIND_ADDR` | What publisher sockets bind |
| `QNNT_PUBLISHER_PORTS` | `low-high` — take publisher ports from a forwardable range |
| `QNNT_CLUSTER_KEY` | Enables federation; required for it |
| `QNNT_FEDERATION_PORT` | Federation's port (default 2223, `0` disables) |
| `QNNT_PEERS` | `host[:port],…` to dial; names are resolved through libc |
| `QNNT_RT_PRIORITY` | `SCHED_FIFO` priority for workers (Linux) |
| `QNNT_LOCK_MEMORY` | `1` to pin pages with `mlockall` (Linux) |
| `QNNT_MAX_FRAME_BYTES` | Largest TOLD frame published or accepted (default 16 MiB) |
| `QNNT_HANDLER_STACK_BYTES` | Stack for per-connection and per-request threads (default 16 MiB; at least 128 KiB, rounded up to a page). For small targets |
| `QNNT_LOCAL_SOCKETS` | `1` (default) or `0` — same-host traffic over Unix sockets, remote over TCP |
| `QNNT_SOCKET_DIR` | Where those sockets go (default `/tmp/qnnt-<uid>`, created `0700`) |
| `QNNT_COALESCE` | `1` (default) or `0` — a scheduled publisher writes its small messages up to 32 at a time, flushed before it sleeps |

## Network topologies

The registry is host-local, so "a host" means "a registry". Federation is what joins them,
and the shape is entirely `QNNT_PEERS`.

| Shape | `QNNT_PEERS` | Good for |
|---|---|---|
| **Single host** | — | Processes on one machine. No federation, no configuration. |
| **Star** | leaves name the hub | Simple; the hub is a single point of failure. |
| **Ring** | each names the next | Cheap; convergence pays one relay hop per link. |
| **Mesh** | each names all others | No relay hop, no host on the path between two others. What a broadcast bus looks like. |
| **Hybrid** | a meshed core, leaves onto it | Realistic: a core that must not partition, cheap edges. |

All four are checked across six containers by `docker/federation.sh`, including a real
partition (`docker network disconnect`) and latency/loss with `tc netem`.

**Through a firewall or NAT.** Federation crosses one easily — one well-known port per
host. The data plane does not, because publishers bind ephemeral ports nobody can forward.
Set `QNNT_PUBLISHER_PORTS=2300-2399` on every node on the host and one rule covers every
topic; the registry assigns from the range, stickily, so a restarting publisher reclaims
its own port. Forward **1:1** — the port travels verbatim through federation even though
the host is substituted. See EXAMPLES.txt §7.

**It does not make those sockets safe to expose.** The data plane authenticates nobody:
whoever reaches a publisher port reads every message on that topic. The range is for the
inside of a tunnel, or a segment you already trust — `SECURITY.txt`.

## Examples

| Path | What it shows |
|---|---|
| `examples/mesh/` | The same struct published by five languages, each verifying the other four |
| `examples/can/` | A **CAN gateway mesh**: SocketCAN bridged across hosts on topic patterns, classic and CAN FD, with a Qt station |
| `examples/dirigera/` | An IKEA DIRIGERA hub: TLS + OAuth bridge, and a QML control station |
| `examples/ugv/` | A real robot over Socket.IO, with a QML pilot and a watchdog |
| `examples/zed/` | A depth camera: shared memory, a bridge, a QML viewer |
| `examples/lidar/` | Two LiDAR protocols behind one topic shape |
| `examples/federation/` | Every topology, on loopback |
| `examples/registry/` | Registry failover, measured |
| `examples/cpp_logic_test.cpp` | The Qt-free C++ logic, 165 checks |

Full walkthroughs, with the reasoning behind each decision: **`EXAMPLES.txt`**.

## Documentation

| File | What it is |
|---|---|
| `EXAMPLES.txt` | Every example and subsystem, with the reasoning behind each decision |
| `SECURITY.txt` | The threat model: what qnnt protects, what it does not, and which gaps are decisions. **Read §6 before deploying anything.** |
| `BENCHMARK.txt` | Measured throughput and latency on real hosts and links, with the conditions for each figure |
| `docker/README.md` | The container harnesses, and why they exist |

## Testing

```sh
zig build test                      # unit tests, incl. federation merge logic
zig build cpp-logic                 # C++ logic and cross-language golden frames
zig build python-demo               # the Python package against the built library

docker/colima.sh                    # a Linux VM (Docker Desktop's kernel lacks CAN)
docker/federation.sh                # topologies, partition, across six real hosts
docker/federation.sh netem          # …with latency and packet loss
docker/federation.sh ports          # …with a forwardable publisher port range
docker/can.sh                       # the CAN gateway mesh on real vcan interfaces
```

`docker/README.md` covers the container harnesses and why they exist.

## Layout

```
lib/          the library: qnnt.zig, federation.zig, topics.zig, env.zig
deps/told/    the TOLD codec, a git submodule
src/          the tools: qnnt-ls, qnnt-cat
include/      qnnt.h, qnnt_qt.hpp (told.h and told.hpp come from deps/told/include)
python/       the Python package
examples/     see the table above
docker/       multi-host harnesses
```
