# Receive/transmit: a receiver-paced counterpart to pub/sub

Design proposal, 2026-11-27. Status: draft for review; nothing here is implemented.

## Summary

qnnt gains a second paradigm beside pub/sub. A **receiver** declares a named input and what
it can accept: the framing, the largest message, an optional schema, and how many messages it
will take at a time. **Transmitters** dial it and push, but only as much as the receiver has
granted them. Pub/sub is producer-paced, and every subscriber takes what the publisher sends.
Receive/transmit is consumer-paced: the receiver decides what arrives and how fast.

It fits inputs rather than broadcasts: an actuator taking setpoints, a logger collecting
events from many nodes, a recorder that can only absorb so much. It reuses qnnt's directory,
listeners, local/remote transports and the planned connect handshake. The new parts are a
directory entry kind, a credit-based flow-control protocol, and an exclusive mode with leases
for inputs that must have one controller at a time.

## Why

| | Pub/sub (today) | Receive/transmit (proposed) |
|---|---|---|
| Registers in the directory | the publisher, a producer | the receiver, a consumer |
| Who dials whom | subscriber → publisher | transmitter → receiver |
| Who sets the pace | the producer | **the receiver**, by granting credit |
| Fan | one to many | many to one |
| Order | per topic | per transmitter |

Two things pub/sub cannot express today:

- **A consumer that must not be flooded.** `publishAll` writes to each subscriber in turn,
  blocking. A slow subscriber stalls the publisher and every other subscriber; a fast
  publisher has no way to learn what a consumer can take until its write blocks.
- **An input with a contract.** A motor controller wants exactly one source of setpoints,
  of one schema, no larger than a known size, at most so many in flight. Pub/sub has no
  place to state any of that: a topic is whatever its publisher sends.

Request/reply is the nearest existing shape, and it stays as it is: one request, one reply,
a connection per call. Receive/transmit is a long-lived, one-way stream with flow control
and no reply.

## Goals and non-goals

Goals:

- A receiver states what it accepts; a transmitter that does not match is refused at connect,
  never mid-stream.
- A transmitter can never send more than the receiver has granted, so no receiver is
  overrun and no transmitter stalls another.
- An exclusive mode for inputs that must have one controller at a time, with priority
  takeover and a lease whose expiry the receiver hears about.
- Same reach as pub/sub: local over the Unix socket, remote over TCP, across federated hosts.
- Every binding: Zig, C, C++/Qt, Python. Every tool: `qnnt-ls`, `qnnt-cat`, `qnnt-perf`.

Non-goals:

- Replies or acknowledgements of individual messages. A transmitter that needs an answer
  uses request/reply.
- Persistence or replay. A message the receiver never granted credit for is never sent.
- Ordering across transmitters. Each transmitter's messages arrive in its order; how the
  receiver interleaves several transmitters is not specified beyond fairness.
- Text framing in the first version. Receivers carry TOLD frames only; text can follow.

## The accept contract

A receiver declares, once, at registration:

| Field | Meaning | Default |
|---|---|---|
| `framing` | `told` (text later) | `told` |
| `max_bytes` | largest message accepted | the node's `QNNT_MAX_FRAME_BYTES` |
| `schema` | optional name and version, e.g. `arm.targets/2`, compared as an opaque string | none: any |
| `credit` | messages a transmitter may have in flight | 32 |
| `mode` | `shared` or `exclusive` | `shared` |
| `delivery` | `strict` or `keep_last` | `strict` |
| `lease_ms` | exclusive mode: silence after which the holder loses the input | 500 |

All of it is advertised in the directory, so `qnnt-ls` can show it and a transmitter can
refuse itself before dialling. The receiver enforces it at connect regardless: the
advertisement is a hint, the handshake is the authority.

## Flow control: credit

The core mechanism, and what makes this "push what the receiver can accept".

1. At connect the receiver grants each transmitter an initial window of `credit` messages.
2. Each message the transmitter sends uses one credit. With none left it cannot send.
3. As the receiver's handler consumes messages, the receiver returns credit. It batches the
   grants, returning them once half the window has been consumed, so credit traffic stays
   a small fraction of data traffic.

```
transmitter                                   receiver
    | -- hello {name, schema, priority} -------> |  checks framing, schema, mode
    | <------------------ welcome {credit: 32} -- |
    | -- data #1 ... data #32 ------------------> |  handler runs per message
    |    (window empty: transmit waits)           |
    | <------------------------- credit {16} ---- |  after 16 consumed
    | -- data #33 ... --------------------------> |
```

What a transmitter does with an empty window depends on the call (see API) and the delivery
mode:

