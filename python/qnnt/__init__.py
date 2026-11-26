"""qnnt -- Python interface to the qnnt pub/sub node.

    import qnnt

    with qnnt.Node() as node:
        node.publisher("sensors/temp")
        node.subscribe("sensors/temp", frames=True)

        node.publish_object("sensors/temp", {"celsius": 21.5, "raw": b"\\x00\\xff"})

        for message in node.poll(timeout=0.5):
            print(message.topic, message.value())

Two things about the design are deliberate and worth reading once.

**Delivery is by polling, not callbacks.** The C API can call you back on one of its own
threads, and this wrapper does not expose that. A callback from a thread CPython has never
seen means acquiring the GIL from a foreign thread and having nowhere sensible to put an
exception, and it pays an FFI crossing per message -- microseconds against a ~30 ns
decode. `poll()` drains a batch on your thread instead, so one crossing carries a hundred
messages and no library thread ever calls into Python.

**Publishing is done by you, not by a scheduler.** For the same reason: the library can
drive a publisher from its own thread at a fixed period, but that requires calling a
Python callback from it. Publish from your own loop or thread, timed however you like.

One node per process: the library keeps global state, so `Node` is a process-wide resource
and constructing a second one while the first is open raises.
"""

from __future__ import annotations

import ctypes as C
import enum as _enum
import os
from dataclasses import dataclass
from typing import Any, Iterator, Sequence

from ._lib import Error, EventRecord as _CEvent, Message as _CMessage, Reply as _CReply, declare, load


def _import_told():
    """TOLD's own Python package, which qnnt uses for the wire format.

    Installed from a qnnt wheel it sits beside this package, with libtold bundled inside it,
    and needs nothing. In a checkout it is the deps/told submodule's copy, pointed at the
    libtold that `zig build` puts beside libqnnt_c -- unless TOLD_LIBRARY already says where.
    """
    try:
        import told
        return told
    except ImportError:
        pass
    from pathlib import Path
    import sys
    root = Path(__file__).resolve().parents[2]
    sys.path.append(str(root / "deps" / "told" / "python"))
    built = root / "zig-out" / "lib"
    for name in ("libtold.dylib", "libtold.so", "told.dll"):
        if (built / name).exists():
            os.environ.setdefault("TOLD_LIBRARY", str(built / name))
            break
    import told
    return told


told = _import_told()

__all__ = ["Node", "Message", "Reply", "RpcStatus", "Error", "told", "version"]

_QUEUE_TEXT = 0
_QUEUE_FRAMES = 1


def _check(lib: C.CDLL, status: int, context: str) -> None:
    if status != 0:
        raise Error(status, lib.qnnt_status_name(status).decode(), context)


def _split_host_port(spec):
    """Split a peer spec into (host, port); port 0 means "use the federation port".

    Splitting on the last colon is wrong for IPv6 -- `fe80::1` would come apart into the
    host `fe80:` on port 1 -- so brackets are how an address with a port says where it
    stops. Mirrors splitHostPort in lib/env.zig, which parses QNNT_PEERS the same way:

        nodeb.local        10.0.0.9:2223        [fe80::1]:2223        fe80::1

    A host may be an address or a name; names are resolved by the library, per attempt.
    """
    if spec.startswith("["):
        host, close, rest = spec[1:].partition("]")
        if close and rest.startswith(":") and rest[1:].isdigit():
            return host, int(rest[1:])
        return host, 0

    if spec.count(":") == 1:
        host, _, port_text = spec.partition(":")
        if port_text.isdigit():
            return host, int(port_text)

    # No port, or something that is not a number where one would go: the whole spec is the
    # host, and an unusable one fails later by name rather than being silently truncated.
    return spec, 0


class EventKind(_enum.IntEnum):
    """What a connection event reports. Mirrors qnnt_event in qnnt.h."""

    subscriber_connected = 0
    subscriber_disconnected = 1
    publisher_connected = 2
    publisher_disconnected = 3
    publisher_stale = 4
    publisher_resumed = 5


