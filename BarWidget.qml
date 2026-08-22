import QtQuick
import qs.Commons
import qs.Ui
import "lib/Format.js" as Fmt
import "lib/Store.js" as Store

// Pure view over the service. Never fetches: one of these exists per monitor,
// and a per-widget fetch would poll every publisher once per screen.
BarWidget {
  id: root
  moduleName: "io.github.alejandro-llanes.news"

  // shell._services is reassigned wholesale, so reading it in a binding
  // registers a dependency and this re-fires when the service instantiates.
  readonly property var svc: (bar && bar.shell && typeof bar.shell.serviceFor === "function")
                             ? bar.shell.serviceFor(moduleName) : null

  readonly property string barMode: setting("barMode", "headline")
  readonly property int rotateSeconds: Math.max(4, Math.min(120, setting("rotateSeconds", 12)))
  readonly property bool showMedia: setting("showMedia", true)
  readonly property string icon: setting("icon", "")

  readonly property int unread: svc ? svc.unreadCount : 0

  // The rotation walks unread stories only. A bar that cycles stories you have
  // already read is a screensaver, not a headline ticker.
  readonly property var ticker: svc ? svc.viewFor("", true, "") : []
  property int tickIndex: 0
  readonly property var headline: (ticker.length && tickIndex < ticker.length) ? ticker[tickIndex] : null

  // Long headlines have to be cut to something a bar can hold. The cut is
  // generous on a wide bar and tight on a narrow one.
  readonly property int headlineChars: {
    if (!bar || root.vertical) return 0
    var screenW = bar.screen ? bar.screen.width : 1920
    if (screenW >= 2560) return 64
    if (screenW >= 1920) return 48
    return 34
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Underline the readout rather than the padded slot. Explicitly NOT
  // button.labelWidth, which is 0 while labelVisible is false.
  readonly property real openPanelIndicatorWidth: row.implicitWidth

  Timer {
    id: rotateTimer
    interval: root.rotateSeconds * 1000
    repeat: true
    running: root.barMode === "headline" && root.ticker.length > 1 && !root.vertical
    onTriggered: root.tickIndex = root.ticker.length ? (root.tickIndex + 1) % root.ticker.length : 0
  }

  // The list shrinks as stories are read, so an index into it goes stale.
  onTickerChanged: if (tickIndex >= ticker.length) tickIndex = 0

  function togglePanel() {
    var p = ensurePanel()
    if (!p) return
    if (p.open) { p.open = false; return }
    if (configLoader.item) configLoader.item.open = false
    root.dataIdentity.popoutSwitchClosing = false
    p.open = true
  }

  // Right-clicking a second time closes the menu again, which is what every
  // other context menu on the desktop does.
  function openConfig() {
    var c = ensureConfig()
    if (!c) return
    if (c.open) { c.open = false; return }
    if (panelLoader.item) panelLoader.item.open = false
    root.configIdentity.popoutSwitchClosing = false
    c.open = true
  }

  function openBookmarks() {
    var p = ensurePanel()
    if (!p) return
    p.setFilter(Store.BOOKMARKS_VIEW)
    if (configLoader.item) configLoader.item.open = false
    root.dataIdentity.popoutSwitchClosing = false
    p.open = true
  }

  function requestRefresh() { if (svc) svc.refreshAll(true) }

  // Shape contract so shell.summon/hide/toggle can route to this widget.
  readonly property bool opened: panelLoader.item ? panelLoader.item.open === true : false
  function open() { var p = ensurePanel(); if (p) { root.dataIdentity.popoutSwitchClosing = false; p.open = true } }
  function close() { if (panelLoader.item) panelLoader.item.open = false }

  // Push bar-entry settings down into the singleton service once, from
  // whichever widget instance loads first; the service ignores redundant
  // applies.
  onSvcChanged: pushSettings()
  onSettingsChanged: pushSettings()
  function pushSettings() {
    if (!svc || typeof svc.applySettings !== "function") return
    // sources MUST be included: the service seeds itself with the shipped
    // default, so omitting them here would silently discard a configured list
    // on every shell restart.
    svc.applySettings({
      sources: setting("sources", null),
      refreshMinutes: setting("refreshMinutes", 30),
      retentionDays: setting("retentionDays", 7),
      maxPerSource: setting("maxPerSource", 40),
      fetchArtwork: setting("fetchArtwork", true),
      markReadOnOpen: setting("markReadOnOpen", true),
      pauseNetwork: setting("pauseNetwork", false)
    })
  }

  Connections {
    target: root.svc
    ignoreUnknownSignals: true
    function onOpenConfigRequested() { root.openConfig() }
    function onOpenPanelRequested() { root.togglePanel() }
    function onBookmarksRequested() { root.openBookmarks() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true                                  // else the widget is invisible
    fixedWidth: root.vertical ? -1 : row.implicitWidth + scaledHorizontalMargin * 2
    tooltipText: {
      if (!root.svc) return "News — starting"
      if (root.svc.pauseNetwork) return "News — cache only. Right-click to configure."
      var t = root.unread + (root.unread === 1 ? " unread story" : " unread stories")
      if (root.headline) t += "\n" + root.headline.title + "\n" + (root.headline.domain || "")
      if (root.svc.lastRefreshMs) t += "\nUpdated " + Fmt.relTime(root.svc.lastRefreshMs, Date.now()) + " ago"
      else t += "\nNot fetched yet"
      return t
    }

    Row {
      id: row
      anchors.centerIn: parent
      spacing: Style.space(6)
      visible: !root.vertical

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.icon
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        color: root.bar ? root.bar.barForeground : Color.foreground
        opacity: root.unread > 0 ? 1.0 : 0.7
        renderType: Text.NativeRendering
      }

      // Unread count. Present in headline and count modes; icon mode is the
      // quietest option the settings menu offers, and a number is not quiet.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.barMode !== "icon" && root.unread > 0
        text: root.unread > 99 ? "99+" : String(root.unread)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        color: root.bar ? root.bar.barForeground : Color.foreground
        renderType: Text.NativeRendering
      }

      Text {
        id: headlineText
        anchors.verticalCenter: parent.verticalCenter
        visible: root.barMode === "headline" && root.headline !== null && root.headlineChars > 0
        text: root.headline ? Fmt.truncate(root.headline.title, root.headlineChars) : ""
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        color: root.bar ? root.bar.barForeground : Color.foreground
        opacity: 0.8
        renderType: Text.NativeRendering

        // A crossfade on the text change, so a headline swap reads as a swap
        // and not as a flicker.
        Behavior on text {
          SequentialAnimation {
            NumberAnimation { target: headlineText; property: "opacity"; to: 0; duration: 130 }
            PropertyAction { target: headlineText; property: "text" }
            NumberAnimation { target: headlineText; property: "opacity"; to: 0.8; duration: 200 }
          }
        }
      }

      // Cache-only is a mode the user chose, so it is stated rather than
      // hidden -- otherwise a stale bar looks like a broken one.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.svc && root.svc.pauseNetwork
        text: "offline"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        color: root.bar ? root.bar.barForeground : Color.foreground
        opacity: 0.45
        renderType: Text.NativeRendering
      }
    }

    // Vertical bar: collapse to the icon rather than squeezing a headline
    // through a 28px column.
    Column {
      anchors.centerIn: parent
      visible: root.vertical
      spacing: Style.space(1)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.icon
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        color: root.bar ? root.bar.barForeground : Color.foreground
        renderType: Text.NativeRendering
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.barMode !== "icon" && root.unread > 0
        text: root.unread > 9 ? "9+" : String(root.unread)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        color: root.bar ? root.bar.barForeground : Color.foreground
        renderType: Text.NativeRendering
      }
    }

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton)       root.openConfig()
      else if (b === Qt.MiddleButton) root.requestRefresh()
      else                            root.togglePanel()
    }

    // Wheeling the bar readout only picks a different cached headline; it
    // costs nothing and never fetches.
    onWheelMoved: function(delta) {
      if (root.barMode !== "headline" || root.ticker.length < 2) return
      var n = root.ticker.length
      root.tickIndex = (root.tickIndex + (delta > 0 ? -1 : 1) + n) % n
      rotateTimer.restart()
    }
  }

  // ---- placement in the bar -------------------------------------------------
  // The widget is not told which section it is in, so read it back out of the
  // live config. Position IS the layout, so moving persists itself.
  function currentSection() {
    var cfg = bar && bar.shell ? bar.shell.shellConfig : null
    if (!cfg || !cfg.bar || !cfg.bar.layout) return ""
    var names = ["left", "center", "right"]
    for (var i = 0; i < names.length; i++) {
      var arr = cfg.bar.layout[names[i]] || []
      for (var j = 0; j < arr.length; j++) {
        if (arr[j] && String(arr[j].id) === moduleName) return names[i]
      }
    }
    return ""
  }

  function moveToSection(section) {
    if (!bar || !bar.shell || !bar.shell.pluginRegistry) return "no registry"
    if (section === currentSection()) return ""
    var err = bar.shell.pluginRegistry.moveBarWidget(moduleName, { section: section })
    if (err) console.warn("news: move to " + section + " failed: " + err)
    return err
  }

  // Read-modify-write through the host so a concurrent `omarchy bar set` is
  // not clobbered. A settings-only write does not rebuild the bar, so an open
  // panel survives it.
  function persist(key, value) {
    var entry = ({})
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function") {
      bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  // KeyboardPanel declares `bar` and `anchorItem` as REQUIRED properties,
  // which a Loader cannot satisfy from onLoaded -- required properties must
  // exist at construction. setSource() passes them as initial properties,
  // which is the only route that works here.
  //
  // Two DISTINCT popout owners. KeyboardPanel delegates its close() to `owner`
  // and uses `owner` as the bar's activePopout coordinator key, so sharing one
  // owner between both surfaces means dismissing the config menu runs the
  // reader's close() instead and the menu sticks open.
  property QtObject dataIdentity: QtObject {
    property bool popoutSwitchClosing: false
    function close() { if (panelLoader.item) panelLoader.item.open = false }
    function closeForPopoutSwitch() {
      popoutSwitchClosing = true
      if (panelLoader.item) panelLoader.item.open = false
    }
  }

  property QtObject configIdentity: QtObject {
    property bool popoutSwitchClosing: false
    function close() { if (configLoader.item) configLoader.item.open = false }
    function closeForPopoutSwitch() {
      popoutSwitchClosing = true
      if (configLoader.item) configLoader.item.open = false
    }
  }

  Loader { id: panelLoader; active: true }
  Loader { id: configLoader; active: true }

  function ensurePanel() {
    if (!panelLoader.item) {
      panelLoader.setSource(Qt.resolvedUrl("Panel.qml"),
                            { bar: root.bar, anchorItem: button, owner: root.dataIdentity, host: root })
    }
    return panelLoader.item
  }

  function ensureConfig() {
    if (!configLoader.item) {
      configLoader.setSource(Qt.resolvedUrl("ConfigMenu.qml"),
                             { bar: root.bar, anchorItem: button, owner: root.configIdentity, host: root })
    }
    return configLoader.item
  }
}
