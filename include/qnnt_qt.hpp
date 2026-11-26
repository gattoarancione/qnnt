/*
 * qnnt_qt.hpp -- a proposed Qt signal/slot interface for qnnt.
 *
 * Shaped after the original Qt/nng `Qnnt` class, but declaring only what the Zig library
 * can actually do today. Everything the old class had that has no implementation behind it
 * is listed at the bottom, with what each would require, rather than declared here and left
 * to fail at run time.
 *
 * STATUS: proposal, but a working one. Compiled with Qt 6.10.3 on macOS (moc over this
 * header and over the example), linked against the qnnt C ABI, and run: it starts a node,
 * publishes on two topics, receives both a text stream and TOLD frames as signals on the Qt
 * thread, and unpacks a struct carrying QString, QList<double> and QByteArray members.
 *
 *     zig build qt-demo -Dqt=/path/to/Qt/6.10.3/macos     (examples/qt_demo.cpp)
 *
 * What is settled is the shape; what is not is the naming and the division of labour with
 * your application, which is what this is for review on. It has only been built on macOS.
 *
 * Two constraints shape the whole design.
 *
 * 1. The library is a process singleton. qnnt_init/qnnt_deinit are global, there is one
 *    registry role and one message queue per process, and a second initialisation is
 *    refused. So this is not a class you instantiate per component: it is one object with
 *    an accessor, and the constructor is private.
 *
 * 2. Messages arrive on qnnt's own threads, which are not Qt threads. Emitting a signal
 *    from there and hoping is how a Qt program acquires intermittent crashes. This design
 *    therefore uses the library's poll queue rather than its callbacks: a worker thread
 *    drains the queue and emits into the object's thread through a queued connection, so
 *    every slot runs where the receiver expects, with a QByteArray it owns.
 *
 *    That choice also removes a per-message FFI crossing -- one poll returns a batch --
 *    which is why the queue exists.
 *
 * Build: needs Qt Core, the qnnt C ABI (include/qnnt.h) and the TOLD C++ header
 * (include/told.hpp). Run moc over this file; with CMake, AUTOMOC handles it.
 */

#ifndef QNNT_QT_HPP
#define QNNT_QT_HPP

#include "qnnt.h"
#include "told.hpp"

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QMap>
#include <QObject>
#include <QPair>
#include <QString>
#include <QThread>

#include <atomic>
#include <cstring>
#include <functional>
#include <optional>
#include <vector>

/* ---------------------------------------------------------------- Qt types in TOLD
 *
 * So a Qt model class can carry QString and QList members and still be packed by the
 * macros from told.hpp:
 *
 *     struct Telemetry {
 *         QString name;
 *         QList<double> samples;
 *         QByteArray blob;
 *         TOLD_DEFINE_MAP(name, samples, blob)
 *     };
 *
 * QString goes out as UTF-8 in a STRING frame, so a Zig or Python peer reads it as a
 * plain string; QByteArray goes out as a BUFFER, because a QByteArray is bytes and
 * claiming otherwise would put invalid UTF-8 in a field a peer may validate.
 */

template <>
struct told::Adaptor<QString> {
    static void pack(Encoder& enc, const QString& value) {
        const QByteArray utf8 = value.toUtf8();
        enc.writeString(std::string_view{utf8.constData(), static_cast<std::size_t>(utf8.size())});
    }
    static void unpack(const Frame& frame, QString& out) {
        // Either framing is accepted: a peer may have chosen BUFFER for the same field.
        if (frame.type() == Type::string) {
            const std::string_view text = frame.asString();
            out = QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
        } else {
            const Bytes raw = frame.asBuffer();
            out = QString::fromUtf8(reinterpret_cast<const char*>(raw.data()),
                                    static_cast<qsizetype>(raw.size()));
        }
    }
};

template <>
struct told::Adaptor<QByteArray> {
    static void pack(Encoder& enc, const QByteArray& value) {
        enc.writeBuffer(Bytes{reinterpret_cast<const std::uint8_t*>(value.constData()),
                              static_cast<std::size_t>(value.size())});
    }
    static void unpack(const Frame& frame, QByteArray& out) {
        if (frame.type() == Type::string) {
            const std::string_view text = frame.asString();
            out = QByteArray{text.data(), static_cast<qsizetype>(text.size())};
        } else {
            const Bytes raw = frame.asBuffer();
            out = QByteArray{reinterpret_cast<const char*>(raw.data()),
                             static_cast<qsizetype>(raw.size())};
        }
    }
};

template <class T>
struct told::Adaptor<QList<T>> {
    static void pack(Encoder& enc, const QList<T>& value) {
        auto scope = enc.beginArray();
        for (const T& item : value) packValue(enc, item);
        scope.close();
    }
    static void unpack(const Frame& frame, QList<T>& out) {
        out.clear();
        for (const Frame& item : frame.array()) {
            T element{};
            unpackValue(item, element);
            out.append(std::move(element));
        }
    }
};

template <class V>
struct told::Adaptor<QMap<QString, V>> {
    static void pack(Encoder& enc, const QMap<QString, V>& value) {
        auto scope = enc.beginObject();
        for (auto it = value.cbegin(); it != value.cend(); ++it) {
            Adaptor<QString>::pack(enc, it.key());
            packValue(enc, it.value());
        }
        scope.close();
    }
    static void unpack(const Frame& frame, QMap<QString, V>& out) {
        out.clear();
        for (const Field& field : frame.object()) {
            V element{};
            unpackValue(field.value, element);
            out.insert(QString::fromUtf8(field.key.data(),
                                         static_cast<qsizetype>(field.key.size())),
                       std::move(element));
        }
    }
};

