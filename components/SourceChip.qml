import QtQuick
import qs.Commons
import qs.Ui

// One entry in the filter rail. Carries three things at once: which source it
// is, how much unread sits behind it, and whether its last fetch worked --
// the last one as a dot rather than as words, because a rail of error messages
// would be unreadable at this size.
Rectangle {
  id: root

  property string label: ""
  property int count: 0
  property bool active: false
  property bool hasCursor: false
  // NOT named `state`: Item.state drives the QML state machine, and assigning
  // "fetching" to it would make Qt look for a State of that name.
  property string feedState: ""    // "" | fetching | ok | error | offline
  property string iconText: ""

  signal clicked()
  signal secondaryClicked()

  readonly property bool hot: hasCursor || mouse.containsMouse
  readonly property bool troubled: feedState === "error" || feedState === "offline"

  implicitWidth: row.implicitWidth + Style.spacing.rowPaddingX
  implicitHeight: Style.space(24)
  radius: Style.cornerRadius > 0 ? Style.cornerRadius : height / 2
  color: active ? Style.selectedAccentFill : (hot ? Style.hoverFill : Style.normalFill)
  border.width: active ? Style.selectedBorderWidth : (hot ? Style.hoverBorderWidth : 0)
  border.color: active ? Color.accent : Style.hoverBorderColor

  Behavior on color { ColorAnimation { duration: 120 } }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(e) {
      if (e.button === Qt.RightButton) root.secondaryClicked()
      else root.clicked()
    }
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.spacing.sm

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.iconText !== ""
      text: root.iconText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: root.active ? Color.accent : Color.foreground
      opacity: root.active ? 1.0 : 0.7
      renderType: Text.NativeRendering
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Color.foreground
      opacity: root.active ? 1.0 : (root.hot ? 0.85 : 0.6)
      renderType: Text.NativeRendering
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      visible: root.count > 0
      text: root.count > 99 ? "99+" : String(root.count)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: root.active ? Color.accent : Color.foreground
      opacity: root.active ? 0.9 : 0.45
      renderType: Text.NativeRendering
    }

    // Status, as one dot. Amber-ish is not available in a two-colour theme, so
    // trouble borrows the urgent role and a fetch in progress just pulses the
    // accent.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.feedState === "fetching" || root.troubled
      width: Style.space(5)
      height: width
      radius: width / 2
      color: root.troubled ? Color.urgent : Color.accent

      SequentialAnimation on opacity {
        running: root.feedState === "fetching"
        loops: Animation.Infinite
        NumberAnimation { from: 0.25; to: 1.0; duration: 620; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1.0; to: 0.25; duration: 620; easing.type: Easing.InOutSine }
      }
    }
  }
}
