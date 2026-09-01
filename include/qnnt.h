/*
 * qnnt -- C interface to the node: lifecycle, publishing, and subscriptions.
 *
 * Hand-written and kept in step with lib/qnnt_c.zig by hand. The TLD codec has its own
 * header, included below; linking libqnnt_c gives you both.
 *
 * Lifetimes and ownership, once:
 *
 *   - Topics are NOT copied. The (pointer, length) you pass to a publisher or a
 *     subscription is retained, so it must outlive that subscription -- a string literal
 *     or other long-lived storage, not a stack buffer.
 *   - Message bytes handed to a callback are valid only for that call. Copy what you keep.
 *   - Messages returned by qnnt_poll stay valid until your next qnnt_poll call, which
 *     recycles the storage.
 *   - One node per process: the library keeps global state, so qnnt_init/qnnt_deinit
 *     bracket the whole process, not an object.
 *
 * Threads: callbacks arrive on library threads and must be thread-safe. qnnt_poll must be
 * called from one thread only. Everything else may be called from any thread.
 */
#ifndef QNNT_H
#define QNNT_H

#include "qnnt_tld.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    QNNT_OK = 0,
    /* The operation failed; specifics have been printed to stderr. */
    QNNT_FAILED = 1,
    QNNT_INVALID_ARGUMENT = 2,
    /* A source callback without a period, or a period without a source. */
    QNNT_INVALID_PERIOD = 3
} qnnt_status;

const char *qnnt_status_name(qnnt_status status);

/* --- lifecycle --------------------------------------------------------------- */

/* Choose the registry port used by the next qnnt_init. Returns QNNT_FAILED while a node is
 * running -- its workers already hold the value. Distinct ports give fully independent
 * registries on one machine, which is how two programs stay out of each other's way. The
 * default is 2222. The library reads no environment of its own: if you want the port to
 * come from one, read it and pass it. */
qnnt_status qnnt_set_registry_port(uint16_t port);

/*
 * Run qnnt's worker threads on SCHED_FIFO at `priority` (Linux only; 0 disables, and is
 * the default). Call before qnnt_init.
 *
 * Returns qnnt_ok if the request was accepted, which is not the same as it working: the
 * process needs CAP_SYS_NICE, root, or an RLIMIT_RTPRIO ceiling at least this high, and
 * that is only discovered when a worker thread tries. A refusal is printed once, to
 * stderr, naming the errno -- watch for it, because otherwise the threads run at default
 * priority and the latency bound is silently absent.
 *
 * The calling thread is never touched. If your own thread needs a real-time priority, set
 * it yourself.
 *
 * Do not combine a high priority with an unpaced publisher (period_us 0): that is a busy
 * loop outranking everything else on its core.
 */
qnnt_status qnnt_set_realtime_priority(uint8_t priority);
uint8_t qnnt_realtime_priority(void);

/*
 * Pin this process's memory into RAM with mlockall(MCL_CURRENT | MCL_FUTURE) before worker
 * threads start (Linux only; off by default). Call before qnnt_init.
 *
 * The companion to qnnt_set_realtime_priority. A SCHED_FIFO thread cannot be preempted by
 * another thread, but it can still be stopped for milliseconds by a major page fault, and
 * no scheduling policy prevents that.
 *
 * Needs CAP_IPC_LOCK, root, or an RLIMIT_MEMLOCK ceiling above the process's size
 * (ulimit -l). Returns qnnt_ok if accepted; a kernel refusal is printed once to stderr.
 *
 * Two consequences to weigh. MCL_FUTURE locks every later mapping, so if RLIMIT_MEMLOCK is
 * too low the failure surfaces as an allocation error somewhere unrelated. And locked pages
 * cannot be reclaimed, which on a small board is memory the rest of the system loses.
 */
qnnt_status qnnt_set_lock_memory(uint8_t enabled);
uint8_t qnnt_lock_memory(void);
uint16_t    qnnt_registry_port(void);

