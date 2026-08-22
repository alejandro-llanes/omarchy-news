import QtQuick
import qs.Commons
import qs.Ui
import "../lib/Format.js" as Fmt

// One story. Collapsed it is a headline with a thumbnail; focused it grows to
// show the picture larger, the standfirst, and the actions.
//
// The card expands in place rather than opening a second surface, so the list
// never jumps under the cursor and the keyboard and the mouse drive exactly the
// same thing.
Rectangle {
  id: root

  property var story: null
  property bool expanded: false
  property bool hasCursor: false
  property bool showMedia: true
  property int cardIndex: 0

  signal activated()
  signal commentsRequested()
  signal bookmarkToggled()
  signal copyRequested()
  signal focusRequested()

  readonly property bool unread: story ? story.read !== true : false
  readonly property bool bookmarked: story ? story.bookmarked === true : false
  readonly property bool hot: hasCursor || mouse.containsMouse
  readonly property bool hasComments: story ? !!story.comments : false
  readonly property bool hasPoints: story ? (Number(story.points) || 0) > 0 : false
  readonly property bool hasSummary: story ? Fmt.collapse(story.summary || "").length > 0 : false

  readonly property int thumbWidth: expanded ? Style.space(196) : Style.space(96)
  readonly property int thumbHeight: expanded ? Style.space(124) : Style.space(62)

  width: parent ? parent.width : 0
  implicitHeight: body.implicitHeight + Style.spacing.md * 2
  height: implicitHeight
  radius: Style.cornerRadius
  color: expanded ? Style.selectedFill : (hot ? Style.hoverFill : "transparent")
  Behavior on color { ColorAnimation { duration: 120 } }
  Behavior on height { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

  // Unread marker: a rule on the leading edge rather than a dot, because it
  // also reads as the focus indicator when the card is the current one.
  Rectangle {
    id: rule
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Math.max(1, Style.space(root.expanded ? 3 : 2))
    radius: width / 2
    visible: root.unread || root.expanded
    color: root.expanded ? Color.accent : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5)
    Behavior on width { NumberAnimation { duration: 140 } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    onEntered: root.focusRequested()
    onClicked: function(e) {
      if (e.button === Qt.MiddleButton) root.bookmarkToggled()
      else if (e.button === Qt.RightButton) root.commentsRequested()
      else if (root.expanded) root.activated()
      else root.focusRequested()
    }
    onDoubleClicked: root.activated()
  }

  Row {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: Style.spacing.xl
    anchors.rightMargin: Style.spacing.lg
    anchors.topMargin: Style.spacing.md
    spacing: Style.spacing.xl

    MediaFrame {
      id: art
      story: root.story
      showMedia: root.showMedia
      compact: !root.expanded
      width: root.showMedia ? root.thumbWidth : 0
      height: root.showMedia ? root.thumbHeight : 0
      visible: root.showMedia
      opacity: root.unread || root.expanded ? 1.0 : 0.72

      Behavior on width { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
    }

    Column {
      id: content
      width: parent.width - (root.showMedia ? art.width + parent.spacing : 0) - saveColumn.width - parent.spacing
      spacing: Style.spacing.xs

      Text {
        id: headline
        width: parent.width
        text: root.story ? root.story.title : ""
        font.family: Style.font.family
        font.pixelSize: root.expanded ? Style.font.subtitle : Style.font.body
        font.weight: root.unread ? Font.DemiBold : Font.Normal
        color: Color.foreground
        opacity: root.unread || root.expanded ? 1.0 : 0.62
        wrapMode: Text.WordWrap
        maximumLineCount: root.expanded ? 3 : 2
        elide: Text.ElideRight
        renderType: Text.NativeRendering
      }

      // Provenance line. Every piece is optional, because feeds vary wildly in
      // what they bother to say -- Lobsters has no points, the BBC has no
      // author, a bare Atom feed may have neither.
      Row {
        width: parent.width
        spacing: Style.spacing.md

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.story ? (root.story.domain || "") : ""
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.foreground
          opacity: 0.55
          elide: Text.ElideRight
          renderType: Text.NativeRendering
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: text !== ""
          text: root.story && root.story.hasDate ? Fmt.relTime(root.story.publishedMs, root.now) : ""
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.foreground
          opacity: 0.45
          renderType: Text.NativeRendering
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: root.hasPoints
          text: "▲ " + Fmt.count(root.story ? root.story.points : 0)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.accent
          opacity: 0.85
          renderType: Text.NativeRendering
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: root.story && (Number(root.story.commentCount) || 0) > 0
          text: Fmt.count(root.story ? root.story.commentCount : 0) + " comments"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.foreground
          opacity: 0.45
          renderType: Text.NativeRendering
        }
      }

      // Standfirst, focused cards only. Height is animated from zero so the
      // list settles instead of snapping.
      Text {
        width: parent.width
        visible: root.expanded && root.hasSummary
        text: root.story ? Fmt.truncate(root.story.summary, 220) : ""
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: Color.foreground
        opacity: 0.6
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
        renderType: Text.NativeRendering
        topPadding: Style.spacing.xxs
      }

      Row {
        visible: root.expanded
        spacing: Style.spacing.sm
        topPadding: Style.spacing.xs

        Button {
          text: "Open"
          iconText: ""
          fontSize: Style.font.caption
          iconSize: Style.font.caption
          verticalPadding: Style.spacing.xs
          bordered: true
          onClicked: root.activated()
        }

        Button {
          visible: root.hasComments
          text: "Discussion"
          iconText: ""
          fontSize: Style.font.caption
          iconSize: Style.font.caption
          verticalPadding: Style.spacing.xs
          bordered: true
          onClicked: root.commentsRequested()
        }

        Button {
          text: root.bookmarked ? "Saved" : "Save"
          iconText: root.bookmarked ? "" : ""
          fontSize: Style.font.caption
          iconSize: Style.font.caption
          verticalPadding: Style.spacing.xs
          bordered: true
          selected: root.bookmarked
          onClicked: root.bookmarkToggled()
        }

        Button {
          text: "Copy link"
          iconText: ""
          fontSize: Style.font.caption
          iconSize: Style.font.caption
          verticalPadding: Style.spacing.xs
          bordered: true
          onClicked: root.copyRequested()
        }
      }
    }

    // The star holds its column whether or not it is showing, so headlines do
    // not reflow as the cursor moves down the list.
    Item {
      id: saveColumn
      width: Style.space(22)
      height: Style.space(22)

      PanelActionButton {
        anchors.centerIn: parent
        visible: root.bookmarked || root.hot || root.expanded
        iconText: root.bookmarked ? "" : ""
        fontSize: Style.font.bodySmall
        size: Style.space(20)
        foreground: root.bookmarked ? Color.accent : Color.foreground
        opacity: root.bookmarked ? 1.0 : 0.5
        tooltipText: root.bookmarked ? "Remove bookmark" : "Bookmark"
        onClicked: root.bookmarkToggled()
      }
    }
  }

  // Passed down so every card in the list ages against one clock reading
  // rather than each calling Date.now() on its own.
  property real now: 0
}
