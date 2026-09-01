// Drives the proposed Qt interface in include/qnnt_qt.hpp end to end: configure, start,
// publish, receive through signals on the Qt thread, unpack a struct carrying QString and
// QList members, stop.
//
//   zig build qt-demo -Dqt=/path/to/Qt/6.10.3/macos
//
// Qt is not a dependency of qnnt, so this step only exists when -Dqt points at a kit. It
// was developed against Qt 6.10.3 on macOS.
#include "qnnt_qt.hpp"

#include <QCoreApplication>
#include <QTimer>
#include <QDebug>

struct Telemetry {
    QString name;
    QList<double> samples;
    QByteArray blob;
    int mode{};
    TLD_DEFINE_MAP(name, samples, blob, mode)
};

class Probe : public QObject {
    Q_OBJECT
public:
    int text_seen = 0;
    int frames_seen = 0;
    bool struct_ok = false;

public Q_SLOTS:
    void onMessage(const QString& topic, const QByteArray& data) {
        ++text_seen;
        if (text_seen == 1) qInfo() << "  text message on" << topic << ":" << data.trimmed();
    }
    void onFrame(const QString& topic, const QByteArray& frame) {
        ++frames_seen;
        const Telemetry t = qnnt::QnntNode::unpacked<Telemetry>(frame);
        if (t.name == "probe" && t.samples.size() == 3 && t.samples[2] == 3.5
            && t.blob == QByteArray::fromRawData("\x00\xFF\x0A", 3) && t.mode == 2) {
            struct_ok = true;
        }
        if (frames_seen == 1) {
            qInfo() << "  frame on" << topic << ": name" << t.name
                    << "samples" << t.samples.size() << "mode" << t.mode;
        }
    }
    void onError(const QString& context, int status, const QString& name) {
        qWarning() << "  ERROR" << context << status << name;
    }
};

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);

    auto* node = qnnt::QnntNode::instance();
    Probe probe;
    QObject::connect(node, &qnnt::QnntNode::messageAvailable, &probe, &Probe::onMessage);
    QObject::connect(node, &qnnt::QnntNode::frameAvailable, &probe, &Probe::onFrame);
    QObject::connect(node, &qnnt::QnntNode::errorOccurred, &probe, &Probe::onError);

    node->setRegistryPort(22450);
    if (!node->start()) {
        qCritical() << "start failed";
        return 1;
    }
    qInfo() << "  started, node" << node->nodeId()
            << "registry" << node->registryPort()
            << "advertise" << node->advertiseAddress()
            << "federation" << node->federationEnabled();

    node->addPublisher("qt/text");
    node->addPublisher("qt/frames");
    node->addSubscriber("qt/text", qnnt::QnntNode::Delivery::Text);
    node->addSubscriber("qt/frames", qnnt::QnntNode::Delivery::Frames);

    Telemetry sample;
    sample.name = "probe";
    sample.samples = {1.0, 2.25, 3.5};
    sample.blob = QByteArray::fromRawData("\x00\xFF\x0A", 3);
    sample.mode = 2;

    // Give the subscriptions a moment to resolve through the registry, then publish.
    QTimer::singleShot(700, [&] {
        for (int i = 0; i < 5; ++i) {
            node->publish("qt/text", QByteArray("hello from Qt\n"));
            node->publishPacked("qt/frames", sample);
        }
    });

    QTimer::singleShot(2200, [&] {
        qInfo() << "  received" << probe.text_seen << "text and" << probe.frames_seen
                << "frames; dropped" << node->droppedCount();
        const bool ok = probe.text_seen >= 5 && probe.frames_seen >= 5 && probe.struct_ok;
        qInfo() << (ok ? "  all Qt interface checks passed" : "  FAILED");
        node->stop();
        app.exit(ok ? 0 : 1);
    });

    return app.exec();
}

#include "qt_demo.moc"