/* Addressing. Both optional and both must precede qnnt_init.
 *
 * advertise: the address remote subscribers are told to dial. Leave it unset and a peer
 *   fills it in from the address it reached this host on -- which is what lets a node that
 *   binds 0.0.0.0, or sits behind a gateway that picks its public address, be reachable
 *   without ever knowing its own address.
 * bind: what publisher sockets listen on. Defaults to following the advertise address, so
 *   loopback stays private and anything else listens on 0.0.0.0.
 */
qnnt_status qnnt_set_advertise_address(const char *addr);
qnnt_status qnnt_set_bind_address(const char *addr);

/* Federation across hosts. All optional, all before qnnt_init.
 *
 * Federation stays off unless BOTH a port and a cluster key are set: an unauthenticated
 * directory reachable from a network lets anyone redirect a topic's subscribers.
 *
 * Peers need not know their own addresses. An entry carries a port and an optional host;
 * when the host is absent the receiver substitutes the address it reached the sender on.
 * A node can therefore bind 0.0.0.0, or sit behind a gateway that chooses its public
 * address, and still be reachable.
 *
 * Port-translating NAT with no forwarding is the exception: inbound connections are
 * impossible there, and no address rewriting changes that. Across the internet, run qnnt
 * over a VPN or tunnel and treat it as a LAN.
 */
qnnt_status qnnt_set_federation_port(uint16_t port);
qnnt_status qnnt_set_cluster_key(const char *key);
/*
 * A peer to dial. `host` may be an IPv4 or IPv6 address, or a hostname -- names are
 * resolved through the system resolver (so /etc/hosts, resolv.conf, search domains and
 * mDNS all apply) and re-resolved on every connection attempt, so a peer that changes
 * address is followed without a restart. Pass 0 for `port` to use the federation port.
 *
 * Note that qnnt_set_advertise_address and qnnt_set_bind_address also accept names, but
 * resolve once, at the time of the call, and keep the resulting address: what a publisher
 * advertises has to be parseable by every subscriber, including ones that cannot resolve
 * the name.
 */
qnnt_status qnnt_add_peer(const char *host, uint16_t port);

/* Apply configuration from the process environment, reading these if present:
 *
 *   QNNT_REGISTRY_PORT   QNNT_ADVERTISE_ADDR   QNNT_BIND_ADDR
 *   QNNT_CLUSTER_KEY     QNNT_FEDERATION_PORT  QNNT_PEERS
 *
 * One call, and the same variables behave identically from C, C++, Python and Zig. An unset
 * or empty variable is absent; a value that cannot be used is reported on stderr rather
 * than ignored. Explicit rather than automatic, because a library that silently
 * reconfigures itself from process-wide state surprises whatever embeds it.
 *
 * Call before qnnt_init; explicit setters afterwards override it. */
void qnnt_configure_from_environment(void);

/* Start the node: joins the registry election and brings up the worker threads. */
qnnt_status qnnt_init(void);

/* Stop everything and release it: signals the workers, breaks the calls they are blocked
 * in, joins them, then frees. Safe to follow with another qnnt_init. */
void qnnt_deinit(void);

/* Opt in to SIGINT/SIGTERM handling, which requests a stop rather than exiting the
 * process. qnnt_init deliberately does NOT do this: a library must not take over its
 * host's signal disposition unasked. Call after qnnt_init -- the Io backend installs its
 * own handlers during init and would overwrite yours. */
void qnnt_install_signal_handlers(void);

/* True once a stop has been requested by a handled signal or by qnnt_deinit. A main
 * thread with nothing else to do can loop on this. */
bool qnnt_stop_requested(void);

int64_t qnnt_now_micros(void);
void    qnnt_sleep_ms(uint64_t ms);

/* --- publishing -------------------------------------------------------------- */

/* Produces one payload per scheduler tick. Return NULL, or set *out_len to 0, to skip a
 * tick. The bytes are read after you return, so they must outlive the call: a literal, a
 * global, or your own heap -- never a local buffer. */
typedef const uint8_t *(*qnnt_source_fn)(const char *topic, size_t topic_len,
                                         size_t *out_len, void *user);

