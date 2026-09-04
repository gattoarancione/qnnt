"""One node in a federation test: a site's registry holder, or an app on top of it.

Two roles, because federation only ever runs in one of them:

  --publish / plain   a SITE. Holds its own registry on its own port, carries the cluster
                      key, dials its peers. This is the process that federates.
  --subscribe         an APP on that site. No cluster key, federation port 0. It reaches
                      remote publishers through the directory its site's registry holder
                      federated, which is the realistic shape -- and it keeps a test honest,
                      since an app that federated on its own account could carry entries
                      between sites and manufacture the result.

Configuration is entirely through QNNT_* variables, so a topology is nothing but a set of
QNNT_PEERS lists. Several sites fit on one machine because the registry is host-local by
design: here "host" means "registry port".
"""
import sys, time
sys.path.insert(0, "python")
import qnnt


def main() -> int:
    topic = sys.argv[1]
    publishing = "--publish" in sys.argv
    subscribing = "--subscribe" in sys.argv
    seconds = 0.0
    for i, a in enumerate(sys.argv):
        if a == "--seconds":
            seconds = float(sys.argv[i + 1])

    with qnnt.Node() as node:
        if subscribing:
            node.subscribe(topic, frames=True)
            received, last_seq = 0, 0
            end = time.time() + seconds
            while time.time() < end:
                for msg in node.poll(timeout=0.25):
                    received += 1
                    try:
                        last_seq = msg.value().get("seq", 0)
                    except Exception:
                        pass
            print(f"RESULT received={received} last_seq={last_seq}", flush=True)
            return 0

        node.publisher(topic)
        print(f"ready {topic}", flush=True)
        seq = 0
        while True:
            if publishing:
                seq += 1
                node.publish_object(topic, {"seq": seq, "from": topic})
                time.sleep(0.1)
            else:
                time.sleep(1)


if __name__ == "__main__":
    sys.exit(main())
