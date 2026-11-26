// A Qt/QML viewer for the depth camera chain. See SCHEMA.txt.
//
//   zig build zed -Dqt=/path/to/Qt/6.10.3/macos
//   ./zig-out/bin/fake-zed              # terminal 1
//   ./zig-out/bin/camera-sensor          # terminal 2
//   ./zig-out/bin/camera-viewer          # terminal 3, from the project root
//
// The same split the LiDAR viewer demonstrates: the camera is a Zig node, the display is
// QML, and neither knows the other's language -- only the topic and the TOLD schema. It
// subscribes to camera/zedx/depth and camera/zedx/calibration and knows nothing about ZED
// X, GMSL2 or the ZED SDK; a different depth camera with its own driver would show up here
// unchanged.
//
// Two images per frame: the mono view as it arrives, and depth colourised. Decoding is a
// pair of memcpy-shaped loops over 64,000 pixels at 15 Hz, which is nothing; the work that
// would matter at full resolution is discussed in SCHEMA.txt.

#include "qnnt_qt.hpp"

#include <QColor>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickPaintedItem>
#include <QTimer>
#include <QUrl>
#include <QtQml/qqml.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>
#include <cstdio>
#include <cstring>

namespace {
constexpr auto kDefaultTopic = "camera/zedx";

/// The largest geometry this will accept, matching the driver's own ceiling in frame.zig
/// (a ZED 2i's 2K mode). It is a sanity bound on a number that arrives over the network,
/// not a buffer size -- the buffers below are sized from the frame.
///
/// It was 640x400 and fixed, which was true when the chain only ever published 320x200 and
/// became wrong the moment the bridge grew --scale. At scale 2 a 960x540 frame wrote twice
/// past the end of a fixed member array and corrupted the object holding it; at scale 1,
/// eight times past. The lesson is not the number, it is that a decode buffer must be sized
/// from the frame it decodes and never from what the sender happened to send last month.
constexpr int kMaxWidth = 2208;
constexpr int kMaxHeight = 1242;

/// A blue-to-red ramp over the depth range, built once. Not a perceptually uniform map --
/// that is a bigger discussion than this example needs -- but monotonic in hue, so nearer
/// really does read as a different colour rather than merely a different brightness.
struct DepthRamp {
    std::array<QRgb, 256> table{};

    DepthRamp() {
        for (int i = 0; i < 256; ++i) {
            const double t = i / 255.0;
            // Blue (near) -> cyan -> green -> yellow -> red (far).
            const double r = std::clamp(1.5 - std::abs(4.0 * t - 3.0), 0.0, 1.0);
            const double g = std::clamp(1.5 - std::abs(4.0 * t - 2.0), 0.0, 1.0);
            const double b = std::clamp(1.5 - std::abs(4.0 * t - 1.0), 0.0, 1.0);
            table[static_cast<std::size_t>(i)] =
                qRgb(static_cast<int>(r * 255), static_cast<int>(g * 255),
                     static_cast<int>(b * 255));
        }
    }
};
const DepthRamp kRamp{};
} // namespace

/// The rendered item: the last frame, as a mono image and a colourised depth image.
class CameraView : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(int layout MEMBER m_layout NOTIFY viewChanged)
    Q_PROPERTY(bool markHoles MEMBER m_mark_holes NOTIFY viewChanged)