template <class V>
struct told::Adaptor<QHash<QString, V>> {
    static void pack(Encoder& enc, const QHash<QString, V>& value) {
        auto scope = enc.beginObject();
        for (auto it = value.cbegin(); it != value.cend(); ++it) {
            Adaptor<QString>::pack(enc, it.key());
            packValue(enc, it.value());
        }
        scope.close();
    }
    static void unpack(const Frame& frame, QHash<QString, V>& out) {
        out.clear();
        for (const Field& field : frame.object()) {
            V element{};
            unpackValue(field.value, element);
            out.insert(QString::fromUtf8(field.key.data(),
                                         static_cast<qsizetype>(field.key.size())),
                       std::move(element));
        }
    }
};

namespace qnnt {

class QnntPoller; // below

/* ---------------------------------------------------------------- the node
 *
 * One object per process. Configure it, start it, connect to its signals.
 *
 *     auto *node = qnnt::QnntNode::instance();
 *     node->setRegistryPort(2222);
 *     node->setClusterKey("secret");
 *     node->addPeer("10.0.0.9");
 *     connect(node, &QnntNode::messageAvailable, this, &Widget::onMessage);
 *     node->start();
 *     node->addPublisher("test/topic-a");
 *     node->addSubscriber("test/topic-b");
 *     node->publish("test/topic-a", QByteArray("hello\n"));
 *
 * Note the trailing newline. A topic is either a newline-delimited text stream or a TOLD
 * frame stream, and that is a property of the topic rather than of a call: publish text
 * with a delimiter, or publish frames and let subscribers read them as Delivery::Frames.
 * The template publish() below always produces a frame, so it needs no delimiter.
 */
class QnntNode : public QObject
{
    Q_OBJECT

public:
    /// How a subscription reads its stream. Framing belongs to the topic, so this must
    /// match what the publisher writes.
    enum class Delivery {
        Text,  ///< newline-delimited; `data` is one line, delimiter included
        Frames ///< TOLD; `data` is one whole frame, ready for told::unpack
    };
    Q_ENUM(Delivery)

    /// The one instance. Created on first call, parented to nothing; call stop() before
    /// the application exits, or let the destructor do it.
    static QnntNode* instance();

    ~QnntNode() override;

    QnntNode(const QnntNode&) = delete;
    QnntNode& operator=(const QnntNode&) = delete;

    /* --- configuration: all of it must precede start() ------------------------ */

    bool setRegistryPort(quint16 port);
    bool setAdvertiseAddress(const QString& address);
    bool setBindAddress(const QString& address);
    bool setFederationPort(quint16 port);
    bool setClusterKey(const QString& key);
    /// `host` may be an address or a name; port 0 means the federation port.
    bool addPeer(const QString& host, quint16 port = 0);
    /// Linux only, and needs privilege; see qnnt.h. Refusal is reported on stderr.
    bool setRealtimePriority(quint8 priority);
    bool setLockMemory(bool enabled);
    /// Stack for per-connection and per-request threads; 0 is the default. See qnnt.h.
    bool setHandlerStackBytes(size_t bytes);
    /// Same-host traffic over Unix sockets, remote over TCP; on by default. See qnnt.h.
    bool setLocalSockets(bool enabled);
    /// Where those sockets go; empty restores /tmp/qnnt-<uid>.
    bool setSocketDir(const QString& path);
    /// Size the poll queue before the first subscription. Optional.
    bool reserveQueue(int capacity);
    /// Apply every QNNT_* environment variable, so a Qt program configures like the others.
    void configureFromEnvironment();

    /* --- lifecycle ------------------------------------------------------------ */

    /// Initialise the library and start draining the queue. Emits started(), or
    /// errorOccurred() and returns false.
    bool start();
    /// Stop the poller and tear the node down. Emits stopped(). Idempotent.
    void stop();
    bool isRunning() const;

    /// Install qnnt's SIGINT/SIGTERM handlers, which set a flag rather than exiting, and
    /// emit stopRequested() when it is seen. Opt-in: a Qt application may prefer its own.
    void installSignalHandlers();

    /* --- publishing ----------------------------------------------------------- */

    /// Start a manually-driven publisher for `topic`.
    bool addPublisher(const QString& topic);

    /// Start a self-paced publisher: `source` is called every `periodMicros` on a library
    /// thread, NOT on a Qt thread, and whatever it returns is published. Return an empty
    /// QByteArray to skip a tick. Keep it free of Qt object access for that reason; if you
    /// need Qt state, use addPublisher() and publish() from a QTimer instead.
    bool addScheduledPublisher(const QString& topic, quint64 periodMicros,
                               std::function<QByteArray()> source);

    bool publish(const QString& topic, const QByteArray& data);
    bool publish(const QString& topic, const char* data, int size);

    /// Pack any TOLD-mapped type and publish it as one frame -- the replacement for the old
    /// pub<T>() and its msgpack::pack. Subscribers read the topic as Delivery::Frames.
    template <class T>
    bool publishPacked(const QString& topic, const T& value) {
        const std::vector<std::uint8_t> bytes = told::pack(value);
        return publish(topic, reinterpret_cast<const char*>(bytes.data()),
                       static_cast<int>(bytes.size()));
    }

    /* --- subscribing ---------------------------------------------------------- */

    /* --- connection state ----------------------------------------------------- */

    /// Subscribers connected to this node's publisher for `topic`.
    int subscriberCount(const QString& topic) const;

