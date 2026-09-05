//! ugv-pilot: the Qt/QML control station for the UGV Beast.
//!
//!   ./zig-out/bin/ugv-bridge --host 192.168.50.5:5000    # terminal 1
//!   ./zig-out/bin/ugv-pilot                              # terminal 2
//!
//!   ugv-pilot [path/to/main.qml] [topic-prefix]
//!
//! Drive with WASD or the arrow keys, or drag the pad. Space stops. The slider scales
//! everything, and what it scales is a fraction of the robot's own max_speed, which arrives
//! on the status topic -- this program has no speed constant of its own.
//!
//! Three things here are safety behaviour rather than interface, and they are the reason
//! this is not just a few buttons wired to publish():
//!
//! 1. **It publishes at a fixed 10 Hz whether or not anything changed.** The bridge's
//!    watchdog stops the robot if commands stop arriving for 500 ms, so a controller that
//!    published only on change would be indistinguishable from a crashed one the moment the
//!    operator held a steady speed. Publishing continuously is what makes the watchdog's
//!    silence meaningful: if this window closes, freezes, or loses its network, the robot
//!    stops on its own.
//!
//! 2. **Losing window focus releases every key.** A key-up that arrives while another
//!    window has focus is never delivered, so a held key would latch on and the robot would
//!    keep driving after the operator alt-tabbed away. Focus-out clears the key state.
//!
//! 3. **It shows the deadman.** When the bridge has zeroed the setpoint the pad turns red
//!    and says so, because "I am pressing a key and the robot is not moving" needs to be
//!    visibly explained rather than silently true.

#include "qnnt_qt.hpp"
#include "steering.hpp"

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
#include <cmath>
#include <cstdio>

namespace {

/// What the bridge subscribes to. Field names and types match the Zig structs in
/// examples/ugv/bridge.zig; TLD matches on names, so the two have to agree.
struct Drive {
    float left{};
    float right{};
    TLD_DEFINE_MAP(left, right)
};

struct GimbalCmd {
    float pan{};
    float tilt{};
    quint16 speed{};
    quint16 accel{};
    TLD_DEFINE_MAP(pan, tilt, speed, accel)
};

struct TelemetryFrame {
    quint64 seq{};
    quint64 t_us{};
    float voltage{};
    float pan_deg{};
    float tilt_deg{};
    float cpu_load{};
    float cpu_temp_c{};
    float ram_usage{};
    float video_fps{};
    float wifi_rssi{};
    quint8 led_mode{};
    quint8 base_light{};
    quint32 detect_type{};
    quint32 detect_react{};
    bool motion_mode{};
    TLD_DEFINE_MAP(seq, t_us, voltage, pan_deg, tilt_deg, cpu_load, cpu_temp_c, ram_usage,
                   video_fps, wifi_rssi, led_mode, base_light, detect_type, detect_react,
                   motion_mode)
};

struct StatusFrame {
    quint64 t_us{};
    bool link{};
    bool telemetry_link{};
    bool limits_from_robot{};
    QString robot;
    float max_speed{};
    float pan_min_deg{};
    float pan_max_deg{};
    float tilt_min_deg{};
    float tilt_max_deg{};
    float commanded_left{};
    float commanded_right{};
    bool deadman{};
    quint64 since_command_ms{};
    quint64 commands_sent{};
    quint64 commands_failed{};
    quint64 telemetry_frames{};
    quint64 telemetry_errors{};
    quint64 clamped{};
    quint64 rejected{};
    TLD_DEFINE_MAP(t_us, link, telemetry_link, limits_from_robot, robot, max_speed,
                   pan_min_deg, pan_max_deg, tilt_min_deg, tilt_max_deg, commanded_left,
                   commanded_right, deadman, since_command_ms, commands_sent,
                   commands_failed, telemetry_frames, telemetry_errors, clamped, rejected)
};

/// How often the setpoint goes out. Must be comfortably inside the bridge's --deadman
/// (500 ms by default) or the robot would stop under a steady hand.
constexpr int kPublishMs = 100;

/// Battery range for the gauge. A 3S pack: 12.6 V charged, 9.0 V empty-and-damaged, so the
/// bar is scaled over the usable part rather than to zero.
constexpr float kVoltFull = 12.6F;
constexpr float kVoltEmpty = 10.5F;

} // namespace

