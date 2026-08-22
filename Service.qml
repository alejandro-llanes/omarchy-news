import QtQuick
import Quickshell
import Quickshell.Io
import "lib/Feed.js" as Feed
import "lib/Store.js" as Store
import "lib/Sources.js" as Sources
import "lib/Format.js" as Fmt

// Headless singleton. Owns every network request, the story cache, the picture
// cache on disk, and the refresh schedule. The bar widget and the reader are
// pure views over `items` and never fetch anything themselves -- the shell
// instantiates one bar widget per monitor, and a per-widget fetch would poll
// every publisher once per screen.
Item {
  id: root

  // Injected by shell.qml AFTER createObject() returns -- see bootstrapTimer.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property string omarchyPath: ""

  readonly property string moduleId: "io.github.alejandro-llanes.news"

  // ---- persisted state ----------------------------------------------------
  property string stateDir: ""
  property string artworkDir: ""
  property string helperPath: ""
  property var items: []                    // the whole cache, newest first
  property var sources: []                  // normalized source list
  property real lastRefreshMs: 0
  property bool ready: false
  property bool cacheLoaded: false

  // ---- settings mirrored from the bar entry -------------------------------
  property int  refreshMinutes: 30
  property int  retentionDays: 7
  property int  maxPerSource: 40
  property bool fetchArtwork: true
  property bool pauseNetwork: false
  property bool markReadOnOpen: true

  // ---- live status --------------------------------------------------------
  property bool refreshing: false
  property string lastState: "idle"
  property string lastMessage: ""
  property var sourceStatus: ({})           // sid -> { state, message, atMs, count }
  property var diagnostics: []
  property int inFlight: 0
  property real cacheBytes: 0

  signal itemsUpdated()
  signal openConfigRequested()
  signal openPanelRequested()
  signal bookmarksRequested()

  readonly property var stats: Store.stats(items)
  readonly property int unreadCount: stats.unread
  readonly property int bookmarkCount: stats.bookmarked

  // How many artwork lookups one refresh may spend. Each is a single request
  // to a different publisher, run strictly one at a time with a gap between,
  // so a full budget is about two minutes of trickle rather than a burst. Set
  // high enough that a cold cache fills on its first sync instead of over the
  // several hours a small budget would take at a 30-minute schedule; failures
  // are remembered, so the steady-state cost is only genuinely new stories.
  readonly property int enrichBudget: 60

  // =========================================================================
  // Bootstrap. `shell` and `manifest` are null during Component.onCompleted
  // (shell.qml assigns them after createObject returns), so anything needing
  // them waits a tick. A Timer is used rather than Qt.callLater because a
  // callLater closure was observed not to run in this context.
  // =========================================================================
  Component.onCompleted: {
    root.sources = Sources.normalize(null)
    bootstrapTimer.start()
  }

  Timer {
    id: bootstrapTimer
    interval: 0; repeat: false
    onTriggered: root.bootstrap()
  }

  function bootstrap() {
    var home = Quickshell.env("HOME") || ""
    var xdg = Quickshell.env("XDG_STATE_HOME") || ""
    root.stateDir = (xdg && xdg.length ? xdg : home + "/.local/state") + "/omarchy-news"
    root.artworkDir = root.stateDir + "/artwork"
    root.helperPath = pluginDir() + "/bin/news-media"

    // What you read is private. FileView cannot create directories and the
    // shell's umask is 0022, so the mode is set explicitly rather than
    // inherited.
    mkdirProc.command = ["bash", "-c",
      "umask 077; mkdir -p \"$1/artwork\"; chmod 700 \"$1\" \"$1/artwork\"", "_", root.stateDir]
    mkdirProc.running = true
  }

  // The manifest carries the plugin's own directory, which is where the helper
  // script lives. Falling back to the conventional path keeps a hand-installed
  // copy working if that field is ever absent.
  function pluginDir() {
    if (root.manifest && root.manifest.__sourceDir) return String(root.manifest.__sourceDir).replace(/\/$/, "")
    return (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/" + root.moduleId
  }

  Process {
    id: mkdirProc
    running: false
    onExited: function(code) {
      if (code !== 0) { root.note("error", "could not create " + root.stateDir); return }
      cacheFile.path = root.stateDir + "/cache.json"
      cacheFile.reload()
      root.ready = true
      startupTimer.start()
    }
  }

  // Give the cache FileView a moment to land before deciding the cache is cold.
  Timer {
    id: startupTimer
    interval: 400; repeat: false
    onTriggered: {
      root.cacheLoaded = true
      root.measureCache()
      root.tick()
    }
  }

  // =========================================================================
  // Persistence
  // =========================================================================
  FileView {
    id: cacheFile
    watchChanges: false; atomicWrites: true; printErrors: false
    onLoaded: {
      try {
        var j = JSON.parse(text())
        if (j && j.v === 1 && Array.isArray(j.items)) {
          root.items = Store.sortItems(j.items)
          root.lastRefreshMs = Number(j.lastRefreshMs) || 0
          root.itemsUpdated()
        }
      } catch (e) { root.note("warn", "cache unreadable, starting cold") }
    }
    onLoadFailed: { root.items = []; root.lastRefreshMs = 0 }   // first run
  }

  // Story state changes in bursts -- a merge touches dozens of rows, and
  // marking a source read touches all of them -- so the write is debounced
  // rather than run per change.
  Timer {
    id: saveTimer
    interval: 900; repeat: false
    onTriggered: root.saveNow()
  }

  function save() { if (root.ready) saveTimer.restart() }

  function saveNow() {
    if (!root.ready) return
    cacheFile.setText(JSON.stringify({ v: 1, lastRefreshMs: root.lastRefreshMs, items: root.items }) + "\n")
    secureTimer.restart()
  }

  // FileView recreates the file on every atomic write, so the 0644 the shell's
  // umask produces comes back each time. Re-tighten after the write settles.
  Timer {
    id: secureTimer
    interval: 250; repeat: false
    onTriggered: {
      if (!root.stateDir) return
      secureProc.command = ["bash", "-c", "chmod 600 \"$1/cache.json\" 2>/dev/null; exit 0", "_", root.stateDir]
      secureProc.running = true
    }
  }
  Process { id: secureProc; running: false }

  function note(level, message) {
    var line = { t: Date.now(), level: level, message: String(message || "") }
    var next = root.diagnostics.slice(0, 9)
    next.unshift(line)
    root.diagnostics = next
    if (level === "error") console.warn("news: " + line.message)
  }

  function setSourceStatus(sid, state, message, count) {
    var next = ({})
    for (var k in root.sourceStatus) next[k] = root.sourceStatus[k]
    next[sid] = { state: state, message: String(message || ""), atMs: Date.now(),
                  count: count === undefined ? (next[sid] ? next[sid].count : 0) : count }
    root.sourceStatus = next
  }

  function statusFor(sid) { return root.sourceStatus[sid] || null }

  // =========================================================================
  // Fetch queue. Serial and spaced: a refresh of six feeds should look like a
  // person opening six tabs, not like a scraper.
  // =========================================================================
  property var queue: []
  property bool draining: false

  function enqueue(source, manual) {
    for (var i = 0; i < root.queue.length; i++) {
      if (root.queue[i].source.sid === source.sid) return
    }
    var q = root.queue.slice()
    q.push({ source: source, manual: manual === true })
    root.queue = q
    if (!root.draining) drainTimer.start()
  }

  Timer {
    id: drainTimer
    interval: 1200; repeat: true; triggeredOnStart: true
    running: false
    onTriggered: root.drain()
  }

  function drain() {
    if (!root.queue.length) {
      drainTimer.stop()
      root.draining = false
      if (root.refreshing) root.finishRefresh()
      return
    }
    root.draining = true
    if (root.pauseNetwork) { root.queue = []; drainTimer.stop(); root.draining = false; root.refreshing = false; return }
    if (root.inFlight > 0) return           // one request at a time

    var q = root.queue.slice()
    var job = q.shift()
    root.queue = q
    root.fetch(job.source, job.manual)
  }

  // =========================================================================
  // Transport
  // =========================================================================
  function fetch(source, manual) {
    var url = Sources.endpointFor(source, root.maxPerSource)
    if (!Fmt.isHttpUrl(url)) { root.setSourceStatus(source.sid, "error", "not a usable URL", 0); return }

    var xhr = new XMLHttpRequest()
    var settled = false
    root.inFlight += 1
    root.setSourceStatus(source.sid, "fetching", "")

    var watchdog = Qt.createQmlObject('import QtQuick; Timer { interval: 20000; repeat: false }', root)
    watchdog.triggered.connect(function() {
      if (settled) return
      settled = true
      root.inFlight = Math.max(0, root.inFlight - 1)
      try { xhr.abort() } catch (e) {}
      root.setSourceStatus(source.sid, "error", "timed out after 20s")
      root.note("warn", source.label + ": timed out")
      watchdog.destroy()
    })
    watchdog.start()

    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE || settled) return
      settled = true
      root.inFlight = Math.max(0, root.inFlight - 1)
      watchdog.stop(); watchdog.destroy()

      // status 0 means the request never reached a server: offline, DNS, TLS.
      if (xhr.status === 0) {
        root.setSourceStatus(source.sid, "offline", "could not be reached")
        root.lastState = "offline"
        return
      }
      if (xhr.status >= 400) {
        root.setSourceStatus(source.sid, "error", "HTTP " + xhr.status)
        root.note("warn", source.label + ": HTTP " + xhr.status)
        return
      }
      root.ingest(source, xhr.responseText)
    }

    try {
      xhr.open("GET", url)
      // Some CDNs answer a bare request with a challenge page; a plain,
      // honest UA gets the feed.
      xhr.setRequestHeader("User-Agent", "omarchy-news/1.0 (+quickshell)")
      xhr.setRequestHeader("Accept", "application/rss+xml, application/atom+xml, application/xml, application/json;q=0.9, text/xml;q=0.8, */*;q=0.5")
      xhr.send()
    } catch (e) {
      settled = true
      root.inFlight = Math.max(0, root.inFlight - 1)
      watchdog.stop(); watchdog.destroy()
      root.setSourceStatus(source.sid, "error", "request failed to start")
    }
  }

  function ingest(source, body) {
    var res = Feed.parseSource(body, source, Date.now())
    if (!res.ok) {
      root.setSourceStatus(source.sid, "error", res.error, 0)
      root.note("warn", source.label + ": " + res.error)
      return
    }

    var merged = Store.merge(root.items, res.items, source.sid)
    root.items = Store.sortItems(merged.items)
    root.setSourceStatus(source.sid, "ok", merged.added > 0 ? merged.added + " new" : "up to date", res.items.length)
    root.itemsUpdated()
    root.save()
    root.lastState = "ok"
    root.lastMessage = ""
  }

  // Runs once the whole queue has drained: prune first so artwork is never
  // fetched for a story that cleanup is about to drop.
  function finishRefresh() {
    root.refreshing = false
    root.lastRefreshMs = Date.now()
    root.cleanup(false)
    root.save()
    if (root.fetchArtwork && !root.pauseNetwork) root.startEnrichment()
  }

  // =========================================================================
  // Artwork. Everything heavy happens in bin/news-media: reading a 400 KB
  // article page for its OpenGraph tags, and writing the picture to disk so a
  // second panel open costs nothing and "clean the cache" has something to
  // clean.
  // =========================================================================
  property var enrichQueue: []
  property bool enriching: false
  property string enrichingId: ""

  function startEnrichment() {
    if (root.enriching) return
    var pending = Store.enrichQueue(root.items, root.enrichBudget)
    if (!pending.length) return
    root.enrichQueue = pending
    root.enrichNext()
  }

  function enrichNext() {
    if (!root.enrichQueue.length) {
      root.enriching = false
      root.enrichingId = ""
      root.measureCache()
      root.save()
      return
    }
    if (root.pauseNetwork || !root.fetchArtwork) { root.enrichQueue = []; root.enriching = false; return }

    var q = root.enrichQueue.slice()
    var item = q.shift()
    root.enrichQueue = q
    root.enriching = true
    root.enrichingId = item.id

    // Two different jobs behind one helper: when the feed already named a
    // picture worth having, only download it; when it did not, read the article
    // page first. `enrichRetried` marks the fallback pass -- the page was tried
    // and gave nothing, so take the small picture the feed named after all.
    var media = item.media || {}
    var haveUsableImage = media.image && (!media.weak || item.enrichRetried === true || !item.link)
    if (haveUsableImage) {
      enrichProc.command = [root.helperPath, "image", root.artworkDir, media.image, item.id]
    } else {
      enrichProc.command = [root.helperPath, "page", root.artworkDir, item.link, item.id]
    }
    enrichProc.running = true
  }

  Process {
    id: enrichProc
    running: false
    stdout: StdioCollector { id: enrichOut; waitForEnd: true }
    onExited: function(code) {
      root.applyEnrichment(String(enrichOut.text || ""))
      // A short gap between publishers, for the same reason the feed queue is
      // spaced. Also gives the UI a frame to breathe between disk writes.
      enrichGap.restart()
    }
  }

  Timer {
    id: enrichGap
    interval: 350; repeat: false
    onTriggered: root.enrichNext()
  }

  function applyEnrichment(raw) {
    var res
    try { res = JSON.parse(raw) } catch (e) { res = null }
    var id = res && res.id ? res.id : root.enrichingId
    if (!id) return
    var retry = null

    var out = root.items.slice()
    for (var i = 0; i < out.length; i++) {
      if (out[i].id !== id) continue
      var e = ({})
      for (var k in out[i]) e[k] = out[i][k]
      e.enrichedMs = Date.now()
      if (res && res.ok === true && res.artwork) {
        e.artwork = String(res.artwork)
        e.artworkBytes = Number(res.bytes) || 0
        e.enrichFailed = false
        var media = ({})
        for (var m in e.media) media[m] = e.media[m]
        if (res.image) { media.image = String(res.image); media.weak = false }
        if (res.video && !media.video) media.video = String(res.video)
        if (!media.poster) media.poster = media.image
        e.media = media
      } else if (e.media && e.media.image && e.enrichRetried !== true) {
        // The page had nothing, but the feed did name a picture -- a small one,
        // which is why the page was consulted at all. Fall back to caching that
        // rather than leaving the card blank.
        e.enrichRetried = true
        e.enrichedMs = 0
        retry = e
      } else {
        // Remembered so a paywalled or picture-less page is asked once, not
        // once per refresh forever.
        e.enrichFailed = true
      }
      out[i] = e
      break
    }
    root.items = out
    root.itemsUpdated()
    // Re-queued at the front so the fallback download happens immediately
    // after the page attempt it is standing in for.
    if (retry) {
      var q = root.enrichQueue.slice()
      q.unshift(retry)
      root.enrichQueue = q
    }
  }

  // =========================================================================
  // Cache maintenance
  // =========================================================================

  // Retention + per-source cap + stories from sources that are gone. Bookmarks
  // are exempt from every one of those, which is the whole point.
  function cleanup(manual) {
    var sids = []
    for (var i = 0; i < root.sources.length; i++) sids.push(root.sources[i].sid)

    var res = Store.prune(root.items, {
      nowMs: Date.now(),
      retentionDays: root.retentionDays,
      maxPerSource: root.maxPerSource,
      validSids: sids
    })
    root.items = res.items
    root.itemsUpdated()
    root.save()

    // Delete the pictures those stories owned, then sweep anything on disk
    // that no surviving story claims.
    if (res.artwork.length) root.deleteArtwork(res.artwork)
    sweepProc.command = [root.helperPath, "list", root.artworkDir]
    sweepProc.running = true

    if (manual) root.note("info", res.removed > 0 ? "cleared " + res.removed + " old stor" + (res.removed === 1 ? "y" : "ies")
                                                  : "nothing to clear")
    return res.removed
  }

  function deleteArtwork(paths) {
    if (!paths || !paths.length) return
    var cmd = [root.helperPath, "gc", root.artworkDir]
    for (var i = 0; i < paths.length; i++) cmd.push(paths[i])
    gcProc.command = cmd
    gcProc.running = true
  }

  Process {
    id: gcProc
    running: false
    stdout: StdioCollector { id: gcOut; waitForEnd: true }
    onExited: root.measureCache()
  }

  // Orphan sweep. Ownership, not age, decides what goes: a bookmark from last
  // year keeps its picture through every cleanup because a live story still
  // points at it.
  Process {
    id: sweepProc
    running: false
    stdout: StdioCollector { id: sweepOut; waitForEnd: true }
    onExited: {
      var res
      try { res = JSON.parse(String(sweepOut.text || "")) } catch (e) { return }
      if (!res || !res.ok || !Array.isArray(res.files)) return
      var onDisk = []
      for (var i = 0; i < res.files.length; i++) onDisk.push(res.files[i].path)
      var orphans = Store.orphanArtwork(root.items, onDisk)
      root.cacheBytes = Number(res.bytes) || 0
      if (orphans.length) root.deleteArtwork(orphans)
    }
  }

  function measureCache() {
    if (!root.helperPath || !root.artworkDir) return
    measureProc.command = [root.helperPath, "list", root.artworkDir]
    measureProc.running = true
  }

  Process {
    id: measureProc
    running: false
    stdout: StdioCollector { id: measureOut; waitForEnd: true }
    onExited: {
      try {
        var res = JSON.parse(String(measureOut.text || ""))
        if (res && res.ok) root.cacheBytes = Number(res.bytes) || 0
      } catch (e) {}
    }
  }

  // The nuclear option, still bounded by the same promise: bookmarks stay.
  function clearCache() {
    var kept = []
    var doomed = []
    for (var i = 0; i < root.items.length; i++) {
      if (root.items[i].bookmarked === true) kept.push(root.items[i])
      else doomed.push(root.items[i])
    }
    root.items = kept
    root.itemsUpdated()
    root.saveNow()
    root.deleteArtwork(Store.artworkPaths(doomed))
    root.note("info", "cleared " + doomed.length + " stories, kept " + kept.length + " bookmarked")
    return doomed.length
  }

  // =========================================================================
  // Scheduler. A SystemClock minute tick plus a Date.now() delta, because QML
  // Timers freeze across suspend and fire late on resume.
  // =========================================================================
  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.tick()
  }

  function tick() {
    if (!root.ready || !root.cacheLoaded || root.pauseNetwork) return
    var due = root.lastRefreshMs === 0
              || (Date.now() - root.lastRefreshMs) >= Math.max(5, root.refreshMinutes) * 60000
    if (due) root.refreshAll(false)
  }

  readonly property real nextRefreshMs: root.lastRefreshMs
    ? root.lastRefreshMs + Math.max(5, root.refreshMinutes) * 60000 : 0

  // =========================================================================
  // Public API used by the bar widget and the reader
  // =========================================================================
  function refreshAll(manual) {
    if (root.pauseNetwork) { root.note("warn", "cache-only mode is on"); return false }
    if (root.refreshing && !manual) return false
    root.refreshing = true
    for (var i = 0; i < root.sources.length; i++) {
      if (root.sources[i].enabled !== false) root.enqueue(root.sources[i], manual === true)
    }
    if (!root.queue.length) { root.refreshing = false; return false }
    return true
  }

  function refreshSource(sid) {
    var s = Sources.find(root.sources, sid)
    if (!s || root.pauseNetwork) return false
    root.refreshing = true
    root.enqueue(s, true)
    return true
  }

  // NOT named `visible`: this is an Item, and Item.visible is a final property.
  // Shadowing it makes the widget's own visibility unassignable.
  function viewFor(sid, unreadOnly, query) {
    return Store.view(root.items, { sid: sid, unreadOnly: unreadOnly === true, query: query || "" })
  }

  function itemById(id) {
    for (var i = 0; i < root.items.length; i++) if (root.items[i].id === id) return root.items[i]
    return null
  }

  function toggleBookmark(id) {
    root.items = Store.toggleBookmark(root.items, id, Date.now())
    root.itemsUpdated()
    root.save()
    var it = root.itemById(id)
    // A newly bookmarked story with no picture yet is worth one lookup now:
    // it is the one story we know the user wants to keep.
    if (it && it.bookmarked && !it.artwork && root.fetchArtwork && !root.pauseNetwork && !root.enriching) {
      root.enrichQueue = [it]
      root.enrichNext()
    }
    return it ? it.bookmarked === true : false
  }

  function markRead(id, value) {
    root.items = Store.setFlag(root.items, id, "read", value !== false)
    root.itemsUpdated()
    root.save()
  }

  function markAllRead(sid) {
    root.items = Store.markAllRead(root.items, sid || "")
    root.itemsUpdated()
    root.save()
  }

  // The browser is the user's, chosen once for the whole desktop; the reader
  // never tries to render the article itself.
  function openUrl(url) {
    if (!Fmt.isHttpUrl(url)) return false
    Quickshell.execDetached(["omarchy-launch-browser", url])
    return true
  }

  function openItem(id) {
    var it = root.itemById(id)
    if (!it) return false
    var opened = root.openUrl(it.link)
    if (opened) {
      if (root.markReadOnOpen) root.markRead(id, true)
      root.items = Store.setFlag(root.items, id, "openedMs", Date.now())
      root.save()
    }
    return opened
  }

  function openComments(id) {
    var it = root.itemById(id)
    if (!it || !it.comments) return false
    var opened = root.openUrl(it.comments)
    if (opened && root.markReadOnOpen) root.markRead(id, true)
    return opened
  }

  function copyLink(id) {
    var it = root.itemById(id)
    if (!it || !it.link) return false
    Quickshell.execDetached(["bash", "-c", "printf %s \"$1\" | wl-copy", "_", it.link])
    return true
  }

  // Settings arrive from the bar entry, which is the single source of truth in
  // shell.json. A changed source list re-normalises and triggers a refresh so
  // the reader is never showing a feed the user just removed.
  function applySettings(s) {
    if (!s) return
    if (s.refreshMinutes !== undefined) root.refreshMinutes = Math.max(5, Math.min(1440, Number(s.refreshMinutes) || 30))
    if (s.retentionDays !== undefined) root.retentionDays = Math.max(1, Math.min(90, Number(s.retentionDays) || 7))
    if (s.maxPerSource !== undefined) root.maxPerSource = Math.max(10, Math.min(200, Number(s.maxPerSource) || 40))
    if (s.fetchArtwork !== undefined) root.fetchArtwork = s.fetchArtwork !== false
    if (s.markReadOnOpen !== undefined) root.markReadOnOpen = s.markReadOnOpen !== false
    if (s.pauseNetwork !== undefined) root.pauseNetwork = s.pauseNetwork === true

    // Sources.normalize duck-types array-ness rather than trusting
    // Array.isArray, because this list arrives across a QML var boundary.
    var incoming = Sources.normalize(s.sources && s.sources.length ? s.sources : null)
    if (JSON.stringify(Sources.toConfig(incoming)) !== JSON.stringify(Sources.toConfig(root.sources))) {
      var hadSources = root.sources.length > 0
      root.sources = incoming
      if (root.ready && hadSources) {
        root.lastRefreshMs = 0        // a changed list is due immediately
        root.tick()
      }
    }
  }

  IpcHandler {
    target: "io.github.alejandro-llanes.news"

    function refresh(): string { return root.refreshAll(true) ? "ok" : "blocked" }
    function panel(): string { root.openPanelRequested(); return "ok" }
    function config(): string { root.openConfigRequested(); return "ok" }
    function bookmarks(): string { root.bookmarksRequested(); return "ok" }
    function cleanup(): string { return String(root.cleanup(true)) }
    function clear(): string { return String(root.clearCache()) }
    function markAllRead(): string { root.markAllRead(""); return "ok" }
    function status(): string {
      return JSON.stringify({
        sources: root.sources.length,
        stories: root.items.length,
        unread: root.unreadCount,
        bookmarks: root.bookmarkCount,
        cacheBytes: root.cacheBytes,
        lastRefresh: root.lastRefreshMs,
        state: root.lastState,
        paused: root.pauseNetwork
      })
    }
  }
}