- **`strict`:** `transmit` waits for credit up to its timeout; `tryTransmit` returns
  `would_block` at once. Nothing is dropped.
- **`keep_last`:** the transmitter never waits. With no credit it overwrites a single
  pending slot, and sends whatever is newest once credit arrives. The receiver sees only the
  latest value, which is what a setpoint input wants. Skipped messages show as gaps in the
  sequence numbers.

With several transmitters in `shared` mode, each has its own window, so one transmitter's
burst uses only its own credit and cannot starve the others. The receiver serves ready
transmitters round-robin.

## Admission: shared and exclusive

- **`shared`:** any number of transmitters, each with its own window.
- **`exclusive`:** one transmitter holds the input at a time.
  - A second transmitter is refused with `busy`, unless its priority is higher than the
    holder's: then the holder receives `lease_lost {preempted}` and is disconnected, and
    the newcomer takes over.
  - The holder keeps the lease by transmitting or sending a heartbeat at least every
    `lease_ms`. Silence past that raises `lease_expired` on the receiver, which is the
    moment an actuator should go to a safe state, and frees the input for the next
    transmitter.
  - Equal priorities: first come, first served; the holder is never preempted by a peer.

## Wire protocol

Every message on a receive/transmit connection, in either direction, starts with a
16-byte header:

| Bytes | Field |
|---|---|
| 0–3 | payload length, u32 little-endian |
| 4–5 | kind, u16 |
| 6–7 | flags, u16, zero for now |
| 8–15 | sequence number, u64, per direction, starting at 1 |

| Kind | Direction | Payload |
|---|---|---|
| `hello` | T → R | TOLD object: protocol version, receiver name, framing, schema, priority |
| `welcome` | R → T | TOLD object: protocol version, initial credit, `max_bytes`, `lease_ms`, delivery |
| `refuse` | R → T | TOLD object: reason (`schema`, `framing`, `busy`, `too_large`, `version`), detail |
| `data` | T → R | one message: a TOLD frame, at most `max_bytes` |
| `credit` | R → T | u32: messages granted |
| `heartbeat` | T → R | empty: keeps an exclusive lease while there is nothing to send |
| `lease_lost` | R → T | TOLD object: reason (`preempted`, `expired`), then the receiver closes |

Why a header rather than raw TOLD frames as pub/sub uses: control and data share one stream
in each direction, so each message needs a kind; and the sequence number is what makes
`keep_last` skips countable, the same need the adaptive-transport design has. TOLD's
EXTENDED frame was considered for control messages, but TOLD's roadmap notes that EXTENDED is
the one frame a reader cannot measure, which rules it out for a stream.

## Directory and federation

- A new entry kind, `receiver`, beside `topic` and `responder`, registered with a new verb
  carrying the accept contract as tokens, as the `unix://` token is today:

  ```
  rx arm/joint-targets tcp://10.0.0.4:5120 unix:///tmp/qnnt-1000/3f9a-4.sock framing=told max=4096 schema=arm.targets/2 mode=exclusive credit=32
  ```

- `rx-find <name>` resolves it, as `rpc-find` resolves a procedure, and refuses a topic or a
  procedure by name, so a transmitter never dials a publisher.
- Federation carries receiver entries, so a transmitter on another host reaches the
  receiver over TCP. Local-socket paths are never federated, as today.
- **Compatibility trap:** `EntryKind.fromWire` makes an older node read an unknown kind as a
  `topic`. An old node's subscriber could therefore dial a receiver believing it a
  publisher. The receiver refuses any connection whose first bytes are not a `hello`, so the
  mistake ends in a clean refusal; the old subscriber then retries on its usual 2 s cycle.
  Whether to also withhold receiver entries from peers too old to know the kind is an open
  question.

## API

Zig, the reference; the other bindings mirror it.

```zig
// Receiver
try Qnnt.addReceiver("arm/joint-targets", .{
    .max_bytes = 4096, .schema = "arm.targets/2", .credit = 32,
    .mode = .exclusive, .delivery = .keep_last, .lease_ms = 200,
}, onTarget, ctx);            // handler: fn (name, frame: Told.Frame, from: TransmitterInfo, ctx) void
Qnnt.removeReceiver("arm/joint-targets");

// Transmitter
const tx = try Qnnt.openTransmitter("arm/joint-targets", .{ .priority = 10, .schema = "arm.targets/2" });
defer tx.close();
try tx.transmit(frame_bytes, .{ .timeout_ms = 50 });  // strict: waits for credit, or error.TimedOut
switch (tx.tryTransmit(frame_bytes)) { .ok, .would_block => {} }
tx.credit();                  // credit currently available, for a caller pacing itself
```

