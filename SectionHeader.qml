import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A panel section's small-caps title with a dim note on the right ("RULES ·
// last match wins", "MATCH · matches 2 windows"), and room above it to set
// the section off from the one before. `metaTooltip` explains the note on hover.
Item {
  id: header

  property string text: ""
  property string meta: ""
  property string metaTooltip: ""
  property color metaColor: Qt.darker(foreground, 1.4)
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property real gap: Style.space(6)

  width: parent ? parent.width : implicitWidth
  implicitHeight: gap + Math.max(title.implicitHeight, metaText.implicitHeight)

  PanelSectionHeader {
    id: title
    anchors.left: parent.left
    anchors.right: metaText.left
    anchors.rightMargin: Style.space(8)
    anchors.bottom: parent.bottom
    text: header.text.toUpperCase()
    foreground: header.foreground
    fontFamily: header.fontFamily
    elide: Text.ElideRight
  }

  Text {
    id: metaText
    textFormat: Text.PlainText
    anchors.right: parent.right
    anchors.baseline: title.baseline
    width: Math.min(implicitWidth, header.width * 0.6)
    visible: text !== ""
    text: header.meta
    color: header.metaColor
    font.family: header.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    elide: Text.ElideRight

    HoverHandler { id: metaHover }
    PanelToolTip {
      visible: header.metaTooltip !== "" && metaHover.hovered
      text: header.metaTooltip
      fontFamily: header.fontFamily
    }
  }
}
