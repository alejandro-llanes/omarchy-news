// Unit tests for the pure-logic libraries, run outside QML under node.
//   node test/run.mjs
//
// Every fixture in test/fixtures/ is a real response captured on 2026-08-21
// from the feed it is named after. The assertions below describe what those
// feeds actually contain, so a regression in the parser shows up as a failure
// against real-world markup rather than against a convenient mock.
import { loadLib, fixture, fixtureText } from "./load.mjs"

const F = loadLib("Format.js")
const M = loadLib("Media.js")
const Feed = loadLib("Feed.js")
const Store = loadLib("Store.js")
const Src = loadLib("Sources.js")

let pass = 0, fail = 0
const failures = []
function ok(name, cond, detail) {
  if (cond) pass++
  else { fail++; failures.push(name + (detail ? "  -> " + detail : "")) }
}
function eq(name, got, want) {
  ok(name, Object.is(got, want) || JSON.stringify(got) === JSON.stringify(want),
     `got ${JSON.stringify(got)} want ${JSON.stringify(want)}`)
}

// ============================================================ Format
eq("entities decode", F.decodeEntities("Tom &amp; Jerry &#8212; &quot;hi&quot;"), 'Tom & Jerry — "hi"')
// Feeds that CDATA-wrap already-escaped markup produce &amp;amp;. One pass
// leaves a stray &amp; visible in the headline.
eq("double-escaped entities", F.decodeEntities("R&amp;amp;D"), "R&D")
eq("unknown entity survives", F.decodeEntities("&notareal; x"), "&notareal; x")
eq("script bodies are removed, not unwrapped",
   F.stripHtml("<p>Real<script>var x=1;</script></p>"), "Real")
eq("block tags become spaces", F.stripHtml("<p>one</p><p>two</p>"), "one two")
eq("truncate breaks on a word", F.truncate("the quick brown fox jumps", 12), "the quick…")

// Markup that comes back after the entities are decoded. A feed controls both
// its titles and its summaries, and the old pipeline decoded AFTER stripping,
// so "&lt;img src=...&gt;" left the sanitiser as a live tag. Any Text on Qt's
// default AutoText then renders it and the publisher gets a read receipt.
eq("double-escaped markup does not survive",
   F.stripHtml("&lt;img src=http://tracker/x.png&gt;"), "")
eq("triple-escaped markup does not survive",
   F.stripHtml("&amp;lt;img src=http://tracker/x.png&amp;gt;"), "")
eq("a plain tag does not survive", F.stripHtml("<img src=http://tracker/>"), "")
eq("nor does one wrapped in CDATA",
   F.stripHtml("<![CDATA[&lt;img src=http://tracker/&gt;]]>"), "")
// Nothing that leaves the sanitiser may still look like a tag to Qt's
// rich-text heuristic, because strings handed to shell components (the bar
// tooltip) are rendered by a Text this plugin does not configure.
ok("no output can open a tag", ["&lt;img src=x&gt;", "<b>hi</b>", "x<b", "a<!--c-->b"]
   .every(v => !/<[a-zA-Z\/!?]/.test(F.stripHtml(v))))
// ...while ordinary prose keeps reading like prose.
eq("a legitimate less-than is kept", F.stripHtml("a &lt; b"), "a < b")
eq("entities still decode", F.stripHtml("Tom &amp; Jerry"), "Tom & Jerry")
eq("script bodies still go", F.stripHtml("Real<script>evil()</script>"), "Real")

eq("truncate leaves short text alone", F.truncate("short", 12), "short")

// URLs: anything not http(s) must not survive, because these reach both a
// browser launch and an Image source.
eq("protocol-relative upgraded", F.normalizeUrl("//cdn.example.com/a.jpg"), "https://cdn.example.com/a.jpg")
eq("javascript: refused", F.normalizeUrl("javascript:alert(1)"), "")
eq("file: refused", F.normalizeUrl("file:///etc/passwd"), "")
eq("root-relative needs a base", F.normalizeUrl("/img/a.png"), "")
eq("root-relative joins the base origin",
   F.normalizeUrl("/img/a.png", "https://site.example/x/y"), "https://site.example/img/a.png")
