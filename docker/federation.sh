#!/usr/bin/env bash
# Federation across real hosts, in containers.
#
#   docker/federation.sh                  # every topology, then a partition
#   docker/federation.sh ring             # one topology
#   docker/federation.sh mesh partition   # and cut a host out of it
#   docker/federation.sh netem            # latency and packet loss
#   docker/federation.sh ports            # publisher ports from a forwardable range
#
# Six containers on a bridge network, each a host with its own address, all on the default
# ports. What this reaches that examples/federation/topologies.py cannot:
#
#   * observed-address substitution, for real. No node is told its own address, so every
#     entry a peer learns is recorded at the address the peer was REACHED on. On loopback
#     that was untestable -- every address was 127.0.0.1, so a wrong answer looked like a
#     right one. Here a wrong answer is a wrong container.
#   * peers by NAME, resolved through libc against Docker's DNS.
#   * a real partition: `docker network disconnect` removes a host from the network the way
#     a cable does, rather than by killing a process.
#
# Prerequisite: Linux binaries for the container's architecture.
#
#   zig build -Dtarget=aarch64-linux-gnu     # Apple silicon
#   zig build -Dtarget=x86_64-linux-gnu      # Intel, or --platform linux/amd64
set -u

cd "$(dirname "$0")/.." || exit 1
COMPOSE="docker compose -f docker/compose.federation.yml -p qnntfed"
SITES="alpha bravo charlie delta echo zulu"
LINKED="alpha bravo charlie delta echo"     # zulu is the control and joins nothing

pass=0; fail=0
check() {
  if [ "$2" = "1" ]; then echo "  ok    $1"; pass=$((pass+1))
  else echo "  FAIL  $1 ${3:-}"; fail=$((fail+1)); fi
}

# Peers are service names; Docker's DNS resolves them, and the default federation port is
# implied. That is deliberately the same thing an operator would write.
set_topology() {
  unset ALPHA_PEERS BRAVO_PEERS CHARLIE_PEERS DELTA_PEERS ECHO_PEERS
  case "$1" in
    star)   # every leaf dials alpha; alpha dials nobody
      export ALPHA_PEERS="" BRAVO_PEERS="alpha" CHARLIE_PEERS="alpha" \
             DELTA_PEERS="alpha" ECHO_PEERS="alpha" ;;
    ring)   # each dials the next, echo closes the loop
      export ALPHA_PEERS="bravo" BRAVO_PEERS="charlie" CHARLIE_PEERS="delta" \
             DELTA_PEERS="echo" ECHO_PEERS="alpha" ;;
    mesh)   # any to any
      export ALPHA_PEERS="bravo,charlie,delta,echo" \
             BRAVO_PEERS="alpha,charlie,delta,echo" \
             CHARLIE_PEERS="alpha,bravo,delta,echo" \
             DELTA_PEERS="alpha,bravo,charlie,echo" \
             ECHO_PEERS="alpha,bravo,charlie,delta" ;;
    hybrid) # a meshed core, a leaf onto it, and a chain off that leaf
      export ALPHA_PEERS="bravo,charlie" BRAVO_PEERS="alpha,charlie" \
             CHARLIE_PEERS="alpha,bravo" DELTA_PEERS="alpha" ECHO_PEERS="delta" ;;
    *) echo "unknown topology: $1"; exit 2 ;;
  esac
}

# The registry listens on loopback by design, so it is asked from INSIDE the container.
# Mapping the port out would change the thing under test.
topics_at() { $COMPOSE exec -T "$1" /qnnt/bin/qnnt-ls 'fed/*' 2>/dev/null | tr -d '\r'; }
address_of() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "$($COMPOSE ps -q "$1")" 2>/dev/null
}

# What `viewer` would tell a subscriber asking for `subject`'s topic. Asked over loopback
# INSIDE the container, because that is where the registry listens.
resolve_at() {
  $COMPOSE exec -T "$1" sh -c \
    "printf 'sub fed/$2/beacon\n' | nc -q1 127.0.0.1 2222" 2>/dev/null \
    | tr -d '\r' | grep -E '^tcp://|^error' | head -1
}