    /// Block until `topic` has a subscriber, or the timeout expires. Returns whether it
    /// has one.
    ///
    /// Prefer connecting to subscriberConnected() in a Qt program -- this blocks the
    /// calling thread, and blocking the GUI thread is rarely what you want. It is here for
    /// startup code that legitimately wants to wait before publishing anything.
    bool waitForSubscriber(const QString& topic, int timeoutMs = 5000);

    /// Silence after which a connected subscription emits publisherStale(). 0 disables it,
    /// which is the default: a quiet topic is not in itself an error.
    void setStaleTimeout(int ms);
    int staleTimeout() const;

    /// Subscribe through the poll queue. Messages arrive as messageAvailable() (Text) or
    /// frameAvailable() (Frames), on this object's thread.
    bool addSubscriber(const QString& topic, Delivery delivery = Delivery::Text);

    /// Subscribe to every topic matching a glob, now and as they appear. '*' spans any run
    /// of characters, '?' exactly one, and both cross '/' -- so "room/*" also matches
    /// "room/kitchen/light". Messages arrive through the same two signals, and the topic
    /// each carries says which stream it came from.
    ///
    /// `rescanMs` is how often to look for topics that have appeared since; 0 joins what
    /// exists now and then stops looking. A pattern costs a poll of the registry and one
    /// connection per matching publisher, which is why it is a separate call from
    /// addSubscriber() rather than that one noticing a '*'.
    bool addSubscriberPattern(const QString& pattern, Delivery delivery = Delivery::Text,
                              int rescanMs = 500);

    /// Stop publishing a topic, without stopping the node. Joins that publisher's threads
    /// before returning, so once it does, no scheduler callback for this topic can still be
    /// running and the std::function behind it is released.
    ///
    /// False when nothing of that name was publishing here -- so it is safe to call
    /// speculatively -- and also when called from that topic's own source callback, which
    /// would otherwise wait for the calling thread.
    bool removePublisher(const QString& topic);

    /// --- request/reply ---------------------------------------------------------
    ///
    /// The other shape: one request, one reply, addressed to a name. Procedures live in
    /// the same directory as topics -- so they federate and expire the same way -- but the
    /// two cannot be crossed: requesting a topic fails rather than hanging.

    /// Serve `procedure` on this node. Return std::nullopt to refuse, which the caller sees
    /// as QNNT_RPC_REFUSED -- distinct from returning an empty QByteArray, which is an
    /// empty but successful reply.
    ///
    /// The handler runs on the RESPONDER'S thread, not the Qt thread, exactly as
    /// addScheduledPublisher()'s source does. Requests are served one at a time, so it
    /// needs no lock against itself -- but it does against anything the GUI touches.
    bool addResponder(const QString& procedure,
                      std::function<std::optional<QByteArray>(const QString&, const QByteArray&)> handler);

    /// Stop serving it: joins the responder's threads, then drops the registration. False
    /// when nothing of that name was served here, and when called from its own handler.
    bool removeResponder(const QString& procedure);

    /// One request, BLOCKING the calling thread until the reply arrives or the timeout
    /// expires. Never call this from the GUI thread with a timeout you would not freeze
    /// for -- that is what requestBegin() is for. `status`, if given, receives the outcome.
    QByteArray request(const QString& procedure, const QByteArray& data,
                       int timeoutMs = 5000, qnnt_rpc_status* status = nullptr);

    /// Start a request and return a ticket at once; 0 if it could not be started. The
    /// reply arrives as replyAvailable() on this object's thread, matched by the ticket.
    /// Nothing blocks, which is what makes this the one to call from a GUI.
    quint64 requestBegin(const QString& procedure, const QByteArray& data, int timeoutMs = 5000);

    /// requestBegin() with a TOLD-mapped type as the payload -- the counterpart of
    /// publishPacked(). Decode the reply with unpacked<T>().
    template <class T>
    quint64 requestBeginPacked(const QString& procedure, const T& value, int timeoutMs = 5000) {
        const auto bytes = told::pack(value);
        return requestBegin(procedure,
                            QByteArray(reinterpret_cast<const char*>(bytes.data()),
                                       static_cast<qsizetype>(bytes.size())),
                            timeoutMs);
    }

    /// How many requestBegin() calls have not yet completed.
    int requestsInFlight() const { return static_cast<int>(qnnt_requests_in_flight()); }

    /// Stop every subscription on a topic, whichever call started it. A topic reached
    /// through addSubscriberPattern() stays gone: the pattern will not rejoin it.
    ///
    /// False when nothing was subscribed, and when called from that topic's own
    /// messageAvailable()/frameAvailable() handler -- see removePublisher().
    bool removeSubscriber(const QString& topic);

    /// Decode a frame from frameAvailable() into a TOLD-mapped type -- the replacement for
    /// the old getUnpacked<T>(). Throws told::Error on a malformed frame.
    template <class T>
    static T unpacked(const QByteArray& frame) {
        return told::unpack<T>(
            told::Bytes{reinterpret_cast<const std::uint8_t*>(frame.constData()),
                             static_cast<std::size_t>(frame.size())});
    }

    /* --- state ---------------------------------------------------------------- */

    /// This node's identity, the 32 hex characters federation uses to attribute entries.
    QString nodeId() const;
    quint16 registryPort() const;
    QString advertiseAddress() const;
    bool federationEnabled() const;
    /// Messages discarded because the queue was full. Monotonic; the newest is dropped.
    quint64 droppedCount() const;

Q_SIGNALS:
    /// Internal: carries a library event across the thread boundary. Connect to the named
    /// signals above instead.
    void eventRelay(int event, const QString& topic, const QString& peer, int count);

