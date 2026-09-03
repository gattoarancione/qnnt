// A Qt/QML viewer for the fake RS-LiDAR-16 in sensor.zig. See SCHEMA.txt.
//
//   zig build lidar -Dqt=/path/to/Qt/6.10.3/macos
//   ./zig-out/bin/lidar-sensor          # terminal 1
//   ./zig-out/bin/lidar-viewer          # terminal 2, from the project root
//
// The split this demonstrates: the sensor is a Zig node, the display is QML, and neither
// knows the other's language -- only the topic and the TLD schema.
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
#include <vector>

namespace {
/// Default topic; override with an argument to view a different sensor.
constexpr auto kDefaultTopic = "lidar/rs16";

constexpr int kMaxChannels = 32;

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

/// The rendered item: a top-down view of the last completed revolution.
class LidarView : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(double metresAcross MEMBER m_metres_across NOTIFY viewChanged)
    Q_PROPERTY(bool showFloor MEMBER m_show_floor NOTIFY viewChanged)

public:
    explicit LidarView(QQuickItem* parent = nullptr) : QQuickPaintedItem{parent} {
        setFillColor(QColor{16, 18, 22});
        for (auto& pass : m_display) pass.reserve(16000);
        for (auto& pass : m_building) pass.reserve(16000);
    }

    /// Called from the decoder for every returned sample of the revolution in progress.
    void addPoint(float x, float y, std::uint8_t intensity) {
        m_building[classify(intensity)].append(QPointF{x, y});
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
        painter->setRenderHint(QPainter::Antialiasing, false);

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
            // the zoom, and rescaling 28,800 points is cheaper than the paint itself.
            QVarLengthArray<QPointF, 1> unused;
            Q_UNUSED(unused);
            m_scratch.resize(points.size());
            for (qsizetype i = 0; i < points.size(); ++i) {
                m_scratch[i] = QPointF{points[i].x() * scale, -points[i].y() * scale};
            }

            painter->setPen(QPen{colours[pass], pass == kFloor ? 1.0 : 2.0});
            painter->drawPoints(m_scratch.constData(), static_cast<int>(m_scratch.size()));
        }

        // The sensor itself.
        painter->setPen(Qt::NoPen);
        painter->setBrush(QColor{90, 255, 160});
        painter->drawEllipse(QPointF{0, 0}, 4, 4);
    }

    int revolutions() const { return m_revolutions; }
    bool dirty() const { return m_dirty; }

    int displayedPoints() const {
        int total = 0;
        for (const auto& pass : m_display) total += static_cast<int>(pass.size());
        return total;
    }

Q_SIGNALS:
    void viewChanged();

private:
    void drawGrid(QPainter* painter, double scale) {
        painter->setPen(QPen{QColor{40, 44, 52}, 1.0});
        for (int m = 2; m <= static_cast<int>(m_metres_across / 2); m += 2) {
            const double r = m * scale;
            painter->drawEllipse(QPointF{0, 0}, r, r);
        }
        painter->drawLine(QPointF{-width(), 0}, QPointF{width(), 0});
        painter->drawLine(QPointF{0, -height()}, QPointF{0, height()});
    }

    std::array<QList<QPointF>, kSurfaceCount> m_display{};
    std::array<QList<QPointF>, kSurfaceCount> m_building{};
    QList<QPointF> m_scratch;
    double m_metres_across = 26.0;
    bool m_show_floor = true;
    int m_revolutions = 0;
    bool m_dirty = false;
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
            const qnnt::tld::Frame packet = qnnt::tld::decode(qnnt::tld::Bytes{
                reinterpret_cast<const std::uint8_t*>(frame.constData()),
                static_cast<std::size_t>(frame.size())});

            // Walked field by field rather than unpacked into a struct: the samples are a
            // buffer this reads in place, so there is nothing to copy and no allocation
            // per frame at 750 frames a second.
            for (const qnnt::tld::Field& field : packet.object()) {
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
                    for (const qnnt::tld::Frame& block : field.value.array()) {
                        decodeBlock(block);
                    }
                }
            }
        } catch (const qnnt::tld::Error& err) {
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
            const qnnt::tld::Frame packet = qnnt::tld::decode(qnnt::tld::Bytes{
                reinterpret_cast<const std::uint8_t*>(frame.constData()),
                static_cast<std::size_t>(frame.size())});

            for (const qnnt::tld::Field& field : packet.object()) {
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
                    for (const qnnt::tld::Frame& angle : field.value.array()) {
                        if (i >= kMaxChannels) break;
                        m_elevations[static_cast<std::size_t>(i++)] =
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
        } catch (const qnnt::tld::Error&) {
            ++m_malformed;
        }
    }

    void decodeBlock(const qnnt::tld::Frame& block) {
        int azimuth_cdeg = -1;
        qnnt::tld::Bytes samples{};

        for (const qnnt::tld::Field& field : block.object()) {
            if (field.key == "azimuth_cdeg") {
                azimuth_cdeg = static_cast<int>(field.value.asUint());
            } else if (field.key == "samples") {
                samples = field.value.asBuffer();
            }
        }
        const int samples_needed = m_channels * m_firings_per_block;
        if (azimuth_cdeg < 0 || samples.size() < static_cast<std::size_t>(samples_needed) * 3) {
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
            const double azim =
                (azimuth_cdeg + firing * m_azimuth_step_cdeg) * M_PI / 18000.0;
            const double sin_a = std::sin(azim);
            const double cos_a = std::cos(azim);

            for (int ch = 0; ch < m_channels; ++ch) {
                const std::size_t at = static_cast<std::size_t>(firing * m_channels + ch) * 3;
                const std::uint16_t distance_mm =
                    static_cast<std::uint16_t>(samples[at] | (samples[at + 1] << 8));
                const std::uint8_t intensity = samples[at + 2];

                ++m_points;
                // 0 is no return -- absorbed, out of range or sky. Plotting it would put a
                // false point at the sensor.
                if (distance_mm == 0) continue;

                const double r = distance_mm / 1000.0;
                const double elev = m_elevations[static_cast<std::size_t>(ch)] * M_PI / 180.0;
                const double horizontal = r * std::cos(elev);
                m_view->addPoint(static_cast<float>(horizontal * sin_a),
                                 static_cast<float>(horizontal * cos_a), intensity);
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