@dataclass(frozen=True)
class Event:
    """One connection event, copied out of library storage.

    `subscribers` is the topic's subscriber count at the time, which is what lets a
    publisher wait for a known number of peers:

        for event in node.poll_events():
            if (event.kind is EventKind.subscriber_connected
                    and event.subscribers == expected):
                start_publishing()

    It is 0 for the publisher_* kinds, which concern the other direction.
    """

    kind: EventKind
    topic: str
    peer: str
    subscribers: int
    at_us: int


class RpcStatus(_enum.IntEnum):
    """How a request ended. Mirrors qnnt_rpc_status in qnnt.h."""

    ok = 0
    no_procedure = 1
    unreachable = 2
    timed_out = 3
    refused = 4
    too_large = 5
    failed = 6


@dataclass(frozen=True)
class Reply:
    """One completed request, copied out of library storage.

    `id` is the ticket `request_begin` returned, so one drain loop can serve many call
    sites; `procedure` says which name answered.
    """

    id: int
    status: RpcStatus
    procedure: str
    data: bytes

    @property
    def ok(self) -> bool:
        return self.status is RpcStatus.ok


@dataclass(frozen=True)
class Message:
    """One received message. `data` is already copied out of library storage."""

    topic: str
    data: bytes
    received_us: int

    def text(self) -> str:
        """The payload as UTF-8 text, for topics carrying lines."""
        return self.data.decode("utf-8")

    def value(self) -> Any:
        """The payload decoded as a TOLD frame, for topics carrying frames."""
        return told.loads(self.data)

    def unpacked(self, target: type) -> Any:
        """The payload decoded into `target` -- a dataclass, usually.

        The counterpart of QnntNode::unpacked<T>() in the Qt header and of
        told.unpackFrom(T, ...) in Zig, so the same struct crosses all three.
        """
        return told.unpack(target, self.data)


