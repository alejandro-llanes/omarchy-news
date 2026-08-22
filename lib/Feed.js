.pragma library
.import "Format.js" as Fmt
.import "Media.js" as Media

// Feed parsing, by regex rather than by DOM.
//
// The QML JS engine has no DOMParser, and XMLHttpRequest.responseXML refuses
// anything a strict XML parser dislikes -- which real feeds are, constantly:
// stray ampersands, undeclared namespaces, mismatched tags. A tolerant scanner
// gets a headline out of a feed that a conforming parser would reject whole,
// and a news reader that goes blank because one item had a bad entity is worse
// than one that shows 29 of 30 stories.

var RSS = "rss"
var ATOM = "atom"
var HN = "hn"

function tagText(block, names) {
  var list = [].concat(names)
  for (var i = 0; i < list.length; i++) {
    var re = new RegExp("<" + list[i] + "(?:\\s[^>]*)?>([\\s\\S]*?)<\\/" + list[i] + ">", "i")
    var m = String(block).match(re)
    if (m && Fmt.collapse(Fmt.stripCdata(m[1])) !== "") return m[1]
  }
  return ""
}

// Atom allows several <link>s per entry and distinguishes them by @rel. The
// story is the one marked alternate, or -- since @rel defaults to alternate --
// the one with no @rel at all. self/replies/edit/enclosure are never the story.
function atomLink(block) {
  var links = String(block).match(/<link\b[^>]*\/?>/gi) || []
  var fallback = ""
  for (var i = 0; i < links.length; i++) {
    var rel = Media.attr(links[i], "rel").toLowerCase()
    var href = Media.attr(links[i], "href")
    if (!href) continue
    if (rel === "self" || rel === "edit" || rel === "replies" || rel === "enclosure" || rel === "hub") continue
    if (rel === "" || rel === "alternate") return href
    if (!fallback) fallback = href
  }
  return fallback
}

function pickLink(block, kind) {
  if (kind === ATOM) {
    var a = atomLink(block)
    if (a) return a
  }
  // RSS <link> is plain text. Some hybrid feeds ship both forms, so an empty
  // text node falls through to the Atom-style attribute.
  var t = Fmt.collapse(Fmt.stripCdata(tagText(block, ["link"])))
  if (t) return t
  return atomLink(block)
}

function pickAuthor(block) {
  var creator = Fmt.stripHtml(tagText(block, ["dc:creator", "creator"]))
  if (creator) return creator
  var authorBlock = tagText(block, ["author"])
  if (authorBlock) {
    var name = Fmt.stripHtml(tagText(authorBlock, ["name"]))
    if (name) return name
    var plain = Fmt.stripHtml(authorBlock)
    // RSS puts an email in <author>; the name in parentheses is the human part.
    var paren = plain.match(/\(([^)]+)\)/)
    if (paren) return Fmt.collapse(paren[1])
    if (plain && plain.indexOf("@") === -1) return plain
  }
  return ""
}

function pickDate(block) {
  var raw = tagText(block, ["pubDate", "published", "updated", "dc:date", "date", "lastBuildDate"])
  return Fmt.parseDate(Fmt.stripHtml(raw))
}

// The body is used for two different jobs -- the card summary and the <img>
// scan -- so both the rendered text and the raw markup are kept.
function pickBody(block) {
  var raw = tagText(block, ["content:encoded", "content", "description", "summary", "media:description", "subtitle"])
  return { raw: Fmt.stripCdata(raw), text: Fmt.stripHtml(raw) }
}

function itemBlocks(text) {
  var rss = String(text).match(/<item\b[\s\S]*?<\/item>/gi)
  if (rss && rss.length) return { kind: RSS, blocks: rss }
  var atom = String(text).match(/<entry\b[\s\S]*?<\/entry>/gi)
  if (atom && atom.length) return { kind: ATOM, blocks: atom }
  return { kind: "", blocks: [] }
}

function channelTitle(text) {
  // Strip the items first: otherwise the first item's <title> is picked up on
  // feeds whose channel title sits after the items (rare, but it happens).
  var head = String(text).split(/<(?:item|entry)\b/i)[0]
  return Fmt.stripHtml(tagText(head, ["title"]))
}