/// The whole control station: holds the qnnt node, the operator's input, and the last
/// telemetry, and exposes all three to QML.
class Pilot : public QObject
{
    Q_OBJECT

    // -- what the operator is asking for --------------------------------------------
    Q_PROPERTY(double throttle MEMBER m_throttle NOTIFY inputChanged)
    Q_PROPERTY(double left READ left NOTIFY inputChanged)
    Q_PROPERTY(double right READ right NOTIFY inputChanged)
    // The same command expressed as the two axes an operator thinks in. Derived here
    // rather than in QML because the sign convention belongs next to the differential
    // steering that produced it -- deriving it a second time in a QML binding is exactly
    // how the pad indicator ended up moving against the operator's input.
    Q_PROPERTY(double driveAxis READ driveAxis NOTIFY inputChanged)
    Q_PROPERTY(double steerAxis READ steerAxis NOTIFY inputChanged)

    // -- what the robot says ---------------------------------------------------------
    Q_PROPERTY(QString robot READ robot NOTIFY statusChanged)
    Q_PROPERTY(bool link READ link NOTIFY statusChanged)
    Q_PROPERTY(bool telemetryLink READ telemetryLink NOTIFY statusChanged)
    Q_PROPERTY(bool deadman READ deadman NOTIFY statusChanged)
    Q_PROPERTY(bool limitsFromRobot READ limitsFromRobot NOTIFY statusChanged)
    Q_PROPERTY(double maxSpeed READ maxSpeed NOTIFY statusChanged)
    Q_PROPERTY(QString linkDetail READ linkDetail NOTIFY statusChanged)
    Q_PROPERTY(QString commandStats READ commandStats NOTIFY statusChanged)

    Q_PROPERTY(double voltage READ voltage NOTIFY telemetryChanged)
    Q_PROPERTY(double batteryFraction READ batteryFraction NOTIFY telemetryChanged)
    Q_PROPERTY(double panDeg READ panDeg NOTIFY telemetryChanged)
    Q_PROPERTY(double tiltDeg READ tiltDeg NOTIFY telemetryChanged)
    Q_PROPERTY(double cpuLoad READ cpuLoad NOTIFY telemetryChanged)
    Q_PROPERTY(double cpuTemp READ cpuTemp NOTIFY telemetryChanged)
    Q_PROPERTY(double ramUsage READ ramUsage NOTIFY telemetryChanged)
    Q_PROPERTY(double videoFps READ videoFps NOTIFY telemetryChanged)
    Q_PROPERTY(QString telemetryAge READ telemetryAge NOTIFY telemetryChanged)
    Q_PROPERTY(bool haveTelemetry READ haveTelemetry NOTIFY telemetryChanged)

public:
    explicit Pilot(const QString& prefix, QObject* parent = nullptr)
        : QObject(parent), m_prefix(prefix)
    {
        auto* node = qnnt::QnntNode::instance();
        // Every QNNT_* variable, so this can join a federation the same way the bridge and
        // the other examples do.
        node->configureFromEnvironment();
        if (!node->start()) {
            std::printf("ugv-pilot: could not start the qnnt node\n");
            return;
        }

        node->addPublisher(topic("drive"));
        node->addPublisher(topic("gimbal"));
        node->addSubscriber(topic("telemetry"), qnnt::QnntNode::Delivery::Frames);
        node->addSubscriber(topic("status"), qnnt::QnntNode::Delivery::Frames);
        connect(node, &qnnt::QnntNode::frameAvailable, this, &Pilot::onFrame);

        // The fixed-rate output. See note 1 in the file header: this runs whether or not
        // the operator is touching anything.
        auto* timer = new QTimer(this);
        connect(timer, &QTimer::timeout, this, &Pilot::publishDrive);
        timer->start(kPublishMs);

        m_elapsed.start();
        m_started = true;
    }

    bool started() const { return m_started; }

    double left() const { return m_left; }
    double right() const { return m_right; }

    /// The same command as the two axes an operator thinks in. Defined once in
    /// steering.hpp; deriving it a second time in a QML binding is how the pad indicator
    /// once ran backwards.
    double driveAxis() const { return ugv::driveAxis({ m_left, m_right }); }
    double steerAxis() const { return ugv::steerAxis({ m_left, m_right }); }

