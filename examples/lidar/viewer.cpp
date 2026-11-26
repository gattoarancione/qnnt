// A Qt/QML viewer for the fake RS-LiDAR-16 in sensor.zig. See SCHEMA.txt.
//
//   zig build lidar -Dqt=/path/to/Qt/6.10.3/macos
//   ./zig-out/bin/lidar-sensor          # terminal 1
//   ./zig-out/bin/lidar-viewer          # terminal 2, from the project root
//
//   ./zig-out/bin/lidar-viewer '' lidar/helios32 first-person   # open in perspective
//
// The split this demonstrates: the sensor is a Zig node, the display is QML, and neither
// knows the other's language -- only the topic and the TOLD schema.
//
// Two projections of the same revolution, swapped with V: a top-down orthographic view that
// drops z, and a pinhole first-person view from a camera beside the sensor. The first is the
// better instrument -- dropping z collapses a vertical wall onto one line, so a per-channel
// azimuth error shows as a fan -- and the second is the one that reads as a place. See
// kDefaultEye for why the camera must not start at the sensor itself.
//
// Where the work happens matters at this rate. 750 frames a second arrive as signals on the
// GUI thread (the poller inside QnntNode marshals them there), and each is decoded into
// points immediately -- 288,000 points/s, which is a few milliseconds of CPU per second in
// C++. Painting is decoupled from that: points accumulate into the revolution being swept,
// and the item repaints at the window's refresh rate from the last completed revolution.
// Repainting per frame instead would be 750 paints/s of a 28,800-point cloud.

#include "qnnt_qt.hpp"

#include <QColor>
#include <QGuiApplication>
#include <QPainter>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickPaintedItem>
#include <QTimer>
#include <QUrl>
#include <QtQml/qqml.h>

#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {
/// Default topic; override with an argument to view a different sensor.
constexpr auto kDefaultTopic = "lidar/rs16";

constexpr int kMaxChannels = 32;

/// One returned sample in sensor-frame metres: x east, y north, z up, the sensor at the
/// origin. The bird view drops z, which is why it was never carried before; the first-person
/// view needs all three.
struct Point3 {
    float x, y, z;
};

/// A point cloud is drawn in a few passes, one per surface class, so each pass is a single
/// drawPoints call with one pen rather than a pen change per point.
enum SurfaceClass { kFloor = 0, kWall = 1, kPillar = 2, kBox = 3, kSurfaceCount = 4 };

SurfaceClass classify(std::uint8_t intensity) {
    if (intensity >= 250) return kBox;
    if (intensity >= 200) return kPillar;
    if (intensity >= 100) return kWall;
    return kFloor;
}
} // namespace

/// The rendered item: the last completed revolution, drawn either from above or from the
/// sensor's own position.
class LidarView : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(double metresAcross MEMBER m_metres_across NOTIFY viewChanged)
    Q_PROPERTY(bool showFloor MEMBER m_show_floor NOTIFY viewChanged)
    Q_PROPERTY(ViewMode viewMode MEMBER m_mode NOTIFY viewChanged)
    Q_PROPERTY(double fovDeg MEMBER m_fov_deg NOTIFY viewChanged)
    Q_PROPERTY(double yawDeg READ yawDeg NOTIFY viewChanged)
    Q_PROPERTY(double pitchDeg READ pitchDeg NOTIFY viewChanged)
    Q_PROPERTY(QString eyeText READ eyeText NOTIFY viewChanged)
    Q_PROPERTY(bool atOrigin READ atOrigin NOTIFY viewChanged)