    void started();
    void stopped();

    /// One newline-delimited message, delimiter included, on a Delivery::Text topic.
    void messageAvailable(const QString& topic, const QByteArray& data);

    /// One whole TOLD frame on a Delivery::Frames topic. Pass it to unpacked<T>().
    void frameAvailable(const QString& topic, const QByteArray& frame);

    /// A request started with requestBegin() has completed. `status` is a qnnt_rpc_status;
    /// compare against QNNT_RPC_OK. Emitted on this object's thread, so a slot may touch
    /// the GUI directly.
    void replyAvailable(quint64 id, int status, const QString& procedure, const QByteArray& data);

    /// The queue overflowed and discarded messages; `total` is cumulative. Emitted when the
    /// count changes, so connecting to it is how a Qt program notices it is falling behind.
    void messagesDropped(quint64 total);

    /// A signal handler asked the process to stop, if installSignalHandlers() was called.
    void stopRequested();

    /// A subscriber connected to one of this node's publishers. `count` is how many that
    /// topic now has, so `count == 1` is the moment publishing becomes worthwhile.
    void subscriberConnected(const QString& topic, const QString& peer, int count);

    /// A subscriber's connection was found broken while publishing to it.
    void subscriberDisconnected(const QString& topic, const QString& peer, int count);

    /// One of this node's subscriptions attached to a publisher.
    void publisherConnected(const QString& topic, const QString& peer);

    /// A publisher this node was subscribed to closed the stream. The subscription retries
    /// on its own; this is notification, not a call to action.
    void publisherDisconnected(const QString& topic, const QString& peer);

    /// Nothing has arrived on a connected subscription for the stale timeout. Only emitted
    /// when setStaleTimeout() has been called with a non-zero value.
    void publisherStale(const QString& topic);

    /// Data arrived on a subscription that had gone stale.
    void publisherResumed(const QString& topic);

    /// A library call failed. `context` names the call, `status` is the qnnt_status value
    /// and `statusName` its spelling from qnnt_status_name().
    void errorOccurred(const QString& context, int status, const QString& statusName);

private Q_SLOTS:
    /// Where a library event lands, on this object's thread. The trampoline below emits
    /// eventRelay() from a library thread; the queued connection to this slot is what
    /// moves it, so every signal above is emitted where the receiver expects.
    void eventDelivered(int event, const QString& topic, const QString& peer, int count);

    /// Where the poller's queued signal lands, on this object's thread. Chooses which
    /// public signal to emit, since the queue carries bytes without recording the framing
    /// that produced them.
    void messageDelivered(const QString& topic, const QByteArray& data);

private:
    explicit QnntNode(QObject* parent = nullptr);

    bool check(qnnt_status status, const QString& context);

    /// Which framing a delivered topic was subscribed with -- a literal subscription, or
    /// failing that whichever pattern matches it.
    Delivery deliveryFor(const QString& topic) const;

    QThread* m_thread = nullptr;
    QnntPoller* m_poller = nullptr;
    bool m_running = false;
    QMap<QString, Delivery> m_subscriptions;
    // Patterns cannot go in the map above: their topics are discovered later, so there is
    // nothing to key on when the subscription is made. Kept in order and consulted only
    // when a topic is not a literal subscription.
    QList<QPair<QString, Delivery>> m_patterns;
    /// Kept alive for the lifetime of the publisher: the C ABI holds the raw pointer.
    QMap<QString, std::function<QByteArray()>> m_sources;
    /// The C ABI keeps a raw pointer to each of these for as long as the responder runs.
    QMap<QString, std::function<std::optional<QByteArray>(const QString&, const QByteArray&)>> m_responders;
    /// The last reply each procedure returned. The library reads those bytes after the
    /// handler returns, so they have to outlive it.
    QMap<QString, QByteArray> m_lastReply;

    friend class QnntPoller;
};

/* ---------------------------------------------------------------- the poller
 *
 * Lives in its own QThread and does nothing but drain the queue. Its signals are connected
 * to QnntNode's with a queued connection, which is what moves delivery onto the Qt thread.
 *
 * qnnt_poll blocks up to its timeout, so this costs one sleeping thread rather than a
 * timer waking the event loop to find nothing. The timeout is what makes stop() prompt.
 */
class QnntPoller : public QObject
{
    Q_OBJECT

public:
    explicit QnntPoller(QObject* parent = nullptr) : QObject{parent} {}

    void requestStop() { m_stop.store(true); }

public Q_SLOTS:
    void run();

Q_SIGNALS:
    void message(const QString& topic, const QByteArray& data);
    void reply(quint64 id, int status, const QString& procedure, const QByteArray& data);
    void dropped_(quint64 total);
    void stopSeen();
    void finished();

private:
    static constexpr int kBatch = 64;
    static constexpr int kTimeoutMs = 100;

    std::atomic<bool> m_stop{false};
};

} // namespace qnnt

/* ---------------------------------------------------------------- implementation
 *
 * Inline so the header stands alone; only moc has to run over it.
 */

