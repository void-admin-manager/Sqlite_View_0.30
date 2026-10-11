import QtQuick

Rectangle {
    id: control

    property string text: ""
    property string tone: "neutral"
    property bool danger: false
    readonly property bool hovered: buttonArea.containsMouse
    readonly property bool pressed: buttonArea.pressed

    signal clicked()

    readonly property bool isDangerOutline: danger && !filled

    readonly property color toneColor: {
        switch (tone) {
        case "primary": return "#2f6fd0"
        case "success": return "#1a8a3c"
        case "danger":  return "#d9363e"
        case "neutral": return "#ffffff"
        default:        return "#ffffff" // outline
        }
    }
    readonly property color toneHover: {
        switch (tone) {
        case "primary": return "#3d7ddc"
        case "success": return "#21a04a"
        case "danger":  return "#e34b52"
        case "neutral": return "#f2f5f9"
        default:        return isDangerOutline ? "#fdf1f2" : "#f2f5f9" // outline
        }
    }
    readonly property color toneDown: {
        switch (tone) {
        case "primary": return "#2a62ba"
        case "success": return "#15762f"
        case "danger":  return "#bd2b32"
        case "neutral": return "#e4e8ee"
        default:        return isDangerOutline ? "#f9dfe1" : "#e4e8ee" // outline
        }
    }
    readonly property bool filled: tone === "primary" || tone === "success" || tone === "danger"

    implicitWidth: labelText.implicitWidth + 26
    implicitHeight: 30
    radius: 6

    border.width: filled ? 0 : 1
    border.color: isDangerOutline
                  ? (hovered ? "#e0898e" : "#edb9bc")
                  : (hovered ? "#b9bfc8" : "#d7dade")

    color: !enabled ? "#f0f2f5"
                    : (pressed ? toneDown : (hovered ? toneHover : toneColor))
    opacity: enabled ? 1.0 : 0.7

    Text {
        id: labelText

        anchors.centerIn: parent
        text: control.text
        font.pixelSize: 12
        font.weight: control.filled ? Font.DemiBold : Font.Medium
        color: !control.enabled ? "#a8adb5"
                                : (control.isDangerOutline ? "#c62f37"
                                  : control.filled ? "#ffffff" : "#3b4250")
    }

    MouseArea {
        id: buttonArea

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: control.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled: control.enabled
        onClicked: control.clicked()
    }
}