public:
    enum ViewMode { Bird, FirstPerson };
    Q_ENUM(ViewMode)

    explicit LidarView(QQuickItem* parent = nullptr) : QQuickPaintedItem{parent} {
        setFillColor(QColor{16, 18, 22});
        for (auto& pass : m_display) pass.reserve(16000);
        for (auto& pass : m_building) pass.reserve(16000);
    }

    /// Called from the decoder for every returned sample of the revolution in progress.
    void addPoint(float x, float y, float z, std::uint8_t intensity) {
        m_building[classify(intensity)].append(Point3{x, y, z});
    }

    /// The sweep passed 360 degrees: the revolution being built becomes the one displayed.
    void completeRevolution() {
        m_display.swap(m_building);
        for (auto& pass : m_building) pass.clear();
        ++m_revolutions;
        m_dirty = true;
    }

    void paint(QPainter* painter) override {
        m_dirty = false;
        m_drawn = 0;
        painter->setRenderHint(QPainter::Antialiasing, false);
        if (m_mode == FirstPerson) {
            paintFirstPerson(painter);
        } else {
            paintBird(painter);
        }
    }

    /// Look around, in degrees. Pitch stops just short of straight up and down: at exactly
    /// +/-90 the yaw becomes meaningless and the view spins on the spot.
    Q_INVOKABLE void look(double d_yaw, double d_pitch) {
        m_yaw_deg = std::fmod(m_yaw_deg + d_yaw, 360.0);
        m_pitch_deg = std::clamp(m_pitch_deg + d_pitch, -89.0, 89.0);
        m_dirty = true;
        Q_EMIT viewChanged();
    }

    /// Walk: forward and strafe in the horizontal plane, rise straight up.
    Q_INVOKABLE void moveBy(double forward, double strafe, double rise = 0.0) {
        const double yaw = m_yaw_deg * M_PI / 180.0;
        m_eye.x += static_cast<float>(forward * std::sin(yaw) + strafe * std::cos(yaw));
        m_eye.y += static_cast<float>(forward * std::cos(yaw) - strafe * std::sin(yaw));
        m_eye.z += static_cast<float>(rise);
        m_dirty = true;
        Q_EMIT viewChanged();
    }

    Q_INVOKABLE void resetView() {
        m_eye = kDefaultEye;
        m_yaw_deg = 0.0;
        m_pitch_deg = kDefaultPitch;
        m_dirty = true;
        Q_EMIT viewChanged();
    }

    /// True when the eye is close enough to the scanner origin for the perspective to be
    /// degenerate. Surfaced so the UI can say so: the view does not look broken in a way
    /// that suggests moving, it looks like a bug.
    bool atOrigin() const {
        return std::hypot(std::hypot(m_eye.x, m_eye.y), m_eye.z) < 0.75;
    }

    double yawDeg() const { return m_yaw_deg < 0 ? m_yaw_deg + 360.0 : m_yaw_deg; }
    double pitchDeg() const { return m_pitch_deg; }

    QString eyeText() const {
        return QStringLiteral("%1, %2, %3 m")
            .arg(static_cast<double>(m_eye.x), 0, 'f', 1)
            .arg(static_cast<double>(m_eye.y), 0, 'f', 1)
            .arg(static_cast<double>(m_eye.z), 0, 'f', 1);
    }

private:
    void paintBird(QPainter* painter) {
        const double side = std::min(width(), height());
        const double scale = side / m_metres_across; // pixels per metre
        painter->translate(width() / 2.0, height() / 2.0);

        drawGrid(painter, scale);

        static const QColor colours[kSurfaceCount]{
            QColor{70, 80, 95},    // floor: dim, it is the bulk of the cloud
            QColor{120, 190, 255}, // wall
            QColor{255, 200, 90},  // pillar
            QColor{255, 90, 120},  // the moving box
        };

        for (int pass = 0; pass < kSurfaceCount; ++pass) {
            if (pass == kFloor && !m_show_floor) continue;
            const auto& points = m_display[pass];
            if (points.isEmpty()) continue;

            // Scaled here rather than at decode time: the decoder should not have to know
            // the zoom, and rescaling 28,800 points is cheaper than the paint itself. z is
            // simply dropped, which is what makes this view flatten a vertical wall onto a
            // single line and so a good test of per-channel azimuth.
            m_scratch.resize(points.size());
            for (qsizetype i = 0; i < points.size(); ++i) {
                m_scratch[i] = QPointF{points[i].x * scale, -points[i].y * scale};
            }

            painter->setPen(QPen{colours[pass], pass == kFloor ? 1.0 : 2.0});
            painter->drawPoints(m_scratch.constData(), static_cast<int>(m_scratch.size()));
            m_drawn += static_cast<int>(m_scratch.size());
        }

        // The sensor itself.
        painter->setPen(Qt::NoPen);
        painter->setBrush(QColor{90, 255, 160});
        painter->drawEllipse(QPointF{0, 0}, 4, 4);
    }

