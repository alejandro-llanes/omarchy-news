import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "components"
import "lib/Store.js" as Store
import "lib/Format.js" as Fmt

// The reader. KeyboardPanel rather than PopupCard because this wants Esc, j/k,
// a search field and Tab between sources; PopupCard is an xdg-popup and never
// takes keyboard focus.
//
// It never fetches on open. The schedule owns refreshing; opening the reader
// five times in a lunch break should not poll five publishers five times.
KeyboardPanel {
  id: panel

  property var host: null
  readonly property var svc: host ? host.svc : null

  property string sourceFilter: ""       // "" = everything, or a sid, or the bookmarks view
  property bool unreadOnly: false
  property string query: ""
  property bool searching: false
  property int cursor: 0

  // One clock reading per repaint cycle, handed to every card, instead of
  // each of forty cards calling Date.now() in its own binding.
  property real now: Date.now()

  contentWidth: fittedContentWidth(Style.space(760) + verticalContentInset)
  contentHeight: Math.min(availableCardHeight, Style.space(600))
  centerOnBar: true
  focusTarget: keys

  readonly property var stories: svc ? svc.viewFor(sourceFilter, unreadOnly, query) : []
  readonly property var current: (stories.length && cursor >= 0 && cursor < stories.length) ? stories[cursor] : null
  readonly property var stats: svc ? svc.stats : ({ total: 0, unread: 0, bookmarked: 0, bySource: {} })

  onOpenChanged: {
    if (!open) return
    panel.now = Date.now()
    panel.cursor = 0
    list.positionViewAtBeginning()
    clockTimer.restart()
  }

  function step(delta) {
    if (!stories.length) return
    var next = cursor + delta
    if (next < 0) next = 0
    if (next > stories.length - 1) next = stories.length - 1
    cursor = next
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  function jumpTo(index) {
    if (index < 0 || index >= stories.length) return
    cursor = index
  }

  function openCurrent() {
    if (!current || !svc) return
    svc.openItem(current.id)
    panel.close()
  }

  function commentsForCurrent() {
    if (!current || !svc || !current.comments) return
    svc.openComments(current.id)
    panel.close()
  }

  function bookmarkCurrent() {
    if (!current || !svc) return
    svc.toggleBookmark(current.id)
  }

  function copyCurrent() {
    if (!current || !svc) return
    svc.copyLink(current.id)
  }

  // Tab walks the rail: everything, then each source in configured order, then
  // the saved view, then back round.
  function railKeys() {
    var out = [""]
    var list2 = svc ? svc.sources : []
    for (var i = 0; i < list2.length; i++) out.push(list2[i].sid)
    out.push(Store.BOOKMARKS_VIEW)
    return out
  }

  function cycleSource(direction) {
    var keys = railKeys()
    var at = keys.indexOf(panel.sourceFilter)
    if (at === -1) at = 0
    var next = (at + direction + keys.length) % keys.length
    panel.setFilter(keys[next])
  }

  function setFilter(sid) {
    panel.sourceFilter = sid
    panel.cursor = 0
    list.positionViewAtBeginning()
  }

  function beginSearch() {
    panel.searching = true
    searchField.forceActiveFocus()
  }

  function endSearch(clear) {
    if (clear) { panel.query = ""; searchField.text = "" }
    panel.searching = false
    panel.cursor = 0
    keys.forceActiveFocus()
  }

  Item {
    anchors.fill: parent

    // Relative timestamps go stale while the panel sits open. A minute is the
    // resolution the labels are written at, so a minute is how often they move.
    // Lives inside this Item, not at the panel's top level: KeyboardPanel's
    // default property is a list<Item>, so a bare Timer there fails to assign
    // and the whole panel refuses to load.
    Timer {
      id: clockTimer
      interval: 60000
      repeat: true
      running: panel.open
      onTriggered: panel.now = Date.now()
    }

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      Keys.onEscapePressed: {
        if (panel.searching || panel.query !== "") panel.endSearch(true)
        else panel.close()
      }
      Keys.onPressed: function(e) {
        if (e.key === Qt.Key_J || e.key === Qt.Key_Down) { panel.step(1); e.accepted = true }
        else if (e.key === Qt.Key_K || e.key === Qt.Key_Up) { panel.step(-1); e.accepted = true }
        else if (e.key === Qt.Key_PageDown) { panel.step(6); e.accepted = true }
        else if (e.key === Qt.Key_PageUp) { panel.step(-6); e.accepted = true }
        else if (e.key === Qt.Key_Home || e.key === Qt.Key_G && (e.modifiers & Qt.ShiftModifier) === 0) { panel.jumpTo(0); list.positionViewAtBeginning(); e.accepted = true }
        else if (e.key === Qt.Key_End || (e.key === Qt.Key_G && (e.modifiers & Qt.ShiftModifier))) { panel.jumpTo(panel.stories.length - 1); list.positionViewAtEnd(); e.accepted = true }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_O) { panel.openCurrent(); e.accepted = true }
        else if (e.key === Qt.Key_C) { panel.commentsForCurrent(); e.accepted = true }
        else if (e.key === Qt.Key_B || e.key === Qt.Key_S) { panel.bookmarkCurrent(); e.accepted = true }
        else if (e.key === Qt.Key_Y) { panel.copyCurrent(); e.accepted = true }
        else if (e.key === Qt.Key_R) { if (panel.svc) panel.svc.refreshAll(true); e.accepted = true }
        else if (e.key === Qt.Key_U) { panel.unreadOnly = !panel.unreadOnly; panel.cursor = 0; e.accepted = true }
        else if (e.key === Qt.Key_A && (e.modifiers & Qt.ShiftModifier)) { if (panel.svc) panel.svc.markAllRead(panel.sourceFilter === Store.BOOKMARKS_VIEW ? "" : panel.sourceFilter); e.accepted = true }
        else if (e.key === Qt.Key_Slash) { panel.beginSearch(); e.accepted = true }
        else if (e.key === Qt.Key_Tab) { panel.cycleSource(1); e.accepted = true }
        else if (e.key === Qt.Key_Backtab) { panel.cycleSource(-1); e.accepted = true }
        else if (e.key === Qt.Key_Comma) { panel.close(); if (panel.host) panel.host.openConfig(); e.accepted = true }
      }
    }

    Column {
      anchors.fill: parent
      spacing: Style.spacing.lg

      // ---- masthead --------------------------------------------------------
      Item {
        id: mastheadBox
        width: parent.width
        height: masthead.implicitHeight

        Row {
          id: masthead
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.lg

          // A solid accent block, sized to the cap height of the wordmark. The
          // only piece of pure decoration in the panel, and it earns its place
          // by giving the eye somewhere to start.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(3)
            height: Style.space(15)
            color: Color.accent
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "NEWS"
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.letterSpacing: Style.space(3)
            font.weight: Font.DemiBold
            color: Color.foreground
            renderType: Text.NativeRendering
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: panel.stats.unread > 0
            text: panel.stats.unread + " unread"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.accent
            opacity: 0.8
            renderType: Text.NativeRendering
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: panel.svc && panel.svc.pauseNetwork
            text: "· cache only"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.foreground
            opacity: 0.45
            renderType: Text.NativeRendering
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xs

          TextField {
            id: searchField
            anchors.verticalCenter: parent.verticalCenter
            visible: panel.searching || panel.query !== ""
            width: visible ? Style.space(190) : 0
            placeholderText: "Filter headlines"
            text: panel.query
            onTextChanged: { panel.query = text; panel.cursor = 0 }
            Keys.onEscapePressed: panel.endSearch(true)
            Keys.onReturnPressed: { panel.searching = false; keys.forceActiveFocus() }
            Keys.onDownPressed: { panel.searching = false; keys.forceActiveFocus(); panel.step(1) }
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: "Filter headlines  /"
            onClicked: panel.searching ? panel.endSearch(true) : panel.beginSearch()
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: panel.unreadOnly ? "Showing unread only  u" : "Show unread only  u"
            foreground: panel.unreadOnly ? Color.accent : Color.foreground
            onClicked: { panel.unreadOnly = !panel.unreadOnly; panel.cursor = 0 }
          }

          PanelActionButton {
            id: refreshButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: panel.svc && panel.svc.refreshing ? "Refreshing…" : "Refresh now  r"
            enabled: panel.svc !== null && !panel.svc.pauseNetwork
            onClicked: if (panel.svc) panel.svc.refreshAll(true)

            // PanelActionButton has no spin of its own and no documented handle
            // on its glyph child, so the refreshing state is shown by pulsing
            // the button rather than by reaching into its internals.
            SequentialAnimation on opacity {
              running: panel.open && panel.svc !== null && panel.svc.refreshing === true
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.35; duration: 620; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.35; to: 1.0; duration: 620; easing.type: Easing.InOutSine }
            }
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: "Sources and settings  ,"
            onClicked: { panel.close(); if (panel.host) panel.host.openConfig() }
          }
        }
      }

      // ---- source rail -----------------------------------------------------
      Flickable {
        id: railBox
        width: parent.width
        height: Style.space(26)
        contentWidth: rail.implicitWidth
        flickableDirection: Flickable.HorizontalFlick
        clip: true

        Row {
          id: rail
          spacing: Style.spacing.sm

          SourceChip {
            label: "All"
            count: panel.stats.unread
            active: panel.sourceFilter === ""
            onClicked: panel.setFilter("")
          }

          Repeater {
            model: panel.svc ? panel.svc.sources : []

            SourceChip {
              required property var modelData
              readonly property var st: panel.svc ? panel.svc.statusFor(modelData.sid) : null
              label: modelData.label
              count: panel.stats.bySource[modelData.sid] ? panel.stats.bySource[modelData.sid].unread : 0
              active: panel.sourceFilter === modelData.sid
              feedState: st ? st.state : ""
              onClicked: panel.setFilter(modelData.sid)
              // Right-click refetches just this one, which is the natural
              // thing to want when its dot is red.
              onSecondaryClicked: if (panel.svc) panel.svc.refreshSource(modelData.sid)
            }
          }

          SourceChip {
            label: "Saved"
            iconText: ""
            count: panel.stats.bookmarked
            active: panel.sourceFilter === Store.BOOKMARKS_VIEW
            onClicked: panel.setFilter(Store.BOOKMARKS_VIEW)
          }
        }
      }

      PanelSeparator { id: sep; width: parent.width }

      // ---- stories ---------------------------------------------------------
      // The list takes whatever the fixed rows leave. Stated as an explicit
      // subtraction of named siblings so adding a row cannot silently push the
      // last story under the footer.
      Item {
        id: listBox
        width: parent.width
        height: Math.max(Style.space(80),
                         parent.height - mastheadBox.height - railBox.height - sep.height
                         - footer.height - Style.spacing.lg * 4)

        ListView {
          id: list
          anchors.fill: parent
          model: panel.stories
          clip: true
          spacing: Style.spacing.xxs
          currentIndex: panel.cursor
          visible: panel.stories.length > 0
          boundsBehavior: Flickable.StopAtBounds
          cacheBuffer: Style.space(400)
          reuseItems: true

          delegate: NewsCard {
            required property var modelData
            required property int index
            width: list.width
            story: modelData
            cardIndex: index
            expanded: index === panel.cursor
            showMedia: panel.host ? panel.host.showMedia : true
            now: panel.now
            onFocusRequested: panel.jumpTo(index)
            onActivated: { panel.jumpTo(index); panel.openCurrent() }
            onCommentsRequested: { panel.jumpTo(index); panel.commentsForCurrent() }
            onBookmarkToggled: if (panel.svc) panel.svc.toggleBookmark(modelData.id)
            onCopyRequested: if (panel.svc) panel.svc.copyLink(modelData.id)
          }

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        }

        // ---- empty states --------------------------------------------------
        // Four different nothings, and telling them apart is most of the value:
        // a cold start, a filter with no hits, an empty saved list, and every
        // source failing are four different things for the user to do next.
        Column {
          anchors.centerIn: parent
          width: parent.width * 0.8
          spacing: Style.spacing.md
          visible: panel.stories.length === 0

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: {
              if (!panel.svc || panel.svc.refreshing) return ""
              if (panel.query !== "") return ""
              if (panel.sourceFilter === Store.BOOKMARKS_VIEW) return ""
              if (panel.unreadOnly && panel.stats.total > 0) return ""
              return ""
            }
            font.family: Style.font.family
            font.pixelSize: Style.fontPx(2.2)
            color: Color.foreground
            opacity: 0.25
            renderType: Text.NativeRendering
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: {
              if (!panel.svc) return "Starting up…"
              if (panel.svc.refreshing) return "Fetching the news…"
              if (panel.query !== "") return "Nothing matches “" + panel.query + "”"
              if (panel.sourceFilter === Store.BOOKMARKS_VIEW) return "Nothing saved yet"
              if (panel.unreadOnly && panel.stats.total > 0) return "All caught up"
              if (panel.svc.pauseNetwork) return "Cache-only mode is on, and the cache is empty"
              return "No stories yet"
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            color: Color.foreground
            opacity: 0.7
            wrapMode: Text.WordWrap
            renderType: Text.NativeRendering
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: text !== ""
            text: {
              if (!panel.svc || panel.svc.refreshing) return ""
              if (panel.query !== "") return "Esc clears the filter"
              if (panel.sourceFilter === Store.BOOKMARKS_VIEW) return "Press b on any story to keep it here. Bookmarks survive every cleanup."
              if (panel.unreadOnly) return "Press u to show everything again"
              if (panel.svc.pauseNetwork) return "Turn it off in settings to fetch again"
              // The honest case: sources exist and none of them worked.
              var broken = panel.brokenSources()
              if (broken.length) return broken.join("\n")
              return "Press r to fetch now"
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.foreground
            opacity: 0.45
            wrapMode: Text.WordWrap
            renderType: Text.NativeRendering
          }
        }
      }

      // ---- footer ----------------------------------------------------------
      Item {
        id: footer
        width: parent.width
        height: footerRow.implicitHeight

        Row {
          id: footerRow
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: {
              if (!panel.svc) return ""
              var bits = []
              bits.push(panel.stories.length + (panel.stories.length === 1 ? " story" : " stories"))
              if (panel.stats.bookmarked > 0) bits.push(panel.stats.bookmarked + " saved")
              if (panel.svc.cacheBytes > 0) bits.push(Fmt.bytes(panel.svc.cacheBytes) + " of artwork")
              return bits.join("  ·  ")
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.foreground
            opacity: 0.4
            renderType: Text.NativeRendering
          }
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: {
            if (!panel.svc) return ""
            if (panel.svc.refreshing) return "refreshing…"
            if (!panel.svc.lastRefreshMs) return "not fetched yet"
            return "updated " + Fmt.relTime(panel.svc.lastRefreshMs, panel.now) + " ago"
          }
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.foreground
          opacity: 0.4
          renderType: Text.NativeRendering
        }
      }
    }
  }

  // Sources whose last fetch failed, phrased for the empty state rather than
  // for a log file.
  function brokenSources() {
    if (!svc) return []
    var out = []
    for (var i = 0; i < svc.sources.length; i++) {
      var s = svc.sources[i]
      var st = svc.statusFor(s.sid)
      if (st && (st.state === "error" || st.state === "offline")) out.push(s.label + ": " + st.message)
    }
    return out
  }
}
