#!/usr/bin/env bash
# Checks that the Linux build behaves the way the macOS build does. Run inside the
# container built from docker/Dockerfile.linux-test.
set -u
cd /qnnt

pass=0; fail=0
check() { if [ "$2" = "1" ]; then echo "  ok    $1"; pass=$((pass+1)); else echo "  FAIL  $1 ${3:-}"; fail=$((fail+1)); fi; }

echo "== the artefacts we are testing =="
file bin/qnnt-node-0 | sed 's/^/  /'
echo

echo "== 1. a Zig node reads the environment (needs libc; static builds silently do not) =="
QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31001 QNNT_FEDERATION_PORT=31101 \
  ./bin/qnnt-node-0 > /tmp/z0.log 2>&1 &
sleep 3
grep -q "federation enabled" /tmp/z0.log; check "federation enabled from QNNT_CLUSTER_KEY" $((1-$?))
grep -q "did nothing" /tmp/z0.log && check "no libc warning" 0 "(binary is not linked against libc)" || check "no libc warning" 1
printf 'status\nquit\n' | nc -q1 127.0.0.1 31001 | grep -q "federation port 31101"
check "registry reports the federation port" $((1-$?))
pkill -f qnnt-node-0; sleep 1
echo

echo "== 2. the federation port is actually bound on 0.0.0.0 =="
QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31002 QNNT_FEDERATION_PORT=31102 \
  ./bin/qnnt-node-0 > /tmp/z1.log 2>&1 &
sleep 3
nc -z 127.0.0.1 31102; check "federation port accepts connections" $((1-$?))
pkill -f qnnt-node-0; sleep 1
echo

echo "== 3. two Linux nodes federate with each other =="
QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31003 QNNT_FEDERATION_PORT=31103 \
  QNNT_PEERS=127.0.0.1:31104 ./bin/qnnt-node-0 > /tmp/z2.log 2>&1 &
sleep 1
QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31004 QNNT_FEDERATION_PORT=31104 \
  QNNT_PEERS=127.0.0.1:31103 ./bin/qnnt-node-1 > /tmp/z3.log 2>&1 &
sleep 7
learned=$(printf 'list\nquit\n' | nc -q1 127.0.0.1 31004 | grep -c 'test/topic-[ab]')
[ "$learned" -ge 2 ] && check "node-1 learned node-0's topics by federation ($learned)" 1 \
                     || check "node-1 learned node-0's topics" 0 "(got $learned)"
got=$(grep -c 'received on' /tmp/z3.log)
[ "$got" -gt 0 ] && check "and receives across the federation ($got msgs)" 1 \
                 || check "receives across the federation" 0
pkill -f qnnt-node; sleep 1
echo

echo "== 4. a peer named rather than numbered =="
# glibc resolves through NSS, a different path from macOS, so the hostname support gets
# its own check here. "localhost" comes from /etc/hosts, so this needs no DNS server.
QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31008 QNNT_FEDERATION_PORT=31108 \
  ./bin/qnnt-node-0 > /tmp/n0.log 2>&1 &
sleep 1
QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31009 QNNT_FEDERATION_PORT=31109 \
  QNNT_PEERS=localhost:31108 ./bin/qnnt-node-2 > /tmp/n1.log 2>&1 &
sleep 7
grep -q "synced with localhost:31108" /tmp/n1.log
check "peer given as a hostname resolves and connects" $((1-$?))

# The entry a named peer teaches us must carry a numeric host: every other node parses
# that text as a literal, so a name leaking in here would break them.
hosts=$(printf 'list\nquit\n' | nc -q1 127.0.0.1 31009 | grep -c 'tcp://127.0.0.1:')
named=$(printf 'list\nquit\n' | nc -q1 127.0.0.1 31009 | grep -c 'tcp://localhost')
[ "$hosts" -ge 1 ] && [ "$named" -eq 0 ] \
  && check "entries learned from it carry a numeric host ($hosts)" 1 \
  || check "entries learned from it carry a numeric host" 0 "(numeric $hosts, named $named)"

# A name that cannot resolve must be reported as such, not retried mutely forever.
QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31010 QNNT_FEDERATION_PORT=31110 \
  QNNT_PEERS=qnnt-nope.invalid:31108 ./bin/qnnt-node-2 > /tmp/n2.log 2>&1 &
sleep 4
grep -qE "UnknownHost|TemporaryResolveFailure" /tmp/n2.log
check "an unresolvable peer name is named as unresolvable" $((1-$?))
pkill -f qnnt-node; sleep 1
echo

echo "== 5. the C ABI and Python package work on Linux =="
QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31005 QNNT_FEDERATION_PORT=31105 \
  ./bin/node-c 0 > /tmp/c0.log 2>&1 &
sleep 3
grep -q "federation enabled" /tmp/c0.log; check "C node reads the environment" $((1-$?))
pkill -f node-c; sleep 1

QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31006 QNNT_FEDERATION_PORT=31106 \
  python3 -u python/nodes.py 2 > /tmp/p0.log 2>&1 &
sleep 4
grep -q "federation enabled" /tmp/p0.log; check "Python node loads the .so and reads the environment" $((1-$?))
pkill -f nodes.py; sleep 1
echo

echo "== 6. federate with the macOS host, if it is running a node =="
if [ -n "${HOST_FEDERATION_PORT:-}" ]; then
  QNNT_CLUSTER_KEY=secret QNNT_REGISTRY_PORT=31007 QNNT_FEDERATION_PORT=31107 \
    QNNT_PEERS=host.docker.internal:${HOST_FEDERATION_PORT} ./bin/qnnt-node-2 > /tmp/h0.log 2>&1 &
  sleep 8
  n=$(printf 'list\nquit\n' | nc -q1 127.0.0.1 31007 | grep -c 'test/')
  [ "$n" -gt 0 ] && check "learned $n topic(s) from the macOS host" 1 \
                 || check "learned topics from the macOS host" 0 "(peers: $(printf 'peers\nquit\n' | nc -q1 127.0.0.1 31007 | tr '\n' ' '))"
  pkill -f qnnt-node-2
else
  echo "  skipped (set HOST_FEDERATION_PORT to test against the host)"
fi

echo
echo "passed $pass, failed $fail"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