public:
    int revolutions() const { return m_revolutions; }
    bool dirty() const { return m_dirty; }

    /// Points actually put on screen by the last paint, not the size of the revolution.
    /// Those differ once a view can hide some: the floor toggle already made the old count
    /// an overstatement, and first person shows only what is inside the frustum.
    int displayedPoints() const { return m_drawn; }

Q_SIGNALS:
    void viewChanged();

private:
    /// The camera basis for the current yaw and pitch, in the world frame the cloud is in:
    /// x east, y north, z up.
    struct Basis {
        double fx, fy, fz; // forward
        double rx, ry, rz; // right
        double ux, uy, uz; // up
    };

    Basis basis() const {
        const double yaw = m_yaw_deg * M_PI / 180.0;
        const double pitch = m_pitch_deg * M_PI / 180.0;
        const double cy = std::cos(yaw), sy = std::sin(yaw);
        const double cp = std::cos(pitch), sp = std::sin(pitch);

        Basis b{};
        b.fx = sy * cp;
        b.fy = cy * cp;
        b.fz = sp;
        // Right is forward turned a quarter turn in the horizontal plane, so it stays level
        // however far the view pitches.
        b.rx = cy;
        b.ry = -sy;
        b.rz = 0.0;
        // Up completes the frame as right x forward, which tilts with pitch as it should.
        b.ux = b.ry * b.fz - b.rz * b.fy;
        b.uy = b.rz * b.fx - b.rx * b.fz;
        b.uz = b.rx * b.fy - b.ry * b.fx;
        return b;
    }

    /// Anything at or behind this is discarded rather than clamped: a point behind the
    /// camera has a negative depth and would otherwise be drawn mirrored in front of it.
    static constexpr double kNear = 0.15;

    /// A pinhole projection: metres to pixels relative to the centre of the item, the
    /// caller having already translated the painter there.
    bool project(const Point3& p, const Basis& b, double focal, QPointF& out) const {
        const double dx = static_cast<double>(p.x) - m_eye.x;
        const double dy = static_cast<double>(p.y) - m_eye.y;
        const double dz = static_cast<double>(p.z) - m_eye.z;

        const double depth = dx * b.fx + dy * b.fy + dz * b.fz;
        if (depth < kNear) return false;

        const double h = dx * b.rx + dy * b.ry + dz * b.rz;
        const double vv = dx * b.ux + dy * b.uy + dz * b.uz;
        out = QPointF{h / depth * focal, -vv / depth * focal};
        return true;
    }

    void paintFirstPerson(QPainter* painter) {
        // Horizontal field of view to a focal length in pixels -- off the width, so the
        // number in the UI is the angle actually spanned left to right, and the vertical
        // angle follows from the aspect ratio. Halving the FOV doubles the magnification,
        // which is what a zoom control should feel like.
        const double half_w = width() / 2.0;
        const double half_h = height() / 2.0;
        const double focal = half_w / std::tan(m_fov_deg * M_PI / 360.0);
        painter->translate(half_w, half_h);

        const Basis b = basis();
        drawHorizon(painter, b, focal);
        drawRangeRings(painter, b, focal);

        static const QColor colours[kSurfaceCount]{
            QColor{70, 80, 95},
            QColor{120, 190, 255},
            QColor{255, 200, 90},
            QColor{255, 90, 120},
        };

        for (int pass = 0; pass < kSurfaceCount; ++pass) {
            if (pass == kFloor && !m_show_floor) continue;
            const auto& points = m_display[pass];
            if (points.isEmpty()) continue;

            // Compacted rather than resized: points behind the camera or off the edges
            // leave gaps, and drawPoints takes a count, so only the kept prefix is handed
            // over. Culling here rather than inside project() because the rings and the
            // horizon need endpoints off-screen to draw the segment between them -- and
            // culling at all because half a 360 degree cloud lies behind the viewport
            // edges, which Qt would clip only after transforming every one of them.
            m_scratch.resize(points.size());
            qsizetype kept = 0;
            for (qsizetype i = 0; i < points.size(); ++i) {
                QPointF at;
                if (!project(points[i], b, focal, at)) continue;
                if (std::abs(at.x()) > half_w + 2.0 || std::abs(at.y()) > half_h + 2.0) {
                    continue;
                }
                m_scratch[kept++] = at;
            }

            painter->setPen(QPen{colours[pass], pass == kFloor ? 1.0 : 2.0});
            painter->drawPoints(m_scratch.constData(), static_cast<int>(kept));
            m_drawn += static_cast<int>(kept);
        }

        drawCrosshair(painter);
    }

    /// A plane's vanishing line is straight whatever height the eye is at, so two distant
    /// points on z = 0 place the horizon; extending the line across the item avoids caring
    /// which way the view is turned.
    void drawHorizon(QPainter* painter, const Basis& b, double focal) {
        const double far = 1.0e5;
        const double yaw = m_yaw_deg * M_PI / 180.0;
        // Two directions in the plane, well to either side of straight ahead, so both stay
        // in front of the camera and well separated whatever the pitch.
        const Point3 left{static_cast<float>(m_eye.x + far * std::sin(yaw - 0.7)),
                          static_cast<float>(m_eye.y + far * std::cos(yaw - 0.7)), 0.0f};
        const Point3 right{static_cast<float>(m_eye.x + far * std::sin(yaw + 0.7)),
                           static_cast<float>(m_eye.y + far * std::cos(yaw + 0.7)), 0.0f};

        QPointF a, c;
        if (!project(left, b, focal, a) || !project(right, b, focal, c)) return;

        const QPointF d = c - a;
        const double len = std::hypot(d.x(), d.y());
        if (len < 1.0e-6) return;
        const QPointF unit{d.x() / len, d.y() / len};
        const double reach = width() + height();

        painter->setPen(QPen{QColor{54, 60, 70}, 1.0});
        painter->drawLine(a - unit * reach, a + unit * reach);
    }

    /// The same rings the bird view draws, on the sensor's own horizontal plane. In
    /// perspective they are the strongest depth cue available -- without them a cloud of
    /// points has no scale at all.
    void drawRangeRings(QPainter* painter, const Basis& b, double focal) {
        painter->setPen(QPen{QColor{40, 44, 52}, 1.0});
        const int segments = 180;

        for (int m = 2; m <= static_cast<int>(m_metres_across / 2); m += 2) {
            QPointF prev;
            bool have_prev = false;
            for (int i = 0; i <= segments; ++i) {
                const double t = 2.0 * M_PI * i / segments;
                const Point3 p{static_cast<float>(m * std::sin(t)),
                               static_cast<float>(m * std::cos(t)), 0.0f};
                QPointF at;
                const bool ok = project(p, b, focal, at);
                // Only join consecutive points that both projected: a segment straddling
                // the near plane would otherwise be drawn right across the viewport.
                if (ok && have_prev) painter->drawLine(prev, at);
                prev = at;
                have_prev = ok;
            }
        }
    }

    /// Where the view is pointing. Small, because it is an aiming aid rather than chrome.
    void drawCrosshair(QPainter* painter) {
        painter->setPen(QPen{QColor{90, 255, 160, 140}, 1.0});
        painter->drawLine(QPointF{-7, 0}, QPointF{-2, 0});
        painter->drawLine(QPointF{2, 0}, QPointF{7, 0});
        painter->drawLine(QPointF{0, -7}, QPointF{0, -2});
        painter->drawLine(QPointF{0, 2}, QPointF{0, 7});
    }

    void drawGrid(QPainter* painter, double scale) {
        painter->setPen(QPen{QColor{40, 44, 52}, 1.0});
        for (int m = 2; m <= static_cast<int>(m_metres_across / 2); m += 2) {
            const double r = m * scale;
            painter->drawEllipse(QPointF{0, 0}, r, r);
        }
        painter->drawLine(QPointF{-width(), 0}, QPointF{width(), 0});
        painter->drawLine(QPointF{0, -height()}, QPointF{0, height()});
    }

    std::array<QList<Point3>, kSurfaceCount> m_display{};
    std::array<QList<Point3>, kSurfaceCount> m_building{};
    QList<QPointF> m_scratch;
    double m_metres_across = 26.0;
    bool m_show_floor = true;
    int m_revolutions = 0;
    bool m_dirty = false;
    int m_drawn = 0;

    ViewMode m_mode = Bird;
    /// Horizontal field of view. 70 degrees reads as neither a fisheye nor a telescope.
    double m_fov_deg = 70.0;
    double m_yaw_deg = 0.0;
    double m_pitch_deg = kDefaultPitch;
    /// Beside the sensor, not at it, and this is the whole subtlety of the mode.
    ///
    /// A pinhole camera AT the scanner origin is degenerate. Screen radius comes out as
    /// focal * tan(angle between the point and the view axis), with range cancelling
    /// exactly -- and a scan holds one range per direction, so the image is the angular
    /// sampling lattice and nothing else: each channel a ring of evenly spaced points, the
    /// scene invisible. Range only becomes visible through parallax, which needs the eye
    /// somewhere the rangefinder is not.
    ///
    /// 9 m south and 2 m up, looking north over the sensor, puts a 26 m room in frame.
    static constexpr Point3 kDefaultEye{0.0f, -9.0f, 2.0f};
    static constexpr double kDefaultPitch = -8.0;

    /// The eye, in sensor-frame metres.
    Point3 m_eye = kDefaultEye;
};