    QString robot() const { return m_status.robot.isEmpty() ? QStringLiteral("UGV") : m_status.robot; }
    bool link() const { return m_have_status && m_status.link; }
    bool telemetryLink() const { return m_have_status && m_status.telemetry_link; }
    bool deadman() const { return m_have_status && m_status.deadman; }
    bool limitsFromRobot() const { return m_have_status && m_status.limits_from_robot; }
    double maxSpeed() const { return m_have_status ? m_status.max_speed : 0.0; }

    QString linkDetail() const
    {
        if (!m_have_status) return QStringLiteral("waiting for the bridge");
        return QStringLiteral("commands %1  telemetry %2  last command %3 ms ago")
            .arg(m_status.link ? QStringLiteral("up") : QStringLiteral("DOWN"),
                 m_status.telemetry_link ? QStringLiteral("up") : QStringLiteral("DOWN"))
            .arg(m_status.since_command_ms);
    }

    QString commandStats() const
    {
        if (!m_have_status) return QString();
        QString text = QStringLiteral("sent %1, failed %2, telemetry %3")
                           .arg(m_status.commands_sent)
                           .arg(m_status.commands_failed)
                           .arg(m_status.telemetry_frames);
        // Only shown when non-zero: these mean a controller is publishing something the
        // bridge cannot use, or asking for more than the robot allows.
        if (m_status.rejected > 0) text += QStringLiteral(", REJECTED %1").arg(m_status.rejected);
        if (m_status.clamped > 0) text += QStringLiteral(", clamped %1").arg(m_status.clamped);
        if (m_status.telemetry_errors > 0)
            text += QStringLiteral(", poll errors %1").arg(m_status.telemetry_errors);
        return text;
    }

    double voltage() const { return m_telemetry.voltage; }
    double batteryFraction() const
    {
        if (!m_have_telemetry) return 0.0;
        const double f = (m_telemetry.voltage - kVoltEmpty) / (kVoltFull - kVoltEmpty);
        return std::clamp(f, 0.0, 1.0);
    }
    double panDeg() const { return m_telemetry.pan_deg; }
    double tiltDeg() const { return m_telemetry.tilt_deg; }
    double cpuLoad() const { return m_telemetry.cpu_load; }
    double cpuTemp() const { return m_telemetry.cpu_temp_c; }
    double ramUsage() const { return m_telemetry.ram_usage; }
    double videoFps() const { return m_telemetry.video_fps; }
    bool haveTelemetry() const { return m_have_telemetry; }

    /// How stale the reading is. Shown because this robot emits telemetry about every five
    /// seconds, so a display with no age looks frozen or broken when it is neither.
    QString telemetryAge() const
    {
        if (!m_have_telemetry) return QStringLiteral("no telemetry yet");
        const qint64 ms = m_elapsed.elapsed() - m_telemetry_at_ms;
        return ms < 1000 ? QStringLiteral("just now")
                         : QStringLiteral("%1.%2 s ago").arg(ms / 1000).arg((ms % 1000) / 100);
    }

public Q_SLOTS:
    /// A key went down or up. Held as a set rather than as a velocity so that opposing keys
    /// cancel and releasing one of two still leaves the other driving.
    void setKey(const QString& key, bool down)
    {
        const QString k = key.toLower();
        if (k == QStringLiteral("w") || k == QStringLiteral("up")) m_fwd = down;
        else if (k == QStringLiteral("s") || k == QStringLiteral("down")) m_back = down;
        else if (k == QStringLiteral("a") || k == QStringLiteral("left")) m_leftward = down;
        else if (k == QStringLiteral("d") || k == QStringLiteral("right")) m_rightward = down;
        else return;
        recompute();
    }

    /// Every key up at once, for focus loss. See note 2 in the file header.
    void releaseAll()
    {
        m_fwd = m_back = m_leftward = m_rightward = false;
        m_pad_active = false;
        m_pad_x = m_pad_y = 0.0;
        recompute();
    }

    /// The drag pad: -1..1 in each axis, y positive forward.
    void setPad(double x, double y)
    {
        m_pad_active = true;
        m_pad_x = std::clamp(x, -1.0, 1.0);
        m_pad_y = std::clamp(y, -1.0, 1.0);
        recompute();
    }

    void releasePad()
    {
        m_pad_active = false;
        m_pad_x = m_pad_y = 0.0;
        recompute();
    }

    /// Zero now, and drop the operator's input with it. Not merely "publish a zero": if the
    /// keys were left held, a stop that did not clear them would be undone 100 ms later.
    void stop() { releaseAll(); }