eq("domain strips www", F.domainOf("https://www.bbc.co.uk/news/x"), "bbc.co.uk")

// Dates. Everything lands on epoch ms, so a UTC-5 machine cannot shift a day.
eq("RFC-822 with numeric offset", F.parseDate("Fri, 21 Aug 2026 23:32:17 +0000"), Date.UTC(2026, 7, 21, 23, 32, 17))
eq("RFC-822 GMT", F.parseDate("Sat, 22 Aug 2026 00:40:47 GMT"), Date.UTC(2026, 7, 22, 0, 40, 47))
eq("RFC-822 negative offset", F.parseDate("Fri, 21 Aug 2026 10:15:16 -0500"), Date.UTC(2026, 7, 21, 15, 15, 16))
eq("ISO with offset", F.parseDate("2026-08-21T18:14:11-04:00"), Date.UTC(2026, 7, 21, 22, 14, 11))
eq("ISO with Z", F.parseDate("2026-08-21T16:51:24+00:00"), Date.UTC(2026, 7, 21, 16, 51, 24))
eq("date-only is UTC midnight", F.parseDate("2026-08-21"), Date.UTC(2026, 7, 21))
eq("garbage date is zero, not NaN", F.parseDate("not a date"), 0)

const T0 = Date.UTC(2026, 7, 22, 12, 0, 0)
eq("relTime minutes", F.relTime(T0 - 5 * 60000, T0), "5m")
eq("relTime hours", F.relTime(T0 - 3 * 3600000, T0), "3h")
eq("relTime days", F.relTime(T0 - 3 * 86400000, T0), "3d")
eq("relTime clamps the future", F.relTime(T0 + 60000, T0), "now")
eq("relTime of nothing is empty", F.relTime(0, T0), "")
eq("count compacts", F.count(1032), "1k")
eq("count keeps small numbers exact", F.count(346), "346")

// ============================================================ Feed: Atom
const verge = Feed.parse(fixtureText("verge.xml"), { sid: "rss-theverge-com", url: "https://www.theverge.com/rss/index.xml" }, T0)
ok("verge parses", verge.ok, verge.error)
eq("verge is atom", verge.kind, "atom")
eq("verge channel title", verge.title, "The Verge")
ok("verge has items", verge.items.length > 5, String(verge.items.length))
// Atom entries carry the story on <link rel="alternate">, while <id> is a
// non-navigable permalink (?p=983500). Taking <id> as the link would open a
// redirect page instead of the article.
ok("verge link is the alternate href, not the id",
   verge.items[0].link.indexOf("/tech/983500/hoverair-versa") > 0, verge.items[0].link)
eq("verge author", verge.items[0].author, "Sean Hollister")
ok("verge title decoded", verge.items[0].title.indexOf("HoverAir") === 0, verge.items[0].title)
ok("verge has a date", verge.items[0].hasDate)
// The Verge declares no media:* element anywhere, but embeds the lead image
// as an <img> inside the CDATA summary -- which is why the body scan exists at
// all. Found there, it counts as real artwork and costs no extra request.
ok("verge artwork comes from the summary body",
   verge.items[0].media.image.indexOf("hoverair-versa.jpg") > 0, verge.items[0].media.image)
eq("body artwork is not flagged for upgrade", verge.items[0].media.weak, false)

// ============================================================ Feed: RSS + media
const ars = Feed.parse(fixtureText("ars.xml"), { sid: "rss-arstechnica", url: "https://feeds.arstechnica.com/arstechnica/index" }, T0)
ok("ars parses", ars.ok, ars.error)
eq("ars is rss", ars.kind, "rss")
ok("ars has items", ars.items.length >= 15, String(ars.items.length))
eq("ars author from dc:creator", ars.items[0].author, "Stephen Clark")
ok("ars finds artwork", ars.items[0].media.image.indexOf("http") === 0, ars.items[0].media.image)
ok("ars artwork is strong enough to skip enrichment", ars.items[0].media.weak === false,
   JSON.stringify({ w: ars.items[0].media.imageWidth, weak: ars.items[0].media.weak }))