namespace qnnt {

inline void QnntPoller::run() {
    qnnt_message batch[kBatch];
    quint64 last_dropped = 0;

    while (!m_stop.load()) {
        std::size_t count = 0;
        // Blocks up to the timeout, so an idle node costs a sleeping thread rather than a
        // timer waking the event loop to find nothing. The timeout is what bounds stop().
        const qnnt_status status = qnnt_poll(batch, kBatch, kTimeoutMs, &count);
        if (status != QNNT_OK) {
            // A poll failure with no subscriptions yet is normal; just back off.
            QThread::msleep(kTimeoutMs);
            continue;
        }

        for (std::size_t i = 0; i < count; ++i) {
            const qnnt_message& msg = batch[i];
            // Copied here, on this thread: the library's buffer is reused as soon as the
            // next poll runs, and the receiving slot may look at it much later.
            Q_EMIT message(QString::fromUtf8(msg.topic, static_cast<qsizetype>(msg.topic_len)),
                           QByteArray(reinterpret_cast<const char*>(msg.data),
                                      static_cast<qsizetype>(msg.data_len)));
        }

        // Replies share this thread rather than getting one of their own, and that is only
        // acceptable because a completing request WAKES the poll above. Without that it
        // would sleep out its whole timeout on a node that streams nothing, and every reply
        // would arrive up to kTimeoutMs late -- far larger than the round trip it reports.
        // So this is polled with timeout 0: by the time we get here, either a message
        // arrived or a reply did.
        qnnt_reply replies[kBatch];
        std::size_t reply_count = 0;
        if (qnnt_poll_replies(replies, kBatch, 0, &reply_count) == QNNT_OK) {
            for (std::size_t i = 0; i < reply_count; ++i) {
                const qnnt_reply& r = replies[i];
                // Copied on this thread, like messages: the library recycles both buffers
                // on the next poll and the receiving slot may look much later.
                Q_EMIT reply(r.id, static_cast<int>(r.status),
                             QString::fromUtf8(r.procedure, static_cast<qsizetype>(r.procedure_len)),
                             QByteArray(reinterpret_cast<const char*>(r.data),
                                        static_cast<qsizetype>(r.data_len)));
            }
        }

        const quint64 dropped = qnnt_queue_dropped();
        if (dropped != last_dropped) {
            last_dropped = dropped;
            Q_EMIT dropped_(dropped);
        }

        if (qnnt_stop_requested()) Q_EMIT stopSeen();
    }

    Q_EMIT finished();
}

inline QnntNode* QnntNode::instance() {
    // Deliberately never destroyed. A QObject torn down by static destruction runs after
    // QCoreApplication is gone, which is where Qt programs acquire exit-time crashes, and
    // it made the linker on macOS reach for __dso_handle to register the destructor. Call
    // stop() before the application exits; nothing here relies on the destructor running.
    static QnntNode* node = new QnntNode;
    return node;
}

inline QnntNode::QnntNode(QObject* parent) : QObject{parent} {}

inline QnntNode::~QnntNode() { stop(); }

inline bool QnntNode::check(qnnt_status status, const QString& context) {
    if (status == QNNT_OK) return true;
    Q_EMIT errorOccurred(context, static_cast<int>(status),
                         QString::fromUtf8(qnnt_status_name(status)));
    return false;
}

inline bool QnntNode::setRegistryPort(quint16 port) {
    return check(qnnt_set_registry_port(port), QStringLiteral("setRegistryPort"));
}

inline bool QnntNode::setAdvertiseAddress(const QString& address) {
    return check(qnnt_set_advertise_address(address.toUtf8().constData()),
                 QStringLiteral("setAdvertiseAddress"));
}

inline bool QnntNode::setBindAddress(const QString& address) {
    return check(qnnt_set_bind_address(address.toUtf8().constData()),
                 QStringLiteral("setBindAddress"));
}

inline bool QnntNode::setFederationPort(quint16 port) {
    return check(qnnt_set_federation_port(port), QStringLiteral("setFederationPort"));
}

inline bool QnntNode::setClusterKey(const QString& key) {
    return check(qnnt_set_cluster_key(key.toUtf8().constData()),
                 QStringLiteral("setClusterKey"));
}

inline bool QnntNode::addPeer(const QString& host, quint16 port) {
    return check(qnnt_add_peer(host.toUtf8().constData(), port),
                 QStringLiteral("addPeer"));
}

inline bool QnntNode::setRealtimePriority(quint8 priority) {
    return check(qnnt_set_realtime_priority(priority),
                 QStringLiteral("setRealtimePriority"));
}

inline bool QnntNode::setLockMemory(bool enabled) {
    return check(qnnt_set_lock_memory(enabled ? 1 : 0), QStringLiteral("setLockMemory"));
}

inline bool QnntNode::setHandlerStackBytes(size_t bytes) {
    return check(qnnt_set_handler_stack_bytes(bytes), QStringLiteral("setHandlerStackBytes"));
}

inline bool QnntNode::setLocalSockets(bool enabled) {
    return check(qnnt_set_local_sockets(enabled ? 1 : 0), QStringLiteral("setLocalSockets"));
}

inline bool QnntNode::setSocketDir(const QString& path) {
    return check(qnnt_set_socket_dir(path.toUtf8().constData()), QStringLiteral("setSocketDir"));
}

inline bool QnntNode::reserveQueue(int capacity) {
    return check(qnnt_queue_reserve(static_cast<std::size_t>(capacity)),
                 QStringLiteral("reserveQueue"));
}

inline void QnntNode::configureFromEnvironment() { qnnt_configure_from_environment(); }

/// Called by the library on one of its own threads. It does the least possible: convert to
/// Qt types and emit the relay, whose queued connection carries it to the Qt thread. Doing
/// anything else here would be doing it on a library thread.
inline void qnntEventTrampoline(qnnt_event event, const char* topic, std::size_t topic_len,
                                const char* peer, std::size_t peer_len,
                                std::size_t subscribers, void* user) {
    auto* node = static_cast<QnntNode*>(user);
    Q_EMIT node->eventRelay(static_cast<int>(event),
                            QString::fromUtf8(topic, static_cast<qsizetype>(topic_len)),
                            QString::fromUtf8(peer, static_cast<qsizetype>(peer_len)),
                            static_cast<int>(subscribers));
}

inline void QnntNode::eventDelivered(int event, const QString& topic, const QString& peer,
                                     int count) {
    switch (static_cast<qnnt_event>(event)) {
    case QNNT_EVENT_SUBSCRIBER_CONNECTED:
        Q_EMIT subscriberConnected(topic, peer, count);
        break;
    case QNNT_EVENT_SUBSCRIBER_DISCONNECTED:
        Q_EMIT subscriberDisconnected(topic, peer, count);
        break;
    case QNNT_EVENT_PUBLISHER_CONNECTED:
        Q_EMIT publisherConnected(topic, peer);
        break;
    case QNNT_EVENT_PUBLISHER_DISCONNECTED:
        Q_EMIT publisherDisconnected(topic, peer);
        break;
    case QNNT_EVENT_PUBLISHER_STALE:
        Q_EMIT publisherStale(topic);
        break;
    case QNNT_EVENT_PUBLISHER_RESUMED:
        Q_EMIT publisherResumed(topic);
        break;
    }
}

inline int QnntNode::subscriberCount(const QString& topic) const {
    const QByteArray name = topic.toUtf8();
    return static_cast<int>(
        qnnt_subscriber_count(name.constData(), static_cast<std::size_t>(name.size())));
}

inline bool QnntNode::waitForSubscriber(const QString& topic, int timeoutMs) {
    const QByteArray name = topic.toUtf8();
    return qnnt_wait_for_subscriber(name.constData(),
                                    static_cast<std::size_t>(name.size()),
                                    static_cast<std::uint64_t>(timeoutMs));
}

inline void QnntNode::setStaleTimeout(int ms) {
    qnnt_set_stale_timeout(static_cast<std::uint64_t>(ms));
}

inline int QnntNode::staleTimeout() const {
    return static_cast<int>(qnnt_stale_timeout());
}

inline bool QnntNode::start() {
    if (m_running) return true;
    if (!check(qnnt_init(), QStringLiteral("start"))) return false;
    m_running = true;

    // Queued, because the trampoline emits from a library thread.
    connect(this, &QnntNode::eventRelay, this, &QnntNode::eventDelivered,
            Qt::QueuedConnection);
    qnnt_set_event_handler(&qnntEventTrampoline, this);

    m_thread = new QThread(this);
    m_poller = new QnntPoller;
    m_poller->moveToThread(m_thread);

    // The queued connection is the whole point: the poller emits on its own thread and the
    // slot -- and therefore every connected slot of ours -- runs on this object's thread.
    connect(m_thread, &QThread::started, m_poller, &QnntPoller::run);
    connect(m_poller, &QnntPoller::message, this, &QnntNode::messageDelivered,
            Qt::QueuedConnection);
    connect(m_poller, &QnntPoller::reply, this, &QnntNode::replyAvailable,
            Qt::QueuedConnection);
    connect(m_poller, &QnntPoller::dropped_, this, &QnntNode::messagesDropped,
            Qt::QueuedConnection);
    connect(m_poller, &QnntPoller::stopSeen, this, &QnntNode::stopRequested,
            Qt::QueuedConnection);
    connect(m_poller, &QnntPoller::finished, m_thread, &QThread::quit);
    connect(m_thread, &QThread::finished, m_poller, &QObject::deleteLater);

    m_thread->start();
    Q_EMIT started();
    return true;
}

inline void QnntNode::stop() {
    if (!m_running) return;

    // Before the node goes down, so no event arrives with this object half torn down.
    qnnt_set_event_handler(nullptr, nullptr);

    if (m_poller != nullptr) m_poller->requestStop();
    if (m_thread != nullptr) {
        m_thread->quit();
        // Generous: the poller can be inside a blocking poll for up to its timeout.
        m_thread->wait(2000);
        m_thread = nullptr;
        m_poller = nullptr;
    }

    qnnt_deinit();
    m_running = false;
    m_subscriptions.clear();
    m_patterns.clear();
    m_sources.clear();
    Q_EMIT stopped();
}

inline bool QnntNode::isRunning() const { return m_running; }

inline void QnntNode::installSignalHandlers() { qnnt_install_signal_handlers(); }

inline bool QnntNode::addPublisher(const QString& topic) {
    const QByteArray name = topic.toUtf8();
    return check(qnnt_publisher_start(name.constData(),
                                      static_cast<std::size_t>(name.size()),
                                      nullptr, 0, nullptr),
                 QStringLiteral("addPublisher(%1)").arg(topic));
}

inline bool QnntNode::addScheduledPublisher(const QString& topic, quint64 periodMicros,
                                            std::function<QByteArray()> source) {
    if (!source) return false;

    // The C ABI keeps the raw pointer, so the std::function has to outlive the call. The
    // map owns it for as long as the node runs.
    auto it = m_sources.insert(topic, std::move(source));

    struct Trampoline {
        static const std::uint8_t* call(const char*, std::size_t, std::size_t* out_len,
                                        void* user) {
            auto* fn = static_cast<std::function<QByteArray()>*>(user);
            // Held between calls, because the library reads the bytes after this returns.
            static thread_local QByteArray held;
            held = (*fn)();
            *out_len = static_cast<std::size_t>(held.size());
            return held.isEmpty() ? nullptr
                                  : reinterpret_cast<const std::uint8_t*>(held.constData());
        }
    };

    const QByteArray name = topic.toUtf8();
    return check(qnnt_publisher_start(name.constData(),
                                      static_cast<std::size_t>(name.size()),
                                      &Trampoline::call, periodMicros, &(*it)),
                 QStringLiteral("addScheduledPublisher(%1)").arg(topic));
}

inline bool QnntNode::publish(const QString& topic, const QByteArray& data) {
    return publish(topic, data.constData(), static_cast<int>(data.size()));
}

inline bool QnntNode::publish(const QString& topic, const char* data, int size) {
    const QByteArray name = topic.toUtf8();
    return check(qnnt_publish(name.constData(), static_cast<std::size_t>(name.size()),
                              data, static_cast<std::size_t>(size)),
                 QStringLiteral("publish(%1)").arg(topic));
}

inline bool QnntNode::addSubscriber(const QString& topic, Delivery delivery) {
    const QByteArray name = topic.toUtf8();
    const qnnt_queue_mode mode =
        delivery == Delivery::Frames ? QNNT_QUEUE_FRAMES : QNNT_QUEUE_TEXT;
    if (!check(qnnt_subscribe_queue(name.constData(),
                                    static_cast<std::size_t>(name.size()), mode),
               QStringLiteral("addSubscriber(%1)").arg(topic))) {
        return false;
    }
    // Remembered so delivery can pick the right signal: the queue carries bytes without
    // saying which framing produced them.
    m_subscriptions.insert(topic, delivery);
    return true;
}

inline bool QnntNode::addSubscriberPattern(const QString& pattern, Delivery delivery,
                                           int rescanMs) {
    const QByteArray glob = pattern.toUtf8();
    const qnnt_queue_mode mode =
        delivery == Delivery::Frames ? QNNT_QUEUE_FRAMES : QNNT_QUEUE_TEXT;
    if (!check(qnnt_subscribe_pattern_queue(glob.constData(),
                                            static_cast<std::size_t>(glob.size()), mode,
                                            static_cast<quint64>(rescanMs)),
               QStringLiteral("addSubscriberPattern(%1)").arg(pattern))) {
        return false;
    }
    m_patterns.append(qMakePair(pattern, delivery));
    return true;
}

inline bool QnntNode::removePublisher(const QString& topic) {
    const QByteArray name = topic.toUtf8();
    if (qnnt_remove_publisher(name.constData(),
                              static_cast<std::size_t>(name.size())) != QNNT_OK) {
        return false;
    }
    // After the call, never before: the library has joined the scheduler thread, so no tick
    // can be part-way through the std::function this drops.
    m_sources.remove(topic);
    return true;
}

inline bool QnntNode::removeSubscriber(const QString& topic) {
    const QByteArray name = topic.toUtf8();
    if (qnnt_remove_subscriber(name.constData(),
                               static_cast<std::size_t>(name.size())) != QNNT_OK) {
        return false;
    }
    m_subscriptions.remove(topic);
    return true;
}

inline bool QnntNode::addResponder(
    const QString& procedure,
    std::function<std::optional<QByteArray>(const QString&, const QByteArray&)> handler) {
    if (!handler) return false;

    // The C ABI keeps the raw pointer, so the std::function has to outlive this call.
    auto it = m_responders.insert(procedure, std::move(handler));

    struct Trampoline {
        static const std::uint8_t* call(const char* name, std::size_t name_len,
                                        const std::uint8_t* request, std::size_t request_len,
                                        std::size_t* reply_len, void* user) {
            auto* self = static_cast<QnntNode*>(user);
            const QString who = QString::fromUtf8(name, static_cast<qsizetype>(name_len));

            const auto slot = self->m_responders.constFind(who);
            if (slot == self->m_responders.constEnd()) return nullptr;

            const QByteArray body(reinterpret_cast<const char*>(request),
                                  static_cast<qsizetype>(request_len));
            const std::optional<QByteArray> reply = (*slot)(who, body);
            if (!reply) return nullptr; // std::nullopt refuses; an empty QByteArray does not

            // Held on the node, because these bytes are written to the socket after this
            // returns. Replaced on the next call to the same procedure.
            self->m_lastReply[who] = *reply;
            const QByteArray& kept = self->m_lastReply[who];
            *reply_len = static_cast<std::size_t>(kept.size());
            return reinterpret_cast<const std::uint8_t*>(kept.constData());
        }
    };

    const QByteArray name = procedure.toUtf8();
    const bool ok = check(qnnt_add_responder(name.constData(),
                                             static_cast<std::size_t>(name.size()),
                                             &Trampoline::call, this),
                          QStringLiteral("addResponder(%1)").arg(procedure));
    if (!ok) {
        m_responders.erase(it);
        return false;
    }
    return true;
}

inline bool QnntNode::removeResponder(const QString& procedure) {
    const QByteArray name = procedure.toUtf8();
    if (qnnt_remove_responder(name.constData(),
                              static_cast<std::size_t>(name.size())) != QNNT_OK) {
        return false;
    }
    // After the call, never before: the library has joined the responder, so no request can
    // be part-way through the std::function this drops.
    m_responders.remove(procedure);
    m_lastReply.remove(procedure);
    return true;
}

inline QByteArray QnntNode::request(const QString& procedure, const QByteArray& data,
                                    int timeoutMs, qnnt_rpc_status* status) {
    const QByteArray name = procedure.toUtf8();

    // Sized once and reused per call rather than guessed small: a reply that does not fit
    // is reported as too_large, and silently choosing a tiny cap here would turn ordinary
    // replies into errors the caller cannot explain.
    QByteArray out(1 << 20, Qt::Uninitialized);
    std::size_t written = 0;
    const qnnt_rpc_status rc = qnnt_request(name.constData(),
                                            static_cast<std::size_t>(name.size()),
                                            data.constData(),
                                            static_cast<std::size_t>(data.size()),
                                            static_cast<std::uint64_t>(timeoutMs),
                                            out.data(),
                                            static_cast<std::size_t>(out.size()),
                                            &written);
    if (status) *status = rc;
    if (rc != QNNT_RPC_OK) {
        Q_EMIT errorOccurred(QStringLiteral("request(%1)").arg(procedure),
                             static_cast<int>(rc),
                             QString::fromUtf8(qnnt_rpc_status_name(rc)));
        return {};
    }
    out.truncate(static_cast<qsizetype>(written));
    return out;
}

inline quint64 QnntNode::requestBegin(const QString& procedure, const QByteArray& data,
                                      int timeoutMs) {
    const QByteArray name = procedure.toUtf8();
    return qnnt_request_begin(name.constData(),
                              static_cast<std::size_t>(name.size()),
                              data.constData(),
                              static_cast<std::size_t>(data.size()),
                              static_cast<std::uint64_t>(timeoutMs));
}

/// Which framing a delivered topic was subscribed with. A literal subscription answers
/// directly; otherwise the patterns are asked, through the LIBRARY's matcher rather than a
/// second implementation here -- a header that disagreed with the library about what
/// "room/*" means would route frames to the text signal and hand the reader garbage.
inline QnntNode::Delivery QnntNode::deliveryFor(const QString& topic) const {
    const auto it = m_subscriptions.constFind(topic);
    if (it != m_subscriptions.constEnd()) return it.value();

    const QByteArray name = topic.toUtf8();
    for (const auto& entry : m_patterns) {
        const QByteArray glob = entry.first.toUtf8();
        if (qnnt_topic_matches(glob.constData(), static_cast<std::size_t>(glob.size()),
                               name.constData(), static_cast<std::size_t>(name.size()))) {
            return entry.second;
        }
    }
    return Delivery::Text;
}

inline void QnntNode::messageDelivered(const QString& topic, const QByteArray& data) {
    if (deliveryFor(topic) == Delivery::Frames) {
        Q_EMIT frameAvailable(topic, data);
    } else {
        Q_EMIT messageAvailable(topic, data);
    }
}

inline QString QnntNode::nodeId() const {
    char buf[33] = {0};
    if (qnnt_node_id(buf, sizeof buf) != QNNT_OK) return {};
    return QString::fromLatin1(buf);
}

inline quint16 QnntNode::registryPort() const { return qnnt_registry_port(); }

inline QString QnntNode::advertiseAddress() const {
    char buf[46] = {0};
    if (qnnt_advertise_address(buf, sizeof buf) != QNNT_OK) return {};
    return QString::fromLatin1(buf);
}

inline bool QnntNode::federationEnabled() const { return qnnt_federation_enabled() != 0; }

inline quint64 QnntNode::droppedCount() const { return qnnt_queue_dropped(); }

} // namespace qnnt