matrix() {
  echo
  printf "  %-9s" "sees"; for s in $SITES; do printf " %-8s" "$s"; done; echo
  local ok_all=1
  for viewer in $SITES; do
    local seen; seen=$(topics_at "$viewer")
    printf "  %-9s" "$viewer"
    for subject in $SITES; do
      local want=1
      [ "$viewer" = "zulu" ] || [ "$subject" = "zulu" ] && want=0
      [ "$viewer" = "zulu" ] && [ "$subject" = "zulu" ] && want=1
      local has=0
      echo "$seen" | grep -q "fed/$subject/beacon" && has=1
      if [ "$has" = "$want" ]; then printf " %-8s" "ok"
      else printf " %-8s" "XX"; ok_all=0; fi
    done
    echo
  done
  check "every linked host sees every linked topic, and the control stays alone" "$ok_all"
}

# The headline check, and the reason this runs in containers at all.
observed_addresses() {
  echo
  local ok=1 detail=""
  for viewer in $LINKED; do
    for subject in $LINKED; do
      [ "$viewer" = "$subject" ] && continue
      local want; want=$(address_of "$subject")
      local line; line=$(resolve_at "$viewer" "$subject")
      case "$line" in
        "tcp://$want:"*) : ;;
        "") ok=0; detail="$detail $viewer->$subject:none" ;;
        *)  ok=0; detail="$detail $viewer->$subject:$line(want $want)" ;;
      esac
    done
  done
  check "learned endpoints are the peer's real container address, not loopback" "$ok" "$detail"
}

partition() {
  local victim="$1"
  local id; id=$($COMPOSE ps -q "$victim")
  echo
  echo "  cutting $victim off the network -- a cable, not a kill, so the process keeps"
  echo "  running and keeps thinking it is fine"
  docker network disconnect "qnntfed_fed" "$id" 2>/dev/null

  # Long enough to pass fed_serve_until_us (30s), after which a peer stops handing the
  # entry out. It is NOT forgotten yet -- that is 300s -- so `list` still shows it.
  sleep 38
  local still=0
  for viewer in $LINKED; do
    [ "$viewer" = "$victim" ] && continue
    resolve_at "$viewer" "$victim" | grep -q '^tcp://' && still=1
  done
  check "a cut host's topic stops being handed out once its 30s lease lapses"         "$([ "$still" = "0" ] && echo 1 || echo 0)"

  docker network connect "qnntfed_fed" "$id" 2>/dev/null
  echo "  reconnected at $(address_of "$victim"); waiting for it to be re-learned"

  # Polled rather than slept, and the time is reported: measured at about 20s here, and a
  # fixed wait shorter than that reported a failure that was only impatience.
  local waited=0 back=0
  while [ "$waited" -lt 60 ]; do
    sleep 5; waited=$((waited + 5))
    if resolve_at alpha "$victim" | grep -q '^tcp://'; then back=1; break; fi
  done
  check "and is learned again when the network comes back (took ${waited}s)" "$back"
}

# -- latency and loss -------------------------------------------------------------------
#
# Containers on one bridge talk at memory speed, so everything above measures federation on
# a perfect network. netem puts a real one underneath it. The interesting question is not
# whether a delayed host is slower -- of course it is -- but whether a SLOW peer slows down
# everybody else, which is the failure a dead peer cannot produce and the one a timing
# assumption hides behind.

netem_apply() {
  $COMPOSE exec -T "$1" tc qdisc replace dev eth0 root netem $2 >/dev/null 2>&1
}

netem_clear() {
  $COMPOSE exec -T "$1" tc qdisc del dev eth0 root >/dev/null 2>&1
}

netem_clear_all() { for s in $SITES; do netem_clear "$s"; done; }

