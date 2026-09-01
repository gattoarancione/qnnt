// The Qt node of the five-language mesh. See SCHEMA.txt.
//
//   zig build mesh -Dqt=/path/to/Qt/6.10.3/macos && bash examples/mesh/run.sh
//
// Publishes mesh/qt and subscribes to the other four topics. Same schema as node.cpp, but
// declared with Qt types -- QString where that one has std::string, QList where it has
// std::vector, QByteArray where it has std::vector<uint8_t> -- which is the point: they
// produce and consume the same bytes, so a Qt program is a peer rather than a special case.
//
// Frames arrive as a signal on this object's thread, drained from the poll queue by the
// worker inside QnntNode.

#include "qnnt_qt.hpp"

#include <QCoreApplication>
#include <QHash>
#include <QTimer>
#include <QtGlobal>

#include <cmath>
#include <cstdio>

namespace {
constexpr const char* kMe = "qt";
constexpr auto kMyTopic = "mesh/qt";
constexpr int kIntervalMs = 200;
constexpr int kStartupDelayMs = 600;
} // namespace

enum class Mode : qint32 { idle = 0, running = 1, faulted = 2 };
TLD_ADD_ENUM(Mode)

struct Reading {
    quint8 channel{};
    double value{};
    bool valid{};
    TLD_DEFINE_MAP(channel, value, valid)
};

struct Origin {
    double x{};
    double y{};
    TLD_DEFINE_MAP(x, y)
};

struct Sample {
    quint64 seq{};
    QString source;
    Mode mode{Mode::idle};
    qint32 count{};
    float temp{};
    QByteArray blob;
    Origin origin;
    QList<Reading> readings;
    TLD_DEFINE_MAP(seq, source, mode, count, temp, blob, origin, readings)
};

static Sample expected(quint64 seq, const QString& source) {
    Sample s;
    s.seq = seq;
    s.source = source;
    s.mode = static_cast<Mode>(seq % 3);
    s.count = -static_cast<qint32>(seq);
    s.temp = 36.5f;
    s.blob = QByteArray::fromRawData("\x00\xFF\x0A", 3);
    s.origin = Origin{1.5, -2.5};
    for (quint8 i = 0; i < 3; ++i) {
        s.readings.append(Reading{static_cast<quint8>(i + 1),
                                  static_cast<double>(seq * 10 + i), i != 1});
    }
    return s;
}

struct PeerState {
    QString name;
    quint64 received = 0;
    quint64 first_seq = 0;
    quint64 last_seq = 0;
    quint64 problems = 0;
};

class MeshNode : public QObject
{
    Q_OBJECT

public:
    explicit MeshNode(QObject* parent = nullptr) : QObject{parent} {
        // topic -> peer name, so one slot serves every subscription.
        // run.sh sets MESH_PEERS to the languages it actually started, so the mesh works
        // with any subset rather than every node waiting for one that was never built.
        const QByteArray roster = qgetenv("MESH_PEERS");
        QStringList wanted;
        if (!roster.isEmpty()) {
            wanted = QString::fromUtf8(roster).split(QLatin1Char(','), Qt::SkipEmptyParts);
            for (QString& entry : wanted) entry = entry.trimmed();
        }

        const QHash<QString, QString> all{
            {QStringLiteral("mesh/zig"), QStringLiteral("zig")},
            {QStringLiteral("mesh/c"), QStringLiteral("c")},
            {QStringLiteral("mesh/cpp"), QStringLiteral("cpp")},
            {QStringLiteral("mesh/python"), QStringLiteral("python")},
        };
        for (auto it = all.cbegin(); it != all.cend(); ++it) {
            if (wanted.isEmpty() || wanted.contains(it.value())) {
                peers_.insert(it.key(), it.value());
            }
        }
        for (auto it = peers_.cbegin(); it != peers_.cend(); ++it) {
            states_.insert(it.value(), PeerState{it.value()});
        }
    }

    bool report(quint64 need) const {
        bool failed = false;
        for (auto it = states_.cbegin(); it != states_.cend(); ++it) {
            const PeerState& s = it.value();
            const bool ok = s.received >= need && s.problems == 0;
            failed = failed || !ok;
            std::printf("%s: from %-7s %3llu samples, seq %llu..%llu, %llu problem(s) %s\n",
                        kMe, qPrintable(s.name), (unsigned long long)s.received,
                        (unsigned long long)s.first_seq, (unsigned long long)s.last_seq,
                        (unsigned long long)s.problems, ok ? "ok" : "FAILED");
        }
        return failed;
    }

