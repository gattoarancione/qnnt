//! can-station: the Qt/QML view of a CAN gateway mesh, and a node on it.
//!
//!   docker/colima.sh && docker/can.sh   # a mesh to watch, or real gateways of your own
//!   ./zig-out/bin/can-station
//!
//!   can-station [path/to/main.qml] [gateway-name]
//!
//! The fifth station in this repository, and the first that does not know what it is
//! looking at when it starts. lidar-viewer is pointed at a topic, ugv-pilot at a robot,
//! dirigera-home at a bridge. This one subscribes to `can/*/*` and finds out: which buses
//! exist, which gateways are on them, and which identifiers those gateways carry are all
//! discovered from the topic names, because that is all a gateway publishes about itself.
//!
//! Three things about it are decisions rather than accidents.
//!
//! **The screen is repainted on a timer, not on a frame.** A CAN bus at 500 kbit/s carries
//! a few thousand frames a second and a mesh carries the sum of all of them. Touching a QML
//! model per frame would spend the whole machine on layout and still show a blur; the model
//! is rebuilt at 10 Hz from counters the frames update, so the arrival path stays a few
//! increments and the cost of drawing is bounded by the screen rather than by the bus.
//!
//! **A row per identifier, not a scrolling log.** A bus carries the same handful of
//! identifiers over and over -- engine speed at 100 Hz, a door switch when a door opens --
//! so a scroll shows the fastest one and hides the rest. The table has a line per
//! identifier with its rate and its latest payload, which is what a bus actually looks like.
//!
//! **Sending puts a frame on every gateway's bus.** The station publishes on
//! `can/<bus>/<name>` exactly as a gateway does, so every gateway subscribed to that bus
//! writes it to its local interface. It is a participant, not an observer -- which is why
//! the inject box refuses a malformed payload rather than padding it: see parseHex in
//! frames.hpp.

#include "qnnt_qt.hpp"
#include "frames.hpp"

#include <qnnt.h>

#include <QElapsedTimer>
#include <QGuiApplication>
#include <QObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

#include <algorithm>
#include <exception>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

namespace {

/// A gateway is called dead after this long without a frame. Long enough that a bus which
/// is merely quiet is not accused, short enough that a gateway which has gone is not still
/// drawn as present.
constexpr qint64 stale_after_ms = 5000;

/// Everything one logical bus carries, as this station has seen it.
struct Bus {
    /// Per gateway, so the station can say WHERE traffic is coming from -- which is the
    /// question a mesh raises and a single bus does not.
    std::map<std::string, can::Rate> gateways;
    /// Per identifier, merged across gateways: the bus is one broadcast medium, and which
    /// gateway relayed a frame is a property of the mesh, not of the frame.
    std::vector<can::IdRow> rows;
    can::Rate rate;
    /// Frames this station could not decode. Visible rather than swallowed: it is the
    /// symptom of the two sides of the wire format having drifted.
    quint64 undecodable{};
};

class Station : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList buses READ buses NOTIFY meshChanged)
    Q_PROPERTY(QVariantList rows READ rows NOTIFY meshChanged)
    Q_PROPERTY(QString selectedBus READ selectedBus WRITE selectBus NOTIFY meshChanged)
    Q_PROPERTY(QString name READ name CONSTANT)
    Q_PROPERTY(QString summary READ summary NOTIFY meshChanged)
    Q_PROPERTY(QString sendResult READ sendResult NOTIFY sendResultChanged)
    Q_PROPERTY(bool haveMesh READ haveMesh NOTIFY meshChanged)

