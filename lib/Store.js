.pragma library
.import "Media.js" as Media

// The cache: one flat array of stories, merged across every source.
//
// Two rules hold this together. First, a story's read/bookmarked state belongs
// to the user and always survives a re-fetch -- the feed is authoritative about
// the story, never about what you did with it. Second, a bookmark is permanent:
// no retention window, no per-source cap, and no source removal can delete one.
// Everything below is written so that both rules hold even when the inputs are
// contradictory.

function index(items) {
  var by = {}
  for (var i = 0; i < (items || []).length; i++) {
    var it = items[i]
    if (it && it.id) by[it.id] = it
  }
  return by
}

// Fields the user owns. Copied forward on every merge, never taken from the
// incoming copy, because the network has no opinion about them.
function carryUserState(target, prior) {
  target.read = prior.read === true
  target.bookmarked = prior.bookmarked === true
  target.bookmarkedAtMs = Number(prior.bookmarkedAtMs) || 0
  target.firstSeenMs = Number(prior.firstSeenMs) || target.firstSeenMs
  target.openedMs = Number(prior.openedMs) || 0
  return target
}

// Artwork resolution is expensive (one HTTP request to the publisher, plus a
// download), so its results are carried forward too -- and a prior failure is
// remembered so a paywalled or image-less page is not re-fetched every cycle.
function carryArtwork(target, prior) {
  target.artwork = prior.artwork || ""
  target.artworkBytes = Number(prior.artworkBytes) || 0
  target.enrichedMs = Number(prior.enrichedMs) || 0
  target.enrichFailed = prior.enrichFailed === true
  if (prior.media && Media.hasMedia(prior.media)) {
    // The prior media may itself be an enrichment result, which outranks
    // whatever the feed re-served.
    target.media = prior.enrichedMs ? prior.media : Media.mergeMedia(target.media, prior.media)
  }
  return target
}

function merge(existing, incoming, sid) {
  var by = index(existing)
  var out = (existing || []).slice()
  var added = 0
  var updated = 0

  for (var i = 0; i < (incoming || []).length; i++) {
    var fresh = incoming[i]
    if (!fresh || !fresh.id) continue
    var prior = by[fresh.id]
    if (!prior) {
      fresh.read = false
      fresh.bookmarked = false
      fresh.bookmarkedAtMs = 0
      fresh.artwork = ""
      fresh.artworkBytes = 0
      fresh.enrichedMs = 0
      fresh.enrichFailed = false
      out.push(fresh)
      by[fresh.id] = fresh
      added++
      continue
    }
    var next = {}
    for (var k in fresh) next[k] = fresh[k]
    carryUserState(next, prior)
    carryArtwork(next, prior)
    // A story that lost its date upstream keeps the one it arrived with, so it
    // does not jump to the bottom of the list mid-session.
    if (!next.hasDate && prior.hasDate) {
      next.publishedMs = prior.publishedMs
      next.hasDate = true
    }
    for (var j = 0; j < out.length; j++) {
      if (out[j].id === next.id) { out[j] = next; break }
    }
    by[next.id] = next
    updated++
  }

  return { items: out, added: added, updated: updated, sid: sid }
}

function ageOf(item, nowMs) {
  var when = Number(item.publishedMs) || Number(item.firstSeenMs) || 0
  if (!when) return 0
  return Math.max(0, (Number(nowMs) || Date.now()) - when)
}

function sortKey(item) {
  return Number(item.publishedMs) || Number(item.firstSeenMs) || 0
}

function sortItems(items) {
  return (items || []).slice().sort(function(a, b) { return sortKey(b) - sortKey(a) })
}

// Cleanup. Everything a bookmark touches is exempt, in every branch -- that is
// the whole contract this function exists to keep.
function prune(items, opts) {
  var o = opts || {}
  var now = Number(o.nowMs) || Date.now()
  var retentionMs = Math.max(1, Number(o.retentionDays) || 7) * 86400000
  var cap = Math.max(1, Number(o.maxPerSource) || 40)
  var validSids = o.validSids || null

  var kept = []
  var dropped = []
  var perSource = {}

  var ordered = sortItems(items)
  for (var i = 0; i < ordered.length; i++) {
    var it = ordered[i]
    if (!it || !it.id) continue

    if (it.bookmarked === true) { kept.push(it); continue }

    // A source the user removed leaves its unbookmarked stories behind as
    // dead weight; they go on the next cleanup.
    if (validSids && validSids.indexOf(it.sid) === -1) { dropped.push(it); continue }

    if (o.readOnly === true && it.read !== true) { kept.push(it); continue }

    if (ageOf(it, now) > retentionMs) { dropped.push(it); continue }

    var n = perSource[it.sid] || 0
    if (n >= cap) { dropped.push(it); continue }
    perSource[it.sid] = n + 1
    kept.push(it)
  }

  return { items: sortItems(kept), dropped: dropped, removed: dropped.length,
           artwork: artworkPaths(dropped) }
}

// Cache files belonging to dropped stories, so the caller can delete exactly
// those and leave every bookmarked story's picture on disk.
function artworkPaths(items) {
  var out = []
  for (var i = 0; i < (items || []).length; i++) {
    var a = items[i] && items[i].artwork
    if (a) out.push(a)
  }
  return out
}

