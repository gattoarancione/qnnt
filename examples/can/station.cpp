//! can-station: the Qt/QML view of a CAN gateway mesh, and a node on it.
//!
//!   bash examples/can/demo.sh            # a mesh to look at, no CAN interface needed
//!   docker/colima.sh && docker/can.sh    # or real gateways on real vcan interfaces
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
//! **The screen is refreshed on a timer, not on a frame.** A CAN bus at 500 kbit/s carries
//! a few thousand frames a second and a mesh carries the sum of all of them. Touching a QML
//! model per frame would spend the whole machine on layout and still show a blur; frames
//! only bump counters, and the view is refreshed at 10 Hz.
//!
//! REFRESHED, not rebuilt, and the difference is not academic. The first version handed QML
//! a freshly built QVariantList every tick. That resets a ListView and destroys every
//! delegate with it -- measured at twelve rebuilds a second per row -- so a click's press
//! and its release almost never landed on the same MouseArea, and the bus list could not be
//! clicked at all. The lists below hold STABLE QObjects: a tick updates their properties in
//! place, only changed bindings re-evaluate, and a list changes identity only when a bus or
//! an identifier actually appears.
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

/// One gateway's traffic on one bus. A stable object: created when that gateway is first
/// heard from, then updated in place for the life of the station.
class GatewayItem : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString name MEMBER m_name CONSTANT)
    Q_PROPERTY(bool self MEMBER m_self CONSTANT)
    Q_PROPERTY(double rate MEMBER m_rate NOTIFY changed)
    Q_PROPERTY(quint64 total MEMBER m_total NOTIFY changed)
    Q_PROPERTY(bool stale MEMBER m_stale NOTIFY changed)

public:
    GatewayItem(QString name, bool self, QObject* parent)
        : QObject(parent), m_name(std::move(name)), m_self(self) {}

    [[nodiscard]] QString name() const { return m_name; }
    void tick(qint64 now) { m_counter.tick(now); }

    /// Recompute what the view reads, and say so only if it moved. Emitting unconditionally
    /// would re-evaluate every binding on every tick for nothing.
    void refresh(qint64 now)
    {
        const double rate = m_counter.perSecond(now);
        const quint64 total = m_counter.total();
        const bool stale = m_counter.stale(now, stale_after_ms);
        if (rate == m_rate && total == m_total && stale == m_stale) return;
        m_rate = rate;
        m_total = total;
        m_stale = stale;
        Q_EMIT changed();
    }

Q_SIGNALS:
    void changed();

private:
    QString m_name;
    bool m_self{};
    double m_rate{};
    quint64 m_total{};
    bool m_stale{};
    can::Rate m_counter;
};

/// One CAN identifier on one bus.
///
/// A bus carries the same few identifiers over and over -- engine speed at 100 Hz, a door
/// switch when somebody opens a door -- so a scrolling log shows only the fastest of them
/// and a per-identifier table shows the bus.
class RowItem : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString id MEMBER m_id CONSTANT)
    Q_PROPERTY(QString flags MEMBER m_flags NOTIFY changed)
    Q_PROPERTY(int dlc MEMBER m_dlc NOTIFY changed)
    Q_PROPERTY(QString data MEMBER m_data NOTIFY changed)
    Q_PROPERTY(QString from MEMBER m_from NOTIFY changed)
    Q_PROPERTY(double rate MEMBER m_rate NOTIFY changed)
    Q_PROPERTY(quint64 total MEMBER m_total NOTIFY changed)
    Q_PROPERTY(bool stale MEMBER m_stale NOTIFY changed)
    Q_PROPERTY(bool error MEMBER m_error NOTIFY changed)