public:
    explicit Station(QString name, QObject* parent = nullptr)
        : QObject(parent), m_name(std::move(name))
    {
        auto* node = qnnt::QnntNode::instance();
        node->configureFromEnvironment();
        if (!node->start()) {
            std::printf("can-station: could not start the qnnt node\n");
            return;
        }

        // The whole configuration. Not a topic, not a list of gateways, not an address: a
        // shape. Gateways that appear later are joined without anything being restarted,
        // and gateways on other hosts arrive through the federated directory.
        if (!node->addSubscriberPattern(QStringLiteral("can/*/*"),
                                        qnnt::QnntNode::Delivery::Frames, 500)) {
            std::printf("can-station: could not subscribe to can/*/*\n");
            return;
        }
        connect(node, &qnnt::QnntNode::frameAvailable, this, &Station::onFrame);

        m_clock.start();

        // Redraw on a timer rather than per frame. See the note at the top of this file:
        // this is the difference between a station that idles on a busy mesh and one that
        // spends a core on layout.
        auto* timer = new QTimer(this);
        connect(timer, &QTimer::timeout, this, [this] { Q_EMIT meshChanged(); });
        timer->start(100);

        m_started = true;
    }

    bool started() const { return m_started; }
    QString name() const { return m_name; }
    QString selectedBus() const { return m_selected; }
    bool haveMesh() const { return !m_buses.empty(); }

    /// One entry per bus: its name, how many gateways, its rate, and the gateways
    /// themselves so the view can show which host is quiet.
    QVariantList buses() const
    {
        const qint64 now = m_clock.elapsed();
        QVariantList out;
        for (auto& [name, bus] : m_buses) {
            QVariantList gws;
            for (auto& [gw, rate] : bus.gateways) {
                gws.append(QVariantMap{
                    {QStringLiteral("name"), QString::fromStdString(gw)},
                    {QStringLiteral("rate"), rate.perSecond(now)},
                    {QStringLiteral("total"), QVariant::fromValue(rate.total())},
                    {QStringLiteral("stale"), rate.stale(now, stale_after_ms)},
                    // Its own traffic, come back to it through the mesh. Worth marking:
                    // the pattern matches the station's own topic, as documented, and a
                    // reader who did not know that would think a gateway had duplicated.
                    {QStringLiteral("self"), QString::fromStdString(gw) == m_name},
                });
            }
            out.append(QVariantMap{
                {QStringLiteral("name"), QString::fromStdString(name)},
                {QStringLiteral("gateways"), gws},
                {QStringLiteral("ids"), int(bus.rows.size())},
                {QStringLiteral("rate"), bus.rate.perSecond(now)},
                {QStringLiteral("undecodable"), QVariant::fromValue(bus.undecodable)},
                {QStringLiteral("selected"), QString::fromStdString(name) == m_selected},
            });
        }
        return out;
    }

    /// The identifier table for the selected bus, busiest first -- the ordering a CAN tool
    /// uses, because the fast identifiers are the ones carrying periodic signals.
    QVariantList rows() const
    {
        const auto it = m_buses.find(m_selected.toStdString());
        if (it == m_buses.end()) return {};

        const qint64 now = m_clock.elapsed();
        auto sorted = it->second.rows;
        std::sort(sorted.begin(), sorted.end(), [&](can::IdRow& a, can::IdRow& b) {
            const auto ra = a.rate.perSecond(now), rb = b.rate.perSecond(now);
            if (ra != rb) return ra > rb;
            return a.id < b.id;
        });

        QVariantList out;
        for (auto& row : sorted) {
            out.append(QVariantMap{
                {QStringLiteral("id"), QString::fromStdString(can::formatId(row.id, row.ext))},
                {QStringLiteral("flags"), QString::fromStdString(rowFlags(row))},
                {QStringLiteral("dlc"), int(row.dlc)},
                {QStringLiteral("data"), QString::fromStdString(can::formatData(row.data))},
                {QStringLiteral("from"), QString::fromStdString(row.gateway)},
                {QStringLiteral("rate"), row.rate.perSecond(now)},
                {QStringLiteral("total"), QVariant::fromValue(row.rate.total())},
                {QStringLiteral("stale"), row.rate.stale(now, stale_after_ms)},
                {QStringLiteral("error"), row.err},
            });
        }
        return out;
    }

    QString summary() const
    {
        if (m_buses.empty()) {
            return QStringLiteral("no gateways yet -- looking for can/*/*");
        }
        int gateways = 0;
        double rate = 0;
        const qint64 now = m_clock.elapsed();
        for (auto& [name, bus] : m_buses) {
            gateways += int(bus.gateways.size());
            rate += bus.rate.perSecond(now);
        }
        return QStringLiteral("%1 bus(es), %2 gateway view(s), %3 frames/s")
            .arg(m_buses.size())
            .arg(gateways)
            .arg(rate, 0, 'f', 0);
    }

    QString sendResult() const { return m_send_result; }

