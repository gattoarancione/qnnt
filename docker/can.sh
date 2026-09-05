#!/usr/bin/env bash
# A CAN gateway mesh across containers.
#
#   docker/can.sh              # the full thing: vcan interfaces, real CAN frames
#   docker/can.sh wire         # the qnnt half only -- no kernel CAN needed
#   docker/can.sh shell alpha  # a prompt on one gateway, with candump available
#
# Four hosts, two independent buses, no gateway told the name of another. What this checks:
#
#   1. a frame put on one host's vcan0 reaches every other host bridging that bus
#   2. a second bus rides the same mesh and never mixes with the first
#   3. a host bridging only one bus never sees the other, though it is federated with
#      hosts that carry both
#   4. a host outside the cluster key sees nothing, however hard it dials
#   5. one frame in is one frame out -- no relay loop, no amplification
#
# Prerequisites:
#   zig build can -Dtarget=aarch64-linux-gnu    # Apple silicon
#   zig build can -Dtarget=x86_64-linux-gnu     # Intel, or --platform linux/amd64
#
# A KERNEL WITH vcan. Docker Desktop's LinuxKit kernel has no CAN subsystem at all, so 1-5
# cannot run there; `wire` runs the qnnt half of the same checks on any kernel. See
# docker/README.md.
set -u

cd "$(dirname "$0")/.." || exit 1
MODE="${1:-full}"
CAN="docker compose -f docker/compose.can.yml -p qnntcan"
WIRE="docker compose -f docker/compose.can-wire.yml -p qnntcanwire"

pass=0; fail=0; skip=0
check() {
  if [ "$2" = "1" ]; then echo "  ok    $1"; pass=$((pass+1))
  else echo "  FAIL  $1 ${3:-}"; fail=$((fail+1)); fi
}
skipped() { echo "  skip  $1 ${2:-}"; skip=$((skip+1)); }

build_image() {
  [ -x zig-out/bin/qnnt-can-gw ] || {
    echo "no zig-out/bin/qnnt-can-gw -- build the Linux binaries first:"
    echo "  zig build can -Dtarget=aarch64-linux-gnu"
    exit 1
  }
  file zig-out/bin/qnnt-can-gw | grep -q ELF || {
    echo "zig-out/bin/qnnt-can-gw is not a Linux binary. Cross-compile it:"
    echo "  zig build can -Dtarget=aarch64-linux-gnu"
    exit 1
  }
  echo "== building the image =="
  docker build -q -f docker/Dockerfile.linux-test -t qnnt-fed . >/dev/null || exit 1
}

# Whether this kernel can make a vcan interface at all. Asked once, in a throwaway
# container, so the answer is about the kernel and not about anything we started.
have_vcan() {
  # --entrypoint, because the image's ENTRYPOINT runs the smoke tests and a `command` is
  # APPENDED to an entrypoint rather than replacing it. Without this the probe ran
  # run-tests.sh, which exits 0, and the answer was always yes.
  docker run --rm --cap-add NET_ADMIN --entrypoint bash qnnt-fed \
    -c 'ip link add dev __probe type vcan >/dev/null 2>&1 && ip link delete __probe' \
    >/dev/null 2>&1
}

# ---------------------------------------------------------------- the qnnt half