public:
    RowItem(const can::Frame& f, QObject* parent) : QObject(parent)
    {
        m_row.id = f.id;
        m_row.ext = f.ext;
        m_row.fd = f.fd;
        // The identifier IS the row's identity and never changes, so it is rendered once
        // and declared CONSTANT.
        m_id = QString::fromStdString(can::formatId(f.id, f.ext));
    }

    [[nodiscard]] const can::IdRow& key() const { return m_row; }

    void tick(const can::Frame& f, const QString& from, qint64 now)
    {
        m_row.rtr = f.rtr;
        m_row.err = f.err;
        m_row.brs = f.brs;
        m_row.esi = f.esi;
        m_row.dlc = f.dlc;
        m_row.data = f.data;
        m_seen_from = from;
        m_row.rate.tick(now);
    }

    void refresh(qint64 now)
    {
        can::Frame shape;
        shape.ext = m_row.ext;
        shape.rtr = m_row.rtr;
        shape.err = m_row.err;
        shape.fd = m_row.fd;
        shape.brs = m_row.brs;
        shape.esi = m_row.esi;

        const auto flags = QString::fromStdString(can::formatFlags(shape));
        const auto data = QString::fromStdString(can::formatData(m_row.data));
        const double rate = m_row.rate.perSecond(now);
        const quint64 total = m_row.rate.total();
        const bool stale = m_row.rate.stale(now, stale_after_ms);

        if (flags == m_flags && data == m_data && m_seen_from == m_from && rate == m_rate &&
            total == m_total && stale == m_stale && int(m_row.dlc) == m_dlc &&
            m_row.err == m_error) {
            return;
        }
        m_flags = flags;
        m_data = data;
        m_from = m_seen_from;
        m_rate = rate;
        m_total = total;
        m_stale = stale;
        m_dlc = int(m_row.dlc);
        m_error = m_row.err;
        Q_EMIT changed();
    }

Q_SIGNALS:
    void changed();

private:
    can::IdRow m_row;
    QString m_id, m_flags, m_data, m_from, m_seen_from;
    int m_dlc{};
    double m_rate{};
    quint64 m_total{};
    bool m_stale{}, m_error{};
};

/// Everything one logical bus carries, as this station has seen it.
class BusItem : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString name MEMBER m_name CONSTANT)
    Q_PROPERTY(double rate MEMBER m_rate NOTIFY changed)
    Q_PROPERTY(int ids MEMBER m_ids NOTIFY changed)
    Q_PROPERTY(quint64 undecodable MEMBER m_undecodable NOTIFY changed)
    Q_PROPERTY(bool selected MEMBER m_selected NOTIFY changed)
    /// Per gateway, so the station can say WHERE traffic is coming from -- the question a
    /// mesh raises and a single bus does not.
    Q_PROPERTY(QList<QObject*> gateways MEMBER m_gateways NOTIFY gatewaysChanged)

public:
    BusItem(QString name, QObject* parent) : QObject(parent), m_name(std::move(name)) {}

    [[nodiscard]] QString name() const { return m_name; }
    [[nodiscard]] const QList<QObject*>& rows() const { return m_rows; }

    void setSelected(bool on)
    {
        if (on == m_selected) return;
        m_selected = on;
        Q_EMIT changed();
    }

    /// A frame from `gateway`. True when this added a row, which is the only thing that
    /// makes the table's list change identity.
    bool tick(const can::Frame& f, const QString& gateway, bool self, qint64 now)
    {
        m_counter.tick(now);
        gatewayFor(gateway, self)->tick(now);

        for (auto* object : m_rows) {
            auto* row = static_cast<RowItem*>(object);
            if (can::sameRow(row->key(), f)) {
                row->tick(f, gateway, now);
                return false;
            }
        }

        auto* row = new RowItem(f, this);
        row->tick(f, gateway, now);
        // Inserted in identifier order rather than appended and re-sorted on each repaint:
        // a table that re-sorts while you read it moves rows out from under the pointer.
        auto at = m_rows.begin();
        while (at != m_rows.end() &&
               can::rowPrecedes(static_cast<RowItem*>(*at)->key(), row->key())) {
            ++at;
        }
        m_rows.insert(at, row);
        return true;
    }

    void countUndecodable()
    {
        ++m_undecodable;
        Q_EMIT changed();
    }

    void refresh(qint64 now)
    {
        for (auto* g : m_gateways) static_cast<GatewayItem*>(g)->refresh(now);
        for (auto* r : m_rows) static_cast<RowItem*>(r)->refresh(now);

        const double rate = m_counter.perSecond(now);
        const int ids = int(m_rows.size());
        if (rate == m_rate && ids == m_ids) return;
        m_rate = rate;
        m_ids = ids;
        Q_EMIT changed();
    }

    [[nodiscard]] double rate(qint64 now) { return m_counter.perSecond(now); }
    [[nodiscard]] int gatewayCount() const { return int(m_gateways.size()); }