public Q_SLOTS:
    void selectBus(const QString& bus)
    {
        if (m_selected == bus) return;
        m_selected = bus;
        Q_EMIT meshChanged();
    }

    /// Publish a frame as if this station were a gateway on `bus`. Every gateway subscribed
    /// to that bus writes it to its local interface, so this reaches real hardware.
    void send(const QString& bus, const QString& id_text, bool ext, bool rtr,
              const QString& data_hex)
    {
        bool ok = false;
        // Base 0, so 0x123 and 291 both work and neither is guessed at.
        const auto id = id_text.trimmed().toUInt(&ok, 0);
        if (!ok) return fail(QStringLiteral("identifier '%1' is not a number").arg(id_text));

        const auto limit = ext ? 0x1FFFFFFFu : 0x7FFu;
        if (id > limit) {
            return fail(QStringLiteral("0x%1 does not fit in %2 bits -- tick extended")
                            .arg(id, 0, 16).arg(ext ? 29 : 11));
        }

        std::vector<std::uint8_t> data;
        if (!can::parseHex(data_hex.toStdString(), data)) {
            return fail(QStringLiteral("payload is not 0-8 bytes of hex"));
        }

        can::Frame f;
        f.id = id;
        f.ext = ext;
        f.rtr = rtr;
        f.err = false;  // never injectable: an error frame describes a bus, and this is not one
        f.dlc = std::uint8_t(rtr ? data.size() : data.size());
        f.data = rtr ? std::vector<std::uint8_t>{} : data;
        // The C entry point: the Qt wrapper does not surface a clock, and this stamp has
        // to be the same one a gateway would use.
        f.us = qnnt_now_micros();

        const QString topic = QStringLiteral("can/%1/%2").arg(bus, m_name);
        // Registered lazily: the station cannot know the bus names before it has seen one,
        // and publishing to an unregistered topic reaches nobody.
        auto* node = qnnt::QnntNode::instance();
        if (!m_publishing.contains(topic)) {
            if (!node->addPublisher(topic)) return fail(QStringLiteral("cannot publish %1").arg(topic));
            m_publishing.insert(topic);
        }
        // Encoding throws rather than returning a status, and a window that dies because a
        // frame would not encode is a worse outcome than any frame. The box below says what
        // happened; the station stays up.
        try {
            if (!node->publishPacked(topic, f)) return fail(QStringLiteral("publish failed"));
        } catch (const std::exception& e) {
            return fail(QStringLiteral("could not encode: %1").arg(QString::fromUtf8(e.what())));
        }

        m_send_result = QStringLiteral("sent %1 [%2] on %3")
                            .arg(QString::fromStdString(can::formatId(id, ext)))
                            .arg(f.data.size())
                            .arg(bus);
        Q_EMIT sendResultChanged();
    }

Q_SIGNALS:
    void meshChanged();
    void sendResultChanged();

private Q_SLOTS:
    void onFrame(const QString& topic, const QByteArray& payload)
    {
        const auto origin = can::parseTopic(topic.toStdString());
        // The pattern can match a topic that is not a gateway's -- `can/anything` from some
        // other program. Counted nowhere and drawn nowhere, rather than drawn as a bus.
        if (!origin.valid()) return;

        auto& bus = m_buses[origin.bus];
        const qint64 now = m_clock.elapsed();

        can::Frame f;
        try {
            f = qnnt::QnntNode::unpacked<can::Frame>(payload);
        } catch (...) {
            // A frame that will not decode is the symptom of the wire format having drifted
            // between the gateway and this station. Shown per bus rather than logged once,
            // because "some frames do not decode" and "this bus does not decode" are
            // different faults.
            ++bus.undecodable;
            return;
        }

        bus.rate.tick(now);
        bus.gateways[origin.gateway].tick(now);

        auto& row = bus.rows[can::rowFor(bus.rows, f)];
        row.rtr = f.rtr;
        row.err = f.err;
        row.dlc = f.dlc;
        row.data = f.data;
        row.gateway = origin.gateway;
        row.rate.tick(now);

        if (m_selected.isEmpty()) m_selected = QString::fromStdString(origin.bus);
    }

private:
    static std::string rowFlags(const can::IdRow& row)
    {
        std::string out;
        if (row.ext) out += 'E';
        if (row.rtr) out += 'R';
        if (row.err) out += '!';
        return out;
    }

    void fail(const QString& why)
    {
        m_send_result = why;
        Q_EMIT sendResultChanged();
    }

    bool m_started{false};
    QString m_name;
    QString m_selected;
    QString m_send_result;
    QSet<QString> m_publishing;
    QElapsedTimer m_clock;
    std::map<std::string, Bus> m_buses;
};

}  // namespace

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);

    const QString qml = (argc > 1 && argv[1][0] != '\0')
                            ? QString::fromLocal8Bit(argv[1])
                            : QStringLiteral("examples/can/main.qml");
    // The station's own gateway name, which is what its injected frames are published
    // under. Distinct per instance, or two stations would publish the same topic.
    const QString name = (argc > 2 && argv[2][0] != '\0')
                             ? QString::fromLocal8Bit(argv[2])
                             : QStringLiteral("station");

    Station station(name);
    if (!station.started()) return 1;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("station"), &station);
    engine.load(QUrl::fromLocalFile(qml));
    if (engine.rootObjects().isEmpty()) {
        std::printf("can-station: could not load %s (run from the repository root, or pass "
                    "a path to main.qml)\n",
                    qPrintable(qml));
        return 1;
    }

    const int rc = app.exec();
    qnnt::QnntNode::instance()->stop();
    return rc;
}

#include "station.moc"