public:
    /// Which images to show. Side by side is the default because the pair is the point:
    /// depth without the image it came from is hard to read, and a hole in the depth is
    /// only interesting next to what was there.
    enum Layout { SideBySide, DepthOnly, MonoOnly };
    Q_ENUM(Layout)

    explicit CameraView(QQuickItem* parent = nullptr) : QQuickPaintedItem{parent} {
        setFillColor(QColor{16, 18, 22});
    }

    /// Called from the decoder with one frame's planes. Both images are rebuilt here rather
    /// than in paint(), because a frame arrives 15 times a second and the window repaints
    /// 60: doing it per paint would be four times the work for the same picture.
    void setFrame(int w, int h, const std::uint16_t* depth_mm, const std::uint8_t* mono,
                  std::uint16_t depth_min, std::uint16_t depth_max) {
        if (w <= 0 || h <= 0 || w > kMaxWidth || h > kMaxHeight) return;
        // The QImages are rebuilt whenever the geometry changes, so nothing here assumes a
        // size -- but the guard above still matters: it is the only thing standing between a
        // hostile width and a QImage allocation sized from it.

        if (m_mono.width() != w || m_mono.height() != h) {
            m_mono = QImage{w, h, QImage::Format_Grayscale8};
            m_depth = QImage{w, h, QImage::Format_RGB32};
        }

        const double span = (depth_max > depth_min)
                                ? static_cast<double>(depth_max - depth_min)
                                : 1.0;

        for (int y = 0; y < h; ++y) {
            auto* mono_row = m_mono.scanLine(y);
            auto* depth_row = reinterpret_cast<QRgb*>(m_depth.scanLine(y));
            const std::size_t at = static_cast<std::size_t>(y) * static_cast<std::size_t>(w);

            for (int x = 0; x < w; ++x) {
                mono_row[x] = mono[at + static_cast<std::size_t>(x)];

                const std::uint16_t mm = depth_mm[at + static_cast<std::size_t>(x)];
                if (mm == 0) {
                    // No depth here. Left black, or flagged: a stereo camera has no depth
                    // over a good fraction of every frame, and mistaking that for "near"
                    // would paint the holes the brightest thing on screen.
                    depth_row[x] = m_mark_holes ? qRgb(60, 20, 30) : qRgb(0, 0, 0);
                    continue;
                }
                const double t = (static_cast<double>(mm) - depth_min) / span;
                const int idx = std::clamp(static_cast<int>(t * 255.0), 0, 255);
                depth_row[x] = kRamp.table[static_cast<std::size_t>(idx)];
            }
        }

        m_dirty = true;
    }

    void paint(QPainter* painter) override {
        m_dirty = false;
        if (m_mono.isNull()) return;

        painter->setRenderHint(QPainter::SmoothPixmapTransform, false);

        switch (m_layout) {
        case DepthOnly:
            drawFitted(painter, m_depth, QRectF{0, 0, width(), height()});
            break;
        case MonoOnly:
            drawFitted(painter, m_mono, QRectF{0, 0, width(), height()});
            break;
        case SideBySide:
        default: {
            const double half = width() / 2.0;
            drawFitted(painter, m_mono, QRectF{0, 0, half, height()});
            drawFitted(painter, m_depth, QRectF{half, 0, half, height()});
            painter->setPen(QPen{QColor{40, 44, 52}, 1.0});
            painter->drawLine(QPointF{half, 0}, QPointF{half, height()});
            break;
        }
        }
    }

    bool dirty() const { return m_dirty; }

Q_SIGNALS:
    void viewChanged();

private:
    /// Letterboxed rather than stretched: a depth map at the wrong aspect ratio is a
    /// misleading picture, not merely an ugly one.
    static void drawFitted(QPainter* painter, const QImage& img, const QRectF& box) {
        if (img.isNull() || box.width() <= 0 || box.height() <= 0) return;

        const double scale = std::min(box.width() / img.width(), box.height() / img.height());
        const double w = img.width() * scale;
        const double h = img.height() * scale;
        painter->drawImage(
            QRectF{box.x() + (box.width() - w) / 2.0, box.y() + (box.height() - h) / 2.0, w, h},
            img);
    }

    QImage m_mono;
    QImage m_depth;
    int m_layout = SideBySide;
    bool m_mark_holes = true;
    bool m_dirty = false;
};

/// Owns the subscriptions, decodes frames, and reports what it is seeing to QML.
class Camera : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString model READ model NOTIFY statsChanged)
    Q_PROPERTY(QString geometry READ geometry NOTIFY statsChanged)
    Q_PROPERTY(int framesPerSecond READ framesPerSecond NOTIFY statsChanged)
    Q_PROPERTY(int framesMissed READ framesMissed NOTIFY statsChanged)
    Q_PROPERTY(int holePercent READ holePercent NOTIFY statsChanged)
    Q_PROPERTY(QString calibration READ calibration NOTIFY statsChanged)
    Q_PROPERTY(QString status READ status NOTIFY statsChanged)