run_wire() {
  echo "== the qnnt half: topics, globs and federation, no kernel CAN =="
  $WIRE down -v --remove-orphans >/dev/null 2>&1
  WIRE_SECONDS="${WIRE_SECONDS:-12}" $WIRE up --abort-on-container-exit >/tmp/canwire.log 2>&1
  $WIRE down -v --remove-orphans >/dev/null 2>&1

  # RESULT alpha bus=powertrain sent=N origins=alpha,bravo,... counts=... malformed=0
  result() { grep -o "RESULT $1 bus=$2 .*" /tmp/canwire.log | tail -1; }
  origins() { result "$1" "$2" | sed -n 's/.*origins=\([^ ]*\).*/\1/p'; }

  local pt_alpha pt_delta body_bravo body_delta zulu_pt
  pt_alpha=$(origins alpha powertrain)
  pt_delta=$(origins delta powertrain)
  body_bravo=$(origins bravo body)
  body_delta=$(origins delta body)
  zulu_pt=$(origins zulu powertrain)

  # 1. every gateway on powertrain reaches every other, including itself: the pattern
  #    matches the topic this node publishes on, which is the documented behaviour.
  check "powertrain reaches all four hosts" \
    "$([ "$pt_alpha" = "alpha,bravo,charlie,delta" ] && echo 1 || echo 0)" \
    "(alpha saw: ${pt_alpha:-nothing})"
  check "a host that joined the mesh is found without being named" \
    "$([ "$pt_delta" = "alpha,bravo,charlie,delta" ] && echo 1 || echo 0)" \
    "(delta saw: ${pt_delta:-nothing})"

  # 2 and 3. the second bus is carried, and only to the hosts that bridge it.
  check "body reaches only the two hosts that bridge it" \
    "$([ "$body_bravo" = "alpha,bravo" ] && echo 1 || echo 0)" \
    "(bravo saw: ${body_bravo:-nothing})"
  check "a host bridging one bus never sees the other" \
    "$([ -z "$body_delta" ] && echo 1 || echo 0)" \
    "(delta saw on body: ${body_delta:-nothing})"

  # 4. the control.
  check "a host outside the cluster key sees only itself" \
    "$([ "$zulu_pt" = "zulu" ] && echo 1 || echo 0)" \
    "(zulu saw: ${zulu_pt:-nothing})"

  # The frame format, across languages: these were packed by Python and checked field by
  # field on the way back in. A rename on either side lands here.
  local bad
  bad=$(grep -c 'malformed=[1-9]' /tmp/canwire.log)
  check "every frame decoded to the declared shape" \
    "$([ "$bad" = "0" ] && echo 1 || echo 0)" "($bad host(s) reported malformed frames)"
}

# ---------------------------------------------------------------- the whole thing

