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
#include <QQuickPaintedItem>
#include <QPainter>
#include <QImage>
#include <QColor>
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

/// One camera frame, as the bridge republished it. Mirrors CameraFrame in bridge.zig.
/// The live view. A painted item holding one decoded frame, which is the same shape the
/// depth-camera viewer uses -- and the reason not to use an Image with an image provider is
/// that the provider would decode on the render thread and the frame arrives on this one.
///
/// It holds ONE frame. A queue would only add latency: a frame that arrives while the
/// previous one is still on screen is newer, and showing the newer one is the whole job.
class VideoView : public QQuickPaintedItem
{
    Q_OBJECT
    // Registered explicitly in main() rather than with QML_ELEMENT, which would need the
    // qmlregistration header and a qt_add_qml_module build this example does not use.

public:
    VideoView() { setFillColor(QColor{"#0a0c10"}); }

    /// Called from the frame handler with the JPEG exactly as the robot produced it.
    void offer(const QByteArray& jpeg)
    {
        QImage decoded;
        // Decoding here rather than in paint(): paint runs on the render thread and would
        // block the UI for the length of a JPEG decode, every frame.
        if (!decoded.loadFromData(jpeg, "JPEG")) {
            ++m_undecodable;
            return;
        }
        m_image = std::move(decoded);
        ++m_shown;
        update();
    }

    [[nodiscard]] quint64 shown() const { return m_shown; }
    [[nodiscard]] quint64 undecodable() const { return m_undecodable; }
    [[nodiscard]] QSize frameSize() const { return m_image.size(); }

    void paint(QPainter* painter) override
    {
        if (m_image.isNull()) return;
        // Fitted, never stretched: a robot camera's aspect ratio is information -- an
        // operator judging a gap by eye must not be judging a distorted one.
        const QSizeF box = size();
        const QSizeF scaled = QSizeF{m_image.size()}.scaled(box, Qt::KeepAspectRatio);
        const QRectF target{
            (box.width() - scaled.width()) / 2,
            (box.height() - scaled.height()) / 2,
            scaled.width(),
            scaled.height(),
        };
        painter->setRenderHint(QPainter::SmoothPixmapTransform, true);
        painter->drawImage(target, m_image);
    }

private:
    QImage m_image;
    quint64 m_shown{0};
    quint64 m_undecodable{0};
};

struct CameraFrame {
    quint64 seq{};
    quint64 t_us{};
    quint32 bytes{};
    std::vector<std::uint8_t> jpeg;
    TLD_DEFINE_MAP(seq, t_us, bytes, jpeg)
};

/// Cycle a light. Mirrors LightCommand in bridge.zig: a step, not a level, because the
/// robot offers no absolute set for either light.
struct LightCommand {
    bool base{};
    bool head{};
    TLD_DEFINE_MAP(base, head)
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
    bool video_link{};
    quint64 video_frames{};
    quint64 video_dropped{};
    TLD_DEFINE_MAP(t_us, link, telemetry_link, limits_from_robot, robot, max_speed,
                   pan_min_deg, pan_max_deg, tilt_min_deg, tilt_max_deg, commanded_left,
                   commanded_right, deadman, since_command_ms, commands_sent,
                   commands_failed, telemetry_frames, telemetry_errors, clamped, rejected,
                   video_link, video_frames, video_dropped)
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
    /// What the pad drives: false the rover, true the camera arm.
    ///
    /// One control for both, rather than a pad for the rover and a row of preset buttons for
    /// the arm. The presets could only jump to fixed angles, which is not how you aim a
    /// camera -- you aim it by looking at the picture and moving until it is right, and that
    /// is exactly what the pad already affords.
    Q_PROPERTY(bool cameraMode READ cameraMode WRITE setCameraMode NOTIFY modeChanged)
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
    Q_PROPERTY(bool videoLink READ videoLink NOTIFY statusChanged)
    Q_PROPERTY(QString videoStats READ videoStats NOTIFY videoChanged)
    /// 0-255 as the robot reports them, so the button can show what actually happened
    /// rather than what was asked for.
    Q_PROPERTY(int baseLight READ baseLight NOTIFY telemetryChanged)
    Q_PROPERTY(int ledMode READ ledMode NOTIFY telemetryChanged)

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
        node->addSubscriber(topic("camera"), qnnt::QnntNode::Delivery::Frames);
        node->addPublisher(topic("lights"));
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