| Binding | Receiver | Transmitter |
|---|---|---|
| C | `qnnt_add_receiver` with a callback, or a queue drained by `qnnt_poll` | `qnnt_transmitter_open`, `qnnt_transmit`, `qnnt_try_transmit`, `qnnt_transmitter_close` |
| C++/Qt | `QnntNode::addReceiver`, a `messageReceived` signal | `QnntTransmitter` with `transmit()` and a `canTransmit` signal |
| Python | `node.receiver(name, ...)`, then the existing `poll()` / `stream()` | `node.transmitter(name, ...)`, with `transmit()` and `try_transmit()` |

Events, through the existing event handler and queue:

| Event | Where | Meaning |
|---|---|---|
| `transmitter_attached` / `transmitter_detached` | receiver | a transmitter connected or left |
| `lease_expired` | receiver | the exclusive holder went silent |
| `receiver_attached` / `receiver_detached` | transmitter | the input became reachable or was lost |
| `credit_available` | transmitter | a waiting transmitter can send again |
| `transmit_refused` | transmitter | the handshake was refused, with the reason |
| `lease_lost` | transmitter | preempted, or the lease expired |

## Transports

- **Local and remote:** receivers listen on TCP and a Unix socket, exactly as publishers and
  responders do, with the same fallback.
- **Coalescing:** a transmitter with credit for several queued messages writes them together,
  the same mechanism scheduled publishers use.
- **Shared memory, later:** the adaptive-transport ring is one writer, many readers. A
  receiver would need the inverse, a ring the receiver owns and many transmitters write
  into, with credit as the reservation. That is a separate design, after the socket version
  has proven the protocol.

## Failure modes

| Event | Outcome |
|---|---|
| Receiver restarts | Transmitters see the connection close, get `receiver_detached`, and redial on the 2 s cycle; their windows reset at the next `welcome` |
| Transmitter crashes | The receiver frees its window; in exclusive mode the input is free at once, without waiting out the lease |
| Exclusive holder goes silent | `lease_expired` after `lease_ms`; the input is free |
| Higher-priority transmitter arrives | The holder gets `lease_lost {preempted}`; the newcomer is welcomed |
| Message larger than `max_bytes` | Refused locally by `transmit`, never sent; the receiver also closes any connection that sends one |
| Old subscriber dials a receiver | Refused, because it sends no `hello` |

## Security

The same position as the data plane in SECURITY.txt: no authentication of transmitters.
Exclusive mode is not access control: any transmitter that claims a higher priority can
take over. An actuator input reachable from an untrusted network needs the measures
SECURITY.txt describes (a tunnel, a trusted segment), and is the strongest argument yet for
the authenticated data plane that document lists as the main gap. Locally, the 0700 socket
directory limits the fast path to the same user, as for publishers.

## Testing

- Credit: a transmitter never sends past its window, under load and across credit batching;
  a mutation that drops the check must fail a test.
- Fairness: with several shared transmitters, a fast one cannot starve a slow one.
- `keep_last`: a stalled receiver gets only the newest message per transmitter, and the
  sequence gaps equal the skips exactly.
- Exclusive: refusal at equal priority, takeover at higher priority, `lease_expired` after
  silence, immediate release on a crash.
- Compatibility: an old subscriber dialling a receiver is refused cleanly; a receiver entry
  survives federation to a current peer.
- Bindings: the C, C++ and Python demos each run a receiver and a transmitter.
- On the i.MX: an exclusive setpoint receiver fed from a remote transmitter, with latency
  and lease timing measured.

## Phases

1. **Core:** entry kind, listener, handshake, credit, `transmit` and `tryTransmit`; shared
   mode, strict delivery; the credit and fairness tests.
2. **Exclusive mode:** leases, priority takeover, `lease_expired`.
3. **`keep_last` delivery** and refusal on a schema mismatch.
4. **Bindings and tools:** C, C++/Qt, Python; `qnnt-ls` lists receivers and their contract,
   `qnnt-cat --transmit` pushes stdin, `qnnt-perf` reports credit stalls.
5. **Federation and documentation,** and the i.MX run.

## Open questions

1. **Names.** Receiver and transmitter, or another pair such as inlet/outlet or sink/source?
2. **Default mode.** `shared` is proposed, with `exclusive` explicit, since a takeover is a
   safety-relevant choice.
3. **Default transmit behaviour.** Wait for credit with a required timeout, plus
   `tryTransmit` for real-time loops, is proposed.
4. **Credit unit.** Messages are proposed. Bytes suit receivers whose cost is per byte; both
   at once is possible but adds a second window.
5. **Old peers.** Withhold receiver entries from federation peers that do not know the kind,
   or rely on the receiver's refusal?
6. **Text framing.** Needed in the first version, or later?
