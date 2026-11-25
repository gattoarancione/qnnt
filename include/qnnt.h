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

/*
 * Stack size, in bytes, for the threads qnnt starts per connection or per request and that
 * exit when it is served: the registry's and federation's client handlers, and the worker
 * behind qnnt_request_begin. Call before qnnt_init. Same as QNNT_HANDLER_STACK_BYTES.
 *
 * For a small target. Each of these threads otherwise reserves std.Thread's 16 MiB default,
 * and a burst of connections on a 32-bit board with no overcommit is what runs out of
 * memory. Long-lived threads -- one per topic or per node -- keep the default regardless.
 *
 * 0 restores the default. Values below 128 KiB are refused, because a handler that
 * overflows its stack takes the process down; anything else is rounded up to a whole page,
 * which qnnt_handler_stack_bytes then reports.
 */
qnnt_status qnnt_set_handler_stack_bytes(size_t bytes);
size_t qnnt_handler_stack_bytes(void);

/*
 * Same-host traffic over Unix domain sockets, everything else over TCP. On by default; call
 * before qnnt_init. Same as QNNT_LOCAL_SOCKETS.
 *
 * Every publisher and responder listens on both, and a subscriber or requester on the same
 * host uses the Unix socket, falling back to TCP if it cannot connect -- another user's node,
 * a container without the shared directory, an older node on either end. Remote peers always
 * use TCP; the socket path is never federated.
 *
 * qnnt_set_socket_dir chooses the directory (default /tmp/qnnt-<uid>, NULL or "" restores
 * it). It must be absolute and at most 64 bytes. It is created 0700, and if it exists it
 * must be a real directory owned by this user, or local sockets are turned off for the run
 * with a notice on stderr.
 */
qnnt_status qnnt_set_local_sockets(uint8_t enabled);
uint8_t qnnt_local_sockets(void);
qnnt_status qnnt_set_socket_dir(const char *path);
uint16_t    qnnt_registry_port(void);

/* This node's identity as 32 hex characters plus a NUL: `cap` must be >= 33. Copied out,
 * so the caller owns the buffer's lifetime. */
qnnt_status qnnt_node_id(char *out, size_t cap);

/* The address remote subscribers are told to dial, NUL-terminated. 46 bytes is enough. */
qnnt_status qnnt_advertise_address(char *out, size_t cap);

/* Non-zero when federation will actually run: a cluster key is set and a port is free. */
uint8_t qnnt_federation_enabled(void);

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

/* Topic strings passed to qnnt_publisher_start, qnnt_subscribe, qnnt_subscribe_frames and
 * qnnt_subscribe_queue are copied by the library, so a temporary is fine: a stack buffer, a
 * QByteArray from toUtf8(), or a Python bytes object that is collected straight after. Only
 * qnnt_publish borrows, and only for the duration of the call. */

/* Publish one message. Payloads are arbitrary bytes if the topic's subscribers read
 * frames; readers using qnnt_subscribe expect newline-delimited text. */
qnnt_status qnnt_publish(const char *topic, size_t topic_len,
                         const void *data, size_t data_len);

/* --- connection events ------------------------------------------------------- */
/*
 * A publisher that starts producing before anyone has connected is publishing into
 * nothing: qnnt has no replay. These events, and qnnt_wait_for_subscriber below, are how a
 * publisher knows when to begin.
 */
typedef enum {
    /* A subscriber connected to one of this node's publishers. */
    QNNT_EVENT_SUBSCRIBER_CONNECTED = 0,
    /* A subscriber's connection was found broken while publishing to it. */
    QNNT_EVENT_SUBSCRIBER_DISCONNECTED = 1,
    /* One of this node's subscriptions attached to a publisher. */
    QNNT_EVENT_PUBLISHER_CONNECTED = 2,
    /* A publisher this node was subscribed to closed the stream. */
    QNNT_EVENT_PUBLISHER_DISCONNECTED = 3,
    /* Nothing has arrived on a connected subscription for the stale timeout. Only emitted
     * when that timeout is set; a quiet topic is not otherwise an error. */
    QNNT_EVENT_PUBLISHER_STALE = 4,
    /* Data arrived on a subscription that had gone stale. */
    QNNT_EVENT_PUBLISHER_RESUMED = 5
} qnnt_event;

/*
 * `peer` is the address the event concerns, empty when there is none to name.
 * `subscribers` is this node's subscriber count for `topic`, and is 0 for the
 * QNNT_EVENT_PUBLISHER_* events, which concern the other direction.
 *
 * Called on one of the library's threads, not yours, and possibly from two threads at
 * once. No library lock is held, so calling back in -- qnnt_subscriber_count, for
 * instance -- is safe.
 */
typedef void (*qnnt_event_fn)(qnnt_event event, const char *topic, size_t topic_len,
                              const char *peer, size_t peer_len, size_t subscribers,
                              void *user);

void qnnt_set_event_handler(qnnt_event_fn handler, void *user);

/*
 * One buffered event, as handed out by qnnt_poll_events. `topic` and `peer` point into
 * library storage and are valid until the next qnnt_poll_events call, as with qnnt_poll.
 */