        // In camera mode the same keys nudge the arm. A NUDGE per key-down, not a held
        // rate: the gimbal command is an absolute angle, so a rate would need a timer of
        // its own here and would drift against whatever the arm actually reached. A step
        // per press is also what an operator wants when framing a shot.
        if (m_camera_mode) {
            if (!down) return;
            constexpr double step = 5.0;
            double pan = m_aim_pan;
            double tilt = m_aim_tilt;
            if (k == QStringLiteral("a") || k == QStringLiteral("left")) pan -= step;
            else if (k == QStringLiteral("d") || k == QStringLiteral("right")) pan += step;
            else if (k == QStringLiteral("w") || k == QStringLiteral("up")) tilt += step;
            else if (k == QStringLiteral("s") || k == QStringLiteral("down")) tilt -= step;
            else return;

            m_aim_pan = std::clamp(pan, panMin(), panMax());
            m_aim_tilt = std::clamp(tilt, tiltMin(), tiltMax());
            aimGimbal(m_aim_pan, m_aim_tilt);
            Q_EMIT inputChanged();
            return;
        }

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
    [[nodiscard]] bool cameraMode() const { return m_camera_mode; }

    /// The axes' travel, as the robot reported it. Falling back to the conservative built-in
    /// range rather than to zero: a zero range would make the pad inert and look broken,
    /// where a small range simply aims less far until the status frame arrives.
    [[nodiscard]] double panMin() const {
        return m_have_status and m_status.pan_min_deg != 0 ? m_status.pan_min_deg : -180.0;
    }
    [[nodiscard]] double panMax() const {
        return m_have_status and m_status.pan_max_deg != 0 ? m_status.pan_max_deg : 180.0;
    }
    [[nodiscard]] double tiltMin() const {
        return m_have_status and m_status.tilt_min_deg != 0 ? m_status.tilt_min_deg : -30.0;
    }
    [[nodiscard]] double tiltMax() const {
        return m_have_status and m_status.tilt_max_deg != 0 ? m_status.tilt_max_deg : 90.0;
    }

    /// Switching mode STOPS THE ROVER first, always, in both directions.
    ///
    /// Leaving for the camera while a track command stands would drive the robot with a
    /// control that is no longer pointed at it -- the operator's hand is on the pad, the pad
    /// now means "pan", and the rover keeps the last thing it was told. The deadman would
    /// catch it in half a second, but a mode switch should not depend on a watchdog.
    void setCameraMode(bool on)
    {
        if (on == m_camera_mode) return;
        releaseAll();
        m_camera_mode = on;
        Q_EMIT modeChanged();
        Q_EMIT inputChanged();
    }

    void setPad(double x, double y)
    {
        const double cx = std::clamp(x, -1.0, 1.0);
        const double cy = std::clamp(y, -1.0, 1.0);

        if (m_camera_mode) {
            // The pad's position IS the aim, scaled to the axes' travel as the robot
            // reported it -- so the pad's edge is the axis's limit rather than an arbitrary
            // angle, and the same gesture means the same thing on a differently-built robot.
            const double pan = cx >= 0 ? cx * panMax() : -cx * panMin();
            const double tilt = cy >= 0 ? cy * tiltMax() : -cy * tiltMin();
            m_aim_pan = pan;
            m_aim_tilt = tilt;
            aimGimbal(pan, tilt);
            Q_EMIT inputChanged();
            return;
        }

        m_pad_active = true;
        m_pad_x = cx;
        m_pad_y = cy;
        recompute();
    }

    /// Let go.
    ///
    /// The two modes differ here on purpose. The rover springs back to stopped, because a
    /// vehicle that keeps moving when you release the control is the one failure this whole
    /// bridge is built to prevent. The camera HOLDS its aim, because a camera that snapped
    /// back to centre every time you let go could never be pointed at anything.
    void releasePad()
    {
        if (m_camera_mode) return;
        m_pad_active = false;
        m_pad_x = m_pad_y = 0.0;
        recompute();
    }

