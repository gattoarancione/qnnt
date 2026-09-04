// The UGV Beast control station.
//
// Drive with WASD or the arrow keys, or drag inside the pad. Space stops.
//
// The layout puts the things that matter when something goes wrong where they cannot be
// missed: the pad turns red and names the reason when the bridge's watchdog has stopped the
// robot, and the link row is at the top rather than buried in a status bar.

import QtQuick
import QtQuick.Window
// The Basic style specifically, not `QtQuick.Controls`: the native macOS style refuses
// `background` and `contentItem` overrides, so the STOP button and the pan-tilt row would
// silently fall back to system chrome. A stop control that does not look like one is a real
// problem rather than a cosmetic one. Importing the style module directly also avoids
// linking QtQuickControls2 just to call QQuickStyle::setStyle.
import QtQuick.Controls.Basic
import QtQuick.Layouts

Window {
    id: root
    width: 900
    height: 620
    visible: true
    title: pilot.robot + " -- qnnt control station"
    color: "#14161a"

    readonly property color accent: "#4a9eff"
    readonly property color warn: "#ff5a4a"
    readonly property color ok: "#4ad07a"
    readonly property color dim: "#8b93a1"

    // Every key event lands here. `focus: true` on the item plus forceActiveFocus below is
    // what keeps them coming after a click on a control.
    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onPressed: (event) => {
            if (event.isAutoRepeat) return;
            if (event.key === Qt.Key_Space) { pilot.stop(); event.accepted = true; return; }
            var name = keyName(event.key);
            if (name !== "") { pilot.setKey(name, true); event.accepted = true; }
        }
        Keys.onReleased: (event) => {
            if (event.isAutoRepeat) return;
            var name = keyName(event.key);
            if (name !== "") { pilot.setKey(name, false); event.accepted = true; }
        }

        function keyName(k) {
            switch (k) {
            case Qt.Key_W: case Qt.Key_Up: return "up";
            case Qt.Key_S: case Qt.Key_Down: return "down";
            case Qt.Key_A: case Qt.Key_Left: return "left";
            case Qt.Key_D: case Qt.Key_Right: return "right";
            }
            return "";
        }
    }

    // A key-up is never delivered to a window that has lost focus, so a held key would
    // latch on and the robot would keep driving after the operator switched away.
    onActiveChanged: if (!active) pilot.releaseAll()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 14

        // -- the link row ---------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            height: 54
            radius: 8
            color: "#1c1f26"
            border.width: 1
            border.color: pilot.link ? "#2a2f38" : root.warn

            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 16

                Rectangle {
                    width: 12; height: 12; radius: 6
                    color: pilot.link ? root.ok : root.warn
                    Layout.alignment: Qt.AlignVCenter
                }

                Column {
                    Layout.fillWidth: true
                    Text {
                        text: pilot.robot
                        color: "white"
                        font.pixelSize: 15
                        font.bold: true
                    }
                    Text {
                        text: pilot.linkDetail
                        color: root.dim
                        font.pixelSize: 11
                    }
                }

                // Shown only when the bridge is enforcing its own built-in limits, because
                // then the numbers on screen are not the robot's.
                Text {
                    visible: pilot.link && !pilot.limitsFromRobot
                    text: "LIMITS ASSUMED"
                    color: root.warn
                    font.pixelSize: 11
                    font.bold: true
                }

                Text {
                    text: "max_speed " + pilot.maxSpeed.toFixed(2)
                    color: root.dim
                    font.pixelSize: 11
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 14

            // -- the drive pad ----------------------------------------------------
            Rectangle {
                Layout.preferredWidth: 420
                Layout.fillHeight: true
                radius: 10
                color: "#1c1f26"
                border.width: 2
                border.color: pilot.deadman ? root.warn : "#2a2f38"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    Text {
                        text: pilot.deadman ? "WATCHDOG STOPPED THE ROBOT"
                                            : "drive -- WASD or arrows, or drag"
                        color: pilot.deadman ? root.warn : root.dim
                        font.pixelSize: 12
                        font.bold: pilot.deadman
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Item {
                        id: pad
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        Rectangle {
                            anchors.centerIn: parent
                            width: Math.min(pad.width, pad.height)
                            height: width
                            radius: width / 2
                            color: "#22262f"
                            border.width: 1
                            border.color: "#2f353f"

                            // Cross-hairs, so the centre -- which is "stopped" -- is
                            // visible rather than implied.
                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width * 0.9; height: 1
                                color: "#2f353f"
                            }
                            Rectangle {
                                anchors.centerIn: parent
                                width: 1; height: parent.height * 0.9
                                color: "#2f353f"
                            }

                            // The commanded point. Both axes come from the C++ side
                            // already signed -- steerAxis is positive to the right,
                            // driveAxis positive forward -- so this only places them, and
                            // the sign convention lives in one place rather than two.
                            Rectangle {
                                width: 26; height: 26; radius: 13
                                color: pilot.deadman ? root.warn : root.accent
                                x: parent.width / 2 - 13
                                    + pilot.steerAxis * (parent.width / 2 - 20)
                                y: parent.height / 2 - 13
                                    - pilot.driveAxis * (parent.height / 2 - 20)
                                Behavior on x { NumberAnimation { duration: 60 } }
                                Behavior on y { NumberAnimation { duration: 60 } }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onPressed: (m) => { keys.forceActiveFocus(); report(m.x, m.y); }
                                onPositionChanged: (m) => { if (pressed) report(m.x, m.y); }
                                onReleased: pilot.releasePad()
                                onCanceled: pilot.releasePad()

                                function report(mx, my) {
                                    var cx = width / 2;
                                    var cy = height / 2;
                                    pilot.setPad((mx - cx) / cx, -(my - cy) / cy);
                                }
                            }
                        }
                    }

                    // The two track speeds, as sent.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 20
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: "L " + pilot.left.toFixed(2)
                            color: "white"
                            font.pixelSize: 14
                            font.family: "Menlo"
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: "R " + pilot.right.toFixed(2)
                            color: "white"
                            font.pixelSize: 14
                            font.family: "Menlo"
                        }
                    }

                    Button {
                        Layout.fillWidth: true
                        text: "STOP  (space)"
                        onClicked: { pilot.stop(); keys.forceActiveFocus(); }
                        background: Rectangle {
                            radius: 6
                            color: parent.pressed ? "#c03a2c" : root.warn
                        }
                        contentItem: Text {
                            text: parent.text
                            color: "white"
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }

            // -- throttle, telemetry, gimbal -------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 14

                Rectangle {
                    Layout.fillWidth: true
                    height: 92
                    radius: 10
                    color: "#1c1f26"

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 4

                        Text {
                            text: "throttle -- " + Math.round(pilot.throttle * 100) + "% of "
                                  + pilot.maxSpeed.toFixed(2)
                            color: root.dim
                            font.pixelSize: 12
                        }
                        Slider {
                            id: throttleSlider
                            Layout.fillWidth: true
                            from: 0.0; to: 1.0
                            value: 0.4
                            onMoved: { pilot.setThrottle(value); keys.forceActiveFocus(); }
                        }
                    }
                }

                // -- telemetry -----------------------------------------------------
                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 10
                    color: "#1c1f26"

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                Layout.fillWidth: true
                                text: "telemetry"
                                color: root.dim
                                font.pixelSize: 12
                            }
                            // This robot emits about every five seconds, so the age is part
                            // of the reading, not a diagnostic.
                            Text {
                                text: pilot.telemetryAge
                                color: root.dim
                                font.pixelSize: 11
                            }
                        }

                        // Battery.
                        Column {
                            Layout.fillWidth: true
                            spacing: 4
                            Text {
                                text: pilot.haveTelemetry
                                      ? pilot.voltage.toFixed(2) + " V"
                                      : "-- V"
                                color: "white"
                                font.pixelSize: 26
                                font.family: "Menlo"
                            }
                            Rectangle {
                                width: parent.width
                                height: 6
                                radius: 3
                                color: "#22262f"
                                Rectangle {
                                    width: parent.width * pilot.batteryFraction
                                    height: parent.height
                                    radius: 3
                                    color: pilot.batteryFraction < 0.2 ? root.warn
                                         : pilot.batteryFraction < 0.4 ? "#ffb84a" : root.ok
                                    Behavior on width { NumberAnimation { duration: 200 } }
                                }
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 2
                            columnSpacing: 18
                            rowSpacing: 6

                            Repeater {
                                model: [
                                    { k: "pan",  v: pilot.panDeg.toFixed(1) + " deg" },
                                    { k: "tilt", v: pilot.tiltDeg.toFixed(1) + " deg" },
                                    { k: "cpu",  v: pilot.cpuLoad.toFixed(0) + " %" },
                                    { k: "temp", v: pilot.cpuTemp.toFixed(1) + " C" },
                                    { k: "ram",  v: pilot.ramUsage.toFixed(1) + " %" },
                                    { k: "video", v: pilot.videoFps.toFixed(1) + " fps" }
                                ]
                                delegate: RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        text: modelData.k
                                        color: root.dim
                                        font.pixelSize: 11
                                        Layout.preferredWidth: 42
                                    }
                                    Text {
                                        text: pilot.haveTelemetry ? modelData.v : "--"
                                        color: "white"
                                        font.pixelSize: 12
                                        font.family: "Menlo"
                                    }
                                }
                            }
                        }

                        Item { Layout.fillHeight: true }

                        Text {
                            Layout.fillWidth: true
                            text: pilot.commandStats
                            color: root.dim
                            font.pixelSize: 10
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                // -- gimbal -------------------------------------------------------
                //
                // Present but inert on this machine: its /config reports module_type 0, so
                // no pan-tilt module is configured and the robot ignores T:133. Left in
                // place because the command path is complete and the robot is a "PT" model.
                Rectangle {
                    Layout.fillWidth: true
                    height: 78
                    radius: 10
                    color: "#1c1f26"

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 6

                        Text {
                            text: "pan-tilt"
                            color: root.dim
                            font.pixelSize: 12
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Repeater {
                                model: [
                                    { label: "left",   pan: -45, tilt: 0 },
                                    { label: "centre", pan: 0,   tilt: 0 },
                                    { label: "right",  pan: 45,  tilt: 0 },
                                    { label: "up",     pan: 0,   tilt: 45 },
                                    { label: "down",   pan: 0,   tilt: -20 }
                                ]
                                delegate: Button {
                                    Layout.fillWidth: true
                                    text: modelData.label
                                    onClicked: {
                                        pilot.aimGimbal(modelData.pan, modelData.tilt);
                                        keys.forceActiveFocus();
                                    }
                                    background: Rectangle {
                                        radius: 5
                                        color: parent.pressed ? "#2f3947" : "#22262f"
                                        border.width: 1
                                        border.color: "#2f353f"
                                    }
                                    contentItem: Text {
                                        text: parent.text
                                        color: "white"
                                        font.pixelSize: 11
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component.onCompleted: keys.forceActiveFocus()
}
