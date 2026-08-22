.pragma library
.import "Format.js" as Fmt

// Artwork discovery inside one feed item.
//
// There is no single place a feed puts its picture. Across the feeds this was
// built against: Ars ships media:thumbnail AND media:content, the BBC ships a
// 240px media:thumbnail and nothing else, YouTube nests everything in a
// media:group, The Verge and Lobsters ship no image at all. So this walks every
// known carrier in quality order and keeps the best candidate, recording how
// confident it is so the enrichment pass knows whether it is worth asking the
// article page for something better.

// Feeds carry beacons dressed as images. A 1x1 with a tracking host is the
// classic, but so is any declared dimension small enough to be worthless as
// card artwork.
var BEACON_HOSTS = /(feedburner|feedsportal|doubleclick|scorecardresearch|pixel\.|\.gif$)/i
var MIN_USEFUL_PX = 64

function attr(tag, name) {
  var re = new RegExp(name + '\\s*=\\s*"([^"]*)"', "i")
  var m = String(tag || "").match(re)
  if (m) return Fmt.decodeEntities(m[1])
  var re2 = new RegExp(name + "\\s*=\\s*'([^']*)'", "i")
  var m2 = String(tag || "").match(re2)
  return m2 ? Fmt.decodeEntities(m2[1]) : ""
}

function num(v) {
  var n = parseInt(String(v || "").replace(/[^0-9]/g, ""), 10)
  return isFinite(n) ? n : 0
}

