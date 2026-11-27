# qnnt adaptive local transport — design

Nov 26, 2026, updated Nov 27, 2026 with the i.MX8M Plus results · Claudio Russo

## Summary

Local topics stay on Unix sockets until a message reaches 16 KiB; from then on that topic moves, for good, to a shared-memory record ring that subscribers read in place. Remote subscribers keep using TCP throughout.

The split follows the measurements. Below about 4 KiB a ring costs the same CPU and latency as a socket, because waking the reader dominates. On the target, an i.MX8M Plus, the ring wins from 4 KiB with four subscribers and from 16 KiB with one, using a third of the socket's CPU from 64 KiB up. A mixed topic of small telemetry and large snapshots runs 3.4× faster under the adaptive policy than on sockets there. Small messages are served by write coalescing instead, which qnnt 0.2.0 already ships for scheduled publishers.

The handover is one-way per topic, ordered by a marker in the subscriber's own stream, and was verified exactly-once across 200 up/down cycles with four subscribers on macOS and Linux.

## Background and evidence

Today a publisher listens on TCP and on a Unix socket; a same-host subscriber connects over the Unix socket and the publisher writes every message to every subscriber, one write each (`publishAll`). Delivery is lossless with backpressure: a slow subscriber blocks the publisher, and a broken one is dropped. That cost grows with message size and with the number of local subscribers.

The design rests on three benchmarks, all in `bench/` with raw tables beside them:

- **`shmbench` 6.2 MB frames** — a latest-wins ring cut 30 Hz CPU from 38% to 7–26% (Mac) and 30% to 16–28% (Linux VM) with four subscribers.
- **`shmbench sweep`** — 64 B to 8 MiB, one and four subscribers, Unix socket vs a lossless record ring with copy-out or in-place reads. Results in the chart below.
- **`shmbench handover`** — the adaptive policy itself on three workloads; ordering checked on every message, with the checker mutation-tested.

The Linux figures in this section come from a 4-vCPU colima VM on an M4 Pro, and Mac aggregates above DRAM bandwidth are cache effects. The target's own figures, which set the threshold, follow in "On the target".

**From 64 KiB the ring uses about half the CPU; below 4 KiB it saves nothing.** CPU at a paced rate, 4 subscribers, Linux VM: 10,000 messages/s up to 16 KiB, then 200 MB/s. Source: `shmbench sweep`, colima Linux VM, 4 vCPU, kernel 6.8, 26 Nov 2026.

| Message size | 64 B | 256 B | 1 KiB | 4 KiB | 16 KiB | 64 KiB | 256 KiB | 1 MiB | 4 MiB | 8 MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Unix socket | 15% | 16% | 16% | 22% | 35% | 38% | 51% | 46% | 33% | 32% |
| Shared-memory ring | 16% | 17% | 17% | 18% | 25% | 26% | 22% | 20% | 16% | 19% |

In the VM the rows part between 16 and 64 KiB. On the target they part sooner, which is why the threshold is 16 KiB.

The socket's CPU climbs with message size while the ring's stays near flat; the threshold sits where the gap opens. With one subscriber the throughput gain is smaller (1.15–1.3×), but from 256 KiB CPU still drops by about a third (26% to 17%) and latency by half or more.

### On the target

Engicam SmarCore i.MX8M Plus: 4× Cortex-A53 up to 1.6 GHz, 1.9 GB, kernel 6.1.36, `ondemand` governor. Paced CPU (10,000 messages/s up to 16 KiB, then 200 MB/s) and median latency, 4 subscribers, 26 Nov 2026. Tables in `bench/*-imx8mp.txt`.

| Message size | 64 B | 1 KiB | 4 KiB | 16 KiB | 64 KiB | 256 KiB | 1 MiB | 8 MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Unix socket, CPU | 65% | 74% | 88% | 155% | 246% | 231% | 226% | 216% |
| TCP, CPU | 78% | 41% | 67% | 181% | 228% | 189% | 193% | 180% |
| Ring, in place, CPU | 67% | 71% | 71% | 89% | 75% | 70% | 74% | 84% |
| Ring, copy-out, CPU | 67% | 74% | 81% | 104% | 107% | 134% | 137% | 178% |
| Unix socket, median latency | < 33 µs | < 33 µs | < 66 µs | < 66 µs | < 524 µs | < 1 ms | < 4.2 ms | < 34 ms |
| Ring, in place, median latency | < 33 µs | < 33 µs | < 33 µs | < 33 µs | < 66 µs | < 262 µs | < 1 ms | < 4.2 ms |