// A story's identity has to survive re-fetching, re-titling, and tracking
// parameters being re-rolled on the link. guid/id is the publisher's own answer
// and is preferred whenever it exists; the link is the fallback, stripped of
// the campaign junk that would otherwise fork one story into many.
function stripTracking(url) {
  var u = String(url || "")
  if (!u) return ""
  var cut = u.replace(/([?&])(utm_[a-z_]+|at_medium|at_campaign|at_campaign_type|at_ptr_name|CMP|ncid|fbclid|gclid|mc_cid|mc_eid|__twitter_impression|guccounter)=[^&#]*/gi, "$1")
  cut = cut.replace(/[?&]+(#|$)/, "$1").replace(/([?&])&+/g, "$1")
  return cut.replace(/[?&]$/, "")
}

function identityFor(guid, link, title, sourceId) {
  var g = Fmt.collapse(guid)
  if (g) return sourceId + "|" + g
  var l = stripTracking(Fmt.collapse(link))
  if (l) return sourceId + "|" + l
  return sourceId + "|" + Fmt.collapse(title).toLowerCase().slice(0, 120)
}

function parse(text, source, nowMs) {
  var body = String(text || "")
  if (!body) return { ok: false, error: "empty response", items: [] }
  if (/^\s*</.test(body) === false && /^\s*[{[]/.test(body)) {
    return { ok: false, error: "that URL returns JSON, not an RSS or Atom feed", items: [] }
  }

  var found = itemBlocks(body)
  if (!found.blocks.length) {
    var looksHtml = /<html[\s>]/i.test(body)
    return { ok: false, items: [],
             error: looksHtml ? "that URL is a web page, not a feed" : "no items found in the feed" }
  }

  var sourceId = source && source.sid ? source.sid : "feed"
  var feedTitle = channelTitle(body)
  var items = []
  var seen = {}
  var now = Number(nowMs) || Date.now()

  for (var i = 0; i < found.blocks.length; i++) {
    var block = found.blocks[i]
    var title = Fmt.stripHtml(tagText(block, ["title", "media:title"]))
    var link = Fmt.normalizeUrl(pickLink(block, found.kind), source ? source.url : "")
    if (!title && !link) continue

    var content = pickBody(block)
    var guid = Fmt.stripHtml(tagText(block, ["guid", "id"]))
    var id = identityFor(guid, link, title, sourceId)
    if (seen[id]) continue
    seen[id] = true

    var published = pickDate(block)
    // A feed with no dates at all would otherwise sort at the epoch and look
    // like decade-old news. Falling back to first-sight time keeps the order
    // stable and honest -- the card shows no timestamp when there is none.
    var comments = Fmt.normalizeUrl(Fmt.stripHtml(tagText(block, ["comments", "wfw:commentRss"])), link)

    items.push({
      id: id,
      sid: sourceId,
      title: title || Fmt.truncate(content.text, 80) || Fmt.domainOf(link),
      link: link,
      comments: comments && comments !== link ? comments : "",
      author: pickAuthor(block),
      publishedMs: published,
      hasDate: published > 0,
      summary: Fmt.truncate(content.text, 300),
      domain: Fmt.domainOf(link),
      media: Media.extract(block, content.raw, link),
      points: 0,
      commentCount: 0,
      firstSeenMs: now
    })
  }

  if (!items.length) return { ok: false, error: "the feed parsed but held no readable items", items: [] }
  return { ok: true, kind: found.kind, title: feedTitle, items: items }
}

// Hacker News through its own search backend. One request returns the whole
// front page with points and comment counts, where the plain RSS feed would
// give titles alone and the Firebase API would cost thirty round trips.
function parseHn(text, source, nowMs) {
  var json
  try { json = JSON.parse(String(text || "")) }
  catch (e) { return { ok: false, error: "Hacker News returned something that is not JSON", items: [] } }
  if (!json || !Array.isArray(json.hits)) return { ok: false, error: "unexpected Hacker News response", items: [] }

  var sourceId = source && source.sid ? source.sid : "hn"
  var now = Number(nowMs) || Date.now()
  var items = []

  for (var i = 0; i < json.hits.length; i++) {
    var h = json.hits[i]
    if (!h || !h.objectID) continue
    var title = Fmt.stripHtml(h.title || h.story_title || "")
    if (!title) continue
    var discussion = "https://news.ycombinator.com/item?id=" + String(h.objectID)
    // Ask HN, Show HN text posts and polls carry no external URL; the thread
    // itself is the story.
    var link = Fmt.normalizeUrl(h.url || h.story_url || "", "") || discussion
    var when = Number(h.created_at_i) > 0 ? Number(h.created_at_i) * 1000 : Fmt.parseDate(h.created_at)

    items.push({
      id: sourceId + "|hn:" + String(h.objectID),
      sid: sourceId,
      title: title,
      link: link,
      comments: link === discussion ? "" : discussion,
      author: Fmt.collapse(h.author || ""),
      publishedMs: when,
      hasDate: when > 0,
      summary: Fmt.truncate(Fmt.stripHtml(h.story_text || h.comment_text || ""), 300),
      domain: Fmt.domainOf(link),
      media: { image: "", imageWidth: 0, imageHeight: 0, weak: true, video: "", videoPlayable: false, poster: "" },
      points: Number(h.points) || 0,
      commentCount: Number(h.num_comments) || 0,
      firstSeenMs: now
    })
  }

  if (!items.length) return { ok: false, error: "Hacker News returned no stories", items: [] }
  return { ok: true, kind: HN, title: "Hacker News", items: items }
}

function parseSource(text, source, nowMs) {
  if (source && source.type === "hn") return parseHn(text, source, nowMs)
  return parse(text, source, nowMs)
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { parse: parse, parseHn: parseHn, parseSource: parseSource,
                     stripTracking: stripTracking, identityFor: identityFor,
                     channelTitle: channelTitle, itemBlocks: itemBlocks,
                     pickLink: pickLink, pickAuthor: pickAuthor, pickDate: pickDate,
                     RSS: RSS, ATOM: ATOM, HN: HN }
}
