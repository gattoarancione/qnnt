# Plan: spreading the registry across a LAN (and, with care, a WAN)

Today the registry is host-local. Every node on a host contends to bind the registry
port; the winner holds the directory, the rest stand by and take over if it exits. This
plan extends that to a set of hosts, each configured with the addresses of its peers,
exchanging directory contents and propagating changes.

The goal is that a subscriber on host B resolves a topic published on host A and connects
to it without knowing that A is a different machine.

---

## 0. The prerequisite: addresses must be routable

**This is the blocking problem, and it is not the federation protocol.**

Every address in the system is currently hardcoded to loopback:

| place | today | must become |
|---|---|---|
| registry listener | `127.0.0.1:2222` | loopback for local clients; a separate routable listener for peers |
| publisher listeners | `127.0.0.1:0` | bound to `0.0.0.0:0` (or a chosen interface) |
| advertised endpoint | `tcp://127.0.0.1:<port>` | `tcp://<routable addr>:<port>` |
| `registerOnce` / `resolveTopic` | connect `127.0.0.1` | unchanged — these stay local |

Federating the directory before fixing this is actively harmful, not merely useless: host
B would receive `tcp://127.0.0.1:50886` and connect to **its own** loopback. That either
fails or, worse, reaches a *different* publisher that happens to hold that port locally —
silent delivery of the wrong topic's data. Any implementation order must put addressing
first.

Advertised address cannot be reliably auto-detected, and — per §1 — usually does not need
to be. It is an optional override for the cases where observation is wrong or a specific
interface is wanted:

```
QNNT_ADVERTISE_ADDR=10.0.0.7      # what peers and remote subscribers should dial
QNNT_BIND_ADDR=0.0.0.0            # what publishers actually bind (default 0.0.0.0)
```

Unset is the normal case once federation is on: bind `0.0.0.0` and let each observer fill
in the address it reached this host on. No interface guessing, and nothing to get wrong on
a multi-homed or NATed host. Auto-detection was in the first draft of this plan and is now
deliberately absent — a guessed address is a silent data-path failure, and the observer
already knows the right answer.

