//! dirigera-home: the Qt/QML control station for an IKEA DIRIGERA hub.
//!
//!   ./zig-out/bin/dirigera-bridge --host 192.168.1.20:8443   # terminal 1
//!   ./zig-out/bin/dirigera-home                              # terminal 2
//!
//!   dirigera-home [path/to/main.qml] [topic-prefix]
//!
//! The fourth station in this repository, after lidar-viewer, camera-viewer and ugv-pilot,
//! and the one with the least in common with the others: nothing here is a render loop.
//! A LiDAR viewer redraws a million points a second; a home has seventeen devices that
//! change when somebody walks past a sensor. So this is a model that follows a push stream,
//! and the interesting parts are what the bridge's topics let it avoid guessing:
//!
//! **Which control to show comes from the hub.** A light gets a switch only if the hub
//! accepts `isOn` for it, a brightness slider only for `lightLevel`, a colour slider only
//! for `colorTemperature`, and the slider's range is the bulb's own. None of that is
//! inferred from the device type, because the type does not determine it -- a dimmable
//! white bulb and a tunable one are both `light`. The remotes and motion sensors get no
//! controls at all, because the hub accepts nothing but a rename for them.
//!
//! **A command is not a confirmation.** The hub answers `202 Accepted` and applies the
//! change asynchronously -- or not at all, if the device is unreachable. So a switch does
//! not move when clicked; it moves when the state topic says the light changed. The click
//! marks it pending, and a pending change that never arrives stays visible instead of being
//! quietly forgotten.
//!
//! **Unreachable is not off.** The hub reports last-known state for a device it cannot
//! currently talk to, which for one bulb here meant a `lightLevel` of 100 from eight hours
//! earlier. Those devices are drawn dimmed and labelled, because showing stale state as
//! current is the whole failure mode of a home dashboard.

#include "qnnt_qt.hpp"
#include "devices.hpp"
#include "frames.hpp"

#include <QColor>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QTimer>
#include <QUrl>
#include <QtQml/qqml.h>

#include <algorithm>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>

namespace {

// The topic payload types, defined in frames.hpp and held in step with the Zig side by a
// golden frame -- see the header there.
using dirigera::DeviceFrame;
using dirigera::InventoryFrame;
using dirigera::LightCommand;
using dirigera::StateFrame;
using dirigera::StatusFrame;

/// How long a click stays marked pending before the interface admits nothing came back.
/// Generous, because the hub applies changes asynchronously and a Zigbee round trip through
/// a mains-powered relay is not instant.
constexpr qint64 kPendingMs = 4000;

} // namespace

/// One device, as QML sees it. A plain QObject rather than a QAbstractListModel: seventeen
/// devices do not need incremental updates, and a list of QObjects keeps the QML bindings
/// straightforward.
class Device : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString deviceId MEMBER m_id CONSTANT)
    Q_PROPERTY(QString kind MEMBER m_kind CONSTANT)
    Q_PROPERTY(QString name MEMBER m_name NOTIFY changed)
    Q_PROPERTY(QString room MEMBER m_room NOTIFY changed)
    Q_PROPERTY(QString model MEMBER m_model NOTIFY changed)
    Q_PROPERTY(bool reachable MEMBER m_reachable NOTIFY changed)

    Q_PROPERTY(bool isOn MEMBER m_is_on NOTIFY changed)
    Q_PROPERTY(bool hasOn MEMBER m_has_on NOTIFY changed)
    Q_PROPERTY(int level MEMBER m_level NOTIFY changed)
    Q_PROPERTY(bool hasLevel MEMBER m_has_level NOTIFY changed)
    Q_PROPERTY(int kelvin MEMBER m_kelvin NOTIFY changed)
    Q_PROPERTY(bool hasKelvin MEMBER m_has_kelvin NOTIFY changed)
    Q_PROPERTY(int kelvinMin MEMBER m_kelvin_min NOTIFY changed)
    Q_PROPERTY(int kelvinMax MEMBER m_kelvin_max NOTIFY changed)

    Q_PROPERTY(int battery MEMBER m_battery NOTIFY changed)
    Q_PROPERTY(bool hasBattery MEMBER m_has_battery NOTIFY changed)
    Q_PROPERTY(bool motion MEMBER m_motion NOTIFY changed)
    Q_PROPERTY(bool hasMotion MEMBER m_has_motion NOTIFY changed)
    Q_PROPERTY(int illuminance MEMBER m_illuminance NOTIFY changed)
    Q_PROPERTY(bool hasIlluminance MEMBER m_has_illuminance NOTIFY changed)

    // -- what the hub will accept, which decides which controls appear ----------
    Q_PROPERTY(bool canSetOn MEMBER m_can_set_on NOTIFY changed)
    Q_PROPERTY(bool canSetLevel MEMBER m_can_set_level NOTIFY changed)
    Q_PROPERTY(bool canSetKelvin MEMBER m_can_set_kelvin NOTIFY changed)

    /// Which physical unit this belongs to. Two devices sharing it are one sensor on the
    /// wall -- see `relation` on the bridge's DeviceFrame.
    Q_PROPERTY(QString relation MEMBER m_relation NOTIFY changed)
    /// What this device is FOR, which is not the same as what it is. See Home::Role.
    Q_PROPERTY(int role READ roleValue NOTIFY changed)

    /// Motion is an event, not a state: a sensor reads `false` almost all the time, so the
    /// useful fact is when it last fired rather than what it says now.
    Q_PROPERTY(bool everMoved MEMBER m_ever_moved NOTIFY changed)
    Q_PROPERTY(QString lastMotion READ lastMotion NOTIFY changed)
    Q_PROPERTY(bool recentMotion READ recentMotion NOTIFY changed)

    /// A command was sent and the state topic has not confirmed it yet.
    Q_PROPERTY(bool pending MEMBER m_pending NOTIFY changed)
    /// Seconds since this device last reported, so stale readings look stale.
    Q_PROPERTY(QString age READ age NOTIFY changed)

