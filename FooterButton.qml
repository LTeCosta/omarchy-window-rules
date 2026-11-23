import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A footer action: a bordered button with an icon and a short label, and a
// keyboard cursor stop. The panel passes its `cursorItem`, so the highlight
// follows the shared cursor, and handles activated() for a click and Enter.
// While `available` is false it is disabled, skipped by the cursor, and shows
// `unavailableText` on hover (a disabled kit Button shows no tooltip).
Item {
  id: action

  property string text: ""
  property string iconText: ""
  property string tooltipText: ""
  property bool available: true
  property string unavailableText: ""
  property var cursorItem: null
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  readonly property bool keyboardEnabled: visible && available

  signal activated()
  signal pointerEntered()

  function keyboardActivate() { if (available) activated() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Button {
    id: button
    anchors.fill: parent
    enabled: action.available
    bordered: true
    text: action.text
    iconText: action.iconText
    tooltipText: action.tooltipText
    hasCursor: action.cursorItem === action
    foreground: action.foreground
    fontFamily: action.fontFamily
    fontSize: Style.font.bodySmall
    onHovered: function(on) { if (on && action.keyboardEnabled) action.pointerEntered() }
    onClicked: action.keyboardActivate()
  }

  HoverHandler { id: unavailableHover }
  PanelToolTip {
    visible: !action.available && action.unavailableText !== "" && unavailableHover.hovered
    text: action.unavailableText
    fontFamily: action.fontFamily
  }
}
