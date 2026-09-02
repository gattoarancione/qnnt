// The display for the fake RS-LiDAR-16. See SCHEMA.txt.
//
// Everything expensive is in C++: LidarView is a QQuickPaintedItem that owns the point
// cloud, and `sensor` is a context property that decodes frames and exposes counters. QML
// does layout, chrome and controls, which is the division this example is arguing for.

import QtQuick
import QtQuick.Controls
import Qnnt.Lidar

Window {
    id: root
    width: 1000
    height: 720
    visible: true
    color: "#0d0f12"
    title: "qnnt — " + (sensor.model.length > 0 ? sensor.model : "waiting for a sensor")

    LidarView {
        id: cloud
        objectName: "cloud"
        anchors.fill: parent
        metresAcross: zoom.value
        showFloor: floorToggle.checked
    }

    // ---- overlay: what the stream is doing -------------------------------------------

    Rectangle {
        anchors { left: parent.left; top: parent.top; margins: 12 }
        width: 268
        height: stats.implicitHeight + 24
        radius: 6
        color: "#1a1d23"
        opacity: 0.92
        border { color: "#2b3038"; width: 1 }

        Column {
            id: stats
            anchors { fill: parent; margins: 12 }
            spacing: 3

            Text {
                text: sensor.model.length > 0 ? sensor.model : "no data yet"
                color: "#e6e9ef"
                font { pixelSize: 15; bold: true }
            }
            Text {
                text: sensor.rpm > 0 ? sensor.rpm + " rpm — " + (sensor.rpm / 60) + " rev/s"
                                     : "—"
                color: "#8b93a1"
                font.pixelSize: 12
            }
            Item { width: 1; height: 6 }

            Repeater {
                model: [
                    { k: "packets/s",   v: sensor.framesPerSecond },
                    { k: "points/s",    v: sensor.pointsPerSecond },
                    { k: "revolutions", v: sensor.revolutions },
                    { k: "points shown",v: sensor.displayedPoints }
                ]
                Row {
                    spacing: 8
                    Text {
                        text: modelData.k
                        color: "#8b93a1"
                        font.pixelSize: 12
                        width: 96
                    }
                    Text {
                        text: modelData.v.toLocaleString(Qt.locale("en_US"))
                        color: "#d7dce4"
                        font { pixelSize: 12; family: "Menlo" }
                    }
                }
            }

            Item { width: 1; height: 6 }
            Text {
                text: sensor.status
                color: sensor.framesPerSecond > 0 ? "#5ad18c" : "#d1a05a"
                font.pixelSize: 11
                width: 244
                wrapMode: Text.Wrap
            }
        }
    }

    // ---- legend: the intensity classes the sensor encodes -----------------------------

    Row {
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom
                  bottomMargin: 14 }
        spacing: 18

        Repeater {
            model: [
                { c: "#465060", t: "floor" },
                { c: "#78beff", t: "wall" },
                { c: "#ffc85a", t: "pillar" },
                { c: "#ff5a78", t: "moving box" }
            ]
            Row {
                spacing: 6
                Rectangle {
                    width: 9; height: 9; radius: 4.5; color: modelData.c
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text { text: modelData.t; color: "#8b93a1"; font.pixelSize: 11 }
            }
        }
    }

    // ---- controls ---------------------------------------------------------------------

    Row {
        anchors { right: parent.right; top: parent.top; margins: 12 }
        spacing: 12

        // The floor is most of the cloud; hiding it makes the walls and pillars read.
        //
        // A plain CheckBox with a separate label rather than a custom contentItem: the
        // native macOS style refuses contentItem customisation and warns about it, and a
        // demo should not open with a warning.
        Row {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter
            CheckBox {
                id: floorToggle
                checked: true
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: "floor returns"
                color: "#8b93a1"
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Column {
            spacing: 2
            Text {
                text: "view " + zoom.value.toFixed(0) + " m across"
                color: "#8b93a1"
                font.pixelSize: 11
            }
            Slider {
                id: zoom
                from: 6
                to: 60
                value: 26
                width: 150
            }
        }
    }

    Text {
        anchors { left: parent.left; bottom: parent.bottom; margins: 12 }
        text: "top-down view, rings every 2 m"
        color: "#5c6474"
        font.pixelSize: 11
    }
}