    void setThrottle(double t)
    {
        m_throttle = std::clamp(t, 0.0, 1.0);
        recompute();
        Q_EMIT inputChanged();
    }

    /// An absolute pan-tilt target. The bridge clamps to the axes' travel, so out-of-range
    /// values here are reduced rather than refused.
    void aimGimbal(double pan, double tilt)
    {
        GimbalCmd cmd;
        cmd.pan = static_cast<float>(pan);
        cmd.tilt = static_cast<float>(tilt);
        qnnt::QnntNode::instance()->publishPacked(topic("gimbal"), cmd);
    }

Q_SIGNALS:
    void inputChanged();
    void statusChanged();
    void telemetryChanged();

private Q_SLOTS:
    void onFrame(const QString& topic_name, const QByteArray& frame)
    {
        if (topic_name == topic("telemetry")) {
            m_telemetry = qnnt::QnntNode::unpacked<TelemetryFrame>(frame);
            m_telemetry_at_ms = m_elapsed.elapsed();
            m_have_telemetry = true;
            Q_EMIT telemetryChanged();
        } else if (topic_name == topic("status")) {
            m_status = qnnt::QnntNode::unpacked<StatusFrame>(frame);
            m_have_status = true;
            Q_EMIT statusChanged();
        }
    }

    void publishDrive()
    {
        Drive cmd;
        cmd.left = static_cast<float>(m_left);
        cmd.right = static_cast<float>(m_right);
        qnnt::QnntNode::instance()->publishPacked(topic("drive"), cmd);

        // The age readout has to advance between telemetry frames, not only when one lands.
        if (m_have_telemetry) Q_EMIT telemetryChanged();
    }

private:
    QString topic(const char* leaf) const { return m_prefix + QLatin1Char('/') + QLatin1String(leaf); }

    /// Turn the operator's input into two track speeds. Differential steering: forward is
    /// both tracks together, turning is the difference between them.
    void recompute()
    {
        double fwd = 0.0;
        double turn = 0.0;

        if (m_pad_active) {
            fwd = m_pad_y;
            turn = m_pad_x;
        } else {
            if (m_fwd) fwd += 1.0;
            if (m_back) fwd -= 1.0;
            if (m_rightward) turn += 1.0;
            if (m_leftward) turn -= 1.0;
        }

        // The arithmetic lives in steering.hpp so it can be tested without Qt, an event
        // loop or a robot.
        const ugv::Tracks tracks = ugv::mix(fwd, turn, m_throttle);
        m_left = tracks.left;
        m_right = tracks.right;
        Q_EMIT inputChanged();
    }

    QString m_prefix;
    bool m_started{false};

    // The operator's input.
    double m_throttle{0.4};
    bool m_fwd{false}, m_back{false}, m_leftward{false}, m_rightward{false};
    bool m_pad_active{false};
    double m_pad_x{0.0}, m_pad_y{0.0};
    double m_left{0.0}, m_right{0.0};

    TelemetryFrame m_telemetry;
    StatusFrame m_status;
    bool m_have_telemetry{false};
    bool m_have_status{false};
    qint64 m_telemetry_at_ms{0};
    QElapsedTimer m_elapsed;
};

int main(int argc, char* argv[])
{
    QGuiApplication app(argc, argv);

    const QString qml = (argc > 1 && argv[1][0] != '\0')
                            ? QString::fromLocal8Bit(argv[1])
                            : QStringLiteral("examples/ugv/main.qml");
    const QString prefix = (argc > 2 && argv[2][0] != '\0')
                               ? QString::fromLocal8Bit(argv[2])
                               : QStringLiteral("ugv/beast");

    Pilot pilot(prefix);
    if (!pilot.started()) return 1;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("pilot"), &pilot);
    engine.load(QUrl::fromLocalFile(qml));
    if (engine.rootObjects().isEmpty()) {
        std::printf("ugv-pilot: could not load %s (run from the repository root, or pass a "
                    "path to main.qml)\n",
                    qPrintable(qml));
        return 1;
    }

    const int rc = app.exec();
    // The robot is left to the bridge's watchdog: this process stops publishing, and 500 ms
    // later the bridge sends a stop. Publishing a zero here as well would be belt and
    // braces, but relying on it would be wrong -- a crash gets no chance to.
    qnnt::QnntNode::instance()->stop();
    return rc;
}

#include "pilot.moc"