function isImageish(url, type) {
  if (/^image\//i.test(type || "")) return true
  return /\.(jpe?g|png|webp|gif|avif)(\?|#|$)/i.test(String(url || ""))
}

function isVideoish(url, type, medium) {
  if (String(medium || "").toLowerCase() === "video") return true
  if (/^video\//i.test(type || "")) return true
  return /\.(mp4|webm|mov|m4v)(\?|#|$)/i.test(String(url || ""))
}

// Playable in-process means a bare progressive file Qt Multimedia can open.
// A YouTube watch page or a Flash-era media:content stub is a link, not a
// stream, and pretending otherwise gives a permanently spinning player.
function isPlayable(url, type) {
  if (/^application\//i.test(type || "")) return false
  return /\.(mp4|webm|m4v)(\?|#|$)/i.test(String(url || ""))
}

function usable(url, width, height) {
  var u = String(url || "")
  if (!Fmt.isHttpUrl(u)) return false
  if (BEACON_HOSTS.test(u) && (width || height) && width <= 2 && height <= 2) return false
  if (width && height && (width < 8 || height < 8)) return false
  return true
}

function candidate(url, width, height, kind) {
  return { url: url, width: width || 0, height: height || 0, kind: kind || "image" }
}

// Bigger wins, and a declared size beats an unknown one: an undeclared image
// could be anything, and a card would rather show a known-good 600px thumbnail
// than gamble on a mystery URL.
function better(a, b) {
  if (!a) return b
  if (!b) return a
  var aw = a.width || 0, bw = b.width || 0
  if (aw !== bw) return aw > bw ? a : b
  return a
}

function extract(itemXml, htmlBody, link) {
  var xml = String(itemXml || "")
  var image = null
  var video = null
  var poster = null

  // 1. media:content -- the richest carrier, and the only one that reliably
  //    declares both a medium and dimensions.
  var mc = xml.match(/<media:content\b[^>]*\/?>/gi) || []
  for (var i = 0; i < mc.length; i++) {
    var tag = mc[i]
    var url = Fmt.normalizeUrl(attr(tag, "url"), link)
    if (!url) continue
    var type = attr(tag, "type")
    var medium = attr(tag, "medium")
    var w = num(attr(tag, "width")), h = num(attr(tag, "height"))
    if (isVideoish(url, type, medium)) {
      if (!video) video = { url: url, type: type, playable: isPlayable(url, type) }
    } else if (isImageish(url, type) || medium.toLowerCase() === "image") {
      if (usable(url, w, h)) image = better(image, candidate(url, w, h))
    }
  }

  // 2. media:thumbnail -- present on almost everything that has media:content,
  //    and the poster frame for video items.
  var mt = xml.match(/<media:thumbnail\b[^>]*\/?>/gi) || []
  for (var j = 0; j < mt.length; j++) {
    var turl = Fmt.normalizeUrl(attr(mt[j], "url"), link)
    if (!turl) continue
    var tw = num(attr(mt[j], "width")), th = num(attr(mt[j], "height"))
    if (!usable(turl, tw, th)) continue
    var cand = candidate(turl, tw, th, "thumbnail")
    poster = better(poster, cand)
    image = better(image, cand)
  }

  // 3. enclosure -- the RSS 2.0 original, one per item by spec.
  var enc = xml.match(/<enclosure\b[^>]*\/?>/gi) || []
  for (var k = 0; k < enc.length; k++) {
    var eurl = Fmt.normalizeUrl(attr(enc[k], "url"), link)
    if (!eurl) continue
    var etype = attr(enc[k], "type")
    if (isVideoish(eurl, etype, "")) {
      if (!video) video = { url: eurl, type: etype, playable: isPlayable(eurl, etype) }
    } else if (isImageish(eurl, etype) && usable(eurl, 0, 0)) {
      image = better(image, candidate(eurl, 0, 0))
    }
  }

  // 4. itunes:image -- podcast feeds, square art.
  var itunes = xml.match(/<itunes:image\b[^>]*\/?>/i)
  if (itunes) {
    var iurl = Fmt.normalizeUrl(attr(itunes[0], "href"), link)
    if (iurl && usable(iurl, 0, 0)) image = better(image, candidate(iurl, 0, 0))
  }

  // 5. The first <img> inside the rendered body. Last because publishers lead
  //    with author avatars and sharing badges as often as with the real photo.
  if (!image && htmlBody) {
    var imgs = String(htmlBody).match(/<img\b[^>]*>/gi) || []
    for (var n = 0; n < imgs.length; n++) {
      var surl = Fmt.normalizeUrl(attr(imgs[n], "src"), link)
      if (!surl) continue
      var iw = num(attr(imgs[n], "width")), ih = num(attr(imgs[n], "height"))
      if (!usable(surl, iw, ih)) continue
      image = candidate(surl, iw, ih)
      break
    }
  }

  // YouTube and friends put the watch URL on the entry itself; a media:group
  // video stub is not playable, but the item still deserves a play affordance.
  if (!video && /<yt:videoId>/i.test(xml)) {
    var vid = xml.match(/<yt:videoId>([^<]+)<\/yt:videoId>/i)
    if (vid) video = { url: "https://www.youtube.com/watch?v=" + Fmt.collapse(vid[1]), type: "text/html", playable: false }
  }

  var chosen = image || poster
  return {
    image: chosen ? chosen.url : "",
    imageWidth: chosen ? chosen.width : 0,
    imageHeight: chosen ? chosen.height : 0,
    // A thumbnail the publisher itself calls small is worth upgrading from the
    // article page; a 1200px lead image is not.
    weak: !chosen || (chosen.width > 0 && chosen.width < 320) || chosen.kind === "thumbnail" && chosen.width < MIN_USEFUL_PX * 5,
    video: video ? video.url : "",
    videoPlayable: video ? video.playable === true : false,
    poster: poster ? poster.url : (chosen ? chosen.url : "")
  }
}

// OpenGraph tags scraped from the article page by bin/news-media. Kept here so
// the precedence rules live next to the feed ones and are testable together.
function fromOpenGraph(og, link) {
  var o = og || {}
  var image = Fmt.normalizeUrl(o.image || o.twitterImage || "", link)
  var video = Fmt.normalizeUrl(o.video || "", link)
  return {
    image: image,
    imageWidth: num(o.imageWidth),
    imageHeight: num(o.imageHeight),
    weak: !image,
    video: video,
    videoPlayable: video ? isPlayable(video, o.videoType || "") : false,
    poster: image,
    siteName: Fmt.collapse(o.siteName || "")
  }
}

// The feed's own artwork wins unless it was flagged weak, because the feed is
// the publisher speaking about this item while OpenGraph is frequently a
// site-wide default card.
function mergeMedia(feedMedia, ogMedia) {
  var f = feedMedia || {}
  var o = ogMedia || {}
  if (!o.image && !o.video) return f
  var out = {
    image: f.image, imageWidth: f.imageWidth, imageHeight: f.imageHeight,
    video: f.video, videoPlayable: f.videoPlayable, poster: f.poster, weak: f.weak
  }
  if (o.image && (!f.image || f.weak)) {
    out.image = o.image
    out.imageWidth = o.imageWidth
    out.imageHeight = o.imageHeight
    out.weak = false
    if (!out.poster || f.weak) out.poster = o.image
  }
  if (o.video && !f.video) {
    out.video = o.video
    out.videoPlayable = o.videoPlayable
  }
  return out
}

function hasMedia(m) {
  return !!(m && (m.image || m.video))
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { extract: extract, fromOpenGraph: fromOpenGraph, mergeMedia: mergeMedia,
                     hasMedia: hasMedia, attr: attr, isPlayable: isPlayable, usable: usable }
}
