.pragma library

// Text coming out of a feed is HTML written by strangers. Everything here
// assumes hostile input: entities inside CDATA inside markup, unclosed tags,
// tracking junk in URLs. Nothing throws; the worst case is an empty string.

var NAMED = {
  amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ", ndash: "–",
  mdash: "—", hellip: "…", lsquo: "‘", rsquo: "’",
  ldquo: "“", rdquo: "”", laquo: "«", raquo: "»",
  copy: "©", reg: "®", trade: "™", deg: "°", middot: "·",
  bull: "•", eacute: "é", egrave: "è", agrave: "à",
  ccedil: "ç", uuml: "ü", ouml: "ö", auml: "ä", szlig: "ß",
  ntilde: "ñ", aacute: "á", iacute: "í", oacute: "ó",
  uacute: "ú", euro: "€", pound: "£", times: "×"
}

// Entities can be double-escaped (&amp;amp;) when a feed CDATA-wraps content
// that was already escaped once. Two passes cover every case seen in the wild;
// a while-loop would let a crafted "&amp;amp;amp;..." chain spin.
function decodeEntities(s) {
  if (!s) return ""
  var out = String(s)
  for (var pass = 0; pass < 2; pass++) {
    out = out.replace(/&#x([0-9a-fA-F]+);/g, function(_, h) {
      var n = parseInt(h, 16)
      return isFinite(n) && n > 0 && n <= 0x10FFFF ? String.fromCodePoint(n) : ""
    })
    out = out.replace(/&#(\d+);/g, function(_, d) {
      var n = parseInt(d, 10)
      return isFinite(n) && n > 0 && n <= 0x10FFFF ? String.fromCodePoint(n) : ""
    })
    out = out.replace(/&([a-zA-Z][a-zA-Z0-9]{1,10});/g, function(m, name) {
      var v = NAMED[name]
      if (v !== undefined) return v
      var lower = NAMED[name.toLowerCase()]
      return lower !== undefined ? lower : m
    })
  }
  return out
}

function stripCdata(s) {
  if (!s) return ""
  return String(s).replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
}

// Script and style bodies are removed rather than tag-stripped: leaving their
// text content behind dumps minified JavaScript into a headline.
function stripHtml(s) {
  if (!s) return ""
  var out = stripCdata(String(s))
  out = out.replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
  out = out.replace(/<br\s*\/?>/gi, " ")
  out = out.replace(/<\/(p|div|li|h[1-6])>/gi, " ")
  out = out.replace(/<[^>]*>/g, "")
  out = decodeEntities(out)
  return collapse(out)
}

function collapse(s) {
  return String(s || "").replace(/[\s ]+/g, " ").replace(/^\s+|\s+$/g, "")
}

function plainText(s) { return stripHtml(s) }

function truncate(s, n) {
  var t = collapse(s)
  if (!n || t.length <= n) return t
  // Break on a word boundary when one is close enough that the cut does not
  // lose a meaningful chunk of the last word.
  var cut = t.slice(0, n)
  var sp = cut.lastIndexOf(" ")
  if (sp > n * 0.6) cut = cut.slice(0, sp)
  return cut.replace(/[\s,.;:!?-]+$/, "") + "…"
}

// ---------------------------------------------------------------- URLs