# The SocketCAN calls themselves: open, bind, read, write, and the loopback rule the
# gateway's loop prevention depends on. Run against an interface of its own so it cannot be
# confused by gateway traffic.
run_socket_tests() {
  echo "== the SocketCAN layer =="
  local out
  out=$(docker run --rm --cap-add NET_ADMIN --entrypoint bash qnnt-fed -c '
      ip link add dev vcantest type vcan && ip link set up vcantest &&
      /qnnt/bin/qnnt-can-test' 2>&1)
  if echo "$out" | grep -q "All .* tests passed"; then
    check "socket round trip, 29-bit ids, and no read-back of our own writes" 1
  else
    check "socket round trip, 29-bit ids, and no read-back of our own writes" 0
    echo "$out" | tail -12 | sed 's/^/      /'
  fi
}

run_full() {
  run_socket_tests
  echo
  echo "== gateways on vcan interfaces =="
  $CAN down -v --remove-orphans >/dev/null 2>&1
  $CAN up -d >/dev/null 2>&1 || { echo "  could not start the gateways"; return; }

  # Federation and the first pattern rescan.
  sleep 6
  if ! $CAN logs alpha 2>&1 | grep -q "publishes can/powertrain/alpha"; then
    check "alpha bridged its buses" 0 "(see: $CAN logs alpha)"
    # Stop here. Every check below this one is about where frames went, and with no
    # gateway running the negative ones -- "delta never saw a body frame" -- would all
    # pass on an empty log and report a working mesh that was never started.
    $CAN logs alpha 2>&1 | tail -5 | sed 's/^/      /'
    $CAN down -v --remove-orphans >/dev/null 2>&1
    return
  fi
  check "alpha bridged its buses" 1

  # Watchers first, then traffic: a subscriber that attaches after the frames were sent has
  # nothing to receive, because qnnt does not retain.
  # Backgrounded with `&`, NOT with `exec -d`: a detached exec has no stdout attached, so
  # the redirect would capture an empty file and every count would read as zero.
  for host in bravo charlie delta zulu; do
    $CAN exec -T "$host" python3 /qnnt/examples/can/traffic.py watch vcan0 --seconds 8 \
      >/tmp/can-$host-pt.log 2>&1 &
  done
  # bravo's second bus. delta and charlie have no vcan1 -- they bridge powertrain only,
  # which is what makes "delta never saw a body frame" mean something.
  $CAN exec -T bravo python3 /qnnt/examples/can/traffic.py watch vcan1 --seconds 8 \
    >/tmp/can-bravo-body.log 2>&1 &
  sleep 2

  # 20 frames on alpha's powertrain, 20 on alpha's body. Different tags, so a watcher can
  # say which bus a frame came from as well as which host.
  $CAN exec -T alpha python3 /qnnt/examples/can/traffic.py send vcan0 --count 20 --tag 0xA1 \
    >/dev/null 2>&1
  $CAN exec -T alpha python3 /qnnt/examples/can/traffic.py send vcan1 --count 20 --tag 0xB1 \
    >/dev/null 2>&1
  wait   # for the watchers to finish their 8 seconds and write their summaries

  count_tag() { grep -o "0x$2=[0-9]*" "/tmp/can-$1.log" 2>/dev/null | tail -1 | cut -d= -f2; }

  local b c d z
  b=$(count_tag bravo-pt A1); c=$(count_tag charlie-pt A1); d=$(count_tag delta-pt A1)
  z=$(count_tag zulu-pt A1)

  check "powertrain frames reached bravo"   "$([ "${b:-0}" = "20" ] && echo 1 || echo 0)" "(got ${b:-0}/20)"
  check "powertrain frames reached charlie" "$([ "${c:-0}" = "20" ] && echo 1 || echo 0)" "(got ${c:-0}/20)"
  check "powertrain frames reached delta"   "$([ "${d:-0}" = "20" ] && echo 1 || echo 0)" "(got ${d:-0}/20)"

  # 5. exactly 20, not 20-and-a-bit: more than was sent is a relay loop, and it is the
  # failure this design has to rule out rather than merely not observe.
  check "no amplification -- one frame in, one frame out" \
    "$([ "${b:-0}" = "20" ] && [ "${c:-0}" = "20" ] && echo 1 || echo 0)" \
    "(bravo ${b:-0}, charlie ${c:-0} of 20)"

  # 2 and 3.
  local body_b body_d
  body_b=$(count_tag bravo-body B1)
  body_d=$(count_tag delta-pt B1)
  check "body frames reached bravo's second bus" \
    "$([ "${body_b:-0}" = "20" ] && echo 1 || echo 0)" "(got ${body_b:-0}/20)"
  check "body frames never reached the powertrain-only host" \
    "$([ -z "$body_d" ] && echo 1 || echo 0)" "(delta saw ${body_d:-0} body frames)"

  # 4.
  check "the host outside the cluster key saw nothing" \
    "$([ -z "$z" ] && echo 1 || echo 0)" "(zulu saw ${z:-0} frames)"

  $CAN down -v --remove-orphans >/dev/null 2>&1
}

case "$MODE" in
  shell)
    build_image
    $CAN up -d >/dev/null 2>&1
    exec $CAN exec "${2:-alpha}" bash
    ;;
  wire)
    build_image
    run_wire
    ;;
  full)
    build_image
    if have_vcan; then
      run_full
      echo
      run_wire
    else
      echo "== this kernel has no vcan =="
      echo "  \`ip link add type vcan\` fails in a privileged container, so there is no CAN"
      echo "  subsystem here. Docker Desktop's LinuxKit kernel is built without CONFIG_CAN."
      echo "  On a Mac:  docker/colima.sh   (starts a VM whose kernel has it, and selects it)"
      echo "  Elsewhere: run this on a Linux host with vcan available."
      echo
      skipped "the five gateway checks" "(no vcan in this kernel)"
      echo
      echo "== running the qnnt half instead, which needs no kernel CAN =="
      run_wire
    fi
    ;;
  *)
    echo "usage: docker/can.sh [full|wire|shell <host>]"; exit 2 ;;
esac

echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" = "0" ]