public:
    explicit Device(const dirigera::DeviceFrame& f, QObject* parent = nullptr) : QObject(parent)
    {
        m_id = QString::fromStdString(f.id);
        m_kind = QString::fromStdString(f.type);
        apply(f);
    }

    /// What a device is for. Grouping by room alone puts a lamp, an occupancy sensor and a
    /// light meter in one list, and they answer three different questions -- what can I
    /// switch, is anyone there, how bright is it. Room stays a label; this is the axis.
    // Mirrors dirigera::Role so QML can compare against it; the classification itself
    // lives in devices.hpp, where it is testable without Qt.
    enum class Role {
        Light,      ///< an actuator: you operate it
        Presence,   ///< occupancy: motion, transient, event-driven
        Ambient,    ///< a measurement: illuminance, continuous
        Control,    ///< an input: a remote or dimmer, only its battery is actionable
        Other,      ///< the gateway, and anything a firmware adds later
    };
    Q_ENUM(Role)

    Role role() const
    {
        return static_cast<Role>(dirigera::roleFor(m_kind.toStdString()));
    }

    int roleValue() const { return static_cast<int>(role()); }

    void apply(const dirigera::DeviceFrame& f)
    {
        m_name = QString::fromStdString(f.name);
        m_relation = QString::fromStdString(f.relation);
        m_room = QString::fromStdString(f.room);
        m_model = QString::fromStdString(f.model);
        m_reachable = f.reachable;

        m_has_on = f.is_on.has_value();
        if (f.is_on) m_is_on = *f.is_on;
        m_has_level = f.light_level.has_value();
        if (f.light_level) m_level = *f.light_level;
        m_has_kelvin = f.color_temperature.has_value();
        if (f.color_temperature) m_kelvin = *f.color_temperature;
        m_kelvin_min = f.temperature_min ? *f.temperature_min : 2200;
        m_kelvin_max = f.temperature_max ? *f.temperature_max : 4000;

        m_has_battery = f.battery.has_value();
        if (f.battery) m_battery = *f.battery;
        m_has_motion = f.is_detected.has_value();
        if (f.is_detected) {
            // A rising edge is the event worth remembering. Without this the interface
            // shows "no motion" for a sensor that fired ten seconds ago, which is the
            // opposite of what somebody looking at it wants to know.
            if (*f.is_detected && !m_motion) {
                m_last_motion.start();
                m_ever_moved = true;
            }
            m_motion = *f.is_detected;
        }
        m_has_illuminance = f.illuminance.has_value();
        if (f.illuminance) m_illuminance = static_cast<int>(*f.illuminance);

        m_can_set_on = f.can_set_on;
        m_can_set_level = f.can_set_level;
        m_can_set_kelvin = f.can_set_temperature;

        m_seen.start();
        Q_EMIT changed();
    }

    /// The label QML shows. The light-sensor half of a VALLHORN has no name of its own, so
    /// it borrows a description rather than appearing blank.
    Q_INVOKABLE QString label() const
    {
        if (!m_name.isEmpty()) return m_name;
        if (m_kind == QStringLiteral("lightSensor")) return QStringLiteral("light level");
        return m_id.left(8);
    }

    QString age() const
    {
        const qint64 ms = m_seen.isValid() ? m_seen.elapsed() : 0;
        if (ms < 2000) return QStringLiteral("now");
        if (ms < 90'000) return QStringLiteral("%1s").arg(ms / 1000);
        return QStringLiteral("%1m").arg(ms / 60'000);
    }

    void markPending() { m_pending = true; m_pending_since.start(); Q_EMIT changed(); }

    /// Clear a pending mark once the state topic confirms, or once it has plainly not.
    void settle(bool confirmed)
    {
        if (!m_pending) return;
        if (confirmed || (m_pending_since.isValid() && m_pending_since.elapsed() > kPendingMs)) {
            m_pending = false;
            Q_EMIT changed();
        }
    }

    /// How long ago this sensor last saw movement.
    QString lastMotion() const
    {
        if (!m_ever_moved || !m_last_motion.isValid()) return QStringLiteral("--");
        const qint64 s = m_last_motion.elapsed() / 1000;
        if (s < 60) return QStringLiteral("%1s ago").arg(s);
        if (s < 3600) return QStringLiteral("%1m ago").arg(s / 60);
        return QStringLiteral("%1h ago").arg(s / 3600);
    }

    /// Currently detecting, or did so within the last half minute. The hub clears
    /// `isDetected` on its own schedule, so a strict reading flickers.
    bool recentMotion() const
    {
        if (m_motion) return true;
        return m_ever_moved && m_last_motion.isValid() && m_last_motion.elapsed() < 30'000;
    }

    QString id() const { return m_id; }
    QString room() const { return m_room; }
    QString kind() const { return m_kind; }
    QString relation() const { return m_relation; }
    bool hasIlluminanceValue() const { return m_has_illuminance; }
    int illuminanceValue() const { return m_illuminance; }
    QString nameOnly() const { return m_name; }

Q_SIGNALS:
    void changed();

private:
    QString m_id, m_kind, m_name, m_room, m_model, m_relation;
    bool m_reachable{false};
    bool m_is_on{false}, m_has_on{false};
    int m_level{0};
    bool m_has_level{false};
    int m_kelvin{2700}, m_kelvin_min{2200}, m_kelvin_max{4000};
    bool m_has_kelvin{false};
    int m_battery{0};
    bool m_has_battery{false};
    bool m_motion{false}, m_has_motion{false};
    int m_illuminance{0};
    bool m_has_illuminance{false};
    bool m_can_set_on{false}, m_can_set_level{false}, m_can_set_kelvin{false};
    bool m_pending{false};
    bool m_ever_moved{false};
    QElapsedTimer m_seen, m_pending_since, m_last_motion;
};

/// The station: the qnnt node, the device list, and the hub's status.
class Home : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QList<QObject*> devices MEMBER m_devices NOTIFY devicesChanged)
    Q_PROPERTY(QStringList rooms MEMBER m_rooms NOTIFY devicesChanged)

    // Split by FUNCTION, because a lamp, an occupancy sensor and a light meter answer
    // different questions and a single per-room list conflates them. Room remains a label
    // inside each of these.
    Q_PROPERTY(QList<QObject*> lights MEMBER m_lights NOTIFY devicesChanged)
    /// One entry per physical sensor unit, not per hub device: a VALLHORN is one thing on
    /// the wall that the hub reports as two, and `relation` is what joins them.
    Q_PROPERTY(QList<QObject*> sensors MEMBER m_sensors NOTIFY devicesChanged)
    Q_PROPERTY(QList<QObject*> controls MEMBER m_controls NOTIFY devicesChanged)

    Q_PROPERTY(int presenceActive READ presenceActive NOTIFY devicesChanged)
    Q_PROPERTY(int sensorCount READ sensorCount NOTIFY devicesChanged)
    Q_PROPERTY(int lowBattery READ lowBattery NOTIFY devicesChanged)

    Q_PROPERTY(QString hub READ hub NOTIFY statusChanged)
    Q_PROPERTY(QString firmware READ firmware NOTIFY statusChanged)
    Q_PROPERTY(bool apiLink READ apiLink NOTIFY statusChanged)
    Q_PROPERTY(bool eventLink READ eventLink NOTIFY statusChanged)
    Q_PROPERTY(QString linkDetail READ linkDetail NOTIFY statusChanged)
    Q_PROPERTY(bool haveStatus MEMBER m_have_status NOTIFY statusChanged)

    // Pairing. The bridge runs the exchange -- it owns the hub connection -- and this only
    // starts it and shows what it says, because the decisive step happens at the hub
    // itself, under someone's thumb.
    Q_PROPERTY(bool paired MEMBER m_paired NOTIFY statusChanged)
    Q_PROPERTY(bool pairing MEMBER m_pairing NOTIFY statusChanged)
    Q_PROPERTY(QString pairDetail MEMBER m_pair_detail NOTIFY statusChanged)
    Q_PROPERTY(int lightsOn READ lightsOn NOTIFY devicesChanged)
    Q_PROPERTY(int lightCount READ lightCount NOTIFY devicesChanged)