What the target changes:

- **The crossover is lower than in the VM.** Every copy goes to DRAM on the A53, so the ring pays from 4 KiB with four subscribers and from 16 KiB with one. The default threshold is 16 KiB, where it wins on every measure.
- **Reading in place is required, not optional.** Copying records out costs about twice the CPU of reading in place with four subscribers from 64 KiB up: 178% against 84% at 8 MiB.
- **The downgrade must not wait.** Draining a full ring before handing back stalled the publisher for up to 11.4 ms here, against 0.85 ms in the VM. See Downgrade.
- **Ordering held:** 200 up/down cycles with four subscribers, every message exactly once, in order.
- **TCP is slow at mid sizes for a different reason:** qnnt leaves Nagle's algorithm on, which delays 1–16 KiB messages by 0.5–1 ms at this rate. That concerns remote subscribers and is left to its own change.

## Goals and non-goals

Goals:

- Large messages to local subscribers cost one write by the publisher, however many subscribers read them.
- No change for callers: same API, same lossless delivery, same order within a topic.
- Small-message topics keep exactly today's path and performance.
- Every failure falls back to the socket path rather than losing data.
- Works on 32-bit targets, riscv32 included, and within a memory budget on the i.MX.

Non-goals:

- Faster small messages through the ring. The sweep found no gain below 4 KiB at realistic rates, and busy-polling would cost a core per subscriber. Small messages are served by write coalescing instead: qnnt 0.2.0 merges a scheduled publisher's small messages into shared writes, which took 64 B frames over a Unix socket from 205k to 848k per second on the target. Direct `publish()` calls are not coalesced yet.
- Unordered delivery. Every path is one ordered stream; revisit only with a multi-path or datagram transport.
- Zero-copy for Python and Qt. Both copy into their queues by design; they gain the saved kernel copies only.
- Anything across hosts. Remote traffic stays TCP, and ring details are never federated.

## Design: selection and handover

The publisher decides, per topic, from the size of the message it is about to send; each subscriber then follows the markers in its own stream.

A topic moves to the ring once, and back only to free memory:

```
                     message over half the ring:
                     hand back, then a bigger ring
                            +-----+
                            |     |
                            v     |
+-------------------+  message of 16 KiB or more   +----------------------+
|    Unix socket    | ---------------------------> |  Shared-memory ring  |
|  every topic      |     TO_RING + descriptor     |  one write, read in  |
|  starts here; one |                              |  place; 8x largest   |
|  write per        | <--------------------------- |  message, >= 4 MiB   |
|  subscriber       |     quiet window passes:     |                      |
+-------------------+   TO_SOCKET, drain, unmap    +----------------------+

Remote subscribers stay on TCP throughout; older or opted-out local subscribers stay on the socket.
```

Each arrow is a marker in the subscriber's own stream, which is what keeps every message in order across it.

### Who uses the ring

| Subscriber | Path |
| --- | --- |
| Remote | TCP, always |
| Local, current version, can map the segment | Unix socket, then the ring once the topic upgrades |
| Local, older version, opted out, or the mapping failed | Unix socket, always |

The publisher serves both groups at once: ring readers through the ring, everyone else with today's per-subscriber writes.

### Upgrade

1. A message of at least the threshold (default 16 KiB) is about to be published.
2. The publisher creates a segment — `memfd_create` on Linux, `shm_open` plus an immediate unlink on macOS — sized at 8× the largest message seen, 4 MiB minimum.
3. It writes a TO\_RING item down each ring-capable subscriber's socket, with the segment's descriptor attached (SCM\_RIGHTS).
4. Only then does it publish the triggering message, into the ring. No large message crosses a ring reader's socket.

### Growth

A message larger than half the ring hands back to the socket and immediately upgrades to a ring sized from it. The mechanism is the downgrade followed by the upgrade.

### Downgrade

When no message above a quarter of the threshold has been published for the quiet window, the publisher writes a TO\_SOCKET record into the ring and carries on over the socket at once. The old segment is retired, not waited for: it is unmapped once every reader's position has passed the TO\_SOCKET record, which the publisher checks as it goes. This exists to return memory, not for speed: small messages cost the same on the ring.

