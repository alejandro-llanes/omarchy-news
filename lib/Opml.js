.pragma library
.import "Format.js" as Fmt
.import "Sources.js" as Sources

// OPML import, by regex rather than by DOM -- for the same reason as Feed.js:
// the QML JS engine has no DOMParser, and the OPML files other readers export
// are no stricter than the feeds they list (bare ampersands in titles are
// common).
//
// Only what a subscription list needs is read: every <outline> carrying an
// xmlUrl is a feed. Folder outlines (no xmlUrl) are ignored, so a nested
// export flattens into one list in document order. Everything else -- the
// head, htmlUrl, categories -- is dropped.

// Imports beyond this are refused rather than truncated silently: a list this
// long is not a subscription list a bar widget should be polling.
var MAX_FEEDS = 500

// Word-bounded so "url" never matches inside "xmlUrl" or "htmlUrl".
function attr(tag, name) {
  var re = new RegExp("(?:^|[\\s<])" + name + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", "i")
  var m = String(tag || "").match(re)
  if (!m) return ""
  return Fmt.collapse(Fmt.decodeEntities(m[1] !== undefined ? m[1] : m[2]))
}

function looksLikeOpml(text) {
  return /<opml\b/i.test(String(text || ""))
}

// Returns { ok, feeds: [{ type, url, label, enabled }], skipped, error }.
// `skipped` counts outlines that named a feed but whose URL was unusable
// (non-http, malformed) -- reported, so a user can tell "nothing in the file"
// from "nothing usable in the file".
function parse(text) {
  var src = String(text || "")
  if (!looksLikeOpml(src)) return { ok: false, feeds: [], skipped: 0, error: "Not an OPML file" }

  // Comments can hold commented-out outlines; those are not subscriptions.
  src = src.replace(/<!--[\s\S]*?-->/g, "")

  var tags = src.match(/<outline\b[^>]*>/gi) || []
  var feeds = []
  var skipped = 0
  var seen = {}
  for (var i = 0; i < tags.length; i++) {
    var url = attr(tags[i], "xmlUrl")
    if (!url) continue
    var check = Sources.validateUrl(url)
    if (!check.ok) { skipped++; continue }
    var label = Fmt.stripHtml(attr(tags[i], "title") || attr(tags[i], "text"))
    var entry = { type: "rss", url: check.url, label: label, enabled: true }
    var sid = Sources.sidFor(entry)
    if (!sid || seen[sid]) continue
    seen[sid] = true
    feeds.push(entry)
  }

  if (feeds.length > MAX_FEEDS)
    return { ok: false, feeds: [], skipped: skipped, error: "The file lists " + feeds.length + " feeds; the limit is " + MAX_FEEDS }
  if (!feeds.length)
    return { ok: false, feeds: [], skipped: skipped, error: skipped ? "No usable http(s) feeds in the file" : "No feeds in the file" }
  return { ok: true, feeds: feeds, skipped: skipped, error: "" }
}

// Merges parsed feeds into an existing source list. Feeds already present keep
// their place, label and enabled state; new ones are appended in file order.
function merge(list, feeds) {
  var current = Sources.normalize(list)
  var have = {}
  for (var i = 0; i < current.length; i++) have[current[i].sid] = true
  var next = current.slice()
  var added = []
  var duplicates = 0
  var given = Sources.toArray(feeds)
  for (var j = 0; j < given.length; j++) {
    var sid = Sources.sidFor(given[j])
    if (!sid || have[sid]) { duplicates++; continue }
    have[sid] = true
    next.push(given[j])
    added.push(sid)
  }
  return { list: Sources.normalize(next), added: added, duplicates: duplicates }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { MAX_FEEDS: MAX_FEEDS, attr: attr, looksLikeOpml: looksLikeOpml, parse: parse, merge: merge }
}
