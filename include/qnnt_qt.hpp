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
 * publishes on two topics, receives both a text stream and TLD frames as signals on the Qt
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
 * Build: needs Qt Core, the qnnt C ABI (include/qnnt.h) and the TLD C++ header
 * (include/qnnt_tld.hpp). Run moc over this file; with CMake, AUTOMOC handles it.
 */

#ifndef QNNT_QT_HPP
#define QNNT_QT_HPP

#include "qnnt.h"
#include "qnnt_tld.hpp"

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QMap>
#include <QObject>
#include <QString>
#include <QThread>

#include <atomic>
#include <cstring>
#include <functional>
#include <vector>

/* ---------------------------------------------------------------- Qt types in TLD
 *
 * So a Qt model class can carry QString and QList members and still be packed by the
 * macros from qnnt_tld.hpp:
 *
 *     struct Telemetry {
 *         QString name;
 *         QList<double> samples;
 *         QByteArray blob;
 *         TLD_DEFINE_MAP(name, samples, blob)
 *     };
 *
 * QString goes out as UTF-8 in a STRING frame, so a Zig or Python peer reads it as a
 * plain string; QByteArray goes out as a BUFFER, because a QByteArray is bytes and
 * claiming otherwise would put invalid UTF-8 in a field a peer may validate.
 */

template <>
struct qnnt::tld::Adaptor<QString> {
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
struct qnnt::tld::Adaptor<QByteArray> {
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
struct qnnt::tld::Adaptor<QList<T>> {
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
struct qnnt::tld::Adaptor<QMap<QString, V>> {
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
struct qnnt::tld::Adaptor<QHash<QString, V>> {
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
 * Note the trailing newline. A topic is either a newline-delimited text stream or a TLD
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
        Frames ///< TLD; `data` is one whole frame, ready for qnnt::tld::unpack
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

    /// Pack any TLD-mapped type and publish it as one frame -- the replacement for the old
    /// pub<T>() and its msgpack::pack. Subscribers read the topic as Delivery::Frames.
    template <class T>
    bool publishPacked(const QString& topic, const T& value) {
        const std::vector<std::uint8_t> bytes = qnnt::tld::pack(value);
        return publish(topic, reinterpret_cast<const char*>(bytes.data()),
                       static_cast<int>(bytes.size()));
    }

    /* --- subscribing ---------------------------------------------------------- */

    /// Subscribe through the poll queue. Messages arrive as messageAvailable() (Text) or
    /// frameAvailable() (Frames), on this object's thread.
    bool addSubscriber(const QString& topic, Delivery delivery = Delivery::Text);

    /// Decode a frame from frameAvailable() into a TLD-mapped type -- the replacement for
    /// the old getUnpacked<T>(). Throws qnnt::tld::Error on a malformed frame.
    template <class T>
    static T unpacked(const QByteArray& frame) {
        return qnnt::tld::unpack<T>(
            qnnt::tld::Bytes{reinterpret_cast<const std::uint8_t*>(frame.constData()),
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
    void started();
    void stopped();

    /// One newline-delimited message, delimiter included, on a Delivery::Text topic.
    void messageAvailable(const QString& topic, const QByteArray& data);

    /// One whole TLD frame on a Delivery::Frames topic. Pass it to unpacked<T>().
    void frameAvailable(const QString& topic, const QByteArray& frame);

    /// The queue overflowed and discarded messages; `total` is cumulative. Emitted when the
    /// count changes, so connecting to it is how a Qt program notices it is falling behind.
    void messagesDropped(quint64 total);

    /// A signal handler asked the process to stop, if installSignalHandlers() was called.
    void stopRequested();

    /// A library call failed. `context` names the call, `status` is the qnnt_status value
    /// and `statusName` its spelling from qnnt_status_name().
    void errorOccurred(const QString& context, int status, const QString& statusName);

private Q_SLOTS:
    /// Where the poller's queued signal lands, on this object's thread. Chooses which
    /// public signal to emit, since the queue carries bytes without recording the framing
    /// that produced them.
    void messageDelivered(const QString& topic, const QByteArray& data);

private:
    explicit QnntNode(QObject* parent = nullptr);

    bool check(qnnt_status status, const QString& context);

    QThread* m_thread = nullptr;
    QnntPoller* m_poller = nullptr;
    bool m_running = false;
    QMap<QString, Delivery> m_subscriptions;
    /// Kept alive for the lifetime of the publisher: the C ABI holds the raw pointer.
    QMap<QString, std::function<QByteArray()>> m_sources;

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

inline bool QnntNode::reserveQueue(int capacity) {
    return check(qnnt_queue_reserve(static_cast<std::size_t>(capacity)),
                 QStringLiteral("reserveQueue"));
}

inline void QnntNode::configureFromEnvironment() { qnnt_configure_from_environment(); }

inline bool QnntNode::start() {
    if (m_running) return true;
    if (!check(qnnt_init(), QStringLiteral("start"))) return false;
    m_running = true;

    m_thread = new QThread(this);
    m_poller = new QnntPoller;
    m_poller->moveToThread(m_thread);

    // The queued connection is the whole point: the poller emits on its own thread and the
    // slot -- and therefore every connected slot of ours -- runs on this object's thread.
    connect(m_thread, &QThread::started, m_poller, &QnntPoller::run);
    connect(m_poller, &QnntPoller::message, this, &QnntNode::messageDelivered,
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

inline void QnntNode::messageDelivered(const QString& topic, const QByteArray& data) {
    if (m_subscriptions.value(topic, Delivery::Text) == Delivery::Frames) {
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
 *   addResponder / removeResponder / request / req<Tin,Tout>
 *   requestAvailable(QString procedure, QByteArray data)
 *       Request/reply does not exist. qnnt is publish/subscribe only: there is no
 *       responder socket role, no registry verb for a procedure, and no request path.
 *       Adding it needs a new socket role that reads a request and writes a reply, a way
 *       to register and resolve procedure names (the topic directory can carry them, which
 *       would give federation and expiry for free), a length-prefixed request/reply framing
 *       since payloads are binary, and a timeout on the client side. Then a Qt layer over
 *       it: request() as an async call returning a QFuture, or a requestAvailable() signal
 *       plus a reply() slot for the serving side.
 *
 *   removePublisher / removeSubscriber
 *       There is no per-topic teardown. A publisher or subscriber lives until the whole
 *       node is torn down by stop(). The registry does understand an `unpub` verb, so half
 *       the wire support exists; what is missing is a way to stop the worker thread for one
 *       topic and unregister it.
 *
 *   publisherConnected / publisherDisconnected
 *   subscriberConnected / subscriberDisconnected / responderConnected
 *       No connection events exist. The registry does track subscribers per topic and its
 *       line protocol on loopback reports them (`list` shows a count, `subs <topic>` the
 *       detail), so a Qt implementation could poll that with a QTcpSocket and emit
 *       subscriberCountChanged(topic, count) honestly -- as a polled figure, not an event.
 *       Real edge-triggered signals would need the library to call back when a publisher
 *       accepts or loses a subscriber, which it currently does not.
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
 *   * msgpack becomes TLD. MSGPACK_DEFINE_MAP becomes TLD_DEFINE_MAP, MSGPACK::pack
 *     becomes qnnt::tld::pack, and the Qt adaptors at the top of this file cover QString,
 *     QByteArray, QList, QMap and QHash. See the porting table in EXAMPLES.txt.
 */

#endif // QNNT_QT_HPP
