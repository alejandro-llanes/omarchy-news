import QtQuick
import QtQuick.Effects
import qs.Commons

// The picture on a story card.
//
// Three states, and the third one is the interesting one: most stories in most
// feeds have no artwork at all, and a card that just leaves a hole there looks
// broken rather than sparse. So a story with no picture gets a generated plate
// -- a wash mixed from the theme's own colours at an angle derived from the
// publisher's domain, with its initials set large. Same domain, same plate,
// every time, in whatever theme is loaded.
Item {
  id: root

  property var story: null
  property bool showMedia: true
  property real radius: Style.cornerRadius
  property bool compact: false
  // Decoding a 2000px press photo into a 120px thumbnail costs real memory per
  // card. The frame tells Qt the size it actually needs.
  property int decodeWidth: Math.max(64, Math.round(width * 2))

  readonly property var media: story && story.media ? story.media : ({})
  readonly property string localArtwork: story && story.artwork ? story.artwork : ""
  // The URL the publisher named. Recorded so the card can tell "no picture
  // exists" from "the picture has not been downloaded yet", and deliberately
  // NEVER handed to the Image below -- see the note on `source`.
  readonly property string remoteArtwork: media.image || media.poster || ""
  readonly property bool hasVideo: !!media.video
  readonly property bool hasArtwork: image.status === Image.Ready

  // The downloaded copy is preferred: it is already on disk, it costs the
  // publisher nothing to show again, and it is what the cache controls own.
  // The remote URL is the fallback for the window between a story arriving and
  // its picture being fetched -- and for after a cleanup deleted the file.
  property bool localFailed: false

  readonly property string domain: story ? (story.domain || "") : ""

  // Deterministic from the domain, so a publisher's plate never changes
  // between openings. Not a hash with any strength requirement -- just a
  // stable spread.
  readonly property int domainSeed: {
    var s = domain || (story ? story.title || "" : "")
    var h = 0
    for (var i = 0; i < s.length; i++) h = ((h << 5) - h + s.charCodeAt(i)) | 0
    return Math.abs(h)
  }

  readonly property string monogram: {
    var d = domain.replace(/^(www|feeds|rss|blog|news)\./, "")
    if (!d) return "◆"
    var parts = d.split(".")
    var name = parts[0] || d
    if (name.length >= 2) return name.substring(0, 2).toUpperCase()
    return name.toUpperCase()
  }

  clip: true

  // ---- the plate behind everything ----------------------------------------
  Rectangle {
    id: plate
    anchors.fill: parent
    radius: root.radius
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)

    // Two tints from the palette, angled by the domain seed. On a monochrome
    // theme this reads as a subtle graphite wash rather than as colour, which
    // is the right outcome -- it should never fight the theme.
    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      visible: !root.hasArtwork
      gradient: Gradient {
        orientation: root.domainSeed % 2 === 0 ? Gradient.Vertical : Gradient.Horizontal
        GradientStop {
          position: 0.0
          color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10 + (root.domainSeed % 7) * 0.012)
        }
        GradientStop {
          position: 1.0
          color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.03)
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: !root.hasArtwork && !skeleton.visible
      text: root.monogram
      font.family: Style.font.family
      font.pixelSize: Math.max(Style.font.body, Math.min(root.height * 0.42, Style.fontPx(2.6)))
      font.letterSpacing: 1
      color: Color.foreground
      opacity: 0.32
      renderType: Text.NativeRendering
    }
  }

  // ---- the picture ---------------------------------------------------------
  Item {
    id: imageHolder
    anchors.fill: parent
    visible: root.showMedia

    // Masking costs a full offscreen layer per card, so it is only switched on
    // when the theme actually rounds its corners. At rounding 0 -- the Omarchy
    // default -- this is a plain textured rectangle.
    layer.enabled: root.radius > 0
    layer.smooth: true
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: maskShape
      maskThresholdMin: 0.5
      maskSpreadAtMin: 0.1
    }

    Image {
      id: image
      anchors.fill: parent
      // Local files only, never a remote URL.
      //
      // Pointing an Image at a publisher's URL makes the shell itself fetch it:
      // outside the helper's byte and time limits, with no check that what
      // comes back is even an image, and announcing to the publisher exactly
      // when the story was displayed. Everything shown here has already been
      // through bin/news-media, which bounds the download and identifies the
      // format by sniffing the bytes. A story whose picture has not been
      // downloaded yet simply shows its plate until it has.
      source: (root.showMedia && root.localArtwork && !root.localFailed)
              ? Util.fileUrl(root.localArtwork) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      smooth: true
      sourceSize.width: root.decodeWidth
      opacity: status === Image.Ready ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

      // A cleanup can delete the file under a card that is already on screen.
      // The card falls back to its plate rather than to the publisher's URL.
      onStatusChanged: {
        if (status === Image.Error && root.localArtwork && !root.localFailed) root.localFailed = true
      }
    }
  }

  Item {
    id: maskShape
    anchors.fill: parent
    visible: false
    layer.enabled: true
    Rectangle { anchors.fill: parent; radius: root.radius; color: "white" }
  }

  // ---- loading ------------------------------------------------------------
  // A quiet pulse, not a spinner: several of these are on screen at once and
  // half a dozen spinners in a popup is a slot machine.
  Rectangle {
    id: skeleton
    anchors.fill: parent
    radius: root.radius
    // Decode only. Tying this to "a download is still pending" would pulse
    // forever whenever the download is never going to arrive -- the page had no
    // picture, or the network is switched off -- and a card that pulses
    // indefinitely reads as broken. The plate shows immediately instead, and
    // the picture replaces it if and when it lands.
    visible: root.showMedia && image.status === Image.Loading
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)

    SequentialAnimation on opacity {
      running: skeleton.visible
      loops: Animation.Infinite
      NumberAnimation { from: 0.35; to: 0.85; duration: 900; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.85; to: 0.35; duration: 900; easing.type: Easing.InOutSine }
    }
  }

  // ---- video affordance ----------------------------------------------------

  // A hairline scrim so a play glyph never has to sit on a white sky. Declared
  // before the badge so it draws over the picture and under the glyph: these
  // siblings share a z, so document order is the stacking order.
  Rectangle {
    visible: playBadge.visible
    anchors.fill: parent
    radius: root.radius
    color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.12)
  }

  // A play badge, not an autoplaying preview. The card is 120px of a popup on
  // someone's desktop; video starts when it is asked to.
  Rectangle {
    id: playBadge
    visible: root.hasVideo && root.showMedia
    anchors.centerIn: parent
    width: badgeSize
    height: badgeSize
    radius: badgeSize / 2
    readonly property int badgeSize: root.compact ? Style.space(26) : Style.space(44)
    color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.62)
    border.width: Math.max(1, Style.space(1))
    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.55)

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      // Nudged right by an eighth: a triangle glyph is optically left-heavy in
      // a circle when it is centred by its bounding box.
      anchors.horizontalCenterOffset: Math.round(parent.badgeSize / 14)
      text: "▶"
      font.family: Style.font.family
      font.pixelSize: Math.round(parent.badgeSize * 0.38)
      color: Color.foreground
      renderType: Text.NativeRendering
    }
  }

}
