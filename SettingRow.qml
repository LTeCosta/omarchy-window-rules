import QtQuick
import qs.Commons
import qs.Ui

// One setting: a title and a dim one-line description on the left, its
// control on the right (the children), on the panel's cursor surface. The
// instance defines keyboardEnabled, keyboardActivate and, when it has one,
// keyboardAdjust; a click on the row outside its control emits clicked().
CursorSurface {
  id: row

  property string title: ""
  property string detail: ""
  property string fontFamily: Style.font.family
  default property alias controls: controlRow.data

  readonly property color dim: Qt.darker(foreground, 1.4)

  signal clicked()
  signal pointerEntered()

  width: parent ? parent.width : implicitWidth
  implicitHeight: content.implicitHeight + Style.space(12)

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: if (containsMouse) row.pointerEntered()
    onClicked: row.clicked()
  }

  Item {
    id: content
    x: Style.space(8)
    width: parent.width - Style.space(16)
    anchors.verticalCenter: parent.verticalCenter
    implicitHeight: Math.max(labels.implicitHeight, controlRow.implicitHeight)

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: controlRow.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: row.title
        color: row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: row.detail
        color: row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: controlRow
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
    }
  }
}
