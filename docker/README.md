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

## What this still does not cover

Latency and packet loss. Containers on one bridge talk at memory speed, so a peer that is
*slow* rather than absent is untested — which is the condition most likely to expose a
timing assumption. Adding it needs `NET_ADMIN` and `tc`:

```yaml
    cap_add: [NET_ADMIN]
```

```bash
docker compose -f docker/compose.federation.yml -p qnntfed exec delta \
  tc qdisc add dev eth0 root netem delay 200ms loss 5%
```

Nothing here does that yet, and no claim about behaviour under loss should be read into
these results.