typedef struct {
    qnnt_event event;
    const char *topic;
    size_t topic_len;
    const char *peer;
    size_t peer_len;
    size_t subscribers;
    uint64_t at_us;
} qnnt_event_record;

/*
 * Drain buffered connection events; *count receives how many were written.
 *
 * The alternative to a handler, and the right one for a language that cannot be called on
 * a foreign thread -- a ctypes callback would acquire the GIL on this node's accept thread
 * and hold up the library while it ran. Events are buffered as they happen, so nothing is
 * lost before the first poll, which is exactly when the interesting ones occur. Both
 * mechanisms may be used at once.
 *
 * The buffer holds 64 events; past that the newest are dropped and counted, so a consumer
 * that stops draining loses new events rather than the history it has not read.
 */
qnnt_status qnnt_poll_events(qnnt_event_record *out, size_t max, size_t *count);

/* Events discarded because nothing drained the queue. */
uint64_t qnnt_events_dropped(void);

/* Subscribers connected to this node's publisher for `topic`. */
size_t qnnt_subscriber_count(const char *topic, size_t topic_len);

/*
 * Block until `topic` has at least one subscriber, or the timeout expires; returns whether
 * it has one. A timeout of 0 polls once.
 *
 * This is the call to make before a publisher's first message. A subscriber cannot attach
 * until the publisher has registered AND the subscriber's next registry probe comes round,
 * so the delay is neither zero nor predictable -- waiting for the fact beats sleeping for
 * a guess.
 */
bool qnnt_wait_for_subscriber(const char *topic, size_t topic_len, uint64_t timeout_ms);

/* As above, for a known number of peers. Waiting for one subscriber stops a publisher
 * shouting into an empty room; waiting for all of them means every peer sees the stream
 * from its first message. */
bool qnnt_wait_for_subscribers(const char *topic, size_t topic_len, size_t count,
                               uint64_t timeout_ms);

/* Silence after which a connected subscription is reported stale, via
 * QNNT_EVENT_PUBLISHER_STALE. 0 (the default) disables it. */
void qnnt_set_stale_timeout(uint64_t ms);
uint64_t qnnt_stale_timeout(void);

/* --- subscriptions: callback ------------------------------------------------- */

/* Invoked on the subscriber's own thread. `data` is valid only for this call. */
typedef void (*qnnt_message_fn)(const char *topic, size_t topic_len,
                                const uint8_t *data, size_t data_len, void *user);

/* Newline-delimited text stream. */
qnnt_status qnnt_subscribe(const char *topic, size_t topic_len,
                           qnnt_message_fn callback, void *user);

/*
 * Every topic matching a glob, including ones that do not exist yet: '*' spans any run of
 * characters, '?' exactly one. Each match is joined as its own subscription, and the
 * callback's `topic` says which one a message came from.
 *
 * `rescan_ms` is how often to look for topics that have appeared since; 0 joins what
 * exists now and stops looking, for a one-shot capture. Discovery is polled, and fan-out
 * is one connection per matching publisher -- so this is a separate call rather than
 * qnnt_subscribe noticing a '*', and nobody who does not ask for it pays for it.
 */
qnnt_status qnnt_subscribe_pattern(const char *pattern, size_t pattern_len,
                                   qnnt_message_fn callback, void *user,
                                   uint64_t rescan_ms);

/* Invoked with a decoded TLD frame, valid only for this call. */
typedef void (*qnnt_frame_fn)(const char *topic, size_t topic_len,
                              const qnnt_tld_frame *frame, void *user);

/* TLD-framed stream. Framing is a property of the topic: a producer publishing TLD must
 * be read with this, and one publishing text lines with qnnt_subscribe. */
qnnt_status qnnt_subscribe_frames(const char *topic, size_t topic_len,
                                  qnnt_frame_fn callback, void *user);

/* qnnt_subscribe_frames over a glob. See qnnt_subscribe_pattern. */
qnnt_status qnnt_subscribe_pattern_frames(const char *pattern, size_t pattern_len,
                                          qnnt_frame_fn callback, void *user,
                                          uint64_t rescan_ms);

/* --- request/reply ----------------------------------------------------------- */

/*
 * The other shape: one request, one reply, addressed to a name.
 *
 * Discovery is the same directory publishers use, so a procedure federates and expires
 * like a topic -- but the entry records which it is, and the two cannot be crossed: asking
 * for a topic by qnnt_request is QNNT_RPC_NO_PROCEDURE rather than a connection that waits
 * for a reply no publisher will send.
 *
 * On the wire a request is a 4-byte big-endian length then the bytes; a reply prefixes its
 * payload with a status byte, which is what makes "refused" distinguishable from "an empty
 * answer". Each call is its own connection, so callers never block behind one another and
 * a dead peer is a failed connect rather than a hang. That handshake per call is also why
 * this is a control-plane facility: for anything at streaming rates, publish.
 */

