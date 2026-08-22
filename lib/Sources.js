.pragma library
.import "Format.js" as Fmt

// What a source is, how it is identified, and what ships in the box.
//
// Two kinds. "hn" is Hacker News through its search backend, which is the only
// endpoint that returns the front page with points and comment counts in a
// single request. "rss" is any RSS/Atom URL the user pastes in.

var HN_ENDPOINT = "https://hn.algolia.com/api/v1/search"

var DEFAULT_SOURCES = [
  { type: "hn", label: "Hacker News", url: "", feed: "front_page", enabled: true }
]

// Offered as one-click adds in the config menu. Every one of these was fetched
// and parsed while building the plugin, so none of them is a guess.
var PRESETS = [
  { type: "hn",  label: "Hacker News",        url: "", feed: "front_page" },
  { type: "hn",  label: "Hacker News · Show", url: "", feed: "show_hn" },
  { type: "hn",  label: "Hacker News · Ask",  url: "", feed: "ask_hn" },
  { type: "rss", label: "Lobsters",           url: "https://lobste.rs/rss" },
  { type: "rss", label: "Ars Technica",       url: "https://feeds.arstechnica.com/arstechnica/index" },
  { type: "rss", label: "The Verge",          url: "https://www.theverge.com/rss/index.xml" },
  { type: "rss", label: "BBC World",          url: "https://feeds.bbci.co.uk/news/world/rss.xml" },
  { type: "rss", label: "Hacker News (RSS)",  url: "https://news.ycombinator.com/rss" }
]

var HN_FEEDS = ["front_page", "show_hn", "ask_hn", "story"]

// A JS array that reaches here through a QML `var` property is wrapped, and
// Array.isArray() answers false for the wrapper even though it indexes and
// reports .length exactly like an array. Every list arriving from shell.json
// crosses that boundary, so array-ness is duck-typed and copied into a real
// array once, here, rather than trusted anywhere downstream.
function toArray(value) {
  if (!value) return []
  if (Array.isArray(value)) return value.slice()
  if (typeof value === "string") return []
  var n = value.length
  if (typeof n !== "number" || n < 0) return []
  var out = []
  for (var i = 0; i < n; i++) out.push(value[i])
  return out
}

function slugify(s) {
  return String(s || "")
    .toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/^www\d?\./, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48)
}

// The id is derived from the URL, not from list position, so reordering or
// removing a source never re-keys anyone else's cached stories or bookmarks.
function sidFor(source) {
  if (!source) return ""
  if (source.type === "hn") {
    var feed = String(source.feed || "front_page")
    return feed === "front_page" ? "hn" : "hn-" + slugify(feed)
  }
  var slug = slugify(source.url)
  return slug ? "rss-" + slug : ""
}

// Only http(s) is accepted. A feed URL ends up in an XMLHttpRequest and its
// items end up in a browser launch, so file: and javascript: are refused at
// the door rather than filtered later.
function validateUrl(url) {
  var u = Fmt.collapse(url)
  if (!u) return { ok: false, error: "Enter a feed URL" }
  if (/^[a-z][a-z0-9+.-]*:/i.test(u) === false) u = "https://" + u
  if (!/^https?:\/\//i.test(u)) return { ok: false, error: "Only http and https feeds are supported" }
  if (!Fmt.isHttpUrl(u)) return { ok: false, error: "That does not look like a URL" }
  return { ok: true, url: u }
}

function labelFor(source) {
  if (!source) return ""
  var l = Fmt.collapse(source.label)
  if (l) return l
  if (source.type === "hn") return "Hacker News"
  return Fmt.domainOf(source.url) || "Feed"
}

// Normalising is total: anything unparseable is dropped rather than carried as
// a half-source, and an empty result falls back to the shipped default so the
// reader is never staring at nothing because of one bad config edit.
function normalize(list) {
  var given = toArray(list)
  var input = given.length ? given : DEFAULT_SOURCES
  var out = []
  var seen = {}
  for (var i = 0; i < input.length; i++) {
    var s = input[i] || {}
    var type = s.type === "hn" ? "hn" : "rss"
    var url = ""
    if (type === "rss") {
      var v = validateUrl(s.url)
      if (!v.ok) continue
      url = v.url
    }
    var feed = type === "hn" ? (HN_FEEDS.indexOf(String(s.feed || "")) >= 0 ? String(s.feed) : "front_page") : ""
    var entry = { type: type, url: url, feed: feed, label: labelFor({ type: type, url: url, label: s.label }),
                  enabled: s.enabled !== false }
    entry.sid = sidFor(entry)
    if (!entry.sid || seen[entry.sid]) continue
    seen[entry.sid] = true
    out.push(entry)
  }
  if (!out.length) return normalize(DEFAULT_SOURCES)
  return out
}

function endpointFor(source, limit) {
  if (!source) return ""
  if (source.type === "hn") {
    var n = Math.max(10, Math.min(100, Number(limit) || 40))
    var feed = source.feed || "front_page"
    // "story" means "everything newest-first"; the others are HN's own tags.
    var tags = feed === "story" ? "story" : feed
    return HN_ENDPOINT + (feed === "story" ? "_by_date" : "") + "?tags=" + encodeURIComponent(tags) + "&hitsPerPage=" + n
  }
  return source.url
}

// Persisted shape is deliberately narrower than the runtime shape: sid is
// derived, so writing it into shell.json would let a stale copy outlive the
// URL it was computed from.
function toConfig(list) {
  var out = []
  var input = toArray(list)
  for (var i = 0; i < input.length; i++) {
    var s = input[i]
    var e = { type: s.type, label: s.label, enabled: s.enabled !== false }
    if (s.type === "rss") e.url = s.url
    else e.feed = s.feed || "front_page"
    out.push(e)
  }
  return out
}

function find(list, sid) {
  var input = toArray(list)
  for (var i = 0; i < input.length; i++) if (input[i].sid === sid) return input[i]
  return null
}

function add(list, source) {
  var next = toArray(list)
  next.push(source)
  return normalize(next)
}

function removeAt(list, index) {
  var next = toArray(list)
  if (index < 0 || index >= next.length) return next
  next.splice(index, 1)
  return next.length ? next : []
}

function move(list, from, to) {
  var next = toArray(list)
  if (from < 0 || from >= next.length || to < 0 || to >= next.length || from === to) return next
  var item = next.splice(from, 1)[0]
  next.splice(to, 0, item)
  return next
}

function setEnabled(list, index, enabled) {
  var next = toArray(list)
  if (index < 0 || index >= next.length) return next
  var e = {}
  for (var k in next[index]) e[k] = next[index][k]
  e.enabled = enabled === true
  next[index] = e
  return next
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { toArray: toArray, DEFAULT_SOURCES: DEFAULT_SOURCES, PRESETS: PRESETS, HN_FEEDS: HN_FEEDS,
                     HN_ENDPOINT: HN_ENDPOINT, slugify: slugify, sidFor: sidFor,
                     validateUrl: validateUrl, labelFor: labelFor, normalize: normalize,
                     endpointFor: endpointFor, toConfig: toConfig, find: find,
                     add: add, removeAt: removeAt, move: move, setEnabled: setEnabled }
}