/// Owns the subscription, decodes frames, and reports what it is seeing to QML.
class Sensor : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString model READ model NOTIFY statsChanged)
    Q_PROPERTY(int rpm READ rpm NOTIFY statsChanged)
    Q_PROPERTY(int framesPerSecond READ framesPerSecond NOTIFY statsChanged)
    Q_PROPERTY(int pointsPerSecond READ pointsPerSecond NOTIFY statsChanged)
    Q_PROPERTY(int revolutions READ revolutions NOTIFY statsChanged)
    Q_PROPERTY(int displayedPoints READ displayedPoints NOTIFY statsChanged)
    Q_PROPERTY(QString status READ status NOTIFY statsChanged)

public:
    explicit Sensor(QString topic, QObject* parent = nullptr)
        : QObject{parent},
          m_topic{std::move(topic)},
          m_calibration_topic{m_topic + QStringLiteral("/calibration")} {}

    void setView(LidarView* view) { m_view = view; }

    QString model() const { return m_model; }
    int rpm() const { return m_rpm; }
    int framesPerSecond() const { return m_frames_per_second; }
    int pointsPerSecond() const { return m_points_per_second; }
    int revolutions() const { return m_view ? m_view->revolutions() : 0; }
    int displayedPoints() const { return m_view ? m_view->displayedPoints() : 0; }
    QString status() const { return m_status; }

    bool start() {
        auto* node = qnnt::QnntNode::instance();
        connect(node, &qnnt::QnntNode::frameAvailable, this, &Sensor::onFrame);
        connect(node, &qnnt::QnntNode::publisherConnected, this,
                [this](const QString& topic, const QString& peer) {
                    m_status = QStringLiteral("connected to %1 at %2").arg(topic, peer);
                    Q_EMIT statsChanged();
                });
        connect(node, &qnnt::QnntNode::publisherDisconnected, this,
                [this](const QString& topic, const QString&) {
                    m_status = QStringLiteral("%1 went away, retrying").arg(topic);
                    Q_EMIT statsChanged();
                });

        node->configureFromEnvironment();
        // The queue must hold a second of packets, or a hitch in the GUI thread costs
        // frames. A Helios-32 sends 1500/s, twice the RS-LiDAR-16, so this is sized for
        // the faster of the two.
        node->reserveQueue(4096);
        if (!node->start()) return false;
        if (!node->addSubscriber(m_topic, qnnt::QnntNode::Delivery::Frames)) return false;
        // The angle table arrives on its own topic: it is 32 floats that change
        // approximately never, and putting it in every frame would be 192 KB/s of
        // unchanging data at the Helios rate.
        if (!node->addSubscriber(m_calibration_topic, qnnt::QnntNode::Delivery::Frames)) {
            return false;
        }
        m_status = QStringLiteral("waiting for %1").arg(m_topic);

        auto* ticker = new QTimer(this);
        connect(ticker, &QTimer::timeout, this, &Sensor::tick);
        ticker->start(1000);
        return true;
    }