// Artwork on disk that no live story claims any more. Deleting by this list
// rather than by age is what makes a bookmarked story from last year keep its
// picture through every cleanup.
function orphanArtwork(items, filesOnDisk) {
  var claimed = {}
  for (var i = 0; i < (items || []).length; i++) {
    var a = items[i] && items[i].artwork
    if (a) claimed[a] = true
  }
  var out = []
  for (var j = 0; j < (filesOnDisk || []).length; j++) {
    if (!claimed[filesOnDisk[j]]) out.push(filesOnDisk[j])
  }
  return out
}

function stats(items) {
  var out = { total: 0, unread: 0, bookmarked: 0, withArtwork: 0, bytes: 0, bySource: {} }
  for (var i = 0; i < (items || []).length; i++) {
    var it = items[i]
    if (!it) continue
    out.total++
    if (it.read !== true) out.unread++
    if (it.bookmarked === true) out.bookmarked++
    if (it.artwork) { out.withArtwork++; out.bytes += Number(it.artworkBytes) || 0 }
    var s = out.bySource[it.sid] || { total: 0, unread: 0, bookmarked: 0 }
    s.total++
    if (it.read !== true) s.unread++
    if (it.bookmarked === true) s.bookmarked++
    out.bySource[it.sid] = s
  }
  return out
}

function matches(item, query) {
  var q = String(query || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  if (!q) return true
  var hay = (item.title + " " + (item.domain || "") + " " + (item.author || "") + " " + (item.summary || "")).toLowerCase()
  var words = q.split(/\s+/)
  for (var i = 0; i < words.length; i++) if (hay.indexOf(words[i]) === -1) return false
  return true
}

// The reader's single filtering entry point. `sid` of "" means every source,
// "*bookmarks" is the saved view -- a pseudo-source so the UI can treat the
// rail as one uniform list of chips.
var BOOKMARKS_VIEW = "*bookmarks"

function view(items, opts) {
  var o = opts || {}
  var out = []
  for (var i = 0; i < (items || []).length; i++) {
    var it = items[i]
    if (!it) continue
    if (o.sid === BOOKMARKS_VIEW) { if (it.bookmarked !== true) continue }
    else if (o.sid && it.sid !== o.sid) continue
    if (o.unreadOnly === true && it.read === true && it.bookmarked !== true) continue
    if (!matches(it, o.query)) continue
    out.push(it)
  }
  return sortItems(out)
}

// Every mutation returns a new array: QML re-evaluates bindings on assignment,
// so an in-place edit updates the data and leaves the view showing the old one.
function setFlag(items, id, field, value) {
  var out = (items || []).slice()
  for (var i = 0; i < out.length; i++) {
    if (out[i].id !== id) continue
    var e = {}
    for (var k in out[i]) e[k] = out[i][k]
    e[field] = value
    out[i] = e
    return out
  }
  return out
}

function toggleBookmark(items, id, nowMs) {
  var out = (items || []).slice()
  for (var i = 0; i < out.length; i++) {
    if (out[i].id !== id) continue
    var e = {}
    for (var k in out[i]) e[k] = out[i][k]
    e.bookmarked = !(e.bookmarked === true)
    e.bookmarkedAtMs = e.bookmarked ? (Number(nowMs) || Date.now()) : 0
    out[i] = e
    return out
  }
  return out
}

function markAllRead(items, sid) {
  var out = (items || []).slice()
  for (var i = 0; i < out.length; i++) {
    if (sid && out[i].sid !== sid) continue
    if (out[i].read === true) continue
    var e = {}
    for (var k in out[i]) e[k] = out[i][k]
    e.read = true
    out[i] = e
  }
  return out
}

// Enrichment candidates, best-first: unread before read, newest before oldest,
// and nothing that has already been tried. The cap is the caller's per-cycle
// budget, so a 200-story cache does not turn one refresh into 200 requests.
function enrichQueue(items, limit) {
  var pending = []
  for (var i = 0; i < (items || []).length; i++) {
    var it = items[i]
    if (!it || !it.link) continue
    if (it.enrichFailed === true) continue
    if (it.artwork) continue
    if (it.enrichedMs && !it.media.weak) continue
    if (it.media && it.media.image && !it.media.weak && it.artwork) continue
    pending.push(it)
  }
  pending.sort(function(a, b) {
    var ar = a.read === true ? 1 : 0, br = b.read === true ? 1 : 0
    if (ar !== br) return ar - br
    return sortKey(b) - sortKey(a)
  })
  return pending.slice(0, Math.max(0, Number(limit) || 0))
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { index: index, merge: merge, prune: prune, stats: stats, view: view,
                     sortItems: sortItems, sortKey: sortKey, ageOf: ageOf, matches: matches,
                     setFlag: setFlag, toggleBookmark: toggleBookmark, markAllRead: markAllRead,
                     enrichQueue: enrichQueue, orphanArtwork: orphanArtwork,
                     artworkPaths: artworkPaths, BOOKMARKS_VIEW: BOOKMARKS_VIEW }
}
