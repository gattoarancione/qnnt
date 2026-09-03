// The display for the RS-LiDAR-16 and the Helios-32. See SCHEMA.txt.
//
// Two views of the same cloud: top-down, and first person from the sensor's position. QML
// owns the controls and the input -- drag, WASD, wheel, V, R -- and calls into LidarView,
// which owns the cloud and both projections.
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

    readonly property bool firstPerson: cloud.viewMode === LidarView.FirstPerson

    LidarView {
        id: cloud
        objectName: "cloud"
        anchors.fill: parent
        metresAcross: zoom.value
        showFloor: floorToggle.checked
        fovDeg: fov.value
    }

    // ---- looking around --------------------------------------------------------------
    //
    // Declared before the overlays and controls, so those get the mouse first and this only
    // sees drags on the cloud itself. Inert in the bird view, which has nothing to aim.

    MouseArea {
        anchors.fill: parent
        enabled: root.firstPerson
        cursorShape: root.firstPerson ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                                      : Qt.ArrowCursor
        property real lastX: 0
        property real lastY: 0

        onPressed: (mouse) => {
            lastX = mouse.x;
            lastY = mouse.y;
            keys.forceActiveFocus(); // a click on a slider takes focus; take it back
        }
        onPositionChanged: (mouse) => {
            if (!pressed) return;
            // A quarter degree per pixel: a full turn is roughly a screen and a half of
            // drag, which is about right for a trackpad.
            cloud.look((mouse.x - lastX) * 0.25, -(mouse.y - lastY) * 0.25);
            lastX = mouse.x;
            lastY = mouse.y;
        }
        onWheel: (wheel) => {
            // Field of view, which is what zoom means for a perspective camera. Only bound
            // in first person, since this MouseArea is disabled in the bird view.
            const step = wheel.angleDelta.y > 0 ? -1 : 1;
            fov.value = Math.max(fov.from, Math.min(fov.to, fov.value + step * 4));
        }
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onPressed: (event) => {
            const stride = 0.5; // metres per press, and auto-repeat carries a held key
            switch (event.key) {
            case Qt.Key_W: case Qt.Key_Up:    cloud.moveBy(stride, 0, 0); break;
            case Qt.Key_S: case Qt.Key_Down:  cloud.moveBy(-stride, 0, 0); break;
            case Qt.Key_A:                    cloud.moveBy(0, -stride, 0); break;
            case Qt.Key_D:                    cloud.moveBy(0, stride, 0); break;
            case Qt.Key_E:                    cloud.moveBy(0, 0, stride); break;
            case Qt.Key_Q:                    cloud.moveBy(0, 0, -stride); break;
            case Qt.Key_Left:                 cloud.look(-3, 0); break;
            case Qt.Key_Right:                cloud.look(3, 0); break;
            case Qt.Key_R:                    cloud.resetView(); break;
            case Qt.Key_V:
                cloud.viewMode = root.firstPerson ? LidarView.Bird : LidarView.FirstPerson;
                break;
            default: return;
            }
            event.accepted = true;
        }
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

    // A camera sitting on the rangefinder sees one range per direction, so the picture is
    // the sampling lattice rather than the room. It reads as a broken projection, so say so
    // rather than letting it be rediscovered as a bug.
    Rectangle {
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 14 }
        visible: root.firstPerson && cloud.atOrigin
        width: warning.implicitWidth + 20
        height: warning.implicitHeight + 12
        radius: 4
        color: "#3a2a18"
        border { color: "#7a5a2a"; width: 1 }

        Text {
            id: warning
            anchors.centerIn: parent
            text: "at the sensor itself — no parallax here, so range is invisible. R to step back."
            color: "#e0b070"
            font.pixelSize: 11
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

        // Which projection. The rings are the same 2 m rings in both, so they give the eye
        // something continuous to hold on to when the view changes under it.
        //
        // Hand-rolled rather than two checkable Buttons, for one structural reason: clicking
        // a checkable Button ASSIGNS its `checked`, which destroys a declarative binding on
        // it, so `checked: !root.firstPerson` survives exactly one click and then the
        // highlight drifts from the actual mode. Here nothing writes to the control at all
        // -- every visual property reads out of cloud.viewMode -- so it cannot disagree with
        // the view it is switching, however the mode was changed. The V key changes it too.
        Rectangle {
            id: viewToggle
            anchors.verticalCenter: parent.verticalCenter
            width: 172
            height: 26
            radius: 5
            color: "#15181d"
            border { color: "#2b3038"; width: 1 }

            Rectangle {
                x: root.firstPerson ? viewToggle.width / 2 : 0
                y: 2
                width: viewToggle.width / 2
                height: viewToggle.height - 4
                radius: 4
                color: "#2c3e57"
                // Slides rather than jumps, so it is obvious which half became active.
                Behavior on x {
                    NumberAnimation { duration: 110; easing.type: Easing.OutQuad }
                }
            }

            Row {
                anchors.fill: parent

                Repeater {
                    model: [
                        { label: "bird", wants: false },
                        { label: "first person", wants: true }
                    ]

                    Item {
                        width: viewToggle.width / 2
                        height: viewToggle.height

                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: modelData.wants === root.firstPerson ? "#e6e9ef" : "#7b8494"
                            font.pixelSize: 11
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                cloud.viewMode = modelData.wants ? LidarView.FirstPerson
                                                                 : LidarView.Bird;
                                // The cloud keeps the keys, so V and WASD work straight
                                // after a click on the toggle.
                                keys.forceActiveFocus();
                            }
                        }
                    }
                }
            }
        }

        Column {
            spacing: 2
            Text {
                // The same slider means the width of the frame from above, and how far the
                // rings reach in first person -- where the field of view sets the framing.
                text: root.firstPerson ? "rings out to " + (zoom.value / 2).toFixed(0) + " m"
                                       : "view " + zoom.value.toFixed(0) + " m across"
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

        Column {
            spacing: 2
            visible: root.firstPerson
            Text {
                text: "field of view " + fov.value.toFixed(0) + "°"
                color: "#8b93a1"
                font.pixelSize: 11
            }
            Slider {
                id: fov
                from: 20
                to: 120
                value: 70
                width: 150
            }
        }
    }

    // ---- where the camera is, in first person ----------------------------------------

    Text {
        anchors { right: parent.right; bottom: parent.bottom; margins: 12 }
        visible: root.firstPerson
        horizontalAlignment: Text.AlignRight
        text: "heading " + cloud.yawDeg.toFixed(0) + "°   pitch "
              + cloud.pitchDeg.toFixed(0) + "°\nat " + cloud.eyeText
        color: "#5c6474"
        font { pixelSize: 11; family: "Menlo" }
    }

    Text {
        anchors { left: parent.left; bottom: parent.bottom; margins: 12 }
        text: root.firstPerson
              ? "first person beside the sensor — drag to look, WASD and Q/E to move, wheel to zoom, R to reset, V to swap"
              : "top-down view, rings every 2 m — V for first person"
        color: "#5c6474"
        font.pixelSize: 11
    }
}