    const QHash<QString, QString>& peers() const { return peers_; }

public Q_SLOTS:
    void onFrame(const QString& topic, const QByteArray& frame) {
        const QString name = peers_.value(topic);
        if (name.isEmpty()) return;
        PeerState& peer = states_[name];

        bool bad = false;
        quint64 seq = 0;
        try {
            const Sample got = qnnt::QnntNode::unpacked<Sample>(frame);
            seq = got.seq;
            const Sample want = expected(seq, name);

            if (got.source != want.source || got.mode != want.mode) bad = true;
            if (got.count != want.count) bad = true;
            // temp crosses as a 32-bit float; the f64 fields survive exactly.
            if (std::fabs(got.temp - want.temp) > 1e-6f) bad = true;
            if (got.blob != want.blob) bad = true;
            if (got.origin.x != want.origin.x || got.origin.y != want.origin.y) bad = true;
            if (got.readings.size() != want.readings.size()) {
                bad = true;
            } else {
                for (qsizetype i = 0; i < got.readings.size(); ++i) {
                    if (got.readings[i].channel != want.readings[i].channel) bad = true;
                    if (got.readings[i].value != want.readings[i].value) bad = true;
                    if (got.readings[i].valid != want.readings[i].valid) bad = true;
                }
            }
        } catch (const qnnt::tld::Error&) {
            bad = true;
        }

        // A gap inside the run means loss; attaching late only sets the baseline.
        if (peer.last_seq != 0 && seq != peer.last_seq + 1) bad = true;
        if (peer.last_seq == 0) peer.first_seq = seq;
        peer.last_seq = seq;

        ++peer.received;
        if (bad) ++peer.problems;
    }

private:
    QHash<QString, QString> peers_;
    QHash<QString, PeerState> states_;
};

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const long run_ms = argc > 1 ? std::strtol(argv[1], nullptr, 10) : 9000;
    const unsigned long need = argc > 2 ? std::strtoul(argv[2], nullptr, 10) : 5;

    auto* node = qnnt::QnntNode::instance();
    MeshNode mesh;

    QObject::connect(node, &qnnt::QnntNode::frameAvailable, &mesh, &MeshNode::onFrame);
    QObject::connect(node, &qnnt::QnntNode::errorOccurred,
                     [](const QString& context, int status, const QString& name) {
                         std::printf("%s: error %s %d %s\n", kMe, qPrintable(context), status,
                                     qPrintable(name));
                     });

    node->configureFromEnvironment();
    if (!node->start()) return 1;
    if (!node->addPublisher(QString::fromLatin1(kMyTopic))) return 1;
    for (auto it = mesh.peers().cbegin(); it != mesh.peers().cend(); ++it) {
        if (!node->addSubscriber(it.key(), qnnt::QnntNode::Delivery::Frames)) return 1;
    }

    std::printf("%s: publishing %s, subscribed to %lld peers\n", kMe, kMyTopic,
                (long long)mesh.peers().size());
    std::fflush(stdout);

    auto seq = std::make_shared<quint64>(0);
    auto* timer = new QTimer(&app);
    QObject::connect(timer, &QTimer::timeout, [node, seq] {
        ++*seq;
        node->publishPacked(QString::fromLatin1(kMyTopic),
                            expected(*seq, QString::fromLatin1(kMe)));
    });
    // A peer cannot resolve this topic until it is registered and their next probe comes
    // round, and qnnt has no replay, so the first frames would otherwise go nowhere.
    QTimer::singleShot(kStartupDelayMs, [timer] { timer->start(kIntervalMs); });

    QTimer::singleShot(static_cast<int>(run_ms), &app, &QCoreApplication::quit);
    app.exec();

    timer->stop();
    node->stop();

    const bool failed = mesh.report(need);
    std::printf("%s: %s\n", kMe, failed ? "FAILED" : "all peers verified");
    std::fflush(stdout);
    return failed ? 1 : 0;
}

#include "node_qt.moc"