class Node:
    """A running qnnt node. Use as a context manager so it is always shut down."""

    _open: "Node | None" = None

    # const uint8_t *(*)(const char *, size_t, const uint8_t *, size_t, size_t *, void *)
    #
    # The result is c_void_p rather than POINTER(c_uint8): ctypes refuses a typed pointer
    # as a callback's return type, and the address is the same either way.
    _RESPONDER_FN = C.CFUNCTYPE(
        C.c_void_p,
        C.POINTER(C.c_char), C.c_size_t,
        C.POINTER(C.c_uint8), C.c_size_t,
        C.POINTER(C.c_size_t), C.c_void_p,
    )

    def __init__(
        self,
        *,
        registry_port: int | None = None,
        advertise_addr: str | None = None,
        bind_addr: str | None = None,
        federation_port: int | None = None,
        cluster_key: str | None = None,
        peers: Sequence[str] | None = None,
        realtime_priority: int | None = None,
        lock_memory: bool = False,
        handler_stack_bytes: int | None = None,
        local_sockets: bool | None = None,
        socket_dir: str | None = None,
        queue_capacity: int = 4096,
        handle_signals: bool = False,
    ) -> None:
        if Node._open is not None:
            raise RuntimeError("a qnnt Node is already open; the library is a process singleton")

        self._lib = declare(load())

        # Topics are retained by the library rather than copied, so the encoded bytes have
        # to be kept alive here for as long as the subscription exists.
        self._topics: dict[str, bytes] = {}
        # Responder trampolines and the last reply each returned. Both are referenced by
        # the library after the call that created them, so Python must not collect them.
        self._responders: dict[str, Any] = {}
        self._replies: dict[str, bytes] = {}
        self._closed = False

        # The library reads every QNNT_* variable itself, so all four languages agree on
        # what they mean. Keyword arguments are applied on top and win, which is why this
        # runs first.
        self._lib.qnnt_configure_from_environment()

        if registry_port is not None:
            _check(self._lib, self._lib.qnnt_set_registry_port(registry_port),
                   f"set_registry_port({registry_port})")
        if realtime_priority is not None:
            # Linux only, and acceptance is not success: the library prints a refusal to
            # stderr if the process may not take a real-time priority. See qnnt.h.
            _check(self._lib, self._lib.qnnt_set_realtime_priority(realtime_priority),
                   f"set_realtime_priority({realtime_priority})")
        if lock_memory:
            # The companion to realtime_priority: no scheduling policy stops a page fault.
            _check(self._lib, self._lib.qnnt_set_lock_memory(1), "set_lock_memory")
        if handler_stack_bytes is not None:
            # For small targets: the per-connection threads' stack, rounded up to a page.
            # 0 restores the default; below 128 KiB is refused. See qnnt.h.
            _check(self._lib, self._lib.qnnt_set_handler_stack_bytes(handler_stack_bytes),
                   f"set_handler_stack_bytes({handler_stack_bytes})")
        if local_sockets is not None:
            # Same-host traffic over Unix sockets, remote over TCP; on by default. See qnnt.h.
            _check(self._lib, self._lib.qnnt_set_local_sockets(1 if local_sockets else 0),
                   f"set_local_sockets({local_sockets})")
        if socket_dir is not None:
            _check(self._lib, self._lib.qnnt_set_socket_dir(socket_dir.encode()),
                   f"set_socket_dir({socket_dir!r})")
        if advertise_addr:
            _check(self._lib, self._lib.qnnt_set_advertise_address(advertise_addr.encode()),
                   "set_advertise_address")
        if bind_addr:
            _check(self._lib, self._lib.qnnt_set_bind_address(bind_addr.encode()),
                   "set_bind_address")
        if federation_port is not None:
            _check(self._lib, self._lib.qnnt_set_federation_port(federation_port),
                   "set_federation_port")
        if cluster_key:
            _check(self._lib, self._lib.qnnt_set_cluster_key(cluster_key.encode()),
                   "set_cluster_key")
        for spec in peers or ():
            host, port = _split_host_port(spec)
            _check(self._lib, self._lib.qnnt_add_peer(host.encode(), port),
                   f"add_peer({spec})")

        _check(self._lib, self._lib.qnnt_init(), "init")
        Node._open = self

        try:
            _check(self._lib, self._lib.qnnt_queue_reserve(queue_capacity), "queue_reserve")
        except Error:
            self.close()
            raise

        if handle_signals:
            # Off by default: taking over SIGINT would break KeyboardInterrupt, which is
            # exactly the sort of thing a library should not do behind your back.
            self._lib.qnnt_install_signal_handlers()

        self._batch_size = 0
        self._batch: Any = None
        self._count = C.c_size_t()

    # --- lifecycle ---------------------------------------------------------------

    def __enter__(self) -> "Node":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._lib.qnnt_deinit()
        if Node._open is self:
            Node._open = None

    @property
    def registry_port(self) -> int:
        """The port this node's registry election is contending for."""
        return int(self._lib.qnnt_registry_port())

    @property
    def stop_requested(self) -> bool:
        """True once a handled signal has asked the node to stop."""
        return bool(self._lib.qnnt_stop_requested())

    def now_micros(self) -> int:
        return int(self._lib.qnnt_now_micros())

    # --- topics ------------------------------------------------------------------

    def _topic_bytes(self, topic: str) -> bytes:
        """Encode once and keep it: the library holds the pointer, not a copy."""
        cached = self._topics.get(topic)
        if cached is None:
            cached = topic.encode("utf-8")
            self._topics[topic] = cached
        return cached

    def publisher(self, topic: str) -> None:
        """Announce that this node publishes `topic`. Publish with `publish*` afterwards."""
        raw = self._topic_bytes(topic)
        _check(
            self._lib,
            self._lib.qnnt_publisher_start(raw, len(raw), None, 0, None),
            f"publisher_start({topic})",
        )

    def publish(self, topic: str, data: bytes) -> None:
        """Publish raw bytes. For a text topic, include the trailing newline yourself."""
        raw = self._topic_bytes(topic)
        _check(self._lib, self._lib.qnnt_publish(raw, len(raw), data, len(data)), f"publish({topic})")

    def publish_object(self, topic: str, value: Any) -> None:
        """Encode `value` as one TOLD frame and publish it."""
        self.publish(topic, told.dumps(value))

    def remove_publisher(self, topic: str) -> bool:
        """Stop publishing `topic`, leaving the rest of the node running.

        Joins the topic's worker threads before returning, so afterwards nothing is still
        writing to its subscribers and the registration is gone. Returns False when nothing
        of that name was publishing here, which makes it safe to call speculatively.
        """
        raw = self._topic_bytes(topic)
        return self._lib.qnnt_remove_publisher(raw, len(raw)) == 0

    def remove_subscriber(self, topic: str) -> bool:
        """Stop every subscription on `topic`, leaving the rest of the node running.

        A topic reached through `subscribe_pattern` stays gone -- the pattern will not
        rejoin it. Messages already queued are still returned by `poll`; this stops new
        ones arriving. Returns False when nothing was subscribed.
        """
        raw = self._topic_bytes(topic)
        return self._lib.qnnt_remove_subscriber(raw, len(raw)) == 0

    # --- request/reply ------------------------------------------------------------
    #
    # The responder side DOES call into Python from a library thread, which the delivery
    # path deliberately does not. The reasoning that rules it out there does not apply
    # here: it is per message against per request, and a request has already paid for a TCP
    # handshake, so one FFI crossing on top is noise. What remains is the exception
    # problem, and that has a sensible answer for a procedure -- a handler that raises has
    # declined, so it is reported to the caller as `refused` and the traceback is printed
    # rather than swallowed.

    def add_responder(self, procedure: str, handler) -> None:
        """Serve `procedure`. `handler(procedure: str, request: bytes) -> bytes | None`.

        Returning None refuses the request, which the caller sees as RpcStatus.refused --
        distinct from returning b"", which is an empty but successful reply. A handler that
        raises is treated as a refusal.

        Requests are served one at a time, so a handler touching shared state needs no lock.
        """
        raw = self._topic_bytes(procedure)

        def trampoline(name_ptr, name_len, req_ptr, req_len, out_len, _user):
            try:
                name = C.string_at(name_ptr, name_len).decode("utf-8", "replace")
                request = C.string_at(req_ptr, req_len) if req_len else b""
                reply = handler(name, request)
            except Exception:  # noqa: BLE001 -- a raising handler is a refusal, not a crash
                import traceback

                traceback.print_exc()
                return None
            if reply is None:
                return None
            if not isinstance(reply, (bytes, bytearray, memoryview)):
                raise TypeError("a responder must return bytes or None")
            reply = bytes(reply)
            # The C side reads these bytes AFTER this returns, so they have to outlive the
            # call. Held until this procedure answers again, or is removed.
            self._replies[procedure] = reply
            out_len[0] = len(reply)
            # The address of the stored bytes. Kept in _replies, so the buffer this points
            # at outlives the return -- which is the whole contract for a reply.
            return C.cast(C.c_char_p(reply), C.c_void_p).value

        cb = self._RESPONDER_FN(trampoline)
        # Both the closure and the ctypes thunk have to outlive this call, or the library
        # is left holding a pointer to a collected object.
        self._responders[procedure] = cb
        try:
            _check(
                self._lib,
                self._lib.qnnt_add_responder(raw, len(raw), C.cast(cb, C.c_void_p), None),
                f"add_responder({procedure})",
            )
        except Error:
            self._responders.pop(procedure, None)
            raise

    def remove_responder(self, procedure: str) -> bool:
        """Stop serving `procedure`, leaving the rest of the node running.

        Joins the responder's threads before returning, so afterwards the handler is not
        running and will not be called again. Returns False when nothing of that name was
        being served here.
        """
        raw = self._topic_bytes(procedure)
        removed = self._lib.qnnt_remove_responder(raw, len(raw)) == 0
        if removed:
            self._responders.pop(procedure, None)
            self._replies.pop(procedure, None)
        return removed

    def request(self, procedure: str, data: bytes = b"", *, timeout: float = 5.0,
                max_reply: int = 1 << 20) -> bytes:
        """Call `procedure` and wait for the reply. Raises Error on anything but success.

        This blocks for up to `timeout` seconds. Use `request_begin` from anything with a
        UI or a control loop -- an unreachable host costs the whole timeout here.
        """
        raw = self._topic_bytes(procedure)
        out = (C.c_ubyte * max_reply)()
        written = C.c_size_t(0)
        status = self._lib.qnnt_request(
            raw, len(raw), data, len(data), int(timeout * 1000),
            out, max_reply, C.byref(written),
        )
        if status != 0:
            name = self._lib.qnnt_rpc_status_name(status).decode()
            raise Error(status, name, f"request({procedure})")
        return bytes(bytearray(out[: written.value]))

    def request_object(self, procedure: str, value: Any, **kwargs) -> Any:
        """`request` with a TOLD frame in each direction."""
        return told.loads(self.request(procedure, told.dumps(value), **kwargs))

    def request_begin(self, procedure: str, data: bytes = b"", *, timeout: float = 5.0) -> int:
        """Start a request and return a ticket at once; 0 if it could not be started.

        The reply arrives through `poll_replies`, matched by the ticket. Nothing blocks.
        """
        raw = self._topic_bytes(procedure)
        return self._lib.qnnt_request_begin(raw, len(raw), data, len(data), int(timeout * 1000))

    def poll_replies(self, *, timeout: float | None = 0.0, max_replies: int = 64) -> list[Reply]:
        """Drain completed requests. `timeout=None` waits until one completes."""
        buf = (_CReply * max_replies)()
        count = C.c_size_t(0)
        ms = -1 if timeout is None else int(timeout * 1000)
        _check(self._lib, self._lib.qnnt_poll_replies(buf, max_replies, ms, C.byref(count)),
               "poll_replies")
        out: list[Reply] = []
        for i in range(count.value):
            r = buf[i]
            out.append(Reply(
                id=r.id,
                status=RpcStatus(r.status),
                procedure=C.string_at(r.procedure, r.procedure_len).decode("utf-8", "replace"),
                data=bytes(bytearray(r.data[: r.data_len])) if r.data_len else b"",
            ))
        return out

    def requests_in_flight(self) -> int:
        """How many `request_begin` calls have not yet completed."""
        return self._lib.qnnt_requests_in_flight()

    def subscribe(self, topic: str, *, frames: bool = False) -> None:
        """Subscribe, delivering into the queue that `poll` drains.

        `frames=True` for a topic carrying TOLD frames, which is also what lets a payload
        contain arbitrary bytes; the default reads newline-delimited text.
        """
        raw = self._topic_bytes(topic)
        mode = _QUEUE_FRAMES if frames else _QUEUE_TEXT
        _check(
            self._lib,
            self._lib.qnnt_subscribe_queue(raw, len(raw), mode),
            f"subscribe({topic})",
        )

    def subscribe_pattern(
        self, pattern: str, *, frames: bool = False, rescan: float = 0.5
    ) -> None:
        """Subscribe to every topic matching a glob, now and as they appear.

        `*` spans any run of characters, `?` exactly one. Each match becomes its own
        subscription, all feeding the one queue `poll` drains -- and every `Message`
        carries its own `topic`, so telling the streams apart costs nothing extra.

        `rescan` is how often, in seconds, to look for topics that have appeared since;
        0 joins what exists now and then stops looking, for a one-shot capture.

        This is a separate call from `subscribe`, not `subscribe` noticing a `*`, because
        it costs a poll of the registry and one connection per matching publisher. A node's
        own topics match its own pattern and it will subscribe to itself; filter on
        `message.topic` if that is not what you want.
        """
        raw = self._topic_bytes(pattern)
        mode = _QUEUE_FRAMES if frames else _QUEUE_TEXT
        _check(
            self._lib,
            self._lib.qnnt_subscribe_pattern_queue(raw, len(raw), mode, int(rescan * 1000)),
            f"subscribe_pattern({pattern})",
        )

    def topic_matches(self, pattern: str, topic: str) -> bool:
        """Does `topic` match `pattern`, by the same rules `subscribe_pattern` used?

        The library's own matcher, not a re-implementation, so a program deciding what a
        message is cannot disagree with what it subscribed to. Note `*` crosses `/` here,
        unlike a shell glob.
        """
        pat = self._topic_bytes(pattern)
        name = self._topic_bytes(topic)
        return bool(self._lib.qnnt_topic_matches(pat, len(pat), name, len(name)))

    # --- receiving ---------------------------------------------------------------

    def poll(self, *, timeout: float | None = 0.0, max_messages: int = 1024) -> list[Message]:
        """Drain up to `max_messages`, waiting at most `timeout` seconds.

        `timeout=0` returns immediately with whatever is queued; `timeout=None` waits
        until something arrives. Returns a list rather than a generator so the native
        storage is fully copied out before you touch any of it -- the next `poll` recycles
        that storage.
        """
        if max_messages != self._batch_size:
            self._batch = (_CMessage * max_messages)()
            self._batch_size = max_messages

        ms = -1 if timeout is None else int(timeout * 1000)
        _check(
            self._lib,
            self._lib.qnnt_poll(self._batch, max_messages, ms, C.byref(self._count)),
            "poll",
        )

        out: list[Message] = []
        for i in range(self._count.value):
            entry = self._batch[i]
            topic = bytes(bytearray(entry.topic[0 : entry.topic_len])).decode("utf-8")
            data = bytes(bytearray(entry.data[0 : entry.data_len])) if entry.data_len else b""
            out.append(Message(topic=topic, data=data, received_us=int(entry.received_us)))
        return out

    def stream(self, *, timeout: float | None = 0.25) -> Iterator[Message]:
        """Yield messages forever, re-polling as batches run out.

        Stops when a handled signal requests shutdown, so it is usable as a main loop.
        """
        while not self.stop_requested:
            for message in self.poll(timeout=timeout):
                yield message

    def poll_events(self, max_events: int = 64) -> list["Event"]:
        """Drain buffered connection events.

        Python has no event callback on purpose: the library would call it on one of its own
        threads, so ctypes would acquire the GIL there -- on this node's accept thread or a
        subscriber's read thread -- and a Python handler would hold up the library while it
        ran. Events are buffered instead and handed over here, the same trade `poll` makes
        for messages.

        Nothing is lost before the first call: buffering starts with the node, not with the
        first poll. Past 64 undrained events the newest are dropped and counted in
        `events_dropped`.
        """
        if max_events <= 0:
            return []

        buffer = (_CEvent * max_events)()
        written = C.c_size_t(0)
        _check(self._lib,
               self._lib.qnnt_poll_events(buffer, max_events, C.byref(written)),
               "poll_events")

        out: list[Event] = []
        for i in range(written.value):
            record = buffer[i]
            # Copied now: the pointers are only valid until the next call.
            out.append(Event(
                kind=EventKind(record.event),
                topic=C.string_at(record.topic, record.topic_len).decode("utf-8", "replace"),
                peer=C.string_at(record.peer, record.peer_len).decode("utf-8", "replace"),
                subscribers=int(record.subscribers),
                at_us=int(record.at_us),
            ))
        return out

    @property
    def events_dropped(self) -> int:
        """Events discarded because nothing drained the queue."""
        return int(self._lib.qnnt_events_dropped())

    def subscriber_count(self, topic: str) -> int:
        """Subscribers connected to this node's publisher for `topic`."""
        raw = self._topic_bytes(topic)
        return int(self._lib.qnnt_subscriber_count(raw, len(raw)))

    def wait_for_subscriber(self, topic: str, *, timeout: float = 5.0) -> bool:
        """Block until `topic` has a subscriber, or the timeout expires.

        What a publisher should call before its first message: a subscriber cannot attach
        until this publisher has registered AND the subscriber's next registry probe comes
        round, so the delay is neither zero nor predictable. Sleeping a guess loses the
        opening messages, because qnnt has no replay.
        """
        raw = self._topic_bytes(topic)
        return bool(self._lib.qnnt_wait_for_subscriber(raw, len(raw), int(timeout * 1000)))

    def wait_for_subscribers(self, topic: str, count: int, *, timeout: float = 5.0) -> bool:
        """Block until `topic` has `count` subscribers, or the timeout expires.

        For a node that knows how many peers to expect: waiting for one stops a publisher
        shouting into an empty room, while waiting for all of them means every peer sees
        the stream from its first message.
        """
        raw = self._topic_bytes(topic)
        return bool(self._lib.qnnt_wait_for_subscribers(raw, len(raw), int(count),
                                                        int(timeout * 1000)))

    def set_stale_timeout(self, ms: int) -> None:
        """Silence after which a connected subscription counts as stale. 0 disables it.

        Once set, a quiet subscription produces EventKind.publisher_stale, which
        `poll_events` will hand over, followed by publisher_resumed when data returns.
        """
        self._lib.qnnt_set_stale_timeout(int(ms))

    @property
    def dropped(self) -> int:
        """Messages discarded because the queue was full. Non-zero means falling behind."""
        return int(self._lib.qnnt_queue_dropped())


def version() -> str:
    """The TOLD wire-format version this build speaks."""
    return told.version()