eq("ars domain", ars.items[0].domain, "arstechnica.com")

// The BBC ships a 240px media:thumbnail and nothing else: usable as a
// placeholder, but the enrichment pass should be allowed to improve on it.
const bbc = Feed.parse(fixtureText("bbc.xml"), { sid: "rss-bbc", url: "https://feeds.bbci.co.uk/news/world/rss.xml" }, T0)
ok("bbc parses", bbc.ok, bbc.error)
ok("bbc finds the thumbnail", bbc.items[0].media.image.indexOf("ichef.bbci.co.uk") > 0, bbc.items[0].media.image)
eq("bbc thumbnail width is read", bbc.items[0].media.imageWidth, 240)
ok("small thumbnail is flagged weak", bbc.items[0].media.weak)
// The BBC hangs at_medium/at_campaign on every link; two fetches of the same
// story must still be one story.
ok("tracking params are stripped from identity",
   bbc.items[0].id.indexOf("at_medium") === -1, bbc.items[0].id)
ok("the link itself keeps working", bbc.items[0].link.indexOf("bbc.co.uk/news/articles/") > 0)

// ============================================================ Feed: video
const yt = Feed.parse(fixtureText("yt.xml"), { sid: "rss-youtube", url: "https://www.youtube.com/feeds/videos.xml" }, T0)
ok("youtube parses", yt.ok, yt.error)
ok("youtube finds a poster", yt.items[0].media.image.indexOf("ytimg.com") > 0, yt.items[0].media.image)
ok("youtube finds the watch url", /youtube\.com\/(watch|v)/.test(yt.items[0].media.video), yt.items[0].media.video)
// A media:content of type application/x-shockwave-flash is a link, not a
// stream. Handing it to a media player gives a permanent spinner.
eq("flash stub is not treated as playable", yt.items[0].media.videoPlayable, false)
eq("mp4 enclosures are playable", M.isPlayable("https://x/a.mp4", "video/mp4"), true)

// ============================================================ Feed: link-only
const lob = Feed.parse(fixtureText("lobsters.xml"), { sid: "rss-lobste-rs", url: "https://lobste.rs/rss" }, T0)
ok("lobsters parses", lob.ok, lob.error)
// <guid> is the lobste.rs thread and <link> is the article. The comments link
// must not overwrite the story link.
ok("lobsters link is the article", lob.items[0].link.indexOf("lobste.rs") === -1, lob.items[0].link)
ok("lobsters keeps a comments link", lob.items[0].comments.indexOf("lobste.rs") > 0, lob.items[0].comments)

// ============================================================ Feed: failure modes
const html = Feed.parse("<!doctype html><html><body>hi</body></html>", { sid: "x" }, T0)
eq("a web page is rejected with a readable reason", html.ok, false)
ok("web page error explains itself", /web page/.test(html.error), html.error)
eq("empty body rejected", Feed.parse("", { sid: "x" }, T0).ok, false)
ok("json body is named as json", /JSON/.test(Feed.parse('{"a":1}', { sid: "x" }, T0).error))

// ============================================================ Hacker News
const hn = Feed.parseHn(fixtureText("hn_frontpage.json"), { sid: "hn" }, T0)
ok("hn parses", hn.ok, hn.error)
ok("hn has stories", hn.items.length >= 15, String(hn.items.length))
ok("hn carries points", hn.items[0].points > 0, String(hn.items[0].points))
ok("hn carries comment counts", hn.items[0].commentCount > 0, String(hn.items[0].commentCount))
ok("hn links to the discussion", /news\.ycombinator\.com\/item\?id=/.test(hn.items[0].comments), hn.items[0].comments)
ok("hn ids are stable across fetches",
   Feed.parseHn(fixtureText("hn_frontpage.json"), { sid: "hn" }, T0 + 99999).items[0].id === hn.items[0].id)