function isHttpUrl(u) {
  return /^https?:\/\/[^\s<>"']+$/i.test(String(u || "").replace(/^\s+|\s+$/g, ""))
}

// Feeds hand out protocol-relative and scheme-less URLs freely. Anything that
// is not http(s) after normalising is refused outright -- a file: or
// javascript: URL must never reach a browser launch or an Image source.
function normalizeUrl(u, baseUrl) {
  var s = String(u || "").replace(/^\s+|\s+$/g, "")
  if (!s) return ""
  s = decodeEntities(s)
  if (/^\/\//.test(s)) s = "https:" + s
  if (/^https?:\/\//i.test(s)) return isHttpUrl(s) ? s : ""
  if (baseUrl && /^\//.test(s)) {
    var origin = String(baseUrl).match(/^(https?:\/\/[^\/]+)/i)
    if (origin) {
      var joined = origin[1] + s
      return isHttpUrl(joined) ? joined : ""
    }
  }
  return ""
}

function domainOf(u) {
  var m = String(u || "").match(/^https?:\/\/([^\/?#:]+)/i)
  if (!m) return ""
  return m[1].replace(/^www\d?\./i, "").toLowerCase()
}

// ---------------------------------------------------------------- time

var MONTHS = { jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5, jul: 6, aug: 7,
               sep: 8, oct: 9, nov: 10, dec: 11 }

// Date.parse handles ISO-8601 and, in most engines, RFC-822. "Most" is not a
// contract worth resting a timeline on, so both grammars are parsed here and
// Date.parse is only the last resort. Everything returns epoch ms (UTC), so no
// local-midnight drift is possible downstream.
function parseDate(raw) {
  var s = collapse(raw)
  if (!s) return 0

  var iso = s.match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?)?/)
  if (iso) {
    var ms = Date.UTC(+iso[1], +iso[2] - 1, +iso[3], +(iso[4] || 0), +(iso[5] || 0), +(iso[6] || 0))
    return ms - offsetMs(iso[7])
  }

  var rfc = s.match(/^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{2,4})(?:\s+(\d{2}):(\d{2})(?::(\d{2}))?)?\s*([A-Z]{1,5}|[+-]\d{4})?/)
  if (rfc) {
    var mon = MONTHS[rfc[2].toLowerCase()]
    if (mon === undefined) return fallbackParse(s)
    var year = +rfc[3]
    if (year < 100) year += year < 70 ? 2000 : 1900
    var t = Date.UTC(year, mon, +rfc[1], +(rfc[4] || 0), +(rfc[5] || 0), +(rfc[6] || 0))
    return t - offsetMs(rfc[7])
  }

  return fallbackParse(s)
}

function fallbackParse(s) {
  var n = Date.parse(s)
  return isFinite(n) ? n : 0
}

// Named military/zone abbreviations beyond UT/GMT/Z are ambiguous by
// definition (RFC 2822 says to treat them as -0000), so they read as UTC.
function offsetMs(tz) {
  if (!tz) return 0
  var t = String(tz).toUpperCase()
  if (t === "Z" || t === "UT" || t === "UTC" || t === "GMT") return 0
  var num = t.match(/^([+-])(\d{2}):?(\d{2})$/)
  if (num) {
    var mins = (+num[2]) * 60 + (+num[3])
    return (num[1] === "-" ? -1 : 1) * mins * 60000
  }
  var named = { EST: -5, EDT: -4, CST: -6, CDT: -5, MST: -7, MDT: -6,
                PST: -8, PDT: -7, BST: 1, CET: 1, CEST: 2 }
  return named[t] !== undefined ? named[t] * 3600000 : 0
}

// Compact age, sized for a bar pill: minutes, then hours, then days, then a
// date. "now" is a parameter so the tests are not clock-dependent.
function relTime(whenMs, nowMs) {
  var when = Number(whenMs) || 0
  if (!when) return ""
  var now = Number(nowMs) || Date.now()
  var d = now - when
  if (d < 0) return "now"
  var mins = Math.floor(d / 60000)
  if (mins < 1) return "now"
  if (mins < 60) return mins + "m"
  var hours = Math.floor(mins / 60)
  if (hours < 24) return hours + "h"
  var days = Math.floor(hours / 24)
  if (days < 7) return days + "d"
  var weeks = Math.floor(days / 7)
  if (days < 365) return weeks + "w"
  return Math.floor(days / 365) + "y"
}

function absTime(whenMs) {
  var when = Number(whenMs) || 0
  if (!when) return ""
  var d = new Date(when)
  var names = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
  var hh = ("0" + d.getHours()).slice(-2)
  var mm = ("0" + d.getMinutes()).slice(-2)
  return names[d.getMonth()] + " " + d.getDate() + ", " + hh + ":" + mm
}

function count(n) {
  var v = Number(n) || 0
  if (v < 1000) return String(v)
  if (v < 10000) return (v / 1000).toFixed(1).replace(/\.0$/, "") + "k"
  return Math.round(v / 1000) + "k"
}

function bytes(n) {
  var v = Number(n) || 0
  if (v < 1024) return v + " B"
  if (v < 1024 * 1024) return Math.round(v / 1024) + " KB"
  return (v / 1048576).toFixed(1) + " MB"
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    decodeEntities: decodeEntities, stripCdata: stripCdata, stripHtml: stripHtml,
    collapse: collapse, plainText: plainText, truncate: truncate,
    isHttpUrl: isHttpUrl, normalizeUrl: normalizeUrl, domainOf: domainOf,
    parseDate: parseDate, offsetMs: offsetMs, relTime: relTime, absTime: absTime,
    count: count, bytes: bytes
  }
}