/*
 * ---------------------------------------------------------------- what is NOT here
 *
 * The old class had these, and the Zig library has nothing behind them yet. They are left
 * undeclared on purpose: a method that compiles and then fails is worse than one that is
 * absent and documented.
 *
 *   requestAvailable(QString procedure, QByteArray data) + reply() slot
 *       Request/reply itself now exists -- addResponder, removeResponder, request and
 *       requestBegin are above. What is absent is serving a request FROM the Qt thread:
 *       a handler passed to addResponder runs on the responder's own thread, as
 *       addScheduledPublisher's source does. The signal/slot form would have to hold the
 *       responder thread blocked while the Qt thread decided what to answer, with a
 *       correlation id to pair the reply with its request and a timeout for a slot that
 *       never replies. Worth doing when something needs it; until then a handler that
 *       needs GUI state should copy what it needs under a lock, or answer from a worker.
 *
 *   responderConnected
 *       No event is emitted when a requester connects. Requests are one connection each
 *       and typically shorter-lived than the signal would be useful for -- the four
 *       connection signals that do exist (subscriberConnected, subscriberDisconnected,
 *       publisherConnected, publisherDisconnected, plus publisherStale and
 *       publisherResumed) all concern long-lived streams.
 *
 * Also worth knowing when porting:
 *
 *   * The old constructor took a registry endpoint ("tcp://0.0.0.0:2222"). Here the
 *     registry is always loopback and only its port is configurable, deliberately: an
 *     unauthenticated directory reachable from a network lets anyone redirect a topic's
 *     subscribers. Cross-host discovery is federation, which is authenticated with a
 *     pre-shared key.
 *   * Endpoints are not passed per topic. A publisher binds an ephemeral port and
 *     registers it; subscribers resolve through the registry. setAdvertiseAddress() exists
 *     for the case where this host is reachable at an address it cannot discover itself,
 *     and even that is usually unnecessary -- a peer substitutes the address it reached
 *     you on.
 *   * msgpack becomes TOLD. MSGPACK_DEFINE_MAP becomes TOLD_DEFINE_MAP, MSGPACK::pack
 *     becomes told::pack, and the Qt adaptors at the top of this file cover QString,
 *     QByteArray, QList, QMap and QHash. See the porting table in EXAMPLES.txt.
 */

#endif // QNNT_QT_HPP