# Publish something BRAND NEW on alpha and time how long every other linked host takes to
# learn it. A fresh name each time, because a topic already in the directory would measure
# nothing.
#
# The probe publisher carries no cluster key and federation port 0: it is an ordinary
# application on alpha's host, and its topic reaches the others only because alpha's
# registry federates the directory. `docker exec` reaches it over the daemon's channel
# rather than the container network, so the instrument itself is not slowed by the
# condition under test.
converge_time() {
  local tag="probe$1"
  local topic="fed/$tag/beacon"
  local wait_for="${2:-$LINKED}"
  $COMPOSE exec -d -T -e QNNT_CLUSTER_KEY= -e QNNT_FEDERATION_PORT=0 \
    alpha python3 examples/federation/node.py "$topic" >/dev/null 2>&1

  local start; start=$(date +%s)
  local deadline=$((start + 90))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local all=1
    for viewer in $wait_for; do
      topics_at "$viewer" | grep -q "$topic" || all=0
    done
    [ "$all" = "1" ] && { echo $(( $(date +%s) - start )); return; }
    sleep 1
  done
  echo "-1"
}

netem_run() {
  echo
  echo "================================================================"
  echo " latency and loss, on a mesh"
  echo "================================================================"
  set_topology mesh
  $COMPOSE up -d --wait >/dev/null 2>&1 || $COMPOSE up -d >/dev/null 2>&1
  sleep 12
  netem_clear_all

  local n=0
  measure() {
    n=$((n + 1))
    local t; t=$(converge_time "$n")
    # To stderr so the number stays visible: the caller captures stdout to read the
    # value, and a printf on stdout is swallowed by that command substitution with it.
    printf "  %-46s %s\n" "$1" \
      "$([ "$t" = "-1" ] && echo "did not converge in 90s" || echo "${t}s")" >&2
    echo "$t"
  }

  local base; base=$(measure "a perfect network (the baseline)" | tail -1)
  check "converges with no impairment" "$([ "$base" != "-1" ] && echo 1 || echo 0)"

  for s in $LINKED; do netem_apply "$s" "delay 100ms"; done
  local slow; slow=$(measure "100ms added to every host" | tail -1)
  check "converges with 100ms on every link" "$([ "$slow" != "-1" ] && echo 1 || echo 0)"
  netem_clear_all

  for s in $LINKED; do netem_apply "$s" "loss 10%"; done
  local lossy; lossy=$(measure "10% packet loss on every host" | tail -1)
  check "converges through 10% loss (TCP retransmits, it does not lose entries)" \
        "$([ "$lossy" != "-1" ] && echo 1 || echo 0)"
  netem_clear_all

  # The question worth asking, and it has to be asked carefully. One host is made very
  # slow and the others are left alone. Waiting for EVERY host would just measure the slow
  # one -- an 11s answer that says nothing about whether the others were held up, and a
  # check that would pass even if they had been. So the fast hosts are timed on their own,
  # and the slow one is timed separately for contrast.
  netem_apply delta "delay 2000ms"
  local fast_hosts=""
  for h in $LINKED; do [ "$h" = "delta" ] || fast_hosts="$fast_hosts $h"; done

  n=$((n + 1))
  local others; others=$(converge_time "$n" "$fast_hosts")
  printf "  %-46s %s\n" "one host at 2000ms: the four unaffected" \
    "$([ "$others" = "-1" ] && echo "did not converge" || echo "${others}s")" >&2

  n=$((n + 1))
  local laggard; laggard=$(converge_time "$n" "delta")
  printf "  %-46s %s\n" "  and the slow host itself" \
    "$([ "$laggard" = "-1" ] && echo "did not converge" || echo "${laggard}s")" >&2
  netem_clear_all

  # NOT a pass/fail, and read the numbers with care.
  #
  # An earlier version of this script reported that a slow peer cost the others 4-7x their
  # convergence. That was the INSTRUMENT: `qnnt-ls` is itself a qnnt node, so `docker exec
  # <host> qnnt-ls` starts a node that contends for the registry, becomes a standby and
  # pulls a mirror -- and that startup slows down when the host is busy, which a slow peer
  # makes every host. Timing the events inside the system instead (registration to applied)
  # showed no difference at all between healthy and slow.
  #
  # So these numbers include the probe's own cost and are useful for spotting something
  # gross, not for comparing conditions a few hundred milliseconds apart.
  check "everyone still converges with a slow peer present" \
        "$([ "$others" != "-1" ] && [ "$laggard" != "-1" ] && echo 1 || echo 0)"
  printf "  note: these include the probe's own startup, which is not constant across\n"
  printf "        conditions. See the comment here before reading a ratio into them.\n"

  $COMPOSE down --remove-orphans >/dev/null 2>&1
}