Q_SIGNALS:
    void changed();
    void gatewaysChanged();

private:
    GatewayItem* gatewayFor(const QString& name, bool self)
    {
        for (auto* object : m_gateways) {
            auto* g = static_cast<GatewayItem*>(object);
            if (g->name() == name) return g;
        }
        auto* g = new GatewayItem(name, self, this);
        m_gateways.append(g);
        Q_EMIT gatewaysChanged();
        return g;
    }

    QString m_name;
    double m_rate{};
    int m_ids{};
    quint64 m_undecodable{};
    bool m_selected{};
    can::Rate m_counter;
    QList<QObject*> m_gateways;
    QList<QObject*> m_rows;
};

/// Everything the send box holds. One struct so the button and the periodic sender are
/// given the same thing and cannot diverge.
struct Spec {
    QString bus;
    QString id_text;
    bool ext{};
    bool rtr{};
    bool fd{};
    bool brs{};
    QString data_hex;
};

class Station : public QObject {
    Q_OBJECT
    // These two change identity only when a bus or an identifier appears. Binding them to
    // the refresh tick is what made the list unclickable: it reset the ListView and took
    // every delegate with it, ten times a second.
    Q_PROPERTY(QList<QObject*> buses MEMBER m_buses NOTIFY busesChanged)
    Q_PROPERTY(QList<QObject*> rows READ rows NOTIFY rowsChanged)
    Q_PROPERTY(QString selectedBus READ selectedBus WRITE selectBus NOTIFY selectedChanged)
    Q_PROPERTY(QString name READ name CONSTANT)
    Q_PROPERTY(QString summary READ summary NOTIFY summaryChanged)
    Q_PROPERTY(QString sendResult READ sendResult NOTIFY sendResultChanged)
    /// So the view can untick its own box when a period or a frame is refused, rather than
    /// showing a repeat that is not running.
    Q_PROPERTY(bool repeating READ repeating NOTIFY repeatingChanged)
    Q_PROPERTY(bool haveMesh READ haveMesh NOTIFY busesChanged)

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
        connect(timer, &QTimer::timeout, this, &Station::refresh);
        timer->start(100);

        // Its own timer, not a counter inside the refresh tick: the repeat period is the
        // operator's number and must not be quantised to the redraw interval.
        m_repeat_timer = new QTimer(this);
        // Precise, because the shortest period offered is 1 ms. Qt's default coarse timer
        // is free to shift an interval by up to 5% to batch wakeups, which at these periods
        // is the difference between the rate asked for and the rate delivered.
        m_repeat_timer->setTimerType(Qt::PreciseTimer);
        connect(m_repeat_timer, &QTimer::timeout, this, &Station::onRepeatTick);

        m_started = true;
    }

    bool started() const { return m_started; }
    QString name() const { return m_name; }
    QString selectedBus() const { return m_selected; }
    bool haveMesh() const { return !m_buses.isEmpty(); }
    QString summary() const { return m_summary; }

    /// The identifier table for the selected bus. The list belongs to the bus, so
    /// switching bus is the only thing that changes it; the other bus keeps its own rows
    /// and its own scroll position.
    QList<QObject*> rows() const
    {
        auto* bus = busNamed(m_selected);
        return bus ? bus->rows() : QList<QObject*>{};
    }

    QString sendResult() const { return m_send_result; }
    bool repeating() const { return m_repeating; }