/* Start publishing `topic`.
 *
 *   source = NULL, period_us = 0 : publish by hand with qnnt_publish
 *   source, period_us > 0        : the library calls source once per period
 *   source, period_us = 0        : unpaced -- as fast as the machine manages, which
 *                                  busies a core; intended for load generation
 *
 * The period is a period, not a frequency, so any rate the clock can express is reachable
 * with no rounding step. */
qnnt_status qnnt_publisher_start(const char *topic, size_t topic_len,
                                 qnnt_source_fn source, uint64_t period_us, void *user);

/* Publish one message. Payloads are arbitrary bytes if the topic's subscribers read
 * frames; readers using qnnt_subscribe expect newline-delimited text. */
qnnt_status qnnt_publish(const char *topic, size_t topic_len,
                         const void *data, size_t data_len);

/* --- subscriptions: callback ------------------------------------------------- */

/* Invoked on the subscriber's own thread. `data` is valid only for this call. */
typedef void (*qnnt_message_fn)(const char *topic, size_t topic_len,
                                const uint8_t *data, size_t data_len, void *user);

/* Newline-delimited text stream. */
qnnt_status qnnt_subscribe(const char *topic, size_t topic_len,
                           qnnt_message_fn callback, void *user);

/* Invoked with a decoded TLD frame, valid only for this call. */
typedef void (*qnnt_frame_fn)(const char *topic, size_t topic_len,
                              const qnnt_tld_frame *frame, void *user);

/* TLD-framed stream. Framing is a property of the topic: a producer publishing TLD must
 * be read with this, and one publishing text lines with qnnt_subscribe. */
qnnt_status qnnt_subscribe_frames(const char *topic, size_t topic_len,
                                  qnnt_frame_fn callback, void *user);

/* --- subscriptions: queue ---------------------------------------------------- */

/*
 * The alternative to callbacks: messages are copied into a queue you drain yourself.
 *
 * Prefer this when a callback would cross into a managed runtime. Crossing per message
 * costs far more than the copy, and draining a batch amortises it; more importantly, no
 * library thread ever calls into your runtime, so there is no GIL to acquire from a
 * thread Python has never seen and no exception with nowhere to go.
 *
 * One queue serves every queued subscription, so there is a single drain point; each
 * message carries the topic it arrived on.
 */
typedef struct {
    const char    *topic;
    size_t         topic_len;
    const uint8_t *data;
    size_t         data_len;
    uint64_t       received_us;
} qnnt_message;

/* Size the shared queue before subscribing. Optional -- the first queued subscription
 * reserves a default (1024) if you have not asked for something else. A deliberately
 * small queue is how you feel backpressure early. */
qnnt_status qnnt_queue_reserve(size_t capacity);

/* Messages discarded because the queue was full. When full the NEWEST is dropped, so
 * what was already accepted stays contiguous and a consumer tracking sequence numbers
 * sees a clean gap at the end rather than a hole in the middle. */
uint64_t qnnt_queue_dropped(void);

/* Which reader the queued subscription uses. Framing belongs to the stream, not to the
 * delivery mode: a TLD producer read as text is chopped at every 0x0A inside a payload. */
typedef enum {
    QNNT_QUEUE_TEXT = 0,  /* newline-delimited, like qnnt_subscribe */
    QNNT_QUEUE_FRAMES = 1 /* TLD; queued bytes are a whole frame, ready for qnnt_tld_decode */
} qnnt_queue_mode;

qnnt_status qnnt_subscribe_queue(const char *topic, size_t topic_len, qnnt_queue_mode mode);

/* Drain up to `max` messages into `out`, writing how many to *count.
 *
 *   timeout_ms =  0 : never blocks
 *   timeout_ms = -1 : blocks until something arrives
 *   timeout_ms >  0 : blocks up to that long
 *
 * Returned pointers stay valid until your next qnnt_poll. Single-consumer: call from one
 * thread only. */
qnnt_status qnnt_poll(qnnt_message *out, size_t max, int32_t timeout_ms, size_t *count);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* QNNT_H */
