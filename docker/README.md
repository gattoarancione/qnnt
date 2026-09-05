# Testing the Linux build from macOS

Zig cross-compiles the whole library, so the binaries are built on the host and only
*run* in the container. The image carries no toolchain, and what gets tested is exactly
the artefact that would ship.

    # build Linux binaries (glibc; use -linux-musl with an alpine base instead)
    zig build -Dtarget=x86_64-linux-gnu          # or aarch64-linux-gnu, native on Apple silicon

    docker build -f docker/Dockerfile.linux-test -t qnnt-linux-test .
    docker run --rm qnnt-linux-test

To federate a container node with a node running on the macOS host, publish the
container's port and point it at the host:

    # on the host
    QNNT_CLUSTER_KEY=secret QNNT_FEDERATION_PORT=2223 ./zig-out/bin/qnnt-node-0

    docker run --rm -p 31107:31107 -e HOST_FEDERATION_PORT=2223 qnnt-linux-test

`host.docker.internal` resolves to the macOS host from inside Docker Desktop. Note this
exercises the observed-address path in earnest: the container reaches the host at one
address and the host sees the container at another, and neither has to be told its own.

Match the target to the container's architecture — `aarch64-linux-gnu` for the default
arm64 images on Apple silicon, `x86_64-linux-gnu` with `--platform linux/amd64`.

## Peers by name

`QNNT_PEERS` accepts hostnames as well as addresses, resolved through libc, so the
container can dial the host by the name Docker gives it:

```bash
docker run --rm --entrypoint /bin/bash qnnt-linux-test -c '
  cd /qnnt
  QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31901 QNNT_FEDERATION_PORT=31902 \
    QNNT_PEERS=host.docker.internal:2223 ./bin/qnnt-node-2'
```

Verified this way against a node on the macOS host:

```
federation: synced with host.docker.internal:2223 (192.168.65.254)
  test/topic-a  tcp://192.168.65.254:59366  0  4.0s  9.0s  da628480  live
```

Two things worth noting in that output. The name resolved inside the container, and the
address it resolved to is reported next to it. And the topic the host taught the container
is recorded at a numeric address -- the one the container reached the host on -- which is
the observed-address substitution doing its job: neither side was told its own public
address, and the entry stays dialable by nodes that never heard the name.

---

# Federation across real hosts

Six containers on one bridge network, each a host with its own address. One command:

```bash
zig build -Dtarget=aarch64-linux-gnu     # Apple silicon / arm64 images
# zig build -Dtarget=x86_64-linux-gnu    # amd64 images

bash docker/federation.sh
```

That builds the image, then runs four topologies and, on each, cuts a host off the
network and puts it back:

```
  sees      alpha    bravo    charlie  delta    echo     zulu
  alpha     ok       ok       ok       ok       ok       ok
  ...
  ok    every linked host sees every linked topic, and the control stays alone
  ok    learned endpoints are the peer's real container address, not loopback
  ok    a cut host's topic stops being handed out once its 30s lease lapses
  ok    and is learned again when the network comes back (took 15s)

  16 passed, 0 failed
```

Narrow it down while working on something:

```bash
bash docker/federation.sh ring                # one topology, no partition
bash docker/federation.sh "star mesh"         # two
bash docker/federation.sh hybrid partition    # one, with the cable pulled
```

## Why containers, when there is already a loopback harness

`examples/federation/topologies.py` runs the same four topologies as ports on one
machine, in a couple of minutes and with no Docker. It is the faster check and it stays
the right one for most work. Three things it *cannot* reach:

* **Observed-address substitution.** No node here is told its own address — none sets
  `QNNT_ADVERTISE_ADDR` — so an entry travels with an empty host and the receiver fills
  in the address it was reached on. On loopback every address is `127.0.0.1`, so a wrong
  answer is indistinguishable from a right one. Here a wrong answer is a wrong container,
  and the script checks every learned endpoint against the peer's real address.
* **The default ports.** Every container uses registry 2222 and federation 2223, because
  each has an address of its own. The loopback harness has to give every site different
  ports, which is not how anything is deployed.
* **A partition.** `docker network disconnect` removes a host the way a cable does: the
  process keeps running and keeps thinking it is fine. Killing a process, which is all
  the loopback harness can do, is a different failure.

Peers are also named rather than numbered here (`QNNT_PEERS=alpha,charlie`), which
exercises the libc resolution path an address literal skips.

## What it measured

| | |
|---|---|
| all four topologies converge | every linked host sees every linked topic |
| learned endpoints | the peer's real container address, never loopback |
| a cut host stops being served | inside its 30s lease (`fed_serve_until_us`) |
| and is re-learned after healing | 15–20s |

The recovery time is polled and reported rather than asserted against a fixed deadline.
A 12s wait reported a failure that turned out to be impatience, which is worth knowing
before trusting a red result here.

## Site zulu is the control

It carries the cluster key, has no peers, and nobody dials it. It must see only its own
topic, and nothing may see its topic. Without it, "every host sees every topic" would
equally be the result of a misconfiguration that merged them all — which is the easiest
way for a test like this to pass while proving nothing.

## Changing the shape