private Q_SLOTS:
    void onFrame(const QString& topic, const QByteArray& frame) {
        if (topic == m_calibration_topic) {
            onCalibration(frame);
            return;
        }

        ++m_frames;
        // Nothing can be plotted without the angle table, and it arrives on its own topic:
        // dropping these few frames is better than inventing geometry for them.
        if (m_view == nullptr || !m_have_calibration) return;

        try {
            const told::Frame packet = told::decode(told::Bytes{
                reinterpret_cast<const std::uint8_t*>(frame.constData()),
                static_cast<std::size_t>(frame.size())});

            // Walked field by field rather than unpacked into a struct: the samples are a
            // buffer this reads in place, so there is nothing to copy and no allocation
            // per frame at 750 frames a second.
            for (const told::Field& field : packet.object()) {
                if (field.key == "model") {
                    if (m_model.isEmpty()) {
                        m_model = QString::fromUtf8(field.value.asString().data(),
                                                    static_cast<qsizetype>(
                                                        field.value.asString().size()));
                    }
                } else if (field.key == "rpm") {
                    m_rpm = static_cast<int>(field.value.asUint());
                } else if (field.key == "channels") {
                    m_channels = static_cast<int>(field.value.asUint());
                } else if (field.key == "firings_per_block") {
                    m_firings_per_block = static_cast<int>(field.value.asUint());
                } else if (field.key == "azimuth_step_cdeg") {
                    m_azimuth_step_cdeg = static_cast<int>(field.value.asUint());
                } else if (field.key == "blocks") {
                    for (const told::Frame& block : field.value.array()) {
                        decodeBlock(block);
                    }
                }
            }
        } catch (const told::Error& err) {
            ++m_malformed;
            if (m_malformed == 1) {
                std::printf("lidar-viewer: malformed frame: %s\n", err.what());
            }
        }
    }

    void tick() {
        m_frames_per_second = m_frames - m_frames_last;
        m_points_per_second = m_points - m_points_last;
        m_frames_last = m_frames;
        m_points_last = m_points;
        Q_EMIT statsChanged();

        // The drop count belongs in this line: at the Helios rate the GUI thread decodes
        // 576,000 points/s, and if it falls behind the queue sheds frames rather than
        // growing. Reporting frames/s without it would hide the loss.
        std::printf("lidar-viewer: %d frames/s, %d points/s, %d revolutions, %d displayed, "
                    "%llu dropped\n",
                    m_frames_per_second, m_points_per_second, revolutions(),
                    displayedPoints(),
                    static_cast<unsigned long long>(
                        qnnt::QnntNode::instance()->droppedCount()));
        std::fflush(stdout);
    }

