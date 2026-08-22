import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "lib/Sources.js" as Sources
import "lib/Format.js" as Fmt

// Right-click surface: sources, schedule, reading, and the cache controls.
//
// Everything here writes straight through to the widget's entry in shell.json
// via host.persist(), which is the single source of truth -- there is no
// separate settings file to drift out of sync with the bar. The service picks
// the change up through applySettings on the next binding pass.
KeyboardPanel {
  id: menu

  property var host: null
  readonly property var svc: host ? host.svc : null

  contentWidth: fittedContentWidth(Style.space(560) + verticalContentInset)
  // Tall on purpose: the form runs to roughly 900px and scrolling past the
  // cache controls to find them is worse than a tall popup. availableCardHeight
  // still clamps it on a short screen, where it scrolls as before.
  contentHeight: Math.min(availableCardHeight, Style.space(880))
  focusTarget: keys

  // Working copy of the source list. Edits are applied here and persisted on
  // every change, so the reader reflects an added feed immediately rather than
  // on the next restart.
  property var sourceList: []
  property string addError: ""
  property bool clearArmed: false

  onOpenChanged: {
    if (!open) { addError = ""; clearArmed = false; return }
    menu.sourceList = svc ? svc.sources.slice() : Sources.normalize(null)
    if (svc) svc.measureCache()
  }

  function commitSources(next) {
    menu.sourceList = Sources.normalize(next)
    if (host) host.persist("sources", Sources.toConfig(menu.sourceList))
  }

  function addFeed(rawUrl) {
    var check = Sources.validateUrl(rawUrl)
    if (!check.ok) { menu.addError = check.error; return false }
    var candidate = { type: "rss", url: check.url, label: "", enabled: true }
    var next = Sources.add(menu.sourceList, candidate)
    if (next.length === menu.sourceList.length) { menu.addError = "That feed is already in the list"; return false }
    menu.addError = ""
    menu.commitSources(next)
    // Fetch it now: an added feed that stays empty until the next scheduled
    // tick looks like it failed.
    if (svc) {
      var added = next[next.length - 1]
      Qt.callLater(function() { if (svc) svc.refreshSource(added.sid) })
    }
    return true
  }

  function addPreset(label) {
    for (var i = 0; i < Sources.PRESETS.length; i++) {
      var p = Sources.PRESETS[i]
      if (p.label !== label) continue
      var next = Sources.add(menu.sourceList, { type: p.type, url: p.url, feed: p.feed, label: p.label, enabled: true })
      if (next.length === menu.sourceList.length) { menu.addError = "“" + label + "” is already in the list"; return }
      menu.addError = ""
      menu.commitSources(next)
      if (svc) {
        var added = next[next.length - 1]
        Qt.callLater(function() { if (svc) svc.refreshSource(added.sid) })
      }
      return
    }
  }

  readonly property var presetLabels: {
    var out = []
    for (var i = 0; i < Sources.PRESETS.length; i++) out.push(Sources.PRESETS[i].label)
    return out
  }

  readonly property var stats: svc ? svc.stats : ({ total: 0, unread: 0, bookmarked: 0 })

  // Clamped so the form cannot be scrolled past either end into empty space.
  function scrollTo(y) {
    var max = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(max, y))
  }
  function scrollBy(delta) { menu.scrollTo(flick.contentY + delta) }

  Item {
    anchors.fill: parent

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      Keys.onEscapePressed: menu.close()

      // The form is taller than the panel on any short screen, and the
      // controls that get pushed below the fold are the cache ones -- the
      // section a user is most likely to have come here for. Without this the
      // only way down is a mouse wheel.
      Keys.onPressed: function(e) {
        var step = Style.space(60)
        if (e.key === Qt.Key_Down || e.key === Qt.Key_J) { menu.scrollBy(step); e.accepted = true }
        else if (e.key === Qt.Key_Up || e.key === Qt.Key_K) { menu.scrollBy(-step); e.accepted = true }
        else if (e.key === Qt.Key_PageDown) { menu.scrollBy(flick.height * 0.9); e.accepted = true }
        else if (e.key === Qt.Key_PageUp) { menu.scrollBy(-flick.height * 0.9); e.accepted = true }
        else if (e.key === Qt.Key_Home) { menu.scrollTo(0); e.accepted = true }
        else if (e.key === Qt.Key_End) { menu.scrollTo(flick.contentHeight); e.accepted = true }
      }
    }

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: form.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: form
        width: flick.width - Style.spacing.lg
        spacing: Style.spacing.xl

        // ---- header --------------------------------------------------------
        Row {
          width: parent.width
          spacing: Style.spacing.md

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(3)
            height: Style.space(14)
            color: Color.accent
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "NEWS"
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.letterSpacing: Style.space(2)
            font.weight: Font.DemiBold
            color: Color.foreground
            renderType: Text.NativeRendering
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "settings"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.foreground
            opacity: 0.45
            renderType: Text.NativeRendering
          }
        }

        // ---- sources -------------------------------------------------------
        PanelSectionHeader { width: parent.width; text: "SOURCES" }

        Column {
          width: parent.width
          spacing: Style.spacing.xxs

          Repeater {
            model: menu.sourceList

            Rectangle {
              required property var modelData
              required property int index

              width: parent.width
              height: Style.space(30)
              radius: Style.cornerRadius
              color: rowMouse.containsMouse ? Style.hoverFill : "transparent"

              readonly property var st: menu.svc ? menu.svc.statusFor(modelData.sid) : null
              readonly property bool disabledSource: modelData.enabled === false

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.sm
                anchors.rightMargin: Style.spacing.sm
                spacing: Style.spacing.md

                // Enabled is a toggle rather than a delete, because muting a
                // noisy feed for a week is a different intent from dropping it
                // and losing its place in the order.
                ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: modelData.enabled !== false
                  onToggled: menu.commitSources(Sources.setEnabled(menu.sourceList, index, modelData.enabled === false))
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(190)
                  spacing: 0

                  Text {
                    width: parent.width
                    text: modelData.label
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    color: Color.foreground
                    opacity: disabledSource ? 0.45 : 1.0
                    elide: Text.ElideRight
                    renderType: Text.NativeRendering
                  }

                  Text {
                    width: parent.width
                    text: {
                      if (modelData.type === "hn") return "news.ycombinator.com · " + modelData.feed.replace(/_/g, " ")
                      var line = Fmt.domainOf(modelData.url)
                      if (st && st.state === "error") return line + " · " + st.message
                      if (st && st.state === "offline") return line + " · unreachable"
                      if (st && st.count > 0) return line + " · " + st.count + " stories"
                      return line
                    }
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: (st && (st.state === "error" || st.state === "offline")) ? Color.urgent : Color.foreground
                    opacity: (st && (st.state === "error" || st.state === "offline")) ? 0.85 : 0.4
                    elide: Text.ElideRight
                    renderType: Text.NativeRendering
                  }
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Fetch this feed now"
                  size: Style.space(20)
                  fontSize: Style.font.caption
                  enabled: menu.svc !== null && !menu.svc.pauseNetwork
                  onClicked: if (menu.svc) menu.svc.refreshSource(modelData.sid)
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Move up"
                  size: Style.space(20)
                  fontSize: Style.font.caption
                  enabled: index > 0
                  onClicked: menu.commitSources(Sources.move(menu.sourceList, index, index - 1))
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Move down"
                  size: Style.space(20)
                  fontSize: Style.font.caption
                  enabled: index < menu.sourceList.length - 1
                  onClicked: menu.commitSources(Sources.move(menu.sourceList, index, index + 1))
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Remove this source. Bookmarked stories from it are kept."
                  size: Style.space(20)
                  fontSize: Style.font.caption
                  hoverColor: Color.urgent
                  onClicked: menu.commitSources(Sources.removeAt(menu.sourceList, index))
                }
              }
            }
          }
        }

        // ---- add a feed -----------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.spacing.sm

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            TextField {
              id: urlField
              width: parent.width - addButton.width - parent.spacing
              placeholderText: "Paste an RSS or Atom feed URL"
              onAccepted: if (menu.addFeed(text)) text = ""
              onTextChanged: menu.addError = ""
            }

            Button {
              id: addButton
              text: "Add"
              bordered: true
              onClicked: if (menu.addFeed(urlField.text)) urlField.text = ""
            }
          }

          Text {
            width: parent.width
            visible: menu.addError !== ""
            text: menu.addError
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.urgent
            wrapMode: Text.WordWrap
            renderType: Text.NativeRendering
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "or add a known one"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: Color.foreground
              opacity: 0.4
              renderType: Text.NativeRendering
            }

            Dropdown {
              anchors.verticalCenter: parent.verticalCenter
              showLabel: false
              value: ""
              options: menu.presetLabels
              onChanged: function(v) { if (v) { menu.addPreset(v); value = "" } }
            }
          }
        }

        PanelSeparator { width: parent.width }

        // ---- schedule --------------------------------------------------------
        PanelSectionHeader { width: parent.width; text: "REFRESH" }

        Row {
          width: parent.width
          spacing: Style.spacing.lg

          NumberField {
            anchors.verticalCenter: parent.verticalCenter
            label: "Every (minutes)"
            value: menu.host ? menu.host.setting("refreshMinutes", 30) : 30
            from: 5; to: 1440; stepSize: 5
            onModified: function(v) { if (menu.host) menu.host.persist("refreshMinutes", v) }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: {
              if (!menu.svc) return ""
              if (menu.svc.pauseNetwork) return "paused"
              if (!menu.svc.nextRefreshMs) return "first fetch pending"
              var due = menu.svc.nextRefreshMs - Date.now()
              if (due <= 0) return "due now"
              return "next in " + Fmt.relTime(Date.now() - due, Date.now())
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.foreground
            opacity: 0.4
            renderType: Text.NativeRendering
          }
        }

        Toggle {
          width: parent.width
          label: "Cache only"
          description: "A real kill switch: nothing leaves this machine, and the reader keeps working from disk."
          checked: menu.host ? menu.host.setting("pauseNetwork", false) : false
          onClicked: if (menu.host) menu.host.persist("pauseNetwork", !menu.host.setting("pauseNetwork", false))
        }

        PanelSeparator { width: parent.width }

        // ---- reading ---------------------------------------------------------
        PanelSectionHeader { width: parent.width; text: "READING" }

        Row {
          width: parent.width
          spacing: Style.spacing.lg

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Bar shows"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: Color.foreground
            renderType: Text.NativeRendering
          }

          ButtonGroup {
            anchors.verticalCenter: parent.verticalCenter
            options: ["headline", "count", "icon"]
            value: menu.host ? menu.host.setting("barMode", "headline") : "headline"
            onChanged: function(v) { if (menu.host) menu.host.persist("barMode", v) }
          }

          NumberField {
            anchors.verticalCenter: parent.verticalCenter
            visible: (menu.host ? menu.host.setting("barMode", "headline") : "headline") === "headline"
            label: "rotate (s)"
            value: menu.host ? menu.host.setting("rotateSeconds", 12) : 12
            from: 4; to: 120; stepSize: 1
            onModified: function(v) { if (menu.host) menu.host.persist("rotateSeconds", v) }
          }
        }

        Toggle {
          width: parent.width
          label: "Show artwork in cards"
          description: "Off gives a dense, text-only list. Pictures already on disk are kept, not deleted."
          checked: menu.host ? menu.host.setting("showMedia", true) : true
          onClicked: if (menu.host) menu.host.persist("showMedia", !menu.host.setting("showMedia", true))
        }

        Toggle {
          width: parent.width
          label: "Fetch missing artwork"
          description: "When a feed ships no picture, read the article page's OpenGraph tags to find one. This contacts the publisher directly."
          checked: menu.host ? menu.host.setting("fetchArtwork", true) : true
          onClicked: if (menu.host) menu.host.persist("fetchArtwork", !menu.host.setting("fetchArtwork", true))
        }

        Toggle {
          width: parent.width
          label: "Mark read when opened"
          description: "Off keeps the unread count entirely under your own control."
          checked: menu.host ? menu.host.setting("markReadOnOpen", true) : true
          onClicked: if (menu.host) menu.host.persist("markReadOnOpen", !menu.host.setting("markReadOnOpen", true))
        }

        PanelSeparator { width: parent.width }

        // ---- cache ------------------------------------------------------------
        PanelSectionHeader { width: parent.width; text: "CACHE" }

        Row {
          width: parent.width
          spacing: Style.spacing.lg

          NumberField {
            anchors.verticalCenter: parent.verticalCenter
            label: "Keep for (days)"
            value: menu.host ? menu.host.setting("retentionDays", 7) : 7
            from: 1; to: 90; stepSize: 1
            onModified: function(v) { if (menu.host) menu.host.persist("retentionDays", v) }
          }

          NumberField {
            anchors.verticalCenter: parent.verticalCenter
            label: "Per source"
            value: menu.host ? menu.host.setting("maxPerSource", 40) : 40
            from: 10; to: 200; stepSize: 10
            onModified: function(v) { if (menu.host) menu.host.persist("maxPerSource", v) }
          }
        }

        Text {
          width: parent.width
          text: {
            if (!menu.svc) return ""
            var bits = []
            bits.push(menu.stats.total + " stories")
            bits.push(menu.stats.bookmarked + " bookmarked")
            bits.push(Fmt.bytes(menu.svc.cacheBytes) + " of artwork")
            return bits.join("  ·  ")
          }
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.foreground
          opacity: 0.45
          renderType: Text.NativeRendering
        }

        // The promise, stated where the destructive buttons are, because this
        // is the moment a user needs to read it.
        Text {
          width: parent.width
          text: "Bookmarks are never removed by either button, at any age."
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.accent
          opacity: 0.7
          wrapMode: Text.WordWrap
          renderType: Text.NativeRendering
        }

        Row {
          width: parent.width
          spacing: Style.spacing.sm

          Button {
            text: "Clean up now"
            iconText: ""
            bordered: true
            tooltipText: "Apply the retention window and the per-source cap, and delete artwork nothing points at any more."
            onClicked: if (menu.svc) { menu.svc.cleanup(true); menu.clearArmed = false }
          }

          // Two-step rather than a dialog: the second press is the confirmation,
          // and the label says exactly what is about to happen.
          Button {
            text: menu.clearArmed ? "Really clear? Press again" : "Clear all but bookmarks"
            iconText: menu.clearArmed ? "" : ""
            bordered: true
            foreground: menu.clearArmed ? Color.urgent : Color.foreground
            onClicked: {
              if (!menu.svc) return
              if (!menu.clearArmed) { menu.clearArmed = true; disarm.restart(); return }
              menu.svc.clearCache()
              menu.clearArmed = false
            }
          }
        }

        Timer {
          id: disarm
          interval: 4000
          onTriggered: menu.clearArmed = false
        }

        PanelSeparator { width: parent.width }

        // ---- placement ---------------------------------------------------------
        Row {
          width: parent.width
          spacing: Style.spacing.lg

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Bar section"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: Color.foreground
            renderType: Text.NativeRendering
          }

          ButtonGroup {
            anchors.verticalCenter: parent.verticalCenter
            options: ["left", "center", "right"]
            value: menu.host ? menu.host.currentSection() : ""
            onChanged: function(v) { if (menu.host) menu.host.moveToSection(v) }
          }
        }

        Text {
          width: parent.width
          text: "In the reader:  j k move  ·  enter opens  ·  c discussion  ·  b bookmark  ·  y copy link  ·  u unread only  ·  / filter  ·  tab source  ·  r refresh"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.foreground
          opacity: 0.35
          wrapMode: Text.WordWrap
          renderType: Text.NativeRendering
          bottomPadding: Style.spacing.md
        }
      }
    }
  }
}