# -- the publisher port range ----------------------------------------------------------
#
# Federation crosses a firewall because it needs one well-known port per host. The data
# plane does not, because a publisher takes whatever ephemeral port the OS gives it, and
# nobody can forward a port they cannot predict. QNNT_PUBLISHER_PORTS makes that half
# forwardable too.
#
# What only real hosts can show, and a single machine cannot:
#
#   * the endpoint a PEER would dial carries a port from the range. That is the number
#     that has to appear in a forwarding rule, and it travels through federation.
#   * two hosts run the SAME range at the same time without interfering. The allocator
#     decides what is free from the directory, which holds every peer's entries too --
#     counting those would make each host report itself out of ports while all of them
#     were free, and with one registry per machine that cannot be reproduced locally.

# The port `viewer` would dial for `subject`'s topic, or empty.
port_at() {
  resolve_at "$1" "$2" | sed -n 's|^tcp://[^:]*:\([0-9]*\).*|\1|p'
}

# What this container's registry would assign a topic. The publisher's side of the
# handshake, asked by hand.
ask_port() {
  $COMPOSE exec -T "$1" sh -c "printf 'port $2\n' | nc -q1 127.0.0.1 2222" 2>/dev/null \
    | tr -d '\r' | grep -E '^[0-9]+$' | head -1
}

in_range() {
  [ -n "$1" ] || return 1
  [ "$1" -ge "$PORT_LOW" ] 2>/dev/null && [ "$1" -le "$PORT_HIGH" ] 2>/dev/null
}

ports_run() {
  PORT_LOW=2300
  PORT_HIGH=2309
  export PUBLISHER_PORTS="$PORT_LOW-$PORT_HIGH"

  echo
  echo "================================================================"
  echo " publisher port range $PUBLISHER_PORTS, on a mesh"
  echo "================================================================"
  set_topology mesh
  $COMPOSE down --remove-orphans >/dev/null 2>&1
  $COMPOSE up -d --wait >/dev/null 2>&1 || $COMPOSE up -d >/dev/null 2>&1
  sleep 12

  # 1. Every host put its own publisher inside the range.
  local own_ok=1 own_detail=""
  for s in $LINKED; do
    local p; p=$(port_at "$s" "$s")
    in_range "$p" || { own_ok=0; own_detail="$own_detail $s:${p:-none}"; }
  done
  check "every host's publisher took a port from the range" "$own_ok" "$own_detail"

  # 2. THE ONE THAT MATTERS: what a peer would dial is a range port, not an ephemeral one.
  #    A forwarding rule is written against this number.
  local fed_ok=1 fed_detail=""
  for viewer in $LINKED; do
    for subject in $LINKED; do
      [ "$viewer" = "$subject" ] && continue
      local p; p=$(port_at "$viewer" "$subject")
      in_range "$p" || { fed_ok=0; fed_detail="$fed_detail $viewer->$subject:${p:-none}"; }
    done
  done
  check "the port a PEER would dial is in the range, so it is forwardable" "$fed_ok" "$fed_detail"

  # 3. Hosts do not eat each other's ranges.
  #
  #    Every site landing on the same low port is NOT evidence of this: each allocates at
  #    startup, before federation has taught it anything, so a broken allocator would give
  #    the same answer. The first version of this check did exactly that and passed with
  #    the accounting deliberately broken.
  #
  #    So spread alpha across several slots, wait until bravo has LEARNED them, and only
  #    then ask bravo for a new port. Alpha's 2301-2303 are in bravo's directory by that
  #    point; if they counted as holding a port on bravo, bravo would skip past them.
  local ports=""
  for s in $LINKED; do ports="$ports $(port_at "$s" "$s")"; done
  echo "  each host's own publisher port:$ports"

  for i in 1 2 3; do
    $COMPOSE exec -d -T alpha python3 examples/federation/node.py "fed/fill$i/beacon" \
      >/dev/null 2>&1
  done

  local waited=0 learned=0
  while [ "$waited" -lt 60 ]; do
    learned=1
    for i in 1 2 3; do
      topics_at bravo | grep -q "fed/fill$i/beacon" || learned=0
    done
    [ "$learned" = "1" ] && break
    sleep 2
    waited=$((waited + 2))
  done
  check "bravo learned the three extra topics alpha placed in its own range" "$learned"

  # Bravo holds one local port (2300), so its next free is 2301 -- the very port alpha is
  # using and bravo can see. An allocator counting peers' entries would answer 2304.
  local next; next=$(ask_port bravo "fed/probe/new")
  check "a host allocates around ITS OWN ports, not its peers'" \
    "$([ "$next" = "2301" ] && echo 1 || echo 0)" \
    "(bravo offered ${next:-none}; 2301 is its own next free, 2304 means it counted alpha's)"

  # 4. And it is still a working mesh, not just a well-numbered one.
  matrix
  observed_addresses

  $COMPOSE down --remove-orphans >/dev/null 2>&1
  unset PUBLISHER_PORTS
}

