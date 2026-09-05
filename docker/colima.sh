#!/usr/bin/env bash
# Set up the Linux VM everything in docker/ runs on.
#
#   docker/colima.sh          # create it, or bring it back, and select it
#   docker/colima.sh stop     # stop the VM (it keeps its disk and its images)
#   docker/colima.sh delete   # and throw it away
#
# Why colima and not Docker Desktop. Docker Desktop's LinuxKit kernel is built without
# CONFIG_CAN, so `ip link add type vcan` fails there however many capabilities you grant --
# examples/can/ cannot run on it at all. colima boots an ordinary Ubuntu kernel, where CAN
# is a loadable module and everything else behaves the same. Since one runtime has to be
# able to run all of it, it is this one.
#
# The VM is a normal Linux host, so what runs here is closer to a deployment than Docker
# Desktop's tuned VM is: its own kernel, its own module set, its own network stack.
set -u

CPU="${COLIMA_CPU:-4}"
MEM="${COLIMA_MEM:-6}"
DISK="${COLIMA_DISK:-30}"

# Stopping colima resets the docker context to `default`, which on a Mac points at
# /var/run/docker.sock -- a socket nothing is listening on unless Docker Desktop is
# running. So `docker` stops working entirely, with an error about a missing file that
# says nothing about why. Say what happened and how to get it back.
say_context() {
  echo
  echo "docker context is now '$(docker context show 2>/dev/null || echo unknown)'."
  echo "  docker/colima.sh                   bring colima back"
  echo "  docker context use desktop-linux   Docker Desktop instead (start the app first)"
}

case "${1:-start}" in
  stop)
    colima status >/dev/null 2>&1 || { echo "colima is not running"; say_context; exit 0; }
    colima stop || exit 1
    say_context
    exit 0 ;;
  delete) exec colima delete ;;
  start)  ;;
  *) echo "usage: docker/colima.sh [start|stop|delete]"; exit 2 ;;
esac

command -v colima >/dev/null || { echo "colima is not installed: brew install colima"; exit 1; }

# 2 CPUs and 2 GB is colima's default and is not enough: docker/federation.sh runs six
# containers and docker/can.sh five, each a full node with its own registry.
if colima status >/dev/null 2>&1; then
  echo "colima is already running"
else
  echo "== starting the VM (${CPU} CPU, ${MEM} GB, ${DISK} GB disk) =="
  colima start --cpu "$CPU" --memory "$MEM" --disk "$DISK" || exit 1
fi

# The CAN modules. The Ubuntu CLOUD image ships a trimmed module set, so vcan is missing
# until linux-modules-extra is installed -- and `modprobe vcan` then fails with "Module
# vcan not found", which reads exactly like a kernel with no CAN support and is not.
#
# Loaded in the VM, never in a container: a container has no /lib/modules and can only
# `ip link add` against a subsystem the kernel already has.
if colima ssh -- sudo modprobe vcan 2>/dev/null; then
  echo "== vcan already available =="
else
  echo "== installing the CAN modules (once per VM; a few minutes) =="
  colima ssh -- sh -c 'sudo apt-get update -qq && \
    sudo apt-get install -y -qq linux-modules-extra-$(uname -r)' || exit 1
fi
colima ssh -- sudo modprobe vcan can can_raw || exit 1

# modprobe survives until the VM stops, so this has to run after every `colima start`.
# Running this script again is how.
colima ssh -- lsmod | grep -q '^vcan' && echo "  vcan loaded"

docker context use colima >/dev/null && echo "== docker context: colima =="
echo
echo "Now:  docker/run-tests.sh via the image, docker/federation.sh, docker/can.sh"
echo "Back: docker context use desktop-linux"
