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