This phase is worth doing on its own merits: it makes two machines interoperate manually
(publish on A, `nc` A's registry from B, connect by hand) before any federation exists.

---

## 1. Identity is not an address

**Revised after the requirement that a host may bind `0.0.0.0` and have its public
address chosen by a gateway.** An address-derived identity is unworkable there: the node
cannot know its own name, and the name would change whenever the gateway's choice changed.

So identity and reachability are separated:

```zig
const NodeId = [16]u8;   // random per process, printed as 32 hex chars
```

The id names the origin of a directory entry and is what version comparison and loop
suppression key on. Addresses are *routing hints* carried alongside, never identity.

### The address rule: the observer decides

**Host from the connection, port from the entry.**

- When B learns A's entries over a connection **B opened** to `addr_A`, B substitutes
  `addr_A` as the host for A's entries. That address demonstrably works — B just used it.
- When A learns B's entries over a connection **B opened to A**, A takes the host part of
  the accepted socket's peer address. The source *port* is ephemeral and meaningless for
  dialing, so it is discarded; the port always comes from the entry.
- A self-claimed advertise address is used only when the observer has nothing better, and
  an explicitly configured one always wins locally.

A node therefore never has to know its own address for others to reach it. Binding
`0.0.0.0` is the natural default once federation is on, and a gateway is free to choose
whatever public address it likes.

### Reflexive hint

On accept, the federation listener tells the connecting peer what source address it
observed:

```
# observed 203.0.113.5
```

Informational (so it is skipped by anything that does not care), and it gives a node
behind a gateway a way to *learn* its public address — useful for logs, and needed when it
must describe itself to a third party it has not spoken to directly.

### What this does and does not solve

| deployment | works? |
|---|---|
| bound `0.0.0.0`, several interfaces, same LAN | **yes** — observers fill in the address they used |
| 1:1 NAT / address-only translation, ports preserved | **yes** — the public address is whatever the peer dialed |
| public address chosen by a gateway, unknown locally | **yes** — never needed locally |
| NAPT with port translation and no forwarding | **no** — see below |

Under port-translating NAT with no forwarding, inbound connections are impossible at all,
and no amount of address rewriting changes that: the advertised port does not exist on the
outside. Reaching such a node needs either a port mapping (static forward, UPnP/PCP) or a
data plane that reverses the connection or relays it — a different project, and one that
should be a deliberate decision rather than something implied by "works over a WAN".

Chained peers inherit a weaker guarantee: C learning A's entries via B gets *A as B sees
it*, which is correct only if B and C share a routing domain toward A. A full mesh avoids
the question; a chain is fine on one LAN and suspect across gateways.

## 2. Topology: symmetric mesh of host registries

Each host's *elected* registry federates with the registries of its configured peers.
Standby nodes do not federate; if a registry dies, the standby that takes over inherits
the peer list and re-syncs from scratch (cheap: the directory is small and lease-based).

```
   host A                     host B                     host C
 ┌─────────┐  federation    ┌─────────┐  federation    ┌─────────┐
 │registry │◄──────────────►│registry │◄──────────────►│registry │
 └────┬────┘                └────┬────┘                └────┬────┘
      │ loopback                 │ loopback                 │ loopback
   local nodes               local nodes               local nodes
```

Peer lists need not be symmetric or complete — an entry learned from one peer is
re-advertised to the others (with its origin preserved), so a chain converges. A full mesh
just converges in one hop.

Data still flows **publisher → subscriber directly**. The registry federation is a control
plane only, so LAN-wide discovery yields LAN-wide data transfer for free, provided §0 is
done.

---

## 3. Two listeners, not one

Keep the existing loopback registry listener exactly as it is, and add a **separate
federation listener** on a routable address, off unless peers are configured.

Why separate rather than binding the existing port to `0.0.0.0`:

- The human interface (`list`, `subs`, `status`, `history`) and the destructive commands
  (`unpub`) stay reachable only from the host itself. Exposing `unpub` to a LAN is a
  denial-of-service primitive; exposing `pub` is a traffic-hijack primitive (§7).
- The local election semantics are untouched, so nothing already working changes.
- The federation port speaks a smaller, purpose-built command set that can be
  authenticated as a whole.

```
QNNT_FEDERATION_PORT=2223         # 0 or unset = federation disabled
QNNT_PEERS=10.0.0.8,10.0.0.9:2223 # host or host:port, comma-separated
```

---

## 4. Data model changes

`TopicEntry` gains provenance:

```zig
const TopicEntry = struct {
    endpoint: net.IpAddress,
    first_us: u64,
    last_us: u64,
    peers: std.ArrayList(PeerRecord),
    peers_us: u64,
    pending: std.ArrayList(PeerRecord),

    // --- new ---
    origin: HostId,   // whose registry owns this entry; self for local registrations
    version: u64,     // the origin's own last_us at the time it published this state
    learned_us: u64,  // when we learned it, for expiry of remote entries
};
```

`version` is the origin's clock, and is **only ever compared against other versions from
the same origin**. That makes clock skew between hosts irrelevant — no vector clocks, no
NTP dependency. An update is accepted iff `incoming.version > held.version` for that
origin, which is also what suppresses loops in a mesh.

### The conflict question (needs a decision)

Today the directory key is the topic name and there is exactly one endpoint per topic.
Federated, two hosts can legitimately publish the same topic name. Options:

1. **Global uniqueness, deterministic winner** (lowest `HostId` wins). Simple, preserves
   today's `sub` contract, but silently hides a publisher — a misconfiguration that looks
   like "my data sometimes vanishes".
2. **Key by (topic, origin); `sub` returns all endpoints.** Honest and supports
   fan-in/redundancy, but changes the `sub` reply from one line to many, and every
   subscriber must decide which to use.
3. **Global uniqueness, conflict surfaced.** First registration wins; the loser is kept
   and reported as `conflict` in `list`, with a stderr warning on both hosts.

Recommendation: **3** for the first cut. It keeps the wire contract and the subscriber
code unchanged while making the misconfiguration loud, and it leaves room to add 2 later
behind an opt-in. This deserves your call before implementation — it is the only part of
this plan that changes existing semantics.

---

## 5. Propagation

Two mechanisms, because neither alone is sufficient:

**Push on change** (latency). When a local mutation commits — `pub` of a new topic, an
endpoint change, `unpub`, a `report end` that alters subscriber counts — mark the
directory dirty and wake a per-peer sender. Delta only:

```
fed-update <origin> <version> <topic> <uri> <subs>
```

**Periodic anti-entropy** (correctness). Every `federation_sync_interval` (default 5 s),
send a digest so a peer that missed a push, restarted, or healed from a partition
converges without needing reliable delivery:

```
fed-digest <origin> <count> <max_version>     # per origin we hold
fed-pull <origin> [since_version]             # peer asks for what it lacks
```

Digest-then-pull keeps steady-state traffic at O(origins) rather than O(topics), which
matters on a WAN link. Full-state sync on connect.

**Expiry, not tombstones.** Deletion is the hardest part of naive replication, and the
existing design already avoids needing it: publishers refresh every 2 s, and an entry not
refreshed is stale. Extend that to remote entries — an entry whose origin stops refreshing
ages out. So `unpub` needs no distributed delete; it simply stops being refreshed.

Three thresholds, all configurable:

| age since origin's last version | behaviour |
|---|---|
| < `stale_after` (6 s) | live |
| `stale_after` .. `serve_until` (30 s) | reported stale, still served (matches today) |
| > `serve_until` | withdrawn from `sub`, still listed as `expired` for visibility |
| > `forget_after` (5 min) | removed |

Continuing to *list* an expired entry for a while is deliberate: "the topic used to be on
host C, which we can no longer reach" is exactly what an operator debugging a partition
needs to see, and it is information a plain delete throws away.

**Connections.** One persistent TCP per peer with exponential-backoff reconnect, rather
than connect-per-sync. The existing publisher refresh opens a connection every 2 s, and
that churn is what produced the server-side `TIME_WAIT` that once blocked rebinding —
repeating it per peer per 5 s on a WAN would be worse. Persistent sockets are also already
supported by the shutdown machinery (`trackSocket` / `breakLiveSockets` / `joinWorkers`).

---

## 6. Configuration surface

Consistent with the principle already established: **the library takes values, callers
decide where they came from.** Zig 0.16 gives a library no ambient environment access, and
that has proved to be the right shape.

Library (before `run()`):

```zig
pub fn setAdvertiseAddress(addr: []const u8) bool;
pub fn setFederationPort(port: u16) bool;
pub fn addPeer(host: []const u8, port: u16) bool;   // repeatable
pub fn setPeers(specs: []const []const u8) bool;    // "host" or "host:port"
```

C ABI mirrors these; Python exposes them as `Node(advertise_addr=…, federation_port=…,
peers=[…])`. The example programs read the environment and pass it on, as they already do
for `QNNT_REGISTRY_PORT`:

```
QNNT_ADVERTISE_ADDR   QNNT_BIND_ADDR   QNNT_FEDERATION_PORT   QNNT_PEERS
--advertise-addr      --bind-addr      --federation-port      --peers
```

CLI parameters take precedence over the environment, which takes precedence over defaults
— the same order already used for the registry port.

---

## 7. Security: the part that changes character on a WAN

On a single host, the registry is protected by being loopback-only. The moment a port is
routable, two abuses become available to anyone who can reach it:

- **Hijack.** Register `tcp://attacker:1234` for a topic subscribers want. They connect
  and receive attacker-controlled data. The registry is a *trusted* directory, so this is
  the serious one.
- **Denial.** `unpub` a topic, or flood registrations.

Minimum for LAN use:

1. The federation listener accepts **only** federation verbs. No `unpub`, no `list`, no
   human commands. Mutating and inspecting the local directory stays a loopback
   privilege.
2. A **pre-shared cluster key**, required on every federation connection:
   `fed-auth <cluster> <hmac>` over a nonce the listener sends, so the key never crosses
   the wire. `QNNT_CLUSTER_KEY`, no default — federation refuses to start without one.
3. Peer address allow-list: only accept federation connections from configured peers.
   Cheap, and it makes the attack surface the same set as the config.

For WAN, the honest position is that a PSK over cleartext TCP protects integrity of the
*control* plane only, and not confidentiality — and the **data** plane (publisher →
subscriber) has no authentication at all. Anyone who can reach an advertised publisher
port can read that topic. So "transparently on a WAN" should mean **over a VPN or an
SSH/WireGuard tunnel**, with qnnt treating the tunnel as a LAN. Adding TLS to both planes
is a much larger project (certificates, rotation, identity) and should be an explicit
decision, not a side effect of this plan.

I would document that boundary prominently rather than imply WAN-readiness.

---

## 8. Testing without a second machine

Because `HostId` is `advertise_addr:port`, several "hosts" can run on one box by giving
each a distinct registry and federation port, all advertising `127.0.0.1`. Loopback
aliases (`127.0.0.2`, …) give an even closer simulation where the OS allows them.

That makes the interesting cases CI-testable on one machine:

- two hosts, topic on A, subscriber on B — resolves and delivers
- change propagation latency: `pub` on A visible in B's `list` within one push
- partition: block a peer, watch entries go stale → expired → forgotten; unblock, watch
  anti-entropy restore them
- conflicting topic names on two hosts — whichever §4 semantics we choose, asserted
- registry failover *with* federation: kill A's registry, its standby takes over and
  re-syncs; B's view converges
- loop suppression: three hosts in a triangle, one `pub`, assert each entry is applied
  once per host and versions stop advancing

The existing multi-role example programs already give the node behaviour; these tests need
only the port/peer wiring.

---

## 9. A protocol gap to close first

The line protocol has **no response terminator**. Single-line replies (`pub`, `sub`,
`ping`) are unambiguous; multi-line ones (`list`, `help`) are not, so a generic client
cannot tell when a reply ends. Measured cost of the workaround (idle timeout): **81.6 ms
per command versus 0.47 ms** when the reply length is known — 172×.

Federation adds machine-read multi-line replies (`fed-digest`, full-state sync), so this
stops being a nuisance and becomes a correctness requirement. The fix is small and
backward compatible: emit `# end` after every reply. `takeReply` already skips every `#`
line, so existing machine clients are unaffected.

Do this before §5.

---

## 10. Phasing

| phase | content | independently useful? |
|---|---|---|
| **0** | routable addressing: separate bind/advertise, loopback default | **done** |
| **1** | `# end` terminator, banner included | **done** — 81.6 ms → 0.22 ms per command |
| **2** | `NodeId`, `origin`/`version`/`learned_us`/`conflict`, origin column in `list` | **done** |
| **3** | federation listener + peer list + full-state sync on connect and anti-entropy | **first working federation** |
| **4** | push-on-change | latency |
| **5** | PSK auth + peer allow-list + federation-only verb set | required before any untrusted network |
| **6** | `peers` command, expiry states in `list`, partition visibility | operability |
| **7** | WAN notes: tunnel guidance, keepalive tuning, NAT advertise | documentation more than code |

Phases 0–2 are small and touch existing code paths; 3 is the substantial one; 5 should not
be deferred past the first deployment on a shared network.

---

## 11. Decisions needed before implementation

All settled:

1. **Same-topic conflicts:** first registration wins, loser reported. `list` shows
   `CONFLICT` in the state column. *Decided.*
2. **Security:** pre-shared cluster key, with WAN documented as tunnel-only (VPN /
   WireGuard / SSH). TLS is explicitly out of scope. *Decided.*
3. **`subs` federation:** counts federate, detail is proxied to the owning host on demand.
   *Taken as proposed.*
4. **Topology:** design tolerates partial peer lists (entries are re-advertised with origin
   preserved), with the §1 caveat that chained address hints assume a shared routing
   domain. Full mesh recommended across gateways. *Taken as proposed.*
