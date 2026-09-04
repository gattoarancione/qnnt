// The display for the ZED X depth camera chain. See SCHEMA.txt.
//
// Everything expensive is in C++: CameraView owns the two QImages and rebuilds them once
// per frame, and `camera` is a context property that decodes frames and exposes counters.
// QML does layout, chrome and controls -- the same division the LiDAR viewer argues for.

import QtQuick
import QtQuick.Controls
import Qnnt.Camera

Window {
    id: root
    width: 1080
    height: 560
    visible: true
    color: "#0d0f12"
    title: "qnnt — " + (camera.model.length > 0 ? camera.model : "waiting for a camera")

    CameraView {
        id: view
        objectName: "view"
        anchors.fill: parent
        layout: layoutBox.currentIndex
        markHoles: holesToggle.checked
    }

    // ---- overlay: what the stream is doing -------------------------------------------

    Rectangle {
        anchors { left: parent.left; top: parent.top; margins: 12 }
        width: 300
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
                text: camera.model.length > 0 ? camera.model : "no data yet"
                color: "#e6e9ef"
                font { pixelSize: 15; bold: true }
            }
            Text {
                text: camera.geometry.length > 0 ? camera.geometry : "—"
                color: "#8b93a1"
                font.pixelSize: 12
            }
            Item { width: 1; height: 6 }

            Repeater {
                model: [
                    { k: "frames/s",      v: camera.framesPerSecond + "" },
                    { k: "no depth",      v: camera.holePercent + "%" },
                    { k: "frames missed", v: camera.framesMissed + "" }
                ]
                Row {
                    spacing: 8
                    Text {
                        text: modelData.k
                        color: "#8b93a1"
                        font.pixelSize: 12
                        width: 104
                    }
                    Text {
                        text: modelData.v
                        color: "#d7dce4"
                        font { pixelSize: 12; family: "Menlo" }
                    }
                }
            }

            Item { width: 1; height: 6 }
            // Coloured by whether the intrinsics came from the camera: a cloud built on
            // nominal ones is wrong in a way that looks entirely plausible, so the warning
            // has to be visible rather than merely present.
            Text {
                text: camera.calibration.length > 0 ? camera.calibration : "awaiting calibration"
                color: camera.calibration.indexOf("DEFAULTS") >= 0 ? "#d1a05a" : "#8b93a1"
                font.pixelSize: 11
                width: 276
                wrapMode: Text.Wrap
            }
            Text {
                text: camera.status
                color: camera.framesPerSecond > 0 ? "#5ad18c" : "#d1a05a"
                font.pixelSize: 11
                width: 276
                wrapMode: Text.Wrap
            }
        }
    }

    // ---- the depth scale --------------------------------------------------------------

    Row {
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom
                  bottomMargin: 14 }
        spacing: 10

        Text {
            text: "near"
            color: "#8b93a1"
            font.pixelSize: 11
            anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
            width: 220
            height: 9
            radius: 4.5
            anchors.verticalCenter: parent.verticalCenter
            // The same blue-to-red ramp the depth image uses, so the legend and the picture
            // agree by construction rather than by eye.
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.00; color: "#0000ff" }
                GradientStop { position: 0.25; color: "#00ffff" }
                GradientStop { position: 0.50; color: "#00ff00" }
                GradientStop { position: 0.75; color: "#ffff00" }
                GradientStop { position: 1.00; color: "#ff0000" }
            }
        }
        Text {
            text: "far"
            color: "#8b93a1"
            font.pixelSize: 11
            anchors.verticalCenter: parent.verticalCenter
        }
        Item { width: 8; height: 1 }
        Rectangle {
            width: 9; height: 9; radius: 4.5; color: "#3c141e"
            anchors.verticalCenter: parent.verticalCenter
            visible: holesToggle.checked
        }
        Text {
            text: "no depth"
            color: "#8b93a1"
            font.pixelSize: 11
            visible: holesToggle.checked
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // ---- controls ---------------------------------------------------------------------

    Row {
        anchors { right: parent.right; top: parent.top; margins: 12 }
        spacing: 12

        // A plain CheckBox with a separate label rather than a custom contentItem: the
        // native macOS style refuses contentItem customisation and warns about it, and a
        // demo should not open with a warning.
        Row {
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter
            CheckBox {
                id: holesToggle
                checked: true
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: "flag missing depth"
                color: "#8b93a1"
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        ComboBox {
            id: layoutBox
            width: 150
            anchors.verticalCenter: parent.verticalCenter
            // The order matches CameraView::Layout: side by side, depth, mono.
            model: ["mono + depth", "depth only", "mono only"]
        }
    }

    Text {
        anchors { left: parent.left; bottom: parent.bottom; margins: 12 }
        text: "left: the mono image as it arrives   right: depth, colourised over the camera's rated range"
        color: "#5c6474"
        font.pixelSize: 11
    }
}
