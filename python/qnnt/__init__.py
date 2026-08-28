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
import os
from dataclasses import dataclass
from typing import Any, Iterator, Sequence

from . import tld
from ._lib import Error, Message as _CMessage, declare, load

__all__ = ["Node", "Message", "Error", "tld", "version"]

_QUEUE_TEXT = 0
_QUEUE_FRAMES = 1


def _check(lib: C.CDLL, status: int, context: str) -> None:
    if status != 0:
        raise Error(status, lib.qnnt_status_name(status).decode(), context)


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
        """The payload decoded as a TLD frame, for topics carrying frames."""
        return tld.loads(self.data)


class Node:
    """A running qnnt node. Use as a context manager so it is always shut down."""

    _open: "Node | None" = None

    def __init__(
        self,
        *,
        registry_port: int | None = None,
        queue_capacity: int = 4096,
        handle_signals: bool = False,
    ) -> None:
        if Node._open is not None:
            raise RuntimeError("a qnnt Node is already open; the library is a process singleton")

        self._lib = declare(load())

        # Precedence: the argument, then QNNT_REGISTRY_PORT, then the library default.
        # The library reads no environment itself -- that is deliberate, so this is the
        # layer that decides where the value comes from.
        if registry_port is None:
            env = os.environ.get("QNNT_REGISTRY_PORT")
            registry_port = int(env) if env else None
        if registry_port is not None:
            _check(
                self._lib,
                self._lib.qnnt_set_registry_port(registry_port),
                f"set_registry_port({registry_port})",
            )
        # Topics are retained by the library rather than copied, so the encoded bytes have
        # to be kept alive here for as long as the subscription exists.
        self._topics: dict[str, bytes] = {}
        self._closed = False

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
        """Encode `value` as one TLD frame and publish it."""
        self.publish(topic, tld.dumps(value))

    def subscribe(self, topic: str, *, frames: bool = False) -> None:
        """Subscribe, delivering into the queue that `poll` drains.

        `frames=True` for a topic carrying TLD frames, which is also what lets a payload
        contain arbitrary bytes; the default reads newline-delimited text.
        """
        raw = self._topic_bytes(topic)
        mode = _QUEUE_FRAMES if frames else _QUEUE_TEXT
        _check(
            self._lib,
            self._lib.qnnt_subscribe_queue(raw, len(raw), mode),
            f"subscribe({topic})",
        )

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

    @property
    def dropped(self) -> int:
        """Messages discarded because the queue was full. Non-zero means falling behind."""
        return int(self._lib.qnnt_queue_dropped())


def version() -> str:
    """The TLD wire-format version this build speaks."""
    return tld.version()
