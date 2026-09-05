#!/usr/bin/env bash
# Create the vcan interfaces a gateway is about to bridge, then become the gateway.
#
# Each container has its own network namespace, so each gets its OWN vcan0 -- which is why
# this models separate hosts rather than one host with several interfaces. Frames put on
# alpha's vcan0 reach bravo's vcan0 only if the gateways carried them.
#
#   start-gateway.sh <gateway-name> <bus>=<iface> [<bus>=<iface>]...
#
# Needs NET_ADMIN (granted in docker/compose.can.yml) and a kernel with vcan.
set -u

NAME="${1:?usage: start-gateway.sh <name> <bus>=<iface>...}"
shift

if ! ip link add dev __probe type vcan 2>/dev/null; then
  echo "start-gateway.sh: this kernel cannot create vcan interfaces."
  echo "  Docker Desktop's LinuxKit kernel has no CAN subsystem. See docker/README.md."
  exit 3
fi
ip link delete __probe 2>/dev/null

ARGS=()
for spec in "$@"; do
  iface="${spec#*=}"
  ip link add dev "$iface" type vcan 2>/dev/null
  ip link set up "$iface" || { echo "start-gateway.sh: cannot bring up $iface"; exit 3; }
  ARGS+=(--bus "$spec")
done

echo "start-gateway.sh: $NAME bridging $*"
exec /qnnt/bin/qnnt-can-gw --name "$NAME" "${ARGS[@]}" --stats "${STATS_MS:-5000}"