private:
    void onCalibration(const QByteArray& frame) {
        try {
            const told::Frame packet = told::decode(told::Bytes{
                reinterpret_cast<const std::uint8_t*>(frame.constData()),
                static_cast<std::size_t>(frame.size())});

            for (const told::Field& field : packet.object()) {
                if (field.key == "model") {
                    const std::string_view text = field.value.asString();
                    m_model = QString::fromUtf8(text.data(),
                                                static_cast<qsizetype>(text.size()));
                } else if (field.key == "rpm") {
                    m_rpm = static_cast<int>(field.value.asUint());
                } else if (field.key == "channels") {
                    m_channels = static_cast<int>(field.value.asUint());
                } else if (field.key == "firings_per_block") {
                    m_firings_per_block = static_cast<int>(field.value.asUint());
                } else if (field.key == "azimuth_step_cdeg") {
                    m_azimuth_step_cdeg = static_cast<int>(field.value.asUint());
                } else if (field.key == "from_device") {
                    m_angles_from_device = field.value.asBool();
                } else if (field.key == "elevations_deg") {
                    int i = 0;
                    for (const told::Frame& angle : field.value.array()) {
                        if (i >= kMaxChannels) break;
                        m_elevations[static_cast<std::size_t>(i++)] =
                            static_cast<float>(angle.asFloat());
                    }
                } else if (field.key == "lens_offset_m") {
                    m_lens_offset_m = static_cast<double>(field.value.asFloat());
                } else if (field.key == "azimuth_offsets_deg") {
                    int i = 0;
                    for (const told::Frame& angle : field.value.array()) {
                        if (i >= kMaxChannels) break;
                        m_azimuth_offsets[static_cast<std::size_t>(i++)] =
                            static_cast<float>(angle.asFloat());
                    }
                }
            }

            if (m_channels > 0 && m_firings_per_block > 0) {
                const bool first = !m_have_calibration;
                m_have_calibration = true;
                if (first) {
                    std::printf("lidar-viewer: %s, %d channels, %d firing(s)/block, "
                                "angles %.2f..%.2f deg, %s\n",
                                qPrintable(m_model), m_channels, m_firings_per_block,
                                m_elevations[0],
                                m_elevations[static_cast<std::size_t>(m_channels - 1)],
                                m_angles_from_device ? "from the device"
                                                     : "from the driver's table");
                    std::fflush(stdout);
                }
                Q_EMIT statsChanged();
            }
        } catch (const told::Error&) {
            ++m_malformed;
        }
    }

    void decodeBlock(const told::Frame& block) {
        int azimuth_cdeg = -1;
        // 4 bytes of little-endian millimetres plus 1 of intensity. Named because the
        // length guard below and the reader further down must never disagree: a buffer at
        // the wrong stride still passes a too-small check and renders a plausible, wrong
        // cloud rather than failing.
        constexpr std::size_t kSampleStride = 5;
        told::Bytes samples{};

        for (const told::Field& field : block.object()) {
            if (field.key == "azimuth_cdeg") {
                azimuth_cdeg = static_cast<int>(field.value.asUint());
            } else if (field.key == "samples") {
                samples = field.value.asBuffer();
            }
        }
        const int samples_needed = m_channels * m_firings_per_block;
        if (azimuth_cdeg < 0 ||
            samples.size() < static_cast<std::size_t>(samples_needed) * kSampleStride) {
            return;
        }

        // A wrap in azimuth is the end of a revolution.
        if (azimuth_cdeg < m_last_azimuth_cdeg && m_view != nullptr) {
            m_view->completeRevolution();
        }
        m_last_azimuth_cdeg = azimuth_cdeg;

        for (int firing = 0; firing < m_firings_per_block; ++firing) {
            // With two firings per block the second half of the samples belongs to the
            // NEXT azimuth, not this one. With one firing they all share it. Getting this
            // wrong smears the cloud by a fifth of a degree and looks almost right.
            // Was hoisted out of the channel loop, which is only valid when every channel
            // in a firing shares an azimuth. A two-column sensor breaks that: each channel
            // carries its own horizontal correction, so the sin/cos move inside.
            const double firing_deg =
                (azimuth_cdeg + firing * m_azimuth_step_cdeg) / 100.0;

            // The lens sits off the rotation axis, so the ray starts here rather than at
            // the origin. At the BLOCK azimuth, without the per-channel correction: the
            // offset is where the mirror is aimed, not where each beam goes from there.
            const double block_azim = firing_deg * M_PI / 180.0;
            const double lens_x = m_lens_offset_m * std::sin(block_azim);
            const double lens_y = m_lens_offset_m * std::cos(block_azim);

            for (int ch = 0; ch < m_channels; ++ch) {
                const double azim =
                    (firing_deg + m_azimuth_offsets[static_cast<std::size_t>(ch)]) *
                    M_PI / 180.0;
                const double sin_a = std::sin(azim);
                const double cos_a = std::cos(azim);
                // The distance was 2 bytes until ranges past 65.535 m had to survive the
                // trip; see kSampleStride above.
                const std::size_t at =
                    static_cast<std::size_t>(firing * m_channels + ch) * kSampleStride;
                const std::uint32_t distance_mm =
                    static_cast<std::uint32_t>(samples[at]) |
                    (static_cast<std::uint32_t>(samples[at + 1]) << 8) |
                    (static_cast<std::uint32_t>(samples[at + 2]) << 16) |
                    (static_cast<std::uint32_t>(samples[at + 3]) << 24);
                const std::uint8_t intensity = samples[at + 4];

                ++m_points;
                // 0 is no return -- absorbed, out of range or sky. Plotting it would put a
                // false point at the sensor.
                if (distance_mm == 0) continue;

                const double r = distance_mm / 1000.0;
                const double elev = m_elevations[static_cast<std::size_t>(ch)] * M_PI / 180.0;
                const double horizontal = r * std::cos(elev);
                // z was computed and thrown away while the only view was top-down. The
                // first-person view needs it, and it costs one multiply per point.
                m_view->addPoint(static_cast<float>(horizontal * sin_a + lens_x),
                                 static_cast<float>(horizontal * cos_a + lens_y),
                                 static_cast<float>(r * std::sin(elev)), intensity);
            }
        }
    }