// Ask/Show HN posts have url: null. Falling through to the discussion thread is
// the only thing that opens something readable.
const askish = Feed.parseHn(JSON.stringify({ hits: [{ objectID: "1", title: "Ask HN: anything?", url: null, points: 5, num_comments: 2, created_at_i: 1787320597 }] }), { sid: "hn" }, T0)
eq("textless hn post falls back to its thread", askish.items[0].link, "https://news.ycombinator.com/item?id=1")
eq("and does not duplicate that as a comments link", askish.items[0].comments, "")
eq("hn junk is rejected cleanly", Feed.parseHn("<html>", { sid: "hn" }, T0).ok, false)

// ============================================================ Media precedence
const feedMedia = { image: "https://a/small.jpg", imageWidth: 240, weak: true, video: "", videoPlayable: false, poster: "https://a/small.jpg" }
const og = M.fromOpenGraph({ image: "https://a/big.jpg", imageWidth: 1200 }, "https://a/x")
eq("opengraph replaces weak feed artwork", M.mergeMedia(feedMedia, og).image, "https://a/big.jpg")
const strong = { image: "https://a/lead.jpg", imageWidth: 1200, weak: false, video: "", videoPlayable: false, poster: "" }
eq("opengraph does not override strong feed artwork", M.mergeMedia(strong, og).image, "https://a/lead.jpg")
eq("a 1x1 beacon is not artwork", M.usable("https://feedburner.example/pixel.gif", 1, 1), false)
eq("a real image passes", M.usable("https://cdn.example/lead.jpg", 1200, 600), true)

// ============================================================ Store: merge
const first = Feed.parseHn(fixtureText("hn_frontpage.json"), { sid: "hn" }, T0)
let cache = Store.merge([], first.items, "hn").items
eq("first merge adds everything", cache.length, first.items.length)
cache = Store.setFlag(cache, cache[0].id, "read", true)
cache = Store.toggleBookmark(cache, cache[1].id, T0)
cache = Store.setFlag(cache, cache[0].id, "artwork", "/cache/a.jpg")

// Re-fetching the same feed must not undo what the user did to it.
const second = Feed.parseHn(fixtureText("hn_frontpage.json"), { sid: "hn" }, T0 + 3600000)
const remerged = Store.merge(cache, second.items, "hn")
eq("re-merge adds nothing new", remerged.added, 0)
eq("read survives a re-fetch", Store.index(remerged.items)[cache[0].id].read, true)
eq("bookmark survives a re-fetch", Store.index(remerged.items)[cache[1].id].bookmarked, true)
eq("downloaded artwork survives a re-fetch", Store.index(remerged.items)[cache[0].id].artwork, "/cache/a.jpg")
eq("first-seen time is not reset", Store.index(remerged.items)[cache[0].id].firstSeenMs, T0)

// ============================================================ Store: cleanup
// The contract: cleanup may delete anything except a bookmark.
const old = { id: "s|old", sid: "s", title: "old", link: "https://x/old", publishedMs: T0 - 40 * 86400000, media: {}, artwork: "/cache/old.jpg" }
const oldBookmarked = { id: "s|keep", sid: "s", title: "keep", link: "https://x/k", publishedMs: T0 - 400 * 86400000, bookmarked: true, media: {}, artwork: "/cache/keep.jpg" }
const fresh = { id: "s|new", sid: "s", title: "new", link: "https://x/n", publishedMs: T0 - 3600000, media: {} }
const orphanSource = { id: "gone|z", sid: "gone", title: "z", link: "https://x/z", publishedMs: T0, media: {} }
const orphanBookmark = { id: "gone|b", sid: "gone", title: "b", link: "https://x/b", publishedMs: T0, bookmarked: true, media: {} }