public:
    explicit Home(const QString& prefix, QObject* parent = nullptr)
        : QObject(parent), m_prefix(prefix)
    {
        auto* node = qnnt::QnntNode::instance();
        node->configureFromEnvironment();
        if (!node->start()) {
            std::printf("dirigera-home: could not start the qnnt node\n");
            return;
        }

        node->addPublisher(topic("light"));
        node->addPublisher(topic("pair"));
        node->addSubscriber(topic("inventory"), qnnt::QnntNode::Delivery::Frames);
        node->addSubscriber(topic("state"), qnnt::QnntNode::Delivery::Frames);
        node->addSubscriber(topic("status"), qnnt::QnntNode::Delivery::Frames);
        connect(node, &qnnt::QnntNode::frameAvailable, this, &Home::onFrame);

        // Ages and pending marks are time-based, so they need a tick of their own -- the
        // topics only speak when something changes.
        auto* timer = new QTimer(this);
        connect(timer, &QTimer::timeout, this, [this] {
            for (auto* object : m_devices) {
                auto* device = qobject_cast<Device*>(object);
                if (device) device->settle(false);
            }
            Q_EMIT devicesChanged();
        });
        timer->start(1000);

        m_started = true;
    }

    bool started() const { return m_started; }

    QString hub() const { return m_hub.isEmpty() ? QStringLiteral("DIRIGERA") : m_hub; }
    QString firmware() const { return m_firmware; }
    bool apiLink() const { return m_have_status && m_api_link; }
    bool eventLink() const { return m_have_status && m_event_link; }

    QString linkDetail() const
    {
        if (!m_have_status) return QStringLiteral("waiting for the bridge");
        QString text = QStringLiteral("api %1  events %2  %3 received")
                           .arg(m_api_link ? QStringLiteral("up") : QStringLiteral("DOWN"),
                                m_event_link ? QStringLiteral("up") : QStringLiteral("DOWN"))
                           .arg(m_events);
        if (m_unparsed > 0) text += QStringLiteral(", %1 unparsed").arg(m_unparsed);
        if (m_dropped > 0) text += QStringLiteral(", %1 fragments dropped").arg(m_dropped);
        if (m_refused > 0) text += QStringLiteral(", %1 refused").arg(m_refused);
        if (m_failed > 0) text += QStringLiteral(", %1 failed").arg(m_failed);
        if (m_reconnects > 0) text += QStringLiteral(", %1 reconnects").arg(m_reconnects);
        return text;
    }

    int lightsOn() const
    {
        int n = 0;
        for (auto* object : m_devices) {
            auto* d = qobject_cast<Device*>(object);
            if (d && d->kind() == QStringLiteral("light") && d->property("isOn").toBool()) n++;
        }
        return n;
    }

    int lightCount() const { return static_cast<int>(m_lights.size()); }

    /// Sensors seeing movement now or very recently -- the "is anyone home" number.
    int presenceActive() const
    {
        int n = 0;
        for (auto* object : m_sensors) {
            auto* d = qobject_cast<Device*>(object);
            if (d && d->recentMotion()) n++;
        }
        return n;
    }

    int sensorCount() const { return static_cast<int>(m_sensors.size()); }

    /// Battery-powered devices worth attending to. The only actionable fact a remote or a
    /// sensor offers, which is why it is surfaced as a count rather than buried per row.
    int lowBattery() const
    {
        int n = 0;
        for (auto* list : { &m_sensors, &m_controls }) {
            for (auto* object : *list) {
                auto* d = qobject_cast<Device*>(object);
                if (!d) continue;
                if (d->property("hasBattery").toBool() && d->property("battery").toInt() < 20) n++;
            }
        }
        return n;
    }

    /// The illuminance reported by the OTHER half of a physical sensor unit. The light
    /// sensor carries no name or room of its own, so it is never shown as a row -- its
    /// reading is folded into its motion twin instead.
    Q_INVOKABLE int illuminanceFor(const QString& relation) const
    {
        for (auto* object : m_devices) {
            auto* d = qobject_cast<Device*>(object);
            if (!d || d->relation() != relation) continue;
            if (d->role() == Device::Role::Ambient && d->hasIlluminanceValue())
                return d->illuminanceValue();
        }
        return -1;
    }

    Q_INVOKABLE bool hasIlluminanceFor(const QString& relation) const
    {
        return illuminanceFor(relation) >= 0;
    }