Q_SIGNALS:
    void statsChanged();

private:
    LidarView* m_view = nullptr;
    QString m_model;
    QString m_status;
    QString m_topic;
    QString m_calibration_topic;
    int m_rpm = 0;
    /// Geometry, taken from the stream rather than compiled in: an RS-LiDAR-16 sends 16
    /// channels in two firings per block, a Helios-32 sends 32 in one, and their angle
    /// tables are nothing alike.
    int m_channels = 0;
    int m_firings_per_block = 0;
    int m_azimuth_step_cdeg = 20;
    std::array<float, kMaxChannels> m_elevations{};
    /// Per-channel horizontal correction, degrees. Zero-initialised, so a publisher that
    /// does not send them behaves as before rather than skewing the cloud.
    std::array<float, kMaxChannels> m_azimuth_offsets{};
    /// Lens centre offset, metres, radial along the block azimuth. Zero until a calibration
    /// frame supplies it.
    double m_lens_offset_m = 0.0;
    bool m_have_calibration = false;
    bool m_angles_from_device = false;
    int m_last_azimuth_cdeg = 0;
    int m_frames = 0, m_frames_last = 0, m_frames_per_second = 0;
    int m_points = 0, m_points_last = 0, m_points_per_second = 0;
    int m_malformed = 0;
};