const cleaned = Store.prune([old, oldBookmarked, fresh, orphanSource, orphanBookmark],
                            { nowMs: T0, retentionDays: 7, maxPerSource: 40, validSids: ["s"] })
const keptIds = cleaned.items.map(i => i.id).sort()
eq("cleanup keeps fresh + both bookmarks", keptIds, ["gone|b", "s|keep", "s|new"])
eq("cleanup drops the stale story and the orphaned one", cleaned.removed, 2)
eq("a 400-day-old bookmark is untouchable", cleaned.items.some(i => i.id === "s|keep"), true)
eq("only dropped stories give up their artwork", cleaned.artwork, ["/cache/old.jpg"])

// The per-source cap is a cap on unbookmarked stories, never on bookmarks.
const many = []
for (let i = 0; i < 50; i++) many.push({ id: "s|" + i, sid: "s", title: "t" + i, link: "https://x/" + i, publishedMs: T0 - i * 60000, media: {}, bookmarked: i === 49 })
const capped = Store.prune(many, { nowMs: T0, retentionDays: 30, maxPerSource: 10 })
eq("cap keeps ten plus the bookmark", capped.items.length, 11)
eq("the oldest bookmark outlives the cap", capped.items.some(i => i.id === "s|49"), true)

// Artwork files are reclaimed by ownership, not by age.
eq("orphan artwork is found",
   Store.orphanArtwork([{ artwork: "/c/a.jpg" }], ["/c/a.jpg", "/c/b.jpg", "/c/c.jpg"]), ["/c/b.jpg", "/c/c.jpg"])

// ============================================================ Store: views
const viewItems = [
  { id: "a", sid: "hn", title: "Rust compiler news", domain: "rust-lang.org", read: false, bookmarked: false, publishedMs: 3, media: {} },
  { id: "b", sid: "hn", title: "Kernel patch", domain: "lwn.net", read: true, bookmarked: false, publishedMs: 2, media: {} },
  { id: "c", sid: "rss-x", title: "Saved thing", domain: "x.com", read: true, bookmarked: true, publishedMs: 1, media: {} }
]
eq("all view is newest first", Store.view(viewItems, {}).map(i => i.id), ["a", "b", "c"])
eq("source view filters", Store.view(viewItems, { sid: "rss-x" }).map(i => i.id), ["c"])
eq("bookmarks view", Store.view(viewItems, { sid: Store.BOOKMARKS_VIEW }).map(i => i.id), ["c"])
// A bookmark you have read is still worth showing in the unread view -- it is
// there because you put it there.
eq("unread view keeps bookmarks", Store.view(viewItems, { unreadOnly: true }).map(i => i.id), ["a", "c"])
eq("search matches all words", Store.view(viewItems, { query: "rust compiler" }).map(i => i.id), ["a"])
eq("search misses when one word misses", Store.view(viewItems, { query: "rust kernel" }).length, 0)
eq("stats count what the footer shows",
   (s => [s.total, s.unread, s.bookmarked])(Store.stats(viewItems)), [3, 1, 1])

// Enrichment must not retry a page that already said no.
const q = Store.enrichQueue([
  { id: "1", link: "https://a", read: false, publishedMs: 3, media: { weak: true }, artwork: "" },
  { id: "2", link: "https://b", read: false, publishedMs: 2, media: { weak: true }, artwork: "", enrichFailed: true },
  { id: "3", link: "https://c", read: true, publishedMs: 9, media: { weak: true }, artwork: "" },
  { id: "4", link: "https://d", read: false, publishedMs: 1, media: { weak: false }, artwork: "/c/d.jpg" }
], 10)
eq("enrich queue skips failures and finished work, unread first", q.map(i => i.id), ["1", "3"])
eq("enrich queue honours its budget", Store.enrichQueue([
  { id: "1", link: "https://a", media: { weak: true }, artwork: "" },
  { id: "2", link: "https://b", media: { weak: true }, artwork: "" }
], 1).length, 1)