public Q_SLOTS:
    void selectBus(const QString& bus)
    {
        if (m_selected == bus) return;
        m_selected = bus;
        for (auto* object : m_buses) {
            auto* item = static_cast<BusItem*>(object);
            item->setSelected(item->name() == bus);
        }
        // The table's list, and only it. The bus list itself has not changed, so saying it
        // had would destroy the delegate the click arrived on.
        Q_EMIT selectedChanged();
        Q_EMIT rowsChanged();
    }

    /// Publish a frame as if this station were a gateway on `bus`. Every gateway subscribed
    /// to that bus writes it to its local interface, so this reaches real hardware.
    /// What the operator composed, as a frame to publish. Returns false and says why in
    /// `m_send_result` when the combination is one no controller could transmit.
    ///
    /// Separate from the publishing because the button and the periodic sender must agree
    /// exactly: a repeat that skipped a check the button applies would put frames on the
    /// bus that pressing the button refuses to.
    bool compose(const Spec& spec, can::Frame& out)
    {
        bool ok = false;
        // Base 0, so 0x123 and 291 both work and neither is guessed at.
        const auto id = spec.id_text.trimmed().toUInt(&ok, 0);
        if (!ok) {
            fail(QStringLiteral("identifier '%1' is not a number").arg(spec.id_text));
            return false;
        }

        const auto limit = spec.ext ? 0x1FFFFFFFu : 0x7FFu;
        if (id > limit) {
            fail(QStringLiteral("0x%1 does not fit in %2 bits -- tick extended")
                     .arg(id, 0, 16).arg(spec.ext ? 29 : 11));
            return false;
        }

        std::vector<std::uint8_t> data;
        if (!can::parseHex(spec.data_hex.toStdString(), data)) {
            fail(QStringLiteral("payload is not hex, or is over 64 bytes"));
            return false;
        }
        const auto len = std::uint8_t(data.size());
        if (spec.fd && !can::validFdLength(len)) {
            // Padding to the next legal size would put bytes on a real bus that nobody
            // wrote, so the length is refused and the legal ones are named.
            fail(QStringLiteral("CAN FD has no %1-byte frame; use 0-8, 12, 16, 20, 24, 32, "
                                "48 or 64").arg(len));
            return false;
        }
        if (!spec.fd && len > 8) {
            fail(QStringLiteral("classic CAN carries at most 8 bytes -- tick FD"));
            return false;
        }

        out = can::Frame{};
        out.id = id;
        out.ext = spec.ext;
        out.err = false;  // never injectable: an error frame describes a bus, not a sender
        out.fd = spec.fd;
        // CAN FD has no remote frames, so the two cannot both be set; the view disables one
        // when the other is ticked, and this is the guard behind it.
        out.rtr = spec.rtr && !spec.fd;
        out.brs = spec.fd && spec.brs;
        out.esi = false;  // the transmitter's own state, not something a sender asserts
        out.dlc = len;
        out.data = out.rtr ? std::vector<std::uint8_t>{} : data;
        return true;
    }

    /// Publish one composed frame on `bus`, as if this station were a gateway there.
    bool publish(const QString& bus, can::Frame f)
    {
        // The C entry point: the Qt wrapper does not surface a clock, and this stamp has to
        // be the same one a gateway would use. Restamped per send, so a repeated frame
        // carries the time it actually went out rather than the time it was composed.
        f.us = qnnt_now_micros();

        const QString topic = QStringLiteral("can/%1/%2").arg(bus, m_name);
        // Registered lazily: the station cannot know the bus names before it has seen one,
        // and publishing to an unregistered topic reaches nobody.
        auto* node = qnnt::QnntNode::instance();
        if (!m_publishing.contains(topic)) {
            if (!node->addPublisher(topic)) {
                fail(QStringLiteral("cannot publish %1").arg(topic));
                return false;
            }
            m_publishing.insert(topic);
        }
        // Encoding throws rather than returning a status, and a window that dies because a
        // frame would not encode is a worse outcome than any frame. The box says what
        // happened; the station stays up.
        try {
            if (!node->publishPacked(topic, f)) {
                fail(QStringLiteral("publish failed"));
                return false;
            }
        } catch (const std::exception& e) {
            fail(QStringLiteral("could not encode: %1").arg(QString::fromUtf8(e.what())));
            return false;
        }
        return true;
    }