public Q_SLOTS:
    void setOn(const QString& id, bool on)
    {
        LightCommand cmd;
        cmd.id = id.toStdString();
        cmd.on = on;
        send(id, cmd);
    }

    void setLevel(const QString& id, int level)
    {
        LightCommand cmd;
        cmd.id = id.toStdString();
        cmd.level = static_cast<std::uint8_t>(std::clamp(level, 0, 100));
        send(id, cmd);
    }

    void setKelvin(const QString& id, int kelvin)
    {
        LightCommand cmd;
        cmd.id = id.toStdString();
        cmd.kelvin = static_cast<std::uint16_t>(std::clamp(kelvin, 1000, 10000));
        send(id, cmd);
    }

    /// Every controllable light in one room. Convenient, and the reason it is per-room
    /// rather than whole-house: a single button that switches off someone's entire home is
    /// a mis-click waiting to happen.
    void setRoom(const QString& room, bool on)
    {
        for (auto* object : m_lights) {
            auto* d = qobject_cast<Device*>(object);
            if (!d || d->room() != room) continue;
            if (!d->property("canSetOn").toBool()) continue;
            setOn(d->id(), on);
        }
    }

Q_SIGNALS:
    void devicesChanged();
    void statusChanged();

public Q_SLOTS:
    /// Ask the bridge to pair. It answers through the status topic rather than here: the
    /// operator still has to walk to the hub and press its button, so progress arrives over
    /// the following minutes and this returns at once.
    void startPairing(const QString& name)
    {
        dirigera::PairRequest request;
        request.name = name.isEmpty() ? std::string("qnnt-home") : name.toStdString();
        request.cancel = false;
        qnnt::QnntNode::instance()->publishPacked(topic("pair"), request);
    }

    void cancelPairing()
    {
        dirigera::PairRequest request;
        request.cancel = true;
        qnnt::QnntNode::instance()->publishPacked(topic("pair"), request);
    }