The first prototype waited for every reader to drain before carrying on, and on the target that stalled the publisher for up to 11.4 ms when the ring was full. Not waiting changes nothing about order: messages sent after TO\_SOCKET wait in each subscriber's socket buffer until it has finished the ring. Growth retires its old ring the same way.

### Why order holds

A subscriber reads exactly one path at a time and moves only on a marker. Everything before TO\_RING arrived on the socket; everything after it is in the ring. Everything before TO\_SOCKET is in the ring; everything after it is on the socket, where it waited in the kernel buffer while the subscriber finished the ring. No message can be read on the wrong side of a marker, so no reordering is possible and none needs repairing.

### Why not per message, or by median

The costs are lopsided: a large message on the socket is 1.4–2.9× slower, a small one on the ring costs nothing extra. Flipping back for small messages gains nothing and adds handovers. A median ignores exactly the messages that matter: in the mixed workload (256 B with a 4 MiB snapshot every 100th) the median stays small, yet `auto` ran 97k messages/s per subscriber against 31k on sockets.

## The ring

One ring per upgraded topic: a single contiguous buffer of variable-length records, written once by the publisher and read in place by every subscriber. Records are freed in the order they were written, so it never fragments and needs no slab, buddy allocator or reference counts.

### Layout

| Part | Contents |
| --- | --- |
| Control block (4 KiB) | publisher's head position; a sleeping flag for the publisher; per subscriber a read position and a sleeping flag, each on its own cache line |
| Data (power of two, ≥ 4 MiB) | records of: length u32, flags u32, sequence u64, ready time u64, payload, padded to 8 bytes |
| Wrap marker | a length of 0xFFFFFFFF where a record would not fit before the end; readers skip to offset 0 |

Flags carry END and TO\_SOCKET; data records carry none.

### Reclamation

A subscriber reads a record in place, runs the callback, then advances its position. The publisher may reuse bytes once every live subscriber's position is past them. This is safe zero-copy because qnnt's callback contract already says a message is valid only during the call. A full ring blocks the publisher, the same backpressure a slow socket subscriber exerts today.

Reading in place is the default and is what the target needs: copying each record out before the callback cost about twice the CPU on the A53 with four subscribers from 64 KiB up.

### Wakeups

An eventcount: a subscriber with nothing to read sets its sleeping flag, re-checks the head, and only then blocks on its socket; the publisher sends a bell item only to subscribers whose flag is set. A busy stream therefore makes no system calls. A publisher facing a full ring sleeps the same way on the subscribers' sockets.

### Sizing and memory

The ring is 8× the largest message seen, rounded up to a power of two, minimum 4 MiB: 64 MiB for 8 MiB frames. That matters on the i.MX, and more with `QNNT_LOCK_MEMORY`, so a per-topic cap is needed (Open questions). The lazy downgrade returns the memory when large messages stop.

### 32-bit targets

Positions must be shared across processes as atomics. riscv32 has no 64-bit atomic, and qnnt's `Atomic64` fallback adds a lock byte that would change the shared layout. Positions are therefore 32-bit offsets with wrap-around comparison, which bounds a ring at 2 GiB.

## Configuration and API

The defaults need no configuration; every knob follows the existing pattern of an environment variable plus a setter in each binding, refused once the node runs. The names below are proposals.

| Setting | Default | Environment | Meaning |
| --- | --- | --- | --- |
| Ring threshold | 16 KiB | `QNNT_RING_THRESHOLD` | First message at or above it upgrades the topic; 0 = never use rings |
| Quiet window | 60 s | `QNNT_RING_QUIET_MS` | No message above threshold/4 for this long returns the ring |
| Ring memory cap | open | `QNNT_RING_MAX_BYTES` | Upper bound per ring; a message that cannot fit stays on the socket |
| Accept rings | on | `QNNT_RING` | A subscriber that turns it off ignores TO\_RING and stays on the socket |

Per topic, at publisher creation, a mode overrides the global threshold:

- `auto` with its own threshold (the default behaviour);
- `always` — upgrade before the first message, for topics known to be large, such as a camera;
- `never` — stay on sockets.