    /// Centre the arm. What the pad's middle means, as a button, because reaching the exact
    /// middle by hand is fiddly and centring is the one aim worth having a shortcut for.
    void centreGimbal()
    {
        m_aim_pan = 0;
        m_aim_tilt = 0;
        aimGimbal(0, 0);
        Q_EMIT inputChanged();
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
    /// Cycle a light. One press, one step -- the robot has no absolute level for either, so
    /// the button reports what happened by way of the telemetry that comes back rather than
    /// by assuming it worked.
    void cycleBaseLight()
    {
        LightCommand cmd;
        cmd.base = true;
        qnnt::QnntNode::instance()->publishPacked(topic("lights"), cmd);
    }

    void cycleHeadLight()
    {
        LightCommand cmd;
        cmd.head = true;
        qnnt::QnntNode::instance()->publishPacked(topic("lights"), cmd);
    }

    /// Where the decoded frames go. Set once from QML, because the item is created there.
    void bindVideo(VideoView* view) { m_video = view; }

    [[nodiscard]] bool videoLink() const { return m_have_status and m_status.video_link; }
    [[nodiscard]] int baseLight() const { return m_have_telemetry ? m_telemetry.base_light : 0; }
    [[nodiscard]] int ledMode() const { return m_have_telemetry ? m_telemetry.led_mode : 0; }

    /// What the video path is doing, end to end: what the bridge pulled off the robot, what
    /// reached here, and what would not decode. Three numbers because they fail separately
    /// -- a robot that stopped sending, a topic nobody is publishing, and a frame that
    /// arrived corrupt are three different problems.
    [[nodiscard]] QString videoStats() const
    {
        const quint64 bridged = m_have_status ? m_status.video_frames : 0;
        const quint64 dropped = m_have_status ? m_status.video_dropped : 0;
        const quint64 shown = m_video ? m_video->shown() : 0;
        const quint64 bad = (m_video ? m_video->undecodable() : 0) + m_camera_errors;
        const QSize dim = m_video ? m_video->frameSize() : QSize{};

        QString out = QStringLiteral("%1 shown / %2 bridged").arg(shown).arg(bridged);
        if (!dim.isEmpty()) out += QStringLiteral("  %1x%2").arg(dim.width()).arg(dim.height());
        if (dropped) out += QStringLiteral("  %1 dropped at the bridge").arg(dropped);
        if (bad) out += QStringLiteral("  %1 undecodable").arg(bad);
        return out;
    }

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
    void videoChanged();
    void modeChanged();

private Q_SLOTS:
    void onFrame(const QString& topic_name, const QByteArray& frame)
    {
        if (topic_name == topic("telemetry")) {
            m_telemetry = qnnt::QnntNode::unpacked<TelemetryFrame>(frame);
            m_telemetry_at_ms = m_elapsed.elapsed();
            m_have_telemetry = true;
            Q_EMIT telemetryChanged();
        } else if (topic_name == topic("camera")) {
            // Decoded and drawn, or counted as undecodable -- never silently dropped: a
            // camera that shows nothing and reports nothing is indistinguishable from a
            // camera that is off.
            try {
                const auto cam = qnnt::QnntNode::unpacked<CameraFrame>(frame);
                if (m_video) {
                    m_video->offer(QByteArray{
                        reinterpret_cast<const char*>(cam.jpeg.data()),
                        int(cam.jpeg.size()),
                    });
                    Q_EMIT videoChanged();
                }
            } catch (...) {
                ++m_camera_errors;
            }
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
    bool m_camera_mode{false};
    /// The last aim sent, so the view can show where the arm was pointed even though the
    /// pad has sprung back visually.
    double m_aim_pan{0};
    double m_aim_tilt{0};
    VideoView* m_video{nullptr};
    quint64 m_camera_errors{0};
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

    // Registered so main.qml can create the view; the pilot is handed the instance from
    // there, because QML owns the item's lifetime.
    qmlRegisterType<VideoView>("Qnnt.Ugv", 1, 0, "VideoView");

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