run_topology() {
  local name="$1"
  echo
  echo "================================================================"
  echo " $name, across six hosts"
  echo "================================================================"
  set_topology "$name"
  $COMPOSE up -d --wait >/dev/null 2>&1 || $COMPOSE up -d >/dev/null 2>&1
  sleep 12
  for s in $SITES; do printf "  %-8s %s\n" "$s" "$(address_of "$s")"; done
  matrix
  observed_addresses
  [ "${2:-}" = "partition" ] && partition delta
  $COMPOSE down --remove-orphans >/dev/null 2>&1
}

if [ ! -f zig-out/bin/qnnt-ls ]; then
  echo "no zig-out/bin -- build Linux binaries first:"
  echo "  zig build -Dtarget=aarch64-linux-gnu    # or x86_64-linux-gnu"
  exit 2
fi
if ! file zig-out/bin/qnnt-ls | grep -q ELF; then
  echo "zig-out/bin holds host binaries, not Linux ones. Rebuild with:"
  echo "  zig build -Dtarget=aarch64-linux-gnu    # or x86_64-linux-gnu"
  exit 2
fi

echo "building the image"
docker build -q -f docker/Dockerfile.linux-test -t qnnt-fed . >/dev/null || exit 1

# Fail here, with a sentence, rather than as six containers that exit instantly. The usual
# cause is binaries cross-compiled for the wrong architecture -- the image inherits the
# host's, so an Intel build under an arm64 daemon runs nothing.
if ! docker run --rm --entrypoint /qnnt/bin/qnnt-ls qnnt-fed --help >/dev/null 2>&1; then
  echo
  echo "the binaries in the image do not run there. Almost always the architecture:"
  echo "  host arch:   $(uname -m)"
  echo "  image arch:  $(docker run --rm --entrypoint uname qnnt-fed -m 2>/dev/null)"
  echo "  binary:      $(file -b zig-out/bin/qnnt-ls | cut -d, -f1-2)"
  echo
  echo "rebuild to match, then run this again:"
  echo "  zig build -Dtarget=aarch64-linux-gnu     # arm64 images, e.g. Apple silicon"
  echo "  zig build -Dtarget=x86_64-linux-gnu      # amd64 images"
  exit 2
fi

WHAT="${1:-star ring mesh hybrid}"
EXTRA="${2:-}"
if [ "$WHAT" = "netem" ]; then
  netem_run
elif [ "$WHAT" = "ports" ]; then
  ports_run
else
  for t in $WHAT; do run_topology "$t" "$EXTRA"; done
fi

echo
echo "================================================================"
echo "  $pass passed, $fail failed"
[ "$fail" = "0" ] || exit 1