The delivery settings follow the same pattern: `block` on each binding's publisher call, `delivery` on each subscribe call, with `QNNT_DELIVERY` as the process-wide default for subscriptions.

Bindings follow `setLocalSockets`: `Qnnt.setRingThreshold` in Zig, `qnnt_set_ring_threshold` in C, `QnntNode::setRingThreshold` in Qt, `ring_threshold=` on Python's `Node`, plus a per-topic mode argument on each binding's publisher call. Callers see no other change: callbacks receive the same borrowed slice, now pointing into the ring, and queued deliveries copy as before.

Ring state should be visible: `subs` marks ring readers, `qnnt-perf` gains a transport column, and an event reports each upgrade and downgrade.

## Delivery semantics

The publisher declares whether it may be blocked; each subscriber chooses whether it needs every message or only the newest. Ordering is not a setting: every qnnt path is one ordered stream, and a lossy reader only ever skips forward.

| Side | Setting | Values |
| --- | --- | --- |
| Publisher, per topic | `block` | `allowed` (default, today's behaviour) or `never` (sensors, which cannot be throttled) |
| Subscriber, per subscription | `delivery` | `strict` (every message, in order, with backpressure) or `keep_last(n)` (the newest n, oldest dropped) |

`keep_last(1)` is latest-wins. Which pairs work:

|  | `strict` subscriber | `keep_last(n)` subscriber |
| --- | --- | --- |
| `block = allowed` | today: the subscriber can slow the publisher | never slows the publisher; skips what it cannot keep up with |
| `block = never` | refused at connect, with an event naming the reason | latest-wins sensor delivery |

The refusal is deliberate: a strict subscriber silently downgraded would lose data while believing it had all of it.

### Why this is worth having before the ring

`publishAll` writes to each subscriber in turn, blocking. One stalled subscriber — a viewer on poor Wi-Fi — therefore stalls the publisher and every other subscriber of the topic. `keep_last` on the socket and TCP paths removes that, independently of shared memory.

### How each path implements it

- **Socket or TCP, `keep_last`:** non-blocking writes, plus one pending newest-message slot per subscriber, overwritten while its socket is full. A message already partly written is always finished, so framing stays intact.
- **Ring, `strict`:** the record ring described above.
- **Ring, `keep_last`, beside strict readers:** lossy readers' positions do not hold back reclamation. A lossy reader the publisher has overtaken jumps to the newest record. It must copy the record out and validate it afterwards — the latest-wins `copy` mode in shmbench — because reading in place is unsafe behind a callback without slot pinning.
- **Skips are visible:** every message carries a transport sequence number (next section), so a subscriber and `qnnt-perf` can count exactly what `keep_last` dropped.

## Connect handshake and registry advertisement

Each connection is negotiated by a handshake between subscriber and publisher; the registry only advertises what a topic offers. The handshake is authoritative, the advertisement a hint.

### Why negotiation stays out of the registry

- Delivery mode and ring capability belong to one connection, and the registry never sees connections.
- Registry entries refresh every 2 s, a failover serves a mirrored copy, and federated entries come from other hosts: semantics must be right from a connection's first message, not eventually.
- The ring's descriptor can only travel over the subscriber's own socket.
- Remote subscribers ask their own host's registry, so anything negotiated there would have to be federated and versioned across hosts.

### The advertisement

Optional tokens after the URIs in a registration, ignored by older registries and subscribers exactly as the `unix://` token is:

```
pub cam/front tcp://10.0.0.4:5101 unix:///tmp/qnnt-1000/3f9a-0.sock v=2 framing=told block=never
```

It tells a new subscriber whether to handshake at all, lets `qnnt-ls` and `qnnt-perf` show a topic's semantics before connecting — `framing` ends `qnnt-perf`'s text-or-TOLD guess — and lets a strict subscriber report a `block=never` topic before it dials.

### The handshake

One round trip per connection, which happens rarely.

| Message | Direction | Carries |
| --- | --- | --- |
| `hello` | subscriber to publisher | magic and version; delivery mode; ring capable; expected framing |
| `welcome` | publisher to subscriber | version; accepted mode; sequence numbers on |
| `refuse` | publisher to subscriber | the reason, such as strict on a `block=never` topic |

After `welcome`, every message carries a transport header with its sequence number, which is what makes `keep_last` skips countable. The stream items prototyped in shmbench (length, kind, sequence, time) are a starting point.

### Mixed versions

| Subscriber → publisher | Outcome |
| --- | --- |
| new → new | registry shows `v=2`; hello and welcome |
| new → old | no `v=2`; no hello; a legacy stream, strict |
| old → new | the publisher waits briefly for a `hello` (200 ms proposed), then treats the connection as legacy; only old subscribers pay, once per connection |

## Failure modes, security and compatibility

Every failure ends on the socket path or in a clean disconnect; none loses a message silently.

| Event | What happens |
| --- | --- |
| Segment cannot be created or sized | Topic stays on sockets; a notice says why |
| A subscriber cannot map the segment | It reports back and stays on the socket; the others upgrade |
| A subscriber crashes on the ring | Its socket closes; the publisher drops its position, so it can no longer hold the ring full |
| The publisher crashes | Subscribers see the socket close, unmap, and reconnect as today; the segment is freed with the last mapping, leaving no file behind |
| A slow subscriber | The ring fills and the publisher blocks: today's backpressure, with more buffering |
| A message larger than the cap | That topic hands back to the socket for it |

### Security

The segment has no name: its descriptor travels only over the Unix socket, which a subscriber reaches through the 0700 socket directory. Access therefore follows the same rule as local sockets today — same user, real directory — with nothing new in `/tmp` or `/dev/shm`. A subscriber maps the ring read-only; the control block, where it writes its position, is a separate writable mapping. The TCP endpoint stays open exactly as before, as SECURITY.txt says.

### Compatibility

This mechanism is separate from the codec. Since qnnt 0.2.0 every node on a bus must already run the same TOLD version, because TOLD 1.1 floats are rejected by older decoders; the decision was to upgrade all nodes together rather than negotiate the codec version. The ring adds no new constraint of that kind.

Older subscribers never receive a TO\_RING item, because the publisher upgrades only subscribers that announced ring support in their hello (Connect handshake). Older publishers never send one. A registry needs no change: ring details live entirely between publisher and subscriber. On a registry failover nothing about rings is lost, for the same reason.

## Open questions, validation and rollout

The i.MX run set the threshold at 16 KiB and changed the downgrade; what remains below can be designed in parallel.

### Open questions

- **Rollout default.** Ship rings off by default for one release, or on from the start now that the board results are in? Still open.
- **Memory cap.** What budget per ring, and per node, is acceptable on the i.MX, especially with `QNNT_LOCK_MEMORY`?
- **Legacy wait.** 200 ms for an old subscriber's missing hello is a guess: too short misreads a slow new subscriber as legacy, too long delays every old one.
- **Holding messages past the callback.** If an API ever lets subscribers keep a message, in-order release no longer suffices and a pool with reference counts returns.
- **Quiet window.** 60 s is a guess; the benchmark used 0.25 s and 20 ms to force switches.

### Validation

- [x] Run `shmbench sweep` and `shmbench handover` on the i.MX (26 Nov 2026; `bench/*-imx8mp.txt`)
- [x] Set the default threshold from the i.MX crossover: 16 KiB
- [ ] Downgrade and growth retire the old segment without waiting, and the publisher never stalls on a full ring
- [ ] Library tests: upgrade, growth and downgrade ordering under the existing end-to-end suite, in every binding
- [ ] Failure tests: subscriber killed mid-ring, mapping refused, cap exceeded, publisher killed
- [ ] A 32-bit build with 32-bit positions, on riscv32 under emulation
- [ ] `qnnt-perf` and node-5/node-6 before and after on the board
- [ ] Interop: each pair of old and new subscriber and publisher, over the socket and TCP
- [ ] `keep_last`: a stalled subscriber no longer slows the publisher or its other subscribers, and its skips are counted exactly
- [ ] Refusal: a strict subscriber on a `block=never` topic is refused with its reason

### Rollout

1. Connect handshake, registry advertisement and per-message sequence numbers: the base everything else negotiates on.
2. keep\_last on the socket and TCP paths, which removes the slow-subscriber stall on its own.
3. The strict ring, behind `QNNT_RING_THRESHOLD`, default 0 (off), for one release.
4. The ring on by default once the failure tests are in; the board results are.
5. keep\_last readers on the ring.