// ============================================================ Sources
eq("hn is the shipped default", Src.normalize([])[0].type, "hn")
eq("hn front page keeps a clean id", Src.normalize([])[0].sid, "hn")
eq("ids come from the url, not the position",
   Src.normalize([{ type: "rss", url: "https://lobste.rs/rss" }])[0].sid, "rss-lobste-rs-rss")
const reordered = Src.normalize([{ type: "rss", url: "https://a.example/f" }, { type: "rss", url: "https://lobste.rs/rss" }])
eq("removing a source does not re-key its neighbours",
   Src.normalize(Src.removeAt(reordered, 0))[0].sid, "rss-lobste-rs-rss")
eq("a bare host is upgraded to https", Src.validateUrl("lobste.rs/rss").url, "https://lobste.rs/rss")
eq("file: urls are refused", Src.validateUrl("file:///etc/passwd").ok, false)
eq("javascript: urls are refused", Src.validateUrl("javascript:alert(1)").ok, false)
eq("an unparseable list falls back to the default", Src.normalize([{ type: "rss", url: "nonsense::" }])[0].type, "hn")
eq("duplicate sources collapse", Src.normalize([{ type: "hn" }, { type: "hn" }]).length, 1)
// THE bug this suite exists to keep fixed. A JS array handed across a QML `var`
// property boundary -- which is every list read out of shell.json -- arrives as
// a wrapper that indexes and reports .length like an array but answers false to
// Array.isArray(). Guarding on Array.isArray silently discarded every
// user-configured feed and fell back to the shipped default, on the real shell,
// with no error anywhere. Modelled here as an array-like object.
function asQmlList(arr) {
  const wrapped = { length: arr.length }
  arr.forEach((v, i) => { wrapped[i] = v })
  return wrapped   // Array.isArray(wrapped) === false, by construction
}
const wrappedSources = asQmlList([
  { type: "hn", label: "Hacker News", feed: "front_page", enabled: true },
  { type: "rss", label: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", enabled: true },
  { type: "rss", label: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml", enabled: true }
])
ok("the wrapper really is not an Array", Array.isArray(wrappedSources) === false)
eq("a QML-wrapped source list survives normalising", Src.normalize(wrappedSources).length, 3)
eq("and keeps every id", Src.normalize(wrappedSources).map(s => s.sid),
   ["hn", "rss-feeds-arstechnica-com-arstechnica-index", "rss-feeds-bbci-co-uk-news-world-rss-xml"])
eq("a QML-wrapped list reorders", Src.move(wrappedSources, 0, 2).length, 3)
eq("a QML-wrapped list removes", Src.removeAt(wrappedSources, 1).length, 2)
eq("a QML-wrapped list persists", Src.toConfig(Src.normalize(wrappedSources)).length, 3)
eq("a string is not a list", Src.toArray("nope"), [])
eq("null is not a list", Src.toArray(null), [])

ok("hn endpoint asks for the front page",
   /tags=front_page/.test(Src.endpointFor({ type: "hn", feed: "front_page" }, 40)))
ok("hn endpoint honours the per-source cap",
   /hitsPerPage=40/.test(Src.endpointFor({ type: "hn", feed: "front_page" }, 40)))
eq("rss endpoint is the url itself",
   Src.endpointFor({ type: "rss", url: "https://lobste.rs/rss" }, 40), "https://lobste.rs/rss")
// sid is derived; persisting it would let a stale copy outlive its URL.
ok("persisted config carries no derived id", Src.toConfig(Src.normalize([]))[0].sid === undefined)
eq("every preset normalises", Src.PRESETS.filter(p => Src.normalize([p]).length === 1).length, Src.PRESETS.length)

// ============================================================
console.log(`\n${pass} passed, ${fail} failed`)
if (fail) {
  console.log("\nFailures:")
  for (const f of failures) console.log("  ✗ " + f)
  process.exit(1)
}