public Q_SLOTS:
    /// Publish one frame as if this station were a gateway on `bus`. Every gateway
    /// subscribed to that bus writes it to its local interface, so this reaches real
    /// hardware.
    void send(const QString& bus, const QString& id_text, bool ext, bool rtr, bool fd,
              bool brs, const QString& data_hex)
    {
        const Spec spec{bus, id_text, ext, rtr, fd, brs, data_hex};
        can::Frame f;
        if (!compose(spec, f) || !publish(bus, f)) return;

        m_send_result = QStringLiteral("sent %1 [%2] on %3")
                            .arg(QString::fromStdString(can::formatId(f.id, f.ext)))
                            .arg(f.data.size())
                            .arg(bus);
        Q_EMIT sendResultChanged();
    }

    /// Start or stop sending the composed frame at a fixed period.
    ///
    /// This is what a bus actually carries: almost every message on a vehicle bus is
    /// periodic, and a single frame proves a path works while a paced one is what a
    /// receiver under test is written against.
    ///
    /// Everything is validated ONCE, here, rather than on every tick -- a timer that
    /// re-validated would either spend its budget in the parser or, worse, quietly stop
    /// producing frames when a field was edited into a bad state. Editing a field while it
    /// runs re-enters here and restarts on the new value.
    void setRepeat(bool on, const QString& bus, const QString& id_text, bool ext, bool rtr,
                   bool fd, bool brs, const QString& data_hex, const QString& period_text)
    {
        m_repeat_timer->stop();
        if (!on) {
            if (m_repeating) {
                m_repeating = false;
                m_send_result = QStringLiteral("repeat stopped after %1 frame(s)")
                                    .arg(m_repeat_sent);
                Q_EMIT sendResultChanged();
                Q_EMIT repeatingChanged();
            }
            return;
        }

        const int period = can::parsePeriodMs(period_text.toStdString());
        if (period == 0) {
            m_repeating = false;
            Q_EMIT repeatingChanged();
            return fail(QStringLiteral("period must be %1-%2 ms, plain digits")
                            .arg(can::min_period_ms).arg(can::max_period_ms));
        }

        m_repeat_spec = Spec{bus, id_text, ext, rtr, fd, brs, data_hex};
        if (!compose(m_repeat_spec, m_repeat_frame)) {
            // compose() has already said why. Not repeating, and the view unticks itself.
            m_repeating = false;
            Q_EMIT repeatingChanged();
            return;
        }

        m_repeat_sent = 0;
        m_repeating = true;
        Q_EMIT repeatingChanged();
        // Fire one immediately, so pressing the box does something visible rather than
        // nothing for up to a period.
        onRepeatTick();
        m_repeat_timer->start(period);
    }

Q_SIGNALS:
    void busesChanged();
    void rowsChanged();
    void selectedChanged();
    void summaryChanged();
    void sendResultChanged();
    void repeatingChanged();

