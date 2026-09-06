// The CAN mesh station.
//
// Laid out around the question a MESH raises that a single bus does not: not "what is on
// the bus", but "which of these hosts is putting it there". So the left column is the mesh
// -- buses, and under each the gateways that publish to it, each with its own rate -- and
// the table is the bus itself.
//
// A row per identifier rather than a scrolling log, because a bus repeats a handful of
// identifiers endlessly and a scroll shows only the fastest. Sorted by rate, which puts the
// periodic signals at the top and leaves the occasional ones where they can be seen.
//
// The Basic style specifically: the native macOS style refuses `background` and
// `contentItem` overrides, so custom controls silently fall back to system chrome.
import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts

Window {
    id: root
    width: 1100
    height: 780
    visible: true
    title: "can-station -- qnnt CAN mesh"
    color: "#12141a"

    readonly property color panel: "#1b1f27"
    readonly property color card: "#212632"
    readonly property color panelEdge: "#282e39"
    readonly property color accent: "#6db8ff"     // traffic
    readonly property color ok: "#4ad07a"         // live
    readonly property color warn: "#ff5a4a"       // error frames, stale gateways
    readonly property color mine: "#ffc75a"       // this station's own traffic
    readonly property color dim: "#7f8794"

    // Every control in the send box, handed over in one call. Called whenever any of them
    // changes WHILE a repeat is running, so editing the payload mid-repeat changes what is
    // being sent instead of being ignored until it is toggled off and on again.
    function applyRepeat() {
        station.setRepeat(repeatBox.checked, station.selectedBus, idField.text,
                          extBox.checked, rtrBox.checked, fdBox.checked, brsBox.checked,
                          dataField.text, periodField.text)
    }

    function reapply() {
        if (repeatBox.checked) applyRepeat()
    }

    function rateText(r) {
        if (r <= 0) return "--"
        return r < 10 ? r.toFixed(1) + "/s" : Math.round(r) + "/s"
    }

    // ---------------------------------------------------------------- the mesh summary
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 14 }
        height: 58
        radius: 8
        color: root.panel
        border.width: 1
        border.color: station.haveMesh ? root.panelEdge : root.warn

        RowLayout {
            anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
            spacing: 14

            ColumnLayout {
                spacing: 2
                Text {
                    text: "CAN mesh"
                    color: "#e6e9ef"
                    font.pixelSize: 18
                    font.bold: true
                }
                Text {
                    text: station.summary
                    color: root.dim
                    font.pixelSize: 12
                }
            }

            Item { Layout.fillWidth: true }

            // Which name this station's own injected frames carry. Shown because it is the
            // name that appears in the gateway list below, as one more gateway.
            Text {
                text: "publishing as " + station.name
                color: root.mine
                font.pixelSize: 12
                font.family: "Menlo"
            }
        }
    }

    // ---------------------------------------------------------------- the mesh
    Rectangle {
        id: mesh
        anchors { top: header.bottom; left: parent.left; bottom: inject.top; margins: 14 }
        width: 300
        radius: 8
        color: root.panel
        border.width: 1
        border.color: root.panelEdge

        Text {
            id: meshTitle
            anchors { top: parent.top; left: parent.left; margins: 14 }
            text: "BUSES"
            color: root.dim
            font.pixelSize: 11
            font.bold: true
            font.letterSpacing: 1
        }

        ListView {
            anchors { top: meshTitle.bottom; left: parent.left; right: parent.right
                      bottom: parent.bottom; margins: 10; topMargin: 8 }
            clip: true
            spacing: 8
            model: station.buses

            delegate: Rectangle {
                required property var modelData
                width: ListView.view.width
                height: busColumn.implicitHeight + 20
                radius: 6
                color: modelData.selected ? root.card : "transparent"
                border.width: 1
                border.color: modelData.selected ? root.accent : root.panelEdge

                MouseArea {
                    anchors.fill: parent
                    onClicked: station.selectedBus = modelData.name
                }

                ColumnLayout {
                    id: busColumn
                    anchors { fill: parent; margins: 10 }
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: modelData.name
                            color: "#e6e9ef"
                            font.pixelSize: 15
                            font.bold: true
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: root.rateText(modelData.rate)
                            color: root.accent
                            font.pixelSize: 13
                            font.family: "Menlo"
                        }
                    }

                    Text {
                        text: modelData.ids + " identifier(s)"
                        color: root.dim
                        font.pixelSize: 11
                    }

                    // A frame that would not decode means the wire format has drifted
                    // between the gateway and this station, which is worth a line of its
                    // own rather than a silent discard.
                    Text {
                        visible: modelData.undecodable > 0
                        text: modelData.undecodable + " frame(s) did not decode"
                        color: root.warn
                        font.pixelSize: 11
                    }

                    // One line per gateway. This is the mesh: the same bus, seen from
                    // several hosts, each with a rate of its own. A host that has gone
                    // quiet shows here and nowhere else.
                    Repeater {
                        model: modelData.gateways
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 6


                            Rectangle {
                                width: 7; height: 7; radius: 4
                                color: modelData.stale ? root.warn
                                     : modelData.self ? root.mine : root.ok
                            }

                            Text {
                                text: modelData.name
                                color: modelData.stale ? root.warn : "#c8cdd6"
                                font.pixelSize: 12
                                font.family: "Menlo"
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.rateText(modelData.rate)
                                color: root.dim
                                font.pixelSize: 11
                                font.family: "Menlo"
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- the bus
    Rectangle {
        anchors { top: header.bottom; left: mesh.right; right: parent.right
                  bottom: inject.top; margins: 14; leftMargin: 0 }
        radius: 8
        color: root.panel
        border.width: 1
        border.color: root.panelEdge

        Text {
            id: tableTitle
            anchors { top: parent.top; left: parent.left; margins: 14 }
            text: station.selectedBus ? station.selectedBus.toUpperCase() : "NO BUS SELECTED"
            color: root.dim
            font.pixelSize: 11
            font.bold: true
            font.letterSpacing: 1
        }

        // Fixed columns rather than a layout per row: every row has the same shape, and a
        // table that reflows as values change is unreadable while it is changing.
        RowLayout {
            id: headings
            anchors { top: tableTitle.bottom; left: parent.left; right: parent.right
                      margins: 14; topMargin: 10 }
            spacing: 12
            Text { text: "ID";     color: root.dim; font.pixelSize: 11; Layout.preferredWidth: 92 }
            Text { text: "";       color: root.dim; font.pixelSize: 11; Layout.preferredWidth: 44 }
            Text { text: "DLC";    color: root.dim; font.pixelSize: 11; Layout.preferredWidth: 32 }
            Text { text: "DATA";   color: root.dim; font.pixelSize: 11; Layout.fillWidth: true }
            Text { text: "FROM";   color: root.dim; font.pixelSize: 11; Layout.preferredWidth: 80 }
            Text { text: "RATE";   color: root.dim; font.pixelSize: 11; Layout.preferredWidth: 62
                   horizontalAlignment: Text.AlignRight }
            Text { text: "COUNT";  color: root.dim; font.pixelSize: 11; Layout.preferredWidth: 70
                   horizontalAlignment: Text.AlignRight }
        }

        Text {
            anchors.centerIn: parent
            visible: station.rows.length === 0
            text: station.haveMesh ? "no frames on this bus yet"
                                   : "waiting for a gateway to publish can/<bus>/<name>"
            color: root.dim
            font.pixelSize: 13
        }

        ListView {
            anchors { top: headings.bottom; left: parent.left; right: parent.right
                      bottom: parent.bottom; margins: 10; topMargin: 6 }
            clip: true
            model: station.rows

            delegate: Rectangle {
                required property var modelData
                width: ListView.view.width
                height: 26
                color: index % 2 ? "transparent" : root.card
                required property int index

                RowLayout {
                    anchors { fill: parent; leftMargin: 4; rightMargin: 4 }
                    spacing: 12

                    Text {
                        text: modelData.id
                        // An error frame is drawn as one. It was published so it could be
                        // seen; no gateway will write it to another segment.
                        color: modelData.error ? root.warn
                             : modelData.stale ? root.dim : "#e6e9ef"
                        font.pixelSize: 12
                        font.family: "Menlo"
                        Layout.preferredWidth: 92
                    }
                    Text {
                        text: modelData.flags
                        color: root.mine
                        font.pixelSize: 12
                        font.family: "Menlo"
                        Layout.preferredWidth: 44
                    }
                    Text {
                        text: modelData.dlc
                        color: root.dim
                        font.pixelSize: 12
                        font.family: "Menlo"
                        Layout.preferredWidth: 32
                    }
                    Text {
                        text: modelData.data
                        color: modelData.stale ? root.dim : "#c8cdd6"
                        font.pixelSize: 12
                        font.family: "Menlo"
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                    Text {
                        text: modelData.from
                        color: root.dim
                        font.pixelSize: 11
                        font.family: "Menlo"
                        Layout.preferredWidth: 80
                        elide: Text.ElideRight
                    }
                    Text {
                        text: root.rateText(modelData.rate)
                        color: modelData.stale ? root.dim : root.accent
                        font.pixelSize: 12
                        font.family: "Menlo"
                        Layout.preferredWidth: 62
                        horizontalAlignment: Text.AlignRight
                    }
                    Text {
                        text: modelData.total
                        color: root.dim
                        font.pixelSize: 11
                        font.family: "Menlo"
                        Layout.preferredWidth: 70
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- inject
    //
    // This is not a simulator. A frame sent here is published on can/<bus>/<station> and
    // every gateway on that bus writes it to its local interface, so it reaches whatever is
    // wired to them.
    Rectangle {
        id: inject
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 14 }
        height: 76
        radius: 8
        color: root.panel
        border.width: 1
        border.color: root.panelEdge

        RowLayout {
            anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
            spacing: 10

            Text {
                text: "SEND"
                color: root.dim
                font.pixelSize: 11
                font.bold: true
                font.letterSpacing: 1
            }

            TextField {
                id: idField
                text: "0x123"
                onTextChanged: root.reapply()
                placeholderText: "id"
                Layout.preferredWidth: 100
                color: "#e6e9ef"
                font.family: "Menlo"
                background: Rectangle { color: root.card; radius: 4
                                        border.width: 1; border.color: root.panelEdge }
            }

            CheckBox {
                id: extBox
                text: "ext"
                onToggled: root.reapply()
                contentItem: Text { text: extBox.text; color: root.dim; font.pixelSize: 12
                                    leftPadding: extBox.indicator.width + 4
                                    verticalAlignment: Text.AlignVCenter }
            }
            // rtr and fd are mutually exclusive: CAN FD has no remote frames. Each
            // disables the other rather than letting a combination be composed that no
            // controller could transmit; station.cpp guards it again behind this.
            CheckBox {
                id: rtrBox
                text: "rtr"
                onToggled: root.reapply()
                enabled: !fdBox.checked
                contentItem: Text { text: rtrBox.text
                                    color: rtrBox.enabled ? root.dim : Qt.darker(root.dim, 1.6)
                                    font.pixelSize: 12
                                    leftPadding: rtrBox.indicator.width + 4
                                    verticalAlignment: Text.AlignVCenter }
            }
            CheckBox {
                id: fdBox
                text: "fd"
                onToggled: root.reapply()
                enabled: !rtrBox.checked
                contentItem: Text { text: fdBox.text
                                    color: fdBox.enabled ? root.dim : Qt.darker(root.dim, 1.6)
                                    font.pixelSize: 12
                                    leftPadding: fdBox.indicator.width + 4
                                    verticalAlignment: Text.AlignVCenter }
            }
            // The bit rate switch belongs to the FD data phase, so it is only offered when
            // there is one.
            CheckBox {
                id: brsBox
                text: "brs"
                onToggled: root.reapply()
                enabled: fdBox.checked
                contentItem: Text { text: brsBox.text
                                    color: brsBox.enabled ? root.dim : Qt.darker(root.dim, 1.6)
                                    font.pixelSize: 12
                                    leftPadding: brsBox.indicator.width + 4
                                    verticalAlignment: Text.AlignVCenter }
            }

            TextField {
                id: dataField
                text: "DE AD BE EF"
                onTextChanged: root.reapply()
                placeholderText: fdBox.checked ? "payload, hex -- 0-8, 12, 16, 20, 24, 32, 48 or 64 bytes"
                                               : "payload, hex -- up to 8 bytes"
                Layout.fillWidth: true
                color: "#e6e9ef"
                font.family: "Menlo"
                enabled: !rtrBox.checked   // a remote request carries no data
                background: Rectangle { color: root.card; radius: 4
                                        border.width: 1; border.color: root.panelEdge }
            }

            // The repeat, and its period. Almost every message on a vehicle bus is
            // periodic, so this is what a receiver under test is actually written against;
            // a single frame only proves the path works.
            CheckBox {
                id: repeatBox
                text: "every"
                enabled: station.selectedBus !== ""
                onToggled: root.applyRepeat()
                contentItem: Text { text: repeatBox.text
                                    color: repeatBox.enabled ? root.dim : Qt.darker(root.dim, 1.6)
                                    font.pixelSize: 12
                                    leftPadding: repeatBox.indicator.width + 4
                                    verticalAlignment: Text.AlignVCenter }
            }

            TextField {
                id: periodField
                text: "100"
                placeholderText: "ms"   // 1-60000; see parsePeriodMs in frames.hpp
                Layout.preferredWidth: 62
                color: "#e6e9ef"
                font.family: "Menlo"
                horizontalAlignment: TextInput.AlignRight
                onTextChanged: root.reapply()
                background: Rectangle { color: root.card; radius: 4
                                        border.width: 1; border.color: root.panelEdge }
            }
            Text { text: "ms"; color: root.dim; font.pixelSize: 12 }

            // The station unticks this itself when a period or a frame is refused, so the
            // box never shows a repeat that is not running.
            Binding {
                target: repeatBox
                property: "checked"
                value: station.repeating
                restoreMode: Binding.RestoreNone
            }

            Button {
                text: "Send to " + (station.selectedBus || "...")
                enabled: station.selectedBus !== ""
                onClicked: station.send(station.selectedBus, idField.text,
                                        extBox.checked, rtrBox.checked, fdBox.checked,
                                        brsBox.checked, dataField.text)
                contentItem: Text {
                    text: parent.text
                    color: parent.enabled ? "#12141a" : root.dim
                    font.pixelSize: 12
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: 5
                    implicitWidth: 150
                    implicitHeight: 30
                    color: parent.enabled ? (parent.down ? Qt.darker(root.accent, 1.3) : root.accent)
                                          : root.card
                }
            }
        }

        // What happened to the last one. A refusal says why rather than doing nothing:
        // the payload box takes text from a datasheet or a colleague's message, and an
        // odd digit count is a typo that must not become a frame on a real bus.
        Text {
            anchors { right: parent.right; bottom: parent.bottom; margins: 6 }
            text: station.sendResult
            color: station.sendResult.startsWith("sent") ? root.ok : root.warn
            font.pixelSize: 11
            font.family: "Menlo"
        }
    }
}