int main(int argc, char** argv) {
    QGuiApplication app(argc, argv);

    qmlRegisterType<LidarView>("Qnnt.Lidar", 1, 0, "LidarView");

    // Which sensor to view: the topic prefix, defaulting to the RS-LiDAR-16's.
    //   ./lidar-viewer                       -> lidar/rs16
    //   ./lidar-viewer '' lidar/helios32     -> the Helios, same binary
    //   ./lidar-viewer '' '' first-person    -> open in perspective rather than top-down
    const QString topic = argc > 2 ? QString::fromLocal8Bit(argv[2])
                                   : QString::fromLatin1(kDefaultTopic);
    Sensor sensor{topic};
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("sensor"), &sensor);

    // Loaded from the source tree rather than a resource, so the QML can be edited without
    // rebuilding. Run from the project root, or pass a path.
    const QString qml = (argc > 1 && argv[1][0] != '\0')
                            ? QString::fromLocal8Bit(argv[1])
                            : QStringLiteral("examples/lidar/main.qml");
    engine.load(QUrl::fromLocalFile(qml));
    if (engine.rootObjects().isEmpty()) {
        std::printf("lidar-viewer: could not load %s (run from the project root, or pass a "
                    "path to main.qml)\n",
                    qPrintable(qml));
        return 1;
    }

    // The QML instantiates the view; hand it to the decoder.
    auto* view = engine.rootObjects().first()->findChild<LidarView*>();
    if (view == nullptr) {
        std::printf("lidar-viewer: main.qml has no LidarView\n");
        return 1;
    }
    sensor.setView(view);

    if (argc > 3 && std::strncmp(argv[3], "first", 5) == 0) {
        view->setProperty("viewMode", LidarView::FirstPerson);
    }

    if (!sensor.start()) {
        std::printf("lidar-viewer: failed to start the qnnt node\n");
        return 1;
    }

    // Repaint at a display rate rather than per frame: 750 packets a second arrive, and
    // repainting a 28,800-point cloud that often would spend the whole GUI thread on paint.
    auto* repaint = new QTimer(&app);
    QObject::connect(repaint, &QTimer::timeout, [view] {
        if (view->dirty()) view->update();
    });
    repaint->start(33);

    // Optional lifetime, so the example can be run unattended: QNNT_LIDAR_SECONDS=n.
    if (const QByteArray limit = qgetenv("QNNT_LIDAR_SECONDS"); !limit.isEmpty()) {
        QTimer::singleShot(limit.toInt() * 1000, &app, &QCoreApplication::quit);
    }

    const int status = app.exec();
    qnnt::QnntNode::instance()->stop();
    return status;
}

#include "viewer.moc"
