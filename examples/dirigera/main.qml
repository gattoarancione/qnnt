// The DIRIGERA control station.
//
// Organised by WHAT A DEVICE IS FOR, not by where it is. The first version grouped
// everything by room, which put a lamp, an occupancy sensor and a light meter in one list
// -- and they answer three unrelated questions: what can I switch, is anyone there, how
// bright is it. Room is still shown, as a label.
//
//   LIGHTS     actuators. Grouped by room, because that IS how you think about lights,
//              and given exactly the controls the hub says it will accept.
//   PRESENCE   occupancy. Motion is an EVENT, so the useful fact is when it last fired,
//              not what the sensor reads at this instant.
//   REMOTES    inputs. Nothing to operate; the only actionable fact is battery.
//
// One physical sensor, one row: a VALLHORN is a single unit on the wall that the hub
// reports as two devices, a motion sensor and a light sensor sharing a relationId. The
// light-sensor half has no name and no room of its own, so it is not a row -- its reading
// is folded into its twin's.
//
// The Basic style specifically: the native macOS style refuses `background` and
// `contentItem` overrides, so custom switches and sliders silently fall back to system
// chrome.
import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts

Window {
    id: root
    width: 1040
    height: 760
    visible: true
    title: home.hub + " -- qnnt home"
    color: "#12141a"

    readonly property color panel: "#1b1f27"
    readonly property color card: "#212632"
    readonly property color panelEdge: "#282e39"
    readonly property color accent: "#ffc75a"     // warm, for lit things
    readonly property color cool: "#6db8ff"       // measurements
    readonly property color ok: "#4ad07a"         // presence
    readonly property color warn: "#ff5a4a"
    readonly property color dim: "#7f8794"

    // ---------------------------------------------------------------- the hub row
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 14 }
        height: 60
        radius: 8
        color: root.panel
        border.width: 1
        border.color: home.eventLink ? root.panelEdge : root.warn

        RowLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 16

            // Two dots, because the two directions fail independently: the REST API and
            // the push stream.
            Column {
                spacing: 4
                Row {
                    spacing: 5
                    Rectangle {
                        width: 9; height: 9; radius: 5
                        color: home.apiLink ? root.ok : root.warn
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text { text: "api"; color: root.dim; font.pixelSize: 10 }
                }
                Row {
                    spacing: 5
                    Rectangle {
                        width: 9; height: 9; radius: 5
                        color: home.eventLink ? root.ok : root.warn
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text { text: "push"; color: root.dim; font.pixelSize: 10 }
                }
            }

            Column {
                Layout.fillWidth: true
                Text {
                    text: home.hub
                    color: "white"
                    font.pixelSize: 16
                    font.bold: true
                }
                Text {
                    text: home.haveStatus
                          ? ("firmware " + home.firmware + "  ·  " + home.linkDetail)
                          : home.linkDetail
                    color: root.dim
                    font.pixelSize: 11
                }
            }

            // One figure per function, in the same colours the sections use.
            Repeater {
                model: [
                    { value: home.lightsOn + "/" + home.lightCount, label: "lit",
                      tint: home.lightsOn > 0 ? root.accent : root.dim },
                    { value: "" + home.presenceActive, label: "presence",
                      tint: home.presenceActive > 0 ? root.ok : root.dim },
                    { value: "" + home.lowBattery, label: "low battery",
                      tint: home.lowBattery > 0 ? root.warn : root.dim }
                ]
                delegate: Column {
                    required property var modelData
                    Layout.alignment: Qt.AlignVCenter
                    Text {
                        text: modelData.value
                        color: modelData.tint
                        font.pixelSize: 15
                        font.family: "Menlo"
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                    Text {
                        text: modelData.label
                        color: root.dim
                        font.pixelSize: 9
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- waiting state
    Text {
        anchors.centerIn: parent
        visible: home.devices.length === 0
        horizontalAlignment: Text.AlignHCenter
        color: root.dim
        font.pixelSize: 13
        text: "no devices yet.\n\nstart the bridge:\n" +
              "  ./zig-out/bin/dirigera-bridge --host <hub>:8443"
    }

    // ---------------------------------------------------------------- the three sections
    ScrollView {
        anchors {
            top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom
            margins: 14
        }
        clip: true
        visible: home.devices.length > 0

        ColumnLayout {
            width: root.width - 30
            spacing: 16

            // ======================================================== LIGHTS
            SectionHeader {
                text: "lights"
                hint: "what you can switch"
                tint: root.accent
                count: home.lightCount
            }

            Repeater {
                model: home.rooms

                delegate: Rectangle {
                    required property string modelData
                    readonly property string roomName: modelData

                    // A room with no lights in it is not a lights heading.
                    property int lightsHere: {
                        var n = 0;
                        for (var i = 0; i < home.lights.length; i++) {
                            var d = home.lights[i];
                            var r = d.room === "" ? "Unassigned" : d.room;
                            if (r === roomName) n++;
                        }
                        return n;
                    }

                    Layout.fillWidth: true
                    visible: lightsHere > 0
                    implicitHeight: visible ? roomColumn.implicitHeight + 22 : 0
                    radius: 10
                    color: root.panel

                    ColumnLayout {
                        id: roomColumn
                        anchors.fill: parent
                        anchors.margins: 11
                        spacing: 7

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                Layout.fillWidth: true
                                text: roomName
                                color: "white"
                                font.pixelSize: 13
                                font.bold: true
                            }
                            // Per room, deliberately: one button that switches off a whole
                            // house is a mis-click waiting to happen.
                            Repeater {
                                model: [{ label: "all on", on: true },
                                        { label: "all off", on: false }]
                                delegate: Button {
                                    required property var modelData
                                    text: modelData.label
                                    implicitWidth: 62
                                    implicitHeight: 22
                                    onClicked: home.setRoom(roomName, modelData.on)
                                    background: Rectangle {
                                        radius: 5
                                        color: parent.pressed ? "#333c4a" : "#242a34"
                                        border.width: 1
                                        border.color: root.panelEdge
                                    }
                                    contentItem: Text {
                                        text: parent.text
                                        color: root.dim
                                        font.pixelSize: 10
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }
                        }

                        Repeater {
                            model: home.lights
                            delegate: Loader {
                                required property var modelData
                                readonly property var dev: modelData
                                Layout.fillWidth: true
                                active: (dev.room === roomName
                                         || (dev.room === "" && roomName === "Unassigned"))
                                visible: active
                                sourceComponent: lightRow
                                onLoaded: item.dev = dev
                            }
                        }
                    }
                }
            }

            // ======================================================== PRESENCE
            SectionHeader {
                text: "presence and light level"
                hint: "one row per sensor on the wall, not per device the hub reports"
                tint: root.ok
                count: home.sensorCount
            }

            Rectangle {
                Layout.fillWidth: true
                visible: home.sensors.length > 0
                implicitHeight: sensorColumn.implicitHeight + 22
                radius: 10
                color: root.panel

                ColumnLayout {
                    id: sensorColumn
                    anchors.fill: parent
                    anchors.margins: 11
                    spacing: 7

                    Repeater {
                        model: home.sensors
                        delegate: Loader {
                            required property var modelData
                            readonly property var dev: modelData
                            Layout.fillWidth: true
                            sourceComponent: sensorRow
                            onLoaded: item.dev = dev
                        }
                    }
                }
            }

            // ======================================================== REMOTES
            SectionHeader {
                text: "remotes"
                hint: "inputs -- nothing to operate from here"
                tint: root.dim
                count: home.controls.length
            }

            Rectangle {
                Layout.fillWidth: true
                visible: home.controls.length > 0
                implicitHeight: controlColumn.implicitHeight + 22
                radius: 10
                color: root.panel

                ColumnLayout {
                    id: controlColumn
                    anchors.fill: parent
                    anchors.margins: 11
                    spacing: 7

                    Repeater {
                        model: home.controls
                        delegate: Loader {
                            required property var modelData
                            readonly property var dev: modelData
                            Layout.fillWidth: true
                            sourceComponent: controlRow
                            onLoaded: item.dev = dev
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 6 }
        }
    }

    // ---------------------------------------------------------------- a section heading
    component SectionHeader: RowLayout {
        property string text
        property string hint
        property color tint
        property int count

        Layout.fillWidth: true
        Layout.topMargin: 4
        spacing: 8

        Rectangle { width: 3; height: 22; radius: 2; color: tint }
        Text {
            text: parent.text
            color: "white"
            font.pixelSize: 14
            font.bold: true
        }
        Text {
            text: "" + count
            color: tint
            font.pixelSize: 12
            font.family: "Menlo"
        }
        Text {
            Layout.fillWidth: true
            text: hint
            color: root.dim
            font.pixelSize: 10
        }
    }

    // ---------------------------------------------------------------- a light
    Component {
        id: lightRow

        Rectangle {
            property var dev

            implicitHeight: lightContent.implicitHeight + 16
            radius: 7
            // Unreachable is not off: the hub reports last-known state for a device it
            // cannot talk to, so those are dimmed and labelled rather than shown as live.
            color: dev && !dev.reachable ? "#191c22" : root.card
            border.width: 1
            border.color: dev && dev.pending ? root.cool : "transparent"
            opacity: dev && !dev.reachable ? 0.55 : 1.0

            ColumnLayout {
                id: lightContent
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Rectangle {
                        width: 10; height: 10; radius: 5
                        Layout.alignment: Qt.AlignVCenter
                        color: dev && dev.isOn ? root.accent : "#39404d"
                    }

                    Column {
                        Layout.fillWidth: true
                        Text {
                            text: dev ? dev.label() : ""
                            color: "white"
                            font.pixelSize: 13
                        }
                        Text {
                            text: {
                                if (!dev) return "";
                                var bits = [];
                                if (dev.model !== "") bits.push(dev.model);
                                if (!dev.reachable) bits.push("UNREACHABLE");
                                return bits.join("  ·  ");
                            }
                            color: dev && !dev.reachable ? root.warn : root.dim
                            font.pixelSize: 10
                        }
                    }

                    Text {
                        text: dev ? dev.age : ""
                        color: root.dim
                        font.pixelSize: 10
                        Layout.preferredWidth: 34
                        horizontalAlignment: Text.AlignRight
                    }

                    // Appears only if the hub accepts `isOn` for this device. A click marks
                    // it pending; it moves when the hub confirms through the state topic.
                    Switch {
                        visible: dev && dev.canSetOn
                        checked: dev ? dev.isOn : false
                        enabled: dev ? dev.reachable : false
                        onToggled: home.setOn(dev.deviceId, checked)
                        indicator: Rectangle {
                            implicitWidth: 40; implicitHeight: 20
                            radius: 10
                            color: parent.checked ? root.accent : "#39404d"
                            Rectangle {
                                x: parent.parent.checked ? parent.width - width - 2 : 2
                                y: 2
                                width: 16; height: 16; radius: 8
                                color: "white"
                                Behavior on x { NumberAnimation { duration: 90 } }
                            }
                        }
                        background: Item {}
                    }
                }

                // Brightness, only where the hub accepts `lightLevel`.
                RowLayout {
                    Layout.fillWidth: true
                    visible: dev && dev.canSetLevel
                    spacing: 8
                    Text {
                        text: "level"; color: root.dim; font.pixelSize: 10
                        Layout.preferredWidth: 42
                    }
                    Slider {
                        Layout.fillWidth: true
                        from: 0; to: 100
                        value: dev ? dev.level : 0
                        enabled: dev ? dev.reachable : false
                        // On release, not on every pixel: the hub is a Zigbee coordinator,
                        // not a render target.
                        onPressedChanged: if (!pressed && dev) home.setLevel(dev.deviceId, Math.round(value))
                    }
                    Text {
                        text: dev ? dev.level + "%" : ""
                        color: root.dim; font.pixelSize: 10
                        Layout.preferredWidth: 36
                    }
                }

                // Colour temperature, over the bulb's own range -- which the bridge sorted,
                // because the hub reports its min above its max.
                RowLayout {
                    Layout.fillWidth: true
                    visible: dev && dev.canSetKelvin
                    spacing: 8
                    Text {
                        text: "warmth"; color: root.dim; font.pixelSize: 10
                        Layout.preferredWidth: 42
                    }
                    Slider {
                        Layout.fillWidth: true
                        from: dev ? dev.kelvinMin : 2200
                        to: dev ? dev.kelvinMax : 4000
                        value: dev ? dev.kelvin : 2700
                        enabled: dev ? dev.reachable : false
                        onPressedChanged: if (!pressed && dev) home.setKelvin(dev.deviceId, Math.round(value))
                    }
                    Text {
                        text: dev ? dev.kelvin + "K" : ""
                        color: root.dim; font.pixelSize: 10
                        Layout.preferredWidth: 36
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- a sensor unit
    Component {
        id: sensorRow

        Rectangle {
            property var dev
            // The light meter inside this same physical unit, if there is one.
            readonly property int lux: dev ? home.illuminanceFor(dev.relation) : -1

            implicitHeight: 46
            radius: 7
            color: dev && !dev.reachable ? "#191c22" : root.card
            opacity: dev && !dev.reachable ? 0.55 : 1.0

            RowLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 12

                // Presence, not "isDetected right now": the hub clears the flag on its own
                // schedule, so a strict reading flickers between events.
                Rectangle {
                    width: 10; height: 10; radius: 5
                    Layout.alignment: Qt.AlignVCenter
                    color: dev && dev.recentMotion ? root.ok : "#39404d"
                    Behavior on color { ColorAnimation { duration: 200 } }
                }

                Column {
                    Layout.fillWidth: true
                    Text {
                        text: dev ? dev.label() : ""
                        color: "white"
                        font.pixelSize: 13
                    }
                    Text {
                        text: {
                            if (!dev) return "";
                            var bits = [];
                            if (dev.room !== "") bits.push(dev.room);
                            if (!dev.reachable) bits.push("UNREACHABLE");
                            return bits.join("  ·  ");
                        }
                        color: dev && !dev.reachable ? root.warn : root.dim
                        font.pixelSize: 10
                    }
                }

                // When it last fired, which is the fact that matters for an event device.
                Column {
                    visible: dev && dev.hasMotion
                    Text {
                        text: dev ? dev.lastMotion : ""
                        color: dev && dev.recentMotion ? root.ok : root.dim
                        font.pixelSize: 12
                        font.family: "Menlo"
                        anchors.right: parent.right
                    }
                    Text {
                        text: "last motion"
                        color: root.dim
                        font.pixelSize: 9
                        anchors.right: parent.right
                    }
                }

                // Folded in from the other half of the same unit.
                Column {
                    visible: lux >= 0 || (dev && dev.hasIlluminance)
                    Text {
                        text: (lux >= 0 ? lux : (dev ? dev.illuminance : 0)) + " lx"
                        color: root.cool
                        font.pixelSize: 12
                        font.family: "Menlo"
                        anchors.right: parent.right
                    }
                    Text {
                        text: "light level"
                        color: root.dim
                        font.pixelSize: 9
                        anchors.right: parent.right
                    }
                }

                BatteryPip { dev: parent.dev }
            }
        }
    }

    // ---------------------------------------------------------------- a remote
    Component {
        id: controlRow

        Rectangle {
            property var dev

            implicitHeight: 40
            radius: 7
            color: dev && !dev.reachable ? "#191c22" : root.card
            opacity: dev && !dev.reachable ? 0.55 : 1.0

            RowLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 12

                Column {
                    Layout.fillWidth: true
                    Text {
                        text: dev ? dev.label() : ""
                        color: "white"
                        font.pixelSize: 12
                    }
                    Text {
                        text: dev ? (dev.room + (dev.model !== "" ? "  ·  " + dev.model : "")) : ""
                        color: root.dim
                        font.pixelSize: 9
                    }
                }

                Text {
                    text: dev ? dev.age : ""
                    color: root.dim
                    font.pixelSize: 10
                }

                BatteryPip { dev: parent.dev }
            }
        }
    }

    // ---------------------------------------------------------------- battery
    //
    // The only actionable fact a sensor or a remote offers, so it gets one consistent
    // presentation wherever it appears.
    component BatteryPip: Row {
        property var dev
        visible: dev && dev.hasBattery
        spacing: 5

        Rectangle {
            width: 22; height: 10; radius: 2
            anchors.verticalCenter: parent.verticalCenter
            color: "transparent"
            border.width: 1
            border.color: root.dim
            Rectangle {
                x: 1; y: 1
                width: Math.max(1, (parent.width - 2) * (dev ? dev.battery / 100 : 0))
                height: parent.height - 2
                radius: 1
                color: dev && dev.battery < 20 ? root.warn
                     : dev && dev.battery < 40 ? "#ffb84a" : root.ok
            }
        }
        Text {
            text: dev ? dev.battery + "%" : ""
            color: dev && dev.battery < 20 ? root.warn : root.dim
            font.pixelSize: 10
            font.family: "Menlo"
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