The topology is entirely in `*_PEERS` environment variables, so
`docker/compose.federation.yml` never changes. `set_topology` in `docker/federation.sh`
holds the four presets; a fifth is four lines. To add a host, copy a service block, give
it a name, and add it to `SITES` and `LINKED` in the script.

To keep a stack up and poke at it by hand:

```bash
export ALPHA_PEERS="" BRAVO_PEERS=alpha CHARLIE_PEERS=alpha DELTA_PEERS=alpha ECHO_PEERS=alpha
docker compose -f docker/compose.federation.yml -p qnntfed up -d

docker compose -f docker/compose.federation.yml -p qnntfed exec alpha /qnnt/bin/qnnt-ls --tree
docker compose -f docker/compose.federation.yml -p qnntfed exec alpha \
  sh -c "printf 'status\n' | nc -q1 127.0.0.1 2222"

docker compose -f docker/compose.federation.yml -p qnntfed down
```

The registry listens on loopback by design, so it is asked from *inside* a container.
Mapping the port out would change the thing being tested.

## If it does not run

The script checks first and says so, but the usual causes:

* **Architecture.** The image inherits the host's, so an `x86_64-linux-gnu` build under an
  arm64 daemon runs nothing. Rebuild for the container's architecture, or pass
  `--platform linux/amd64` consistently.
* **Stale binaries.** The image copies `zig-out/`; a `zig build` for macOS leaves host
  binaries there and the script will tell you they are not ELF.
* **The entrypoint.** `Dockerfile.linux-test` runs the Linux smoke tests by default, so the
  compose file overrides `entrypoint` — without that every container runs `run-tests.sh`
  and none is a federation site.

## Latency and packet loss

```bash
bash docker/federation.sh netem
```

Puts a real network underneath federation with `tc netem`, on a mesh. Needs `NET_ADMIN`,
which `compose.federation.yml` grants to these containers only.

```
  a perfect network (the baseline)               2s
  100ms added to every host                      1s
  10% packet loss on every host                  9s
  one host at 2000ms: the four unaffected        8s
    and the slow host itself                     21s
```

Each number is how long a brand-new topic published on `alpha` takes to reach every host
being waited for. A fresh name each time, because a topic already in the directory would
measure nothing. The probe publisher carries no cluster key — it is an ordinary
application on alpha's host — and `docker exec` reaches it over the daemon's channel
rather than the container network, so the instrument is not slowed by the condition under
test.

**Latency and loss are unremarkable.** 100ms on every link changes nothing measurable,
and 10% loss costs a few seconds: the exchange is TCP, so loss becomes retransmission
rather than lost entries.

**A slow peer costs nothing measurable — the earlier claim here was wrong.** An earlier
version of this document reported that one slow host cost the others 4–7× their
convergence. That was an artefact of the instrument, not behaviour of the library, and it
is retracted.

The instrument was `docker exec <host> qnnt-ls`, and `qnnt-ls` is itself a qnnt node: it
starts up, contends for the registry port, becomes a standby and pulls a directory mirror.
That startup gets slower when the host is busier, and a slow peer makes every host busier
(connectors re-exchange immediately when the change counter has already moved on). So the
probe timed itself.

Timing the events *inside* the system instead — from the publisher's registration to each
host applying the entry — shows no difference:

```
MESH, registration -> applied
  healthy      bravo=419ms charlie=419ms echo=418ms
  healthy      bravo=83ms  charlie=83ms  echo=83ms
  delta SLOW   bravo=329ms charlie=328ms echo=330ms
  delta SLOW   bravo=145ms charlie=308ms echo=310ms
```

**What the chase did find is a real defect, in relaying.** Only two places called
`notifyChange`: a node's own outbound exchanges, and its own publishers. A host that
learned an entry by being *pushed* to updated its directory and told nobody, so it did not
relay onward until its 5s anti-entropy deadline. One hop hid this completely — in a star or
a mesh every host hears the publisher directly and nothing needs relaying — but a chain
paid it per hop:

```
RING, publisher -> third host
  before   5119ms   1252ms   5597ms     <- the 5s deadline, not a wake
  after     767ms   1050ms   1162ms
```

End to end, the ring in `examples/federation/topologies.py` went from 2.7s to 0.7s, which
is now in line with the star and the mesh. That 2.7s had been sitting in the docs as "the
cost of multi-hop relay" since the topology harness was written; it was this.

That measurement is reported, not asserted. Only "did everyone converge at all" is a
pass/fail, because printing a red FAIL for behaviour nobody has shown to be a defect
trains people to ignore the output.

### Doing your own

```bash
docker compose -f docker/compose.federation.yml -p qnntfed exec delta \
  tc qdisc replace dev eth0 root netem delay 200ms loss 5% duplicate 1%
docker compose -f docker/compose.federation.yml -p qnntfed exec delta \
  tc qdisc del dev eth0 root      # back to normal
```

`netem` also does reordering, corruption and rate limiting; `man tc-netem` has the list.
Note the delay applies to the container's own interface, so it affects both directions for
that host.

## What this still does not cover

Anything about *sustained* behaviour: these runs last minutes, so a slow leak, a
descriptor that is never closed, or an entry that ages out wrongly over hours would not
show. And every container is on one bridge with the same MTU and no middlebox, so nothing
here says anything about a real WAN path, a NAT that rewrites addresses, or a firewall
that drops idle connections.