public:
    explicit Camera(QString prefix, QObject* parent = nullptr)
        : QObject{parent},
          m_depth_topic{prefix + QStringLiteral("/depth")},
          m_calib_topic{prefix + QStringLiteral("/calibration")} {}

    void setView(CameraView* view) { m_view = view; }

    bool start() {
        auto* node = qnnt::QnntNode::instance();
        connect(node, &qnnt::QnntNode::frameAvailable, this, &Camera::onFrame);
        connect(node, &qnnt::QnntNode::subscriberDisconnected, this,
                [this](const QString& topic, const QString&) {
                    m_status = QStringLiteral("%1 went away, retrying").arg(topic);
                    Q_EMIT statsChanged();
                });

        // Every QNNT_* variable, handled by the library so all four languages agree -- and
        // without this the viewer silently ignores the lot, including the cluster key. It
        // was missing here while the LiDAR viewer and the Qt mesh node both had it, so this
        // viewer could not join a federation at all: it reported "federation disabled: no
        // cluster key" with the key plainly set in its environment.
        node->configureFromEnvironment();

        if (!node->start()) return false;
        if (!node->addSubscriber(m_depth_topic, qnnt::QnntNode::Delivery::Frames)) return false;
        // The intrinsics arrive on their own topic and are republished about once a second,
        // so starting this viewer after the bridge is fine -- which is the whole reason the
        // bridge republishes rather than announcing once.
        if (!node->addSubscriber(m_calib_topic, qnnt::QnntNode::Delivery::Frames)) return false;

        m_status = QStringLiteral("waiting for %1").arg(m_depth_topic);

        auto* timer = new QTimer{this};
        connect(timer, &QTimer::timeout, this, &Camera::tick);
        timer->start(1000);

        auto* repaint = new QTimer{this};
        connect(repaint, &QTimer::timeout, this, [this] {
            if (m_view != nullptr && m_view->dirty()) m_view->update();
        });
        repaint->start(33);
        return true;
    }

    QString model() const { return m_model; }
    QString geometry() const { return m_geometry; }
    int framesPerSecond() const { return m_fps; }
    int framesMissed() const { return m_missed; }
    int holePercent() const { return m_hole_percent; }
    QString calibration() const { return m_calibration; }
    QString status() const { return m_status; }

Q_SIGNALS:
    void statsChanged();

private Q_SLOTS:
    void tick() {
        m_fps = m_frames - m_last_frames;
        m_last_frames = m_frames;
        if (m_fps > 0) {
            m_status = m_have_calibration
                           ? QStringLiteral("streaming")
                           : QStringLiteral("streaming, no calibration yet");
            // Printed as well as shown, so a headless run is verifiable from its log --
            // the same reason lidar-viewer reports.
            std::printf("camera-viewer: %d frames/s, %s, %d%% without depth, %d missed\n",
                        m_fps, qPrintable(m_geometry), m_hole_percent, m_missed);
            std::fflush(stdout);
        }
        Q_EMIT statsChanged();
    }

