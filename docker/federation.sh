#!/usr/bin/env bash
# Federation across real hosts, in containers.
#
#   docker/federation.sh                  # every topology, then a partition
#   docker/federation.sh ring             # one topology
#   docker/federation.sh mesh partition   # and cut a host out of it
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
for t in $WHAT; do run_topology "$t" "$EXTRA"; done

echo
echo "================================================================"
echo "  $pass passed, $fail failed"
[ "$fail" = "0" ] || exit 1