private Q_SLOTS:
    void onFrame(const QString& topic_name, const QByteArray& frame)
    {
        if (topic_name == topic("inventory")) {
            const auto inv = qnnt::QnntNode::unpacked<InventoryFrame>(frame);
            m_hub = QString::fromStdString(inv.hub);
            applyInventory(inv);
        } else if (topic_name == topic("state")) {
            const auto state = qnnt::QnntNode::unpacked<StateFrame>(frame);
            applyState(state);
        } else if (topic_name == topic("status")) {
            const auto status = qnnt::QnntNode::unpacked<StatusFrame>(frame);
            m_hub = QString::fromStdString(status.hub);
            m_firmware = QString::fromStdString(status.firmware);
            m_api_link = status.api_link;
            m_event_link = status.event_link;
            m_events = status.events_received;
            m_unparsed = status.events_unparsed;
            m_dropped = status.dropped_fragments;
            m_failed = status.commands_failed;
            m_refused = status.commands_refused;
            m_reconnects = status.reconnects;
            m_paired = status.paired;
            m_pairing = status.pairing;
            m_pair_detail = QString::fromStdString(status.pair_detail);
            m_have_status = true;
            Q_EMIT statusChanged();
        }
    }

private:
    QString topic(const char* leaf) const
    {
        return m_prefix + QLatin1Char('/') + QLatin1String(leaf);
    }

    void applyInventory(const dirigera::InventoryFrame& inv)
    {
        bool structure_changed = false;
        for (const auto& frame : inv.devices) {
            const QString id = QString::fromStdString(frame.id);
            if (auto* existing = find(id)) {
                existing->apply(frame);
            } else {
                m_devices.append(new Device(frame, this));
                structure_changed = true;
            }
        }

        if (structure_changed) {
            // Rooms in a stable order, so the layout does not reshuffle on every refresh.
            m_rooms.clear();
            for (auto* object : m_devices) {
                auto* d = qobject_cast<Device*>(object);
                if (!d) continue;
                const QString room = d->room().isEmpty() ? QStringLiteral("Unassigned") : d->room();
                if (!m_rooms.contains(room)) m_rooms.append(room);
            }
            m_rooms.sort();
            regroup();
        }
        Q_EMIT devicesChanged();
    }

    void applyState(const dirigera::StateFrame& state)
    {
        const QString id = QString::fromStdString(state.device.id);
        auto* device = find(id);
        if (!device) {
            // A device paired since the last inventory refresh. The bridge says as much
            // with `identified`, and the next refresh will fill in the rest.
            if (state.identified) {
                m_devices.append(new Device(state.device, this));
                regroup();
            }
            Q_EMIT devicesChanged();
            return;
        }
        device->apply(state.device);
        // This is the confirmation a click was waiting for.
        device->settle(true);
        Q_EMIT devicesChanged();
    }

    /// Sort the devices into what they are for.
    ///
    /// The Ambient half of a paired unit is deliberately NOT given a row: it has no name
    /// and no room, and it is not a second sensor -- it is the light meter inside the
    /// motion sensor. It appears as a reading on its twin's row, via illuminanceFor().
    /// An Ambient device with no Presence twin does get its own row, since then it really
    /// is a standalone light meter.
    void regroup()
    {
        m_lights.clear();
        m_sensors.clear();
        m_controls.clear();

        for (auto* object : m_devices) {
            auto* d = qobject_cast<Device*>(object);
            if (!d) continue;
            switch (d->role()) {
                case Device::Role::Light:
                    m_lights.append(d);
                    break;
                case Device::Role::Presence:
                    m_sensors.append(d);
                    break;
                case Device::Role::Ambient:
                    // Folded into its motion twin's row when it has one -- see
                    // dirigera::ownRow.
                    if (dirigera::ownRow(dirigera::Role::Ambient,
                                         hasPresenceTwin(d->relation())))
                        m_sensors.append(d);
                    break;
                case Device::Role::Control:
                    m_controls.append(d);
                    break;
                case Device::Role::Other:
                    break; // the gateway is not a thing to operate or read
            }
        }
    }

    bool hasPresenceTwin(const QString& relation) const
    {
        if (relation.isEmpty()) return false;
        for (auto* object : m_devices) {
            auto* d = qobject_cast<Device*>(object);
            if (d && d->relation() == relation && d->role() == Device::Role::Presence)
                return true;
        }
        return false;
    }

    Device* find(const QString& id) const
    {
        for (auto* object : m_devices) {
            auto* d = qobject_cast<Device*>(object);
            if (d && d->id() == id) return d;
        }
        return nullptr;
    }

    void send(const QString& id, const dirigera::LightCommand& cmd)
    {
        qnnt::QnntNode::instance()->publishPacked(topic("light"), cmd);
        // Marked pending, not applied: the hub confirms through the state topic, and until
        // it does the interface should not pretend the light changed.
        if (auto* device = find(id)) device->markPending();
    }

    QString m_prefix;
    bool m_started{false};
    QList<QObject*> m_devices;
    QList<QObject*> m_lights, m_sensors, m_controls;
    QStringList m_rooms;

    QString m_hub, m_firmware;
    bool m_api_link{false}, m_event_link{false}, m_have_status{false};
    bool m_paired{false}, m_pairing{false};
    QString m_pair_detail;
    quint64 m_events{0}, m_unparsed{0}, m_dropped{0}, m_failed{0}, m_refused{0},
        m_reconnects{0};
};

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);

    const QString qml = (argc > 1 && argv[1][0] != '\0')
                            ? QString::fromLocal8Bit(argv[1])
                            : QStringLiteral("examples/dirigera/main.qml");
    const QString prefix = (argc > 2 && argv[2][0] != '\0')
                               ? QString::fromLocal8Bit(argv[2])
                               : QStringLiteral("home/dirigera");

    Home home(prefix);
    if (!home.started()) return 1;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("home"), &home);
    engine.load(QUrl::fromLocalFile(qml));
    if (engine.rootObjects().isEmpty()) {
        std::printf("dirigera-home: could not load %s (run from the repository root, or "
                    "pass a path to main.qml)\n",
                    qPrintable(qml));
        return 1;
    }

    const int rc = app.exec();
    qnnt::QnntNode::instance()->stop();
    return rc;
}

#include "home.moc"