typedef enum {
    QNNT_RPC_OK = 0,
    /* No such procedure, or the name is a topic rather than a procedure. */
    QNNT_RPC_NO_PROCEDURE = 1,
    QNNT_RPC_UNREACHABLE = 2,
    QNNT_RPC_TIMED_OUT = 3,
    /* The responder ran and declined -- distinct from an empty reply. */
    QNNT_RPC_REFUSED = 4,
    /* The request, the reply, or the caller's buffer was too small for it. */
    QNNT_RPC_TOO_LARGE = 5,
    QNNT_RPC_FAILED = 6
} qnnt_rpc_status;

const char *qnnt_rpc_status_name(qnnt_rpc_status status);

/*
 * Serves one request, on the responder's own thread. Return NULL to refuse.
 *
 * Write the reply length through `reply_len` and return the bytes. Those bytes are read
 * AFTER this returns, so they must outlive the call -- a literal, a global, or heap you
 * keep alive, never a buffer on this function's stack. Same rule as qnnt_source_fn.
 *
 * Requests are served one at a time, so a handler touching shared state needs no lock.
 */
typedef const uint8_t *(*qnnt_responder_fn)(const char *procedure, size_t procedure_len,
                                            const uint8_t *request, size_t request_len,
                                            size_t *reply_len, void *user);

/* Serve `procedure` on this node. */
qnnt_status qnnt_add_responder(const char *procedure, size_t procedure_len,
                               qnnt_responder_fn callback, void *user);

/* Stop serving it: joins the responder's threads, then drops the registration. QNNT_FAILED
 * when nothing of that name was served here, and when called from its own handler -- which
 * would otherwise wait for the calling thread. */
qnnt_status qnnt_remove_responder(const char *procedure, size_t procedure_len);

/*
 * One request, start to finish, on the calling thread.
 *
 * The reply is copied into `out` and its length written to `out_len`. A reply larger than
 * `out_cap` is QNNT_RPC_TOO_LARGE with `out_len` set to 0 -- never a truncated answer that
 * looks complete. `timeout_ms` of 0 means the default (5s).
 */
qnnt_rpc_status qnnt_request(const char *procedure, size_t procedure_len,
                             const void *data, size_t data_len,
                             uint64_t timeout_ms,
                             void *out, size_t out_cap, size_t *out_len);

/*
 * The non-blocking form: start the request and return a ticket immediately, 0 if it could
 * not be started at all. The reply is collected with qnnt_poll_replies.
 *
 * There is no completion callback by design. One would have to fire on a library thread,
 * and that is exactly the crossing qnnt_poll exists to avoid -- so replies are drained,
 * and the same loop can drain messages and replies together.
 */
uint64_t qnnt_request_begin(const char *procedure, size_t procedure_len,
                            const void *data, size_t data_len,
                            uint64_t timeout_ms);

/* One completed request. `procedure` and `data` point into library storage that stays
 * valid until the next qnnt_poll_replies, which recycles it. */
typedef struct {
    uint64_t id;
    qnnt_rpc_status status;
    const char *procedure;
    size_t procedure_len;
    const uint8_t *data;
    size_t data_len;
} qnnt_reply;

/* Drain completed requests into `out`, writing how many through `count`. `timeout_ms` of 0
 * polls, a negative value waits until something completes. */
qnnt_status qnnt_poll_replies(qnnt_reply *out, size_t max, int32_t timeout_ms, size_t *count);

/* How many qnnt_request_begin calls have not yet completed. */
size_t qnnt_requests_in_flight(void);

/* --- per-topic teardown ------------------------------------------------------ */

/*
 * Stop one topic without stopping the node.
 *
 * Both calls JOIN the topic's worker threads before returning, so when they return nothing
 * is still reading, writing or calling back on that topic and any user pointer it held can
 * be freed. That is also the one trap: calling either from the topic's own callback would
 * have the thread wait for itself, so that is refused with QNNT_FAILED rather than
 * deadlocking.
 *
 * QNNT_FAILED also means there was nothing to remove, which makes both safe to call
 * speculatively.
 */

/* Stop publishing a topic: joins the accept loop, the registry refresh and the scheduler,
 * drops the registration and closes the delivery connections. Subscribers on other nodes
 * see the publisher go away, exactly as they would if the process had exited. */
qnnt_status qnnt_remove_publisher(const char *topic, size_t topic_len);

/* Stop every subscription this node holds on a topic, whichever call started it. A topic
 * reached through a glob stays gone -- the pattern will not rejoin it. */
qnnt_status qnnt_remove_subscriber(const char *topic, size_t topic_len);

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

/* qnnt_subscribe_queue over a glob. Each queued message carries its own topic, so one
 * queue serves the whole pattern. See qnnt_subscribe_pattern for what it costs. */
qnnt_status qnnt_subscribe_pattern_queue(const char *pattern, size_t pattern_len,
                                         qnnt_queue_mode mode, uint64_t rescan_ms);

/* Does `topic` match `pattern`? The same matcher the subscription used, and the same one
 * qnnt-ls and qnnt-cat use -- so a caller deciding what a message is can never disagree
 * with the library about what it subscribed to. Note that '*' crosses '/' here, unlike a
 * shell glob, so a pattern ending in a star also matches topics deeper in the tree. */
bool qnnt_topic_matches(const char *pattern, size_t pattern_len,
                        const char *topic, size_t topic_len);

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