private:
    void onFrame(const QString& topic, const QByteArray& payload) {
        if (topic == m_calib_topic) {
            readCalibration(payload);
            return;
        }
        if (topic != m_depth_topic) return;

        // Nothing can be scaled without the depth range, and it arrives on its own topic.
        // Waiting is right: a frame drawn against a guessed range is a picture of nothing.
        if (!m_have_calibration) return;

        const told::Frame frame = told::decode(told::Bytes{
            reinterpret_cast<const std::uint8_t*>(payload.constData()),
            static_cast<std::size_t>(payload.size())});

        int w = 0;
        int h = 0;
        int missed = 0;
        told::Bytes depth{};
        told::Bytes mono{};

        for (const told::Field& field : frame.object()) {
            if (field.key == "width") {
                w = static_cast<int>(field.value.asUint());
            } else if (field.key == "height") {
                h = static_cast<int>(field.value.asUint());
            } else if (field.key == "missed") {
                // Frames the bridge never saw, because the camera does not wait. Shared
                // memory cannot deliver part of a frame, so this replaced a rows-missing
                // count that only meant anything over a lossy transport.
                missed = static_cast<int>(field.value.asUint());
            } else if (field.key == "depth") {
                depth = field.value.asBuffer();
            } else if (field.key == "mono") {
                mono = field.value.asBuffer();
            } else if (field.key == "model") {
                m_model = QString::fromUtf8(field.value.asString().data(),
                                            static_cast<qsizetype>(field.value.asString().size()));
            }
        }

        const std::size_t pixels = static_cast<std::size_t>(w) * static_cast<std::size_t>(h);

        // Every one of these is load-bearing. The geometry arrives in the frame, so it is
        // the sender's number and not this program's: it bounds the allocation below, and
        // the buffer lengths have to agree with it before a single byte is read.
        if (w <= 0 || h <= 0 || w > kMaxWidth || h > kMaxHeight) return;
        if (depth.size() < pixels * 2 || mono.size() < pixels) return;

        // Sized from the frame, not from a constant. This used to be a fixed member array
        // holding 640x400, and anything larger wrote past it -- which is what made
        // --scale 2 a certain crash and --scale 3 a marginal one.
        if (m_depth_scratch.size() < pixels) m_depth_scratch.resize(pixels);

        // Little-endian u16 out of the buffer. Copied into a typed scratch array rather
        // than reinterpret_cast over the payload: the buffer's alignment is whatever the
        // frame gave it, and a u16 read at an odd offset is undefined behaviour on the
        // architectures that care.
        for (std::size_t i = 0; i < pixels; ++i) {
            m_depth_scratch[i] = static_cast<std::uint16_t>(
                static_cast<std::uint16_t>(depth[i * 2]) |
                (static_cast<std::uint16_t>(depth[i * 2 + 1]) << 8));
        }

        std::size_t holes = 0;
        for (std::size_t i = 0; i < pixels; ++i) {
            if (m_depth_scratch[i] == 0) ++holes;
        }

        ++m_frames;
        m_missed = missed;
        m_hole_percent = static_cast<int>(holes * 100 / (pixels == 0 ? 1 : pixels));
        m_geometry = QStringLiteral("%1x%2").arg(w).arg(h);

        if (m_view != nullptr) {
            m_view->setFrame(w, h, m_depth_scratch.data(),
                             reinterpret_cast<const std::uint8_t*>(mono.data()), m_depth_min,
                             m_depth_max);
        }
    }

    void readCalibration(const QByteArray& payload) {
        const told::Frame frame = told::decode(told::Bytes{
            reinterpret_cast<const std::uint8_t*>(payload.constData()),
            static_cast<std::size_t>(payload.size())});

        double fx = 0;
        double fy = 0;
        double baseline = 0;
        bool from_device = false;

        for (const told::Field& field : frame.object()) {
            if (field.key == "fx") {
                fx = field.value.asFloat();
            } else if (field.key == "fy") {
                fy = field.value.asFloat();
            } else if (field.key == "baseline_mm") {
                baseline = field.value.asFloat();
            } else if (field.key == "depth_min_mm") {
                m_depth_min = static_cast<std::uint16_t>(field.value.asUint());
            } else if (field.key == "depth_max_mm") {
                m_depth_max = static_cast<std::uint16_t>(field.value.asUint());
            } else if (field.key == "from_device") {
                from_device = field.value.asBool();
            }
        }

        if (m_depth_max <= m_depth_min) return; // unusable: leave the previous range alone

        // Said plainly, because it is the difference between a metric cloud and a
        // plausible-looking one: nominal intrinsics are not this unit's.
        m_calibration = QStringLiteral("fx %1  fy %2  baseline %3 mm  %4")
                            .arg(fx, 0, 'f', 1)
                            .arg(fy, 0, 'f', 1)
                            .arg(baseline, 0, 'f', 1)
                            .arg(from_device ? QStringLiteral("from the camera")
                                             : QStringLiteral("DRIVER DEFAULTS"));

        if (!m_have_calibration) {
            std::printf("camera-viewer: depth range %u..%u mm, %s\n", m_depth_min, m_depth_max,
                        from_device ? "calibration from the camera"
                                    : "driver defaults (nominal, not this unit)");
            std::fflush(stdout);
        }
        m_have_calibration = true;
        Q_EMIT statsChanged();
    }

    CameraView* m_view = nullptr;
    QString m_depth_topic;
    QString m_calib_topic;
    QString m_model;
    QString m_geometry;
    QString m_calibration;
    QString m_status;

    /// Grown to fit whatever geometry arrives, and never shrunk: a stream that alternates
    /// between two sizes should not reallocate every frame.
    std::vector<std::uint16_t> m_depth_scratch;
    std::uint16_t m_depth_min = 0;
    std::uint16_t m_depth_max = 0;
    bool m_have_calibration = false;

    int m_frames = 0;
    int m_last_frames = 0;
    int m_fps = 0;
    int m_missed = 0;
    int m_hole_percent = 0;
};

#include "viewer.moc"

int main(int argc, char** argv) {
    QGuiApplication app(argc, argv);

    qmlRegisterType<CameraView>("Qnnt.Camera", 1, 0, "CameraView");

    //   ./camera-viewer                        -> camera/zedx
    //   ./camera-viewer '' camera/other        -> a different camera, same binary
    const QString prefix = argc > 2 ? QString::fromLocal8Bit(argv[2])
                                    : QString::fromLatin1(kDefaultTopic);
    Camera camera{prefix};

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("camera"), &camera);

    const QString qml = (argc > 1 && argv[1][0] != '\0')
                            ? QString::fromLocal8Bit(argv[1])
                            : QStringLiteral("examples/zed/main.qml");
    engine.load(QUrl::fromLocalFile(qml));
    if (engine.rootObjects().isEmpty()) {
        std::printf("camera-viewer: could not load %s (run from the project root, or pass a "
                    "path to main.qml)\n",
                    qPrintable(qml));
        return 1;
    }

    auto* view = engine.rootObjects().first()->findChild<CameraView*>();
    if (view == nullptr) {
        std::printf("camera-viewer: main.qml has no CameraView\n");
        return 1;
    }
    camera.setView(view);

    if (!camera.start()) {
        std::printf("camera-viewer: could not subscribe -- is a registry running?\n");
        return 1;
    }

    return app.exec();
}