private Q_SLOTS:
    /// One frame of a repeat. The frame was composed and checked when the repeat started,
    /// so this is only the publish -- and if the publish fails the repeat stops rather than
    /// retrying into a fault every period for as long as the window is open.
    void onRepeatTick()
    {
        if (!publish(m_repeat_spec.bus, m_repeat_frame)) {
            m_repeat_timer->stop();
            m_repeating = false;
            Q_EMIT repeatingChanged();
            return;
        }
        ++m_repeat_sent;
        m_send_result = QStringLiteral("repeating %1 [%2] on %3 -- %4 sent")
                            .arg(QString::fromStdString(
                                     can::formatId(m_repeat_frame.id, m_repeat_frame.ext)))
                            .arg(m_repeat_frame.data.size())
                            .arg(m_repeat_spec.bus)
                            .arg(m_repeat_sent);
        Q_EMIT sendResultChanged();
    }

    /// Once every 100 ms: update what the view reads, IN PLACE. Each item emits only if one
    /// of its own values moved, so a quiet bus costs nothing and no delegate is destroyed.
    void refresh()
    {
        const qint64 now = m_clock.elapsed();
        double rate = 0;
        int gateways = 0;
        for (auto* object : m_buses) {
            auto* bus = static_cast<BusItem*>(object);
            bus->refresh(now);
            rate += bus->rate(now);
            gateways += bus->gatewayCount();
        }

        const QString summary = m_buses.isEmpty()
            ? QStringLiteral("no gateways yet -- looking for can/*/*")
            : QStringLiteral("%1 bus(es), %2 gateway view(s), %3 frames/s")
                  .arg(m_buses.size()).arg(gateways).arg(rate, 0, 'f', 0);
        if (summary != m_summary) {
            m_summary = summary;
            Q_EMIT summaryChanged();
        }
    }

    void onFrame(const QString& topic, const QByteArray& payload)
    {
        const auto origin = can::parseTopic(topic.toStdString());
        // The pattern can match a topic that is not a gateway's -- `can/anything` from some
        // other program. Counted nowhere and drawn nowhere, rather than drawn as a bus.
        if (!origin.valid()) return;

        const auto bus_name = QString::fromStdString(origin.bus);
        const auto gateway = QString::fromStdString(origin.gateway);

        auto* bus = busNamed(bus_name);
        if (!bus) {
            bus = new BusItem(bus_name, this);
            // In name order, so the column does not reshuffle as hosts appear.
            auto at = m_buses.begin();
            while (at != m_buses.end() && static_cast<BusItem*>(*at)->name() < bus_name) ++at;
            m_buses.insert(at, bus);
            Q_EMIT busesChanged();
            if (m_selected.isEmpty()) selectBus(bus_name);
        }

        can::Frame f;
        try {
            f = qnnt::QnntNode::unpacked<can::Frame>(payload);
        } catch (...) {
            // A frame that will not decode is the symptom of the wire format having drifted
            // between the gateway and this station. Counted per bus rather than logged
            // once, because "some frames do not decode" and "this bus does not decode" are
            // different faults.
            bus->countUndecodable();
            return;
        }

        // True only when the identifier is new, which is the one thing that makes the
        // table's list change -- and then only for the bus being shown.
        if (bus->tick(f, gateway, gateway == m_name, m_clock.elapsed()) &&
            bus->name() == m_selected) {
            Q_EMIT rowsChanged();
        }
    }

private:

    void fail(const QString& why)
    {
        m_send_result = why;
        Q_EMIT sendResultChanged();
    }

    [[nodiscard]] BusItem* busNamed(const QString& name) const
    {
        for (auto* object : m_buses) {
            auto* bus = static_cast<BusItem*>(object);
            if (bus->name() == name) return bus;
        }
        return nullptr;
    }

    bool m_started{false};
    QString m_name;
    QString m_selected;
    QString m_send_result;
    QString m_summary{QStringLiteral("no gateways yet -- looking for can/*/*")};
    QSet<QString> m_publishing;
    QElapsedTimer m_clock;
    QList<QObject*> m_buses;

    QTimer* m_repeat_timer{nullptr};
    Spec m_repeat_spec;
    can::Frame m_repeat_frame;
    quint64 m_repeat_sent{0};
    bool m_repeating{false};
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
